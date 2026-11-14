;;; rat-kingdom-epic.el --- Planning tasks and epics -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Chaz Straney

;; Author: Chaz Straney <chaz.straney@gmail.com>
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;;; Commentary:

;; The king plans work as tasks in a repository's tracker (DESIGN.md,
;; sections 9 and 10).  Two of its tools are defined here:
;;
;;   task_create  one task, with its epic, the tasks it depends on, and
;;                the agent and workflow its story should have
;;   epic_create  an epic and its stories, with the dependencies
;;                between them, all at once
;;
;; Neither starts anything.  A task records the agent and workflow its
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
;; Later stories grow this file: an epic token that starts its ready
;; tasks, a view of an epic's progress, a feature branch per epic.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'rat-kingdom-space)
(require 'rat-kingdom-git)
(require 'rat-kingdom-workflow)
(require 'rat-kingdom-task)
(require 'rat-kingdom-agent-shell)
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
         (format "Ready now: %s. Start one with story_start and its task \
id when the user wants work to begin."
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
any of it is wrong. It starts nothing: the stories that are ready are listed \
under Available tasks, and each is started with story_start and its task id \
when the user wants. Returns the epic's id, a table of the stories' tasks and \
which are ready now."
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

(provide 'rat-kingdom-epic)
;;; rat-kingdom-epic.el ends here
