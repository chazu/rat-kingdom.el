;;; rat-kingdom-message.el --- Messages to a story's worker -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Chaz Straney

;; Author: Chaz Straney <chaz.straney@gmail.com>
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Messages to workers (DESIGN.md, sections 5.4, 8.2 and 9).
;;
;; The king tells a story's worker something with the `tell' tool.  The
;; message is a linear `message' tuple scoped to the story's repository
;; and owned by the story, so it is archived with it, with the payload
;; `:to-story STORY :from FROM :text TEXT'.  It is addressed to the
;; story, not to a run: whichever worker the story has when the message
;; can be given is the one that reads it.
;;
;; A message is given to the story's current run only while that run is
;; `working', that is, has not reported with `finish' or `block'.  It is
;; given as the run's next prompt: at once if the agent is between
;; turns, otherwise when it ends its turn.  A worker can also fetch its
;; messages in the middle of a turn with the `inbox' tool.  Messages are
;; removed only once they have been handed over, so a crash repeats one
;; rather than loses it.
;;
;; A story with no working run keeps its messages until its next worker
;; starts.  They are in that worker's brief, and are removed when the
;; run has actually started, that is, when it becomes `working'.  Which
;; messages went into which brief is kept in memory.  If Emacs stops
;; between the brief and the start, the messages stay in the space, and
;; once the restarted run is working they are given to it again as a
;; prompt: repeated, not lost.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'rat-kingdom-space)
(require 'rat-kingdom-mcp)
(require 'rat-kingdom-run)
(require 'rat-kingdom-story)
(require 'rat-kingdom-king)

(defcustom rat-kingdom-message-retry-interval 20
  "Seconds between tries to give a worker messages it could not take.
A worker that is in the middle of a turn is not tried again this way;
it is given its messages when the turn ends."
  :type 'number
  :group 'rat-kingdom)

(defconst rat-kingdom-message-brief-heading
  "Messages for this task from the king (oldest first):"
  "The heading of the section of a worker's brief that holds its messages.")

(defvar rat-kingdom-message--briefed (make-hash-table :test #'equal)
  "Hash table from run id to the messages put in its brief.
Each value is (IDS . SECTION): the ids of the message tuples, and the
section of the prompt they were given in.  They are removed from the
space once the run is working.")

(defvar rat-kingdom-message--retry nil
  "The timer for another try at giving workers their messages, or nil.")

;;;; Writing

(defun rat-kingdom-message--sender (from)
  "Return the sender FROM as words: \"the king\" or FROM itself."
  (if (or (null from) (equal from rat-kingdom-king-id))
      "the king"
    from))

(cl-defun rat-kingdom-message-tell (space story text &key from)
  "Leave in SPACE the message TEXT for the worker of STORY, a story id.
FROM says who it is from; the default is \"king\".  The message is a
linear `message' tuple scoped to the story's repository and owned by
the story.  Signal an error if TEXT is blank or STORY is unknown or
finished.  Return the tuple."
  (let ((text (and text (string-trim (format "%s" text))))
        (from (or from rat-kingdom-king-id))
        (token (and story (rat-kingdom-story-get space story))))
    (unless story
      (error "Name the story the message is for"))
    (unless token
      (if (rat-kingdom-space-archived space story)
          (error "%s is finished, so it has no worker to tell" story)
        (error "There is no story called %s" story)))
    (when (string-empty-p (or text ""))
      (error "A message needs some text"))
    (rat-kingdom-space-out space 'message :scope (plist-get token :scope)
                           :owner story
                           :payload (list :to-story story :from from
                                          :text text)
                           :actor from)))

(defun rat-kingdom-message-waiting (space story)
  "Return the messages in SPACE waiting for the worker of STORY, oldest first."
  (rat-kingdom-space-scan space (list 'message :owner story :to-story story)))

;;;; Delivery

(defun rat-kingdom-message--worker (space story)
  "Return the record of the run in SPACE that may be given STORY's messages.
That is the story's current run, while it is working: it has not
reported, and its agent was started in this Emacs.  The king's run
never is.  Return nil if there is none."
  (when-let* ((token (rat-kingdom-story-get space story))
              (payload (plist-get token :payload))
              ((equal (plist-get payload :awaiting) "worker"))
              (id (plist-get payload :run))
              ((not (equal id rat-kingdom-king-id)))
              (run (rat-kingdom-run-get space id))
              ((equal (plist-get run :story) story))
              ((equal (plist-get run :state) "working"))
              ((rat-kingdom-run-live-p id)))
    run))

(defun rat-kingdom-message--prompt (messages)
  "Return MESSAGES, tuples, as one prompt for a worker."
  (mapconcat (lambda (message)
               (let ((payload (plist-get message :payload)))
                 (format "[rat-kingdom] Message from %s:\n%s"
                         (rat-kingdom-message--sender (plist-get payload :from))
                         (plist-get payload :text))))
             messages "\n\n"))

(defun rat-kingdom-message--retract (space messages actor)
  "Remove MESSAGES, tuples, from SPACE in one transaction, as ACTOR."
  (rat-kingdom-space-with-transaction space
    (dolist (message messages)
      (rat-kingdom-space-retract space (list 'message :id (plist-get message :id))
                                 :actor actor))))

(defun rat-kingdom-message--schedule-retry (space)
  "Try again to give workers in SPACE their messages, a while from now."
  (unless (timerp rat-kingdom-message--retry)
    (setq rat-kingdom-message--retry
          (run-at-time rat-kingdom-message-retry-interval nil
                       #'rat-kingdom-message-deliver-all space))))

(defun rat-kingdom-message-deliver (space story)
  "Give the worker of STORY in SPACE its waiting messages, if it can take them.
They go to the story's run only while it is working.  They are given
together, oldest first, as one prompt, and removed only once the agent
has taken it; `rat-kingdom-run-send' refuses while the agent is in a
turn.  An agent in a turn is tried again when the turn ends.  One that
is between turns but did not take the prompt is tried again after
`rat-kingdom-message-retry-interval' seconds.  Return how many were
given."
  (let* ((messages (and (rat-kingdom-space-db space)
                        (rat-kingdom-message-waiting space story)))
         (run (and messages (rat-kingdom-message--worker space story)))
         (id (plist-get run :id)))
    (cond
     ((null run) 0)
     ((rat-kingdom-run-send id (rat-kingdom-message--prompt messages))
      (rat-kingdom-message--retract space messages id)
      (length messages))
     (t
      (unless (rat-kingdom-run-busy-p id)
        (rat-kingdom-message--schedule-retry space))
      0))))

(defun rat-kingdom-message-deliver-all (&optional space)
  "Give every worker in SPACE that can take them its waiting messages.
Return how many were given."
  (let ((space (or space (rat-kingdom-space-default))))
    (when (timerp rat-kingdom-message--retry)
      (cancel-timer rat-kingdom-message--retry))
    (setq rat-kingdom-message--retry nil)
    (if (not (rat-kingdom-space-db space))
        0
      (cl-loop for story in (delete-dups
                             (delq nil
                                   (mapcar (lambda (message)
                                             (plist-get (plist-get message
                                                                   :payload)
                                                        :to-story))
                                           (rat-kingdom-space-scan
                                            space '(message)))))
               sum (rat-kingdom-message-deliver space story)))))

(defun rat-kingdom-message--deliver-soon (space story)
  "Give the worker of STORY in SPACE its messages, if SPACE is still open."
  (when (rat-kingdom-space-db space)
    (rat-kingdom-message-deliver space story)))

;;;; The brief

(defun rat-kingdom-message--entry (message)
  "Return MESSAGE, a tuple, as an entry of a worker's brief."
  (let ((payload (plist-get message :payload)))
    (concat "- "
            (let ((from (plist-get payload :from)))
              (if (or (null from) (equal from rat-kingdom-king-id))
                  ""
                (format "(from %s) " from)))
            (string-replace "\n" "\n  " (plist-get payload :text))
            "\n")))

(defun rat-kingdom-message-brief (space story run-id)
  "Return the section of a worker's brief with the messages for STORY.
SPACE holds them; RUN-ID is the run being started.  The messages stay
in SPACE until that run is working; see `rat-kingdom-message--started'.
Return nil if there are none."
  (if-let* ((messages (rat-kingdom-message-waiting
                       space (plist-get story :identity))))
      (let ((section (concat rat-kingdom-message-brief-heading "\n"
                             (mapconcat #'rat-kingdom-message--entry
                                        messages ""))))
        (puthash run-id
                 (cons (mapcar (lambda (message) (plist-get message :id))
                               messages)
                       section)
                 rat-kingdom-message--briefed)
        section)
    (remhash run-id rat-kingdom-message--briefed)
    nil))

(defun rat-kingdom-message--started (space run)
  "Remove from SPACE the messages given in the brief of RUN, a run tuple.
Only once RUN is working, and only if its prompt still holds them.  A
run that ended in another way leaves them for the next worker."
  (let* ((id (plist-get run :identity))
         (state (plist-get (plist-get run :payload) :state))
         (briefed (gethash id rat-kingdom-message--briefed)))
    (when (and briefed (not (equal state "starting")))
      (remhash id rat-kingdom-message--briefed)
      (when (and (equal state "working")
                 (string-search (cdr briefed)
                                (or (plist-get (plist-get run :payload) :prompt)
                                    "")))
        (rat-kingdom-space-with-transaction space
          (dolist (message (car briefed))
            (rat-kingdom-space-retract space (list 'message :id message)
                                       :actor id)))))))

;;;; Hooks

(defun rat-kingdom-message--on-change (space op subject)
  "Act on a change to SPACE that concerns messages to workers.
A new message is delivered soon if its worker can take it.  A run that
has become working has the messages of its brief removed.  OP and
SUBJECT are as for `rat-kingdom-space-change-functions'."
  (when (eq op 'out)
    (pcase (plist-get subject :category)
      ('message
       (when-let* ((story (plist-get (plist-get subject :payload) :to-story)))
         (run-at-time 0 nil #'rat-kingdom-message--deliver-soon space story)))
      ('run
       (rat-kingdom-message--started space subject)))))

(defun rat-kingdom-message--on-idle (run)
  "Give RUN its story's messages, now that it has ended a turn."
  (let ((space (rat-kingdom-space-default)))
    (when-let* (((rat-kingdom-space-db space))
                (record (rat-kingdom-run-get space run))
                (story (plist-get record :story)))
      (rat-kingdom-message-deliver space story))))

(add-hook 'rat-kingdom-space-change-functions #'rat-kingdom-message--on-change)
(add-hook 'rat-kingdom-run-idle-functions #'rat-kingdom-message--on-idle)
(add-hook 'rat-kingdom-story-brief-functions #'rat-kingdom-message-brief t)

;;;; What the king sees

(defun rat-kingdom-message-note (space story style)
  "Return what the king is shown of the messages waiting for STORY, a token.
SPACE holds them.  STYLE is `status', for a few words on the story's
line, or `show', for a count and the sender and first line of each.
Return nil if none is waiting."
  (when-let* ((messages (rat-kingdom-message-waiting
                         space (plist-get story :identity))))
    (let ((count (length messages)))
      (pcase style
        ('status (format "%d %s waiting" count
                         (if (= count 1) "message" "messages")))
        (_ (concat
            (format "Messages waiting for its worker: %d" count)
            (mapconcat
             (lambda (message)
               (let ((payload (plist-get message :payload)))
                 (format "\n- from %s: %s"
                         (rat-kingdom-message--sender (plist-get payload :from))
                         (car (split-string (plist-get payload :text) "\n")))))
             messages "")))))))

(add-hook 'rat-kingdom-king-story-note-functions #'rat-kingdom-message-note)

;;;; The king's tell

(defun rat-kingdom-message--told (space story tuple)
  "Return what `tell' answers after leaving TUPLE for STORY in SPACE.
The answer says truthfully where the message is and when it will be
read."
  (let* ((token (rat-kingdom-story-get space story))
         (payload (plist-get token :payload))
         (place (plist-get payload :at))
         (awaiting (plist-get payload :awaiting))
         (run-id (plist-get payload :run))
         (run (and run-id (rat-kingdom-run-get space run-id)))
         (state (plist-get run :state))
         (next "It will be given to the story's next worker, in its brief")
         (unread "If the story is merged without going back to a worker, \
the message will not be read."))
    (cond
     ((not (rat-kingdom-space-rd space (list 'message
                                             :id (plist-get tuple :id))))
      (format "Delivered now to worker %s." run-id))
     ((rat-kingdom-message--worker space story)
      (format "Worker %s is %s, so the message waits. It is given to the \
worker when its current turn ends; the worker can also read it sooner with \
inbox."
              run-id
              (if (rat-kingdom-run-busy-p run-id)
                  "in the middle of a turn"
                "not taking prompts just now")))
     ((and (equal awaiting "worker") (equal state "starting"))
      (format "Worker %s is starting, so the message waits. It is given to \
the worker when its first turn ends; the worker can also read it sooner with \
inbox."
              run-id))
     ((and (equal awaiting "worker")
           (member state '("interrupted" "working")))
      ;; Working, but with no agent in this Emacs: Emacs was restarted
      ;; and the run is about to be found interrupted.
      (format "%s's worker %s was cut off by a restart. %s, when it is \
replaced."
              story run-id next))
     ((equal awaiting "worker")
      (format "%s's worker %s has already %s, so it will not be given the \
message. %s, if it gets one. %s"
              story run-id
              (pcase state
                ("ready" "reported that it is done")
                ("blocked" "reported that it is blocked")
                (_ (format "ended (%s)" (or state "its record is gone"))))
              next unread))
     ((equal awaiting rat-kingdom-story-free-worker)
      (format "%s has no worker right now: it is at %s, waiting for a free \
worker. %s, when it starts."
              story place next))
     ((equal awaiting "setup")
      (format "%s has no worker right now: its worktree is being set up for \
one. %s, when it starts."
              story next))
     ((member awaiting '("check" "review"))
      (format "%s has no worker right now: it is at %s, waiting for %s. %s, \
if it goes back to one. %s"
              story place
              (if (equal awaiting "check") "its check" "a review")
              next unread))
     ((equal (plist-get payload :phase) "parked")
      (format "%s has no worker right now: it is stopped at %s. %s, when \
it is moved to a place that starts one."
              story place next))
     (t
      (format "%s has no worker right now: it is at %s. %s, if it gets \
one. %s"
              story place next unread)))))

(rat-kingdom-king--deftool "tell"
    "Send a message to the worker of a story in progress: a correction, \
more detail, or a change of plan. A worker that is between turns gets it at \
once; one in the middle of a turn gets it when the turn ends, and can read it \
sooner with its inbox tool. A story with no worker right now keeps it for its \
next worker. The answer says which happened. A worker that has reported is \
never told."
    '((:name "story" :type string :description "The story's id, like S-1a2b.")
      (:name "text" :type string
       :description "The message, written so that the worker can act on it."))
  (let* ((story (arg 'story))
         (tuple (rat-kingdom-message-tell space story (arg 'text))))
    (rat-kingdom-message-deliver space story)
    (rat-kingdom-message--told space story tuple)))

;;;; The worker's inbox

(defun rat-kingdom-message--inbox (context _arguments)
  "Return and remove the messages for the story of the run CONTEXT names."
  (pcase-let* ((`(,space ,run) (rat-kingdom-run--calling context))
               (story (plist-get run :story)))
    (unless (and story
                 (equal (plist-get (rat-kingdom-message--worker space story)
                                   :id)
                        (plist-get run :id)))
      (error "You are not this task's working worker, or you have already \
reported; its messages are kept for its next worker"))
    (if-let* ((messages (rat-kingdom-message-waiting space story)))
        (prog1 (concat "Messages for your task, oldest first:\n\n"
                       (mapconcat
                        (lambda (message)
                          (let ((payload (plist-get message :payload)))
                            (format "From %s:\n%s"
                                    (rat-kingdom-message--sender
                                     (plist-get payload :from))
                                    (plist-get payload :text))))
                        messages "\n\n"))
          (rat-kingdom-message--retract space messages (plist-get run :id)))
      "No messages.")))

(rat-kingdom-mcp-define-tool
 "inbox"
 :description "Read the messages the king has sent about your task since you \
started, oldest first. Each is removed once read. Messages also arrive by \
themselves between your turns; during a long turn, check here now and then, \
and always before you call finish."
 :roles '(rat)
 :args nil
 :function #'rat-kingdom-message--inbox)

(provide 'rat-kingdom-message)
;;; rat-kingdom-message.el ends here
