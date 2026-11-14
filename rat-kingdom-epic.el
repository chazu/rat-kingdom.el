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
;; (running, paused, done or cancelled), `:title', `:max-parallel',
;; `:held' (tasks not to be started again by themselves, each with the
;; reason), `:merged' (the tasks its stories merged), `:started' and
;; `:finished'.  It is only ever replaced whole, in one transaction.
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
;; Not here yet: a feature branch per epic, a foreman.

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
  (let* ((repo (arg 'repo))
         (depends (rat-kingdom-epic--ids (arg 'depends_on)))
         (id (rat-kingdom-epic-create-task
              space repo (arg 'title)
              :description (arg 'description) :priority (arg 'priority)
              :type (arg 'type) :parent (arg 'parent) :depends-on depends
              :agent (arg 'agent) :workflow (arg 'workflow))))
    (string-join
     (delq nil
           (list (format "Created the task %s in %s: %s." id repo (arg 'title))
                 (and (arg 'parent) (format "Epic: %s." (arg 'parent)))
                 (and depends (format "Depends on: %s."
                                      (string-join depends ", ")))
                 (and (arg 'agent) (format "Agent: %s." (arg 'agent)))
                 (and (arg 'workflow) (format "Workflow: %s." (arg 'workflow)))
                 (if (rat-kingdom-space-rd space (list 'available :scope repo
                                                       :identity id))
                     "It is ready now. Nothing has been started."
                   "It is not ready yet. Nothing has been started.")))
     " ")))

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

(defconst rat-kingdom-epic-live-states '("running" "paused")
  "The states of an epic that has not ended.")

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
  "Return non-nil if the `epic' tuple RECORD is running or paused."
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

(defun rat-kingdom-epic--tell (space repo text)
  "Leave the king a message in SPACE, about REPO, saying TEXT."
  (rat-kingdom-space-out space 'message :scope repo
                         :payload (list :to rat-kingdom-king-id :text text)
                         :actor "engine"))

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
         space repo task :found (plist-get available :payload) :epic id)))))

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
                          (error-message-string err) id task)))))))))
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
Close the br epic too, and tell the king.  Return non-nil if it was
done now.  A tracker that fails leaves the epic as it is."
  (let ((record (rat-kingdom-epic-record space id repo)))
    (when (rat-kingdom-epic--live-p record)
      (let ((children (condition-case err
                          (rat-kingdom-epic--children space repo id)
                        (error
                         (message "rat-kingdom: the tasks of the epic %s: %s"
                                  id (error-message-string err))
                         nil))))
        (when (and children (cl-every #'rat-kingdom-epic--closed-p children))
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
            (rat-kingdom-space-with-transaction space
              (when (rat-kingdom-epic--update
                     space repo id
                     (lambda (payload)
                       (when (member (plist-get payload :state)
                                     rat-kingdom-epic-live-states)
                         (plist-put (plist-put payload :state "done")
                                    :finished
                                    (funcall rat-kingdom-space-now-function)))))
                (rat-kingdom-epic--tell
                 space repo
                 (concat (format "Epic %s is done: %s."
                                 (rat-kingdom-epic--name record)
                                 (if (= merged total)
                                     (format "%d stories merged" merged)
                                   (format "all %d tasks are closed, %d of \
them by merged stories" total merged)))
                         (if closed
                             (format " The br epic %s could not be closed: %s"
                                     id closed)
                           (format " The br epic %s is closed." id))))
                t))))))))

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
     (format "Epic %s in %s: %s\nState: %s%s. %s.\n"
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
             (rat-kingdom-epic--progress record tasks))
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

(defun rat-kingdom-epic--answer (space record started &optional opening)
  "Return what the king is told after the epic RECORD in SPACE dispatched.
STARTED are the stories it started, as (TASK . STORY).  OPENING is the
first sentence."
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
              ("done" (format "Every task is closed, so the epic is done."))
              (_ nil))))
     "\n\n")))

;;;; The king's tools for running epics

(defun rat-kingdom-epic--run-reactions (space)
  "Run the reactions of SPACE, so that new stories begin, unless they run."
  (unless (memq space rat-kingdom-reaction--running)
    (rat-kingdom-reaction-run space)))

(defun rat-kingdom-epic-start (space repo id &optional max-parallel)
  "Start running the epic ID of REPO in SPACE.
At most MAX-PARALLEL of its stories are in progress at once, if given.
Signal an error if ID is not an epic in REPO's tracker, has no tasks, is
already running, is paused or is done.  A cancelled epic is started
again, with no task held.  Write its record as running and dispatch it.
Return the started stories as (TASK . STORY)."
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
      ("done" (error "The epic %s is done: all its tasks are closed" id)))
    (when (and max-parallel (not (and (integerp max-parallel)
                                      (> max-parallel 0))))
      (error "The argument max_parallel must be a whole number of at least 1, \
not %s"
             max-parallel))
    (unless (rat-kingdom-task-children adapter id)
      (error "The epic %s has no tasks; plan them with epic_create or \
task_create" id))
    (rat-kingdom-space-put
     space 'epic :scope repo :identity id
     :payload (list :state "running" :title (plist-get epic :title)
                    :max-parallel max-parallel :held nil
                    :merged (rat-kingdom-epic--payload record :merged)
                    :started (funcall rat-kingdom-space-now-function)
                    :finished nil)
     :actor rat-kingdom-king-id)
    (rat-kingdom-task-project space repo)
    (unless (rat-kingdom-epic--finish-if-done space repo id)
      (rat-kingdom-epic-dispatch space repo id))))

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
`rat-kingdom-story-cancel' does, which releases its task.  The tracker's
epic and tasks are left open.  Return the cancelled stories as
\(TASK . STORY)."
  (let* ((record (rat-kingdom-epic--set-state
                  space id rat-kingdom-epic-live-states "cancelled"))
         (repo (plist-get record :scope))
         cancelled)
    (dolist (story (rat-kingdom-epic--stories space repo id))
      (rat-kingdom-story-cancel space (plist-get story :identity)
                                rat-kingdom-king-id)
      (push (cons (plist-get (plist-get story :payload) :task)
                  (plist-get story :identity))
            cancelled))
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
once. Default no limit but the workers' cap."))
  (let* ((repo (arg 'repo))
         (id (arg 'epic))
         (started (rat-kingdom-epic-start space repo id (arg 'max_parallel)))
         (record (rat-kingdom-epic-record space id repo)))
    (rat-kingdom-epic--run-reactions space)
    (rat-kingdom-epic--answer
     space record started
     (format "The epic %s in %s is %s%s."
             (rat-kingdom-epic--name record) repo
             (if (equal (rat-kingdom-epic--payload record :state) "running")
                 "running"
               (rat-kingdom-epic--payload record :state))
             (if-let* ((limit (rat-kingdom-epic--payload record :max-parallel)))
                 (format ", with at most %d stories at once" limit)
               "")))))

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
            (arg 'epic))))

(rat-kingdom-king--deftool "epic_retry"
    "Let the engine start a held task of an epic again. A task is held when \
its story ended without being merged, such as when it was cancelled, or when \
its story could not be started."
    '((:name "epic" :type string :description "The epic's id.")
      (:name "task" :type string :description "The held task's id."))
  (let* ((id (arg 'epic))
         (task (arg 'task))
         (started (rat-kingdom-epic-retry space id task))
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

(rat-kingdom-king--deftool "epic_show"
    "Show one epic in full: its state and progress, and a table of its \
tasks with each one's status, story, agent and what it waits on."
    '((:name "epic" :type string :description "The epic's id."))
  (rat-kingdom-epic-show space (arg 'epic)))

(provide 'rat-kingdom-epic)
;;; rat-kingdom-epic.el ends here
