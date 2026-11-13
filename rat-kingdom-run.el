;;; rat-kingdom-run.el --- One agent doing one job -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Chaz Straney

;; Author: Chaz Straney <chaz.straney@gmail.com>
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A run is one agent session doing one job in one worktree (DESIGN.md,
;; section 8).  Its record is a `run' tuple, replaced on each change.
;;
;; A run's state:
;;
;;   starting   recorded, its agent not yet started
;;   working    its agent has been started
;;   ready      the agent called `finish'; a result is recorded
;;   blocked    the agent called `block'
;;   exited     the agent's process went away before it reported
;;   stopped    stopped on purpose
;;
;; The state says what the agent reported, never what its process did:
;; only `finish' makes a run ready.
;;
;; The reaction `rat-kingdom-run-launch' starts the agent of any run
;; that is `starting', so a run recorded just before a crash is started
;; after it.
;;
;; How an agent is started is the backend's business; see
;; `rat-kingdom-run-backend'.  The default is agent-shell.  Tests use a
;; backend that starts nothing.
;;
;; Two tools are offered to a worker: `finish' and `block'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'rat-kingdom-space)
(require 'rat-kingdom-reaction)
(require 'rat-kingdom-git)
(require 'rat-kingdom-mcp)

(autoload 'rat-kingdom-agent-shell-start "rat-kingdom-agent-shell")
(autoload 'rat-kingdom-agent-shell-stop "rat-kingdom-agent-shell")

(defvar rat-kingdom-run-backend
  (list :start #'rat-kingdom-agent-shell-start
        :stop #'rat-kingdom-agent-shell-stop)
  "How agents are started and stopped, as a property list of functions.
`:start' is called with the run's record and its prompt.  It starts an
agent in the run's worktree, sends it the prompt, and returns a handle.
It should arrange for `rat-kingdom-run-exited' to be called if the
agent's process goes away.  `:stop' is called with the handle.")

(defcustom rat-kingdom-run-rat-instructions
  "You are a worker in a rat-kingdom swarm. You have one task. Do it and \
nothing else.

Rules:
- Work only in your worktree, on your branch. They are yours alone.
- Commit your work locally. Never push, and never touch another branch.
- Run the checks that apply before you report.
- When the task is done and committed, call the `finish' tool of the \
rat-kingdom server with a summary and the checks you ran. Your worktree \
must be clean.
- If you cannot finish, call the `block' tool and say what you need.
- After `finish' or `block', stop. Do not start other work."
  "What every worker is told before its task."
  :type 'string
  :group 'rat-kingdom)

(defvar rat-kingdom-run--handles (make-hash-table :test #'equal)
  "Hash table from run id to the handle its backend returned.")

;;;; Records

(defun rat-kingdom-run--record (tuple)
  "Return the run record in TUPLE.
A record is the tuple's payload with `:id', `:repo' and `:story'."
  (append (list :id (plist-get tuple :identity)
                :repo (plist-get tuple :scope)
                :story (plist-get tuple :owner))
          (plist-get tuple :payload)))

(defun rat-kingdom-run-get (space id)
  "Return the record of the run ID in SPACE, or nil."
  (when-let* ((tuple (rat-kingdom-space-rd space (list 'run :identity id))))
    (rat-kingdom-run--record tuple)))

(defun rat-kingdom-run-list (space &optional story)
  "Return the records of the runs in SPACE, or only those of STORY."
  (mapcar #'rat-kingdom-run--record
          (rat-kingdom-space-scan
           space (if story (list 'run :owner story) '(run)))))

(cl-defun rat-kingdom-run-create (space &key id repo story role worktree
                                        branch target prompt)
  "Record a new run in SPACE, to be started by `rat-kingdom-run-launch'.
ID names the run.  It belongs to STORY in REPO, plays ROLE, and works
in WORKTREE on BRANCH, which was cut from TARGET.  PROMPT is what its
agent is told.  Return the record."
  (when (rat-kingdom-run-get space id)
    (error "There is already a run called %s" id))
  (rat-kingdom-space-put
   space 'run :scope repo :identity id :owner story
   :payload (list :state "starting" :role (format "%s" role)
                  :worktree worktree :branch branch :target target
                  :prompt prompt)
   :actor "engine")
  (rat-kingdom-run-get space id))

(defun rat-kingdom-run-update (space id &rest changes)
  "Change the record of the run ID in SPACE by the property list CHANGES.
Return the new record, or nil if there is no such run."
  (when-let* ((tuple (rat-kingdom-space-rd space (list 'run :identity id))))
    (let ((payload (copy-sequence (plist-get tuple :payload))))
      (while changes
        (setq payload (plist-put payload (pop changes) (pop changes))))
      (rat-kingdom-space-put space 'run :scope (plist-get tuple :scope)
                             :identity id :owner (plist-get tuple :owner)
                             :payload payload :actor "engine")
      (rat-kingdom-run-get space id))))

;;;; Starting and stopping

(defun rat-kingdom-run--launch (space id)
  "Start the agent of the run ID in SPACE and mark the run working."
  (let ((run (rat-kingdom-run-get space id)))
    (puthash id
             (funcall (plist-get rat-kingdom-run-backend :start)
                      run (plist-get run :prompt))
             rat-kingdom-run--handles)
    (rat-kingdom-run-update space id :state "working")))

(rat-kingdom-defreaction rat-kingdom-run-launch
  "Start the agent of a run that has been recorded but not started."
  :read (run :identity $run :state starting)
  (rat-kingdom-run--launch rat-kingdom-reaction-space $run))

(defun rat-kingdom-run-stop (space id)
  "Stop the agent of the run ID in SPACE and mark the run stopped.
Nothing in its worktree is touched.  A run that already reported keeps
its state."
  (when-let* ((handle (gethash id rat-kingdom-run--handles)))
    (remhash id rat-kingdom-run--handles)
    (with-demoted-errors "rat-kingdom: stopping a run: %S"
      (funcall (plist-get rat-kingdom-run-backend :stop) handle)))
  (rat-kingdom-mcp-revoke id)
  (when-let* ((run (rat-kingdom-run-get space id))
              ((member (plist-get run :state) '("starting" "working" "exited"))))
    (rat-kingdom-run-update space id :state "stopped")))

(defun rat-kingdom-run-exited (id)
  "Note that the agent process of the run ID has gone away.
A run that had not reported becomes `exited'.  Backends call this."
  (remhash id rat-kingdom-run--handles)
  (rat-kingdom-mcp-revoke id)
  (let ((space (rat-kingdom-space-default)))
    (when-let* ((run (rat-kingdom-run-get space id))
                ((member (plist-get run :state) '("starting" "working"))))
      (rat-kingdom-run-update space id :state "exited"))))

;;;; The worker's tools

(defun rat-kingdom-run--calling (context)
  "Return the space and the record of the run that CONTEXT says is calling."
  (let* ((space (rat-kingdom-space-default))
         (run (rat-kingdom-run-get space (plist-get context :run))))
    (unless run
      (error "This run is over"))
    (list space run)))

(defun rat-kingdom-run--story-waiting-p (space run)
  "Return non-nil if RUN's story in SPACE still waits for its work."
  (rat-kingdom-space-rd space (list 'story :identity (plist-get run :story)
                                    :at "implementing")))

(defun rat-kingdom-run--finish (context arguments)
  "Record that the calling run's work is done.
CONTEXT names the run; ARGUMENTS has `summary' and `checks'."
  (pcase-let* ((`(,space ,run) (rat-kingdom-run--calling context))
               (worktree (plist-get run :worktree))
               (branch (plist-get run :branch)))
    (unless (rat-kingdom-run--story-waiting-p space run)
      (error "This task is no longer waiting for work"))
    (unless (equal (rat-kingdom-git worktree "rev-parse" "--abbrev-ref" "HEAD")
                   branch)
      (error "Your worktree is not on your branch %s; check it out" branch))
    (unless (string-empty-p (rat-kingdom-git worktree "status" "--porcelain"))
      (error "Your worktree has uncommitted or untracked files; \
commit what belongs to the task and remove the rest"))
    (when (equal (rat-kingdom-git worktree "rev-list" "--count"
                                  (concat (plist-get run :target) "..HEAD"))
                 "0")
      (error "Your branch has no commits of its own; commit your work first"))
    (let ((commit (rat-kingdom-git-rev worktree "HEAD")))
      (rat-kingdom-space-with-transaction space
        (rat-kingdom-space-put
         space 'result :scope (plist-get run :repo)
         :identity (plist-get run :story) :owner (plist-get run :story)
         :payload (list :commit commit :run (plist-get run :id)
                        :summary (alist-get 'summary arguments)
                        :checks (alist-get 'checks arguments))
         :actor (plist-get run :id))
        (rat-kingdom-run-update space (plist-get run :id)
                                :state "ready" :commit commit))
      (format "Recorded commit %s. Your task is finished. Stop here; do not \
start other work."
              (substring commit 0 10)))))

(defun rat-kingdom-run--block (context arguments)
  "Record that the calling run cannot go on.
CONTEXT names the run; ARGUMENTS has `summary'."
  (pcase-let ((`(,space ,run) (rat-kingdom-run--calling context)))
    (unless (rat-kingdom-run--story-waiting-p space run)
      (error "This task is no longer waiting for work"))
    (rat-kingdom-space-with-transaction space
      (rat-kingdom-space-put
       space 'blocked :scope (plist-get run :repo)
       :identity (plist-get run :story) :owner (plist-get run :story)
       :payload (list :run (plist-get run :id)
                      :summary (alist-get 'summary arguments))
       :actor (plist-get run :id))
      (rat-kingdom-run-update space (plist-get run :id) :state "blocked"))
    "Recorded. Your work is kept as it is. Stop here; do not start other work."))

(rat-kingdom-mcp-define-tool
 "finish"
 :description "Report that your task is done. Call this once your work is \
committed on your branch and your worktree is clean. It fails, and tells you \
why, if that is not so. After it succeeds, stop."
 :roles '(rat)
 :args '((:name "summary" :type string
          :description "What you changed and why, in a few sentences.")
         (:name "checks" :type string
          :description "The checks you ran and how each came out, for \
example \"go test ./... passed\". Say so if you ran none."))
 :function #'rat-kingdom-run--finish)

(rat-kingdom-mcp-define-tool
 "block"
 :description "Report that you cannot finish your task. Your work so far is \
kept. After it succeeds, stop."
 :roles '(rat)
 :args '((:name "summary" :type string
          :description "What stopped you and what you need to go on."))
 :function #'rat-kingdom-run--block)

(provide 'rat-kingdom-run)
;;; rat-kingdom-run.el ends here
