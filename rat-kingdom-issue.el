;;; rat-kingdom-issue.el --- The issue inspector surface -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Chaz Straney

;; Author: Chaz Straney <chaz.straney@gmail.com>
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;;; Commentary:

;; The issue inspector (DESIGN.md, section 14.1): all of one tracker
;; issue, drawn by the engine in an a2ui surface, the "Issue
;; inspector".  No model is involved.  `rat-kingdom-issue' asks for a
;; repository and an issue and shows it, and the king's `issue_show'
;; shows it for the user.  It is shown in the main window, as the story
;; board is: the selected window of the selected frame takes it in
;; place of its buffer, unless that is a side window or a dedicated
;; one, in which case a2ui's main window does.  \\`q' buries it, and
;; \\`g' draws it again from the tracker and the space.
;;
;; Everything scrolls in one buffer.  A dense header line gives the
;; issue's id, priority, type, status, age, the time since its last
;; update, its parent epic, labels and assignee, and a second line the
;; dates and fields br keeps only for some issues, such as the close
;; reason and the deferred date.  The full title follows, and then
;; Sections, which fold with RET or TAB on their headings: Description
;; (the full Markdown), Acceptance (a checklist from the `- [ ]' and
;; `- [x]' lines of the description and of the acceptance criteria,
;; and the acceptance criteria in full), Design, Notes, Dependencies
;; (each blocker, each issue this one blocks, and each child, with a
;; button that inspects it), Stories (the engine's stories for the
;; issue) and Comments, oldest first.  A Section with nothing to show
;; is left out, except Description and Stories.  Sections start
;; unfolded, and a Section folded stays folded, for every issue shown,
;; until the surface is closed.
;;
;; The buttons are Open parent epic, Refresh and Close.  No button
;; starts a story or changes the tracker: those stay with the king.
;; Open parent epic calls `rat-kingdom-issue-open-epic-function', if it
;; is set, so that an epic surface can take over; otherwise it shows
;; the parent in the inspector.
;;
;; The issue comes from the repository's task adapter, through
;; `rat-kingdom-issue-read'.  For br it is one `br show ID --json',
;; which gives every field of the issue, its dependencies and its
;; dependents, each with its type, and its comments.  The stories are
;; the live and archived `story' tokens whose `:task' is the issue,
;; with their runs and the verdicts in the space's log.
;;
;; The inspector follows `rat-kingdom-space-change-functions': a change
;; to one of the issue's stories, or a story started for it, draws it
;; again, at most every `rat-kingdom-issue-interval' seconds, and so
;; does `rat-kingdom-task-settled-functions' when such a story's task
;; is closed or released.  Nothing in rat-kingdom watches the tracker's
;; files, so a change made to the issue outside rat-kingdom is shown on
;; \\`g' or Refresh.
;;
;; a2ui is optional, as for the epic plan (rat-kingdom-plan.el): it is
;; loaded when the inspector is first shown, and the inspector says
;; plainly when it cannot be.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'iso8601)
(require 'rat-kingdom-space)
(require 'rat-kingdom-git)
(require 'rat-kingdom-run)
(require 'rat-kingdom-task)
(require 'rat-kingdom-story)
(require 'rat-kingdom-king)
(require 'rat-kingdom-plan)

(declare-function a2ui-session-create "a2ui-core")
(declare-function a2ui-session-surface "a2ui-core" (session surface-id))
(declare-function a2ui-apply-message "a2ui-core" (session message))
(declare-function a2ui-delete-surface "a2ui-core" (session surface-id))
(declare-function a2ui-get "a2ui-core" (surface path &optional scope))
(declare-function a2ui-vui-attach "a2ui-vui" (session))
(declare-function a2ui-show-surface "a2ui-vui" (session surface-id))
(declare-function a2ui-vui-display-in-main-window "a2ui-vui" (buffer alist))
(declare-function rat-kingdom-run-display-name "rat-kingdom-run" (run))
(defvar a2ui-vui-display-action)

(defconst rat-kingdom-issue-surface-id "Issue inspector"
  "The id of the issue inspector's surface.")

(defconst rat-kingdom-issue-sections
  '((description . "Description") (acceptance . "Acceptance")
    (design . "Design") (notes . "Notes") (dependencies . "Dependencies")
    (stories . "Stories") (comments . "Comments"))
  "The inspector's Sections, in order, each with its title.")

(defcustom rat-kingdom-issue-interval 0.5
  "The fewest seconds between two redraws of the issue inspector."
  :type 'number
  :group 'rat-kingdom)

(defvar rat-kingdom-issue-open-epic-function nil
  "Function that shows an epic for the inspector's Open parent epic, or nil.
It is called with the space, the repository's name and the epic's id,
and returns non-nil if it showed the epic.  When it is nil, or returns
nil, the inspector shows the epic itself.")

(define-error 'rat-kingdom-issue-unknown "No such issue" 'rat-kingdom-task-error)

(defvar rat-kingdom-issue--session nil
  "The a2ui session that holds the issue inspector, or nil.")

(defvar rat-kingdom-issue--space nil
  "The space of the issue shown, or nil while none is shown.")

(defvar rat-kingdom-issue--repo nil
  "The repository of the issue shown, or nil.")

(defvar rat-kingdom-issue--id nil
  "The id of the issue shown, or nil.")

(defvar rat-kingdom-issue--model nil
  "What the inspector shows, as `rat-kingdom-issue-gather' returns it.")

(defvar rat-kingdom-issue--collapsed nil
  "The Sections folded, as an alist of (SECTION . FOLDED).
SECTION is a symbol of `rat-kingdom-issue-sections'.  It is kept from
one issue to the next while the surface is open.")

(defvar rat-kingdom-issue--buffer nil
  "The buffer a2ui shows the inspector in, or nil.")

(defvar rat-kingdom-issue--timer nil
  "The timer of the next redraw of the inspector, or nil.")

(defvar rat-kingdom-issue--last 0
  "When the inspector was last drawn, as `float-time' gives it.")

(defvar rat-kingdom-issue--defer (lambda (function) (run-at-time 0 nil function))
  "How a button's handler is run: later, outside the button press.")

(defvar rat-kingdom-issue--now #'float-time
  "Function returning the time, for the inspector's throttle.  Tests replace it.")

;;;; The tracker

(cl-defgeneric rat-kingdom-issue-read (adapter id)
  "Return the issue ID of ADAPTER's tracker in full, as a property list.
Its keys are those of `br show --json': `:id', `:title', `:status',
`:priority', `:issue_type', `:description', `:design',
`:acceptance_criteria', `:notes', `:labels', `:assignee', `:owner',
`:parent', `:created_at', `:created_by', `:updated_at', `:closed_at',
`:close_reason', `:defer_until', `:due_at', `:external_ref',
`:dependencies' and `:dependents' (each a list of `:id', `:title',
`:status' and `:dependency_type') and `:comments' (each `:author',
`:text' and `:created_at').  Any but `:id' may be missing.  Signal
`rat-kingdom-issue-unknown' if there is no such issue, and
`rat-kingdom-task-error' if the tracker fails.")

(cl-defgeneric rat-kingdom-issue-open-issues (adapter)
  "Return the open issues of ADAPTER's tracker, as a list of (ID . TITLE).")

(defun rat-kingdom-issue--br-unknown-p (err)
  "Return non-nil if ERR, a `rat-kingdom-task-error', says there is no issue."
  (string-match-p "ISSUE_NOT_FOUND\\|[Ii]ssue not found\\|no such task"
                  (error-message-string err)))

(cl-defmethod rat-kingdom-issue-read ((adapter rat-kingdom-task-br) id)
  "Return the issue ID from `br show ID --json' in ADAPTER's workspace.
br 0.2 gives the comments, the dependencies and the dependents in it,
so no other br command is needed."
  (condition-case err
      (or (car (rat-kingdom-task-br--run adapter "show" id))
          (signal 'rat-kingdom-issue-unknown (list id)))
    (rat-kingdom-issue-unknown (signal (car err) (cdr err)))
    (rat-kingdom-task-error
     (if (rat-kingdom-issue--br-unknown-p err)
         (signal 'rat-kingdom-issue-unknown (list id))
       (signal (car err) (cdr err))))))

(cl-defmethod rat-kingdom-issue-open-issues ((adapter rat-kingdom-task-br))
  "Return the issues `br list --json' gives in ADAPTER's workspace.
br lists the issues that are not closed.  It wraps them in an object,
`issues'; a br that gives a bare array is understood too."
  (let* ((output (rat-kingdom-task-br--run adapter "list"))
         (issues (if (keywordp (car output)) (plist-get output :issues) output)))
    (mapcar (lambda (issue)
              (cons (plist-get issue :id) (or (plist-get issue :title) "")))
            issues)))

;;;; Gathering

(defun rat-kingdom-issue-checklist (&rest texts)
  "Return the checklist items in TEXTS, Markdown or nil, in order.
An item is a line such as \"- [ ] do it\" or \"* [x] done\".  Each is
returned as (DONE . TEXT)."
  (let (items)
    (dolist (text texts)
      (when (stringp text)
        (dolist (line (split-string text "\n"))
          (when (string-match
                 "\\`[ \t]*[-*+][ \t]+\\[\\([ xX]\\)\\][ \t]+\\(.*?\\)[ \t]*\\'"
                 line)
            (push (cons (not (equal (match-string 1 line) " "))
                        (match-string 2 line))
                  items)))))
    (nreverse items)))

(defun rat-kingdom-issue--time (text)
  "Return the time in TEXT, an ISO 8601 string, as `float-time', or nil."
  (and (stringp text) (not (string-empty-p text))
       (ignore-errors (float-time (encode-time (iso8601-parse text))))))

(defun rat-kingdom-issue-age-text (seconds)
  "Return SECONDS as a short age, such as 45s, 12m, 3h 5m or 2d."
  (let ((seconds (max 0 (truncate seconds))))
    (cond ((< seconds 60) (format "%ds" seconds))
          ((< seconds 3600) (format "%dm" (/ seconds 60)))
          ((< seconds 86400)
           (let ((minutes (% (/ seconds 60) 60)))
             (if (zerop minutes)
                 (format "%dh" (/ seconds 3600))
               (format "%dh %dm" (/ seconds 3600) minutes))))
          (t (format "%dd" (/ seconds 86400))))))

(defun rat-kingdom-issue--ago (text)
  "Return how long ago the ISO 8601 time TEXT was, as a short age, or nil."
  (when-let* ((time (rat-kingdom-issue--time text)))
    (rat-kingdom-issue-age-text
     (- (funcall rat-kingdom-space-now-function) time))))

(defun rat-kingdom-issue--date (text)
  "Return the ISO 8601 time TEXT as a local date and time, or TEXT."
  (if-let* ((time (rat-kingdom-issue--time text)))
      (format-time-string "%Y-%m-%d %H:%M" time)
    text))

(defun rat-kingdom-issue--archived-stories (space repo task)
  "Return the archived tokens of the stories of REPO in SPACE for TASK.
Only the last token of each story is kept, oldest first."
  (let ((found nil))
    (dolist (row (sqlite-select
                  (rat-kingdom-space-db space)
                  (format "SELECT %s, archived FROM archive
                           WHERE category = 'story' AND scope = ?
                             AND json_extract(payload, '$.task') = ?
                           ORDER BY id"
                          rat-kingdom-space--columns)
                  (list repo task)))
      (let ((token (append (rat-kingdom-space--row-tuple (butlast row))
                           (list :archived (car (last row))))))
        (setq found (cons token (cl-remove (plist-get token :identity) found
                                           :key (lambda (old)
                                                  (plist-get old :identity))
                                           :test #'equal)))))
    (nreverse found)))

(defun rat-kingdom-issue--verdicts (space story)
  "Return the verdicts given on the story STORY in SPACE, oldest first.
Each is a property list: `:value', `:notes', `:actor' and `:at'.  A
verdict is taken when the story moves on, so they are read from the
space's log."
  (mapcar (pcase-lambda (`(,payload ,actor ,at))
            (let ((payload (rat-kingdom-space--decode payload)))
              (list :value (plist-get payload :value)
                    :notes (plist-get payload :notes)
                    :actor actor :at at)))
          (sqlite-select
           (rat-kingdom-space-db space)
           "SELECT payload, actor, at FROM ops
            WHERE op = 'out' AND category = 'verdict' AND identity = ?
            ORDER BY id"
           (list story))))

(defun rat-kingdom-issue--run-name (run)
  "Return the name to show for the run record RUN."
  (or (and (fboundp 'rat-kingdom-run-display-name)
           (ignore-errors (rat-kingdom-run-display-name run)))
      (plist-get run :id)))

(defun rat-kingdom-issue--workers (space story)
  "Return the names of the workers of the story STORY in SPACE, oldest first.
They are its runs, live and archived, of the roles rat and researcher."
  (let ((runs (append
               (mapcar #'rat-kingdom-run--record
                       (cl-remove-if-not (lambda (tuple)
                                           (eq (plist-get tuple :category) 'run))
                                         (rat-kingdom-space-archived space story)))
               (rat-kingdom-run-list space story)))
        names)
    (dolist (run runs)
      (when (member (plist-get run :role) '("rat" "researcher"))
        (cl-pushnew (rat-kingdom-issue--run-name run) names :test #'equal)))
    (nreverse names)))

(defun rat-kingdom-issue--outcome (payload archived)
  "Return where a story whose token has PAYLOAD stands, or how it ended.
ARCHIVED is non-nil if the token is archived."
  (let ((phase (plist-get payload :phase)))
    (cond
     ((plist-get payload :integrated) "merged")
     ((equal phase "cancelled") "cancelled")
     ((equal phase "done") (format "done at %s" (plist-get payload :at)))
     (archived (format "ended at %s" (plist-get payload :at)))
     ((equal phase "parked")
      (format "parked at %s: %s" (plist-get payload :at)
              (or (plist-get payload :reason) "no reason given")))
     ((equal phase "wait")
      (format "at %s, waiting for %s" (plist-get payload :at)
              (plist-get payload :awaiting)))
     (t (format "at %s" (plist-get payload :at))))))

(defun rat-kingdom-issue--story (space token)
  "Return what the inspector shows of the story whose token is TOKEN in SPACE.
That is a property list: `:id', `:title', `:workers' (names),
`:workflow', `:outcome', `:rounds' (how many times it went back to a
worker), `:verdicts' and `:merge' (the commit it was merged at, or
nil)."
  (let* ((id (plist-get token :identity))
         (payload (plist-get token :payload))
         (workers (rat-kingdom-issue--workers space id)))
    (list :id id :title (plist-get payload :title)
          :workers workers
          :workflow (plist-get payload :workflow)
          :outcome (rat-kingdom-issue--outcome payload
                                               (plist-get token :archived))
          :rounds (max 0 (1- (max (or (plist-get payload :attempt) 0)
                                  (length workers))))
          :verdicts (rat-kingdom-issue--verdicts space id)
          :merge (plist-get payload :integrated))))

(defun rat-kingdom-issue-stories (space repo task)
  "Return the stories of REPO in SPACE that worked on TASK, oldest first.
Each is as `rat-kingdom-issue--story' returns it.  A child story is
its parent's work, and is not included."
  (let* ((live (rat-kingdom-space-scan space (list 'story :scope repo :task task)))
         (ids (mapcar (lambda (token) (plist-get token :identity)) live))
         (archived (cl-remove-if (lambda (token)
                                   (member (plist-get token :identity) ids))
                                 (rat-kingdom-issue--archived-stories
                                  space repo task))))
    (mapcar (lambda (token) (rat-kingdom-issue--story space token))
            (append archived live))))

(defun rat-kingdom-issue--links (issue)
  "Return the issues ISSUE links to, as a list of (RELATION . OTHER).
RELATION is \"blocked by\", \"blocks\", \"child\" or the type of a
dependency of another kind; OTHER is a property list with `:id',
`:status' and `:title'.  The parent is not included: the header names
it."
  (let (links)
    (dolist (dependency (plist-get issue :dependencies))
      (pcase (plist-get dependency :dependency_type)
        ("parent-child" nil)
        ("blocks" (push (cons "blocked by" dependency) links))
        (type (push (cons (format "%s" (or type "related")) dependency) links))))
    (dolist (dependent (plist-get issue :dependents))
      (pcase (plist-get dependent :dependency_type)
        ("parent-child" (push (cons "child" dependent) links))
        ("blocks" (push (cons "blocks" dependent) links))
        (type (push (cons (format "%s of" (or type "related")) dependent)
                    links))))
    (nreverse links)))

(defun rat-kingdom-issue-gather (space repo id)
  "Return what the inspector shows of the issue ID of REPO in SPACE.
That is a property list: `:repo', `:id', `:issue' as
`rat-kingdom-issue-read' gives it, `:checklist' as
`rat-kingdom-issue-checklist' gives it, `:links' as
`rat-kingdom-issue--links' gives them, and `:stories' as
`rat-kingdom-issue-stories' gives them.  Signal an error that says so if
REPO is not registered, has no tracker, or its tracker has no issue ID."
  (unless (rat-kingdom-repo-get space repo)
    (error "There is no repository called %s; the repositories are: %s"
           repo (or (mapconcat (lambda (record) (plist-get record :name))
                               (rat-kingdom-repo-list space) ", ")
                    "none")))
  (let* ((adapter (or (rat-kingdom-task-adapter space repo)
                      (error "The repository %s has no task tracker" repo)))
         (issue (condition-case err
                    (rat-kingdom-issue-read adapter id)
                  (rat-kingdom-issue-unknown
                   (error "The tracker of %s has no issue %s" repo id))
                  (rat-kingdom-task-error
                   (error "The tracker of %s failed: %s" repo
                          (error-message-string err))))))
    (list :repo repo :id (or (plist-get issue :id) id) :issue issue
          :checklist (rat-kingdom-issue-checklist
                      (plist-get issue :description)
                      (plist-get issue :acceptance_criteria))
          :links (rat-kingdom-issue--links issue)
          :stories (rat-kingdom-issue-stories space repo
                                              (or (plist-get issue :id) id)))))

;;;; The surface, as data

(defun rat-kingdom-issue--text (value)
  "Return VALUE, a field of an issue, as a string, or nil if it is blank."
  (let ((text (cond ((null value) nil)
                    ((stringp value) value)
                    (t (format "%s" value)))))
    (and text (not (string-blank-p text)) text)))

(defun rat-kingdom-issue-header (issue)
  "Return the dense header line of ISSUE, in Markdown."
  (let ((labels (plist-get issue :labels)))
    (string-join
     (delq nil
           (list (format "**%s**" (plist-get issue :id))
                 (and (plist-get issue :priority)
                      (format "P%s" (plist-get issue :priority)))
                 (rat-kingdom-issue--text (plist-get issue :issue_type))
                 (rat-kingdom-issue--text (plist-get issue :status))
                 (when-let* ((age (rat-kingdom-issue--ago
                                   (plist-get issue :created_at))))
                   (format "%s old" age))
                 (when-let* ((age (rat-kingdom-issue--ago
                                   (plist-get issue :updated_at))))
                   (format "updated %s ago" age))
                 (when-let* ((parent (rat-kingdom-issue--text
                                      (plist-get issue :parent))))
                   (format "epic %s" parent))
                 (and labels (format "labels %s" (string-join labels ", ")))
                 (when-let* ((assignee (rat-kingdom-issue--text
                                        (plist-get issue :assignee))))
                   (format "assignee %s" assignee))))
     " · ")))

(defun rat-kingdom-issue-details (issue)
  "Return the line of ISSUE's other fields, or \"\" if it has none.
Those are who created it, its owner, when it was closed and why, the
dates it is deferred to and due, and its external reference."
  (string-join
   (delq nil
         (list (when-let* ((by (rat-kingdom-issue--text
                                (plist-get issue :created_by))))
                 (format "created by %s %s" by
                         (rat-kingdom-issue--date (plist-get issue :created_at))))
               (when-let* ((owner (rat-kingdom-issue--text
                                   (plist-get issue :owner))))
                 (format "owner %s" owner))
               (when-let* ((closed (rat-kingdom-issue--text
                                    (plist-get issue :closed_at))))
                 (format "closed %s" (rat-kingdom-issue--date closed)))
               (when-let* ((reason (rat-kingdom-issue--text
                                    (plist-get issue :close_reason))))
                 (format "close reason: %s" reason))
               (when-let* ((defer (rat-kingdom-issue--text
                                   (plist-get issue :defer_until))))
                 (format "deferred until %s" (rat-kingdom-issue--date defer)))
               (when-let* ((due (rat-kingdom-issue--text
                                 (plist-get issue :due_at))))
                 (format "due %s" (rat-kingdom-issue--date due)))
               (when-let* ((ref (rat-kingdom-issue--text
                                 (plist-get issue :external_ref))))
                 (format "ref %s" ref))))
   " · "))

(defun rat-kingdom-issue--present (model)
  "Return the Sections MODEL has something for, in order."
  (let ((issue (plist-get model :issue)))
    (cl-loop for (section . _) in rat-kingdom-issue-sections
             when (pcase section
                    ('acceptance
                     (or (plist-get model :checklist)
                         (rat-kingdom-issue--text
                          (plist-get issue :acceptance_criteria))))
                    ('design (rat-kingdom-issue--text (plist-get issue :design)))
                    ('notes (rat-kingdom-issue--text (plist-get issue :notes)))
                    ('dependencies (plist-get model :links))
                    ('comments (plist-get issue :comments))
                    (_ t))
             collect section)))

(defun rat-kingdom-issue--section-title (section model)
  "Return the heading of SECTION for MODEL, with a count where it helps."
  (let ((title (alist-get section rat-kingdom-issue-sections))
        (issue (plist-get model :issue)))
    (pcase section
      ('acceptance
       (let ((items (plist-get model :checklist)))
         (if items
             (format "%s (%d/%d done)" title (cl-count-if #'car items)
                     (length items))
           title)))
      ('dependencies (format "%s (%d)" title (length (plist-get model :links))))
      ('stories (format "%s (%d)" title (length (plist-get model :stories))))
      ('comments (format "%s (%d)" title (length (plist-get issue :comments))))
      (_ title))))

(defun rat-kingdom-issue--section-body (section model)
  "Return the components of the body of SECTION for MODEL, its root first."
  (let ((name (symbol-name section))
        (issue (plist-get model :issue)))
    (pcase section
      ('description
       (list (rat-kingdom-plan--component
              "description-body" "Text"
              "text" (rat-kingdom-plan--path "/description"))))
      ('acceptance
       (let ((table (and (plist-get model :checklist)
                         (rat-kingdom-plan--component
                          "acceptance-table" "Table"
                          "rows" (rat-kingdom-plan--path "/checklist")
                          "columns" (vector
                                     (rat-kingdom-plan--obj "key" "mark"
                                                            "label" "")
                                     (rat-kingdom-plan--obj "key" "item"
                                                            "label" "Item")))))
             (text (and (rat-kingdom-issue--text
                         (plist-get issue :acceptance_criteria))
                        (rat-kingdom-plan--component
                         "acceptance-text" "Text"
                         "text" (rat-kingdom-plan--path "/acceptance")))))
         (cons (rat-kingdom-plan--component
                "acceptance-body" "Column"
                "children" (vconcat (delq nil (list (and table "acceptance-table")
                                                    (and text "acceptance-text")))))
               (delq nil (list table text)))))
      ((or 'design 'notes)
       (list (rat-kingdom-plan--component
              (concat name "-body") "Text"
              "text" (rat-kingdom-plan--path (concat "/" name)))))
      ('dependencies
       (list (rat-kingdom-plan--component
              "dependencies-body" "Column"
              "children" (rat-kingdom-plan--obj "path" "/links"
                                                "componentId" "link"))
             (rat-kingdom-plan--component "link" "Row"
                                          "children" ["link-open" "link-text"])
             (rat-kingdom-plan--component
              "link-open" "Button" "child" "link-open-label"
              "action" (rat-kingdom-plan--obj
                        "event" (rat-kingdom-plan--obj
                                 "name" "open"
                                 "context" (rat-kingdom-plan--obj
                                            "id" (rat-kingdom-plan--path "id")))))
             (rat-kingdom-plan--component "link-open-label" "Text"
                                          "text" (rat-kingdom-plan--path "id"))
             (rat-kingdom-plan--component "link-text" "Text"
                                          "text" (rat-kingdom-plan--path "line"))))
      ('stories
       (if (plist-get model :stories)
           (list (rat-kingdom-plan--component
                  "stories-body" "Column"
                  "children" ["stories-table" "stories-verdicts"])
                 (rat-kingdom-plan--component
                  "stories-table" "Table"
                  "rows" (rat-kingdom-plan--path "/stories")
                  "columns"
                  (vconcat
                   (mapcar (pcase-lambda (`(,key . ,label))
                             (rat-kingdom-plan--obj "key" key "label" label))
                           '(("id" . "Story") ("workers" . "Workers")
                             ("workflow" . "Workflow") ("outcome" . "Outcome")
                             ("rounds" . "Fix rounds") ("merge" . "Merge")))))
                 (rat-kingdom-plan--component
                  "stories-verdicts" "Text"
                  "text" (rat-kingdom-plan--path "/verdicts")
                  "visible" (rat-kingdom-plan--path "/hasVerdicts")))
         (list (rat-kingdom-plan--component
                "stories-body" "Text" "variant" "caption"
                "text" "No story has worked on this issue."))))
      ('comments
       (list (rat-kingdom-plan--component
              "comments-body" "Column"
              "children" (rat-kingdom-plan--obj "path" "/comments"
                                                "componentId" "comment"))
             (rat-kingdom-plan--component "comment" "Column"
                                          "children" ["comment-heading"
                                                      "comment-text"])
             (rat-kingdom-plan--component "comment-heading" "Text"
                                          "variant" "caption"
                                          "text" (rat-kingdom-plan--path
                                                  "heading"))
             (rat-kingdom-plan--component "comment-text" "Text"
                                          "text" (rat-kingdom-plan--path
                                                  "text")))))))

(defun rat-kingdom-issue-components (model)
  "Return the components of the inspector showing MODEL."
  (let ((present (rat-kingdom-issue--present model)))
    (append
     (list
      (rat-kingdom-plan--component
       "root" "Column"
       "children" (vconcat (list "header" "details" "title" "buttons" "result")
                           (mapcar (lambda (section)
                                     (format "section-%s" section))
                                   present)))
      (rat-kingdom-plan--component "header" "Text"
                                   "text" (rat-kingdom-plan--path "/header"))
      (rat-kingdom-plan--component "details" "Text" "variant" "caption"
                                   "text" (rat-kingdom-plan--path "/details")
                                   "visible" (rat-kingdom-plan--path
                                              "/hasDetails"))
      (rat-kingdom-plan--component "title" "Text" "variant" "h2"
                                   "text" (rat-kingdom-plan--path "/title"))
      (rat-kingdom-plan--component
       "buttons" "Row" "children" ["button-parent" "button-refresh"
                                   "button-close"])
      (rat-kingdom-plan--component
       "button-parent" "Button" "child" "button-parent-label"
       "visible" (rat-kingdom-plan--path "/hasParent")
       "action" (rat-kingdom-plan--obj
                 "event" (rat-kingdom-plan--obj
                          "name" "parent"
                          "context" (rat-kingdom-plan--obj
                                     "id" (rat-kingdom-plan--path "/parent")))))
      (rat-kingdom-plan--component "button-parent-label" "Text"
                                   "text" "Open parent epic")
      (rat-kingdom-plan--component
       "button-refresh" "Button" "child" "button-refresh-label"
       "action" (rat-kingdom-plan--obj
                 "event" (rat-kingdom-plan--obj "name" "refresh")))
      (rat-kingdom-plan--component "button-refresh-label" "Text"
                                   "text" "Refresh")
      (rat-kingdom-plan--component
       "button-close" "Button" "child" "button-close-label"
       "action" (rat-kingdom-plan--obj
                 "event" (rat-kingdom-plan--obj "name" "close")))
      (rat-kingdom-plan--component "button-close-label" "Text" "text" "Close")
      (rat-kingdom-plan--component "result" "Text"
                                   "text" (rat-kingdom-plan--path "/result")
                                   "tone" (rat-kingdom-plan--path "/resultTone")
                                   "visible" (rat-kingdom-plan--path
                                              "/hasResult")))
     (mapcan (lambda (section)
               (let* ((body (rat-kingdom-issue--section-body section model)))
                 (cons (rat-kingdom-plan--component
                        (format "section-%s" section) "Section"
                        "title" (rat-kingdom-issue--section-title section model)
                        "child" (gethash "id" (car body))
                        "collapsed" (rat-kingdom-plan--path
                                     (format "/collapsed/%s" section)))
                       body)))
             present))))

(defun rat-kingdom-issue--verdicts-text (stories)
  "Return the verdicts of STORIES as Markdown, or \"\" if there are none."
  (string-join
   (cl-loop for story in stories
            append (cl-loop for verdict in (plist-get story :verdicts)
                            collect (format "- **%s** %s by %s%s"
                                            (plist-get story :id)
                                            (plist-get verdict :value)
                                            (or (plist-get verdict :actor) "?")
                                            (if-let* ((notes (rat-kingdom-issue--text
                                                              (plist-get verdict
                                                                         :notes))))
                                                (concat ": " (replace-regexp-in-string
                                                              "\n" "\n  " notes))
                                              ""))))
   "\n"))

(defun rat-kingdom-issue--prose (text)
  "Return TEXT, Markdown, for a Text component, with its blank lines kept.
a2ui leaves out a line with nothing on it, so each holds a space."
  (mapconcat (lambda (line) (if (string-empty-p line) " " line))
             (split-string (or text "") "\n") "\n"))

(defun rat-kingdom-issue--link-object (link)
  "Return LINK, (RELATION . OTHER), as the JSON object the data model holds."
  (let ((other (cdr link)))
    (rat-kingdom-plan--obj
     "id" (plist-get other :id)
     "relation" (car link)
     "line" (format "%s · %s · %s" (car link)
                    (or (plist-get other :status) "?")
                    (or (plist-get other :title) "")))))

(defun rat-kingdom-issue-data (model collapsed)
  "Return the inspector's data model for MODEL.
COLLAPSED is the alist of the Sections folded, as
`rat-kingdom-issue--collapsed' holds it."
  (let* ((issue (plist-get model :issue))
         (details (rat-kingdom-issue-details issue))
         (stories (plist-get model :stories))
         (verdicts (rat-kingdom-issue--verdicts-text stories))
         (parent (rat-kingdom-issue--text (plist-get issue :parent))))
    (rat-kingdom-plan--obj
     "header" (rat-kingdom-issue-header issue)
     "details" details
     "hasDetails" (rat-kingdom-plan--bool (not (string-empty-p details)))
     "title" (or (plist-get issue :title) "")
     "parent" (or parent "")
     "hasParent" (rat-kingdom-plan--bool parent)
     "result" "" "resultTone" "muted" "hasResult" :false
     "collapsed" (let ((object (rat-kingdom-plan--obj)))
                   (pcase-dolist (`(,section . ,_) rat-kingdom-issue-sections)
                     (puthash (symbol-name section)
                              (rat-kingdom-plan--bool
                               (alist-get section collapsed))
                              object))
                   object)
     "description" (rat-kingdom-issue--prose
                    (or (rat-kingdom-issue--text (plist-get issue :description))
                        "No description."))
     "acceptance" (rat-kingdom-issue--prose (plist-get issue :acceptance_criteria))
     "checklist" (vconcat
                  (mapcar (lambda (item)
                            (rat-kingdom-plan--obj
                             "mark" (if (car item) "[x]" "[ ]")
                             "done" (rat-kingdom-plan--bool (car item))
                             "item" (cdr item)))
                          (plist-get model :checklist)))
     "design" (rat-kingdom-issue--prose (plist-get issue :design))
     "notes" (rat-kingdom-issue--prose (plist-get issue :notes))
     "links" (vconcat (mapcar #'rat-kingdom-issue--link-object
                              (plist-get model :links)))
     "stories" (vconcat
                (mapcar (lambda (story)
                          (rat-kingdom-plan--obj
                           "id" (plist-get story :id)
                           "workers" (string-join (plist-get story :workers) ", ")
                           "workflow" (or (plist-get story :workflow) "")
                           "outcome" (plist-get story :outcome)
                           "rounds" (number-to-string (plist-get story :rounds))
                           "merge" (if-let* ((head (plist-get story :merge)))
                                       (substring head 0 (min 7 (length head)))
                                     "")))
                        stories))
     "verdicts" (rat-kingdom-issue--prose verdicts)
     "hasVerdicts" (rat-kingdom-plan--bool (not (string-empty-p verdicts)))
     "comments" (vconcat
                 (mapcar (lambda (comment)
                           (rat-kingdom-plan--obj
                            "heading" (format "**%s** · %s%s"
                                              (or (plist-get comment :author) "?")
                                              (rat-kingdom-issue--date
                                               (plist-get comment :created_at))
                                              (if-let* ((ago (rat-kingdom-issue--ago
                                                              (plist-get comment
                                                                         :created_at))))
                                                  (format " (%s ago)" ago)
                                                ""))
                            "text" (rat-kingdom-issue--prose
                                    (plist-get comment :text))))
                         (rat-kingdom-issue--oldest-first
                          (plist-get issue :comments)))))))

(defun rat-kingdom-issue--oldest-first (comments)
  "Return COMMENTS sorted by their creation time, oldest first.
Comments made at the same time keep their order."
  (cl-stable-sort (copy-sequence comments) #'<
                  :key (lambda (comment)
                         (or (rat-kingdom-issue--time
                              (plist-get comment :created_at))
                             0))))

(defun rat-kingdom-issue--message (type &rest pairs)
  "Return the A2UI message TYPE for the inspector, with the fields PAIRS."
  (rat-kingdom-plan--obj
   "version" "v0.9"
   type (apply #'rat-kingdom-plan--obj
               "surfaceId" rat-kingdom-issue-surface-id pairs)))

(defun rat-kingdom-issue-update (path value)
  "Return the updateDataModel message setting PATH to VALUE."
  (rat-kingdom-issue--message "updateDataModel" "path" path "value" value))

(defun rat-kingdom-issue-summary (model)
  "Return a one-line summary of what the inspector shows of MODEL."
  (let* ((issue (plist-get model :issue))
         (links (plist-get model :links))
         (count (lambda (relation)
                  (cl-count relation links :key #'car :test #'equal))))
    (format "Shown to the user: the issue %s of %s (%s, %s, P%s): %s. \
%d blockers, %d issues it blocks, %d stories, %d comments."
            (plist-get model :id) (plist-get model :repo)
            (or (plist-get issue :issue_type) "issue")
            (or (plist-get issue :status) "unknown status")
            (or (plist-get issue :priority) "?")
            (or (plist-get issue :title) "")
            (funcall count "blocked by") (funcall count "blocks")
            (length (plist-get model :stories))
            (length (plist-get issue :comments)))))

;;;; a2ui

(defun rat-kingdom-issue--require-a2ui ()
  "Signal an error saying a2ui is missing, unless it can be loaded."
  (unless (rat-kingdom-plan-a2ui-p)
    (error "The issue inspector needs a2ui (https://github.com/chazu/a2ui.el), \
which is not installed or cannot be loaded")))

(defun rat-kingdom-issue--a2ui-session ()
  "Return the a2ui session of the inspector, making it if needed."
  (or rat-kingdom-issue--session
      (let ((session (a2ui-session-create
                      :name "rat-kingdom"
                      :catalogs '(basic emacs)
                      :send-action-fn (lambda (message _metadata)
                                        (rat-kingdom-issue--receive message))
                      :on-change-fn (lambda (surface-id)
                                      (rat-kingdom-issue--changed surface-id)))))
        (a2ui-vui-attach session)
        (setq rat-kingdom-issue--session session))))

(defun rat-kingdom-issue--surface ()
  "Return the inspector's a2ui surface, or nil if it is not shown."
  (and rat-kingdom-issue--session
       (a2ui-session-surface rat-kingdom-issue--session
                             rat-kingdom-issue-surface-id)))

(defun rat-kingdom-issue--live-p ()
  "Return non-nil if the inspector is shown by a2ui."
  (and (rat-kingdom-issue--surface) t))

(defun rat-kingdom-issue--send (message)
  "Apply MESSAGE, an A2UI message, to the inspector's session."
  (a2ui-apply-message (rat-kingdom-issue--a2ui-session) message))

(defun rat-kingdom-issue--read-collapsed ()
  "Return the Sections the user folded on the surface, as an alist.
Return nil if the surface is not shown or holds no fold state."
  (when-let* ((surface (rat-kingdom-issue--surface))
              (object (ignore-errors (a2ui-get surface "/collapsed")))
              ((hash-table-p object)))
    (cl-loop for (section . _) in rat-kingdom-issue-sections
             for value = (gethash (symbol-name section) object)
             collect (cons section (rat-kingdom-plan--true-p value)))))

(defun rat-kingdom-issue--usable-window-p (window)
  "Return non-nil if WINDOW may be given the inspector in place of its buffer."
  (and (window-live-p window)
       (not (window-minibuffer-p window))
       (not (window-dedicated-p window))
       (not (window-parameter window 'window-side))))

(defun rat-kingdom-issue--display-in-main-window (buffer alist)
  "Show BUFFER in the main frame's selected window, as ALIST says.
Return the window, or nil if that window cannot take it."
  (let* ((frame (selected-frame))
         (frame (or (frame-parameter frame 'parent-frame) frame))
         (window (frame-selected-window frame)))
    (when (rat-kingdom-issue--usable-window-p window)
      (window--display-buffer buffer window 'reuse alist))))

(defun rat-kingdom-issue--display ()
  "Show the inspector's surface in the main window and return its window."
  (let* ((a2ui-vui-display-action
          '((rat-kingdom-issue--display-in-main-window
             a2ui-vui-display-in-main-window)))
         (buffer (a2ui-show-surface (rat-kingdom-issue--a2ui-session)
                                    rat-kingdom-issue-surface-id)))
    (setq rat-kingdom-issue--buffer buffer)
    (with-current-buffer buffer
      (rat-kingdom-issue-mode 1))
    (get-buffer-window buffer t)))

;;;; Showing an issue

(defun rat-kingdom-issue-render (model)
  "Draw the inspector showing MODEL.  Return the messages sent.
The Sections folded on the surface stay folded."
  (when-let* ((folded (rat-kingdom-issue--read-collapsed)))
    (setq rat-kingdom-issue--collapsed folded))
  (let ((messages
         (list (rat-kingdom-issue--message
                "createSurface" "catalogId" (rat-kingdom-plan--catalog)
                "theme" (rat-kingdom-plan--obj "agentDisplayName" "rat-kingdom"))
               (rat-kingdom-issue--message
                "updateComponents"
                "components" (vconcat (rat-kingdom-issue-components model)))
               (rat-kingdom-issue-update
                "/" (rat-kingdom-issue-data model rat-kingdom-issue--collapsed)))))
    (dolist (message messages)
      (rat-kingdom-issue--send message))
    (setq rat-kingdom-issue--model model
          rat-kingdom-issue--last (funcall rat-kingdom-issue--now))
    messages))

(defun rat-kingdom-issue-show (space repo id &optional select)
  "Show the issue ID of the repository REPO in SPACE in the inspector.
SPACE is by default the space rat-kingdom works in.  It takes the place
of the buffer in the main window.  With SELECT, select its window.
Signal an error, and show nothing, if REPO or ID is unknown or a2ui
cannot be loaded.  Return what it shows, as `rat-kingdom-issue-gather'
gives it."
  (let* ((space (or space (rat-kingdom-space-default)))
         (model (rat-kingdom-issue-gather space repo id)))
    (rat-kingdom-issue--require-a2ui)
    (setq rat-kingdom-issue--space space
          rat-kingdom-issue--repo repo
          rat-kingdom-issue--id (plist-get model :id))
    (rat-kingdom-issue--cancel-timer)
    (rat-kingdom-issue-render model)
    (let ((window (rat-kingdom-issue--display)))
      (when (and select (window-live-p window))
        (select-window window)))
    model))

(defun rat-kingdom-issue--read-args ()
  "Read a repository and an issue of its tracker, with completion.
Return (REPO ID)."
  (let* ((space (rat-kingdom-space-default))
         (names (mapcar (lambda (record) (plist-get record :name))
                        (rat-kingdom-repo-list space)))
         (repo (if names
                   (completing-read "Repository: " names nil t nil nil
                                    (if (member rat-kingdom-issue--repo names)
                                        rat-kingdom-issue--repo
                                      (car names)))
                 (user-error "No repository is registered")))
         (issues (when-let* ((adapter (rat-kingdom-task-adapter space repo)))
                   (condition-case err
                       (rat-kingdom-issue-open-issues adapter)
                     (rat-kingdom-task-error
                      (message "rat-kingdom: the issues of %s: %s" repo
                               (error-message-string err))
                      nil))))
         (annotate (lambda (id)
                     (when-let* ((title (cdr (assoc id issues))))
                       (concat "  " title))))
         (id (completing-read
              "Issue: "
              (lambda (string predicate action)
                (if (eq action 'metadata)
                    `(metadata (annotation-function . ,annotate)
                               (category . rat-kingdom-issue))
                  (complete-with-action action (mapcar #'car issues)
                                        string predicate))))))
    (when (string-blank-p id)
      (user-error "Give an issue's id"))
    (list repo (string-trim id))))

;;;###autoload
(defun rat-kingdom-issue (repo id)
  "Show the issue ID of the repository REPO in the issue inspector.
Interactively, ask for both, with completion over the repositories and
over the issues of the tracker that are not closed.  The inspector
takes the place of the buffer in the selected window; \\`q' buries it
and \\`g' draws it again."
  (interactive (rat-kingdom-issue--read-args))
  (rat-kingdom-issue-show nil repo id t))

(defun rat-kingdom-issue-refresh ()
  "Draw the issue inspector again from the tracker and the space."
  (interactive)
  (if (and rat-kingdom-issue--space rat-kingdom-issue--repo rat-kingdom-issue--id)
      (rat-kingdom-issue-show rat-kingdom-issue--space rat-kingdom-issue--repo
                              rat-kingdom-issue--id)
    (call-interactively #'rat-kingdom-issue)))

(defvar-keymap rat-kingdom-issue-mode-map
  :doc "Keymap for `rat-kingdom-issue-mode'."
  "q" #'quit-window
  "g" #'rat-kingdom-issue-refresh)

(define-minor-mode rat-kingdom-issue-mode
  "Minor mode for the buffer of the issue inspector.
\\<rat-kingdom-issue-mode-map>\\[quit-window] buries it and \
\\[rat-kingdom-issue-refresh] draws it again."
  :lighter " Issue"
  :keymap rat-kingdom-issue-mode-map)

;;;; Keeping it up to date

(defun rat-kingdom-issue--story-ids ()
  "Return the ids of the stories the inspector shows."
  (mapcar (lambda (story) (plist-get story :id))
          (plist-get rat-kingdom-issue--model :stories)))

(defun rat-kingdom-issue--concerns-p (op subject)
  "Return non-nil if OP on SUBJECT may change what the inspector shows.
OP and SUBJECT are as for `rat-kingdom-space-change-functions'."
  (let ((ids (rat-kingdom-issue--story-ids)))
    (if (memq op '(sweep expire))
        (member (plist-get subject :owner) ids)
      (or (and (eq (plist-get subject :category) 'story)
               (or (member (plist-get subject :identity) ids)
                   (and (equal (plist-get subject :scope) rat-kingdom-issue--repo)
                        (equal (plist-get (plist-get subject :payload) :task)
                               rat-kingdom-issue--id))))
          (and (memq (plist-get subject :category) '(run verdict))
               (member (plist-get subject :owner) ids))))))

(defun rat-kingdom-issue--on-change (space op subject)
  "Schedule a redraw if OP on SUBJECT in SPACE changes the issue shown."
  (when (and rat-kingdom-issue--id (eq space rat-kingdom-issue--space)
             (rat-kingdom-issue--concerns-p op subject))
    (rat-kingdom-issue-mark)))

(add-hook 'rat-kingdom-space-change-functions #'rat-kingdom-issue--on-change)

(defun rat-kingdom-issue--on-settled (space story)
  "Schedule a redraw if the task of the token STORY in SPACE is the issue shown.
For `rat-kingdom-task-settled-functions': the issue was just closed or
released."
  (when (and rat-kingdom-issue--id (eq space rat-kingdom-issue--space)
             (equal (plist-get story :scope) rat-kingdom-issue--repo)
             (equal (plist-get (plist-get story :payload) :task)
                    rat-kingdom-issue--id))
    (rat-kingdom-issue-mark)))

(add-hook 'rat-kingdom-task-settled-functions #'rat-kingdom-issue--on-settled)

(defun rat-kingdom-issue-mark ()
  "Schedule a redraw of the inspector.
Redraws come at most every `rat-kingdom-issue-interval' seconds."
  (unless rat-kingdom-issue--timer
    (setq rat-kingdom-issue--timer
          (run-at-time (max 0 (- (+ rat-kingdom-issue--last
                                    rat-kingdom-issue-interval)
                                 (funcall rat-kingdom-issue--now)))
                       nil #'rat-kingdom-issue-flush))))

(defun rat-kingdom-issue--cancel-timer ()
  "Cancel the inspector's pending redraw, if any."
  (when (timerp rat-kingdom-issue--timer)
    (cancel-timer rat-kingdom-issue--timer))
  (setq rat-kingdom-issue--timer nil))

(defun rat-kingdom-issue-flush ()
  "Draw the inspector again, if it is shown.  Return the messages sent.
An error, such as the tracker failing, is shown on the surface."
  (rat-kingdom-issue--cancel-timer)
  (when (and rat-kingdom-issue--id rat-kingdom-issue--space
             (rat-kingdom-space-db rat-kingdom-issue--space)
             (rat-kingdom-issue--live-p))
    (condition-case err
        (rat-kingdom-issue-render
         (rat-kingdom-issue-gather rat-kingdom-issue--space
                                   rat-kingdom-issue--repo
                                   rat-kingdom-issue--id))
      (error
       (setq rat-kingdom-issue--last (funcall rat-kingdom-issue--now))
       (rat-kingdom-issue--result (format "**Error:** %s"
                                          (error-message-string err))
                                  "error")
       nil))))

(defun rat-kingdom-issue--stop ()
  "Stop following the space and forget the folds: the surface is gone."
  (rat-kingdom-issue--cancel-timer)
  (setq rat-kingdom-issue--space nil
        rat-kingdom-issue--repo nil
        rat-kingdom-issue--id nil
        rat-kingdom-issue--model nil
        rat-kingdom-issue--collapsed nil))

(defun rat-kingdom-issue--changed (surface-id)
  "Note that the surface SURFACE-ID changed.
Remember the folds the user made, or stop if the surface was deleted."
  (when (equal surface-id rat-kingdom-issue-surface-id)
    (if (rat-kingdom-issue--live-p)
        (when-let* ((folded (rat-kingdom-issue--read-collapsed)))
          (setq rat-kingdom-issue--collapsed folded))
      (when rat-kingdom-issue--id
        (rat-kingdom-issue--stop)))))

;;;; The buttons

(defun rat-kingdom-issue--result (text tone)
  "Show TEXT on the inspector, in TONE."
  (when (rat-kingdom-issue--live-p)
    (rat-kingdom-issue--send (rat-kingdom-issue-update "/result" text))
    (rat-kingdom-issue--send (rat-kingdom-issue-update "/resultTone" tone))
    (rat-kingdom-issue--send (rat-kingdom-issue-update "/hasResult" t))))

(defun rat-kingdom-issue-open (id)
  "Show the issue ID, of the repository shown, in the inspector."
  (rat-kingdom-issue-show rat-kingdom-issue--space rat-kingdom-issue--repo id))

(defun rat-kingdom-issue-open-parent (id)
  "Show the parent epic ID of the issue shown.
`rat-kingdom-issue-open-epic-function' shows it if it is set and can;
otherwise the inspector does."
  (unless (and rat-kingdom-issue-open-epic-function
               (funcall rat-kingdom-issue-open-epic-function
                        rat-kingdom-issue--space rat-kingdom-issue--repo id))
    (rat-kingdom-issue-open id)))

(defun rat-kingdom-issue-close ()
  "Delete the inspector's surface and bury or kill its buffer."
  (let ((buffer rat-kingdom-issue--buffer))
    (when (rat-kingdom-issue--live-p)
      (a2ui-delete-surface rat-kingdom-issue--session
                           rat-kingdom-issue-surface-id))
    (rat-kingdom-issue--stop)
    (when (buffer-live-p buffer)
      (if-let* ((window (get-buffer-window buffer t)))
          (quit-window t window)
        (kill-buffer buffer)))
    (setq rat-kingdom-issue--buffer nil)))

(defun rat-kingdom-issue-handle (name context)
  "Handle the button NAME pressed on the inspector, with CONTEXT."
  (let ((id (rat-kingdom-plan--text (rat-kingdom-plan--get context "id"))))
    (pcase name
      ("open" (when id (rat-kingdom-issue-open id)))
      ("parent" (when id (rat-kingdom-issue-open-parent id)))
      ("refresh" (rat-kingdom-issue-refresh))
      ("close" (rat-kingdom-issue-close)))))

(defun rat-kingdom-issue--receive (message)
  "Act on MESSAGE, which the inspector sent."
  (cond
   ((gethash "action" message)
    (let* ((action (gethash "action" message))
           (name (gethash "name" action))
           (context (gethash "context" action)))
      (funcall rat-kingdom-issue--defer
               (lambda ()
                 (condition-case err
                     (rat-kingdom-issue-handle name context)
                   (error
                    (rat-kingdom-issue--result
                     (format "**Error:** %s" (error-message-string err))
                     "error")
                    (message "rat-kingdom: the issue inspector: %s"
                             (error-message-string err))))))))
   ((gethash "error" message)
    (let ((err (gethash "error" message)))
      (message "rat-kingdom: the issue inspector reports %s: %s"
               (gethash "code" err) (gethash "message" err))))))

;;;; The king's tool

(rat-kingdom-king--deftool "issue_show"
    "Show the user one tracker issue in full in Emacs, in the issue \
inspector: its header (id, priority, type, status, age, parent epic, \
labels, assignee), title, description, acceptance checklist, design, \
notes, dependencies, the stories that worked on it and its comments. It \
takes the place of the buffer in the user's main window, and changes \
nothing. Use it when the user asks to see an issue, or when an issue is \
being discussed."
    '((:name "repo" :type string
             :description "The repository the issue belongs to.")
      (:name "id" :type string
             :description "The issue's id in the repository's tracker."))
  (let ((repo (or (arg 'repo) (error "Give the repository, repo")))
        (id (or (arg 'id) (error "Give the issue's id, id"))))
    (unless (rat-kingdom-repo-get space repo)
      (error "There is no repository called %s.  Nothing was shown" repo))
    (let ((model (condition-case err
                     (rat-kingdom-issue-gather space repo id)
                   (error (error "%s.  Nothing was shown"
                                 (error-message-string err))))))
      (unless (rat-kingdom-plan-a2ui-p)
        (error "The issue inspector is not available: a2ui is not installed \
or cannot be loaded in the user's Emacs.  Nothing was shown.  Tell the user \
about the issue in text instead"))
      (rat-kingdom-issue-show space repo id)
      (rat-kingdom-issue-summary model))))

(provide 'rat-kingdom-issue)
;;; rat-kingdom-issue.el ends here
