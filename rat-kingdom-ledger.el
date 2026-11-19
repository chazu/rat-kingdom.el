;;; rat-kingdom-ledger.el --- The epic ledger surface -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Chaz Straney

;; Author: Chaz Straney <chaz.straney@gmail.com>
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;;; Commentary:

;; The epic ledger (DESIGN.md, section 14.1): one dense row for each
;; open epic of the registered repositories, drawn by the engine in an
;; a2ui surface, the "Epic ledger".  No model is involved.
;; `rat-kingdom-ledger' opens it, and the king's `ledger_show' opens it
;; for the user, for all repositories or for one.  It is shown in the
;; main window, as the story board and the issue inspector are: the
;; selected window of the selected frame takes it in place of its
;; buffer, unless that is a side window or a dedicated one, in which
;; case a2ui's main window does.  \\`q' buries it, and \\`g' draws it
;; again from the trackers and the space.
;;
;; The rows are one a2ui Table, one line for each epic, made to fit in
;; `rat-kingdom-ledger-width' characters.  A row has the epic's id, its
;; repository (when the ledger shows more than one) and its title, cut
;; to fit, a bar of the tasks closed, the counts of its tasks closed, in
;; progress, ready and blocked, the engine's state of the epic, the next
;; ready task, the epic's age and the time since its last change, and a
;; sparkline of the tasks closed on each of the last
;; `rat-kingdom-ledger-spark-days' days.  The engine's state is not
;; started, running (with the stories in progress), paused, landing, or
;; held, with the held task named; +F says the epic has a foreman.
;;
;; The rows come in the order that puts the epics that need attention
;; first: those with a held task, then those with blocked tasks and
;; nothing ready or in progress, then those running, then the others,
;; each group by priority.  Closed epics come last.
;;
;; A row is selected with the box before it, and a selected row expands:
;; under the table, a Section for each selected epic holds a compact
;; table of its tasks, with each one's id, priority, status, title and
;; story in progress.  RET on an epic's id, or on a task's, shows it in
;; the issue inspector (rat-kingdom-issue.el), and the inspector's Open
;; parent epic shows the ledger with the epic expanded.  A picker limits
;; the ledger to one repository, and a check box adds the epics closed
;; in the last `rat-kingdom-ledger-closed-days' days.  Above the rows, a
;; Progress bar and a Sparkline sum up the epics shown.  No button
;; starts, pauses or retries an epic: those stay with the king.
;;
;; The epics come from each repository's tracker through
;; `rat-kingdom-ledger-read-epics', which for br is `br list --type
;; epic'.  Their tasks and the engine's state come from the functions
;; `epic_show' uses (rat-kingdom-epic.el).  The ledger follows
;; `rat-kingdom-space-change-functions': a change to an `epic' tuple, a
;; story of an epic or a task of an epic made available draws it again,
;; at most every `rat-kingdom-ledger-interval' seconds, and so does
;; `rat-kingdom-task-settled-functions' when a story of an epic has its
;; task closed or released.  Each redraw reads the trackers again.  A
;; change made with br outside rat-kingdom is shown on \\`g'.
;;
;; a2ui is optional, as for the epic plan (rat-kingdom-plan.el): it is
;; loaded when the ledger is first shown, and the ledger says plainly
;; when it cannot be.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'rat-kingdom-space)
(require 'rat-kingdom-git)
(require 'rat-kingdom-task)
(require 'rat-kingdom-king)
(require 'rat-kingdom-epic)
(require 'rat-kingdom-plan)
(require 'rat-kingdom-issue)

(declare-function a2ui-session-create "a2ui-core")
(declare-function a2ui-session-surface "a2ui-core" (session surface-id))
(declare-function a2ui-apply-message "a2ui-core" (session message))
(declare-function a2ui-get "a2ui-core" (surface path &optional scope))
(declare-function a2ui-vui-attach "a2ui-vui" (session))
(declare-function a2ui-show-surface "a2ui-vui" (session surface-id))
(declare-function a2ui-vui-display-in-main-window "a2ui-vui" (buffer alist))
(defvar a2ui-vui-display-action)
(defvar a2ui-emacs-table-bar-width)

(defconst rat-kingdom-ledger-surface-id "Epic ledger"
  "The id of the epic ledger's surface.")

(defcustom rat-kingdom-ledger-width 100
  "How many characters wide a row of the epic ledger is made to be.
The title takes what the other columns leave, but no less than
`rat-kingdom-ledger-min-title-width'."
  :type 'natnum
  :group 'rat-kingdom)

(defcustom rat-kingdom-ledger-min-title-width 12
  "The fewest characters of an epic's title a row of the ledger shows."
  :type 'natnum
  :group 'rat-kingdom)

(defcustom rat-kingdom-ledger-closed-days 7
  "How many days back the ledger's check box shows closed epics from."
  :type 'natnum
  :group 'rat-kingdom)

(defcustom rat-kingdom-ledger-spark-days 14
  "How many days a row's sparkline of tasks closed covers."
  :type 'natnum
  :group 'rat-kingdom)

(defcustom rat-kingdom-ledger-interval 1.0
  "The fewest seconds between two redraws of the epic ledger.
Each redraw reads the trackers again."
  :type 'number
  :group 'rat-kingdom)

(defconst rat-kingdom-ledger--widths
  '((select . 3) (counts . 7) (state . 12) (next . 14) (age . 7))
  "The widths of the ledger's columns that do not depend on the rows.
The box that selects a row, the counts, the state, the next ready task
and the ages.  The bar is as wide as a2ui draws it, the sparkline has
a character for each day, and the epic's id takes what it needs.")

(defconst rat-kingdom-ledger--child-widths
  '((status . 24) (title . 28) (story . 28))
  "The most characters of a task's cells in an expanded epic's table.
Those are its status, its title and its story in progress.")

(defvar rat-kingdom-ledger--session nil
  "The a2ui session that holds the epic ledger, or nil.")

(defvar rat-kingdom-ledger--space nil
  "The space the ledger shows, or nil while it is not shown.")

(defvar rat-kingdom-ledger--filter (list :repo nil :closed nil)
  "What the ledger shows, as a property list.
`:repo' is a repository's name, or nil for all, and `:closed' is
non-nil to show the epics closed in the last
`rat-kingdom-ledger-closed-days' days too.")

(defvar rat-kingdom-ledger--model nil
  "What the ledger shows, as `rat-kingdom-ledger-gather' returns it.")

(defvar rat-kingdom-ledger--expanded nil
  "The keys of the rows expanded, as \"REPO/ID\" strings.")

(defvar rat-kingdom-ledger--rendering nil
  "Non-nil while the ledger is being drawn.
The surface changes then, and what it holds is not the user's doing.")

(defvar rat-kingdom-ledger--buffer nil
  "The buffer a2ui shows the ledger in, or nil.")

(defvar rat-kingdom-ledger--timer nil
  "The timer of the next redraw of the ledger, or nil.")

(defvar rat-kingdom-ledger--last 0
  "When the ledger was last drawn, as `float-time' gives it.")

(defvar rat-kingdom-ledger--defer (lambda (function) (run-at-time 0 nil function))
  "How a button's handler is run: later, outside the button press.")

(defvar rat-kingdom-ledger--now #'float-time
  "Function returning the time, for the ledger's throttle.  Tests replace it.")

;;;; The tracker

(cl-defgeneric rat-kingdom-ledger-read-epics (adapter closed)
  "Return the epics of ADAPTER's tracker, as property lists.
With CLOSED nil, the epics that are not closed; otherwise those that
are.  The keys are those of `br list --json': `:id', `:title',
`:status', `:priority', `:created_at', `:updated_at' and `:closed_at';
any but `:id' may be missing.  Signal `rat-kingdom-task-error' if the
tracker fails.")

(cl-defmethod rat-kingdom-ledger-read-epics ((adapter rat-kingdom-task-br) closed)
  "Return the epics `br list --type epic' gives in ADAPTER's workspace.
br lists the issues that are not closed; with CLOSED, `--status
closed' lists those that are.  br wraps them in an object, `issues';
a br that gives a bare array is understood too."
  (let ((output (apply #'rat-kingdom-task-br--run adapter "list" "--type" "epic"
                       (and closed '("--status" "closed")))))
    (if (keywordp (car output)) (plist-get output :issues) output)))

;;;; Gathering

(defun rat-kingdom-ledger-age-text (seconds)
  "Return SECONDS as a short age in its largest unit: 45s, 12m, 3h or 2d."
  (let ((seconds (max 0 (truncate seconds))))
    (cond ((< seconds 60) (format "%ds" seconds))
          ((< seconds 3600) (format "%dm" (/ seconds 60)))
          ((< seconds 86400) (format "%dh" (/ seconds 3600)))
          (t (format "%dd" (/ seconds 86400))))))

(defun rat-kingdom-ledger--key (repo id)
  "Return the key of the row of the epic ID of REPO."
  (format "%s/%s" repo id))

(defun rat-kingdom-ledger-counts (tasks)
  "Return the counts of TASKS, as `rat-kingdom-epic--tasks' gives them.
That is a property list: `:closed', `:progress' (a story in progress,
or in progress in the tracker), `:ready', `:blocked' (every other open
task: held, waiting on others or not ready in the tracker) and
`:total'."
  (let ((closed 0) (progress 0) (ready 0) (blocked 0))
    (dolist (task tasks)
      (pcase (plist-get task :class)
        ('closed (cl-incf closed))
        ('story (cl-incf progress))
        ((guard (equal (plist-get task :status) "in_progress"))
         (cl-incf progress))
        ('ready (cl-incf ready))
        (_ (cl-incf blocked))))
    (list :closed closed :progress progress :ready ready :blocked blocked
          :total (length tasks))))

(defun rat-kingdom-ledger-closed-per-day (tasks now &optional days)
  "Return how many of TASKS were closed on each of the last DAYS days to NOW.
DAYS is by default `rat-kingdom-ledger-spark-days'.  The counts are a
vector, oldest first, ending with today, in local time.  Return nil if
no task has a `:closed-at'."
  (let* ((days (or days rat-kingdom-ledger-spark-days))
         (today (time-to-days now))
         (counts (make-vector days 0))
         (any nil))
    (dolist (task tasks)
      (when-let* ((time (rat-kingdom-issue--time (plist-get task :closed-at))))
        (setq any t)
        (let ((ago (- today (time-to-days time))))
          (when (and (>= ago 0) (< ago days))
            (cl-incf (aref counts (- days 1 ago)))))))
    (and any counts)))

(defun rat-kingdom-ledger--changed-at (issue tasks record)
  "Return when the epic ISSUE, its TASKS or its `epic' tuple RECORD last changed.
That is a `float-time', or nil if none of them says."
  (let ((times (delq nil
                     (append
                      (list (rat-kingdom-issue--time (plist-get issue :updated_at))
                            (rat-kingdom-issue--time (plist-get issue :closed_at))
                            (plist-get record :created))
                      (mapcan (lambda (task)
                                (list (rat-kingdom-issue--time
                                       (plist-get task :updated-at))
                                      (rat-kingdom-issue--time
                                       (plist-get task :closed-at))))
                              tasks)))))
    (and times (apply #'max times))))

(defun rat-kingdom-ledger--state (record closed)
  "Return the engine's state of the epic whose `epic' tuple is RECORD.
CLOSED is non-nil if the tracker has the epic closed.  The state is a
symbol: `closed', `not-started', `running', `paused', `landing', or,
for an epic the engine ended while the tracker keeps it open, `done'
or `cancelled'."
  (cond (closed 'closed)
        ((null record) 'not-started)
        (t (intern (or (rat-kingdom-epic--payload record :state) "not-started")))))

(defun rat-kingdom-ledger--next (space repo id held)
  "Return the next ready task of the epic ID of REPO in SPACE, or nil.
It is (TASK . TITLE): the most urgent available task not in HELD."
  (when-let* ((tuple (cl-find-if-not (lambda (tuple)
                                       (member (plist-get tuple :identity) held))
                                     (rat-kingdom-epic--ready space repo id))))
    (cons (plist-get tuple :identity)
          (or (plist-get (plist-get tuple :payload) :title) ""))))

(defun rat-kingdom-ledger--rank (entry)
  "Return how much the epic ENTRY needs attention: 0 most, 4 least.
0 has a held task, 1 has blocked tasks and none ready or in progress,
2 is running, 3 is anything else that is open, and 4 is closed."
  (let ((counts (plist-get entry :counts)))
    (cond ((eq (plist-get entry :state) 'closed) 4)
          ((plist-get entry :held) 0)
          ((and (zerop (plist-get counts :ready))
                (zerop (plist-get counts :progress))
                (> (plist-get counts :blocked) 0))
           1)
          ((eq (plist-get entry :state) 'running) 2)
          (t 3))))

(defun rat-kingdom-ledger-entry (space repo issue)
  "Return the ledger's row for the epic ISSUE of REPO in SPACE.
ISSUE is as `rat-kingdom-ledger-read-epics' gives it.  The row is a
property list: `:repo', `:id', `:key', `:title', `:priority', `:state'
as `rat-kingdom-ledger--state' gives it, `:held' (the ids of the held
tasks), `:running' (how many stories are in progress), `:foreman'
\(non-nil if it has one), `:tasks' as `rat-kingdom-epic--tasks' gives
them, `:counts' as `rat-kingdom-ledger-counts' gives them, `:next' as
`rat-kingdom-ledger--next' gives it, `:created' and `:changed' (times,
or nil), `:spark' as `rat-kingdom-ledger-closed-per-day' gives it,
`:rank' as `rat-kingdom-ledger--rank' gives it, and `:problem', what
went wrong reading its tasks, or nil."
  (let* ((id (plist-get issue :id))
         (closed (rat-kingdom-epic--closed-p issue))
         (record (rat-kingdom-epic-record space id repo))
         (live (and record (rat-kingdom-epic--live-p record)))
         (problem nil)
         (merged (rat-kingdom-epic--payload record :merged))
         (tasks (condition-case err
                    (mapcar (lambda (task)
                              (append (list :merged (and (member (plist-get task :id)
                                                                 merged)
                                                         t))
                                      task))
                            (rat-kingdom-epic--tasks
                             space (or record
                                       (list :scope repo :identity id))))
                  (error
                   (setq problem (format "The tasks of %s could not be read: %s"
                                         id (error-message-string err)))
                   nil)))
         (held (and live (not closed)
                    (mapcar (lambda (held) (plist-get held :task))
                            (rat-kingdom-epic--held record))))
         (entry (list :repo repo :id id
                      :key (rat-kingdom-ledger--key repo id)
                      :title (or (plist-get issue :title) "")
                      :priority (plist-get issue :priority)
                      :state (rat-kingdom-ledger--state record closed)
                      :held held
                      :running (if live
                                   (length (rat-kingdom-epic--stories space repo id))
                                 0)
                      :foreman (and live (rat-kingdom-epic--payload record :foreman)
                                    t)
                      :tasks tasks
                      :counts (rat-kingdom-ledger-counts tasks)
                      :next (and (not closed)
                                 (rat-kingdom-ledger--next space repo id held))
                      :created (rat-kingdom-issue--time (plist-get issue :created_at))
                      :changed (rat-kingdom-ledger--changed-at issue tasks record)
                      :spark (rat-kingdom-ledger-closed-per-day
                              tasks (funcall rat-kingdom-space-now-function))
                      :problem problem)))
    (append entry (list :rank (rat-kingdom-ledger--rank entry)))))

(defun rat-kingdom-ledger--before-p (a b)
  "Return non-nil if the row A comes before the row B in the ledger.
The more a row needs attention, the sooner it comes; then the most
urgent, then by repository and id."
  (let ((rank-a (plist-get a :rank)) (rank-b (plist-get b :rank))
        (priority-a (or (plist-get a :priority) 9))
        (priority-b (or (plist-get b :priority) 9)))
    (cond ((/= rank-a rank-b) (< rank-a rank-b))
          ((/= priority-a priority-b) (< priority-a priority-b))
          ((not (equal (plist-get a :repo) (plist-get b :repo)))
           (string< (plist-get a :repo) (plist-get b :repo)))
          (t (string-version-lessp (plist-get a :id) (plist-get b :id))))))

(defun rat-kingdom-ledger--recently-closed (issues now)
  "Return those of the closed epics ISSUES closed in the last days to NOW.
The days are `rat-kingdom-ledger-closed-days'.  An epic with no
`:closed_at' is left out."
  (let ((since (- now (* 86400 rat-kingdom-ledger-closed-days))))
    (cl-remove-if-not (lambda (issue)
                        (when-let* ((time (rat-kingdom-issue--time
                                           (plist-get issue :closed_at))))
                          (>= time since)))
                      issues)))

(defun rat-kingdom-ledger-gather (space filter)
  "Return what the ledger of SPACE shows under FILTER.
FILTER is a property list like `rat-kingdom-ledger--filter'.  The
result is a property list: `:filter', `:entries', the rows as
`rat-kingdom-ledger-entry' makes them, in the ledger's order, and
`:problems', what could not be read.  A repository whose tracker fails
is a problem; the others are still shown.  Signal an error if FILTER
names a repository that is not registered."
  (let* ((repo (plist-get filter :repo))
         (names (if repo
                    (if (rat-kingdom-repo-get space repo)
                        (list repo)
                      (error "There is no repository called %s; the \
repositories are: %s"
                             repo (or (mapconcat (lambda (record)
                                                   (plist-get record :name))
                                                 (rat-kingdom-repo-list space)
                                                 ", ")
                                      "none")))
                  (mapcar (lambda (record) (plist-get record :name))
                          (rat-kingdom-repo-list space))))
         (now (funcall rat-kingdom-space-now-function))
         (entries nil)
         (problems nil))
    (dolist (name names)
      (when-let* ((adapter (rat-kingdom-task-adapter space name)))
        (condition-case err
            (dolist (issue (append (rat-kingdom-ledger-read-epics adapter nil)
                                   (and (plist-get filter :closed)
                                        (rat-kingdom-ledger--recently-closed
                                         (rat-kingdom-ledger-read-epics adapter t)
                                         now))))
              (let ((entry (rat-kingdom-ledger-entry space name issue)))
                (push entry entries)
                (when (plist-get entry :problem)
                  (push (plist-get entry :problem) problems))))
          (rat-kingdom-task-error
           (push (format "The tracker of %s failed: %s" name
                         (error-message-string err))
                 problems)))))
    (list :filter (copy-sequence filter)
          :entries (sort entries #'rat-kingdom-ledger--before-p)
          :problems (nreverse problems))))

(defun rat-kingdom-ledger-summary (model)
  "Return a one-line summary of the epics MODEL holds.
For example \"5 open epics, 1 held\"."
  (let* ((entries (plist-get model :entries))
         (open (cl-count-if-not (lambda (entry)
                                  (eq (plist-get entry :state) 'closed))
                                entries))
         (held (cl-count-if (lambda (entry) (plist-get entry :held)) entries))
         (blocked (cl-count 1 entries :key (lambda (entry)
                                             (plist-get entry :rank))))
         (closed (- (length entries) open)))
    (concat (format "%d open epic%s, %d held" open (if (= open 1) "" "s") held)
            (if (> blocked 0)
                (format ", %d blocked with nothing ready" blocked)
              "")
            (if (plist-get (plist-get model :filter) :closed)
                (format ", %d closed in the last %d days" closed
                        rat-kingdom-ledger-closed-days)
              ""))))

;;;; The surface, as data

(defun rat-kingdom-ledger--cut (text width)
  "Return TEXT on one line, no longer than WIDTH."
  (truncate-string-to-width
   (replace-regexp-in-string "[\n\t ]+" " " (string-trim (or text "")))
   (max 1 width) nil nil "…"))

(defun rat-kingdom-ledger-state-text (entry)
  "Return the engine's state of the epic ENTRY, in a few words."
  (let ((held (plist-get entry :held)))
    (concat
     (cond (held (format "held %s%s" (car held)
                         (if (cdr held) (format " +%d" (length (cdr held))) "")))
           (t (pcase (plist-get entry :state)
                ('running (format "running %d" (plist-get entry :running)))
                ('not-started "not started")
                (state (symbol-name state)))))
     (if (plist-get entry :foreman) " +F" ""))))

(defun rat-kingdom-ledger--tone (entry)
  "Return the tone of the state of the epic ENTRY."
  (pcase (plist-get entry :rank)
    (0 "error") (1 "warning") (2 "success") (4 "muted") (_ "")))

(defun rat-kingdom-ledger--counts-text (counts)
  "Return COUNTS as \"CLOSED/PROGRESS/READY/BLOCKED\"."
  (format "%d/%d/%d/%d" (plist-get counts :closed) (plist-get counts :progress)
          (plist-get counts :ready) (plist-get counts :blocked)))

(defun rat-kingdom-ledger--ages-text (entry now)
  "Return the age of the epic ENTRY and the time since it changed, at NOW."
  (cl-flet ((age (time) (if time (rat-kingdom-ledger-age-text (- now time)) "-")))
    (format "%s/%s" (age (plist-get entry :created))
            (age (plist-get entry :changed)))))

(defun rat-kingdom-ledger--bar-width ()
  "Return how wide a2ui draws a bar in a Table cell."
  (if (boundp 'a2ui-emacs-table-bar-width) a2ui-emacs-table-bar-width 8))

(defun rat-kingdom-ledger-title-width (entries)
  "Return how many characters the title has in the rows ENTRIES.
That is what the other columns and the spaces between them leave of
`rat-kingdom-ledger-width', but no less than
`rat-kingdom-ledger-min-title-width'."
  (let* ((id (apply #'max (length "Epic")
                    (mapcar (lambda (entry) (string-width (plist-get entry :id)))
                            entries)))
         (counts (apply #'max (alist-get 'counts rat-kingdom-ledger--widths)
                        (mapcar (lambda (entry)
                                  (string-width (rat-kingdom-ledger--counts-text
                                                 (plist-get entry :counts))))
                                entries)))
         (columns 9)
         (others (+ (alist-get 'select rat-kingdom-ledger--widths) id
                    (rat-kingdom-ledger--bar-width) counts
                    (alist-get 'state rat-kingdom-ledger--widths)
                    (alist-get 'next rat-kingdom-ledger--widths)
                    (alist-get 'age rat-kingdom-ledger--widths)
                    (max (length "Closed") rat-kingdom-ledger-spark-days)
                    (1- columns))))
    (max rat-kingdom-ledger-min-title-width (- rat-kingdom-ledger-width others))))

(defun rat-kingdom-ledger--spark-value (spark)
  "Return SPARK, a vector of counts or nil, as a row's sparkline cell.
A vector with a count above 0 is drawn by a2ui.  One that is all 0 is
drawn here, as a line of the lowest bar, since a2ui would draw it at
mid height.  Without counts, the cell is empty."
  (cond ((null spark) "")
        ((cl-some #'cl-plusp spark) spark)
        (t (make-string (length spark) ?▁))))

(defun rat-kingdom-ledger--row-object (entry title-width all now)
  "Return the row of the epic ENTRY as the JSON object the data model holds.
Its title is cut to TITLE-WIDTH, after its repository if ALL, non-nil,
says the ledger shows every repository.  NOW is the time."
  (let ((counts (plist-get entry :counts))
        (next (plist-get entry :next)))
    (rat-kingdom-plan--obj
     "key" (plist-get entry :key)
     "repo" (plist-get entry :repo)
     "id" (plist-get entry :id)
     "title" (rat-kingdom-ledger--cut
              (if all
                  (format "%s · %s" (plist-get entry :repo) (plist-get entry :title))
                (plist-get entry :title))
              title-width)
     "done" (if (> (plist-get counts :total) 0)
                (/ (float (plist-get counts :closed)) (plist-get counts :total))
              0)
     "counts" (rat-kingdom-ledger--counts-text counts)
     "state" (rat-kingdom-ledger--cut (rat-kingdom-ledger-state-text entry)
                                      (alist-get 'state rat-kingdom-ledger--widths))
     "tone" (rat-kingdom-ledger--tone entry)
     "next" (if next
                (rat-kingdom-ledger--cut (format "%s %s" (car next) (cdr next))
                                         (alist-get 'next rat-kingdom-ledger--widths))
              "-")
     "age" (rat-kingdom-ledger--ages-text entry now)
     "spark" (rat-kingdom-ledger--spark-value (plist-get entry :spark)))))

(defun rat-kingdom-ledger--child-status (task)
  "Return the status the expanded table shows for TASK.
TASK is as `rat-kingdom-epic--tasks' gives it, with `:merged'."
  (rat-kingdom-ledger--cut
   (pcase (plist-get task :class)
     ('closed (if (plist-get task :merged) "merged" (plist-get task :status)))
     ('story "in progress")
     ('held (format "held: %s" (plist-get task :held)))
     ('ready "ready")
     ('waiting (format "waits on %s" (string-join (plist-get task :waits) ", ")))
     (_ (or (plist-get task :status) "open")))
   (alist-get 'status rat-kingdom-ledger--child-widths)))

(defun rat-kingdom-ledger--child-object (repo task)
  "Return the task TASK of REPO as a row of an expanded epic's table."
  (let ((story (plist-get task :story)))
    (rat-kingdom-plan--obj
     "repo" repo
     "id" (plist-get task :id)
     "priority" (if (plist-get task :priority)
                    (format "P%s" (plist-get task :priority))
                  "")
     "status" (rat-kingdom-ledger--child-status task)
     "tone" (pcase (plist-get task :class)
              ('closed "muted") ('held "error") ('ready "success") (_ ""))
     "title" (rat-kingdom-ledger--cut (plist-get task :title)
                                      (alist-get 'title
                                                 rat-kingdom-ledger--child-widths))
     "story" (if story
                 (rat-kingdom-ledger--cut
                  (format "%s %s" (plist-get story :identity)
                          (rat-kingdom-epic--story-place story))
                  (alist-get 'story rat-kingdom-ledger--child-widths))
               ""))))

(defun rat-kingdom-ledger--detail-object (entry expanded)
  "Return the expanded part of the epic ENTRY as the data model holds it.
It is visible if the row's key is in EXPANDED."
  (let ((tasks (plist-get entry :tasks)))
    (rat-kingdom-plan--obj
     "key" (plist-get entry :key)
     "title" (format "%s · %s (%d task%s)%s" (plist-get entry :id)
                     (rat-kingdom-ledger--cut
                      (plist-get entry :title)
                      (- rat-kingdom-ledger-width 30))
                     (length tasks) (if (= (length tasks) 1) "" "s")
                     (if (plist-get entry :problem) ": could not be read" ""))
     "visible" (rat-kingdom-plan--bool (member (plist-get entry :key) expanded))
     "children" (vconcat (mapcar (lambda (task)
                                   (rat-kingdom-ledger--child-object
                                    (plist-get entry :repo) task))
                                 tasks)))))

(defun rat-kingdom-ledger--sum-spark (entries)
  "Return the sparklines of ENTRIES added up, or nil if none has one."
  (let (sum)
    (dolist (entry entries)
      (when-let* ((spark (plist-get entry :spark)))
        (setq sum (if sum (cl-map 'vector #'+ sum spark) (copy-sequence spark)))))
    sum))

(defun rat-kingdom-ledger--repo-options (space)
  "Return the repository picker's options for SPACE, all first."
  (vconcat
   (list (rat-kingdom-plan--obj "label" "all repositories" "value" ""))
   (mapcar (lambda (record)
             (let ((name (plist-get record :name)))
               (rat-kingdom-plan--obj "label" name "value" name)))
           (rat-kingdom-repo-list space))))

(defun rat-kingdom-ledger-data (space model expanded)
  "Return the ledger's data model for SPACE, showing MODEL.
EXPANDED are the keys of the rows expanded."
  (let* ((entries (plist-get model :entries))
         (filter (plist-get model :filter))
         (now (funcall rat-kingdom-space-now-function))
         (title-width (rat-kingdom-ledger-title-width entries))
         (all (null (plist-get filter :repo)))
         (closed (apply #'+ 0 (mapcar (lambda (entry)
                                        (plist-get (plist-get entry :counts) :closed))
                                      entries)))
         (total (apply #'+ 0 (mapcar (lambda (entry)
                                       (plist-get (plist-get entry :counts) :total))
                                     entries)))
         (spark (rat-kingdom-ledger--sum-spark entries))
         (problems (string-join (plist-get model :problems) "\n")))
    (rat-kingdom-plan--obj
     "summary" (rat-kingdom-ledger-summary model)
     "repos" (rat-kingdom-ledger--repo-options space)
     "filter" (rat-kingdom-plan--obj
               "repo" (or (plist-get filter :repo) "")
               "closed" (rat-kingdom-plan--bool (plist-get filter :closed)))
     "overall" (rat-kingdom-plan--obj
                "closed" closed "total" total
                "text" (format "%d/%d" closed total)
                "spark" (or spark [])
                "hasSpark" (rat-kingdom-plan--bool
                            (and spark (cl-some #'cl-plusp spark))))
     "result" problems
     "resultTone" "error"
     "hasResult" (rat-kingdom-plan--bool (not (string-empty-p problems)))
     "hasRows" (rat-kingdom-plan--bool entries)
     "isEmpty" (rat-kingdom-plan--bool (null entries))
     "expanded" (vconcat expanded)
     "rows" (vconcat (mapcar (lambda (entry)
                               (rat-kingdom-ledger--row-object
                                entry title-width all now))
                             entries))
     "details" (vconcat (mapcar (lambda (entry)
                                  (rat-kingdom-ledger--detail-object entry expanded))
                                entries)))))

(defun rat-kingdom-ledger--open-action ()
  "Return the action that shows a row's issue in the inspector.
Its paths are relative to the row."
  (rat-kingdom-plan--obj
   "event" (rat-kingdom-plan--obj
            "name" "open"
            "context" (rat-kingdom-plan--obj
                       "repo" (rat-kingdom-plan--path "repo")
                       "id" (rat-kingdom-plan--path "id")))))

(defun rat-kingdom-ledger--columns (&rest columns)
  "Return the Table COLUMNS, each (KEY LABEL . PROPERTIES), as JSON objects."
  (vconcat (mapcar (pcase-lambda (`(,key ,label . ,properties))
                     (apply #'rat-kingdom-plan--obj "key" key "label" label
                            properties))
                   columns)))

(defun rat-kingdom-ledger-components ()
  "Return the components of the epic ledger."
  (list
   (rat-kingdom-plan--component
    "root" "Column"
    "children" ["heading" "summary" "filters" "overall" "legend" "result"
                "epics" "empty" "details"])
   (rat-kingdom-plan--component "heading" "Text" "variant" "h2"
                                "text" "Epic ledger")
   (rat-kingdom-plan--component "summary" "Text"
                                "text" (rat-kingdom-plan--path "/summary"))
   (rat-kingdom-plan--component
    "filters" "Row" "children" ["filter-repo" "filter-closed" "filter-apply"])
   (rat-kingdom-plan--component
    "filter-repo" "Picker" "label" "Repository"
    "options" (rat-kingdom-plan--path "/repos")
    "value" (rat-kingdom-plan--path "/filter/repo"))
   (rat-kingdom-plan--component
    "filter-closed" "CheckBox"
    "label" (format "Closed in the last %d days" rat-kingdom-ledger-closed-days)
    "value" (rat-kingdom-plan--path "/filter/closed"))
   (rat-kingdom-plan--component
    "filter-apply" "Button" "child" "filter-apply-label"
    "action" (rat-kingdom-plan--obj
              "event" (rat-kingdom-plan--obj
                       "name" "filter"
                       "context" (rat-kingdom-plan--obj
                                  "repo" (rat-kingdom-plan--path "/filter/repo")
                                  "closed" (rat-kingdom-plan--path
                                            "/filter/closed")))))
   (rat-kingdom-plan--component "filter-apply-label" "Text" "text" "Apply")
   (rat-kingdom-plan--component
    "overall" "Row" "children" ["overall-progress" "overall-spark"])
   (rat-kingdom-plan--component
    "overall-progress" "Progress" "label" "Tasks closed"
    "value" (rat-kingdom-plan--path "/overall/closed")
    "max" (rat-kingdom-plan--path "/overall/total")
    "text" (rat-kingdom-plan--path "/overall/text"))
   (rat-kingdom-plan--component
    "overall-spark" "Sparkline"
    "label" (format "Closed per day, %d days" rat-kingdom-ledger-spark-days)
    "values" (rat-kingdom-plan--path "/overall/spark") "min" 0
    "visible" (rat-kingdom-plan--path "/overall/hasSpark"))
   (rat-kingdom-plan--component
    "legend" "Text" "variant" "caption"
    "text" (concat "C/P/R/B: tasks closed, in progress, ready, blocked. \
+F: has a foreman. Age: since made/changed.\n"
                   "Select a row to expand it. RET on an id shows it in the \
issue inspector."))
   (rat-kingdom-plan--component "result" "Text"
                                "text" (rat-kingdom-plan--path "/result")
                                "tone" (rat-kingdom-plan--path "/resultTone")
                                "visible" (rat-kingdom-plan--path "/hasResult"))
   (rat-kingdom-plan--component
    "epics" "Table"
    "rows" (rat-kingdom-plan--path "/rows")
    "rowKey" "key"
    "selectable" "multiple"
    "selection" (rat-kingdom-plan--path "/expanded")
    "rowAction" (rat-kingdom-ledger--open-action)
    "visible" (rat-kingdom-plan--path "/hasRows")
    "columns" (rat-kingdom-ledger--columns
               '("id" "Epic") '("title" "Title")
               '("done" "Done" "display" "bar" "min" 0 "max" 1)
               '("counts" "C/P/R/B") '("state" "State" "toneKey" "tone")
               '("next" "Next") '("age" "Age")
               '("spark" "Closed" "display" "sparkline" "min" 0)))
   (rat-kingdom-plan--component "empty" "Text" "variant" "caption"
                                "text" "No epics to show."
                                "visible" (rat-kingdom-plan--path "/isEmpty"))
   (rat-kingdom-plan--component
    "details" "Column"
    "children" (rat-kingdom-plan--obj "path" "/details"
                                      "componentId" "detail"))
   (rat-kingdom-plan--component "detail" "Section"
                                "title" (rat-kingdom-plan--path "title")
                                "child" "detail-tasks"
                                "visible" (rat-kingdom-plan--path "visible"))
   (rat-kingdom-plan--component
    "detail-tasks" "Table"
    "rows" (rat-kingdom-plan--path "children")
    "rowKey" "id"
    "rowAction" (rat-kingdom-ledger--open-action)
    "columns" (rat-kingdom-ledger--columns
               '("id" "Task") '("priority" "P")
               '("status" "Status" "toneKey" "tone")
               '("title" "Title") '("story" "Story")))))

(defun rat-kingdom-ledger--message (type &rest pairs)
  "Return the A2UI message TYPE for the ledger, with the fields PAIRS."
  (rat-kingdom-plan--obj
   "version" "v0.9"
   type (apply #'rat-kingdom-plan--obj
               "surfaceId" rat-kingdom-ledger-surface-id pairs)))

(defun rat-kingdom-ledger-update (path value)
  "Return the updateDataModel message setting PATH to VALUE."
  (rat-kingdom-ledger--message "updateDataModel" "path" path "value" value))

;;;; a2ui

(defun rat-kingdom-ledger--require-a2ui ()
  "Signal an error saying a2ui is missing, unless it can be loaded."
  (unless (rat-kingdom-plan-a2ui-p)
    (error "The epic ledger needs a2ui (https://github.com/chazu/a2ui.el), \
which is not installed or cannot be loaded")))

(defun rat-kingdom-ledger--a2ui-session ()
  "Return the a2ui session of the ledger, making it if needed."
  (or rat-kingdom-ledger--session
      (let ((session (a2ui-session-create
                      :name "rat-kingdom"
                      :catalogs '(basic emacs)
                      :send-action-fn (lambda (message _metadata)
                                        (rat-kingdom-ledger--receive message))
                      :on-change-fn (lambda (surface-id)
                                      (rat-kingdom-ledger--changed surface-id)))))
        (a2ui-vui-attach session)
        (setq rat-kingdom-ledger--session session))))

(defun rat-kingdom-ledger--surface ()
  "Return the ledger's a2ui surface, or nil if it is not shown."
  (and rat-kingdom-ledger--session
       (a2ui-session-surface rat-kingdom-ledger--session
                             rat-kingdom-ledger-surface-id)))

(defun rat-kingdom-ledger--live-p ()
  "Return non-nil if the ledger is shown by a2ui."
  (and (rat-kingdom-ledger--surface) t))

(defun rat-kingdom-ledger--send (message)
  "Apply MESSAGE, an A2UI message, to the ledger's session."
  (a2ui-apply-message (rat-kingdom-ledger--a2ui-session) message))

(defun rat-kingdom-ledger--read-expanded ()
  "Return the keys of the rows the user selected on the surface."
  (when-let* ((surface (rat-kingdom-ledger--surface)))
    (let ((value (ignore-errors (a2ui-get surface "/expanded"))))
      (cond ((vectorp value) (cl-remove-if-not #'stringp (append value nil)))
            ((stringp value) (list value))))))

(defun rat-kingdom-ledger--display ()
  "Show the ledger's surface in the main window and return its window."
  (let* ((a2ui-vui-display-action
          '((rat-kingdom-issue--display-in-main-window
             a2ui-vui-display-in-main-window)))
         (buffer (a2ui-show-surface (rat-kingdom-ledger--a2ui-session)
                                    rat-kingdom-ledger-surface-id)))
    (setq rat-kingdom-ledger--buffer buffer)
    (with-current-buffer buffer
      (rat-kingdom-ledger-mode 1))
    (get-buffer-window buffer t)))

;;;; Showing the ledger

(defun rat-kingdom-ledger--keys (model)
  "Return the keys of the rows of MODEL."
  (mapcar (lambda (entry) (plist-get entry :key)) (plist-get model :entries)))

(defun rat-kingdom-ledger-render (space model)
  "Draw the ledger of SPACE showing MODEL.  Return the messages sent.
The rows expanded stay expanded, if MODEL still has them."
  (let ((keys (rat-kingdom-ledger--keys model)))
    (setq rat-kingdom-ledger--expanded
          (cl-remove-if-not (lambda (key) (member key keys))
                            rat-kingdom-ledger--expanded)))
  (let ((messages
         (list (rat-kingdom-ledger--message
                "createSurface" "catalogId" (rat-kingdom-plan--catalog)
                "theme" (rat-kingdom-plan--obj "agentDisplayName" "rat-kingdom"))
               (rat-kingdom-ledger--message
                "updateComponents"
                "components" (vconcat (rat-kingdom-ledger-components)))
               (rat-kingdom-ledger-update
                "/" (rat-kingdom-ledger-data space model
                                             rat-kingdom-ledger--expanded)))))
    (let ((rat-kingdom-ledger--rendering t))
      (dolist (message messages)
        (rat-kingdom-ledger--send message)))
    (setq rat-kingdom-ledger--model model
          rat-kingdom-ledger--last (funcall rat-kingdom-ledger--now))
    messages))

(defun rat-kingdom-ledger-show (&optional space filter select model)
  "Show the epic ledger of SPACE under FILTER in the main window.
SPACE is by default the space rat-kingdom works in, and FILTER, a
property list like `rat-kingdom-ledger--filter', by default what the
ledger showed last.  The ledger is read from the trackers and the
space, unless MODEL, as `rat-kingdom-ledger-gather' returns it, is
given.  With SELECT, select its window.  Signal an error, and show
nothing, if a2ui cannot be loaded or FILTER names an unknown
repository.  Return what it shows, as `rat-kingdom-ledger-gather'
gives it."
  (rat-kingdom-ledger--require-a2ui)
  (let* ((space (or space (rat-kingdom-space-default)))
         (filter (copy-sequence (or filter rat-kingdom-ledger--filter)))
         (model (or model (rat-kingdom-ledger-gather space filter))))
    (setq rat-kingdom-ledger--space space
          rat-kingdom-ledger--filter filter)
    (rat-kingdom-ledger--cancel-timer)
    (rat-kingdom-ledger-render space model)
    (let ((window (rat-kingdom-ledger--display)))
      (when (and select (window-live-p window))
        (select-window window)))
    model))

;;;###autoload
(defun rat-kingdom-ledger (&optional repo)
  "Show the epic ledger: one dense row for each open epic.
With REPO, a repository's name, show only its epics; with REPO `all'
or \"\", every repository's; otherwise what the ledger showed last.
Interactively, a prefix argument asks for the repository.  The ledger
takes the place of the buffer in the selected window; \\`q' buries it
and \\`g' draws it again."
  (interactive
   (list (when current-prefix-arg
           (completing-read "Repository (empty for all): "
                            (mapcar (lambda (record) (plist-get record :name))
                                    (rat-kingdom-repo-list
                                     (rat-kingdom-space-default)))
                            nil t))))
  (rat-kingdom-ledger-show
   nil (if repo
           (list :repo (if (or (eq repo 'all) (string-empty-p repo)) nil repo)
                 :closed (plist-get rat-kingdom-ledger--filter :closed))
         rat-kingdom-ledger--filter)
   t))

(defun rat-kingdom-ledger-refresh ()
  "Draw the epic ledger again from the trackers and the space."
  (interactive)
  (rat-kingdom-ledger-show rat-kingdom-ledger--space rat-kingdom-ledger--filter))

(defvar-keymap rat-kingdom-ledger-mode-map
  :doc "Keymap for `rat-kingdom-ledger-mode'."
  "q" #'quit-window
  "g" #'rat-kingdom-ledger-refresh)

(define-minor-mode rat-kingdom-ledger-mode
  "Minor mode for the buffer of the epic ledger.
\\<rat-kingdom-ledger-mode-map>\\[quit-window] buries it and \
\\[rat-kingdom-ledger-refresh] draws it again."
  :lighter " Ledger"
  :keymap rat-kingdom-ledger-mode-map)

;;;; Expanding rows

(defun rat-kingdom-ledger-expand (keys)
  "Expand the rows of the ledger whose keys are KEYS, and fold the others.
Return the messages sent, or nil if nothing changed."
  (unless (equal keys rat-kingdom-ledger--expanded)
    (setq rat-kingdom-ledger--expanded keys)
    (let ((messages
           (cons (rat-kingdom-ledger-update "/expanded" (vconcat keys))
                 (cl-loop for key in (rat-kingdom-ledger--keys rat-kingdom-ledger--model)
                          for index from 0
                          collect (rat-kingdom-ledger-update
                                   (format "/details/%d/visible" index)
                                   (rat-kingdom-plan--bool (member key keys)))))))
      (let ((rat-kingdom-ledger--rendering t))
        (dolist (message messages)
          (rat-kingdom-ledger--send message)))
      messages)))

;;;; Keeping it up to date

(defun rat-kingdom-ledger--concerns-p (op subject)
  "Return non-nil if OP on SUBJECT may change what the ledger shows.
OP and SUBJECT are as for `rat-kingdom-space-change-functions'."
  (let ((repo (plist-get rat-kingdom-ledger--filter :repo))
        (payload (plist-get subject :payload)))
    (and (not (memq op '(sweep expire)))
         (or (null repo) (equal (plist-get subject :scope) repo))
         (pcase (plist-get subject :category)
           ('epic t)
           ('story (plist-get payload :epic))
           ('available (plist-get payload :parent))))))

(defun rat-kingdom-ledger--on-change (space op subject)
  "Schedule a redraw if OP on SUBJECT in SPACE changes what the ledger shows."
  (when (and rat-kingdom-ledger--space (eq space rat-kingdom-ledger--space)
             (rat-kingdom-ledger--concerns-p op subject))
    (rat-kingdom-ledger-mark)))

(add-hook 'rat-kingdom-space-change-functions #'rat-kingdom-ledger--on-change)

(defun rat-kingdom-ledger--on-settled (space story)
  "Schedule a redraw if the token STORY in SPACE is of an epic the ledger shows.
For `rat-kingdom-task-settled-functions': its task was just closed or
released."
  (when (and rat-kingdom-ledger--space (eq space rat-kingdom-ledger--space)
             (plist-get (plist-get story :payload) :epic)
             (let ((repo (plist-get rat-kingdom-ledger--filter :repo)))
               (or (null repo) (equal (plist-get story :scope) repo))))
    (rat-kingdom-ledger-mark)))

(add-hook 'rat-kingdom-task-settled-functions #'rat-kingdom-ledger--on-settled)

(defun rat-kingdom-ledger-mark ()
  "Schedule a redraw of the ledger.
Redraws come at most every `rat-kingdom-ledger-interval' seconds."
  (unless rat-kingdom-ledger--timer
    (setq rat-kingdom-ledger--timer
          (run-at-time (max 0 (- (+ rat-kingdom-ledger--last
                                    rat-kingdom-ledger-interval)
                                 (funcall rat-kingdom-ledger--now)))
                       nil #'rat-kingdom-ledger-flush))))

(defun rat-kingdom-ledger--cancel-timer ()
  "Cancel the ledger's pending redraw, if any."
  (when (timerp rat-kingdom-ledger--timer)
    (cancel-timer rat-kingdom-ledger--timer))
  (setq rat-kingdom-ledger--timer nil))

(defun rat-kingdom-ledger-flush ()
  "Draw the ledger again, if it is shown.  Return the messages sent.
An error is shown on the surface."
  (rat-kingdom-ledger--cancel-timer)
  (when (and rat-kingdom-ledger--space
             (rat-kingdom-space-db rat-kingdom-ledger--space)
             (rat-kingdom-ledger--live-p))
    (condition-case err
        (rat-kingdom-ledger-render
         rat-kingdom-ledger--space
         (rat-kingdom-ledger-gather rat-kingdom-ledger--space
                                    rat-kingdom-ledger--filter))
      (error
       (setq rat-kingdom-ledger--last (funcall rat-kingdom-ledger--now))
       (rat-kingdom-ledger--result (format "**Error:** %s"
                                           (error-message-string err))
                                   "error")
       nil))))

(defun rat-kingdom-ledger--stop ()
  "Stop following the space: the ledger is no longer shown."
  (rat-kingdom-ledger--cancel-timer)
  (setq rat-kingdom-ledger--space nil
        rat-kingdom-ledger--model nil
        rat-kingdom-ledger--expanded nil))

(defun rat-kingdom-ledger--changed (surface-id)
  "Note that the surface SURFACE-ID changed.
Expand the rows the user selected, or stop if the ledger was deleted."
  (when (and (equal surface-id rat-kingdom-ledger-surface-id)
             (not rat-kingdom-ledger--rendering))
    (if (rat-kingdom-ledger--live-p)
        (when rat-kingdom-ledger--model
          (rat-kingdom-ledger-expand (rat-kingdom-ledger--read-expanded)))
      (when rat-kingdom-ledger--space
        (rat-kingdom-ledger--stop)))))

;;;; The buttons

(defun rat-kingdom-ledger--result (text tone)
  "Show TEXT on the ledger, in TONE."
  (when (rat-kingdom-ledger--live-p)
    (let ((rat-kingdom-ledger--rendering t))
      (rat-kingdom-ledger--send (rat-kingdom-ledger-update "/result" text))
      (rat-kingdom-ledger--send (rat-kingdom-ledger-update "/resultTone" tone))
      (rat-kingdom-ledger--send (rat-kingdom-ledger-update "/hasResult" t)))))

(defun rat-kingdom-ledger-open (repo id)
  "Show the issue ID of REPO, an epic or one of its tasks, in the inspector."
  (rat-kingdom-issue-show (or rat-kingdom-ledger--space (rat-kingdom-space-default))
                          repo id t))

(defun rat-kingdom-ledger-filter (context)
  "Show what the filter in CONTEXT asks for: `repo' and `closed'."
  (rat-kingdom-ledger-show
   rat-kingdom-ledger--space
   (list :repo (rat-kingdom-plan--text (rat-kingdom-plan--get context "repo"))
         :closed (rat-kingdom-plan--true-p (rat-kingdom-plan--get context "closed")))))

(defun rat-kingdom-ledger-handle (name context)
  "Handle the button NAME pressed on the ledger, with CONTEXT."
  (pcase name
    ("open"
     (let ((repo (rat-kingdom-plan--text (rat-kingdom-plan--get context "repo")))
           (id (rat-kingdom-plan--text (rat-kingdom-plan--get context "id"))))
       (when (and repo id)
         (rat-kingdom-ledger-open repo id))))
    ("filter" (rat-kingdom-ledger-filter context))))

(defun rat-kingdom-ledger--receive (message)
  "Act on MESSAGE, which the ledger sent."
  (cond
   ((gethash "action" message)
    (let* ((action (gethash "action" message))
           (name (gethash "name" action))
           (context (gethash "context" action)))
      (funcall rat-kingdom-ledger--defer
               (lambda ()
                 (condition-case err
                     (rat-kingdom-ledger-handle name context)
                   (error
                    (rat-kingdom-ledger--result
                     (format "**Error:** %s" (error-message-string err))
                     "error")
                    (message "rat-kingdom: the epic ledger: %s"
                             (error-message-string err))))))))
   ((gethash "error" message)
    (let ((err (gethash "error" message)))
      (message "rat-kingdom: the epic ledger reports %s: %s"
               (gethash "code" err) (gethash "message" err))))))

;;;; The issue inspector's Open parent epic

(defun rat-kingdom-ledger--find (model repo id)
  "Return the row of MODEL for the epic ID of REPO, or nil."
  (cl-find (rat-kingdom-ledger--key repo id) (plist-get model :entries)
           :key (lambda (entry) (plist-get entry :key)) :test #'equal))

(defun rat-kingdom-ledger-open-epic (space repo epic)
  "Show the ledger of REPO in SPACE with the epic EPIC expanded.
For `rat-kingdom-issue-open-epic-function'.  A closed epic is looked
for among those closed lately too.  Return non-nil if the ledger shows
EPIC; otherwise show nothing and return nil, so that the inspector
shows it."
  (when (rat-kingdom-plan-a2ui-p)
    (let* ((filter (list :repo repo
                         :closed (plist-get rat-kingdom-ledger--filter :closed)))
           (model (rat-kingdom-ledger-gather space filter)))
      (unless (or (rat-kingdom-ledger--find model repo epic)
                  (plist-get filter :closed))
        (setq filter (list :repo repo :closed t)
              model (rat-kingdom-ledger-gather space filter)))
      (when (rat-kingdom-ledger--find model repo epic)
        (setq rat-kingdom-ledger--expanded
              (list (rat-kingdom-ledger--key repo epic)))
        (rat-kingdom-ledger-show space filter t model)
        t))))

(unless rat-kingdom-issue-open-epic-function
  (setq rat-kingdom-issue-open-epic-function #'rat-kingdom-ledger-open-epic))

;;;; The king's tool

(rat-kingdom-king--deftool "ledger_show"
    "Show the user the epic ledger in Emacs: one dense row for each open \
epic, with its progress, the counts of its tasks closed, in progress, ready \
and blocked, the engine's state (not started, running, paused, landing or \
held), its next ready task and its age; those that need attention come \
first. It takes the place of the buffer in the user's main window, and \
changes nothing. Use it when the user asks how the epics stand."
    '((:name "repo" :type string :optional t
             :description "Only this repository's epics; by default, every \
repository's."))
  (let ((repo (rat-kingdom-plan--text (arg 'repo))))
    (when (and repo (not (rat-kingdom-repo-get space repo)))
      (error "There is no repository called %s.  Nothing was shown" repo))
    (unless (rat-kingdom-plan-a2ui-p)
      (error "The epic ledger is not available: a2ui is not installed or \
cannot be loaded in the user's Emacs.  Nothing was shown.  Tell the user \
how the epics stand with status instead"))
    (let* ((model (rat-kingdom-ledger-show
                   space (list :repo repo
                               :closed (plist-get rat-kingdom-ledger--filter
                                                  :closed))))
           (problems (plist-get model :problems)))
      (format "Shown to the user: the epic ledger of %s: %s.%s"
              (or repo "all repositories")
              (rat-kingdom-ledger-summary model)
              (if problems
                  (concat " Not all could be read: "
                          (mapconcat (lambda (problem)
                                       (string-trim-right problem "[. ]+"))
                                     problems "; ")
                          ".")
                "")))))

(provide 'rat-kingdom-ledger)
;;; rat-kingdom-ledger.el ends here
