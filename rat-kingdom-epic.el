;;; rat-kingdom-epic.el --- Planning tasks and epics -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Chaz Straney

;; Author: Chaz Straney <chaz.straney@gmail.com>
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;;; Commentary:

;; The king plans work as tasks in a repository's tracker, and runs
;; epics (DESIGN.md, sections 9 and 10).  Its tools defined here:
;;
;;   task_create  one task, with its epic, the tasks it depends on, and
;;                the agent and workflow its story should have
;;   epic_create  an epic and its stories, with the dependencies
;;                between them, all at once
;;   epic_start, epic_pause, epic_resume, epic_cancel, epic_retry and
;;   epic_show    running an epic, and looking at one
;;   epic_diff and epic_verdict
;;                reviewing an epic with a feature branch before it lands
;;
;; The first two start nothing.  A task records the agent and workflow its
;; story should have as the labels rk-agent:NAME and rk-workflow:NAME,
;; which `story_start' uses when it is given the task.  Dependencies are
;; recorded in the tracker, so a task becomes available once the tasks
;; it depends on are closed, as their stories are merged.
;;
;; `epic_create' checks the whole plan before it writes anything: every
;; story has a key of its own, a title and a description, depends only
;; on keys in the plan, and names known agents and workflows, and the
;; dependencies have no cycle.  It then creates the epic, each story as
;; a task of the epic in an order where every task is created after
;; those it depends on, and then the dependencies.  If the tracker fails
;; partway, the error says exactly what was created, for the user to
;; clean up: br has no clean delete, only tombstones, so nothing is
;; rolled back.
;;
;; An epic is run by the engine once the king starts it with
;; `epic_start'.  Its state is one persistent `epic' tuple, scoped to the
;; repository and named by the epic's id, whose payload holds `:state'
;; (running, paused, landing, done or cancelled), `:title',
;; `:max-parallel', `:held' (tasks not to be started again by
;; themselves, each with the reason), `:merged' (the tasks its stories
;; merged), `:started' and `:finished', and for an epic with a feature
;; branch `:branch', `:target' and what its landing is at.  It is only
;; ever replaced whole, in one transaction.
;;
;; Dispatch, `rat-kingdom-epic-dispatch', starts a story for each
;; `available' task of a running epic that is not held and has no story,
;; while the epic has fewer stories in progress than its `:max-parallel'.
;; The worker cap and its queue apply to those stories as to any other.
;; It runs when a task of a running epic becomes available, and when the
;; epic tuple is replaced (a reaction joins the two); when a story of the
;; epic ends and its task has been settled; when the epic is started,
;; resumed or a task retried; and when `rat-kingdom-mode' starts.  A
;; story is only ever started in the transaction that takes its task's
;; `available' tuple and finds no other story for the task, so a task
;; never gets two.
;;
;; A story of the epic that ends without being merged leaves its task
;; held, so that the released task is not started again by itself; the
;; king is told, and `epic_retry' clears it.  A story that stops tells
;; the king which tasks of the epic wait on it.  When every task of the
;; epic is closed, the epic is done, and the br epic is closed.
;;
;; An epic started with `feature_branch' has a branch of its own,
;; rk/epic/ID, cut from the repository's target.  Every story of it is
;; started with that branch as its target (rat-kingdom-story.el), so the
;; target does not move while the epic is built.  When every task is
;; closed the epic is `landing' instead of done: its branch is merged
;; into the target in a candidate worktree and checked there, as a
;; story's commit is, the outcome recorded as a `checked' tuple named by
;; the epic.  A check that passes asks the king for a review of the
;; whole, `epic_diff' and `epic_verdict'.  Pass moves the target by the
;; same compare-and-swap as a story's merge, and the epic is done.  Fix,
;; a failed check, or a merge that conflicts because the target moved,
;; each become a new task of the epic, which dispatch starts on the
;; epic's branch; when it is merged, the epic lands again.  The branch
;; is never deleted.
;;
;; An epic may have a foreman, an agent that runs it for the king
;; (rat-kingdom-foreman.el).  Its id is kept as `:foreman' in the
;; record.  While it runs, news of the epic's work that
;; `rat-kingdom-epic--tell' is given the epic for goes to it instead of
;; the king; `rat-kingdom-epic-ended-functions' are told when an epic
;; ends, so that its foreman stops.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'rat-kingdom-space)
(require 'rat-kingdom-reaction)
(require 'rat-kingdom-git)
(require 'rat-kingdom-workflow)
(require 'rat-kingdom-task)
(require 'rat-kingdom-agent-shell)
(require 'rat-kingdom-story)
(require 'rat-kingdom-king)

(autoload 'rat-kingdom-foreman-start "rat-kingdom-foreman")

(defconst rat-kingdom-epic-task-types '("task" "bug" "feature" "chore")
  "The kinds of task `task_create' makes.")

;;;; Checking

(defun rat-kingdom-epic--blank-p (value)
  "Return non-nil if VALUE is nil or a blank string."
  (or (null value) (and (stringp value) (string-blank-p value))))

(defun rat-kingdom-epic--ids (value)
  "Return VALUE as a list of ids.
VALUE is nil, a list of strings, or a string of ids separated by commas
or spaces."
  (cl-remove-duplicates
   (cl-remove-if #'string-empty-p
                 (mapcan (lambda (item)
                           (split-string (format "%s" item) "[ ,\t\n]+" t))
                         (if (listp value) value (list value))))
   :test #'equal :from-end t))

(defun rat-kingdom-epic--agent-problem (agent)
  "Return what is wrong with the agent name AGENT, or nil."
  (unless (or (rat-kingdom-epic--blank-p agent)
              (member (format "%s" agent) (rat-kingdom-agent-names)))
    (format "there is no agent called %s; there are: %s"
            agent (string-join (rat-kingdom-agent-names) ", "))))

(defun rat-kingdom-epic--workflow-problem (workflow)
  "Return what is wrong with the workflow name WORKFLOW, or nil."
  (unless (or (rat-kingdom-epic--blank-p workflow)
              (rat-kingdom-workflow-get workflow))
    (format "there is no workflow called %s; there are: %s"
            workflow (mapconcat (lambda (workflow) (plist-get workflow :name))
                                (rat-kingdom-workflow-list) ", "))))

(defun rat-kingdom-epic--priority-problem (value)
  "Return what is wrong with VALUE as a priority, or nil.
A priority is blank, or a whole number from 0 to 4, or a string of one."
  (unless (or (rat-kingdom-epic--blank-p value)
              (and (integerp value) (<= 0 value 4))
              (and (stringp value)
                   (string-match-p "\\`[ \t]*[0-4][ \t]*\\'" value)))
    (format "priority must be a whole number from 0 to 4, not %s" value)))

(defun rat-kingdom-epic--priority (value)
  "Return VALUE, a priority without problems, as a number, or nil if blank."
  (cond ((rat-kingdom-epic--blank-p value) nil)
        ((integerp value) value)
        (t (string-to-number value))))

(defun rat-kingdom-epic--message (err)
  "Return the message of the error ERR.
A tracker's error is given as the tracker's own message."
  (if (and (eq (car err) 'rat-kingdom-task-error) (stringp (cadr err)))
      (cadr err)
    (error-message-string err)))

(defun rat-kingdom-epic--problem (function &rest args)
  "Call FUNCTION with ARGS and return the message of any error it signals."
  (condition-case err
      (progn (apply function args) nil)
    (error (rat-kingdom-epic--message err))))

(defun rat-kingdom-epic--adapter (space repo)
  "Return the task adapter of the registered repository REPO in SPACE.
Signal an error if REPO is not registered or has no tracker."
  (unless (rat-kingdom-repo-get space repo)
    (error "No repository called %s is registered" repo))
  (or (rat-kingdom-task-adapter space repo)
      (error "The repository %s has no task tracker" repo)))

(defun rat-kingdom-epic--cycle (keys depends)
  "Return a dependency cycle among KEYS, as a list of keys, or nil.
DEPENDS is a function from a key to the keys it depends on.  The cycle
starts and ends with the same key."
  (let ((state (make-hash-table :test #'equal))
        found)
    (cl-labels ((visit (key path)
                  (pcase (gethash key state)
                    ('done nil)
                    ('open
                     (setq found (reverse (cons key (cl-subseq
                                                     path 0
                                                     (1+ (cl-position
                                                          key path
                                                          :test #'equal)))))))
                    (_
                     (puthash key 'open state)
                     (dolist (next (funcall depends key))
                       (unless found
                         (visit next (cons key path))))
                     (puthash key 'done state)))))
      (dolist (key keys)
        (unless found
          (visit key nil))))
    found))

(defun rat-kingdom-epic--order (stories)
  "Return STORIES ordered so that each comes after those it depends on.
STORIES are checked plans, as `rat-kingdom-epic-check' returns, with
no cycle.  Among stories whose dependencies are all placed, the one
given first goes first, so a list already in order is kept."
  (let ((placed nil)
        (ordered nil)
        (left (copy-sequence stories)))
    (while left
      (let ((next (or (cl-find-if
                       (lambda (story)
                         (cl-every (lambda (key) (member key placed))
                                   (plist-get story :depends-on)))
                       left)
                      (error "The stories' dependencies have a cycle"))))
        (push (plist-get next :key) placed)
        (push next ordered)
        (setq left (delq next left))))
    (nreverse ordered)))

(defun rat-kingdom-epic--story (index story)
  "Return STORY, an alist from JSON, as a property list.
INDEX is its place in the plan, counting from 1.  Return a list of
problems instead, as strings, if STORY is not an object."
  (if (not (and (consp story) (cl-every #'consp story)
                (cl-every (lambda (entry) (symbolp (car entry))) story)))
      (list (format "story %d is not an object with a key, title and \
description" index))
    (cl-flet ((get (name) (alist-get name story)))
      (list :key (and (get 'key) (string-trim (format "%s" (get 'key))))
            :title (get 'title)
            :description (get 'description)
            :depends-on (rat-kingdom-epic--ids (get 'depends_on))
            :agent (and (not (rat-kingdom-epic--blank-p (get 'agent)))
                        (format "%s" (get 'agent)))
            :workflow (and (not (rat-kingdom-epic--blank-p (get 'workflow)))
                           (format "%s" (get 'workflow)))
            :priority (get 'priority)
            :index index))))

(defun rat-kingdom-epic-check (stories)
  "Check the plan STORIES and return its stories, in an order to create.
STORIES is a list of alists, as JSON objects arrive from a tool call,
or a JSON text of such an array.  Each has `key', `title' and
`description', and may have `depends_on' (a list of keys of other
stories, or a string of them separated by commas or spaces), `agent',
`workflow' and `priority'.  Return the stories as property lists with
`:key', `:title', `:description', `:depends-on', `:agent',
`:workflow' and `:priority', each after the stories it depends on.

Signal an error naming every problem found, if any: a story that is not
an object, a missing, blank or repeated key, a blank title or
description, a dependency on a key that is not in the plan, a cycle of
dependencies, an unknown agent or workflow, or a priority that is not
from 0 to 4."
  (when (stringp stories)
    (setq stories (condition-case err
                      (json-parse-string stories :object-type 'alist
                                         :array-type 'list :null-object nil
                                         :false-object nil)
                    (error (error "The stories are not valid JSON: %s"
                                  (error-message-string err))))))
  (unless (and stories (listp stories))
    (error "The stories must be a non-empty array"))
  (let ((index 0)
        (problems nil)
        (plans nil)
        (keys nil))
    (dolist (story stories)
      (let ((plan (rat-kingdom-epic--story (cl-incf index) story)))
        (if (stringp (car plan))
            (setq problems (append problems plan))
          (push plan plans))))
    (setq plans (nreverse plans))
    (dolist (plan plans)
      (let* ((key (plist-get plan :key))
             (name (if (rat-kingdom-epic--blank-p key)
                       (format "story %d" (plist-get plan :index))
                     (format "story %s" key))))
        (cl-flet ((problem (format-string &rest args)
                    (setq problems
                          (append problems
                                  (list (concat name ": "
                                                (apply #'format format-string
                                                       args)))))))
          (cond ((rat-kingdom-epic--blank-p key) (problem "it has no key"))
                ((member key keys)
                 (problem "the key %s is used by more than one story" key))
                (t (push key keys)))
          (when (rat-kingdom-epic--blank-p (plist-get plan :title))
            (problem "its title is blank"))
          (when (rat-kingdom-epic--blank-p (plist-get plan :description))
            (problem "its description is blank"))
          (when-let* ((agent (rat-kingdom-epic--agent-problem
                              (plist-get plan :agent))))
            (problem "%s" agent))
          (when-let* ((workflow (rat-kingdom-epic--workflow-problem
                                 (plist-get plan :workflow))))
            (problem "%s" workflow))
          (when-let* ((priority (rat-kingdom-epic--priority-problem
                                 (plist-get plan :priority))))
            (problem "%s" priority)))))
    (dolist (plan plans)
      (dolist (dependency (plist-get plan :depends-on))
        (unless (cl-find dependency plans
                         :key (lambda (other) (plist-get other :key))
                         :test #'equal)
          (setq problems
                (append problems
                        (list (format "story %s: it depends on %s, which is \
not a key of this plan"
                                      (or (plist-get plan :key)
                                          (plist-get plan :index))
                                      dependency)))))))
    (let ((cycle (rat-kingdom-epic--cycle
                  (mapcar (lambda (plan) (plist-get plan :key)) plans)
                  (lambda (key)
                    (plist-get (cl-find key plans
                                        :key (lambda (plan)
                                               (plist-get plan :key))
                                        :test #'equal)
                               :depends-on)))))
      (when cycle
        (setq problems
              (append problems
                      (list (format "the dependencies have a cycle: %s"
                                    (string-join cycle " depends on ")))))))
    (when problems
      (error "Nothing was created.  The plan has %s:\n- %s"
             (if (cdr problems)
                 (format "%d problems" (length problems))
               "a problem")
             (string-join problems "\n- ")))
    (mapcar (lambda (plan)
              (plist-put plan :priority
                         (rat-kingdom-epic--priority (plist-get plan :priority))))
            (rat-kingdom-epic--order plans))))

;;;; Creating

(defun rat-kingdom-epic--available (space repo ids)
  "Return those of IDS that are available in REPO in SPACE."
  (cl-remove-if-not
   (lambda (id) (rat-kingdom-space-rd space (list 'available :scope repo
                                                  :identity id)))
   ids))

(defun rat-kingdom-epic-create (space repo title description stories)
  "Create in REPO's tracker in SPACE the epic TITLE and its STORIES.
DESCRIPTION is the epic's goal and how it will be judged as a whole.
STORIES is a plan, as `rat-kingdom-epic-check' takes; it is checked
in full first, and nothing is created if it has a problem.  Then the
epic is created, each story as a task of it with its labels, every task
after those it depends on, and then the dependencies.  Finally REPO's
available tasks are projected again.  Nothing is started.

Return a property list: `:epic' the epic's id, `:stories' the stories
each with `:id', and `:ready' the ids of those available now.  If the
tracker fails partway, signal an error saying what was created."
  (when (rat-kingdom-epic--blank-p title)
    (error "Nothing was created: the epic's title is blank"))
  (when (rat-kingdom-epic--blank-p description)
    (error "Nothing was created: the epic's description is blank"))
  (let* ((adapter (rat-kingdom-epic--adapter space repo))
         (plans (rat-kingdom-epic-check stories))
         (epic nil)
         (created nil)                  ; in the order they were made
         (edges nil)                    ; newest first
         (step nil))
    (condition-case err
        (progn
          (setq step "creating the epic")
          (setq epic (rat-kingdom-task-create adapter title
                                              :description description
                                              :type "epic"))
          (dolist (plan plans)
            (setq step (format "creating the task for story %s"
                               (plist-get plan :key)))
            (let ((id (rat-kingdom-task-create
                       adapter (plist-get plan :title)
                       :description (plist-get plan :description)
                       :priority (plist-get plan :priority)
                       :parent epic
                       :labels (rat-kingdom-task-labels
                                (plist-get plan :agent)
                                (plist-get plan :workflow)))))
              (setq created (append created
                                    (list (plist-put plan :id id))))))
          (dolist (plan created)
            (dolist (key (plist-get plan :depends-on))
              (let ((on (plist-get (cl-find key created
                                            :key (lambda (other)
                                                   (plist-get other :key))
                                            :test #'equal)
                                   :id)))
                (setq step (format "recording that %s (%s) depends on %s (%s)"
                                   (plist-get plan :key) (plist-get plan :id)
                                   key on))
                (rat-kingdom-task-depend adapter (plist-get plan :id) on)
                (push (cons (plist-get plan :id) on) edges)))))
      (error
       (error "The tracker failed while %s: %s\n%s" step
              (rat-kingdom-epic--message err)
              (if (not epic)
                  "Nothing was created."
                (concat
                 (format "Created so far, and not removed (br has no \
clean delete; remove them with br delete if they are not wanted): the epic \
%s%s" epic
                         (if created
                             (concat ", and the tasks "
                                     (mapconcat
                                      (lambda (plan)
                                        (format "%s (story %s)"
                                                (plist-get plan :id)
                                                (plist-get plan :key)))
                                      created ", "))
                           ""))
                 "."
                 (if edges
                     (format "\nDependencies recorded: %s."
                             (mapconcat (lambda (edge)
                                          (format "%s depends on %s"
                                                  (car edge) (cdr edge)))
                                        (reverse edges) ", "))
                   "\nNo dependencies were recorded."))))))
    (rat-kingdom-task-project space repo)
    (list :epic epic :stories created
          :ready (rat-kingdom-epic--available
                  space repo (mapcar (lambda (plan) (plist-get plan :id))
                                     created)))))

(defun rat-kingdom-epic-describe (repo title result)
  "Return a text describing the epic TITLE that RESULT says was created.
RESULT is what `rat-kingdom-epic-create' returned for REPO."
  (let* ((stories (plist-get result :stories))
         (ready (cl-remove-if-not
                 (lambda (plan) (member (plist-get plan :id)
                                        (plist-get result :ready)))
                 stories)))
    (concat
     (format "Created the epic %s in %s: %s. Nothing has been started.\n\n"
             (plist-get result :epic) repo title)
     "| key | task | title | depends on | agent | workflow |\n"
     "|---|---|---|---|---|---|\n"
     (mapconcat
      (lambda (plan)
        (format "| %s | %s | %s | %s | %s | %s |"
                (plist-get plan :key) (plist-get plan :id)
                (replace-regexp-in-string "[|\n]" " " (plist-get plan :title))
                (if (plist-get plan :depends-on)
                    (string-join (plist-get plan :depends-on) ", ")
                  "-")
                (or (plist-get plan :agent)
                    (format "default (%s)" (rat-kingdom-agent-name nil)))
                (or (plist-get plan :workflow) "the repository's")))
      stories "\n")
     "\n\n"
     (if ready
         (format "Ready now: %s. Ask the user before you run the epic with \
epic_start, which has the engine start its stories as their tasks become \
ready."
                 (mapconcat (lambda (plan)
                              (format "%s (%s)" (plist-get plan :key)
                                      (plist-get plan :id)))
                            ready ", "))
       "Ready now: none that the tracker reports; see Available tasks in \
status."))))

(defun rat-kingdom-epic-create-task (space repo title &rest options)
  "Create the task TITLE in REPO's tracker in SPACE and return its id.
OPTIONS are keyword arguments: `:description', `:priority' (0 to 4),
`:type' (one of `rat-kingdom-epic-task-types'), `:parent' (the id of
an epic), `:depends-on' (ids, as a list or a string), `:agent' and
`:workflow'.  Everything is checked before anything is created: the
agent and workflow must be known, and the parent and every task
depended on must be in the tracker.  The agent and workflow are kept as
labels.  Then REPO's available tasks are projected again.  Nothing is
started.  If the tracker fails after the task is created, signal an
error that names it."
  (let* ((adapter (rat-kingdom-epic--adapter space repo))
         (depends (rat-kingdom-epic--ids (plist-get options :depends-on)))
         (agent (plist-get options :agent))
         (workflow (plist-get options :workflow))
         (type (plist-get options :type))
         (parent (plist-get options :parent))
         (problems
          (delq nil
                (append
                 (list
                  (and (rat-kingdom-epic--blank-p title) "the title is blank")
                  (and type (not (member type rat-kingdom-epic-task-types))
                       (format "type must be one of %s, not %s"
                               (string-join rat-kingdom-epic-task-types ", ")
                               type))
                  (rat-kingdom-epic--priority-problem
                   (plist-get options :priority))
                  (rat-kingdom-epic--agent-problem agent)
                  (rat-kingdom-epic--workflow-problem workflow)
                  (and parent (member parent depends)
                       (format "%s is the parent; it cannot also be depended \
on" parent)))
                 (mapcar (lambda (id)
                           (when-let* ((problem (rat-kingdom-epic--problem
                                                 #'rat-kingdom-task-show
                                                 adapter id)))
                             (format "%s %s is not in the tracker of %s (%s)"
                                     (if (equal id parent) "the parent"
                                       "the task")
                                     id repo problem)))
                         (if parent (cons parent depends) depends))))))
    (when problems
      (error "Nothing was created: %s" (string-join problems "; ")))
    (let ((id (rat-kingdom-task-create
               adapter title
               :description (plist-get options :description)
               :priority (rat-kingdom-epic--priority (plist-get options :priority))
               :type type :parent parent
               :labels (rat-kingdom-task-labels agent workflow)))
          (recorded nil))
      (condition-case err
          (dolist (on depends)
            (rat-kingdom-task-depend adapter id on)
            (push on recorded))
        (error
         (error "Created the task %s, but the tracker failed to record that \
it depends on %s: %s.%s It was not removed" id
                (car (cl-set-difference depends recorded :test #'equal))
                (rat-kingdom-epic--message err)
                (if recorded
                    (format " Recorded: it depends on %s."
                            (string-join (reverse recorded) ", "))
                  ""))))
      (rat-kingdom-task-project space repo)
      id)))

;;;; The king's tools

(defun rat-kingdom-epic-task-create-answer (space repo title &rest options)
  "Create the task TITLE in REPO in SPACE, as `task_create' does.
OPTIONS are those of `rat-kingdom-epic-create-task'.  Return what
`task_create' answers.  The foreman calls it with its epic as
`:parent'."
  (let* ((depends (rat-kingdom-epic--ids (plist-get options :depends-on)))
         (parent (plist-get options :parent))
         (id (apply #'rat-kingdom-epic-create-task space repo title
                    (plist-put (copy-sequence options) :depends-on depends))))
    (string-join
     (delq nil
           (list (format "Created the task %s in %s: %s." id repo title)
                 (and parent (format "Epic: %s." parent))
                 (and depends (format "Depends on: %s."
                                      (string-join depends ", ")))
                 (and (plist-get options :agent)
                      (format "Agent: %s." (plist-get options :agent)))
                 (and (plist-get options :workflow)
                      (format "Workflow: %s." (plist-get options :workflow)))
                 (if (rat-kingdom-space-rd space (list 'available :scope repo
                                                       :identity id))
                     "It is ready now. Nothing has been started."
                   "It is not ready yet. Nothing has been started.")))
     " ")))

(rat-kingdom-king--deftool "task_create"
    "Create one task in a repository's tracker (br), optionally in an epic, \
depending on other tasks, and naming the agent and workflow its story should \
have. It starts nothing: a story is started for the task with story_start \
when the user wants, and only once the tasks it depends on are closed is it \
listed under Available tasks."
    '((:name "repo" :type string :description "The repository's name.")
      (:name "title" :type string :description "What to do, in one line.")
      (:name "description" :type string
       :description "Everything a worker needs: what to change, where, \
constraints, and how the result will be judged.")
      (:name "priority" :type integer :optional t
       :description "0 (most urgent) to 4. Default the tracker's, 2.")
      (:name "type" :type string :optional t
       :description "task, bug, feature or chore. Default task.")
      (:name "parent" :type string :optional t
       :description "The id of the epic the task belongs to.")
      (:name "depends_on" :type string :optional t
       :description "Ids of tasks that must be closed before this one is \
ready, separated by commas or spaces.")
      (:name "agent" :type string :optional t
       :description "The agent its story's workers should run, claude or \
codex. Kept as the label rk-agent:NAME; story_start uses it by default.")
      (:name "workflow" :type string :optional t
       :description "The workflow its story should follow. Kept as the \
label rk-workflow:NAME; story_start uses it by default."))
  (rat-kingdom-epic-task-create-answer
   space (arg 'repo) (arg 'title)
   :description (arg 'description) :priority (arg 'priority)
   :type (arg 'type) :parent (arg 'parent) :depends-on (arg 'depends_on)
   :agent (arg 'agent) :workflow (arg 'workflow)))

(rat-kingdom-king--deftool "epic_create"
    "Create an epic in a repository's tracker (br) and its stories as tasks \
of it, with the dependencies between them. Call it only once the user has \
agreed to the plan. The whole plan is checked first and nothing is created if \
any of it is wrong. It starts nothing: once the user agrees, epic_start has \
the engine start the stories as their tasks become ready. Returns the epic's \
id, a table of the stories' tasks and which are ready now."
    '((:name "repo" :type string :description "The repository's name.")
      (:name "title" :type string :description "The epic's name, in one line.")
      (:name "description" :type string
       :description "The epic's goal, and how it will be judged as a whole.")
      (:name "stories" :type array
       :description "The stories, in order. Each becomes a task of the \
epic."
       :items
       (:type object
        :properties
        ((:name "key" :type string
          :description "A name for the story, local to this call, such as \
a or parser, for depends_on to refer to.")
         (:name "title" :type string :description "What to do, in one line.")
         (:name "description" :type string
          :description "Everything a worker needs: what to change, where, \
constraints, and how the result will be judged. The worker knows nothing \
else.")
         (:name "depends_on" :type array :optional t
          :items (:type string)
          :description "Keys of stories in this list that must be merged \
before this one starts.")
         (:name "agent" :type string :optional t
          :description "claude or codex. Default the user's setting.")
         (:name "workflow" :type string :optional t
          :description "The workflow its story follows. Default the \
repository's.")
         (:name "priority" :type integer :optional t
          :description "0 (most urgent) to 4.")))))
  (let ((result (rat-kingdom-epic-create space (arg 'repo) (arg 'title)
                                         (arg 'description) (arg 'stories))))
    (rat-kingdom-epic-describe (arg 'repo) (arg 'title) result)))

;;;; The epic record

(defconst rat-kingdom-epic-live-states '("running" "paused" "landing")
  "The states of an epic that has not ended.")

(defconst rat-kingdom-epic-building-states '("running" "paused")
  "The states of an epic whose tasks are still being done.
When every task of such an epic is closed, it is done, or, if it has a
feature branch, it lands.")

(defconst rat-kingdom-epic-branch-prefix "rk/epic/"
  "The start of the name of an epic's feature branch; its id follows.")

(defun rat-kingdom-epic-record (space id &optional repo)
  "Return the `epic' tuple of the epic ID in SPACE, or nil.
With REPO, only one in that repository."
  (rat-kingdom-space-rd space (if repo
                                  (list 'epic :scope repo :identity id)
                                (list 'epic :identity id))))

(defun rat-kingdom-epic--get (space id)
  "Return the `epic' tuple of the epic ID in SPACE, or signal an error."
  (or (rat-kingdom-epic-record space id)
      (error "The epic %s has not been started; start it with epic_start" id)))

(defun rat-kingdom-epic--payload (record key)
  "Return what the `epic' tuple RECORD has under KEY."
  (plist-get (plist-get record :payload) key))

(defun rat-kingdom-epic--live-p (record)
  "Return non-nil if the `epic' tuple RECORD is running, paused or landing."
  (member (rat-kingdom-epic--payload record :state)
          rat-kingdom-epic-live-states))

(defun rat-kingdom-epic--held (record)
  "Return the held tasks of the `epic' tuple RECORD, as (:task :reason) lists."
  (rat-kingdom-epic--payload record :held))

(defun rat-kingdom-epic--held-reason (record task)
  "Return why TASK is held in the `epic' tuple RECORD, or nil if it is not."
  (plist-get (cl-find task (rat-kingdom-epic--held record)
                      :key (lambda (held) (plist-get held :task))
                      :test #'equal)
             :reason))

(defun rat-kingdom-epic--name (record)
  "Return the epic of the `epic' tuple RECORD as \"ID (TITLE)\"."
  (format "%s (%s)" (plist-get record :identity)
          (rat-kingdom-epic--payload record :title)))

(defun rat-kingdom-epic--update (space repo id function &optional actor)
  "Replace the `epic' tuple of the epic ID of REPO in SPACE, in one transaction.
FUNCTION is called with a copy of its payload and returns the new
payload, or nil to leave the tuple as it is.  Return the new tuple, or
nil if nothing changed.  ACTOR is recorded; by default the engine."
  (rat-kingdom-space-with-transaction space
    (let* ((record (or (rat-kingdom-epic-record space id repo)
                       (error "The epic %s has not been started" id)))
           (payload (funcall function
                             (copy-sequence (plist-get record :payload)))))
      (when payload
        (rat-kingdom-space-put space 'epic :scope repo :identity id
                               :payload payload :actor (or actor "engine"))))))

(defun rat-kingdom-epic--hold (space repo id task reason)
  "Hold TASK of the epic ID of REPO in SPACE for REASON, unless it is held.
A held task is not started by dispatch until `epic_retry' clears it."
  (rat-kingdom-epic--update
   space repo id
   (lambda (payload)
     (unless (cl-find task (plist-get payload :held)
                      :key (lambda (held) (plist-get held :task))
                      :test #'equal)
       (plist-put payload :held
                  (append (plist-get payload :held)
                          (list (list :task task :reason reason))))))))

(defun rat-kingdom-epic--target (space record)
  "Return the branch the epic RECORD in SPACE lands on.
That is the `:target' it was started with, or else its repository's."
  (or (rat-kingdom-epic--payload record :target)
      (plist-get (rat-kingdom-repo-get space (plist-get record :scope))
                 :target)))

(defun rat-kingdom-epic--tell (space repo text &optional epic)
  "Leave the king a message in SPACE, about REPO, saying TEXT.
With EPIC, the id of an epic, the news is of that epic's work, which
goes where `rat-kingdom-king-route' says: to the epic's foreman while
one is running.  News of an epic as a whole, that it is done or ready
to land, is given no EPIC, so it is always the king's."
  (pcase-let ((`(,to . ,note) (rat-kingdom-king-route space repo epic)))
    (rat-kingdom-space-out space 'message :scope repo
                           :payload (list :to to
                                          :text (if note
                                                    (concat text "\n" note)
                                                  text))
                           :actor "engine")))

(defvar rat-kingdom-epic-ended-functions nil
  "Functions called when an epic has ended, done or cancelled.
Each is called with the space and the epic's tuple as it is now, after
the transaction that ended it.  rat-kingdom-foreman.el puts one here,
which stops the epic's foreman.  Add to it with `add-hook', so that
reloading does not add a function twice.")

(defun rat-kingdom-epic--ended (space repo id)
  "Tell `rat-kingdom-epic-ended-functions' that the epic ID of REPO in SPACE ended."
  (when-let* ((record (rat-kingdom-epic-record space id repo)))
    (dolist (function rat-kingdom-epic-ended-functions)
      (with-demoted-errors "rat-kingdom: epic ended function: %S"
        (funcall function space record)))))

;;;; What the tracker and the space say of an epic's tasks

(defun rat-kingdom-epic--children (space repo id)
  "Return the tasks of the epic ID of REPO in SPACE, from its tracker."
  (rat-kingdom-task-children (rat-kingdom-epic--adapter space repo) id))

(defun rat-kingdom-epic--closed-p (task)
  "Return non-nil if TASK is closed in its tracker."
  (member (plist-get task :status) '("closed" "tombstone")))

(defun rat-kingdom-epic--stories (space repo id)
  "Return the tokens of the stories in progress of the epic ID of REPO in SPACE.
A token being archived in the transaction in progress is not one."
  (cl-remove-if (lambda (story)
                  (member (plist-get (plist-get story :payload) :phase)
                          '("done" "cancelled")))
                (rat-kingdom-space-scan space (list 'story :scope repo
                                                    :epic id))))

(defun rat-kingdom-epic--waits-on (task children)
  "Return the ids of the tasks among CHILDREN, or else any, TASK waits on.
Those are the tasks it depends on that are not closed.  One that is
not among CHILDREN is taken to be open."
  (cl-remove-if (lambda (dependency)
                  (when-let* ((other (cl-find dependency children
                                              :key (lambda (child)
                                                     (plist-get child :id))
                                              :test #'equal)))
                    (rat-kingdom-epic--closed-p other)))
                (plist-get task :depends-on)))

(defun rat-kingdom-epic--dependents (task children)
  "Return the open tasks among CHILDREN that wait on TASK.
Each is (ID . THROUGH): THROUGH is nil if it depends on TASK itself,
and otherwise the task it depends on through which it waits.  They
come nearest first."
  (let ((queue (list (cons task nil)))
        (found nil))
    (while queue
      (pcase-let ((`(,current . ,through) (pop queue)))
        (dolist (child children)
          (let ((id (plist-get child :id)))
            (when (and (member current (plist-get child :depends-on))
                       (not (rat-kingdom-epic--closed-p child))
                       (not (equal id task))
                       (not (assoc id found)))
              (let ((entry (cons id (if (equal current task)
                                        nil
                                      (or through current)))))
                (push entry found)
                (setq queue (append queue (list (cons id (cdr entry)))))))))))
    (nreverse found)))

(defun rat-kingdom-epic--describe-dependents (dependents)
  "Return the tasks DEPENDENTS, as `rat-kingdom-epic--dependents' gives them."
  (mapconcat (lambda (entry)
               (if (cdr entry)
                   (format "%s (through %s)" (car entry) (cdr entry))
                 (format "%s (directly)" (car entry))))
             dependents ", "))

;;;; Dispatch

(defun rat-kingdom-epic--room-p (space repo record)
  "Return non-nil if the epic RECORD of REPO in SPACE may start a story.
That is if it has fewer stories in progress than its `:max-parallel'."
  (let ((limit (rat-kingdom-epic--payload record :max-parallel)))
    (or (null limit)
        (< (length (rat-kingdom-epic--stories space repo
                                             (plist-get record :identity)))
           limit))))

(defun rat-kingdom-epic--ready (space repo id)
  "Return the `available' tuples of the tasks of the epic ID of REPO in SPACE.
The most urgent come first, then by id."
  (sort (rat-kingdom-space-scan space (list 'available :scope repo :parent id))
        (lambda (a b)
          (let ((pa (or (plist-get (plist-get a :payload) :priority) 9))
                (pb (or (plist-get (plist-get b :payload) :priority) 9)))
            (if (= pa pb)
                (string-version-lessp (plist-get a :identity)
                                      (plist-get b :identity))
              (< pa pb))))))

(defun rat-kingdom-epic--start-task (space repo id task)
  "Start a story for TASK of the epic ID of REPO in SPACE, if dispatch may.
Return the story's id, or nil if it may not: the epic is not running,
TASK is not available, is held or has a story, or the epic has as many
stories in progress as it may.  The checks and the start are one
transaction, which takes TASK's `available' tuple."
  (rat-kingdom-space-with-transaction space
    (let ((record (rat-kingdom-space-rd
                   space (list 'epic :scope repo :identity id :state "running")))
          (available (rat-kingdom-space-rd
                      space (list 'available :scope repo :identity task))))
      (when (and record available
                 (not (rat-kingdom-epic--held-reason record task))
                 (not (rat-kingdom-space-rd space (list 'story :scope repo
                                                        :task task)))
                 (rat-kingdom-epic--room-p space repo record))
        (rat-kingdom-story-start-for-task
         space repo task :found (plist-get available :payload) :epic id
         :target (rat-kingdom-epic--payload record :branch))))))

(defun rat-kingdom-epic--dispatch-one (space repo id)
  "Start stories for the ready tasks of the epic ID of REPO in SPACE.
Return the started stories as (TASK . STORY).  A task whose story
cannot be started is held, and the king is told why."
  (let (started)
    (dolist (available (rat-kingdom-epic--ready space repo id))
      (let ((task (plist-get available :identity)))
        (condition-case err
            (when-let* ((story (rat-kingdom-epic--start-task space repo id task)))
              (push (cons task story) started))
          (error
           (let ((reason (format "a story could not be started for it: %s"
                                 (error-message-string err))))
             (rat-kingdom-space-with-transaction space
               (when-let* ((record (rat-kingdom-epic--hold
                                    space repo id task reason)))
                 (rat-kingdom-epic--tell
                  space repo
                  (format "The epic %s could not start a story for its task \
%s (%s): %s\nThe task is held. Fix the cause, then call epic_retry with %s \
and %s."
                          (rat-kingdom-epic--name record) task
                          (plist-get (plist-get available :payload) :title)
                          (error-message-string err) id task)
                  id))))))))
    (nreverse started)))

(defun rat-kingdom-epic-dispatch (space &optional repo id)
  "Start stories for the ready tasks of the running epics in SPACE.
With REPO, only its epics; with ID too, only that epic.  A story is
started for each `available' task of a running epic that is not held
and has no story, while the epic has fewer stories in progress than
its `:max-parallel'.  The worker cap applies to them as usual.  Return
the started stories as (TASK . STORY)."
  (let (started)
    (dolist (record (rat-kingdom-space-scan
                     space (append (list 'epic :state "running")
                                   (and repo (list :scope repo))
                                   (and id (list :identity id)))))
      (setq started (append started
                            (rat-kingdom-epic--dispatch-one
                             space (plist-get record :scope)
                             (plist-get record :identity)))))
    started))

(rat-kingdom-defreaction rat-kingdom-epic-dispatch-ready
  "Start stories for a running epic's tasks as they become available.
It fires again whenever the epic's tuple is replaced, as when it is
resumed or a task is retried."
  :read ((available :scope $repo :parent $epic)
         (epic :scope $repo :identity $epic :state running))
  (rat-kingdom-epic-dispatch rat-kingdom-reaction-space $repo $epic))

;;;; Ends

(defun rat-kingdom-epic--finish-if-done (space repo id)
  "Mark the epic ID of REPO in SPACE done if every task of it is closed.
Close the br epic too, and tell the king.  An epic with a feature
branch is not done then but lands (`rat-kingdom-epic--land').  Return
non-nil if it was done, or began to land, now.  A tracker that fails
leaves the epic as it is."
  (let ((record (rat-kingdom-epic-record space id repo)))
    (when (member (rat-kingdom-epic--payload record :state)
                  rat-kingdom-epic-building-states)
      (let ((children (condition-case err
                          (rat-kingdom-epic--children space repo id)
                        (error
                         (message "rat-kingdom: the tasks of the epic %s: %s"
                                  id (error-message-string err))
                         nil))))
        (when (and children (cl-every #'rat-kingdom-epic--closed-p children))
          (if (rat-kingdom-epic--payload record :branch)
              (rat-kingdom-epic--land space repo id
                                      rat-kingdom-epic-building-states)
          (let* ((total (length children))
                 (merged (length (cl-intersection
                                  (rat-kingdom-epic--payload record :merged)
                                  (mapcar (lambda (task) (plist-get task :id))
                                          children)
                                  :test #'equal)))
                 (reason (if (= merged total)
                             (format "All %d tasks merged" total)
                           (format "All %d tasks closed, %d merged by its \
stories" total merged)))
                 (closed (rat-kingdom-epic--problem
                          #'rat-kingdom-task-close
                          (rat-kingdom-epic--adapter space repo) id reason)))
            (when (rat-kingdom-space-with-transaction space
                    (when (rat-kingdom-epic--update
                           space repo id
                           (lambda (payload)
                             (when (member (plist-get payload :state)
                                           rat-kingdom-epic-building-states)
                               (plist-put (plist-put payload :state "done")
                                          :finished
                                          (funcall
                                           rat-kingdom-space-now-function)))))
                      (rat-kingdom-epic--tell
                       space repo
                       (concat (format "Epic %s is done: %s."
                                       (rat-kingdom-epic--name record)
                                       (if (= merged total)
                                           (format "%d stories merged" merged)
                                         (format "all %d tasks are closed, %d of \
them by merged stories" total merged)))
                               (if closed
                                   (format " The br epic %s could not be \
closed: %s"
                                           id closed)
                                 (format " The br epic %s is closed." id))))
                      t))
              (rat-kingdom-epic--ended space repo id)
              t))))))))

;;;; Landing an epic with a feature branch

(defun rat-kingdom-epic--set (payload &rest changes)
  "Return PAYLOAD with CHANGES, a property list, put into it."
  (while changes
    (setq payload (plist-put payload (pop changes) (pop changes))))
  payload)

(defun rat-kingdom-epic-branch-name (id)
  "Return the name of the feature branch of the epic ID."
  (concat rat-kingdom-epic-branch-prefix id))

(defun rat-kingdom-epic--prepare-branch (path branch target)
  "Make BRANCH, an epic's feature branch, at TARGET's head, or check it.
PATH is the repository.  A BRANCH that exists is kept if it continues
from TARGET, that is if TARGET's head is in it, and moved forward to
TARGET if it is behind TARGET with no commits of its own.  Signal an
error if it is checked out, or has diverged from TARGET.  Return a
sentence saying what was done."
  (let ((ref (concat "refs/heads/" branch)))
    (unless (rat-kingdom-git-ok-p path "check-ref-format" ref)
      (error "%s is not a valid branch name" branch))
    (cond
     ((not (rat-kingdom-git-ok-p path "rev-parse" "--verify" "--quiet" ref))
      (rat-kingdom-git path "branch" branch target)
      (format "Created the branch %s from %s." branch target))
     ((rat-kingdom-git-checked-out-p path branch)
      (error "The branch %s exists and is checked out in a worktree; check \
out another branch there, then start the epic again" branch))
     ((rat-kingdom-git-ancestor-p path target ref)
      (format "Kept the branch %s, which already continues from %s." branch
              target))
     ((rat-kingdom-git-ancestor-p path ref target)
      (rat-kingdom-git path "update-ref" "-m" "rat-kingdom: epic branch"
                       ref (rat-kingdom-git-rev path target)
                       (rat-kingdom-git-rev path ref))
      (format "Moved the branch %s, which had no commits of its own, forward \
to %s." branch target))
     (t
      (error "The branch %s already exists and has diverged from %s: each \
has commits the other lacks, so it is not a continuation of %s. Merge %s into \
it, or delete it (git branch -D %s), then start the epic again"
             branch target target target branch)))))

(defun rat-kingdom-epic--token (record)
  "Return what the landing check of the epic RECORD is recorded under."
  (list :scope (plist-get record :scope) :identity (plist-get record :identity)))

(defun rat-kingdom-epic--candidate (repo id)
  "Return the candidate worktree the epic ID of REPO lands through."
  (expand-file-name (format "candidates/%s/epic-%s" repo id)
                    rat-kingdom-directory))

(defun rat-kingdom-epic--remove-candidate (space record)
  "Abandon the landing check of the epic RECORD in SPACE and remove its candidate."
  (rat-kingdom-story--abandon-check (plist-get record :identity))
  (when-let* ((candidate (rat-kingdom-epic--payload record :candidate))
              (repo (rat-kingdom-repo-get space (plist-get record :scope))))
    (with-demoted-errors "rat-kingdom: removing a candidate: %S"
      (rat-kingdom-story--remove-candidate (plist-get repo :path) candidate))))

(defun rat-kingdom-epic--stop-landing (space repo id why)
  "Pause the epic ID of REPO in SPACE, whose landing cannot go on because WHY.
Tell the king; `epic_resume' lands it again."
  (rat-kingdom-space-with-transaction space
    (when-let* ((record (rat-kingdom-epic--update
                         space repo id
                         (lambda (payload)
                           (rat-kingdom-epic--set payload :state "paused"
                                                  :landing nil :fix-task nil)))))
      (rat-kingdom-epic--tell
       space repo
       (format "Epic %s could not land on %s: %s\nIt is paused. Fix the \
cause, then epic_resume lands it again."
               (rat-kingdom-epic--name record)
               (rat-kingdom-epic--target space record) why)))))

(defun rat-kingdom-epic--land (space repo id from)
  "Begin landing the epic ID of REPO in SPACE, if it is in a state of FROM.
Its feature branch is merged into its target in a fresh candidate
worktree, and the repository's setup and check run there, by
`rat-kingdom-story-check-candidate', as for a story.  The outcome is a
`checked' tuple named by the epic, which
`rat-kingdom-epic-landing-checked' takes from there.  The epic is
`landing', waiting for the check, meanwhile.  If the check cannot be
begun, the epic is paused and the king told.  Return non-nil if landing
began."
  (when-let* ((record (rat-kingdom-epic--update
                       space repo id
                       (lambda (payload)
                         (when (member (plist-get payload :state) from)
                           (rat-kingdom-epic--set
                            payload :state "landing" :landing "check"
                            :fix-task nil
                            :candidate (rat-kingdom-epic--candidate repo id)))))))
    (condition-case err
        (let* ((repo-record (or (rat-kingdom-repo-get space repo)
                                (error "The repository %s is no longer \
registered" repo)))
               (path (plist-get repo-record :path))
               (branch (rat-kingdom-epic--payload record :branch)))
          (rat-kingdom-story-check-candidate
           space (rat-kingdom-epic--token record) path
           (rat-kingdom-epic--target space record)
           (rat-kingdom-git-rev path (concat "refs/heads/" branch))
           (rat-kingdom-epic--payload record :candidate)
           (format "Merge the epic %s: %s" id
                   (rat-kingdom-epic--payload record :title))
           (plist-get repo-record :check) (plist-get repo-record :setup)))
      (error
       (rat-kingdom-epic--stop-landing
        space repo id (format "its check could not be begun: %s"
                              (error-message-string err)))))
    t))

(defun rat-kingdom-epic--add-task (space repo id title description why)
  "Add the task TITLE with DESCRIPTION to the epic ID of REPO in SPACE.
It is work the epic's landing needs; WHY says what for, for the king.
The epic runs again, its landing waiting for the task, and dispatch
starts the task's story on the epic's branch.  Return (TASK . STARTED),
STARTED being the stories started, as (TASK . STORY).  If the tracker
fails, pause the epic instead, tell the king, and return nil."
  (let ((task (condition-case err
                  (rat-kingdom-task-create (rat-kingdom-epic--adapter space repo)
                                           title :description description
                                           :parent id)
                (error
                 (rat-kingdom-epic--stop-landing
                  space repo id
                  (format "%s, and the tracker failed to create a task in it \
to put that right: %s" why (rat-kingdom-epic--message err)))
                 nil))))
    (when task
      (let ((record (rat-kingdom-epic--update
                     space repo id
                     (lambda (payload)
                       (rat-kingdom-epic--set payload :state "running"
                                              :landing "fix" :fix-task task
                                              :reviewed nil)))))
        (rat-kingdom-epic--tell
         space repo
         (format "Epic %s cannot land on %s yet: %s. Created the task %s in \
it (%s); the engine starts its story on %s, and when it is merged the epic \
lands again."
                 (rat-kingdom-epic--name record)
                 (rat-kingdom-epic--target space record) why task title
                 (rat-kingdom-epic--payload record :branch)))
        (with-demoted-errors "rat-kingdom: projecting tasks: %S"
          (rat-kingdom-task-project space repo))
        (cons task (rat-kingdom-epic-dispatch space repo id))))))

(defun rat-kingdom-epic--landing-problem (record target checked)
  "Return the description of the task that puts right a failed landing.
RECORD is the epic, TARGET where it lands, and CHECKED the outcome of
its landing check."
  (let* ((branch (rat-kingdom-epic--payload record :branch))
         (name (rat-kingdom-epic--name record))
         (conflict (equal (plist-get checked :reason) "merge conflict")))
    (concat
     (pcase (plist-get checked :reason)
       ("merge conflict"
        (format "The epic %s cannot land on %s: its branch %s no longer \
merges cleanly into %s, which has moved on since." name target branch target))
       ("setup failed"
        (format "The epic %s cannot land on %s: with its branch %s merged \
into %s, the repository's setup %s exited with %s, so the check did not run."
                name target branch target
                (combine-and-quote-strings (plist-get checked :setup))
                (plist-get checked :exit)))
       (_
        (format "The epic %s cannot land on %s: with its branch %s merged \
into %s, the check %s exited with %s."
                name target branch target
                (combine-and-quote-strings (plist-get checked :check))
                (plist-get checked :exit))))
     (format "\n\nMerge %s into your branch (git merge %s), %s, make sure the \
repository's check passes, and commit. Your branch is cut from %s and your \
work is merged into it; then the epic tries to land again.\n\n%s\n%s"
             target target
             (if conflict "resolve the conflicts" "fix what breaks")
             branch
             (if conflict "Files in conflict:" "The end of its output:")
             (or (plist-get checked :output) "")))))

(defun rat-kingdom-epic--landing-failed (space record checked)
  "Turn the failed landing check CHECKED of the epic RECORD in SPACE into work.
A task in the epic, to merge the target into the epic's branch and fix
what breaks, is started on that branch."
  (let ((target (rat-kingdom-epic--target space record)))
    (rat-kingdom-epic--add-task
     space (plist-get record :scope) (plist-get record :identity)
     (format "Merge %s into the epic branch and fix what breaks" target)
     (rat-kingdom-epic--landing-problem record target checked)
     (pcase (plist-get checked :reason)
       ("merge conflict" (format "its branch no longer merges cleanly into \
%s, which has moved on (in conflict: %s)"
                                 target
                                 (string-join
                                  (split-string (or (plist-get checked :output)
                                                    "")
                                                "\n" t)
                                  ", ")))
       ("setup failed" "the repository's setup failed with the branch merged")
       (_ (format "the check failed with the branch merged (exit %s)"
                  (plist-get checked :exit)))))))

(defun rat-kingdom-epic--landed (space repo id head)
  "Mark the epic ID of REPO in SPACE done, its target moved to HEAD.
Remove its candidate, close the br epic and tell the king.  The
epic's branch is kept."
  (let* ((record (rat-kingdom-epic-record space id repo))
         (target (rat-kingdom-epic--target space record))
         (short (substring head 0 (min 7 (length head))))
         (closed (rat-kingdom-epic--problem
                  #'rat-kingdom-task-close (rat-kingdom-epic--adapter space repo)
                  id (format "Landed on %s at %s" target short))))
    (rat-kingdom-epic--remove-candidate space record)
    (rat-kingdom-space-with-transaction space
      (rat-kingdom-epic--update
       space repo id
       (lambda (payload)
         (rat-kingdom-epic--set payload :state "done" :landing nil
                                :landed head
                                :finished (funcall rat-kingdom-space-now-function))))
      (rat-kingdom-epic--tell
       space repo
       (format "Epic %s landed on %s at %s: %d stories.%s Its branch %s is \
kept for the user to delete (git branch -d %s)."
               (rat-kingdom-epic--name record) target short
               (length (rat-kingdom-epic--payload record :merged))
               (if closed
                   (format " The br epic %s could not be closed: %s" id closed)
                 (format " The br epic %s is closed." id))
               (rat-kingdom-epic--payload record :branch)
               (rat-kingdom-epic--payload record :branch))))
    (rat-kingdom-epic--ended space repo id)))

(defun rat-kingdom-epic--move-target (space repo id)
  "Land the epic ID of REPO in SPACE, whose landing passed its check and review.
Move its target to the checked merge with a compare-and-swap, as a
story's merge does: only if the target is still where the check found
it.  Return the commit the target is now at if the epic landed.  If
the target or the epic's branch moved after the check, land again,
checking anew, and return nil.  Signal an error if the target is
checked out in a worktree."
  (let* ((record (rat-kingdom-epic-record space id repo))
         (path (plist-get (or (rat-kingdom-repo-get space repo)
                              (error "The repository %s is no longer \
registered" repo))
                          :path))
         (target (rat-kingdom-epic--target space record))
         (branch (rat-kingdom-epic--payload record :branch))
         (head (rat-kingdom-epic--payload record :head))
         (base (rat-kingdom-epic--payload record :base))
         (current (rat-kingdom-git-rev path target))
         (stale
          (cond
           ((equal current head) nil)
           ((not (equal (rat-kingdom-git-rev path (concat "refs/heads/" branch))
                        (rat-kingdom-epic--payload record :commit)))
            t)
           ((not (equal current base)) t)
           ((rat-kingdom-git-checked-out-p path target)
            (error "%s is checked out in a worktree of %s. Check out another \
branch there, then give the verdict again" target repo))
           ;; Moves the target only if it is still where the check began.
           (t (not (rat-kingdom-git-ok-p
                    path "update-ref" "-m"
                    (format "rat-kingdom: land the epic %s" id)
                    (concat "refs/heads/" target) head base))))))
    (if stale
        (progn (rat-kingdom-epic--land space repo id '("landing"))
               nil)
      (rat-kingdom-epic--landed space repo id head)
      head)))

(defun rat-kingdom-epic--landing-checked (space repo id checked)
  "Move on the epic ID of REPO in SPACE, whose landing check came out CHECKED.
CHECKED is the payload of the `checked' tuple, which is retracted.  A
check that failed, or a merge that conflicted, becomes a task of the
epic (`rat-kingdom-epic--landing-failed').  One that passed asks the
king for a review, unless the same branch was reviewed already, which
happens when the target moved after the verdict: then the epic lands."
  (rat-kingdom-space-retract space (list 'checked :scope repo :identity id)
                             :actor "engine")
  (let ((record (rat-kingdom-epic-record space id repo)))
    (if (not (equal (plist-get checked :value) "pass"))
        (rat-kingdom-epic--landing-failed space record checked)
      (let ((reviewed (and (rat-kingdom-epic--payload record :reviewed)
                           (equal (rat-kingdom-epic--payload record :reviewed)
                                  (plist-get checked :commit))))
            (record (rat-kingdom-epic--update
                     space repo id
                     (lambda (payload)
                       (rat-kingdom-epic--set
                        payload :landing "review"
                        :commit (plist-get checked :commit)
                        :base (plist-get checked :base)
                        :head (plist-get checked :head))))))
        (if reviewed
            (condition-case err
                (rat-kingdom-epic--move-target space repo id)
              (error
               (rat-kingdom-epic--tell
                space repo
                (format "Epic %s passed its check again but could not land: \
%s\nGive epic_verdict pass again once that is put right."
                        (rat-kingdom-epic--name record)
                        (error-message-string err)))))
          (rat-kingdom-epic--tell
           space repo
           (format "Epic %s is ready to land on %s: %d stories, review with \
epic_diff and give epic_verdict."
                   (rat-kingdom-epic--name record)
                   (rat-kingdom-epic--target space record)
                   (length (rat-kingdom-epic--payload record :merged)))))))))

(rat-kingdom-defreaction rat-kingdom-epic-landing-checked
  "Move on an epic whose landing check has come out."
  :read ((epic :scope $repo :identity $epic :state landing :landing check)
         (checked :scope $repo :identity $epic))
  (let ((space rat-kingdom-reaction-space))
    (rat-kingdom-epic--landing-checked
     space $repo $epic
     (plist-get (rat-kingdom-space-rd space (list 'checked :scope $repo
                                                  :identity $epic))
                :payload))))

(defun rat-kingdom-epic-verdict (space id value &optional notes)
  "Act on the verdict VALUE on the epic ID in SPACE, which waits for one.
VALUE is \"pass\" or \"fix\".  Pass moves the epic's target to the
checked merge of its branch, and the epic is done; if the target or the
branch moved after the check, the epic is checked again and lands
without another review.  Fix, with NOTES saying what to change, adds a
task to the epic with NOTES as its description, which is started on
the epic's branch, and the epic lands again once it is merged.  Return
a text saying what happened."
  (let* ((record (rat-kingdom-epic--get space id))
         (repo (plist-get record :scope))
         (value (rat-kingdom-workflow--name value)))
    (unless (and (equal (rat-kingdom-epic--payload record :state) "landing")
                 (equal (rat-kingdom-epic--payload record :landing) "review"))
      (error "The epic %s is not waiting for a verdict: it is %s%s" id
             (rat-kingdom-epic--payload record :state)
             (if-let* ((phrase (rat-kingdom-epic--landing-phrase space record)))
                 (format "; %s" phrase)
               ", with no feature branch")))
    (unless (member value '("pass" "fix"))
      (error "A verdict is pass or fix, not %s" value))
    (when (and (equal value "fix") (rat-kingdom-epic--blank-p notes))
      (error "A verdict of fix needs notes that say what to change"))
    (if (equal value "pass")
        (progn
          (rat-kingdom-epic--update
           space repo id
           (lambda (payload)
             (plist-put payload :reviewed (plist-get payload :commit)))
           rat-kingdom-king-id)
          (if-let* ((head (rat-kingdom-epic--move-target space repo id)))
              (format "Landed the epic %s on %s at %s. It is done and the br \
epic is closed. Its branch %s is kept for the user to delete."
                      (rat-kingdom-epic--name record)
                      (rat-kingdom-epic--target space record)
                      (substring head 0 7)
                      (rat-kingdom-epic--payload record :branch))
            (format "Recorded. %s or the epic's branch moved after the check, \
so the epic is checked again on top of it; if that passes it lands without \
another review."
                    (rat-kingdom-epic--target space record))))
      (rat-kingdom-epic--remove-candidate space record)
      (if-let* ((added (rat-kingdom-epic--add-task
                        space repo id
                        (format "Fix what the review of the epic %s asked for"
                                id)
                        notes "the review asked for changes")))
          (format "Recorded. Created the task %s in the epic with your notes. \
%s When it is merged, the epic is checked and lands again, after another \
epic_verdict."
                  (car added)
                  (if-let* ((story (cdr (assoc (car added) (cdr added)))))
                      (format "Started %s for it on %s." story
                              (rat-kingdom-epic--payload record :branch))
                    (format "It starts on %s when the epic has room."
                            (rat-kingdom-epic--payload record :branch))))
        "The tracker could not create a task for your notes, so the epic is \
paused; see the news. epic_resume lands it again."))))

(defun rat-kingdom-epic-reconcile (space)
  "Run again in SPACE each landing check that an Emacs that stopped cut off.
That is the check of a landing epic that is not running here and has
recorded no outcome; it is begun afresh in a new candidate, as an
interrupted story check is.  Return the ids of the epics checked again."
  (let (found)
    (dolist (record (rat-kingdom-space-scan
                     space '(epic :state "landing" :landing "check")))
      (let ((id (plist-get record :identity))
            (repo (plist-get record :scope)))
        (unless (or (gethash id rat-kingdom-story--checks)
                    (rat-kingdom-space-rd space (list 'checked :scope repo
                                                      :identity id)))
          (when (rat-kingdom-epic--land space repo id '("landing"))
            (push id found)))))
    (nreverse found)))

(defun rat-kingdom-epic--landing-phrase (space record)
  "Return what the epic RECORD in SPACE has to say of its feature branch.
Return nil if it has none."
  (when-let* ((branch (rat-kingdom-epic--payload record :branch)))
    (format "branch %s, landing on %s: %s" branch
            (rat-kingdom-epic--target space record)
            (pcase (list (rat-kingdom-epic--payload record :state)
                         (rat-kingdom-epic--payload record :landing))
              (`("landing" "check")
               "waiting for the check of the branch merged into it")
              (`("landing" "review")
               "waiting for your review (epic_diff, then epic_verdict)")
              (`(,_ "fix")
               (format "waiting for the task %s to be merged, then checked \
again"
                       (rat-kingdom-epic--payload record :fix-task)))
              (`("done" ,_)
               (if-let* ((landed (rat-kingdom-epic--payload record :landed)))
                   (format "landed at %s" (substring landed 0 7))
                 "done"))
              (`("cancelled" ,_) "cancelled; the branch is kept")
              (_ "once every task is closed, after one check and \
epic_verdict")))))

(defun rat-kingdom-epic--story-event (space event story)
  "Keep the epic of the token STORY in SPACE up to date after EVENT.
For `rat-kingdom-story-event-functions'.  A merged story's task is
recorded as merged.  A story that ended otherwise, or was cancelled,
leaves its task held, so that dispatch does not start it again when it
is released, unless its epic has ended."
  (let* ((payload (plist-get story :payload))
         (id (plist-get payload :epic))
         (task (plist-get payload :task))
         (repo (plist-get story :scope))
         (record (and id task (rat-kingdom-epic-record space id repo))))
    (when record
      (pcase event
        ('done
         (if (plist-get payload :integrated)
             (rat-kingdom-epic--update
              space repo id
              (lambda (payload)
                (unless (member task (plist-get payload :merged))
                  (plist-put payload :merged
                             (append (plist-get payload :merged)
                                     (list task))))))
           (when (rat-kingdom-epic--live-p record)
             (rat-kingdom-epic--hold
              space repo id task
              (format "its story %s ended at %s without being merged"
                      (plist-get story :identity) (plist-get payload :at))))))
        ('cancelled
         (when (rat-kingdom-epic--live-p record)
           (rat-kingdom-epic--hold
            space repo id task
            (format "its story %s was cancelled"
                    (plist-get story :identity)))))))))

(defun rat-kingdom-epic--news (space event story)
  "Return what the king should hear about EVENT to STORY's epic in SPACE.
For `rat-kingdom-king-news-functions'."
  (let* ((payload (plist-get story :payload))
         (id (plist-get payload :epic))
         (task (plist-get payload :task))
         (repo (plist-get story :scope))
         (record (and id task (rat-kingdom-epic-record space id repo))))
    (when (rat-kingdom-epic--live-p record)
      (pcase event
        ('parked
         (let ((dependents
                (condition-case err
                    (rat-kingdom-epic--dependents
                     task (rat-kingdom-epic--children space repo id))
                  (error (error-message-string err)))))
           (format "It is the story of the task %s of the epic %s. %s"
                   task (rat-kingdom-epic--name record)
                   (cond ((stringp dependents)
                          (format "Which of its tasks wait on it is not \
known: the tracker failed (%s)." dependents))
                         (dependents
                          (format "Tasks of the epic now waiting on it: %s. \
None of them starts until it is merged."
                                  (rat-kingdom-epic--describe-dependents
                                   dependents)))
                         (t "No other task of the epic waits on it.")))))
        ((or 'cancelled
             (and 'done (guard (not (plist-get payload :integrated)))))
         (format "Its task %s of the epic %s is now held: the engine will not \
start it again by itself. If it should be done after all, call epic_retry \
with %s and %s."
                 task (rat-kingdom-epic--name record) id task))))))

(defun rat-kingdom-epic--story-settled (space story)
  "Move the epic of the token STORY in SPACE on, now that its task is settled.
For `rat-kingdom-task-settled-functions': the epic may be done, or
have room for another story."
  (when-let* ((id (plist-get (plist-get story :payload) :epic)))
    (let ((repo (plist-get story :scope)))
      (rat-kingdom-epic--finish-if-done space repo id)
      (rat-kingdom-epic-dispatch space repo id))))

(defun rat-kingdom-epic-recover (space)
  "Bring the epics of SPACE up to date, as when `rat-kingdom-mode' starts.
An epic whose tasks are all closed is done; then the running ones are
dispatched.  Return the started stories as (TASK . STORY)."
  (dolist (record (rat-kingdom-space-scan space '(epic)))
    (with-demoted-errors "rat-kingdom: an epic: %S"
      (rat-kingdom-epic--finish-if-done space (plist-get record :scope)
                                        (plist-get record :identity))))
  (rat-kingdom-epic-dispatch space))

(add-hook 'rat-kingdom-story-event-functions #'rat-kingdom-epic--story-event)
(add-hook 'rat-kingdom-king-news-functions #'rat-kingdom-epic--news)
(add-hook 'rat-kingdom-task-settled-functions #'rat-kingdom-epic--story-settled)

;;;; Views

(defun rat-kingdom-epic--story-place (story)
  "Return where the token STORY is, in a few words."
  (let ((payload (plist-get story :payload)))
    (format "at %s%s" (plist-get payload :at)
            (pcase (plist-get payload :phase)
              ("wait" (format " (waiting for %s)" (plist-get payload :awaiting)))
              ("parked" " (stopped)")
              ("enter" " (starting)")
              (_ "")))))

(defun rat-kingdom-epic--parked-p (story)
  "Return non-nil if the token STORY is stopped until someone moves it."
  (equal (plist-get (plist-get story :payload) :phase) "parked"))

(defun rat-kingdom-epic--tasks (space record)
  "Return the tasks of the epic RECORD in SPACE, with where each stands.
Each is the tracker's task with `:story', the token of its story in
progress if any, `:held', why it is held, `:available', non-nil if it
is available, `:waits', the open tasks it waits on, and `:class':
`closed', `story', `held', `ready', `waiting' or `other'.  Signal an
error if the tracker fails."
  (let* ((repo (plist-get record :scope))
         (id (plist-get record :identity))
         (children (rat-kingdom-epic--children space repo id))
         (stories (rat-kingdom-epic--stories space repo id)))
    (mapcar
     (lambda (task)
       (let* ((task-id (plist-get task :id))
              (story (or (cl-find task-id stories
                                  :key (lambda (story)
                                         (plist-get (plist-get story :payload)
                                                    :task))
                                  :test #'equal)
                         (rat-kingdom-space-rd space (list 'story :scope repo
                                                           :task task-id))))
              (held (rat-kingdom-epic--held-reason record task-id))
              (available (rat-kingdom-space-rd
                          space (list 'available :scope repo
                                      :identity task-id)))
              (waits (rat-kingdom-epic--waits-on task children)))
         (append (list :story story :held held :available (and available t)
                       :waits waits
                       :class (cond ((rat-kingdom-epic--closed-p task) 'closed)
                                    (story 'story)
                                    (held 'held)
                                    (available 'ready)
                                    (waits 'waiting)
                                    (t 'other)))
                 task)))
     children)))

(defun rat-kingdom-epic--progress (record tasks)
  "Return how far the epic RECORD with TASKS has come, as \"M/N merged\"."
  (let ((merged (cl-count-if (lambda (task)
                               (member (plist-get task :id)
                                       (rat-kingdom-epic--payload record
                                                                  :merged)))
                             tasks))
        (closed (cl-count 'closed tasks
                          :key (lambda (task) (plist-get task :class)))))
    (format "%d/%d merged%s" merged (length tasks)
            (if (/= merged closed) (format " (%d closed)" closed) ""))))

(defun rat-kingdom-epic--held-up (tasks)
  "Return the tasks among TASKS held up behind a stopped story.
Each is (STORY TASK DEPENDENTS): the token of a story that is stopped,
its task's id, and its open dependents as `rat-kingdom-epic--dependents'
gives them."
  (delq nil
        (mapcar (lambda (task)
                  (let ((story (plist-get task :story)))
                    (when (and story (rat-kingdom-epic--parked-p story))
                      (list story (plist-get task :id)
                            (rat-kingdom-epic--dependents
                             (plist-get task :id) tasks)))))
                tasks)))

(defun rat-kingdom-epic--state-phrase (record)
  "Return the state of the epic RECORD, with its limit if it has one."
  (concat (rat-kingdom-epic--payload record :state)
          (when-let* ((limit (rat-kingdom-epic--payload record :max-parallel)))
            (format ", at most %d stories at once" limit))))

(defun rat-kingdom-epic-foreman-phrase (space record)
  "Return what the epic RECORD in SPACE has to say of its foreman, or nil.
That is \"foreman F-ID (AGENT, STATE)\": STATE is working or idle while
its agent runs, starting before then, and stopped, with why if it did
not stop on purpose, after."
  (when-let* ((id (rat-kingdom-epic--payload record :foreman)))
    (let* ((run (rat-kingdom-run-get space id))
           (state (plist-get run :state)))
      (format "foreman %s (%s, %s)" id
              (or (plist-get run :agent) rat-kingdom-agent-shell-fallback-agent)
              (cond ((rat-kingdom-run-live-p id)
                     (if (rat-kingdom-run-busy-p id) "working" "idle"))
                    ((equal state "starting") "starting")
                    ((member state '(nil "stopped")) "stopped")
                    (t (format "stopped: %s" state)))))))

(defun rat-kingdom-epic--status-entry (space record)
  "Return the lines `status' gives for the epic RECORD in SPACE."
  (let ((head (format "- %s [%s] %s: %s"
                      (plist-get record :identity) (plist-get record :scope)
                      (rat-kingdom-epic--payload record :title)
                      (rat-kingdom-epic--state-phrase record))))
    (condition-case err
        (let* ((tasks (rat-kingdom-epic--tasks space record))
               (stories (cl-remove-if-not (lambda (task)
                                            (eq (plist-get task :class) 'story))
                                          tasks))
               (held (cl-remove-if-not (lambda (task)
                                         (eq (plist-get task :class) 'held))
                                       tasks))
               (waiting (cl-count 'waiting tasks
                                  :key (lambda (task) (plist-get task :class)))))
          (string-join
           (delq nil
                 (list
                  (format "%s, %s" head (rat-kingdom-epic--progress record tasks))
                  (when-let* ((phrase (rat-kingdom-epic--landing-phrase
                                       space record)))
                    (concat "    " phrase))
                  (when-let* ((phrase (rat-kingdom-epic-foreman-phrase
                                       space record)))
                    (concat "    " phrase))
                  (and stories
                       (format "    in progress: %s"
                               (mapconcat
                                (lambda (task)
                                  (let ((story (plist-get task :story)))
                                    (format "%s for %s %s"
                                            (plist-get story :identity)
                                            (plist-get task :id)
                                            (rat-kingdom-epic--story-place
                                             story))))
                                stories ", ")))
                  (when-let* ((up (rat-kingdom-epic--held-up tasks)))
                    (mapconcat
                     (lambda (entry)
                       (format "    held up behind the stopped %s (%s): %s"
                               (plist-get (nth 0 entry) :identity) (nth 1 entry)
                               (if (nth 2 entry)
                                   (rat-kingdom-epic--describe-dependents
                                    (nth 2 entry))
                                 "nothing else")))
                     up "\n"))
                  (and held
                       (format "    held (epic_retry starts one again): %s"
                               (mapconcat (lambda (task)
                                            (format "%s, %s" (plist-get task :id)
                                                    (plist-get task :held)))
                                          held "; ")))
                  (and (> waiting 0)
                       (format "    waiting on other tasks: %d" waiting))))
           "\n"))
      (error (format "%s; its tasks could not be read: %s" head
                     (rat-kingdom-epic--message err))))))

(defun rat-kingdom-epic-status (space)
  "Return the Epics section of `status' for SPACE, or nil if there are none.
It lists each epic that is running or paused.
For `rat-kingdom-king-status-functions'."
  (when-let* ((records (cl-remove-if-not #'rat-kingdom-epic--live-p
                                         (rat-kingdom-space-scan space '(epic)))))
    (concat "Epics (epic_show gives one in full):\n"
            (mapconcat (lambda (record)
                         (rat-kingdom-epic--status-entry space record))
                       records "\n"))))

(add-hook 'rat-kingdom-king-status-functions #'rat-kingdom-epic-status)

(defun rat-kingdom-epic--cell (text)
  "Return TEXT fit for a cell of a Markdown table."
  (replace-regexp-in-string "[|\n]" " " (format "%s" (or text ""))))

(defun rat-kingdom-epic--task-status (task)
  "Return what the table of `epic_show' says of the state of TASK."
  (let ((status (plist-get task :status)))
    (pcase (plist-get task :class)
      ('closed (format "%s%s" status
                       (if (plist-get task :merged) " (merged)" "")))
      ('story (format "%s, story in progress" status))
      ('held (format "%s, held: %s" status (plist-get task :held)))
      ('ready (format "%s, ready" status))
      ('waiting (format "%s, waiting" status))
      (_ (format "%s, not ready in the tracker" status)))))

(defun rat-kingdom-epic-show (space id)
  "Return a text with everything about the epic ID in SPACE."
  (let* ((record (rat-kingdom-epic--get space id))
         (payload (plist-get record :payload))
         (now (funcall rat-kingdom-space-now-function))
         (tasks (mapcar (lambda (task)
                          (append (list :merged
                                        (member (plist-get task :id)
                                                (plist-get payload :merged)))
                                  task))
                        (rat-kingdom-epic--tasks space record))))
    (concat
     (format "Epic %s in %s: %s\nState: %s%s. %s.\n%s%s"
             id (plist-get record :scope) (plist-get payload :title)
             (rat-kingdom-epic--state-phrase record)
             (cond ((plist-get payload :finished)
                    (format ", ended %s ago"
                            (rat-kingdom-king--age
                             (round (- now (plist-get payload :finished))))))
                   ((plist-get payload :started)
                    (format ", started %s ago"
                            (rat-kingdom-king--age
                             (round (- now (plist-get payload :started))))))
                   (t ""))
             (rat-kingdom-epic--progress record tasks)
             (if-let* ((phrase (rat-kingdom-epic--landing-phrase space record)))
                 (format "Feature %s.\n" phrase)
               "")
             (if-let* ((phrase (rat-kingdom-epic-foreman-phrase space record)))
                 (format "It has a %s.\n" phrase)
               ""))
     "\n| task | title | status | story | agent | waits on |\n"
     "|---|---|---|---|---|---|\n"
     (mapconcat
      (lambda (task)
        (let ((story (plist-get task :story)))
          (format "| %s | %s | %s | %s | %s | %s |"
                  (plist-get task :id)
                  (rat-kingdom-epic--cell (plist-get task :title))
                  (rat-kingdom-epic--cell (rat-kingdom-epic--task-status task))
                  (if story
                      (rat-kingdom-epic--cell
                       (format "%s %s" (plist-get story :identity)
                               (rat-kingdom-epic--story-place story)))
                    "-")
                  (or (rat-kingdom-task-agent task)
                      (format "default (%s)" (rat-kingdom-agent-name nil)))
                  (if (plist-get task :waits)
                      (string-join (plist-get task :waits) ", ")
                    "-"))))
      tasks "\n")
     (if-let* ((up (rat-kingdom-epic--held-up tasks)))
         (concat "\n\n"
                 (mapconcat
                  (lambda (entry)
                    (format "%s (%s) has stopped: %s. Waiting on it: %s."
                            (plist-get (nth 0 entry) :identity) (nth 1 entry)
                            (string-trim-right
                             (or (plist-get (plist-get (nth 0 entry) :payload)
                                            :reason)
                                 "no reason given")
                             "[. \t\n]+")
                            (if (nth 2 entry)
                                (rat-kingdom-epic--describe-dependents
                                 (nth 2 entry))
                              "nothing else")))
                  up "\n"))
       ""))))

(defun rat-kingdom-epic--answer (space record started &optional opening
                                       closing)
  "Return what the king is told after the epic RECORD in SPACE dispatched.
STARTED are the stories it started, as (TASK . STORY).  OPENING is the
first sentence, and CLOSING, if given, the last paragraph."
  (let* ((record (or (rat-kingdom-epic-record space (plist-get record :identity)
                                              (plist-get record :scope))
                     record))
         (tasks (condition-case nil
                    (rat-kingdom-epic--tasks space record)
                  (error nil)))
         (title (lambda (task-id)
                  (or (plist-get (cl-find task-id tasks
                                          :key (lambda (task)
                                                 (plist-get task :id))
                                          :test #'equal)
                                 :title)
                      "")))
         (of (lambda (class)
               (cl-remove-if-not (lambda (task)
                                   (eq (plist-get task :class) class))
                                 tasks)))
         (earlier (cl-remove-if (lambda (task)
                                  (assoc (plist-get task :id) started))
                                (funcall of 'story)))
         (state (rat-kingdom-epic--payload record :state)))
    (string-join
     (delq nil
           (list
            opening
            (if started
                (concat
                 "Stories started now:\n"
                 (mapconcat
                  (lambda (entry)
                    (let ((story (rat-kingdom-story-get space (cdr entry))))
                      (format "- %s for %s (%s), %s"
                              (cdr entry) (car entry)
                              (funcall title (car entry))
                              (cond
                               ((null story) "already over")
                               ((equal (plist-get (plist-get story :payload)
                                                  :awaiting)
                                       rat-kingdom-story-free-worker)
                                (format "queued for a free worker: at most %s \
workers run at once" rat-kingdom-story-max-workers))
                               (t (rat-kingdom-epic--story-place story))))))
                  started "\n"))
              "No story was started now.")
            (and earlier
                 (concat "Already in progress:\n"
                         (mapconcat (lambda (task)
                                      (format "- %s for %s (%s), %s"
                                              (plist-get (plist-get task :story)
                                                         :identity)
                                              (plist-get task :id)
                                              (plist-get task :title)
                                              (rat-kingdom-epic--story-place
                                               (plist-get task :story))))
                                    earlier "\n")))
            (when-let* ((ready (funcall of 'ready)))
              (concat (cond
                       ((not (equal state "running"))
                        "Ready, not started while the epic is not running:\n")
                       ((rat-kingdom-epic--payload record :max-parallel)
                        (format "Ready, queued behind max_parallel (%s):\n"
                                (rat-kingdom-epic--payload record
                                                           :max-parallel)))
                       (t "Ready, not started yet:\n"))
                      (mapconcat (lambda (task)
                                   (format "- %s (%s)" (plist-get task :id)
                                           (plist-get task :title)))
                                 ready "\n")))
            (when-let* ((waiting (funcall of 'waiting)))
              (concat "Waiting on other tasks:\n"
                      (mapconcat (lambda (task)
                                   (format "- %s (%s) waits on %s"
                                           (plist-get task :id)
                                           (plist-get task :title)
                                           (string-join (plist-get task :waits)
                                                        ", ")))
                                 waiting "\n")))
            (when-let* ((held (funcall of 'held)))
              (concat "Held, until epic_retry:\n"
                      (mapconcat (lambda (task)
                                   (format "- %s (%s): %s" (plist-get task :id)
                                           (plist-get task :title)
                                           (plist-get task :held)))
                                 held "\n")))
            (when-let* ((other (funcall of 'other)))
              (concat "Open but not ready in the tracker:\n"
                      (mapconcat (lambda (task)
                                   (format "- %s (%s), %s" (plist-get task :id)
                                           (plist-get task :title)
                                           (plist-get task :status)))
                                 other "\n")))
            (and (null tasks)
                 "The epic's tasks could not be read from the tracker.")
            (pcase state
              ("running" "The engine starts the other stories as their tasks \
become ready; review them as usual.")
              ("landing" (format "Every task is closed, so the epic is \
landing: %s."
                                 (rat-kingdom-epic--landing-phrase space
                                                                   record)))
              ("done" (format "Every task is closed, so the epic is done."))
              (_ nil))
            closing))
     "\n\n")))

;;;; The king's tools for running epics

(defun rat-kingdom-epic--run-reactions (space)
  "Run the reactions of SPACE, so that new stories begin, unless they run."
  (unless (memq space rat-kingdom-reaction--running)
    (rat-kingdom-reaction-run space)))

(defun rat-kingdom-epic-start (space repo id &optional max-parallel
                                    feature-branch)
  "Start running the epic ID of REPO in SPACE.
At most MAX-PARALLEL of its stories are in progress at once, if given.
Signal an error if ID is not an epic in REPO's tracker, has no tasks, is
already running, is paused, is landing or is done.  A cancelled epic is
started again, with no task held.  Write its record as running and
dispatch it.  Return the started stories as (TASK . STORY).

With FEATURE-BRANCH non-nil, the epic gets a branch of its own,
`rat-kingdom-epic-branch-name', cut from the head of REPO's target, or
the existing branch of that name if it continues from the target (see
`rat-kingdom-epic--prepare-branch').  Every story of the epic merges
into it, and once every task is closed the epic lands on the target as
one, after one check and `epic_verdict'.  The record keeps the branch
as `:branch' and the target as `:target'."
  (let* ((adapter (rat-kingdom-epic--adapter space repo))
         (epic (condition-case err
                   (rat-kingdom-task-show adapter id)
                 (error (error "The tracker of %s has no epic %s (%s)"
                               repo id (rat-kingdom-epic--message err)))))
         (record (rat-kingdom-epic-record space id repo)))
    (unless (equal (plist-get epic :type) "epic")
      (error "%s is a %s, not an epic" id (or (plist-get epic :type) "task")))
    (pcase (rat-kingdom-epic--payload record :state)
      ("running" (error "The epic %s is already running" id))
      ("paused" (error "The epic %s is paused; resume it with epic_resume" id))
      ("landing" (error "The epic %s is landing on its target; see epic_show"
                        id))
      ("done" (error "The epic %s is done: all its tasks are closed" id)))
    (when (and max-parallel (not (and (integerp max-parallel)
                                      (> max-parallel 0))))
      (error "The argument max_parallel must be a whole number of at least 1, \
not %s"
             max-parallel))
    (unless (rat-kingdom-task-children adapter id)
      (error "The epic %s has no tasks; plan them with epic_create or \
task_create" id))
    (let* ((target (and feature-branch
                        (plist-get (rat-kingdom-repo-get space repo) :target)))
           (branch (and feature-branch (rat-kingdom-epic-branch-name id))))
      (when branch
        (rat-kingdom-epic--prepare-branch
         (plist-get (rat-kingdom-repo-get space repo) :path) branch target))
      (rat-kingdom-space-put
       space 'epic :scope repo :identity id
       :payload (append
                 (list :state "running" :title (plist-get epic :title)
                       :max-parallel max-parallel :held nil
                       :merged (rat-kingdom-epic--payload record :merged)
                       :started (funcall rat-kingdom-space-now-function)
                       :finished nil)
                 (and branch (list :branch branch :target target)))
       :actor rat-kingdom-king-id))
    (rat-kingdom-task-project space repo)
    (unless (rat-kingdom-epic--finish-if-done space repo id)
      (rat-kingdom-epic-dispatch space repo id))))

(defun rat-kingdom-epic-retry-answer (space id task)
  "Let dispatch start the held TASK of the epic ID in SPACE again.
Return what `epic_retry' answers.  The foreman calls it with its epic."
  (let* ((started (rat-kingdom-epic-retry space id task))
         (record (rat-kingdom-epic--get space id))
         (story (cdr (assoc task started))))
    (rat-kingdom-epic--run-reactions space)
    (concat
     (format "The task %s of the epic %s is no longer held. "
             task (rat-kingdom-epic--name record))
     (cond
      (story (format "Started %s for it." story))
      ((not (equal (rat-kingdom-epic--payload record :state) "running"))
       (format "The epic is %s, so nothing starts until it runs."
               (rat-kingdom-epic--payload record :state)))
      ((rat-kingdom-space-rd space (list 'available
                                         :scope (plist-get record :scope)
                                         :identity task))
       "It is ready, and starts when the epic has room under max_parallel.")
      (t "It starts when the tracker reports it ready."))
     (if (cl-remove task started :key #'car :test #'equal)
         (format " Also started: %s."
                 (mapconcat (lambda (entry)
                              (format "%s for %s" (cdr entry) (car entry)))
                            (cl-remove task started :key #'car :test #'equal)
                            ", "))
       ""))))

(defun rat-kingdom-epic--true-p (value)
  "Return non-nil if VALUE, an argument from a tool call, means yes."
  (and value
       (not (member (downcase (string-trim (format "%s" value)))
                    '("" "false" "no" "0" "nil" "off" ":false")))))

(defun rat-kingdom-epic-diff (space id)
  "Return the commits and combined diff of the feature branch of the epic ID.
They are taken in SPACE against the target the epic lands on."
  (let* ((record (rat-kingdom-epic--get space id))
         (target (rat-kingdom-epic--target space record))
         (branch (or (rat-kingdom-epic--payload record :branch)
                     (error "The epic %s has no feature branch: its stories \
merge into %s one by one, and story_diff shows each" id target)))
         (path (plist-get (or (rat-kingdom-repo-get space
                                                    (plist-get record :scope))
                              (error "The repository %s is no longer \
registered" (plist-get record :scope)))
                          :path)))
    (concat
     (format "Epic %s: its branch %s against %s, with %d stories merged.\n\n"
             (rat-kingdom-epic--name record) branch target
             (length (rat-kingdom-epic--payload record :merged)))
     (or (rat-kingdom-king-diff-text path target branch)
         (format "%s has nothing that %s lacks." branch target)))))

(defun rat-kingdom-epic--set-state (space id from to)
  "Move the epic ID in SPACE from the state FROM, a list, to TO.
Signal an error saying where it is if it is not in one of FROM.
Return its new record."
  (let ((record (rat-kingdom-epic--get space id)))
    (unless (member (rat-kingdom-epic--payload record :state) from)
      (error "The epic %s is %s" id (rat-kingdom-epic--payload record :state)))
    (rat-kingdom-epic--update
     space (plist-get record :scope) id
     (lambda (payload)
       (unless (member (plist-get payload :state) from)
         (error "The epic %s is %s" id (plist-get payload :state)))
       (setq payload (plist-put payload :state to))
       (if (member to rat-kingdom-epic-live-states)
           payload
         (plist-put payload :finished (funcall rat-kingdom-space-now-function))))
     rat-kingdom-king-id)))

(defun rat-kingdom-epic-cancel (space id)
  "Cancel the epic ID in SPACE and every story of it in progress.
The epic is marked cancelled first, so that nothing more is started
for it and its tasks are not held.  Each story is cancelled as
`rat-kingdom-story-cancel' does, which releases its task.  A landing
check is abandoned and its candidate removed.  The tracker's epic and
tasks are left open, and a feature branch is kept.  Return the
cancelled stories as \(TASK . STORY)."
  (let* ((record (rat-kingdom-epic--set-state
                  space id rat-kingdom-epic-live-states "cancelled"))
         (repo (plist-get record :scope))
         cancelled)
    (rat-kingdom-epic--remove-candidate space record)
    (rat-kingdom-space-retract space (list 'checked :scope repo :identity id)
                               :actor rat-kingdom-king-id)
    (dolist (story (rat-kingdom-epic--stories space repo id))
      (rat-kingdom-story-cancel space (plist-get story :identity)
                                rat-kingdom-king-id)
      (push (cons (plist-get (plist-get story :payload) :task)
                  (plist-get story :identity))
            cancelled))
    (rat-kingdom-epic--ended space repo id)
    (nreverse cancelled)))

(defun rat-kingdom-epic-retry (space id task)
  "Let dispatch start TASK of the epic ID in SPACE again.
Signal an error unless TASK is held.  Return the started stories."
  (let* ((record (rat-kingdom-epic--get space id))
         (repo (plist-get record :scope)))
    (unless (rat-kingdom-epic--held-reason record task)
      (error "The task %s is not held by the epic %s%s" task id
             (if-let* ((held (rat-kingdom-epic--held record)))
                 (format "; held are %s"
                         (mapconcat (lambda (held) (plist-get held :task))
                                    held ", "))
               "; no task of it is held")))
    (rat-kingdom-epic--update
     space repo id
     (lambda (payload)
       (plist-put payload :held
                  (cl-remove task (plist-get payload :held)
                             :key (lambda (held) (plist-get held :task))
                             :test #'equal)))
     rat-kingdom-king-id)
    (rat-kingdom-task-project space repo)
    (rat-kingdom-epic-dispatch space repo id)))

(rat-kingdom-king--deftool "epic_start"
    "Run an epic planned with epic_create: from now on the engine itself \
starts a story for each of the epic's tasks as the task becomes ready, \
following the dependencies, and you review each story as usual. Ask the user \
before calling it. Returns the stories started now, the ready tasks that \
wait for a place, and the tasks still waiting, with what each waits on."
    '((:name "repo" :type string :description "The repository's name.")
      (:name "epic" :type string :description "The epic's id, as epic_create \
gave it.")
      (:name "max_parallel" :type integer :optional t
       :description "At most this many of the epic's stories in progress at \
once. Default no limit but the workers' cap.")
      (:name "feature_branch" :type boolean :optional t
       :description "true to give the epic a branch of its own, rk/epic/ID, \
cut from the repository's target: its stories merge there instead, and the \
target moves only once, when every task is closed, after one check of the \
whole and your epic_verdict. Use it when the user wants the epic to land as \
one unit. Default false: each story merges into the target as it passes.")
      (:name "foreman" :type boolean :optional t
       :description "true to start a foreman for the epic right after, as \
foreman_start does: an agent that reviews the epic's stories and steers its \
workers for you, and reports to you. Use it for a big epic, or when the user \
asks. Default false: you review its stories."))
  (let* ((repo (arg 'repo))
         (id (arg 'epic))
         (started (rat-kingdom-epic-start
                   space repo id (arg 'max_parallel)
                   (rat-kingdom-epic--true-p (arg 'feature_branch))))
         (foreman (when (rat-kingdom-epic--true-p (arg 'foreman))
                    (condition-case err
                        (format "Started the foreman %s for it: news of its \
stories goes to the foreman from now on, and it reports to you."
                                (rat-kingdom-foreman-start space id))
                      (error (format "No foreman was started: %s"
                                     (error-message-string err))))))
         (record (rat-kingdom-epic-record space id repo)))
    (rat-kingdom-epic--run-reactions space)
    (rat-kingdom-epic--answer
     space record started
     (format "The epic %s in %s is %s%s."
             (rat-kingdom-epic--name record) repo
             (if (equal (rat-kingdom-epic--payload record :state) "running")
                 "running"
               (rat-kingdom-epic--payload record :state))
             (concat
              (if-let* ((limit (rat-kingdom-epic--payload record :max-parallel)))
                  (format ", with at most %d stories at once" limit)
                "")
              (if-let* ((branch (rat-kingdom-epic--payload record :branch)))
                  (format ". Its stories merge into its feature branch %s; \
%s lands only after every task is closed, one check of the whole, and your \
epic_verdict"
                          branch (rat-kingdom-epic--target space record))
                "")))
     foreman)))

(rat-kingdom-king--deftool "epic_pause"
    "Pause a running epic: no new story of it starts, and those in progress \
carry on. epic_resume starts it again."
    '((:name "epic" :type string :description "The epic's id."))
  (let* ((record (rat-kingdom-epic--set-state space (arg 'epic) '("running")
                                              "paused"))
         (running (rat-kingdom-epic--stories space (plist-get record :scope)
                                             (arg 'epic))))
    (format "Paused the epic %s. No new story of it starts until epic_resume.%s"
            (rat-kingdom-epic--name record)
            (if running
                (format " Its stories in progress carry on: %s."
                        (mapconcat (lambda (story) (plist-get story :identity))
                                   running ", "))
              ""))))

(rat-kingdom-king--deftool "epic_resume"
    "Resume a paused epic: the engine starts its ready tasks again. \
Returns what was started and what waits."
    '((:name "epic" :type string :description "The epic's id."))
  (let* ((record (rat-kingdom-epic--set-state space (arg 'epic) '("paused")
                                              "running"))
         (repo (plist-get record :scope))
         (started (progn (rat-kingdom-task-project space repo)
                         (unless (rat-kingdom-epic--finish-if-done
                                  space repo (arg 'epic))
                           (rat-kingdom-epic-dispatch space repo (arg 'epic))))))
    (rat-kingdom-epic--run-reactions space)
    (rat-kingdom-epic--answer
     space record started
     (format "Resumed the epic %s." (rat-kingdom-epic--name record)))))

(rat-kingdom-king--deftool "epic_cancel"
    "Cancel an epic: every story of it in progress is cancelled, as \
story_cancel does, and no new one starts. The epic and its tasks stay open \
in the tracker. Call it only when the user asks."
    '((:name "epic" :type string :description "The epic's id."))
  (let* ((record (rat-kingdom-epic--get space (arg 'epic)))
         (cancelled (rat-kingdom-epic-cancel space (arg 'epic))))
    (concat
     (format "Cancelled the epic %s. %sNothing more will be started for it. \
The br epic %s and its tasks are left open in the tracker: close them with \
br if they are not wanted, or run the epic again with epic_start."
             (rat-kingdom-epic--name record)
             (if cancelled
                 (format "Cancelled its stories %s; their tasks are released, \
and their worktrees and branches kept. "
                         (mapconcat (lambda (entry)
                                      (format "%s (task %s)" (cdr entry)
                                              (car entry)))
                                    cancelled ", "))
               "It had no story in progress. ")
             (arg 'epic))
     (if-let* ((branch (rat-kingdom-epic--payload record :branch)))
         (format " Its feature branch %s is kept, with what its stories \
merged; %s has not moved for it. Delete the branch with git branch -D %s if \
it is not wanted, or carry on from it with epic_start and feature_branch."
                 branch (rat-kingdom-epic--target space record) branch)
       ""))))

(rat-kingdom-king--deftool "epic_retry"
    "Let the engine start a held task of an epic again. A task is held when \
its story ended without being merged, such as when it was cancelled, or when \
its story could not be started."
    '((:name "epic" :type string :description "The epic's id.")
      (:name "task" :type string :description "The held task's id."))
  (rat-kingdom-epic-retry-answer space (arg 'epic) (arg 'task)))

(rat-kingdom-king--deftool "epic_diff"
    "Show the commits and the combined diff of an epic's feature branch \
against the target it lands on: everything its stories merged. Use it to \
review the whole epic when it waits for your epic_verdict."
    '((:name "epic" :type string :description "The epic's id."))
  (rat-kingdom-epic-diff space (arg 'epic)))

(rat-kingdom-king--deftool "epic_verdict"
    "Give your verdict on an epic with a feature branch that waits for your \
review before it lands. pass moves the target to the checked merge of the \
epic's branch and the epic is done. fix adds a task to the epic with your \
notes as its description; the engine starts it on the epic's branch, and the \
epic lands again, after another review, once it is merged."
    '((:name "epic" :type string :description "The epic's id.")
      (:name "value" :type string :description "pass or fix.")
      (:name "notes" :type string :optional t
       :description "With fix: what to change, exact enough for a worker to \
act on. It becomes the new task's description."))
  (prog1 (rat-kingdom-epic-verdict space (arg 'epic) (arg 'value) (arg 'notes))
    (rat-kingdom-epic--run-reactions space)))

(rat-kingdom-king--deftool "epic_show"
    "Show one epic in full: its state and progress, and a table of its \
tasks with each one's status, story, agent and what it waits on."
    '((:name "epic" :type string :description "The epic's id."))
  (rat-kingdom-epic-show space (arg 'epic)))

(provide 'rat-kingdom-epic)
;;; rat-kingdom-epic.el ends here
