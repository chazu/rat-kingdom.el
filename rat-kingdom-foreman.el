;;; rat-kingdom-foreman.el --- An agent that runs one epic for the king -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Chaz Straney

;; Author: Chaz Straney <chaz.straney@gmail.com>
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A foreman is an optional long-lived agent that runs one epic on the
;; king's behalf (DESIGN.md, section 9), so that a big epic does not
;; flood the king with reviews.  The engine still does the chores: it
;; starts the epic's stories as their tasks become ready, checks and
;; merges them.  The foreman reviews them, steers their workers, and
;; reports to the king.
;;
;; A foreman is a run like the king's, with the id F-EPIC, the role
;; `foreman', and `:epic' and `:repo' in its record.  It runs Claude
;; Code unless it is started with another agent; the user's
;; `rat-kingdom-default-agent' is for workers, not for it.  It works in
;; the repository's checkout, which it is told not to edit.  The king
;; starts one with `foreman_start' (or `epic_start' with `foreman'), for
;; a running or paused epic, and stops it with `foreman_stop'.  The
;; epic's record keeps its id as `:foreman'.  It stops by itself when
;; its epic is done or cancelled.
;;
;; While an epic's foreman runs, news of the epic's stories (review
;; requests, stories that stopped or look stuck, held tasks, merges) is
;; addressed to it instead of the king, through
;; `rat-kingdom-king-route-functions'.  It is given that news the way
;; the king is given its own, between its turns
;; (`rat-kingdom-king-deliver-to').  The king still hears of the epic as
;; a whole: that it is done, that it is ready to land, and whatever the
;; foreman reports.  When the foreman is not running, news goes to the
;; king again; if it died rather than being stopped, the news says so.
;; News that waited for a foreman that stopped is given to the king, so
;; none is lost.
;;
;; A foreman's tools are the king's, limited to its epic: each refuses a
;; story that is not of the epic and a task that is not one of its
;; tasks.  They share the king's code, which takes a scope check (see
;; `rat-kingdom-king-story-start').  It has no `publish' and none of the
;; king's other tools.
;;
;; A foreman that Emacs cut off is taken up again, in the same session,
;; by `rat-kingdom-foreman-reconcile' when `rat-kingdom-mode' starts.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'rat-kingdom-space)
(require 'rat-kingdom-reaction)
(require 'rat-kingdom-mcp)
(require 'rat-kingdom-run)
(require 'rat-kingdom-agent-shell)
(require 'rat-kingdom-story)
(require 'rat-kingdom-task)
(require 'rat-kingdom-king)
(require 'rat-kingdom-fact)
(require 'rat-kingdom-message)
(require 'rat-kingdom-epic)

(defcustom rat-kingdom-foreman-instructions
  "You are the foreman of the epic {epic} ({title}) in the repository \
{repo}, in a rat-kingdom swarm running inside the user's Emacs. You run this \
one epic for the king, the agent the user talks to, so that the king is not \
flooded with reviews.

The epic's goal:
{goal}

How it works:
- Each task of the epic becomes a story: one task for one worker, a separate \
agent in its own Git worktree and branch. You never see a worker's session; \
you see what it reports.
- Stories start by themselves: the engine starts a story for each task of \
the epic as the task becomes ready, following the dependencies, checks the \
work and merges it. You do not start them, except to start one at once with \
story_start.
- The engine tells you what happens to the epic's stories. A message that \
begins with [rat-kingdom] comes from the engine, not from the user or the \
king.

Your tools are those of the rat-kingdom server: {tools}. Each works only on \
this epic: on its stories, and on its tasks.

What to do:
- Review each story you are asked to: read the diff with story_diff and the \
worker's report with story_show, judge it against the story and the epic's \
goal, and give a verdict: pass, or fix with notes exact enough for a worker to \
act on.
- Use tell to steer a worker while it works: a correction, more detail, or a \
change of plan.
- When a story is stuck or stopped, or a task is held, decide: let the engine \
start a held task again with epic_retry, add a task to the epic with \
task_create, or report to the king. Only the king can move or cancel a story.
- Report to the king with report when the epic is held up in a way you \
cannot fix, and briefly at milestones, such as when half of it is merged. Do \
not report every story.
- The king, not you, talks to the user, and reviews the whole epic before it \
lands if it has a feature branch.

Rules:
- Never push, with git, gh or any other way: pushing is blocked in your \
session and will fail, so do not try to work around it.
- Do not write code yourself, and never edit files: your working directory \
is the user's checkout of {repo}, read only for you. Reading files and \
running read-only commands to understand a diff is fine.
- Keep what you write short."
  "What a foreman is told when its session starts.
In it, {epic} is replaced by the epic's id, {title} by its title,
{repo} by its repository, {goal} by its description in the tracker,
and {tools} by the names of the foreman's tools; see
`rat-kingdom-foreman-instructions'."
  :type 'string
  :group 'rat-kingdom)

;;;; Who the foreman is

(defun rat-kingdom-foreman-id (epic)
  "Return the id of the run of the foreman of the epic EPIC."
  (concat rat-kingdom-foreman-id-prefix epic))

(defun rat-kingdom-foreman--running-p (space id)
  "Return non-nil if the foreman ID in SPACE is running or about to.
That is if its agent runs in this Emacs, or its run is `starting', or
it is `working' but was cut off by a restart that has not been
reconciled yet, which will take it up again."
  (or (rat-kingdom-run-live-p id)
      (member (plist-get (rat-kingdom-run-get space id) :state)
              '("starting" "working"))))

(defun rat-kingdom-foreman--reviews (space record)
  "Return the ids of the stories of the epic RECORD in SPACE waiting for review."
  (mapcar (lambda (story) (plist-get story :identity))
          (rat-kingdom-space-scan
           space (list 'story :scope (plist-get record :scope)
                       :epic (plist-get record :identity)
                       :awaiting "review"))))

(defun rat-kingdom-foreman--goal (space record)
  "Return the description of the epic RECORD in SPACE, from its tracker."
  (condition-case err
      (or (plist-get (rat-kingdom-task-show
                      (rat-kingdom-epic--adapter space (plist-get record :scope))
                      (plist-get record :identity))
                     :description)
          "(none given)")
    (error (format "(the tracker could not be read: %s)"
                   (rat-kingdom-epic--message err)))))

(defun rat-kingdom-foreman-instructions (space record)
  "Return `rat-kingdom-foreman-instructions' for the epic RECORD in SPACE."
  (let ((text rat-kingdom-foreman-instructions))
    (dolist (pair (list (cons "{tools}" (rat-kingdom-king-tool-names 'foreman))
                        (cons "{epic}" (plist-get record :identity))
                        (cons "{title}" (rat-kingdom-epic--payload record
                                                                   :title))
                        (cons "{repo}" (plist-get record :scope))
                        ;; Last, so that nothing in it is replaced.
                        (cons "{goal}" (rat-kingdom-foreman--goal space record))))
      (setq text (string-replace (car pair) (format "%s" (cdr pair)) text)))
    text))

(defun rat-kingdom-foreman-status (space record)
  "Return what the foreman of the epic RECORD in SPACE is shown by `status'.
That is the epic as `epic_show' shows it, and the lines of its stories
in progress as the king's `status' gives them."
  (let ((stories (rat-kingdom-epic--stories space (plist-get record :scope)
                                            (plist-get record :identity))))
    (concat (rat-kingdom-epic-show space (plist-get record :identity))
            "\n\nIts stories in progress:\n"
            (if stories
                (mapconcat (lambda (story)
                             (rat-kingdom-king--story-line space story))
                           stories "\n")
              "- none"))))

(defun rat-kingdom-foreman--prompt (space record resumed)
  "Return the first prompt for the foreman of the epic RECORD in SPACE.
RESUMED is non-nil if its earlier session is being taken up again."
  (let ((reviews (rat-kingdom-foreman--reviews space record)))
    (concat
     (if resumed
         (format "[rat-kingdom] Your session was restarted; you are still \
the foreman of the epic %s. Tools you called before the restart may need \
calling again. This is how the epic stands now:\n\n"
                 (rat-kingdom-epic--name record))
       (concat (rat-kingdom-foreman-instructions space record)
               "\n\nThis is how the epic stands now:\n\n"))
     (condition-case err
         (rat-kingdom-foreman-status space record)
       (error (format "(It could not be shown: %s)"
                      (error-message-string err))))
     (if reviews
         (format "\n\nWaiting for your review now: %s."
                 (string-join reviews ", "))
       "")
     "\n\nSay in a line that you are ready. Review any story waiting for \
review, then wait for news from the engine.")))

;;;; Starting and stopping

(defun rat-kingdom-foreman--launch (space record agent prompt &optional session)
  "Record the run of the foreman of the epic RECORD in SPACE, to be started.
It runs AGENT in the repository's checkout and is given PROMPT.
SESSION, if given, is the session to take up again.  The epic's record
keeps the run's id as `:foreman'.  Return the id."
  (let* ((repo (plist-get record :scope))
         (epic (plist-get record :identity))
         (id (rat-kingdom-foreman-id epic))
         (path (plist-get (or (rat-kingdom-repo-get space repo)
                              (error "The repository %s is no longer \
registered" repo))
                          :path)))
    (rat-kingdom-space-with-transaction space
      (rat-kingdom-space-retract space (list 'run :identity id)
                                 :actor rat-kingdom-king-id)
      (rat-kingdom-run-create space :id id :repo repo :role 'foreman
                              :agent agent :worktree path :prompt prompt
                              :resume session)
      (rat-kingdom-run-update space id :epic epic)
      (rat-kingdom-epic--update space repo epic
                                (lambda (payload)
                                  (plist-put payload :foreman id))
                                rat-kingdom-king-id))
    id))

(defun rat-kingdom-foreman-start (space epic &optional agent)
  "Start a foreman for the running or paused epic EPIC in SPACE.
It runs AGENT, a name from `rat-kingdom-agent-names', by default
Claude Code.  Signal an error if the epic is not running or paused, or
already has a foreman running.  Return the foreman's run id.  The
foreman's agent is started by the reaction `rat-kingdom-run-launch'."
  (let* ((record (rat-kingdom-epic--get space epic))
         (id (rat-kingdom-foreman-id epic))
         (state (rat-kingdom-epic--payload record :state)))
    (unless (member state '("running" "paused"))
      (error "The epic %s is %s; a foreman runs only an epic that is running \
or paused" epic state))
    (when (rat-kingdom-foreman--running-p space id)
      (error "The epic %s already has a foreman running, %s" epic id))
    (rat-kingdom-foreman--launch
     space record
     (if (rat-kingdom-epic--blank-p agent)
         rat-kingdom-agent-shell-fallback-agent
       (rat-kingdom-agent-name agent))
     (rat-kingdom-foreman--prompt space record nil))))

(defun rat-kingdom-foreman--hand-over (space id why)
  "Give the king in SPACE the messages that wait for the foreman ID.
WHY says what happened to the foreman, as \"was stopped\".  Each
message is readdressed in one transaction, so none is lost.  Return
how many there were."
  (let ((messages (rat-kingdom-space-scan space (list 'message :to id))))
    (when messages
      (rat-kingdom-space-with-transaction space
        (dolist (message messages)
          (let ((payload (copy-sequence (plist-get message :payload))))
            (rat-kingdom-space-retract space (list 'message
                                                   :id (plist-get message :id))
                                       :actor "engine")
            (rat-kingdom-space-out
             space 'message :scope (plist-get message :scope)
             :payload (plist-put
                       (plist-put payload :to rat-kingdom-king-id)
                       :text (format "(This was for the foreman %s, which %s \
before it read it.)\n%s"
                                     id why (plist-get payload :text)))
             :actor "engine")))))
    (length messages)))

(defun rat-kingdom-foreman--tell-king (space record text)
  "Leave the king a message in SPACE about the epic RECORD, saying TEXT."
  (rat-kingdom-space-out space 'message :scope (plist-get record :scope)
                         :payload (list :to rat-kingdom-king-id :text text)
                         :actor "engine"))

(defun rat-kingdom-foreman--reviews-phrase (space record)
  "Return a sentence naming the stories of RECORD in SPACE that wait for review.
Return the empty string if none does."
  (if-let* ((reviews (rat-kingdom-foreman--reviews space record)))
      (format " Waiting for your review now: %s." (string-join reviews ", "))
    ""))

(defun rat-kingdom-foreman-stop (space epic)
  "Stop the foreman of the epic EPIC in SPACE.
News of the epic's stories goes to the king again, and so does any news
that waited for the foreman.  Signal an error if it has none running.
Return what `foreman_stop' answers."
  (let* ((record (rat-kingdom-epic--get space epic))
         (id (or (rat-kingdom-epic--payload record :foreman)
                 (rat-kingdom-foreman-id epic))))
    (unless (rat-kingdom-foreman--running-p space id)
      (error "The epic %s has no foreman running" epic))
    (rat-kingdom-run-stop space id)
    (let ((handed (rat-kingdom-foreman--hand-over space id "was stopped")))
      (format "Stopped the foreman %s of the epic %s. News of its stories \
comes to you again, and you review them.%s%s"
              id (rat-kingdom-epic--name record)
              (rat-kingdom-foreman--reviews-phrase space record)
              (if (> handed 0)
                  (format " %d %s that waited for the foreman will be given \
to you." handed (if (= handed 1) "message" "messages"))
                "")))))

;;;; Routing news

(defun rat-kingdom-foreman--why-not (run)
  "Return why the foreman whose run record is RUN is not running, in words."
  (pcase (plist-get run :state)
    ("exited" (if-let* ((reason (plist-get run :error)))
                  (format "could not be started (%s)" reason)
                "exited"))
    ("stopped" "was stopped")
    ("interrupted" "was cut off when Emacs stopped")
    (state (format "is %s" state))))

(defun rat-kingdom-foreman--route (space repo epic)
  "Send news of the work of the epic EPIC of REPO in SPACE to its foreman.
For `rat-kingdom-king-route-functions'.  While the live epic has a
foreman running, return its run id.  If its foreman died, return the
king with a note saying so.  A foreman that was stopped on purpose, or
an epic with none, leaves the news to the king."
  (when-let* ((record (rat-kingdom-epic-record space epic repo))
              ((rat-kingdom-epic--live-p record))
              (id (rat-kingdom-epic--payload record :foreman))
              (run (rat-kingdom-run-get space id)))
    (cond ((rat-kingdom-foreman--running-p space id) (list id))
          ((equal (plist-get run :state) "stopped") nil)
          (t (cons rat-kingdom-king-id
                   (format "(This comes to you because the foreman %s of the \
epic %s %s; foreman_start starts another.)"
                           id epic (rat-kingdom-foreman--why-not run)))))))

(add-hook 'rat-kingdom-king-route-functions #'rat-kingdom-foreman--route)

;;;; When a foreman or its epic ends

(defun rat-kingdom-foreman--epic-ended (space record)
  "Stop the foreman of the epic RECORD in SPACE, which has ended.
Tell the king.  For `rat-kingdom-epic-ended-functions'."
  (when-let* ((id (rat-kingdom-epic--payload record :foreman))
              ((rat-kingdom-foreman--running-p space id)))
    (let ((state (rat-kingdom-epic--payload record :state)))
      (rat-kingdom-run-stop space id)
      (rat-kingdom-foreman--hand-over
       space id (format "stopped when the epic was %s" state))
      (rat-kingdom-foreman--tell-king
       space record
       (format "The foreman %s of the epic %s has stopped, as the epic is %s."
               id (rat-kingdom-epic--name record) state)))))

(add-hook 'rat-kingdom-epic-ended-functions #'rat-kingdom-foreman--epic-ended)

(defun rat-kingdom-foreman--run-ended (space id)
  "Act on the foreman ID in SPACE having stopped or exited.
The news that waited for it is given to the king.  If it exited, its
epic being live, the king is told, with the stories that wait for a
review, since they now wait for the king's."
  (when-let* (((rat-kingdom-space-db space))
              (run (rat-kingdom-run-get space id))
              ((not (rat-kingdom-foreman--running-p space id))))
    (let ((record (rat-kingdom-epic-record space (plist-get run :epic)
                                           (plist-get run :repo))))
      (rat-kingdom-foreman--hand-over space id
                                      (rat-kingdom-foreman--why-not run))
      (when (and record
                 (equal (plist-get run :state) "exited")
                 (rat-kingdom-epic--live-p record)
                 (equal (rat-kingdom-epic--payload record :foreman) id))
        (rat-kingdom-foreman--tell-king
         space record
         (format "The foreman %s of the epic %s %s. News of the epic's stories \
comes to you again, and you review them, until foreman_start starts \
another.%s"
                 id (rat-kingdom-epic--name record)
                 (rat-kingdom-foreman--why-not run)
                 (rat-kingdom-foreman--reviews-phrase space record)))))))

(defun rat-kingdom-foreman--on-change (space op subject)
  "Act soon on a foreman's run in SPACE that has stopped or exited.
OP and SUBJECT are as for `rat-kingdom-space-change-functions'."
  (when-let* (((eq op 'out))
              ((eq (plist-get subject :category) 'run))
              (payload (plist-get subject :payload))
              ((equal (plist-get payload :role) "foreman"))
              ((member (plist-get payload :state) '("exited" "stopped"))))
    (run-at-time 0 nil #'rat-kingdom-foreman--run-ended
                 space (plist-get subject :identity))))

(add-hook 'rat-kingdom-space-change-functions #'rat-kingdom-foreman--on-change)

;;;; Recovery

(defun rat-kingdom-foreman-reconcile (space)
  "Take up again in SPACE each foreman that an Emacs that stopped cut off.
That is a foreman whose run is `interrupted', as
`rat-kingdom-run-reconcile' leaves it, with no agent here.  If its epic
is live, the foreman is started again with the same agent, taking its
session up again if it had one, as the king does.  Otherwise it stays
stopped, and news that waited for it is given to the king.  Return the
ids of the foremen started again."
  (let (ids)
    (dolist (record (rat-kingdom-space-scan space '(epic)))
      (when-let* ((id (rat-kingdom-epic--payload record :foreman))
                  (run (rat-kingdom-run-get space id))
                  ((equal (plist-get run :state) "interrupted"))
                  ((not (rat-kingdom-run-live-p id))))
        (if (rat-kingdom-epic--live-p record)
            (condition-case err
                (let ((session (plist-get run :session-id)))
                  (rat-kingdom-foreman--launch
                   space record
                   (or (plist-get run :agent)
                       rat-kingdom-agent-shell-fallback-agent)
                   (rat-kingdom-foreman--prompt space record session)
                   session)
                  (push id ids))
              (error
               (message "rat-kingdom: could not take up the foreman %s \
again: %s" id (error-message-string err))
               ;; Its news goes to the king, with a note, until another
               ;; is started; none waits for it meanwhile.
               (rat-kingdom-foreman--hand-over
                space id (format "was cut off when Emacs stopped and could \
not be started again (%s)," (error-message-string err)))))
          (rat-kingdom-run-update space id :state "stopped")
          (rat-kingdom-foreman--hand-over
           space id "was cut off when Emacs stopped, its epic having \
ended,"))))
    (nreverse ids)))

;;;; The foreman's tools

(defun rat-kingdom-foreman-scope (record)
  "Return the scope check of the foreman of the epic RECORD.
It refuses a story that is not of the epic and a task that is not one
of its tasks; see `rat-kingdom-king-story-start'."
  (let ((repo (plist-get record :scope))
        (epic (plist-get record :identity)))
    (lambda (kind &rest args)
      (pcase kind
        ('story
         (let ((story (car args)))
           (unless (and (equal (plist-get story :scope) repo)
                        (equal (plist-get (plist-get story :payload) :epic)
                               epic))
             (error "%s is not a story of your epic %s; you act only on its \
stories" (plist-get story :identity) epic))))
        ('task
         (pcase-let ((`(,task-repo ,task ,found) args))
           (cond ((null task)
                  (error "Name the task: you start stories only for tasks of \
your epic %s" epic))
                 ((not (and (equal task-repo repo)
                            (equal (plist-get found :parent) epic)))
                  (error "%s is not a task of your epic %s; you start stories \
only for its tasks" task epic)))))
        (_ (error "You act only on your epic %s" epic))))))

(defun rat-kingdom-foreman--calling (space context)
  "Return the run of the foreman CONTEXT names in SPACE, and its epic's tuple."
  (let* ((run (rat-kingdom-run-get space (plist-get context :run)))
         (record (and run (equal (plist-get run :role) "foreman")
                      (rat-kingdom-epic-record space (plist-get run :epic)
                                               (plist-get run :repo)))))
    (unless record
      (error "This run is not the foreman of an epic"))
    (list run record)))

(defmacro rat-kingdom-foreman--deftool (name description args &rest body)
  "Define the foreman's tool NAME with DESCRIPTION and ARGS.
BODY is run as for `rat-kingdom-king--deftool', with `foreman' bound
to the calling foreman's run record, `record' to its epic's tuple,
`epic' and `repo' to the epic's id and repository, and `check' to its
scope check, `rat-kingdom-foreman-scope'."
  (declare (indent 3))
  `(rat-kingdom-king--deftool ,name ,description ,args
     :roles '(foreman)
     (let* ((calling (rat-kingdom-foreman--calling space context))
            (foreman (car calling))
            (record (cadr calling))
            (epic (plist-get record :identity))
            (repo (plist-get record :scope))
            (check (rat-kingdom-foreman-scope record)))
       (ignore foreman epic repo check)
       ,@body)))

(rat-kingdom-foreman--deftool "status"
    "Show your epic: its state and progress, a table of its tasks with each \
one's status, story, agent and what it waits on, and its stories in \
progress, where each is and what it waits for."
    nil
  (rat-kingdom-foreman-status space record))

(rat-kingdom-foreman--deftool "story_show"
    "Show everything recorded about one story of your epic, in progress or \
finished: where it is, why it stopped, the worker's report and the check's \
outcome."
    '((:name "story" :type string :description "The story's id, like S-1a2b."))
  (rat-kingdom-king--show space (arg 'story) check))

(rat-kingdom-foreman--deftool "story_diff"
    "Show the commits and the diff a story of your epic makes against its \
target branch."
    '((:name "story" :type string :description "The story's id."))
  (rat-kingdom-king--diff space (arg 'story) check))

(rat-kingdom-foreman--deftool "verdict"
    "Give your verdict on a story of your epic that waits for review. pass \
lets it be merged. fix sends it back to a worker with your notes."
    '((:name "story" :type string :description "The story's id.")
      (:name "value" :type string :description "pass or fix.")
      (:name "notes" :type string :optional t
       :description "With fix: what to change, exact enough to act on."))
  (rat-kingdom-king-verdict space (arg 'story) (arg 'value) (arg 'notes)
                            (plist-get foreman :id) check))

(rat-kingdom-foreman--deftool "tell"
    "Send a message to the worker of a story of your epic: a correction, \
more detail, or a change of plan. The worker sees it is from you. A worker \
between turns gets it at once; one in the middle of a turn when the turn \
ends. A story with no worker right now keeps it for its next worker. The \
answer says which happened."
    '((:name "story" :type string :description "The story's id, like S-1a2b.")
      (:name "text" :type string
       :description "The message, written so that the worker can act on it."))
  (rat-kingdom-message-tell-answer space (arg 'story) (arg 'text)
                                   :from (plist-get foreman :id) :check check))

(rat-kingdom-foreman--deftool "task_create"
    "Add a task to your epic, in its repository's tracker: work the epic \
needs that none of its tasks covers, such as another way to do the work of a \
stuck story. The engine starts a story for it by itself once it is ready, \
that is once the tasks it depends on are closed."
    '((:name "title" :type string :description "What to do, in one line.")
      (:name "description" :type string
       :description "Everything a worker needs: what to change, where, \
constraints, and how the result will be judged.")
      (:name "depends_on" :type string :optional t
       :description "Ids of tasks of your epic that must be closed before \
this one is ready, separated by commas or spaces.")
      (:name "priority" :type integer :optional t
       :description "0 (most urgent) to 4. Default the tracker's, 2.")
      (:name "type" :type string :optional t
       :description "task, bug, feature or chore. Default task.")
      (:name "agent" :type string :optional t
       :description "The agent its story's workers should run, claude or \
codex.")
      (:name "workflow" :type string :optional t
       :description "The workflow its story should follow."))
  (let* ((depends (rat-kingdom-epic--ids (arg 'depends_on)))
         (tasks (and depends
                     (mapcar (lambda (task) (plist-get task :id))
                             (rat-kingdom-epic--children space repo epic))))
         (outside (cl-set-difference depends tasks :test #'equal)))
    (when outside
      (error "Nothing was created: %s %s not of your epic %s; a task of it \
may depend only on its other tasks"
             (string-join outside ", ") (if (cdr outside) "are" "is") epic))
    (rat-kingdom-epic-task-create-answer
     space repo (arg 'title)
     :description (arg 'description) :priority (arg 'priority)
     :type (arg 'type) :parent epic :depends-on depends
     :agent (arg 'agent) :workflow (arg 'workflow))))

(rat-kingdom-foreman--deftool "epic_retry"
    "Let the engine start a held task of your epic again. A task is held \
when its story ended without being merged, such as when it was cancelled, or \
when its story could not be started."
    '((:name "task" :type string :description "The held task's id.")
      (:name "epic" :type string :optional t
       :description "Your epic's id. It may be left out."))
  (when (and (arg 'epic) (not (equal (arg 'epic) epic)))
    (error "%s is not your epic; you act only on your epic %s" (arg 'epic) epic))
  (rat-kingdom-epic-retry-answer space epic (arg 'task)))

(rat-kingdom-foreman--deftool "story_start"
    "Start a story at once for a task of your epic that has none, rather \
than wait for the engine to start it, for example for a task you just \
created. It is a story of the epic like the others. Returns the story's id \
and any warnings."
    '((:name "task" :type string :description "The id of a task of your epic.")
      (:name "title" :type string :optional t
       :description "What to do, in one line. Default the task's.")
      (:name "description" :type string :optional t
       :description "Everything the worker needs. Default the task's.")
      (:name "workflow" :type string :optional t
       :description "The workflow to follow. Default the task's \
rk-workflow: label, else the repository's.")
      (:name "agent" :type string :optional t
       :description "claude or codex. Default the task's rk-agent: label, \
else the user's setting."))
  (rat-kingdom-king-story-start
   space (list :repo repo :task (arg 'task) :title (arg 'title)
               :description (arg 'description) :workflow (arg 'workflow)
               :agent (arg 'agent))
   check))

(rat-kingdom-foreman--deftool "report"
    "Send a message to the king: when your epic is held up in a way you \
cannot fix, when something needs the king or the user, and briefly at \
milestones. The king reads it between its turns."
    '((:name "text" :type string :description "What the king should know."))
  (let ((text (string-trim (format "%s" (or (arg 'text) "")))))
    (when (string-empty-p text)
      (error "A report needs some text"))
    (rat-kingdom-space-out
     space 'message :scope repo
     :payload (list :to rat-kingdom-king-id :from (plist-get foreman :id)
                    :text (format "[rat-kingdom] Report from the foreman of \
epic %s: %s"
                                  (rat-kingdom-epic--name record) text))
     :actor (plist-get foreman :id))
    "Sent to the king, who reads it between its turns."))

;;;; The king's tools for foremen

(rat-kingdom-king--deftool "foreman_start"
    "Give a running or paused epic a foreman: an agent that runs the epic \
for you. From then on news of the epic's stories goes to it, not to you: it \
reviews them, steers their workers with tell, and decides what to do about a \
stuck one, and it reports to you. You still hear when the epic is done or \
ready to land, and review its landing. Start one when the user asks, or for \
a big epic. It stops by itself when the epic ends."
    '((:name "epic" :type string :description "The epic's id.")
      (:name "agent" :type string :optional t
       :description "The agent it runs, claude or codex. Default claude."))
  (let* ((id (rat-kingdom-foreman-start space (arg 'epic) (arg 'agent)))
         (record (rat-kingdom-epic--get space (arg 'epic)))
         (run (rat-kingdom-run-get space id)))
    (rat-kingdom-epic--run-reactions space)
    (format "Started the foreman %s (%s) for the epic %s. News of its stories \
goes to the foreman from now on; it reviews them and reports to you. \
foreman_stop hands its reviews back to you.%s"
            id (plist-get run :agent) (rat-kingdom-epic--name record)
            (if-let* ((reviews (rat-kingdom-foreman--reviews space record)))
                (format " Waiting for review now, which the foreman was asked \
to review: %s." (string-join reviews ", "))
              ""))))

(rat-kingdom-king--deftool "foreman_stop"
    "Stop the foreman of an epic. News of the epic's stories comes to you \
again, with any the foreman had not read, and you review them."
    '((:name "epic" :type string :description "The epic's id."))
  (rat-kingdom-foreman-stop space (arg 'epic)))

(provide 'rat-kingdom-foreman)
;;; rat-kingdom-foreman.el ends here
