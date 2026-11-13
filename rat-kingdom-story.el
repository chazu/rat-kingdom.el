;;; rat-kingdom-story.el --- Moving stories through workflows -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Chaz Straney

;; Author: Chaz Straney <chaz.straney@gmail.com>
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A story is one piece of work.  Its state is a single `story' tuple,
;; the token.  The token names its workflow (rat-kingdom-workflow.el)
;; and says where the story is:
;;
;;   :at      the place it is at
;;   :phase   enter    it has just arrived and its step is not yet begun
;;            wait     its step is in progress; `:step' names it and
;;                     `:awaiting' says for what: worker, setup, check or
;;                     review, or "a free worker" while it is queued
;;            parked   no step is taken from here; it waits to be moved
;;
;; The reactions here are the workflow engine.  One begins the step of
;; a token that has arrived.  The others each join a waiting token with
;; the tuple that ends its step: a worker's `result' or `blocked', a
;; `checked', a `verdict', or a run that ended without reporting.
;;
;; A step that cannot be begun sends the token to the workflow's failure
;; place with the reason, so an error leaves a story parked and visible
;; and never half moved.  `rat-kingdom-story-move' puts any token at any
;; place by hand.  `rat-kingdom-story-watch' reports as `stuck' a story
;; that has waited longer than its step allows.
;;
;; Merging follows rk2.  The worker's commit is merged in a detached
;; candidate worktree, the repository's check runs there, and only then
;; is the target branch moved, and only if it has not moved meanwhile.
;; If it has, the story is checked again.  Nothing is pushed.
;;
;; A repository may have a setup command, such as "npm ci", that its
;; worktrees need before anything can be built or tested.  It runs in a
;; worker's worktree when that is made, before the worker starts, and in
;; every candidate before the check.  Its outcome in a worker's worktree
;; is recorded as a `setup' tuple, which moves the story on as `checked'
;; does; in a candidate, a setup that fails fails the check.
;;
;; At most `rat-kingdom-story-max-workers' workers run at once.  A story
;; whose worker would go over that waits for a free worker, and the
;; queue is served oldest first whenever a worker's run leaves the
;; running states, a story is archived, the watchdog looks, or Emacs
;; reconciles.
;;
;; `rat-kingdom-story-reconcile' is the recovery after Emacs stopped
;; with work in flight (DESIGN.md, section 8.4): a worker that was cut
;; off is replaced by a new one in the same worktree, and a check that
;; was running is run again.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'rat-kingdom-space)
(require 'rat-kingdom-reaction)
(require 'rat-kingdom-git)
(require 'rat-kingdom-run)
(require 'rat-kingdom-workflow)
(require 'rat-kingdom-task)

(defcustom rat-kingdom-story-default-workflow "story"
  "The workflow of a story whose repository names none."
  :type 'string
  :group 'rat-kingdom)

(defcustom rat-kingdom-story-attempts 5
  "How many workers one story may be given before it is stopped.
A step's `:attempts' overrides this.  Moving a story by hand starts
the count again."
  :type 'integer
  :group 'rat-kingdom)

(defcustom rat-kingdom-story-timeouts '((:spawn . 7200) (:check . 1800))
  "Seconds a step of each kind may take before its story is called stuck.
A step's `:timeout' overrides this.  A kind left out has no limit.
A repository's setup in a worker's worktree may take as long as a
`:check'; in a candidate it is part of the check, and shares its time."
  :type '(alist :key-type symbol :value-type number)
  :group 'rat-kingdom)

(defcustom rat-kingdom-story-max-workers 3
  "Most workers that may run at once, or nil for no limit.
A worker counts while its run is `starting' or `working', that is from
when it is recorded until it reports, ends or is stopped.  A run that
is `ready' or `blocked' has reported, and its agent sits idle until its
story moves on; one that is `interrupted' has no agent in this Emacs.
Only runs that belong to a story count, so the king does not.  A story
whose worker would go over the limit waits for a free worker, and is
given one, oldest first, as workers end."
  :type '(choice (const :tag "No limit" nil) integer)
  :group 'rat-kingdom)

(defconst rat-kingdom-story-free-worker "a free worker"
  "What a story queued for a worker is `:awaiting'.")

(defcustom rat-kingdom-story-watch-interval 60
  "Seconds between looks for stuck stories while `rat-kingdom-mode' is on."
  :type 'number
  :group 'rat-kingdom)

(defconst rat-kingdom-story-output-limit 4000
  "Most characters of a check's or a setup's output that are kept.")

(defvar rat-kingdom-story-event-functions nil
  "Functions called when something a person should know happens to a story.
Each is called with the space, the event and the story's token.  The
events are `done' (merged and about to be archived), `parked' (stopped
until someone moves it; its `:reason' says why), `review' (it waits for
a verdict) and `stuck'.  They are called inside the transaction that
made the change.")

(add-hook 'rat-kingdom-story-event-functions #'rat-kingdom-story--announce t)
(add-hook 'rat-kingdom-story-event-functions #'rat-kingdom-task-story-event t)

(defvar rat-kingdom-story--actor "engine"
  "Who is recorded as moving tokens.")

(defvar rat-kingdom-story--checks (make-hash-table :test #'equal)
  "Hash table from story id to the process running its check or setup.
A story runs at most one at a time: its setup in a new worktree, or in
a candidate its setup and then its check.")

;;;; Tokens

(defun rat-kingdom-story-get (space id)
  "Return the token of the story ID in SPACE, or nil."
  (rat-kingdom-space-rd space (list 'story :identity id)))

(defun rat-kingdom-story-list (space &optional repo)
  "Return the tokens of the stories in SPACE, or only those in REPO."
  (rat-kingdom-space-scan space (if repo (list 'story :scope repo) '(story))))

(defun rat-kingdom-story--workflow (story)
  "Return the workflow of the token STORY, or nil if it is not defined."
  (rat-kingdom-workflow-get (plist-get (plist-get story :payload) :workflow)))

(defun rat-kingdom-story--repo (space story)
  "Return the record of the repository of the token STORY in SPACE."
  (or (rat-kingdom-repo-get space (plist-get story :scope))
      (error "Repository %s is no longer registered" (plist-get story :scope))))

(defun rat-kingdom-story--title (story)
  "Return the token STORY's id and title as one phrase."
  (format "%s (%s)" (plist-get story :identity)
          (plist-get (plist-get story :payload) :title)))

(defun rat-kingdom-story--announce (_space event story)
  "Say in the echo area that EVENT happened to the token STORY."
  (let ((payload (plist-get story :payload)))
    (message "rat-kingdom: %s %s"
             (rat-kingdom-story--title story)
             (pcase event
               ('done (if (plist-get payload :integrated)
                          "is merged"
                        "is over"))
               ('parked (format "is stopped at %s: %s" (plist-get payload :at)
                                (or (plist-get payload :reason) "no reason given")))
               ('review "waits for a review")
               ('stuck "looks stuck")
               (_ (format "%s" event))))))

(defun rat-kingdom-story--event (space event story)
  "Tell `rat-kingdom-story-event-functions' that EVENT happened to STORY in SPACE."
  (dolist (function rat-kingdom-story-event-functions)
    (with-demoted-errors "rat-kingdom: story event function: %S"
      (funcall function space event story))))

(defun rat-kingdom-story--put (space story &rest changes)
  "Write the token STORY, which has been taken, back to SPACE.
CHANGES is a property list merged into its payload.  The time is
recorded and any report that the story is stuck is withdrawn.  Return
the new token."
  (let ((payload (copy-sequence (plist-get story :payload))))
    (while changes
      (setq payload (plist-put payload (pop changes) (pop changes))))
    (setq payload (plist-put payload :entered
                             (funcall rat-kingdom-space-now-function)))
    (rat-kingdom-space-retract
     space (list 'stuck :scope (plist-get story :scope)
                 :identity (plist-get story :identity))
     :actor rat-kingdom-story--actor)
    (rat-kingdom-space-out space 'story :scope (plist-get story :scope)
                           :identity (plist-get story :identity)
                           :owner (plist-get story :owner)
                           :payload payload :actor rat-kingdom-story--actor)))

(defun rat-kingdom-story--goto (space story place &rest changes)
  "Put the taken token STORY at PLACE in SPACE, its step there not begun.
CHANGES is merged into its payload.  The reason it carried is dropped
unless CHANGES gives a new one."
  (apply #'rat-kingdom-story--put space story
         :at place :phase "enter" :step nil :awaiting nil
         (if (plist-member changes :reason)
             changes
           (append (list :reason nil) changes))))

(defun rat-kingdom-story--wait (space story step awaiting &rest changes)
  "Put the taken token STORY back in SPACE, waiting in STEP for AWAITING.
CHANGES is merged into its payload."
  (apply #'rat-kingdom-story--put space story
         :phase "wait" :step (plist-get step :name) :awaiting awaiting
         changes))

(defun rat-kingdom-story--fail (space story reason)
  "Send the taken token STORY in SPACE to its failure place, with REASON."
  (let* ((workflow (rat-kingdom-story--workflow story))
         (failure (and workflow (plist-get workflow :failure))))
    (if (or (null failure)
            (equal failure (plist-get (plist-get story :payload) :at)))
        (rat-kingdom-story--event
         space 'parked
         (rat-kingdom-story--put space story :phase "parked" :step nil
                                 :awaiting nil :reason reason))
      (rat-kingdom-story--goto space story failure :reason reason))))

;;;; Starting a story

(defun rat-kingdom-story--new-id (space)
  "Return a story id not in use in SPACE."
  (let (id)
    (while (or (null id)
               (rat-kingdom-space-rd space (list 'story :identity id))
               (rat-kingdom-space-archived space id))
      (setq id (format "S-%04x" (random 65536))))
    id))

(defun rat-kingdom-story-start (space repo title &optional description id
                                      workflow task)
  "Start a story in SPACE for the repository REPO and return its id.
TITLE says what to do in a line; DESCRIPTION gives the acceptance
criteria.  ID names the story; one is made up if it is nil.  WORKFLOW
names its workflow; by default the repository's, and failing that
`rat-kingdom-story-default-workflow'.  TASK, if given, is the id of
the tracker's task the story works on: its `available' tuple is taken
and the task is claimed for the story."
  (let ((record (or (rat-kingdom-repo-get space repo)
                    (error "No repository called %s is registered" repo)))
        (id (or id (rat-kingdom-story--new-id space))))
    (when (rat-kingdom-space-rd space (list 'story :identity id))
      (error "There is already a story called %s" id))
    (let* ((name (rat-kingdom-workflow--name
                  (or workflow (plist-get record :workflow)
                      rat-kingdom-story-default-workflow)))
           (workflow (or (rat-kingdom-workflow-get name)
                         (error "There is no workflow called %s; there are: %s"
                                name
                                (mapconcat (lambda (workflow)
                                             (plist-get workflow :name))
                                           (rat-kingdom-workflow-list) ", ")))))
      (rat-kingdom-space-with-transaction space
        (when task
          (rat-kingdom-space-in space (list 'available :scope repo :identity task)
                                :actor "user"))
        (rat-kingdom-space-out
         space 'story :scope repo :identity id :owner id
         :payload (append
                   (list :workflow name :at (plist-get workflow :start)
                         :phase "enter" :title title :description description
                         :attempt 0
                         :entered (funcall rat-kingdom-space-now-function))
                   (and task (list :task task)))
         :actor "user"))
      (when task
        (rat-kingdom-task-claim-for-story space repo task id))
      id)))

(defun rat-kingdom-story-warnings (space repo)
  "Return what a person starting a story in REPO in SPACE should know.
The result is a list of strings: that the checkout has changes a worker
will not see, or commits the target branch lacks."
  (let* ((record (or (rat-kingdom-repo-get space repo)
                     (error "No repository called %s is registered" repo)))
         (path (plist-get record :path))
         (target (plist-get record :target))
         warnings)
    (unless (string-empty-p (rat-kingdom-git path "status" "--porcelain"))
      (push (format "The checkout at %s has uncommitted changes. A worker \
starts from %s and will not see them." path target)
            warnings))
    (unless (rat-kingdom-git-ancestor-p path "HEAD" target)
      (push (format "The checkout's HEAD has %s commits that %s lacks, so a \
worker will not see them.%s"
                    (rat-kingdom-git path "rev-list" "--count"
                                     (concat target "..HEAD"))
                    target
                    (if (rat-kingdom-git-ancestor-p path target "HEAD")
                        " Syncing the repository brings it up to date."
                      (format " The two have diverged: merge %s into the \
checkout first." target)))
            warnings))
    (nreverse warnings)))

(defun rat-kingdom-story-sync (space repo)
  "Bring the target branch of REPO in SPACE up to the checkout's HEAD.
The target is only ever moved forward.  Return a sentence saying what
was done or why nothing was."
  (let* ((record (or (rat-kingdom-repo-get space repo)
                     (error "No repository called %s is registered" repo)))
         (path (plist-get record :path))
         (target (plist-get record :target))
         (head (rat-kingdom-git-rev path "HEAD"))
         (old (rat-kingdom-git-rev path target)))
    (cond
     ((equal head old)
      (format "%s is already at the checkout's HEAD." target))
     ((rat-kingdom-git-ancestor-p path target "HEAD")
      (when (rat-kingdom-git-checked-out-p path target)
        (error "%s is checked out in a worktree and cannot be moved" target))
      (rat-kingdom-git path "update-ref" "-m" "rat-kingdom: sync"
                       (concat "refs/heads/" target) head old)
      (format "Moved %s forward to %s." target (substring head 0 10)))
     ((rat-kingdom-git-ancestor-p path "HEAD" target)
      (format "%s is %s commits ahead of the checkout; nothing to do. Merge \
it into the checkout when you want that work: git merge %s"
              target
              (rat-kingdom-git path "rev-list" "--count"
                               (concat "HEAD.." target))
              target))
     (t
      (format "%s and the checkout have diverged. Merge %s into the checkout, \
then sync again." target target)))))

;;;; Spawning a worker

(defun rat-kingdom-story--prompt (story run-id worktree branch target earlier)
  "Return what the worker RUN-ID is told about the token STORY.
It works in WORKTREE on BRANCH, cut from TARGET.  EARLIER is non-nil
if the story has been worked on before."
  (let ((payload (plist-get story :payload)))
    (concat rat-kingdom-run-rat-instructions
            (format "\n\nYou are %s.\nWorktree: %s\nBranch: %s (cut from %s)\
\n\nTask %s: %s\n"
                    run-id worktree branch target (plist-get story :identity)
                    (plist-get payload :title))
            (when-let* ((description (plist-get payload :description)))
              (concat "\n" description "\n"))
            (when earlier
              (format "\nThis task has been worked on before, and that work \
is in your worktree. Before you change anything, look at \
`git log %s..HEAD` and `git status`, then carry on from there.\n" target))
            (when-let* ((reason (plist-get payload :reason)))
              (concat "\nWhy the task has come to you:\n" reason "\n")))))

(defun rat-kingdom-story--worker-free-p (space id)
  "Return non-nil if the story ID in SPACE may start a worker now.
See `rat-kingdom-story-max-workers'.  A story whose worktree is being
set up counts as a running worker: it holds the place of the worker
that starts as soon as the setup succeeds, so that worker never goes
over the limit and a queued story cannot take its place meanwhile.
ID itself is not counted, since starting a new worker stops the old."
  (or (null rat-kingdom-story-max-workers)
      (< (+ (cl-count-if (lambda (run)
                           (and (plist-get run :story)
                                (not (equal (plist-get run :story) id))
                                (member (plist-get run :state)
                                        '("starting" "working"))))
                         (rat-kingdom-run-list space))
            (cl-count-if-not (lambda (story)
                               (equal (plist-get story :identity) id))
                             (rat-kingdom-space-scan
                              space '(story :awaiting setup))))
         rat-kingdom-story-max-workers)))

(defun rat-kingdom-story--worktree (story)
  "Return the worktree of the token STORY, whether or not it exists yet."
  (or (plist-get (plist-get story :payload) :worktree)
      (expand-file-name (format "worktrees/%s/%s" (plist-get story :scope)
                                (plist-get story :identity))
                        rat-kingdom-directory)))

(defun rat-kingdom-story--spawn (space story workflow step)
  "Begin STEP of WORKFLOW for the taken token STORY in SPACE.
Give the story a worktree, unless it has one, and a new worker.  If no
worker is free, queue it instead; that is not an attempt.  If the
repository has a setup command and the worktree is new, or its setup
did not succeed, run the setup first and wait for it; the worker is
started when it succeeds, by `rat-kingdom-story-set-up'."
  (let* ((id (plist-get story :identity))
         (payload (plist-get story :payload))
         (attempt (1+ (or (plist-get payload :attempt) 0)))
         (limit (or (plist-get step :attempts) rat-kingdom-story-attempts)))
    (cond
     ((> attempt limit)
      (rat-kingdom-story--goto
       space story (plist-get workflow :failure)
       :reason (format "Gave up after %d workers. The last reason: %s"
                       limit (or (plist-get payload :reason) "none recorded"))))
     ((not (rat-kingdom-story--worker-free-p space id))
      (rat-kingdom-story--wait space story step rat-kingdom-story-free-worker))
     (t
      (let* ((repo (rat-kingdom-story--repo space story))
             (path (plist-get repo :path))
             (target (plist-get repo :target))
             (known (plist-get payload :branch))
             (branch (or known (concat "rats/" id)))
             (worktree (rat-kingdom-story--worktree story))
             (fresh (not (file-directory-p worktree)))
             (setup (and (or fresh (plist-get payload :needs-setup))
                         (plist-get repo :setup)))
             (run-id (format "%s.%d" id
                             (1+ (length (rat-kingdom-run-list space id))))))
        (when-let* ((old (plist-get payload :run)))
          (rat-kingdom-run-stop space old))
        (when fresh
          (make-directory (file-name-directory worktree) t)
          (rat-kingdom-git path "worktree" "prune")
          (if known
              (rat-kingdom-git path "worktree" "add" worktree branch)
            (rat-kingdom-git path "worktree" "add" "-b" branch worktree target)))
        (condition-case err
            (if setup
                (progn
                  (rat-kingdom-story--set-up space story setup worktree)
                  ;; The worktree and branch are recorded only when the
                  ;; worker starts, so that it is not told of earlier work.
                  (rat-kingdom-story--wait space story step "setup"
                                           :needs-setup t))
              (rat-kingdom-space-retract
               space (list 'result :scope (plist-get story :scope) :identity id))
              (rat-kingdom-space-retract
               space (list 'blocked :scope (plist-get story :scope) :identity id))
              (rat-kingdom-run-create
               space :id run-id :repo (plist-get repo :name) :story id
               :role (plist-get step :with)
               :worktree worktree :branch branch :target target
               :prompt (rat-kingdom-story--prompt
                        story run-id worktree branch target
                        (or known (> attempt 1))))
              (rat-kingdom-story--wait space story step "worker"
                                       :run run-id :branch branch
                                       :worktree worktree :attempt attempt
                                       :reason nil :needs-setup nil))
          (error
           (rat-kingdom-story--abandon-check id)
           (when (and fresh (not known))
             (ignore-errors
               (rat-kingdom-git path "worktree" "remove" "--force" worktree))
             (ignore-errors (rat-kingdom-git path "branch" "-D" branch)))
           (signal (car err) (cdr err)))))))))

(defun rat-kingdom-story-dequeue (space)
  "Give queued stories in SPACE workers, oldest first, while any is free.
Return the ids of the stories whose step was begun again."
  (let (started)
    (dolist (story (rat-kingdom-space-scan
                    space (list 'story :awaiting rat-kingdom-story-free-worker)))
      (when (rat-kingdom-story--worker-free-p space (plist-get story :identity))
        (rat-kingdom-space-with-transaction space
          (when (rat-kingdom-space-in space (list 'story :id (plist-get story :id))
                                      :actor "engine")
            (rat-kingdom-story--enter space story)
            (push (plist-get story :identity) started)))))
    (nreverse started)))

;;;; Checking

(defun rat-kingdom-story--record-check (space story value &rest more)
  "Record in SPACE that the check of the token STORY came out as VALUE.
VALUE is \"pass\" or \"fail\".  MORE is a property list for the payload."
  (rat-kingdom-space-put space 'checked :scope (plist-get story :scope)
                         :identity (plist-get story :identity)
                         :owner (plist-get story :owner)
                         :payload (append (list :value value)
                                          (and (equal value "fail")
                                               (not (plist-member more :reason))
                                               (list :reason "check failed"))
                                          more)
                         :actor "engine"))

(defun rat-kingdom-story--run (space id name command directory then)
  "Run COMMAND, a list of strings, without a shell in DIRECTORY.
It is the process NAME of the story ID in SPACE, kept in
`rat-kingdom-story--checks'.  Return at once.  When it exits, THEN is
called with its exit status and the end of its output, unless it was
abandoned or SPACE was closed meanwhile."
  (let ((buffer (generate-new-buffer (format " *%s*" name)))
        (default-directory (file-name-as-directory directory)))
    (condition-case err
        (puthash
         id
         (make-process
          :name name :buffer buffer :command command
          :connection-type 'pipe :noquery t
          :sentinel
          (lambda (process _event)
            (unless (process-live-p process)
              (let ((exit (process-exit-status process))
                    (output (with-current-buffer buffer
                              (buffer-substring-no-properties
                               (max (point-min)
                                    (- (point-max)
                                       rat-kingdom-story-output-limit))
                               (point-max)))))
                (kill-buffer buffer)
                (when (eq (gethash id rat-kingdom-story--checks) process)
                  (remhash id rat-kingdom-story--checks))
                (when (and (rat-kingdom-space-db space)
                           (not (process-get process :abandoned)))
                  (funcall then exit output))))))
         rat-kingdom-story--checks)
      (error
       (kill-buffer buffer)
       (signal (car err) (cdr err))))))

(defun rat-kingdom-story--run-check (space story command candidate more
                                           &optional setup)
  "Run COMMAND in CANDIDATE and record how it came out for STORY in SPACE.
If SETUP is non-nil, run that command first, and if it fails record
the check as failed by its setup.  MORE is a property list recorded
with the outcome.  Return at once; the outcome is recorded when the
command exits."
  (let* ((id (plist-get story :identity))
         (check
          (lambda ()
            (rat-kingdom-story--run
             space id "rat-kingdom-check" command candidate
             (lambda (exit output)
               (apply #'rat-kingdom-story--record-check space story
                      (if (eql exit 0) "pass" "fail")
                      :check command :exit exit :output output more))))))
    (if (null setup)
        (funcall check)
      (rat-kingdom-story--run
       space id "rat-kingdom-setup" setup candidate
       (lambda (exit output)
         (if (eql exit 0)
             (condition-case err
                 (funcall check)
               (error
                (apply #'rat-kingdom-story--record-check space story "fail"
                       :check command :exit nil
                       :output (error-message-string err) more)))
           (apply #'rat-kingdom-story--record-check space story "fail"
                  :reason "setup failed" :setup setup :check command
                  :exit exit :output output more)))))))

(defun rat-kingdom-story--set-up (space story setup worktree)
  "Run SETUP in the new WORKTREE of the token STORY in SPACE.
Return at once.  How it came out is recorded as a `setup' tuple when it
exits; `rat-kingdom-story-set-up' takes it from there."
  (let ((scope (plist-get story :scope))
        (id (plist-get story :identity)))
    (rat-kingdom-space-retract space (list 'setup :scope scope :identity id))
    (rat-kingdom-story--run
     space id "rat-kingdom-setup" setup worktree
     (lambda (exit output)
       (rat-kingdom-space-put space 'setup :scope scope :identity id
                              :owner (plist-get story :owner)
                              :payload (list :value (if (eql exit 0)
                                                        "pass"
                                                      "fail")
                                             :setup setup :exit exit
                                             :output output)
                              :actor "engine")))))

(defun rat-kingdom-story--setup-reason (setup exit output)
  "Return why a setup failed: the command SETUP exited with EXIT, printing OUTPUT."
  (format "setup failed: the setup command %s exited with %s. The end of \
its output:\n%s"
          (combine-and-quote-strings setup) exit (or output "")))

(defun rat-kingdom-story--abandon-check (id)
  "Kill the check of the story ID, if one is running, recording nothing."
  (when-let* ((process (gethash id rat-kingdom-story--checks)))
    (remhash id rat-kingdom-story--checks)
    (process-put process :abandoned t)
    (when (process-live-p process)
      (delete-process process))))

(defun rat-kingdom-story--remove-candidate (path candidate)
  "Remove the candidate worktree CANDIDATE of the repository at PATH."
  (when (and candidate (file-exists-p candidate))
    (unless (rat-kingdom-git-ok-p path "worktree" "remove" "--force" candidate)
      (delete-directory candidate t)
      (rat-kingdom-git path "worktree" "prune"))))

(defun rat-kingdom-story--check (space story _workflow step)
  "Begin STEP for the taken token STORY in SPACE.
Merge its commit in a candidate worktree and run the repository's check
there, after its setup if it has one.  With no check there is nothing
to set up for, and the clean merge passes.  The outcome is recorded in
SPACE as a `checked' tuple."
  (let* ((id (plist-get story :identity))
         (payload (plist-get story :payload))
         (repo (rat-kingdom-story--repo space story))
         (path (plist-get repo :path))
         (target (plist-get repo :target))
         (commit (or (plist-get payload :commit)
                     (error "There is no commit to check")))
         (base (rat-kingdom-git-rev path target))
         (candidate (expand-file-name
                     (format "candidates/%s/%s" (plist-get repo :name) id)
                     rat-kingdom-directory))
         (check (plist-get repo :check))
         (title (plist-get payload :title)))
    (rat-kingdom-story--abandon-check id)
    (rat-kingdom-story--remove-candidate path candidate)
    (make-directory (file-name-directory candidate) t)
    (rat-kingdom-git path "worktree" "add" "--detach" candidate base)
    (condition-case err
        (let ((facts (list :commit commit :base base :candidate candidate)))
          (rat-kingdom-space-retract
           space (list 'checked :scope (plist-get story :scope) :identity id))
          (if (not (rat-kingdom-git-ok-p
                    candidate "merge" "--no-ff" "-m"
                    (format "Merge %s: %s" id title) commit))
              (apply #'rat-kingdom-story--record-check
                     space story "fail" :reason "merge conflict"
                     :output (rat-kingdom-git candidate "diff" "--name-only"
                                              "--diff-filter=U")
                     facts)
            (setq facts (append facts
                                (list :head (rat-kingdom-git-rev candidate
                                                                 "HEAD"))))
            (if check
                (rat-kingdom-story--run-check space story check candidate facts
                                              (plist-get repo :setup))
              (apply #'rat-kingdom-story--record-check space story "pass"
                     :check nil facts)))
          (rat-kingdom-story--wait space story step "check"
                                   :candidate candidate :base base))
      (error
       (rat-kingdom-story--abandon-check id)
       (ignore-errors (rat-kingdom-story--remove-candidate path candidate))
       (signal (car err) (cdr err))))))

(defun rat-kingdom-story--check-reason (checked)
  "Return what a worker is told when the check recorded as CHECKED failed."
  (let ((output (plist-get checked :output)))
    (pcase (plist-get checked :reason)
      ("merge conflict"
       (format "merge conflict: your branch no longer merges cleanly into \
the target branch. Merge the target branch into your branch, resolve the \
conflicts, commit, and finish again. Files in conflict:\n%s"
               (or output "unknown")))
      ("setup failed"
       (concat "The check did not run because the repository's "
               (rat-kingdom-story--setup-reason (plist-get checked :setup)
                                                (plist-get checked :exit)
                                                output)
               "\nIt ran in a fresh worktree with your branch merged, before \
the check."))
      (_
       (format "check failed: after your branch was merged, the command %s \
exited with %s. The end of its output:\n%s"
               (combine-and-quote-strings (plist-get checked :check))
               (plist-get checked :exit) (or output ""))))))

;;;; Reviewing

(defun rat-kingdom-story--review (space story _workflow step)
  "Begin STEP for the taken token STORY in SPACE: ask for a review.
A commit that has been reviewed already passes at once."
  (let ((payload (plist-get story :payload)))
    (if (and (plist-get payload :reviewed)
             (equal (plist-get payload :reviewed) (plist-get payload :commit)))
        (rat-kingdom-story--goto space story (plist-get step :pass))
      (rat-kingdom-space-retract
       space (list 'verdict :scope (plist-get story :scope)
                   :identity (plist-get story :identity)))
      (rat-kingdom-space-put
       space 'review :scope (plist-get story :scope)
       :identity (plist-get story :identity) :owner (plist-get story :owner)
       :payload (list :by (format "%s" (plist-get step :with))
                      :commit (plist-get payload :commit))
       :actor "engine")
      (rat-kingdom-story--event
       space 'review
       (rat-kingdom-story--wait space story step "review")))))

(defun rat-kingdom-story-verdict (space id value &optional notes actor)
  "Record the verdict VALUE on the story ID in SPACE.
VALUE is \"pass\" or \"fix\".  NOTES says what to change and is needed
with \"fix\".  ACTOR is who gave the verdict."
  (let ((story (rat-kingdom-space-rd
                space (list 'story :identity id :awaiting "review")))
        (value (rat-kingdom-workflow--name value)))
    (unless story
      (error "%s is not waiting for a review" id))
    (unless (member value '("pass" "fix"))
      (error "A verdict is pass or fix, not %s" value))
    (when (and (equal value "fix") (or (null notes) (string-blank-p notes)))
      (error "A verdict of fix needs notes that say what to change"))
    (rat-kingdom-space-out space 'verdict :scope (plist-get story :scope)
                           :identity id :owner (plist-get story :owner)
                           :payload (list :value value :notes notes)
                           :actor (or actor "user"))
    value))

;;;; Merging

(defun rat-kingdom-story--clean-up (space story path head)
  "Remove what the integrated token STORY left behind in SPACE.
PATH is its repository, whose target branch is now at HEAD.  Failures
are reported and otherwise ignored: the work is already merged."
  (let ((payload (plist-get story :payload)))
    (with-demoted-errors "rat-kingdom: cleaning up: %S"
      (rat-kingdom-story--remove-candidate path (plist-get payload :candidate)))
    (with-demoted-errors "rat-kingdom: cleaning up: %S"
      (rat-kingdom-run-stop space (plist-get payload :run)))
    (with-demoted-errors "rat-kingdom: cleaning up: %S"
      ;; Not forced: a worktree the worker dirtied after reporting stays.
      (rat-kingdom-git path "worktree" "remove" (plist-get payload :worktree))
      (when (rat-kingdom-git-ancestor-p
             path (concat "refs/heads/" (plist-get payload :branch)) head)
        (rat-kingdom-git path "branch" "-D" (plist-get payload :branch))))))

(defun rat-kingdom-story--merge (space story _workflow step)
  "Begin STEP for the taken token STORY in SPACE.
Move the target branch to the checked merge, unless the target has
moved since the check."
  (let* ((id (plist-get story :identity))
         (payload (plist-get story :payload))
         (repo (rat-kingdom-story--repo space story))
         (path (plist-get repo :path))
         (target (plist-get repo :target))
         (head (or (plist-get payload :head)
                   (error "There is no checked merge to land")))
         (base (plist-get payload :base))
         (current (rat-kingdom-git-rev path target))
         (stale
          (cond
           ((equal current head) nil)
           ((not (equal current base)) t)
           ((rat-kingdom-git-checked-out-p path target)
            (error "%s is checked out in a worktree of %s. Check out \
another branch there, then move this story back to %s"
                   target (plist-get repo :name) (plist-get payload :at)))
           ;; Moves the branch only if it is still where the merge started.
           (t (not (rat-kingdom-git-ok-p
                    path "update-ref" "-m"
                    (format "rat-kingdom: integrate %s" id)
                    (concat "refs/heads/" target) head base))))))
    (if stale
        (rat-kingdom-story--goto
         space story (plist-get step :stale)
         :reason (format "%s moved after the check" target))
      (rat-kingdom-story--clean-up space story path head)
      (rat-kingdom-story--goto space story (plist-get step :to)
                               :integrated head :target target))))

;;;; The engine

(defun rat-kingdom-story--finish (space story)
  "Archive the taken token STORY, which is at a final place of SPACE."
  (with-demoted-errors "rat-kingdom: finishing: %S"
    (when-let* ((run (plist-get (plist-get story :payload) :run)))
      (rat-kingdom-run-stop space run)))
  (rat-kingdom-story--event
   space 'done (rat-kingdom-story--put space story :phase "done"))
  (rat-kingdom-space-sweep space (plist-get story :owner))
  ;; Its run is archived with it, which may free a worker.
  (rat-kingdom-story-dequeue space))

(defun rat-kingdom-story--enter (space story)
  "Begin the step of the taken token STORY, which has arrived at a place.
At a final place the story is archived.  At a place no step is taken
from, the token is parked."
  (let* ((workflow (rat-kingdom-story--workflow story))
         (place (plist-get (plist-get story :payload) :at))
         (step (and workflow (rat-kingdom-workflow-step workflow place))))
    (cond
     ((null workflow)
      (rat-kingdom-story--fail
       space story
       (format "There is no workflow called %s"
               (plist-get (plist-get story :payload) :workflow))))
     ((rat-kingdom-workflow-final-p workflow place)
      (rat-kingdom-story--finish space story))
     ((null step)
      (rat-kingdom-story--event
       space 'parked
       (rat-kingdom-story--put space story :phase "parked" :step nil
                               :awaiting nil)))
     (t
      (condition-case err
          (funcall (pcase (plist-get step :kind)
                     (:spawn #'rat-kingdom-story--spawn)
                     (:check #'rat-kingdom-story--check)
                     (:review #'rat-kingdom-story--review)
                     (:merge #'rat-kingdom-story--merge))
                   space story workflow step)
        (error
         (rat-kingdom-story--fail
          space story
          (format "Step %s could not be begun: %s" (plist-get step :name)
                  (error-message-string err)))))))))

(defun rat-kingdom-story--step (story)
  "Return the step the waiting token STORY is in, or nil."
  (when-let* ((workflow (rat-kingdom-story--workflow story)))
    (rat-kingdom-workflow-step-named
     workflow (plist-get (plist-get story :payload) :step))))

(defun rat-kingdom-story--leave (space story outcome &rest changes)
  "Move the waiting token STORY in SPACE to where OUTCOME of its step leads.
CHANGES is merged into its payload."
  (if-let* ((step (rat-kingdom-story--step story)))
      (apply #'rat-kingdom-story--goto space story (plist-get step outcome)
             changes)
    (rat-kingdom-story--fail
     space story
     (format "Its workflow no longer has the step %s"
             (plist-get (plist-get story :payload) :step)))))

(rat-kingdom-defreaction rat-kingdom-story-enter
  "Begin the step of a story that has arrived at a place."
  :take (story :phase enter)
  (rat-kingdom-story--enter rat-kingdom-reaction-space
                            (car rat-kingdom-reaction-tuples)))

(rat-kingdom-defreaction rat-kingdom-story-worker-finished
  "Move on a story whose worker reported that the work is done."
  :take (story :scope $repo :identity $story :awaiting worker :run $run)
  :read (result :scope $repo :identity $story :run $run)
  (let ((result (plist-get (cadr rat-kingdom-reaction-tuples) :payload)))
    (rat-kingdom-story--leave rat-kingdom-reaction-space
                              (car rat-kingdom-reaction-tuples) :to
                              :commit (plist-get result :commit)
                              :summary (plist-get result :summary)
                              :checks (plist-get result :checks))))

(rat-kingdom-defreaction rat-kingdom-story-worker-blocked
  "Move on a story whose worker reported that it cannot go on."
  :take (story :scope $repo :identity $story :awaiting worker :run $run)
  :read (blocked :scope $repo :identity $story :run $run :summary $why)
  (rat-kingdom-story--leave rat-kingdom-reaction-space
                            (car rat-kingdom-reaction-tuples) :blocked
                            :reason (format "The worker %s is blocked: %s"
                                            $run $why)))

(rat-kingdom-defreaction rat-kingdom-story-worker-gone
  "Stop a story whose worker's session ended before it reported."
  :take (story :scope $repo :identity $story :awaiting worker :run $run)
  :read (run :identity $run :state exited)
  (let* ((story (car rat-kingdom-reaction-tuples))
         (run (plist-get (cadr rat-kingdom-reaction-tuples) :payload)))
    (rat-kingdom-story--fail
     rat-kingdom-reaction-space story
     (format "The session of the worker %s ended before it reported%s. Its \
work so far is in %s."
             $run
             (if-let* ((why (plist-get run :error))) (concat ": " why) "")
             (plist-get (plist-get story :payload) :worktree)))))

(rat-kingdom-defreaction rat-kingdom-story-worker-interrupted
  "Give a new worker to a story whose worker was cut off when Emacs stopped."
  :take (story :scope $repo :identity $story :awaiting worker :run $run)
  :read (run :identity $run :state interrupted)
  (let* ((space rat-kingdom-reaction-space)
         (story (car rat-kingdom-reaction-tuples))
         (story (rat-kingdom-story--goto
                 space story (plist-get (plist-get story :payload) :at)
                 :reason (format "The worker before you, %s, was cut off \
when Emacs stopped. It did not report, so its work may be unfinished or \
uncommitted."
                                 $run))))
    ;; Begun here rather than by `rat-kingdom-story-enter', so that a
    ;; queued story does not take the worker this one had.
    (rat-kingdom-space-in space (list 'story :id (plist-get story :id))
                          :actor "engine")
    (rat-kingdom-story--enter space story)))

(rat-kingdom-defreaction rat-kingdom-story-set-up
  "Start the worker of a story whose worktree is set up, or stop the story."
  :take (story :scope $repo :identity $story :awaiting setup)
  :read (setup :scope $repo :identity $story :value $value)
  (let* ((space rat-kingdom-reaction-space)
         (story (car rat-kingdom-reaction-tuples))
         (setup (plist-get (cadr rat-kingdom-reaction-tuples) :payload)))
    (if (equal $value "pass")
        ;; Begun here, with the worker place the setup held.
        (rat-kingdom-story--enter
         space (plist-put (copy-sequence story) :payload
                          (plist-put (copy-sequence (plist-get story :payload))
                                     :needs-setup nil)))
      (rat-kingdom-story--fail
       space story
       (format "The worktree %s could not be prepared for a worker, so none \
was started: %s"
               (rat-kingdom-story--worktree story)
               (rat-kingdom-story--setup-reason (plist-get setup :setup)
                                                (plist-get setup :exit)
                                                (plist-get setup :output)))))))

(rat-kingdom-defreaction rat-kingdom-story-checked
  "Move on a story whose check has come out."
  :take (story :scope $repo :identity $story :awaiting check)
  :read (checked :scope $repo :identity $story :value $value)
  (let* ((story (car rat-kingdom-reaction-tuples))
         (checked (plist-get (cadr rat-kingdom-reaction-tuples) :payload)))
    (if (equal $value "pass")
        (rat-kingdom-story--leave rat-kingdom-reaction-space story :pass
                                  :head (plist-get checked :head)
                                  :base (plist-get checked :base))
      (rat-kingdom-story--leave
       rat-kingdom-reaction-space story :fail
       :reason (rat-kingdom-story--check-reason checked)))))

(rat-kingdom-defreaction rat-kingdom-story-judged
  "Move on a story that has been given a verdict."
  :take ((story :scope $repo :identity $story :awaiting review)
         (verdict :scope $repo :identity $story :value $value))
  (let* ((space rat-kingdom-reaction-space)
         (story (car rat-kingdom-reaction-tuples))
         (verdict (plist-get (cadr rat-kingdom-reaction-tuples) :payload)))
    (rat-kingdom-space-retract space (list 'review :scope $repo
                                           :identity $story))
    (if (equal $value "pass")
        (rat-kingdom-story--leave
         space story :pass
         :reviewed (plist-get (plist-get story :payload) :commit))
      (rat-kingdom-story--leave
       space story :fix
       :reason (format "The review asked for changes:\n%s"
                       (plist-get verdict :notes))))))

(rat-kingdom-defreaction rat-kingdom-story-worker-freed
  "Give a queued story a worker, since a run's change may have freed one."
  :read (run :identity $run)
  (rat-kingdom-story-dequeue rat-kingdom-reaction-space))

;;;; Moving by hand

(defun rat-kingdom-story--abandon (space story)
  "Stop whatever is in progress for the token STORY in SPACE."
  (rat-kingdom-story--abandon-check (plist-get story :identity))
  (when-let* ((run (plist-get (plist-get story :payload) :run)))
    (rat-kingdom-run-stop space run)))

(defun rat-kingdom-story-move (space id place &optional note actor)
  "Put the story ID in SPACE at PLACE, whatever it was doing.
Its worker is stopped and a running check is abandoned; no file is
touched.  NOTE says why and reaches the next worker.  ACTOR is who
moved it.  The step taken from PLACE then begins as usual."
  (let* ((story (or (rat-kingdom-story-get space id)
                    (error "There is no story called %s" id)))
         (workflow (or (rat-kingdom-story--workflow story)
                       (error "The workflow of %s is not defined" id)))
         (place (rat-kingdom-workflow--name place))
         (rat-kingdom-story--actor (or actor "user")))
    (unless (member place (plist-get workflow :places))
      (error "%s is not a place of the workflow %s; its places are %s"
             place (plist-get workflow :name)
             (string-join (plist-get workflow :places) ", ")))
    (rat-kingdom-story--abandon space story)
    (rat-kingdom-space-with-transaction space
      (unless (rat-kingdom-space-in space (list 'story :id (plist-get story :id))
                                    :actor rat-kingdom-story--actor)
        (error "%s moved on meanwhile; look again" id))
      (rat-kingdom-story--goto space story place :reason note :attempt 0))
    place))

(defun rat-kingdom-story-cancel (space id &optional actor)
  "Stop the story ID in SPACE for good and archive it.
Its worker is stopped.  Its worktree and branch are kept.  ACTOR is
who cancelled it.  Return a sentence saying what is left."
  (let* ((story (or (rat-kingdom-story-get space id)
                    (error "There is no story called %s" id)))
         (payload (plist-get story :payload))
         (rat-kingdom-story--actor (or actor "user")))
    (rat-kingdom-story--abandon space story)
    (when-let* ((candidate (plist-get payload :candidate))
                (repo (rat-kingdom-repo-get space (plist-get story :scope))))
      (ignore-errors
        (rat-kingdom-story--remove-candidate (plist-get repo :path) candidate)))
    (rat-kingdom-space-with-transaction space
      (unless (rat-kingdom-space-in space (list 'story :id (plist-get story :id))
                                    :actor rat-kingdom-story--actor)
        (error "%s moved on meanwhile; look again" id))
      (rat-kingdom-story--put space story :phase "cancelled" :step nil
                              :awaiting nil)
      (rat-kingdom-space-sweep space (plist-get story :owner))
      (rat-kingdom-story-dequeue space))
    (rat-kingdom-task-story-ended space story)
    (if (plist-get payload :worktree)
        (format "Cancelled %s. Its worktree %s and branch %s are kept."
                id (plist-get payload :worktree) (plist-get payload :branch))
      (format "Cancelled %s." id))))

;;;; Watching and recovering

(defun rat-kingdom-story--stuck (space story reason)
  "Report in SPACE that the token STORY is stuck for REASON, once."
  (unless (rat-kingdom-space-rd
           space (list 'stuck :scope (plist-get story :scope)
                       :identity (plist-get story :identity)))
    (rat-kingdom-space-with-transaction space
      (rat-kingdom-space-put space 'stuck :scope (plist-get story :scope)
                             :identity (plist-get story :identity)
                             :owner (plist-get story :owner)
                             :payload (list :reason reason) :actor "engine")
      (rat-kingdom-story--event
       space 'stuck
       (plist-put (copy-sequence story) :payload
                  (plist-put (copy-sequence (plist-get story :payload))
                             :reason reason))))
    t))

(defun rat-kingdom-story-watch (space)
  "Report as stuck each story in SPACE that will not move by itself.
That is a story whose step or setup has run past its time, whose check
or setup is not running, whose worker is gone, or which no reaction has
picked up.
A story queued for a free worker is not stuck; the queue is served
first, in case a worker is free.  Return how many were newly reported."
  (rat-kingdom-story-dequeue space)
  (let ((now (funcall rat-kingdom-space-now-function))
        (count 0))
    (dolist (story (rat-kingdom-story-list space))
      (let* ((payload (plist-get story :payload))
             (id (plist-get story :identity))
             (waited (- now (or (plist-get payload :entered) now)))
             (step (rat-kingdom-story--step story))
             (awaiting (plist-get payload :awaiting))
             (limit (if (equal awaiting "setup")
                        (alist-get :check rat-kingdom-story-timeouts)
                      (and step
                           (or (plist-get step :timeout)
                               (alist-get (plist-get step :kind)
                                          rat-kingdom-story-timeouts)))))
             (reason
              (pcase (plist-get payload :phase)
                ("enter"
                 (and (> waited 60)
                      (format "It arrived at %s %d seconds ago and no step \
has begun. Reactions may be off or failing." (plist-get payload :at) waited)))
                ("wait"
                 (cond
                  ((equal awaiting rat-kingdom-story-free-worker)
                   nil)
                  ((and (member awaiting '("check" "setup"))
                        (not (gethash id rat-kingdom-story--checks))
                        (not (rat-kingdom-space-rd
                              space (list (if (equal awaiting "check")
                                              'checked
                                            'setup)
                                          :identity id)))
                        (> waited 5))
                   (format "Its %s is not running." awaiting))
                  ((and (equal awaiting "worker")
                        (not (rat-kingdom-run-get space
                                                  (plist-get payload :run))))
                   "Its worker's record is gone.")
                  ((and limit (> waited limit))
                   (format "%s has taken %d minutes; its limit is %d."
                           (if (equal awaiting "setup")
                               "Its setup"
                             (format "Step %s" (plist-get step :name)))
                           (/ waited 60) (/ limit 60))))))))
        (when (and reason (rat-kingdom-story--stuck space story reason))
          (cl-incf count))))
    count))

(defun rat-kingdom-story-reconcile (space)
  "Put right in SPACE what an Emacs that stopped left in flight.
A run recorded as working with no agent in this Emacs is marked
interrupted; the story it worked for is then given a new worker in the
same worktree.  A check that was running is run again, and so is a
setup that was running in a new worktree, still holding its story's
worker place.  Stories queued for a free worker stay queued, and are
given one if one is free.  Return a property list: `:runs', the ids of
the interrupted runs, `:checks', the ids of the stories checked again,
and `:setups', the ids of the stories whose setup is run again."
  ;; Before runs are marked interrupted, so that their stories, whose
  ;; workers are replaced, keep their places ahead of the queue.
  (rat-kingdom-story-dequeue space)
  (let ((runs (rat-kingdom-run-reconcile space))
        checks setups)
    (dolist (story (rat-kingdom-space-scan space '(story :awaiting setup)))
      (let ((id (plist-get story :identity)))
        (unless (or (gethash id rat-kingdom-story--checks)
                    (rat-kingdom-space-rd space (list 'setup :identity id)))
          (rat-kingdom-space-with-transaction space
            ;; Begun here, while it still holds its worker place.
            (when (rat-kingdom-space-in
                   space (list 'story :id (plist-get story :id))
                   :actor "engine")
              (rat-kingdom-story--enter space story)
              (push id setups))))))
    (dolist (story (rat-kingdom-space-scan space '(story :awaiting check)))
      (let ((id (plist-get story :identity)))
        (unless (or (gethash id rat-kingdom-story--checks)
                    (rat-kingdom-space-rd space (list 'checked :identity id)))
          (rat-kingdom-space-with-transaction space
            (when (rat-kingdom-space-in
                   space (list 'story :id (plist-get story :id))
                   :actor "engine")
              (rat-kingdom-story--goto space story
                                       (plist-get (plist-get story :payload)
                                                  :at))
              (push id checks))))))
    (list :runs runs :checks (nreverse checks) :setups (nreverse setups))))

(provide 'rat-kingdom-story)
;;; rat-kingdom-story.el ends here
