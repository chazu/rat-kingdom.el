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
;;                     `:awaiting' says for what: worker, setup, check,
;;                     review, run or gate, or "a free worker" while it
;;                     is queued
;;            parked   no step is taken from here; it waits to be moved
;;
;; The reactions here are the workflow engine.  One begins the step of
;; a token that has arrived.  The others each join a waiting token with
;; the tuple that ends its step: a worker's `result' or `blocked', a
;; `checked', a `verdict', a `ran', a `signal', or a run that ended
;; without reporting.  A timed gate is opened by
;; `rat-kingdom-story-open-gates', from a timer and from the watchdog.
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
;; The target is the repository's, unless the story was started with a
;; `:target' of its own, as the stories of an epic with a feature branch
;; are (rat-kingdom-epic.el).  `rat-kingdom-story-target' is the one
;; place a story's target is read: its worktree is cut from it, its
;; worker is told of it, its candidate is made from it and it is the
;; branch that is moved.
;;
;; The engine's settings come from configuration (rat-kingdom-config.el,
;; DESIGN.md section 7.3), looked up for the story's repository, epic
;; and task: the workflow and worker agent a story starts with, its
;; target, the setup and check, time limits, attempts and the worker
;; limit.  The user options below are the defaults layer.
;;
;; A repository may have a setup, such as "npm ci", that its worktrees
;; need before anything can be built or tested.  A setup or a check is
;; one command or several, named in `:commands', run in order until one
;; fails (`rat-kingdom-story-commands').  The setup runs in a
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
;; A story names the agent its workers run, `:agent' on its token,
;; fixed when it starts: "claude" or "codex", or another kind of
;; rat-kingdom-agent-shell.el.  Every worker it is given, after a failed
;; check, a review or a restart too, runs that agent.
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
(require 'rat-kingdom-agent-shell)
(require 'rat-kingdom-workflow)
(require 'rat-kingdom-task)
(require 'rat-kingdom-config)

(defcustom rat-kingdom-story-default-workflow "story"
  "The workflow of a story whose repository names none.
This is the default of the configuration's `:workflow'."
  :type 'string
  :group 'rat-kingdom)

(defcustom rat-kingdom-story-attempts 5
  "How many workers one story may be given before it is stopped.
A step's `:attempts' overrides this, and so does the configuration's
`:attempts', of which this is the default.  Moving a story by hand
starts the count again."
  :type 'integer
  :group 'rat-kingdom)

(defcustom rat-kingdom-story-timeouts '((:spawn . 7200) (:check . 1800))
  "Seconds a step of each kind may take before its story is called stuck.
A step's `:timeout' overrides this.  A kind left out has no limit.
This is the default of the configuration's `:timeouts', whose `:worker'
is the `:spawn' entry here and `:check' the `:check' entry.
A repository's setup in a worker's worktree may take as long as a
`:check'; in a candidate it is part of the check, and shares its time."
  :type '(alist :key-type symbol :value-type number)
  :group 'rat-kingdom)

(defcustom rat-kingdom-story-max-workers 3
  "Most workers that may run at once, or nil for no limit.
This is the default of the configuration's `:max-workers'.
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
events are `done' (at a final place and about to be archived; its
`:integrated' is set if it was merged), `parked' (stopped until someone
moves it; its `:reason' says why), `review' (it waits for a verdict),
`stuck' and `cancelled' (cancelled by hand and about to be archived).
They are called inside the transaction that made the change, before
the story's task is closed or released.")

(add-hook 'rat-kingdom-story-event-functions #'rat-kingdom-story--announce t)
(add-hook 'rat-kingdom-story-event-functions #'rat-kingdom-task-story-event t)

(defvar rat-kingdom-story-brief-functions nil
  "Functions that add sections to a worker's brief.
Each is called with the space, the story's token and the id of the run
being started, and returns a string, a section of the worker's prompt,
or nil.  The sections are appended to the prompt in the order of this
list, each after a blank line.  An error in one is reported and its
section left out.  Add to it with `add-hook', so that reloading does
not add a function twice.")

(defvar rat-kingdom-story--actor "engine"
  "Who is recorded as moving tokens.")

(defvar rat-kingdom-story--checks (make-hash-table :test #'equal)
  "Hash table from story id to the process running its check, setup or run.
A story runs at most one at a time: its setup in a new worktree, in
a candidate its setup and then its check, or the commands of a `:run'
step in its worktree.")

(defvar rat-kingdom-story--gate-timers (make-hash-table :test #'equal)
  "Hash table from story id to the timer that opens its timed gate.")

;;;; Tokens

(defun rat-kingdom-story-get (space id)
  "Return the token of the story ID in SPACE, or nil."
  (rat-kingdom-space-rd space (list 'story :identity id)))

(defun rat-kingdom-story-list (space &optional repo)
  "Return the tokens of the stories in SPACE, or only those in REPO."
  (rat-kingdom-space-scan space (if repo (list 'story :scope repo) '(story))))

(defun rat-kingdom-story--workflow (space story)
  "Return the workflow of the token STORY in SPACE, or nil if it is not defined.
It is resolved for the story's repository, by
`rat-kingdom-config-workflow': its own workflow files, then the global
ones, then the built-in workflows.  It is looked up each time, so a
workflow whose file changes applies from the token's next move."
  (rat-kingdom-config-workflow
   space (plist-get (plist-get story :payload) :workflow)
   (plist-get story :scope)))

(defun rat-kingdom-story--repo (space story)
  "Return the record of the repository of the token STORY in SPACE."
  (or (rat-kingdom-repo-get space (plist-get story :scope))
      (error "Repository %s is no longer registered" (plist-get story :scope))))

(defun rat-kingdom-story-target (space story)
  "Return the branch the token STORY in SPACE is cut from and merged into.
That is the `:target' it was started with, if any, and otherwise its
repository's target.  STORY may also be a story not yet started, as a
property list with `:scope', the repository, and a `:payload' that may
have `:target'.  Return nil if neither is known, as when the repository
is no longer registered.  Every reading of a story's target goes
through this."
  (or (plist-get (plist-get story :payload) :target)
      (and (rat-kingdom-repo-get space (plist-get story :scope))
           (rat-kingdom-story-repo-target space (plist-get story :scope)))))

(defun rat-kingdom-story-repo-target (space repo)
  "Return the target of the repository REPO in SPACE, from its configuration.
That is the merged `:target' (rat-kingdom-config.el): the repository's
.rk/config.eld, then its registration, then the global file, then
`rat-kingdom-git-default-target'."
  (rat-kingdom-config-get space :target :repo repo))

(defun rat-kingdom-story-config (space story key)
  "Return the configuration KEY in SPACE for the token STORY.
It is looked up with `rat-kingdom-config-get' for the story's
repository, and its epic and task, if it has them, so their policies
count.  STORY may also be a story not yet started, as a property list
with `:scope' and a `:payload' that may have `:epic' and `:task'."
  (let ((payload (plist-get story :payload)))
    (rat-kingdom-config-get space key :repo (plist-get story :scope)
                            :epic (plist-get payload :epic)
                            :task (plist-get payload :task))))

(defun rat-kingdom-story-commands (space key repo &optional epic task)
  "Return the setup or check of REPO in SPACE as the commands to run.
KEY is :setup or :check.  It is the merged configuration for REPO,
EPIC and TASK, with command names resolved against the merged
`:commands' by `rat-kingdom-config-resolve-commands'.  Return a list
of (NAME . ARGV), in the order they run: ARGV is the argument list and
NAME the command's name, a string, or nil if the configuration gave an
argument list rather than names.  Return nil if there is none.  Signal
`rat-kingdom-config-error' if a name is not defined."
  (let* ((merged (rat-kingdom-config-merged space :repo repo :epic epic
                                            :task task))
         (value (plist-get merged key))
         (argvs (rat-kingdom-config-resolve-commands
                 value (plist-get merged :commands))))
    (cl-mapcar (lambda (name argv)
                 (cons (and name (symbol-name name)) argv))
               (if (stringp (car value)) (list nil) value)
               argvs)))

(defun rat-kingdom-story-command-text (argv &optional name)
  "Return the command ARGV as text, after its NAME if it has one."
  (if name
      (format "%s (%s)" name (combine-and-quote-strings argv))
    (combine-and-quote-strings argv)))

(defun rat-kingdom-story-named-commands (space story names)
  "Return the commands NAMES of the token STORY in SPACE, to run in order.
NAMES is a list of symbols, as a step's `:check' or `:run' gives
them.  Each is looked up in the merged `:commands' for the story's
repository, epic and task.  Return a list of (NAME . ARGV), NAME a
string, as `rat-kingdom-story-commands' does.  Signal an error naming
the first name that `:commands' does not define, and the names it
does."
  (let ((commands (rat-kingdom-story-config space story :commands)))
    (mapcar
     (lambda (name)
       (let ((key (rat-kingdom-config--command-key name)))
         (unless (plist-member commands key)
           (error "%s is not a command; %s" name
                  (if commands
                      (concat "the commands are "
                              (mapconcat
                               (lambda (key) (substring (symbol-name key) 1))
                               (cl-loop for (key) on commands by #'cddr
                                        collect key)
                               ", "))
                    "no commands are defined (:commands)")))
         (cons (symbol-name name) (plist-get commands key))))
     names)))

(defun rat-kingdom-story-check-target (space repo target)
  "Signal an error unless TARGET may be the target of a story in REPO of SPACE.
It must be an existing local branch, and not one checked out in any
worktree, the user's checkout included, since work is merged into it
by moving it."
  (let ((path (plist-get (or (rat-kingdom-repo-get space repo)
                             (error "No repository called %s is registered" repo))
                         :path)))
    (unless (and (stringp target)
                 (not (string-empty-p target))
                 (rat-kingdom-git-ok-p path "rev-parse" "--verify" "--quiet"
                                       (concat "refs/heads/" target)))
      (error "%s has no local branch %s to use as the target" repo target))
    (when (rat-kingdom-git-checked-out-p path target)
      (error "The branch %s is checked out in a worktree of %s, so it cannot \
be a target: work is merged into a target by moving it. Check out another \
branch there first" target repo))
    target))

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
               ('cancelled "is cancelled")
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
  (let ((payload (plist-get story :payload)))
    (apply #'rat-kingdom-story--put space story
           :at place :phase "enter" :step nil :awaiting nil
           (append
            ;; What a gate waited for goes with it.
            (and (plist-get payload :until) (list :until nil))
            (and (plist-get payload :signal) (list :signal nil))
            (if (plist-member changes :reason)
                changes
              (append (list :reason nil) changes))))))

(defun rat-kingdom-story--wait (space story step awaiting &rest changes)
  "Put the taken token STORY back in SPACE, waiting in STEP for AWAITING.
CHANGES is merged into its payload."
  (apply #'rat-kingdom-story--put space story
         :phase "wait" :step (plist-get step :name) :awaiting awaiting
         changes))

(defun rat-kingdom-story--fail (space story reason)
  "Send the taken token STORY in SPACE to its failure place, with REASON."
  (let* ((workflow (rat-kingdom-story--workflow space story))
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
                                      workflow task agent epic target)
  "Start a story in SPACE for the repository REPO and return its id.
TITLE says what to do in a line; DESCRIPTION gives the acceptance
criteria.  ID names the story; one is made up if it is nil.  WORKFLOW
names its workflow; by default the configuration's `:workflow' for the
repository, EPIC and TASK (rat-kingdom-config.el), which falls back to
the repository's registration and then to
`rat-kingdom-story-default-workflow'.  TASK, if given, is the id of
the tracker's task the story works on: its `available' tuple is taken
and the task is claimed for the story.  A task has at most one story
in progress, so another for it is an error.  AGENT names the agent
every worker of the story runs, \"claude\" or \"codex\"; by default
the configuration's `:agents' `:worker', which falls back to
`rat-kingdom-default-agent'.  An unknown agent is an error.  EPIC, if
given, is the id of the epic the story was started for, kept on its
token as `:epic'.  TARGET, if given, is the branch the story's worktree
is cut from and its work merged into, instead of the repository's
target, kept on its token as `:target'; it must be an existing local
branch that is not checked out (`rat-kingdom-story-check-target')."
  (unless (rat-kingdom-repo-get space repo)
    (error "No repository called %s is registered" repo))
  (let ((id (or id (rat-kingdom-story--new-id space)))
        (where (list :scope repo :payload (list :epic epic :task task))))
    (when target
      (rat-kingdom-story-check-target space repo target))
    (when (rat-kingdom-space-rd space (list 'story :identity id))
      (error "There is already a story called %s" id))
    (let* ((agent (rat-kingdom-agent-name
                   (if (or (null agent) (equal agent ""))
                       (plist-get (rat-kingdom-story-config space where :agents)
                                  :worker)
                     agent)))
           (name (rat-kingdom-workflow--name
                  (or workflow
                      (rat-kingdom-story-config space where :workflow))))
           (workflow (or (rat-kingdom-config-workflow space name repo)
                         (error "There is no workflow called %s; there are: %s"
                                name
                                (rat-kingdom-config-workflow-names space
                                                                   repo))))
           (branch-name (rat-kingdom-story-branch-name space where id title)))
      (rat-kingdom-space-with-transaction space
        (when task
          (when-let* ((other (rat-kingdom-space-rd
                              space (list 'story :scope repo :task task))))
            (error "The story %s already works on the task %s; see story_show"
                   (plist-get other :identity) task))
          (rat-kingdom-space-in space (list 'available :scope repo :identity task)
                                :actor "user"))
        (rat-kingdom-space-out
         space 'story :scope repo :identity id :owner id
         :payload (append
                   (list :workflow name :at (plist-get workflow :start)
                         :phase "enter" :title title :description description
                         :agent agent :attempt 0 :branch-name branch-name
                         :entered (funcall rat-kingdom-space-now-function))
                   (and task (list :task task))
                   (and epic (list :epic epic))
                   (and target (list :target target)))
         :actor "user"))
      (when task
        (rat-kingdom-task-claim-for-story space repo task id))
      id)))

(defun rat-kingdom-story-branch-name (space story id title)
  "Return the branch name of the story ID titled TITLE, about to start in SPACE.
STORY is the story as `rat-kingdom-story-config' takes it, with its
repository and maybe its epic and task.  The name is made from the
configuration's :git :branch by `rat-kingdom-config-branch-name'.
Signal an error, which starts nothing, if `git check-ref-format
--branch' refuses it."
  (let* ((repo (plist-get story :scope))
         (format-string (or (plist-get (rat-kingdom-story-config space story :git)
                                       :branch)
                            rat-kingdom-config-default-branch-format))
         (name (rat-kingdom-config-branch-name
                format-string id title repo
                (plist-get (plist-get story :payload) :epic))))
    (unless (rat-kingdom-config-git-branch-ok-p
             name (plist-get (rat-kingdom-repo-get space repo) :path))
      (error "The branch name %S, made from the :git :branch %S, is not a \
valid branch name (git check-ref-format --branch); change :git :branch \
with config_set" name format-string))
    name))

(defun rat-kingdom-story--free-branch (path name)
  "Return NAME, or NAME with -2, -3 and so on, whichever is first free in PATH.
A name is free if the repository at PATH has no local branch by it."
  (let ((candidate name) (n 1))
    (while (rat-kingdom-git-ok-p path "rev-parse" "--verify" "--quiet"
                                 (concat "refs/heads/" candidate))
      (setq candidate (format "%s-%d" name (cl-incf n))))
    candidate))

(defun rat-kingdom-story-task (space repo id)
  "Return the task ID of the repository REPO in SPACE, for a new story.
The task is a property list with at least `:title' and `:description',
taken from its `available' tuple or else from the tracker.  Signal an
error if REPO has no tracker, the tracker has no such task, or a story
already works on it."
  (let ((adapter (or (rat-kingdom-task-adapter space repo)
                     (error "The repository %s has no task tracker, so it \
has no task %s; leave out task and give a title and description" repo id))))
    (when-let* ((story (rat-kingdom-space-rd
                        space (list 'story :scope repo :task id))))
      (error "The story %s already works on the task %s; see story_show"
             (plist-get story :identity) id))
    (or (plist-get (rat-kingdom-space-rd
                    space (list 'available :scope repo :identity id))
                   :payload)
        (condition-case err
            (or (rat-kingdom-task-show adapter id)
                (error "No such task"))
          (error (error "The tracker of %s has no task %s (%s); see \
Available tasks in status" repo id (error-message-string err)))))))

(cl-defun rat-kingdom-story-start-for-task (space repo task
                                                  &key title description
                                                  agent workflow epic found
                                                  target)
  "Start a story in SPACE for the task TASK of the repository REPO.
Return the story's id.  The task is looked up as `rat-kingdom-story-task'
does, unless FOUND gives it already.  TITLE defaults to the task's.
Without DESCRIPTION the story's is the task's own text; with it, or if
the task has none, it is DESCRIPTION followed by a line naming the task.
AGENT and WORKFLOW default to the task's rk-agent: and rk-workflow:
labels, then to the usual defaults.  EPIC, if given, is recorded on the
token as `:epic', and TARGET as `:target'.  The task's `available'
tuple is taken and the task is claimed for the story; see
`rat-kingdom-story-start'."
  (let* ((found (or found (rat-kingdom-story-task space repo task)))
         (title (or title (plist-get found :title)
                    (error "Give a title, or a task to take it from")))
         (description
          (if (and (not description) (plist-get found :description))
              (plist-get found :description)
            (concat (and description (concat description "\n\n"))
                    (format "This story works on the tracker task %s: %s"
                            task (plist-get found :title))))))
    (rat-kingdom-story-start
     space repo title description nil
     (or workflow (rat-kingdom-task-workflow found))
     task
     (or agent (rat-kingdom-task-agent found))
     epic target)))

(defun rat-kingdom-story-warnings (space repo &optional target)
  "Return what a person starting a story in REPO in SPACE should know.
The result is a list of strings: that the checkout has changes a worker
will not see, or commits the target branch lacks.  TARGET is the
story's own target, if it is to have one."
  (let* ((record (or (rat-kingdom-repo-get space repo)
                     (error "No repository called %s is registered" repo)))
         (path (plist-get record :path))
         (target (rat-kingdom-story-target
                  space (list :scope repo :payload (list :target target))))
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
         (target (rat-kingdom-story-repo-target space repo))
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

(defun rat-kingdom-story--brief-sections (space story run-id)
  "Return the sections `rat-kingdom-story-brief-functions' give, in order.
Each is called with SPACE, the token STORY and RUN-ID."
  (let (sections)
    (dolist (function rat-kingdom-story-brief-functions)
      (with-demoted-errors "rat-kingdom: brief function: %S"
        (when-let* ((section (funcall function space story run-id)))
          (push section sections))))
    (nreverse sections)))

(defun rat-kingdom-story--prompt (space story run-id worktree branch target
                                        earlier &optional step)
  "Return what the worker RUN-ID is told about the token STORY in SPACE.
It works in WORKTREE on BRANCH, cut from TARGET.  EARLIER is non-nil
if the story has been worked on before.  STEP is the step that starts
the worker; its `:brief', if it has one, follows the task's description
under \"For this step (STEP):\".  The sections from
`rat-kingdom-story-brief-functions' come last."
  (let ((payload (plist-get story :payload))
        (brief (plist-get step :brief)))
    (concat rat-kingdom-run-rat-instructions
            (format "\n\nYou are %s.\nWorktree: %s\nBranch: %s (cut from %s)\
\n\nTask %s: %s\n"
                    run-id worktree branch target (plist-get story :identity)
                    (plist-get payload :title))
            (when-let* ((description (plist-get payload :description)))
              (concat "\n" description "\n"))
            (when (and (stringp brief) (not (string-blank-p brief)))
              (format "\nFor this step (%s):\n%s\n" (plist-get step :name)
                      (string-trim brief)))
            (when earlier
              (format "\nThis task has been worked on before, and that work \
is in your worktree. Before you change anything, look at \
`git log %s..HEAD` and `git status`, then carry on from there.\n" target))
            (when-let* ((reason (plist-get payload :reason)))
              (concat "\nWhy the task has come to you:\n" reason "\n"))
            (mapconcat (lambda (section)
                         (concat "\n" (string-trim-right section) "\n"))
                       (rat-kingdom-story--brief-sections space story run-id)
                       ""))))

(defun rat-kingdom-story--worker-free-p (space id)
  "Return non-nil if the story ID in SPACE may start a worker now.
The limit is the configuration's `:max-workers', set only globally,
by default `rat-kingdom-story-max-workers'.  A story whose worktree is
being set up counts as a running worker: it holds the place of the worker
that starts as soon as the setup succeeds, so that worker never goes
over the limit and a queued story cannot take its place meanwhile.
ID itself is not counted, since starting a new worker stops the old."
  (let ((limit (rat-kingdom-config-get space :max-workers)))
    (or (null limit)
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
           limit))))

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
repository has a setup (`rat-kingdom-story-commands') and the worktree
is new, or its setup did not succeed, run the setup first and wait for
it; the worker is started when it succeeds, by
`rat-kingdom-story-set-up'.  How many workers the story may be given is
the step's `:attempts', else the configuration's."
  (let* ((id (plist-get story :identity))
         (payload (plist-get story :payload))
         (attempt (1+ (or (plist-get payload :attempt) 0)))
         (limit (or (plist-get step :attempts)
                    (rat-kingdom-story-config space story :attempts))))
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
             (target (rat-kingdom-story-target space story))
             (known (plist-get payload :branch))
             (worktree (rat-kingdom-story--worktree story))
             (fresh (not (file-directory-p worktree)))
             ;; A name from :git :branch takes a suffix if it is taken; a
             ;; token from before it, with no :branch-name, does not.  A
             ;; worktree made before the branch was recorded, as while
             ;; its setup ran, is on the branch it was made with.
             (branch (cond (known)
                           ((plist-get payload :branch-name)
                            (if fresh
                                (rat-kingdom-story--free-branch
                                 path (plist-get payload :branch-name))
                              (or (ignore-errors
                                    (rat-kingdom-git worktree "symbolic-ref"
                                                     "--short" "HEAD"))
                                  (plist-get payload :branch-name))))
                           (t (concat "rats/" id))))
             (setup (and (or fresh (plist-get payload :needs-setup))
                         (rat-kingdom-story-commands
                          space :setup (plist-get repo :name)
                          (plist-get payload :epic) (plist-get payload :task))))
             (run-id (format "%s.%d" id
                             (1+ (length (rat-kingdom-run-list space id))))))
        (when-let* ((old (plist-get payload :run)))
          (rat-kingdom-run-stop space old))
        (when fresh
          (make-directory (file-name-directory worktree) t)
          (rat-kingdom-git path "worktree" "prune")
          (cond
           (known (rat-kingdom-git path "worktree" "add" worktree branch))
           ((plist-get payload :branch-name)
            ;; The name was free, so a branch Git made before failing
            ;; is its own, and goes.
            (condition-case err
                (rat-kingdom-git path "worktree" "add" "-b" branch worktree
                                 target)
              (error
               (ignore-errors (rat-kingdom-git path "branch" "-D" branch))
               (signal (car err) (cdr err)))))
           (t (rat-kingdom-git path "worktree" "add" "-b" branch worktree
                               target))))
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
               :agent (plist-get payload :agent)
               :worktree worktree :branch branch :target target
               :prompt (rat-kingdom-story--prompt
                        space story run-id worktree branch target
                        (or known (> attempt 1)) step))
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

(defun rat-kingdom-story--run-all (space id name commands directory then)
  "Run COMMANDS one after another in DIRECTORY, stopping at the first failure.
COMMANDS is a list of (NAME . ARGV), as `rat-kingdom-story-commands'
returns; each runs as `rat-kingdom-story--run' runs it, as the process
NAME of the story ID in SPACE.  Return at once.  When the last has
succeeded, or one has failed, THEN is called with its exit status, the
end of its output and the command, (NAME . ARGV).  A command after the
first that cannot be started fails with exit status nil and the error
as its output; the first signals the error."
  (let ((command (car commands)))
    (rat-kingdom-story--run
     space id name (cdr command) directory
     (lambda (exit output)
       (if (or (not (eql exit 0)) (null (cdr commands)))
           (funcall then exit output command)
         (condition-case err
             (rat-kingdom-story--run-all space id name (cdr commands)
                                         directory then)
           (error (funcall then nil (error-message-string err)
                           (cadr commands)))))))
    ;; So that what is running can be shown.
    (when-let* ((process (gethash id rat-kingdom-story--checks)))
      (process-put process :command command))))

(defun rat-kingdom-story-running (id)
  "Return the command the story ID is running now, as (NAME . ARGV), or nil.
That is a command of its setup, its check or a `:run' step."
  (when-let* ((process (gethash id rat-kingdom-story--checks)))
    (and (process-live-p process) (process-get process :command))))

(defun rat-kingdom-story--command-facts (key command commands)
  "Return what is recorded of the COMMAND that ended a setup or check.
KEY is :setup or :check, COMMAND the (NAME . ARGV) that failed or ran
last, and COMMANDS all of them.  The result is a property list: KEY,
the argument list; `:command', its name, if it has one; and, when
COMMANDS have names, `:names', a list of the names, in order."
  (append (list key (cdr command))
          (and (car command) (list :command (car command)))
          (and (car command)
               (list :names (delq nil (mapcar #'car commands))))))

(defun rat-kingdom-story--run-check (space story check candidate more
                                           &optional setup)
  "Run CHECK in CANDIDATE and record how it came out for STORY in SPACE.
CHECK and SETUP are lists of commands, (NAME . ARGV), as
`rat-kingdom-story-commands' returns.  Each list runs in order and
stops at the first command that fails.  If SETUP is non-nil it runs
first, and if one of its commands fails the check is recorded as
failed by its setup.  The outcome names the command that failed, or the
last that ran.  MORE is a property list recorded with the outcome.
Return at once; the outcome is recorded when the commands exit."
  (let* ((id (plist-get story :identity))
         (run-check
          (lambda ()
            (rat-kingdom-story--run-all
             space id "rat-kingdom-check" check candidate
             (lambda (exit output command)
               (apply #'rat-kingdom-story--record-check space story
                      (if (eql exit 0) "pass" "fail")
                      (append (rat-kingdom-story--command-facts
                               :check command check)
                              (list :exit exit :output output)
                              more)))))))
    (if (null setup)
        (funcall run-check)
      (rat-kingdom-story--run-all
       space id "rat-kingdom-setup" setup candidate
       (lambda (exit output command)
         (if (eql exit 0)
             (condition-case err
                 (funcall run-check)
               (error
                (apply #'rat-kingdom-story--record-check space story "fail"
                       (append (rat-kingdom-story--command-facts
                                :check (car check) check)
                               (list :exit nil
                                     :output (error-message-string err))
                               more))))
           (apply #'rat-kingdom-story--record-check space story "fail"
                  :reason "setup failed"
                  (append (rat-kingdom-story--command-facts
                           :setup command setup)
                          (list :check (cdar check) :exit exit
                                :output output)
                          more))))))))

(defun rat-kingdom-story--set-up (space story setup worktree)
  "Run SETUP in the new WORKTREE of the token STORY in SPACE.
SETUP is a list of commands, (NAME . ARGV), run in order until one
fails.  Return at once.  How it came out is recorded as a `setup'
tuple when it is over, naming the command that failed or the last that
ran; `rat-kingdom-story-set-up' takes it from there."
  (let ((scope (plist-get story :scope))
        (id (plist-get story :identity)))
    (rat-kingdom-space-retract space (list 'setup :scope scope :identity id))
    (rat-kingdom-story--run-all
     space id "rat-kingdom-setup" setup worktree
     (lambda (exit output command)
       (rat-kingdom-space-put space 'setup :scope scope :identity id
                              :owner (plist-get story :owner)
                              :payload (append
                                        (list :value (if (eql exit 0)
                                                         "pass"
                                                       "fail"))
                                        (rat-kingdom-story--command-facts
                                         :setup command setup)
                                        (list :exit exit :output output))
                              :actor "engine")))))

(defun rat-kingdom-story--setup-reason (outcome)
  "Return why a setup failed, from OUTCOME, its recorded outcome.
OUTCOME is a property list with `:setup', the argument list that
failed, `:command', its name if it has one, `:exit' and `:output'."
  (format "setup failed: the setup command %s exited with %s. The end of \
its output:\n%s"
          (rat-kingdom-story-command-text (plist-get outcome :setup)
                                          (plist-get outcome :command))
          (plist-get outcome :exit) (or (plist-get outcome :output) "")))

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

(defun rat-kingdom-story--integrate-mode (value)
  "Return VALUE, a :git :integrate mode as a symbol or string, as a symbol.
nil, or anything that is not a mode, is \=`merge'."
  (or (rat-kingdom-config--integrate-mode value) 'merge))

(defun rat-kingdom-story--integrate (candidate commit base mode message)
  "Put COMMIT into the CANDIDATE worktree by MODE, and say how it went.
CANDIDATE is detached at BASE, the target's head, or for \=`rebase' at
COMMIT.  MODE is \=`merge', \=`rebase' or \=`squash'; MESSAGE is the
merge commit's or the squashed commit's message.  Return nil if it
went in, the candidate's HEAD then being the result, or a property list
with `:reason' and `:output' saying why it did not."
  (pcase mode
    ('rebase
     ;; The user's settings for these would touch other branches or
     ;; reorder commits; unknown to an older Git, they are ignored.
     (if (rat-kingdom-git-ok-p candidate "-c" "rebase.updateRefs=false"
                               "-c" "rebase.autoSquash=false"
                               "-c" "rebase.autoStash=false" "rebase" base)
         nil
       (let ((files (ignore-errors
                      (rat-kingdom-git candidate "diff" "--name-only"
                                       "--diff-filter=U"))))
         (rat-kingdom-git-ok-p candidate "rebase" "--abort")
         (list :reason "rebase conflict" :output (or files "")))))
    ('squash
     (cond
      ((not (rat-kingdom-git-ok-p candidate "merge" "--squash" commit))
       (list :reason "merge conflict"
             :output (rat-kingdom-git candidate "diff" "--name-only"
                                      "--diff-filter=U")))
      ((rat-kingdom-git-ok-p candidate "diff" "--cached" "--quiet")
       (list :reason "nothing to integrate"
             :output (format "%s changes nothing against %s" commit base)))
      (t (rat-kingdom-git candidate "commit" "-q" "-m" message)
         nil)))
    (_
     (unless (rat-kingdom-git-ok-p candidate "merge" "--no-ff" "-m" message
                                   commit)
       (list :reason "merge conflict"
             :output (rat-kingdom-git candidate "diff" "--name-only"
                                      "--diff-filter=U"))))))

(defun rat-kingdom-story-check-candidate (space token path target commit
                                                candidate message check setup
                                                &optional integrate
                                                squash-message)
  "Put COMMIT onto TARGET in a fresh candidate worktree and check it there.
PATH is the repository.  CANDIDATE is the worktree to make; one
already there is removed first.  INTEGRATE, a :git :integrate mode,
says how COMMIT goes in; nil is \=`merge'.

  \=`merge'   the candidate is detached at TARGET's head and COMMIT
            merged with --no-ff, MESSAGE the merge commit's message
  \=`rebase'  the candidate is detached at COMMIT and rebased onto
            TARGET's head; a conflict is recorded as a failure with
            the reason \"rebase conflict\", and the rebase aborted
  \=`squash'  the candidate is detached at TARGET's head, COMMIT is
            merged with --squash and committed with SQUASH-MESSAGE; a
            squash that changes nothing fails with the reason
            \"nothing to integrate\"

CHECK and SETUP are the commands to run, each a list of (NAME . ARGV)
as `rat-kingdom-story-commands' returns: SETUP runs before CHECK, each
in order until a command fails, and with no CHECK there is nothing to
set up for, and the clean result passes at once.

The outcome is recorded in SPACE as a `checked' tuple under TOKEN's
`:scope', `:identity' and `:owner': a story's token, or an epic's
record when it lands.  A merge that conflicts fails with the reason
\"merge conflict\" and the files in conflict as its output.  The
outcome carries `:commit', `:base' (where TARGET was), `:candidate',
`:integrate', the mode, and, once integrated, `:head', the result, a
descendant of the base, so the target moves to it by compare-and-swap
whatever the mode.  A running check of the same identity is abandoned
first.

Return the base.  Return at once: the check's outcome is recorded when
it exits.  If the candidate cannot be made or the check begun, signal
the error, leaving no candidate and no process."
  (let* ((id (plist-get token :identity))
         (mode (rat-kingdom-story--integrate-mode integrate))
         (base (rat-kingdom-git-rev path target)))
    (rat-kingdom-story--abandon-check id)
    (rat-kingdom-story--remove-candidate path candidate)
    (make-directory (file-name-directory candidate) t)
    (rat-kingdom-git path "worktree" "add" "--detach" candidate
                     (if (eq mode 'rebase) commit base))
    (condition-case err
        (let ((facts (list :commit commit :base base :candidate candidate
                           :integrate (symbol-name mode))))
          (rat-kingdom-space-retract
           space (list 'checked :scope (plist-get token :scope) :identity id))
          (if-let* ((failure (rat-kingdom-story--integrate
                              candidate commit base mode
                              (if (eq mode 'squash)
                                  (or squash-message message)
                                message))))
              (apply #'rat-kingdom-story--record-check
                     space token "fail" (append failure facts))
            (setq facts (append facts
                                (list :head (rat-kingdom-git-rev candidate
                                                                 "HEAD"))))
            (if check
                (rat-kingdom-story--run-check space token check candidate facts
                                              setup)
              (apply #'rat-kingdom-story--record-check space token "pass"
                     :check nil facts)))
          base)
      (error
       (rat-kingdom-story--abandon-check id)
       (ignore-errors (rat-kingdom-story--remove-candidate path candidate))
       (signal (car err) (cdr err))))))

(defun rat-kingdom-story-squash-message (id title &optional body)
  "Return the message of the squashed commit of ID titled TITLE.
It is \"ID: TITLE\", then, if BODY is not blank, a blank line and BODY."
  (concat (format "%s: %s" id title)
          (if (and body (not (string-blank-p body)))
              (concat "\n\n" (string-trim body))
            "")))

(defun rat-kingdom-story--check (space story _workflow step)
  "Begin STEP for the taken token STORY in SPACE.
Put its commit onto its target in a candidate worktree, as the
configuration's :git :integrate says, and run the check there, after
the setup if there is one, by `rat-kingdom-story-check-candidate'.
The check is the configured one for a step `:check t', and for
`:check (NAME ...)' those commands, by
`rat-kingdom-story-named-commands'.  The commands are looked up with
`rat-kingdom-story-commands', and the mode with
`rat-kingdom-story-config', for the story's repository, epic and task,
when the check begins.  The outcome is recorded in SPACE as a
`checked' tuple."
  (let* ((id (plist-get story :identity))
         (payload (plist-get story :payload))
         (names (plist-get step :with))
         (check (if (consp names)
                    (rat-kingdom-story-named-commands space story names)
                  'configured))
         (repo (rat-kingdom-story--repo space story))
         (path (plist-get repo :path))
         (commit (or (plist-get payload :commit)
                     (error "There is no commit to check")))
         (candidate (expand-file-name
                     (format "candidates/%s/%s" (plist-get repo :name) id)
                     rat-kingdom-directory))
         (base (rat-kingdom-story-check-candidate
                space story path (rat-kingdom-story-target space story) commit
                candidate (format "Merge %s: %s" id (plist-get payload :title))
                (if (eq check 'configured)
                    (rat-kingdom-story-commands space :check (plist-get repo :name)
                                                (plist-get payload :epic)
                                                (plist-get payload :task))
                  check)
                (rat-kingdom-story-commands space :setup (plist-get repo :name)
                                            (plist-get payload :epic)
                                            (plist-get payload :task))
                (plist-get (rat-kingdom-story-config space story :git)
                           :integrate)
                (rat-kingdom-story-squash-message
                 id (plist-get payload :title) (plist-get payload :summary)))))
    (condition-case err
        (rat-kingdom-story--wait space story step "check"
                                 :candidate candidate :base base)
      (error
       (rat-kingdom-story--abandon-check id)
       (ignore-errors (rat-kingdom-story--remove-candidate path candidate))
       (signal (car err) (cdr err))))))

(defun rat-kingdom-story--check-reason (checked &optional target)
  "Return what a worker is told when the check recorded as CHECKED failed.
TARGET is the branch the work goes into."
  (let ((output (plist-get checked :output)))
    (pcase (plist-get checked :reason)
      ("merge conflict"
       (format "merge conflict: your branch no longer merges cleanly into \
the target branch. Merge the target branch into your branch, resolve the \
conflicts, commit, and finish again. Files in conflict:\n%s"
               (or output "unknown")))
      ("rebase conflict"
       (format "rebase conflict: your branch no longer rebases cleanly onto \
the target branch. Rebase your branch onto %s, resolve the conflicts, \
commit, and finish again. Files in conflict:\n%s"
               (or target "the target branch")
               (if (string-blank-p (or output "")) "unknown" output)))
      ("nothing to integrate"
       (format "nothing to integrate: your branch makes no change against \
%s, so there is nothing to squash into it. Commit the work the story asks \
for, and finish again."
               (or target "the target branch")))
      ("setup failed"
       (concat "The check did not run because the repository's "
               (rat-kingdom-story--setup-reason checked)
               "\nIt ran in a fresh worktree with your branch merged, before \
the check."))
      (_
       (format "check failed: after your branch was merged, the command %s \
exited with %s. The end of its output:\n%s"
               (rat-kingdom-story-command-text (plist-get checked :check)
                                               (plist-get checked :command))
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

;;;; Running commands in the worktree

(defun rat-kingdom-story--record-ran (space story value &rest more)
  "Record in SPACE that the `:run' step of the token STORY came out as VALUE.
VALUE is \"pass\" or \"fail\".  MORE is a property list for the payload."
  (rat-kingdom-space-put space 'ran :scope (plist-get story :scope)
                         :identity (plist-get story :identity)
                         :owner (plist-get story :owner)
                         :payload (append (list :value value) more)
                         :actor "engine"))

(defun rat-kingdom-story--commit-run (worktree names)
  "Commit what the commands NAMES changed in WORKTREE, if anything.
Paths under `rat-kingdom-run-ignored-paths' are left out.  Return nil
if it went well, or Git's message if the commit failed."
  (when (rat-kingdom-run--dirty-paths worktree)
    (condition-case err
        (progn
          (apply #'rat-kingdom-git worktree "add" "-A" "--" "."
                 (mapcar (lambda (prefix) (concat ":(exclude)" prefix))
                         rat-kingdom-run-ignored-paths))
          (rat-kingdom-git worktree "commit" "-q" "--no-verify" "-m"
                           (concat "rat-kingdom: run " (string-join names " ")))
          nil)
      (error (error-message-string err)))))

(defun rat-kingdom-story--start-run (space story commands worktree)
  "Run COMMANDS in WORKTREE, the worktree of the token STORY in SPACE.
COMMANDS is a list of (NAME . ARGV), run in order until one fails.  If
all succeed, whatever they changed is committed on the story's branch.
Return at once; the outcome is recorded as a `ran' tuple when they are
over."
  (let ((names (mapcar #'car commands)))
    (rat-kingdom-space-retract
     space (list 'ran :scope (plist-get story :scope)
                 :identity (plist-get story :identity)))
    (rat-kingdom-story--run-all
     space (plist-get story :identity) "rat-kingdom-run" commands worktree
     (lambda (exit output command)
       (let* ((facts (list :names names :command (car command)
                           :argv (cdr command) :exit exit :output output))
              (failure (if (eql exit 0)
                           (rat-kingdom-story--commit-run worktree names)
                         'failed))
              (head (ignore-errors (rat-kingdom-git-rev worktree "HEAD"))))
         (cond
          ((null failure)
           (apply #'rat-kingdom-story--record-ran space story "pass"
                  :commit head facts))
          ((stringp failure)
           (apply #'rat-kingdom-story--record-ran space story "fail"
                  :reason "commit failed" :commit head
                  (plist-put facts :output failure)))
          (t
           (apply #'rat-kingdom-story--record-ran space story "fail"
                  :reason "run failed" :commit head facts))))))))

(defun rat-kingdom-story--run-step (space story _workflow step &optional again)
  "Begin STEP, a `:run' step, for the taken token STORY in SPACE.
Its commands, resolved by `rat-kingdom-story-named-commands', run in
the story's own worktree, which must be clean and at the story's
commit, by `rat-kingdom-story--start-run'.  The story waits for
\"run\".  AGAIN non-nil runs them again after Emacs stopped while they
ran, whatever the worktree is like."
  (let* ((id (plist-get story :identity))
         (payload (plist-get story :payload))
         (commands (rat-kingdom-story-named-commands
                    space story (plist-get step :with)))
         (worktree (plist-get payload :worktree))
         (commit (plist-get payload :commit)))
    (unless (and worktree (file-directory-p worktree))
      (error "The story has no worktree to run %s in"
             (string-join (mapcar #'car commands) " ")))
    (unless again
      (when-let* ((dirty (rat-kingdom-run--dirty-paths worktree)))
        (error "The worktree %s has uncommitted or untracked files: %s"
               worktree (string-join dirty ", ")))
      (let ((head (rat-kingdom-git-rev worktree "HEAD")))
        (when (and commit (not (equal head commit)))
          (error "The worktree %s is at %s, not at %s, the commit of the \
story" worktree head commit))))
    (rat-kingdom-story--start-run space story commands worktree)
    (condition-case err
        (rat-kingdom-story--wait space story step "run")
      (error
       (rat-kingdom-story--abandon-check id)
       (signal (car err) (cdr err))))))

(defun rat-kingdom-story--run-reason (ran)
  "Return what a worker is told when the `:run' recorded as RAN failed."
  (if (equal (plist-get ran :reason) "commit failed")
      (format "run failed: the commands %s succeeded, but committing what \
they changed failed:\n%s"
              (string-join (plist-get ran :names) " ")
              (or (plist-get ran :output) ""))
    (format "run failed: the command %s exited with %s. The end of its \
output:\n%s"
            (rat-kingdom-story-command-text (plist-get ran :argv)
                                            (plist-get ran :command))
            (plist-get ran :exit) (or (plist-get ran :output) ""))))

;;;; Gates

(defun rat-kingdom-story--gate (space story _workflow step)
  "Begin STEP, a `:gate' step, for the taken token STORY in SPACE.
The story waits for \"gate\", with no process.  A gate (:after
SECONDS) records on the token `:until', the time it opens, and sets a
timer that calls `rat-kingdom-story-open-gates' then.  A gate (:signal
NAME) records NAME, as a string, as `:signal'; the reaction
`rat-kingdom-story-signalled' opens it."
  (pcase (plist-get step :with)
    (`(:after ,seconds)
     (let ((until (+ (funcall rat-kingdom-space-now-function) seconds)))
       (rat-kingdom-story--wait space story step "gate" :until until)
       (rat-kingdom-story--gate-timer space (plist-get story :identity)
                                      seconds)))
    (`(:signal ,name)
     (rat-kingdom-story--wait space story step "gate"
                              :signal (rat-kingdom-workflow--name name)))
    (value (error "A gate waits for (:after SECONDS) or (:signal NAME), \
not %S" value))))

(defun rat-kingdom-story--cancel-gate-timer (id)
  "Cancel the timer that opens the timed gate of the story ID, if any."
  (when-let* ((timer (gethash id rat-kingdom-story--gate-timers)))
    (remhash id rat-kingdom-story--gate-timers)
    (cancel-timer timer)))

(defun rat-kingdom-story--gate-timer (space id seconds)
  "Call `rat-kingdom-story-open-gates' on SPACE in SECONDS, for the story ID.
A timer the story had is replaced."
  (rat-kingdom-story--cancel-gate-timer id)
  (puthash id
           (run-at-time (max 0 seconds) nil
                        (lambda ()
                          (remhash id rat-kingdom-story--gate-timers)
                          (rat-kingdom-story-open-gates space)))
           rat-kingdom-story--gate-timers))

(defun rat-kingdom-story-open-gates (space)
  "Open every timed gate in SPACE whose time has come.
Each story waiting for \"gate\" whose `:until' has passed leaves its
step by `:to', in its own transaction.  Return the ids of the stories
moved on.  A space that is closed is left alone."
  (let (opened)
    (when (rat-kingdom-space-db space)
      (let ((now (funcall rat-kingdom-space-now-function)))
        (dolist (story (rat-kingdom-space-scan space '(story :awaiting gate)))
          (let ((until (plist-get (plist-get story :payload) :until)))
            (when (and (numberp until) (<= until now))
              (with-demoted-errors "rat-kingdom: opening a gate: %S"
                (rat-kingdom-space-with-transaction space
                  (when (rat-kingdom-space-in
                         space (list 'story :id (plist-get story :id))
                         :actor "engine")
                    (rat-kingdom-story--cancel-gate-timer
                     (plist-get story :identity))
                    (rat-kingdom-story--leave space story :to)
                    (push (plist-get story :identity) opened)))))))))
    (nreverse opened)))

(defun rat-kingdom-story-signal (space id name &optional actor)
  "Send the signal NAME to the story ID in SPACE.
It is a linear `signal' tuple scoped to the story's repository, named
and owned by the story, with `:name' NAME, written by ACTOR.  A gate
\(:signal NAME) of the story takes it and opens, now if the story waits
there, or else when it reaches such a gate; the signal is kept until
then or until the story ends.  Signal an error for a story that is not
in progress or a blank NAME.  Return non-nil if the story waits at a
gate for NAME now."
  (let* ((story (or (rat-kingdom-story-get space id)
                    (error "There is no story in progress called %s" id)))
         (name (and name (string-trim (rat-kingdom-workflow--name name)))))
    (when (or (null name) (string-empty-p name))
      (error "A signal needs a name"))
    (let ((waiting (rat-kingdom-space-rd
                    space (list 'story :identity id :awaiting "gate"
                                :signal name))))
      (rat-kingdom-space-out space 'signal :scope (plist-get story :scope)
                             :identity id :owner (plist-get story :owner)
                             :payload (list :name name)
                             :actor (or actor "user"))
      (and waiting t))))

;;;; Merging

(defun rat-kingdom-story--clean-up (space story path head)
  "Remove what the integrated token STORY left behind in SPACE.
PATH is its repository, whose target branch is now at HEAD.  The story
branch is deleted if it is an ancestor of HEAD, as after a merge, or,
when the story was integrated by \=`rebase' or \=`squash' (its
`:integrate'), if its tip is still the commit that was checked, its
`:commit'; otherwise someone has added to it, and it is kept.  Failures
are reported and otherwise ignored: the work is already merged."
  (let* ((payload (plist-get story :payload))
         (branch (plist-get payload :branch))
         (ref (and branch (concat "refs/heads/" branch))))
    (with-demoted-errors "rat-kingdom: cleaning up: %S"
      (rat-kingdom-story--remove-candidate path (plist-get payload :candidate)))
    (with-demoted-errors "rat-kingdom: cleaning up: %S"
      (rat-kingdom-run-stop space (plist-get payload :run)))
    (with-demoted-errors "rat-kingdom: cleaning up: %S"
      ;; Not forced: a worktree the worker dirtied after reporting stays.
      (rat-kingdom-git path "worktree" "remove" (plist-get payload :worktree))
      (when (and ref
                 (or (rat-kingdom-git-ancestor-p path ref head)
                     (and (memq (rat-kingdom-story--integrate-mode
                                 (plist-get payload :integrate))
                                '(rebase squash))
                          (equal (ignore-errors (rat-kingdom-git-rev path ref))
                                 (plist-get payload :commit)))))
        (rat-kingdom-git path "branch" "-D" branch)))))

(defun rat-kingdom-story--merge (space story _workflow step)
  "Begin STEP for the taken token STORY in SPACE.
Move the target branch to the checked merge, unless the target has
moved since the check."
  (let* ((id (plist-get story :identity))
         (payload (plist-get story :payload))
         (repo (rat-kingdom-story--repo space story))
         (path (plist-get repo :path))
         (target (rat-kingdom-story-target space story))
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
  (let* ((workflow (rat-kingdom-story--workflow space story))
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
                     (:merge #'rat-kingdom-story--merge)
                     (:run #'rat-kingdom-story--run-step)
                     (:gate #'rat-kingdom-story--gate)
                     (kind (error "Step %s of kind %s is not supported yet"
                                  (plist-get step :name) kind)))
                   space story workflow step)
        (error
         (rat-kingdom-story--fail
          space story
          (format "Step %s could not be begun: %s" (plist-get step :name)
                  (error-message-string err)))))))))

(defun rat-kingdom-story--step (space story)
  "Return the step the waiting token STORY in SPACE is in, or nil."
  (when-let* ((workflow (rat-kingdom-story--workflow space story)))
    (rat-kingdom-workflow-step-named
     workflow (plist-get (plist-get story :payload) :step))))

(defun rat-kingdom-story--leave (space story outcome &rest changes)
  "Move the waiting token STORY in SPACE to where OUTCOME of its step leads.
CHANGES is merged into its payload."
  (if-let* ((step (rat-kingdom-story--step space story)))
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
               (rat-kingdom-story--setup-reason setup))))))

(rat-kingdom-defreaction rat-kingdom-story-checked
  "Move on a story whose check has come out."
  :take (story :scope $repo :identity $story :awaiting check)
  :read (checked :scope $repo :identity $story :value $value)
  (let* ((story (car rat-kingdom-reaction-tuples))
         (checked (plist-get (cadr rat-kingdom-reaction-tuples) :payload)))
    (if (equal $value "pass")
        (rat-kingdom-story--leave rat-kingdom-reaction-space story :pass
                                  :head (plist-get checked :head)
                                  :base (plist-get checked :base)
                                  :integrate (plist-get checked :integrate))
      (rat-kingdom-story--leave
       rat-kingdom-reaction-space story :fail
       :reason (rat-kingdom-story--check-reason
                checked (ignore-errors
                          (rat-kingdom-story-target rat-kingdom-reaction-space
                                                    story)))))))

(rat-kingdom-defreaction rat-kingdom-story-ran
  "Move on a story whose `:run' step's commands have come out."
  :take (story :scope $repo :identity $story :awaiting run)
  :read (ran :scope $repo :identity $story :value $value)
  (let* ((story (car rat-kingdom-reaction-tuples))
         (ran (plist-get (cadr rat-kingdom-reaction-tuples) :payload)))
    (if (equal $value "pass")
        (rat-kingdom-story--leave rat-kingdom-reaction-space story :pass
                                  :commit (or (plist-get ran :commit)
                                              (plist-get (plist-get story :payload)
                                                         :commit)))
      (rat-kingdom-story--leave rat-kingdom-reaction-space story :fail
                                :reason (rat-kingdom-story--run-reason ran)))))

(rat-kingdom-defreaction rat-kingdom-story-signalled
  "Open the gate of a story that waits for a signal it has been sent."
  :take ((story :scope $repo :identity $story :awaiting gate :signal $name)
         (signal :scope $repo :identity $story :name $name))
  (rat-kingdom-story--leave rat-kingdom-reaction-space
                            (car rat-kingdom-reaction-tuples) :to))

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
  "Stop whatever is in progress for the token STORY in SPACE.
That is its check, setup or run, its worker, and the timer of its gate."
  (rat-kingdom-story--abandon-check (plist-get story :identity))
  (rat-kingdom-story--cancel-gate-timer (plist-get story :identity))
  (when-let* ((run (plist-get (plist-get story :payload) :run)))
    (rat-kingdom-run-stop space run)))

(defun rat-kingdom-story-move (space id place &optional note actor)
  "Put the story ID in SPACE at PLACE, whatever it was doing.
Its worker is stopped and a running check is abandoned; no file is
touched.  NOTE says why and reaches the next worker.  ACTOR is who
moved it.  The step taken from PLACE then begins as usual."
  (let* ((story (or (rat-kingdom-story-get space id)
                    (error "There is no story called %s" id)))
         (workflow (or (rat-kingdom-story--workflow space story)
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
      (rat-kingdom-story--event
       space 'cancelled
       (rat-kingdom-story--put space story :phase "cancelled" :step nil
                               :awaiting nil))
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

(defun rat-kingdom-story--time-limit (space story step awaiting)
  "Return the seconds STEP of the token STORY in SPACE may take, or nil.
AWAITING is what the story waits for.  A setup in a worker's worktree
may take as long as a check.  Otherwise a step's own `:timeout' wins;
then the configuration's `:timeouts' for the story's repository, epic
and task: `:worker' for a step that spawns a worker, `:check' for a
check or a run.  A gate has only its own `:timeout'.  A step of another
kind has the limit `rat-kingdom-story-timeouts' gives it, if any."
  (let ((timeouts (and (or (equal awaiting "setup") step)
                       (rat-kingdom-story-config space story :timeouts))))
    (if (equal awaiting "setup")
        (plist-get timeouts :check)
      (and step
           (or (plist-get step :timeout)
               (pcase (plist-get step :kind)
                 (:spawn (plist-get timeouts :worker))
                 ((or :check :run) (plist-get timeouts :check))
                 (:gate nil)
                 (kind (alist-get kind rat-kingdom-story-timeouts))))))))

(defun rat-kingdom-story-watch (space)
  "Report as stuck each story in SPACE that will not move by itself.
That is a story whose step or setup has run past its time, whose check,
setup or run is not running, whose worker is gone, whose workflow is no
longer defined, or which no reaction has picked up.
A story queued for a free worker is not stuck; the queue is served
first, in case a worker is free.  Nor is a story at a gate, which has
no process, unless its step has a `:timeout' and has run past it.
Timed gates whose time has come are opened first, by
`rat-kingdom-story-open-gates'.  Return how many were newly reported."
  (rat-kingdom-story-open-gates space)
  (rat-kingdom-story-dequeue space)
  (let ((now (funcall rat-kingdom-space-now-function))
        (count 0))
    (dolist (story (rat-kingdom-story-list space))
      (let* ((payload (plist-get story :payload))
             (id (plist-get story :identity))
             (waited (- now (or (plist-get payload :entered) now)))
             (step (rat-kingdom-story--step space story))
             (awaiting (plist-get payload :awaiting))
             (limit (rat-kingdom-story--time-limit space story step
                                                   awaiting))
             (reason
              (pcase (plist-get payload :phase)
                ((and (or "enter" "wait")
                      (guard (not (rat-kingdom-story--workflow space story))))
                 (format "Its workflow %s is not defined for %s any more, \
so it cannot move. Restore the workflow's file, or cancel the story."
                         (plist-get payload :workflow)
                         (plist-get story :scope)))
                ("enter"
                 (and (> waited 60)
                      (format "It arrived at %s %d seconds ago and no step \
has begun. Reactions may be off or failing." (plist-get payload :at) waited)))
                ("wait"
                 (cond
                  ((equal awaiting rat-kingdom-story-free-worker)
                   nil)
                  ((and (member awaiting '("check" "setup" "run"))
                        (not (gethash id rat-kingdom-story--checks))
                        (not (rat-kingdom-space-rd
                              space (list (pcase awaiting
                                            ("check" 'checked)
                                            ("run" 'ran)
                                            (_ 'setup))
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
given one if one is free.  The commands of a `:run' step that was
running are run again, in the worktree as it is; such a story counts
among `:checks'.  Timed gates whose time has passed are opened.
Return a property list: `:runs', the ids of the interrupted runs,
`:checks', the ids of the stories checked or run again, and `:setups',
the ids of the stories whose setup is run again."
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
    (dolist (story (rat-kingdom-space-scan space '(story :awaiting run)))
      (let ((id (plist-get story :identity)))
        (unless (or (gethash id rat-kingdom-story--checks)
                    (rat-kingdom-space-rd space (list 'ran :identity id)))
          (rat-kingdom-space-with-transaction space
            (when (rat-kingdom-space-in
                   space (list 'story :id (plist-get story :id))
                   :actor "engine")
              (if-let* ((step (rat-kingdom-story--step space story)))
                  (condition-case err
                      (rat-kingdom-story--run-step space story nil step t)
                    (error
                     (rat-kingdom-story--fail
                      space story
                      (format "Step %s could not be begun again: %s"
                              (plist-get step :name)
                              (error-message-string err)))))
                (rat-kingdom-story--leave space story :pass))
              (push id checks))))))
    (rat-kingdom-story-open-gates space)
    ;; A timed gate still shut gets its timer again.
    (dolist (story (rat-kingdom-space-scan space '(story :awaiting gate)))
      (when-let* ((until (plist-get (plist-get story :payload) :until))
                  ((numberp until))
                  (id (plist-get story :identity))
                  ((not (gethash id rat-kingdom-story--gate-timers))))
        (rat-kingdom-story--gate-timer
         space id (- until (funcall rat-kingdom-space-now-function)))))
    (list :runs runs :checks (nreverse checks) :setups (nreverse setups))))

(provide 'rat-kingdom-story)
;;; rat-kingdom-story.el ends here
