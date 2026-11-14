;;; rat-kingdom-message-test.el --- Tests for messages to workers -*- lexical-binding: t; -*-

;;; Commentary:

;; Batch tests for the king's `tell', delivery to a worker between
;; turns, the worker's `inbox', and messages in a new worker's brief.
;; They use the fixture of rat-kingdom-story-test.el: real Git, a
;; backend that starts no agent and records what it is asked to send,
;; and tools called over JSON-RPC.

;;; Code:

(require 'ert)
(require 'rat-kingdom)
(require 'rat-kingdom-message)
(require 'rat-kingdom-story-test)
(require 'rat-kingdom-king-test)
(require 'rat-kingdom-reload-test)

(defmacro rat-kingdom-message-test-with-repo (vars &rest body)
  "Run BODY as `rat-kingdom-story-test-with-repo' does, with VARS.
Messages are watched for, as they are when the package is loaded, and
the fake backend says an agent is busy while
`rat-kingdom-story-test--busy' is non-nil."
  (declare (indent 1) (debug t))
  `(rat-kingdom-story-test-with-repo ,vars
     (let ((rat-kingdom-message--briefed (make-hash-table :test #'equal))
           (rat-kingdom-message--retry nil))
       (add-hook 'rat-kingdom-space-change-functions
                 #'rat-kingdom-message--on-change)
       (rat-kingdom-king-test--tell-busy)
       (unwind-protect
           (progn ,@body)
         (when (timerp rat-kingdom-message--retry)
           (cancel-timer rat-kingdom-message--retry))))))

(defun rat-kingdom-message-test--start (space id &rest more)
  "Start the story ID in SPACE, and its worker.  MORE is passed on."
  (apply #'rat-kingdom-story-start space "demo" (format "Task %s" id)
         "Do it." id more)
  (rat-kingdom-reaction-run space))

(defun rat-kingdom-message-test--tell (story text)
  "Call tell as the king for STORY with TEXT.  Return (TEXT . FAILED)."
  (rat-kingdom-king-test--call "tell" (cons 'story story) (cons 'text text)))

(defun rat-kingdom-message-test--texts (space story)
  "Return the texts of the messages waiting for STORY in SPACE."
  (mapcar (lambda (message) (plist-get (plist-get message :payload) :text))
          (rat-kingdom-message-waiting space story)))

(defun rat-kingdom-message-test--sent-to (run)
  "Return the texts the fake backend sent RUN, oldest first."
  (mapcar #'cdr (reverse (cl-remove-if-not
                          (lambda (sent) (equal (car sent) run))
                          rat-kingdom-story-test--sent))))

(defun rat-kingdom-message-test--idle (run)
  "Say that RUN has ended a turn, as a backend does."
  (run-hook-with-args 'rat-kingdom-run-idle-functions run))

;;;; Delivery

(ert-deftest rat-kingdom-message-test-tell-an-idle-worker ()
  (rat-kingdom-message-test-with-repo (space _path)
    (rat-kingdom-king-test--start space)
    (rat-kingdom-message-test--start space "S-1")
    (let ((answer (rat-kingdom-message-test--tell "S-1" "  Use tabs.  ")))
      (should-not (cdr answer))
      (should (equal (car answer) "Delivered now to worker S-1.1.")))
    (should (equal (rat-kingdom-message-test--sent-to "S-1.1")
                   '("[rat-kingdom] Message from the king:\nUse tabs.")))
    (should-not (rat-kingdom-message-waiting space "S-1"))
    (should-not (rat-kingdom-space-scan space '(message)))
    ;; The king is never given a worker's message.
    (should-not (rat-kingdom-message-test--sent-to "king"))
    ;; What was written, before it was taken.
    (let ((op (car (sqlite-select
                    (rat-kingdom-space-db space)
                    "SELECT scope, payload, actor FROM ops
                     WHERE category = 'message' AND op = 'out'"))))
      (should (equal (nth 0 op) "demo"))
      (should (string-search "\"to-story\":\"S-1\"" (nth 1 op)))
      (should (string-search "\"from\":\"king\"" (nth 1 op)))
      (should (equal (nth 2 op) "king")))))

(ert-deftest rat-kingdom-message-test-tell-a-busy-worker ()
  (rat-kingdom-message-test-with-repo (space _path)
    (rat-kingdom-king-test--start space)
    (rat-kingdom-message-test--start space "S-1")
    (setq rat-kingdom-story-test--busy t)
    (dolist (text '("First." "Second."))
      (let ((answer (rat-kingdom-message-test--tell "S-1" text)))
        (should-not (cdr answer))
        (should (string-search "Worker S-1.1 is in the middle of a turn"
                               (car answer)))
        (should (string-search "when its current turn ends" (car answer)))
        (should (string-search "inbox" (car answer)))))
    (should-not rat-kingdom-story-test--sent)
    (should (equal (rat-kingdom-message-test--texts space "S-1")
                   '("First." "Second.")))
    ;; Still busy when its turn ends: nothing is given.
    (rat-kingdom-message-test--idle "S-1.1")
    (should-not rat-kingdom-story-test--sent)
    (setq rat-kingdom-story-test--busy nil)
    ;; Another run's turn is not this one's.
    (rat-kingdom-message-test--idle "king")
    (should-not (rat-kingdom-message-test--sent-to "S-1.1"))
    ;; When its turn ends it gets both, oldest first, in one prompt.
    (rat-kingdom-message-test--idle "S-1.1")
    (should (equal (rat-kingdom-message-test--sent-to "S-1.1")
                   '("[rat-kingdom] Message from the king:\nFirst.\n\n\
[rat-kingdom] Message from the king:\nSecond.")))
    (should-not (rat-kingdom-message-waiting space "S-1"))
    ;; And only once.
    (rat-kingdom-message-test--idle "S-1.1")
    (should (eql (length (rat-kingdom-message-test--sent-to "S-1.1")) 1))
    ;; Another sender is named as such.
    (rat-kingdom-message-tell space "S-1" "From below." :from "foreman")
    (rat-kingdom-message-deliver space "S-1")
    (should (equal (car (last (rat-kingdom-message-test--sent-to "S-1.1")))
                   "[rat-kingdom] Message from foreman:\nFrom below."))))

(ert-deftest rat-kingdom-message-test-a-failed-send-keeps-the-message ()
  (rat-kingdom-message-test-with-repo (space _path)
    (rat-kingdom-king-test--start space)
    (rat-kingdom-message-test--start space "S-1")
    (let ((send (plist-get rat-kingdom-run-backend :send)))
      (setq rat-kingdom-run-backend
            (append (list :send (lambda (_handle _text) nil))
                    rat-kingdom-run-backend))
      (let ((answer (rat-kingdom-message-test--tell "S-1" "Keep me.")))
        (should-not (cdr answer))
        (should (string-search "not taking prompts just now" (car answer))))
      (should (equal (rat-kingdom-message-test--texts space "S-1")
                     '("Keep me.")))
      (should (timerp rat-kingdom-message--retry))
      (rat-kingdom-message-test--idle "S-1.1")
      (should (equal (rat-kingdom-message-test--texts space "S-1")
                     '("Keep me.")))
      ;; Once the agent takes a prompt, the retry gives it the message.
      (setq rat-kingdom-run-backend
            (append (list :send send) rat-kingdom-run-backend))
      (should (eql (rat-kingdom-message-deliver-all space) 1))
      (should-not rat-kingdom-message--retry)
      (should-not (rat-kingdom-message-waiting space "S-1"))
      (should (equal (rat-kingdom-message-test--sent-to "S-1.1")
                     '("[rat-kingdom] Message from the king:\nKeep me."))))))

(ert-deftest rat-kingdom-message-test-a-reported-worker-is-not-told ()
  (rat-kingdom-message-test-with-repo (space path)
    (rat-kingdom-repo-add space path :check '("sh" "-c" "test -f wanted.txt"))
    (rat-kingdom-king-test--start space)
    (rat-kingdom-message-test--start space "S-1")
    (rat-kingdom-story-test--work space "S-1" "other.txt")
    (should (equal (plist-get (rat-kingdom-run-get space "S-1.1") :state)
                   "ready"))
    ;; The worker has reported but the story has not moved on yet.
    (let ((answer (car (rat-kingdom-message-test--tell
                        "S-1" "Name it wanted.txt."))))
      (should (string-search "S-1.1 has already reported that it is done"
                             answer))
      (should (string-search "will not be given" answer))
      (should (string-search "next worker, in its brief" answer))
      (should (string-search "will not be read" answer)))
    (rat-kingdom-message-test--idle "S-1.1")
    (rat-kingdom-message-deliver-all space)
    (should-not (rat-kingdom-message-test--sent-to "S-1.1"))
    ;; Its inbox is closed too.
    (should (cdr (rat-kingdom-story-test--call "S-1.1" "inbox")))
    ;; At the check, there is no worker.
    (rat-kingdom-reaction-run space)
    (should (equal (rat-kingdom-story-test--get space "S-1" :awaiting)
                   "check"))
    (let ((answer (car (rat-kingdom-message-test--tell
                        "S-1" "And commit it."))))
      (should (string-search "S-1 has no worker right now" answer))
      (should (string-search "waiting for its check" answer))
      (should (string-search "will not be read" answer)))
    (should (equal (rat-kingdom-message-test--texts space "S-1")
                   '("Name it wanted.txt." "And commit it.")))
    ;; The check fails; the next worker has both in its brief.
    (rat-kingdom-story-test--settle space "S-1")
    (should (equal (rat-kingdom-story-test--get space "S-1" :run) "S-1.2"))
    (let ((prompt (rat-kingdom-story-test--prompt "S-1.2")))
      (should (string-search
               "Messages for this task from the king (oldest first):
- Name it wanted.txt.
- And commit it.\n"
               prompt))
      (should (string-search "check failed" prompt)))
    ;; Once that worker is running they are gone, and not sent again.
    (should (equal (plist-get (rat-kingdom-run-get space "S-1.2") :state)
                   "working"))
    (should-not (rat-kingdom-message-waiting space "S-1"))
    (should (zerop (hash-table-count rat-kingdom-message--briefed)))
    (rat-kingdom-message-test--idle "S-1.2")
    (should-not (rat-kingdom-message-test--sent-to "S-1.2"))
    (should-not (rat-kingdom-message-test--sent-to "S-1.1"))))

(ert-deftest rat-kingdom-message-test-a-run-that-fails-to-start-keeps-them ()
  (rat-kingdom-message-test-with-repo (space _path)
    (rat-kingdom-story-start space "demo" "Task S-1" "Do it." "S-1")
    (rat-kingdom-message-tell space "S-1" "Before you start.")
    (should (equal (rat-kingdom-message--told
                    space "S-1" (car (rat-kingdom-message-waiting space "S-1")))
                   "S-1 has no worker right now: it is at ready. It will be \
given to the story's next worker, in its brief, if it gets one. If the story \
is merged without going back to a worker, the message will not be read."))
    (let ((start (plist-get rat-kingdom-run-backend :start)))
      (setq rat-kingdom-run-backend
            (append (list :start (lambda (_run _prompt) (error "No agent")))
                    rat-kingdom-run-backend))
      (rat-kingdom-reaction-run space)
      (should (equal (plist-get (rat-kingdom-run-get space "S-1.1") :state)
                     "exited"))
      (should (string-search "Before you start."
                             (plist-get (rat-kingdom-run-get space "S-1.1")
                                        :prompt)))
      (should (equal (rat-kingdom-message-test--texts space "S-1")
                     '("Before you start.")))
      (should (zerop (hash-table-count rat-kingdom-message--briefed)))
      (should (equal (rat-kingdom-story-test--get space "S-1" :phase)
                     "parked"))
      (should (string-search
               "stopped at blocked"
               (rat-kingdom-message--told
                space "S-1" (car (rat-kingdom-message-waiting space "S-1")))))
      ;; Moved, the story's next worker has it, and then it is gone.
      (setq rat-kingdom-run-backend
            (append (list :start start) rat-kingdom-run-backend))
      (rat-kingdom-story-move space "S-1" "ready")
      (rat-kingdom-reaction-run space)
      (should (string-search "- Before you start."
                             (rat-kingdom-story-test--prompt "S-1.2")))
      (should-not (rat-kingdom-message-waiting space "S-1")))))

;;;; The inbox

(ert-deftest rat-kingdom-message-test-inbox ()
  (rat-kingdom-message-test-with-repo (space _path)
    (rat-kingdom-king-test--start space)
    (rat-kingdom-message-test--start space "S-1")
    (rat-kingdom-message-test--start space "S-2")
    (should (equal (rat-kingdom-story-test--call "S-1.1" "inbox")
                   '("No messages." . nil)))
    (setq rat-kingdom-story-test--busy t)
    (rat-kingdom-message-test--tell "S-1" "First.\nWith a second line.")
    (rat-kingdom-message-tell space "S-1" "Second." :from "foreman")
    (rat-kingdom-message-test--tell "S-2" "Not yours.")
    (let ((answer (rat-kingdom-story-test--call "S-1.1" "inbox")))
      (should-not (cdr answer))
      (should (equal (car answer)
                     "Messages for your task, oldest first:

From the king:
First.
With a second line.

From foreman:
Second.")))
    (should-not (rat-kingdom-message-waiting space "S-1"))
    (should (equal (rat-kingdom-story-test--call "S-1.1" "inbox")
                   '("No messages." . nil)))
    ;; Read, they are not given again when the turn ends.
    (setq rat-kingdom-story-test--busy nil)
    (rat-kingdom-message-test--idle "S-1.1")
    (should-not (rat-kingdom-message-test--sent-to "S-1.1"))
    ;; Another story's are its own.
    (should (equal (rat-kingdom-message-test--texts space "S-2")
                   '("Not yours.")))))

;;;; Errors

(ert-deftest rat-kingdom-message-test-what-cannot-be-told ()
  (rat-kingdom-message-test-with-repo (space _path)
    (rat-kingdom-king-test--start space)
    (rat-kingdom-message-test--start space "S-1")
    (should-error (rat-kingdom-message-tell space "S-404" "Hello."))
    (should-error (rat-kingdom-message-tell space nil "Hello."))
    (should-error (rat-kingdom-message-tell space "S-1" ""))
    (should-error (rat-kingdom-message-tell space "S-1" " \n "))
    (should-error (rat-kingdom-message-tell space "S-1" nil))
    (let ((answer (rat-kingdom-message-test--tell "S-404" "Hello.")))
      (should (cdr answer))
      (should (string-search "no story called S-404" (car answer))))
    (should (cdr (rat-kingdom-message-test--tell "S-1" "  ")))
    (should-not (rat-kingdom-space-scan space '(message)))
    ;; A finished story has no worker to tell.
    (rat-kingdom-story-test--work space "S-1" "feature.txt")
    (rat-kingdom-story-test--settle space "S-1")
    (should-not (rat-kingdom-story-get space "S-1"))
    (let ((answer (rat-kingdom-message-test--tell "S-1" "Too late.")))
      (should (cdr answer))
      (should (string-search "S-1 is finished" (car answer))))
    (should-not (cl-remove-if-not
                 (lambda (message)
                   (plist-get (plist-get message :payload) :to-story))
                 (rat-kingdom-space-scan space '(message))))))

;;;; What the king sees

(ert-deftest rat-kingdom-message-test-status-and-story-show ()
  (rat-kingdom-message-test-with-repo (space _path)
    (rat-kingdom-king-test--start space)
    (rat-kingdom-message-test--start space "S-1")
    (rat-kingdom-message-test--start space "S-2")
    (should-not (string-search "waiting:"
                               (rat-kingdom-king-test--ok "story_show"
                                                          '(story . "S-1"))))
    (should-not (string-search "message" (rat-kingdom-king-test--ok "status")))
    (setq rat-kingdom-story-test--busy t)
    (rat-kingdom-message-test--tell "S-1" "Use tabs.\nNot spaces.")
    (rat-kingdom-message-tell space "S-1" "Hurry." :from "foreman")
    (rat-kingdom-message-test--tell "S-2" "Only one.")
    (let ((status (rat-kingdom-king-test--ok "status")))
      (should (string-match-p
               "^- S-1 \\[demo\\] ready (waiting for worker S-1\\.1, working), \
[^,]+, claude, 2 messages waiting: Task S-1$"
               status))
      (should (string-search ", claude, 1 message waiting: Task S-2" status)))
    (let ((show (rat-kingdom-king-test--ok "story_show" '(story . "S-1"))))
      (should (string-search "Messages waiting for its worker: 2
- from the king: Use tabs.
- from foreman: Hurry."
                             show))
      (should-not (string-search "Not spaces." show)))))

;;;; Recovery

(ert-deftest rat-kingdom-message-test-a-replacement-worker-gets-them ()
  (rat-kingdom-message-test-with-repo (space _path)
    (rat-kingdom-message-test--start space "S-1")
    (setq rat-kingdom-story-test--busy t)
    (rat-kingdom-message-tell space "S-1" "Mind the tests.")
    (rat-kingdom-message-deliver space "S-1")
    (should-not rat-kingdom-story-test--sent)
    ;; Emacs stops with the worker in a turn and starts again.
    (let ((file (expand-file-name "space.db" rat-kingdom-directory)))
      (rat-kingdom-space-close space)
      (setq space (rat-kingdom-space-open file)
            rat-kingdom-space--default space)
      (clrhash rat-kingdom-run--handles)
      (clrhash rat-kingdom-mcp--grants)
      (clrhash rat-kingdom-message--briefed))
    (should (equal (rat-kingdom-message-test--texts space "S-1")
                   '("Mind the tests.")))
    (should (equal (plist-get (rat-kingdom-story-reconcile space) :runs)
                   '("S-1.1")))
    (rat-kingdom-reaction-run space)
    (should (equal (rat-kingdom-story-test--get space "S-1" :run) "S-1.2"))
    (let ((prompt (rat-kingdom-story-test--prompt "S-1.2")))
      (should (string-search "cut off when Emacs stopped" prompt))
      (should (string-search "Messages for this task from the king \
(oldest first):\n- Mind the tests.\n"
                             prompt)))
    (should-not (rat-kingdom-message-waiting space "S-1"))
    (should-not rat-kingdom-story-test--sent)))

;;;; Roles and reloading

(ert-deftest rat-kingdom-message-test-tools-by-role ()
  (let ((names (lambda (role)
                 (mapcar (lambda (tool) (plist-get tool :name))
                         (rat-kingdom-mcp-tool-list role)))))
    (should (member "inbox" (funcall names 'rat)))
    (should-not (member "tell" (funcall names 'rat)))
    (should (member "tell" (funcall names 'king)))
    (should-not (member "inbox" (funcall names 'king))))
  (rat-kingdom-message-test-with-repo (space _path)
    (rat-kingdom-king-test--start space)
    (rat-kingdom-message-test--start space "S-1")
    (let ((answer (rat-kingdom-story-test--call
                   "S-1.1" "tell" '(story . "S-1") '(text . "Hi."))))
      (should (cdr answer))
      (should (string-search "unknown tool" (car answer))))
    (let ((answer (rat-kingdom-king-test--call "inbox")))
      (should (cdr answer))
      (should (string-search "unknown tool" (car answer))))
    (should-not (rat-kingdom-space-scan space '(message)))))

(ert-deftest rat-kingdom-message-test-reload-keeps-one-of-each-hook ()
  (rat-kingdom-reload-test--isolated
    (let ((rat-kingdom-story-brief-functions
           (copy-sequence rat-kingdom-story-brief-functions))
          (rat-kingdom-king-story-note-functions
           (copy-sequence rat-kingdom-king-story-note-functions)))
      (rat-kingdom-reload)
      (rat-kingdom-reload)
      (dolist (entry '((rat-kingdom-story-brief-functions
                        . rat-kingdom-message-brief)
                       (rat-kingdom-king-story-note-functions
                        . rat-kingdom-message-note)
                       (rat-kingdom-space-change-functions
                        . rat-kingdom-message--on-change)
                       (rat-kingdom-run-idle-functions
                        . rat-kingdom-message--on-idle)))
        (should (eql (cl-count (cdr entry) (symbol-value (car entry))) 1)))
      (should (equal rat-kingdom-story-brief-functions
                     '(rat-kingdom-fact-brief rat-kingdom-message-brief)))
      (should (eql (cl-count "tell" (rat-kingdom-mcp--tools-for 'king)
                             :key (lambda (tool) (plist-get tool :name))
                             :test #'equal)
                   1))
      (should (eql (cl-count "inbox" rat-kingdom-mcp--tools
                             :key (lambda (tool) (plist-get tool :name))
                             :test #'equal)
                   1)))))

(provide 'rat-kingdom-message-test)
;;; rat-kingdom-message-test.el ends here
