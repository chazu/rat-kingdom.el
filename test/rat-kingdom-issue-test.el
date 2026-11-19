;;; rat-kingdom-issue-test.el --- Tests for the issue inspector -*- lexical-binding: t; -*-

;;; Commentary:

;; Batch tests for the issue inspector.  Most run without a2ui: the
;; issues come from a stub task adapter, the inspector is built as
;; data, the calls into a2ui are stubbed, and the tests press the
;; buttons by handing the handler the message a2ui would send.  The
;; br methods are tested with the fake br of rat-kingdom-task-test.el.
;; The last tests draw the inspector with the real a2ui, where it can
;; be loaded; see rat-kingdom-plan-test.el for RAT_KINGDOM_TEST_A2UI.

;;; Code:

(require 'ert)
(require 'rat-kingdom-test-helper)
(require 'rat-kingdom)
(require 'rat-kingdom-issue)
(require 'rat-kingdom-story-test)
(require 'rat-kingdom-task-test)
(require 'rat-kingdom-reload-test)
(require 'rat-kingdom-plan-test)

;;;; A stub tracker

(cl-defstruct (rat-kingdom-issue-test-adapter
               (:constructor rat-kingdom-issue-test-adapter--create)
               (:copier nil))
  "A tracker held in memory: its issues, by id."
  (issues nil)
  (fails nil))

(cl-defmethod rat-kingdom-issue-read ((adapter rat-kingdom-issue-test-adapter) id)
  "Return the issue ID of the stub ADAPTER."
  (when (rat-kingdom-issue-test-adapter-fails adapter)
    (signal 'rat-kingdom-task-error (list "br show: the database is locked")))
  (or (cdr (assoc id (rat-kingdom-issue-test-adapter-issues adapter)))
      (signal 'rat-kingdom-issue-unknown (list id))))

(cl-defmethod rat-kingdom-issue-open-issues ((adapter rat-kingdom-issue-test-adapter))
  "Return the issues of the stub ADAPTER that are not closed."
  (cl-loop for (id . issue) in (rat-kingdom-issue-test-adapter-issues adapter)
           unless (equal (plist-get issue :status) "closed")
           collect (cons id (plist-get issue :title))))

(defconst rat-kingdom-issue-test--full
  (list :id "demo-1.1" :title "Inspect one issue in full"
        :description "Show everything.\n\n## Steps\n\n- [ ] draw it\n- [x] plan it\n\nThe end."
        :design "Use a2ui Sections."
        :acceptance_criteria "- [ ] tests pass\nAnd the docs say so."
        :notes "Ask the king."
        :status "open" :priority 1 :issue_type "task"
        :assignee "bob" :owner "alice" :labels '("ui" "a2ui")
        :created_at "2026-11-16T12:00:00Z" :created_by "chazu"
        :updated_at "2026-11-19T10:00:00Z"
        :defer_until "2027-01-01T14:00:00Z"
        :parent "demo-1"
        :dependencies '((:id "demo-2" :title "The base" :status "closed"
                             :dependency_type "blocks")
                        (:id "demo-1" :title "The epic" :status "open"
                             :dependency_type "parent-child"))
        :dependents '((:id "demo-3" :title "Built on it" :status "open"
                           :dependency_type "blocks"))
        :comments '((:id 2 :author "bob" :text "second\nwith two lines"
                         :created_at "2026-11-18T09:00:00Z")
                    (:id 1 :author "chazu" :text "first"
                         :created_at "2026-11-17T09:00:00Z")))
  "An issue with every field br keeps.")

(defconst rat-kingdom-issue-test--issues
  (list (cons "demo-1.1" rat-kingdom-issue-test--full)
        (cons "demo-1" (list :id "demo-1" :title "The epic" :status "open"
                             :priority 2 :issue_type "epic"
                             :created_at "2026-11-15T12:00:00Z"
                             :updated_at "2026-11-15T12:00:00Z"
                             :dependents '((:id "demo-1.1"
                                                :title "Inspect one issue in full"
                                                :status "open"
                                                :dependency_type "parent-child"))))
        (cons "demo-2" (list :id "demo-2" :title "The base" :status "closed"
                             :priority 2 :issue_type "task"
                             :close_reason "Merged into rk/integration at abc1234"
                             :closed_at "2026-11-17T12:00:00Z"))
        (cons "demo-3" (list :id "demo-3" :title "Built on it" :status "open"
                             :priority 3 :issue_type "task"))
        (cons "demo-4" (list :id "demo-4" :title "A bare issue" :status "open"
                             :priority 2 :issue_type "bug"
                             :description "Just this."
                             :created_at "2026-11-19T11:00:00Z"
                             :updated_at "2026-11-19T11:00:00Z")))
  "The stub tracker's issues.")

(defvar rat-kingdom-issue-test--adapter nil
  "The stub adapter in use.")

(defvar rat-kingdom-issue-test--sent nil
  "The A2UI messages sent to the stubbed a2ui, newest first.")

(defvar rat-kingdom-issue-test--folded nil
  "What the stubbed surface says is folded, as an alist, or nil.")

(defconst rat-kingdom-issue-test--now
  (float-time (encode-time (iso8601-parse "2026-11-19T12:00:00Z")))
  "The time the tests run at.")

(defmacro rat-kingdom-issue-test-with-stubs (vars &rest body)
  "Run BODY with VARS, (SPACE PATH), a fresh repository and a stubbed a2ui.
The repository \"demo\" has the stub tracker, the inspector's state is
fresh, it follows the space, and what it sends to a2ui is recorded in
`rat-kingdom-issue-test--sent'.  It counts as shown once it was drawn."
  (declare (indent 1) (debug t))
  `(rat-kingdom-story-test-with-repo ,vars
     (let* ((rat-kingdom-issue-test--adapter
             (rat-kingdom-issue-test-adapter--create
              :issues (copy-tree rat-kingdom-issue-test--issues)))
            (rat-kingdom-task-adapter-function
             (lambda (_record) rat-kingdom-issue-test--adapter))
            (rat-kingdom-space-now-function
             (lambda () (or rat-kingdom-story-test--now
                            rat-kingdom-issue-test--now)))
            (rat-kingdom-space-change-functions
             (list #'rat-kingdom-issue--on-change))
            (rat-kingdom-issue--session nil)
            (rat-kingdom-issue--space nil)
            (rat-kingdom-issue--repo nil)
            (rat-kingdom-issue--id nil)
            (rat-kingdom-issue--model nil)
            (rat-kingdom-issue--collapsed nil)
            (rat-kingdom-issue--buffer nil)
            (rat-kingdom-issue--timer nil)
            (rat-kingdom-issue--last 0)
            (rat-kingdom-issue--defer #'funcall)
            (rat-kingdom-issue-open-epic-function nil)
            (rat-kingdom-issue-test--sent nil)
            (rat-kingdom-issue-test--folded nil))
       (cl-letf (((symbol-function 'rat-kingdom-plan-a2ui-p) (lambda () t))
                 ((symbol-function 'rat-kingdom-issue--send)
                  (lambda (message)
                    (push message rat-kingdom-issue-test--sent)))
                 ((symbol-function 'rat-kingdom-issue--live-p)
                  (lambda () (and rat-kingdom-issue--id t)))
                 ((symbol-function 'rat-kingdom-issue--read-collapsed)
                  (lambda () rat-kingdom-issue-test--folded))
                 ((symbol-function 'rat-kingdom-issue--display) #'ignore))
         (unwind-protect
             (progn ,@body)
           (rat-kingdom-issue--cancel-timer))))))

(defun rat-kingdom-issue-test--updates ()
  "Return the updateDataModel messages sent, oldest first, as (PATH . VALUE)."
  (cl-loop for message in (reverse rat-kingdom-issue-test--sent)
           for (type . body) = (rat-kingdom-plan-test--body message)
           when (equal type "updateDataModel")
           collect (cons (gethash "path" body) (gethash "value" body))))

(defun rat-kingdom-issue-test--data ()
  "Return the data model last sent whole."
  (cdr (cl-find "/" (reverse (rat-kingdom-issue-test--updates))
                :key #'car :test #'equal)))

(defun rat-kingdom-issue-test--components ()
  "Return the components last sent, by id."
  (let ((message (cl-find-if (lambda (message)
                               (equal (car (rat-kingdom-plan-test--body message))
                                      "updateComponents"))
                             rat-kingdom-issue-test--sent))
        (components (make-hash-table :test #'equal)))
    (seq-doseq (component (gethash "components"
                                   (cdr (rat-kingdom-plan-test--body message))))
      (puthash (gethash "id" component) component components))
    components))

(defun rat-kingdom-issue-test--sections ()
  "Return the Sections last sent, in order, as symbols."
  (cl-loop for id across (gethash "children"
                                  (gethash "root"
                                           (rat-kingdom-issue-test--components)))
           when (string-prefix-p "section-" id)
           collect (intern (string-remove-prefix "section-" id))))

(defun rat-kingdom-issue-test--title (section)
  "Return the heading last sent for SECTION, a symbol."
  (gethash "title" (gethash (format "section-%s" section)
                            (rat-kingdom-issue-test--components))))

(defun rat-kingdom-issue-test--press (name &optional id)
  "Press the button NAME of the inspector, with ID as its context, as a2ui does."
  (rat-kingdom-issue--receive
   (rat-kingdom-plan--obj
    "version" "v0.9"
    "action" (rat-kingdom-plan--obj
              "name" name "surfaceId" rat-kingdom-issue-surface-id
              "context" (if id (rat-kingdom-plan--obj "id" id)
                          (rat-kingdom-plan--obj))))))

(defun rat-kingdom-issue-test--call (repo id)
  "Call `issue_show' as the king with REPO and ID.  Return (TEXT . FAILED)."
  (rat-kingdom-mcp-call '(:run "king" :role king) "issue_show"
                        `((repo . ,repo) (id . ,id))))

(defun rat-kingdom-issue-test--stories (space)
  "Put two stories for demo-1.1 in SPACE: S-old, merged, and S-new, live.
S-old had two workers and a verdict of fix, then one of pass."
  (rat-kingdom-space-out space 'story :scope "demo" :identity "S-old"
                         :owner "S-old"
                         :payload (list :workflow "story" :at "done"
                                        :phase "done" :task "demo-1.1"
                                        :title "First go" :attempt 2
                                        :integrated "0123456789abcdef"))
  (dolist (run '("S-old.1" "S-old.2"))
    (rat-kingdom-space-out space 'run :scope "demo" :identity run :owner "S-old"
                           :payload (list :state "done" :role "rat")))
  (dolist (verdict '(("fix" . "Draw the comments too.") ("pass" . nil)))
    (rat-kingdom-space-out space 'verdict :scope "demo" :identity "S-old"
                           :owner "S-old"
                           :payload (list :value (car verdict)
                                          :notes (cdr verdict))
                           :actor "king")
    (rat-kingdom-space-in space '(verdict :identity "S-old") :actor "engine"))
  (rat-kingdom-space-sweep space "S-old")
  (rat-kingdom-space-out space 'story :scope "demo" :identity "S-new"
                         :owner "S-new"
                         :payload (list :workflow "story-lite" :at "ready"
                                        :phase "wait" :awaiting "worker"
                                        :step "implement"
                                        :task "demo-1.1" :title "Again"
                                        :attempt 1))
  (rat-kingdom-space-out space 'run :scope "demo" :identity "S-new.1"
                         :owner "S-new"
                         :payload (list :state "running" :role "rat"))
  ;; Neither a story of another task nor a child story is one of its.
  (rat-kingdom-space-out space 'story :scope "demo" :identity "S-other"
                         :owner "S-other"
                         :payload (list :workflow "story" :at "ready"
                                        :phase "enter" :task "demo-3"))
  (rat-kingdom-space-out space 'story :scope "demo" :identity "S-new/check"
                         :owner "S-new/check"
                         :payload (list :workflow "story" :at "ready"
                                        :phase "enter" :parent "S-new"
                                        :config-task "demo-1.1")))

;;;; Parsing

(ert-deftest rat-kingdom-issue-test-checklist ()
  (should (equal (rat-kingdom-issue-checklist
                  "Intro\n- [ ] one\n  * [x] two  \n+ [X] three\n- [] not\n-[ ] not\n- [ ]\nText - [ ] not"
                  nil
                  "- [ ] four")
                 '((nil . "one") (t . "two") (t . "three") (nil . "four"))))
  (should-not (rat-kingdom-issue-checklist "No list here." nil)))

(ert-deftest rat-kingdom-issue-test-age-and-header ()
  (should (equal (rat-kingdom-issue-age-text 45) "45s"))
  (should (equal (rat-kingdom-issue-age-text 3900) "1h 5m"))
  (should (equal (rat-kingdom-issue-age-text (* 3 86400)) "3d"))
  (let ((rat-kingdom-space-now-function (lambda () rat-kingdom-issue-test--now)))
    (should (equal (rat-kingdom-issue-header rat-kingdom-issue-test--full)
                   "**demo-1.1** · P1 · task · open · 3d old · updated 2h ago · \
epic demo-1 · labels ui, a2ui · assignee bob"))
    (let ((details (rat-kingdom-issue-details rat-kingdom-issue-test--full)))
      (should (string-search "created by chazu" details))
      (should (string-search "owner alice" details))
      (should (string-search "deferred until 2027-01-0" details)))
    (should (string-search "close reason: Merged into rk/integration"
                           (rat-kingdom-issue-details
                            (cdr (assoc "demo-2" rat-kingdom-issue-test--issues)))))
    (should (equal (rat-kingdom-issue-details '(:id "x")) ""))))

;;;; Showing an issue

(ert-deftest rat-kingdom-issue-test-full-issue ()
  (rat-kingdom-issue-test-with-stubs (space path)
    (rat-kingdom-issue-test--stories space)
    (let ((model (rat-kingdom-issue-show space "demo" "demo-1.1")))
      (should (equal (plist-get model :id) "demo-1.1")))
    (should (equal rat-kingdom-issue--id "demo-1.1"))
    (should (equal (rat-kingdom-issue-test--sections)
                   '(description acceptance design notes dependencies
                                 stories comments)))
    (should (equal (rat-kingdom-issue-test--title 'acceptance)
                   "Acceptance (1/3 done)"))
    (should (equal (rat-kingdom-issue-test--title 'dependencies)
                   "Dependencies (2)"))
    (should (equal (rat-kingdom-issue-test--title 'stories) "Stories (2)"))
    (should (equal (rat-kingdom-issue-test--title 'comments) "Comments (2)"))
    ;; Every Section folds by the data model, and starts unfolded.
    (let ((section (gethash "section-design" (rat-kingdom-issue-test--components))))
      (should (equal (gethash "path" (gethash "collapsed" section))
                     "/collapsed/design")))
    (let ((data (rat-kingdom-issue-test--data)))
      (should (string-prefix-p "**demo-1.1** · P1 · task · open"
                               (gethash "header" data)))
      (should (equal (gethash "title" data) "Inspect one issue in full"))
      (should (eq (gethash "hasParent" data) t))
      (should (equal (gethash "parent" data) "demo-1"))
      ;; The description is all there, line for line; a blank line
      ;; holds a space, so that a2ui keeps it.
      (should (equal (gethash "description" data)
                     "Show everything.\n \n## Steps\n \n- [ ] draw it\n- [x] plan it\n \nThe end."))
      (should (equal (gethash "acceptance" data)
                     "- [ ] tests pass\nAnd the docs say so."))
      (should (equal (mapcar (lambda (row) (list (gethash "mark" row)
                                                 (gethash "item" row)))
                             (gethash "checklist" data))
                     '(("[ ]" "draw it") ("[x]" "plan it") ("[ ]" "tests pass"))))
      (should (equal (gethash "design" data) "Use a2ui Sections."))
      (should (equal (gethash "notes" data) "Ask the king."))
      (should (equal (mapcar (lambda (link) (gethash "line" link))
                             (gethash "links" data))
                     '("blocked by · closed · The base"
                       "blocks · open · Built on it")))
      (maphash (lambda (section folded)
                 (should (eq folded :false))
                 (should (assq (intern section) rat-kingdom-issue-sections)))
               (gethash "collapsed" data))
      ;; Comments, oldest first, in full.
      (let ((comments (append (gethash "comments" data) nil)))
        (should (equal (mapcar (lambda (c) (gethash "text" c)) comments)
                       '("first" "second\nwith two lines")))
        (should (string-prefix-p "**chazu** · 2026-11-17"
                                 (gethash "heading" (car comments))))
        (should (string-search "(2d ago)" (gethash "heading" (car comments)))))
      ;; The stories: the archived one first, then the live one.
      (let ((stories (append (gethash "stories" data) nil)))
        (should (equal (mapcar (lambda (s) (gethash "id" s)) stories)
                       '("S-old" "S-new")))
        (should (equal (gethash "workers" (car stories)) "S-old.1, S-old.2"))
        (should (equal (gethash "outcome" (car stories)) "merged"))
        (should (equal (gethash "rounds" (car stories)) "1"))
        (should (equal (gethash "merge" (car stories)) "0123456"))
        (should (equal (gethash "workflow" (car stories)) "story"))
        (should (equal (gethash "outcome" (cadr stories))
                       "at ready, waiting for worker"))
        (should (equal (gethash "rounds" (cadr stories)) "0"))
        (should (equal (gethash "merge" (cadr stories)) "")))
      (should (equal (gethash "verdicts" data)
                     "- **S-old** fix by king: Draw the comments too.\n\
- **S-old** pass by king")))))

(ert-deftest rat-kingdom-issue-test-bare-issue ()
  (rat-kingdom-issue-test-with-stubs (space path)
    (rat-kingdom-issue-show space "demo" "demo-4")
    ;; No checklist, design, notes, dependencies or comments: those
    ;; Sections are left out.
    (should (equal (rat-kingdom-issue-test--sections) '(description stories)))
    (let ((components (rat-kingdom-issue-test--components))
          (data (rat-kingdom-issue-test--data)))
      (should-not (gethash "link" components))
      (should-not (gethash "comments-body" components))
      (should (equal (gethash "text" (gethash "stories-body" components))
                     "No story has worked on this issue."))
      (should (eq (gethash "hasParent" data) :false))
      (should (equal (gethash "description" data) "Just this.")))))

(ert-deftest rat-kingdom-issue-test-dependency-buttons ()
  (rat-kingdom-issue-test-with-stubs (space path)
    (rat-kingdom-issue-show space "demo" "demo-1.1")
    (let* ((components (rat-kingdom-issue-test--components))
           (button (gethash "link-open" components))
           (event (gethash "event" (gethash "action" button))))
      (should (equal (gethash "component" button) "Button"))
      (should (equal (gethash "name" event) "open"))
      (should (equal (gethash "path" (gethash "id" (gethash "context" event)))
                     "id"))
      (should (equal (gethash "path" (gethash "children"
                                              (gethash "dependencies-body"
                                                       components)))
                     "/links")))
    (should (equal (mapcar (lambda (link) (gethash "id" link))
                           (gethash "links" (rat-kingdom-issue-test--data)))
                   '("demo-2" "demo-3")))
    ;; Pressing one inspects that issue.
    (rat-kingdom-issue-test--press "open" "demo-3")
    (should (equal rat-kingdom-issue--id "demo-3"))
    (should (equal (gethash "title" (rat-kingdom-issue-test--data)) "Built on it"))
    ;; demo-3 is blocked by nothing it knows of, and has no parent.
    (should (equal (rat-kingdom-issue-test--sections) '(description stories)))
    ;; The epic lists its children.
    (rat-kingdom-issue-test--press "open" "demo-1")
    (should (equal (mapcar (lambda (link) (gethash "line" link))
                           (gethash "links" (rat-kingdom-issue-test--data)))
                   '("child · open · Inspect one issue in full")))))

(ert-deftest rat-kingdom-issue-test-parent-refresh-close ()
  (rat-kingdom-issue-test-with-stubs (space path)
    (rat-kingdom-issue-show space "demo" "demo-1.1")
    (let ((event (gethash "event" (gethash "action"
                                           (gethash "button-parent"
                                                    (rat-kingdom-issue-test--components))))))
      (should (equal (gethash "name" event) "parent"))
      (should (equal (gethash "path" (gethash "id" (gethash "context" event)))
                     "/parent")))
    (rat-kingdom-issue-test--press "parent" "demo-1")
    (should (equal rat-kingdom-issue--id "demo-1"))
    ;; A surface for epics takes over when there is one.
    (let* ((asked nil)
           (rat-kingdom-issue-open-epic-function
            (lambda (_space repo epic) (push (list repo epic) asked) t)))
      (rat-kingdom-issue-show space "demo" "demo-1.1")
      (rat-kingdom-issue-test--press "parent" "demo-1")
      (should (equal asked '(("demo" "demo-1"))))
      (should (equal rat-kingdom-issue--id "demo-1.1")))
    ;; Refresh reads the tracker again.
    (setf (alist-get "demo-1.1"
                     (rat-kingdom-issue-test-adapter-issues
                      rat-kingdom-issue-test--adapter)
                     nil nil #'equal)
          (append (list :title "Renamed") rat-kingdom-issue-test--full))
    (setq rat-kingdom-issue-test--sent nil)
    (rat-kingdom-issue-test--press "refresh")
    (should (equal (gethash "title" (rat-kingdom-issue-test--data)) "Renamed"))
    ;; No button changes the tracker or starts a story.
    (should-not (rat-kingdom-story-list space))
    ;; Close stops following and forgets the folds.
    (setq rat-kingdom-issue--collapsed '((notes . t)))
    (cl-letf (((symbol-function 'rat-kingdom-issue--live-p) #'ignore))
      (rat-kingdom-issue-test--press "close"))
    (should-not rat-kingdom-issue--id)
    (should-not rat-kingdom-issue--space)
    (should-not rat-kingdom-issue--collapsed)))

(ert-deftest rat-kingdom-issue-test-folds-are-kept ()
  (rat-kingdom-issue-test-with-stubs (space path)
    (rat-kingdom-issue-show space "demo" "demo-1.1")
    ;; The user folds Description and Comments.
    (setq rat-kingdom-issue-test--folded '((description . t) (comments . t)))
    (rat-kingdom-issue--changed rat-kingdom-issue-surface-id)
    (should (equal rat-kingdom-issue--collapsed
                   '((description . t) (comments . t))))
    (setq rat-kingdom-issue-test--folded nil)
    (rat-kingdom-issue-refresh)
    (let ((folds (gethash "collapsed" (rat-kingdom-issue-test--data))))
      (should (eq (gethash "description" folds) t))
      (should (eq (gethash "comments" folds) t))
      (should (eq (gethash "notes" folds) :false)))
    ;; They stay folded for the next issue shown.
    (rat-kingdom-issue-test--press "open" "demo-4")
    (should (eq (gethash "description"
                         (gethash "collapsed" (rat-kingdom-issue-test--data)))
                t))))

;;;; Following the space

(ert-deftest rat-kingdom-issue-test-follows-its-stories ()
  (rat-kingdom-issue-test-with-stubs (space path)
    (rat-kingdom-issue-show space "demo" "demo-1.1")
    (should (equal (rat-kingdom-issue-test--title 'stories) "Stories (0)"))
    ;; Another task's story does not concern it.
    (rat-kingdom-space-out space 'story :scope "demo" :identity "S-x"
                           :owner "S-x"
                           :payload (list :workflow "story" :at "ready"
                                          :phase "enter" :task "demo-3"))
    (should-not rat-kingdom-issue--timer)
    ;; A story started for it does.
    (rat-kingdom-space-out space 'story :scope "demo" :identity "S-1"
                           :owner "S-1"
                           :payload (list :workflow "story" :at "ready"
                                          :phase "enter" :task "demo-1.1"
                                          :attempt 0))
    (should (timerp rat-kingdom-issue--timer))
    (setq rat-kingdom-issue-test--sent nil)
    (rat-kingdom-issue-flush)
    (should-not rat-kingdom-issue--timer)
    (should (equal (rat-kingdom-issue-test--title 'stories) "Stories (1)"))
    ;; So does a change to that story's run, or its end.
    (rat-kingdom-space-out space 'run :scope "demo" :identity "S-1.1"
                           :owner "S-1" :payload (list :state "running"
                                                       :role "rat"))
    (should (timerp rat-kingdom-issue--timer))
    (rat-kingdom-issue-flush)
    (should (equal (gethash "workers"
                            (aref (gethash "stories"
                                           (rat-kingdom-issue-test--data))
                                  0))
                   "S-1.1"))
    (rat-kingdom-space-sweep space "S-1")
    (should (timerp rat-kingdom-issue--timer))
    (rat-kingdom-issue-flush)
    ;; And so does its task being settled.
    (rat-kingdom-issue--on-settled
     space (list :scope "demo" :identity "S-1" :payload '(:task "demo-1.1")))
    (should (timerp rat-kingdom-issue--timer))
    (rat-kingdom-issue--cancel-timer)
    (rat-kingdom-issue--on-settled
     space (list :scope "demo" :identity "S-x" :payload '(:task "demo-3")))
    (should-not rat-kingdom-issue--timer)))

(ert-deftest rat-kingdom-issue-test-tracker-failure-is-shown ()
  (rat-kingdom-issue-test-with-stubs (space path)
    (rat-kingdom-issue-show space "demo" "demo-1.1")
    (setf (rat-kingdom-issue-test-adapter-fails rat-kingdom-issue-test--adapter) t)
    (setq rat-kingdom-issue-test--sent nil)
    (rat-kingdom-issue-flush)
    (let ((updates (rat-kingdom-issue-test--updates)))
      (should (string-search "database is locked" (cdr (assoc "/result" updates))))
      (should (equal (cdr (assoc "/resultTone" updates)) "error")))))

;;;; The king's tool and the command

(ert-deftest rat-kingdom-issue-test-tool ()
  (rat-kingdom-issue-test-with-stubs (space path)
    (rat-kingdom-issue-test--stories space)
    (let ((answer (rat-kingdom-issue-test--call "demo" "demo-1.1")))
      (should-not (cdr answer))
      (should (equal (car answer)
                     "Shown to the user: the issue demo-1.1 of demo (task, open, \
P1): Inspect one issue in full. 1 blockers, 1 issues it blocks, 2 stories, \
2 comments."))
      (should-not (string-search "\n" (car answer))))
    (should (equal rat-kingdom-issue--id "demo-1.1"))))

(ert-deftest rat-kingdom-issue-test-tool-errors ()
  (rat-kingdom-issue-test-with-stubs (space path)
    (cl-flet ((fails (repo id expected)
                (setq rat-kingdom-issue-test--sent nil)
                (let ((answer (rat-kingdom-issue-test--call repo id)))
                  (should (cdr answer))
                  (should (string-search expected (car answer)))
                  (should (string-search "Nothing was shown" (car answer))))
                ;; Nothing was shown.
                (should-not rat-kingdom-issue-test--sent)
                (should-not rat-kingdom-issue--id)))
      (fails "nowhere" "demo-1.1" "There is no repository called nowhere")
      (fails "demo" "demo-99" "The tracker of demo has no issue demo-99")
      (cl-letf (((symbol-function 'rat-kingdom-plan-a2ui-p) #'ignore))
        (fails "demo" "demo-1.1" "a2ui is not installed"))
      (setf (rat-kingdom-issue-test-adapter-fails rat-kingdom-issue-test--adapter) t)
      (fails "demo" "demo-1.1" "database is locked"))
    ;; The command says the same, and shows nothing.
    (setf (rat-kingdom-issue-test-adapter-fails rat-kingdom-issue-test--adapter) nil)
    (should-error (rat-kingdom-issue "demo" "demo-99"))
    (cl-letf (((symbol-function 'rat-kingdom-plan-a2ui-p) #'ignore))
      (should (string-search "needs a2ui"
                             (cadr (should-error (rat-kingdom-issue "demo"
                                                                    "demo-1.1"))))))
    (should-not rat-kingdom-issue-test--sent)))

(ert-deftest rat-kingdom-issue-test-command-completes-open-issues ()
  (rat-kingdom-issue-test-with-stubs (space path)
    (let (offered annotation)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (prompt collection &rest _)
                   (if (string-prefix-p "Repository" prompt)
                       "demo"
                     (setq offered (all-completions "" collection)
                           annotation (funcall
                                       (alist-get 'annotation-function
                                                  (cdr (funcall collection ""
                                                                nil 'metadata)))
                                       "demo-3"))
                     "demo-3"))))
        (call-interactively #'rat-kingdom-issue))
      (should (equal (sort offered #'string<)
                     '("demo-1" "demo-1.1" "demo-3" "demo-4")))
      (should (equal annotation "  Built on it"))
      (should (equal rat-kingdom-issue--id "demo-3")))))

;;;; br

(ert-deftest rat-kingdom-issue-test-br ()
  (rat-kingdom-task-test-with-fake adapter
    (rat-kingdom-task-test--answer
     (concat "[{\"id\":\"bd-1\",\"title\":\"One\",\"status\":\"open\","
             "\"design\":\"D\",\"acceptance_criteria\":\"- [ ] a\","
             "\"dependents\":[{\"id\":\"bd-2\",\"title\":\"Two\","
             "\"status\":\"open\",\"dependency_type\":\"blocks\"}],"
             "\"comments\":[{\"id\":1,\"author\":\"me\",\"text\":\"hi\","
             "\"created_at\":\"2026-11-19T13:29:53Z\"}]}]"))
    (let ((issue (rat-kingdom-issue-read adapter "bd-1")))
      (should (equal (rat-kingdom-task-test--args) '("show" "bd-1" "--json")))
      (should (equal (plist-get issue :design) "D"))
      (should (equal (plist-get (car (plist-get issue :comments)) :text) "hi"))
      (should (equal (rat-kingdom-issue--links issue)
                     '(("blocks" :id "bd-2" :title "Two" :status "open"
                        :dependency_type "blocks")))))
    ;; br says an issue is unknown with a message and exit status 3.
    (rat-kingdom-task-test--answer
     "{\"error\":{\"code\":\"ISSUE_NOT_FOUND\",\"message\":\"Issue not found: bd-9\"}}"
     3)
    (should-error (rat-kingdom-issue-read adapter "bd-9")
                  :type 'rat-kingdom-issue-unknown)
    (rat-kingdom-task-test--answer "" 1 "database is locked")
    (let ((err (should-error (rat-kingdom-issue-read adapter "bd-1")
                             :type 'rat-kingdom-task-error)))
      (should-not (eq (car err) 'rat-kingdom-issue-unknown)))
    ;; br list wraps the issues in an object.
    (rat-kingdom-task-test--answer
     "{\"issues\":[{\"id\":\"bd-1\",\"title\":\"One\"},{\"id\":\"bd-2\",\"title\":\"Two\"}]}")
    (should (equal (rat-kingdom-issue-open-issues adapter)
                   '(("bd-1" . "One") ("bd-2" . "Two"))))
    (should (equal (rat-kingdom-task-test--args) '("list" "--json")))
    (rat-kingdom-task-test--answer "[{\"id\":\"bd-3\",\"title\":\"Three\"}]")
    (should (equal (rat-kingdom-issue-open-issues adapter) '(("bd-3" . "Three"))))))

(ert-deftest rat-kingdom-issue-test-real-br ()
  (skip-unless (executable-find "br"))
  (let* ((directory (file-name-as-directory
                     (file-truename (make-temp-file "rat-kingdom-issue" t))))
         (rat-kingdom-task-br-program "br")
         (adapter (rat-kingdom-task-br (list :name "tt" :path directory))))
    (unwind-protect
        (progn
          (rat-kingdom-task-br--call directory "init" "--prefix" "tt")
          (let* ((epic (rat-kingdom-task-create adapter "Epic" :type "epic"))
                 (task (rat-kingdom-task-create adapter "Task"
                                                :description "- [x] done"
                                                :parent epic))
                 (other (rat-kingdom-task-create adapter "Other")))
            (rat-kingdom-task-depend adapter other task)
            (rat-kingdom-task-comment adapter task "A comment")
            (let ((issue (rat-kingdom-issue-read adapter task)))
              (should (equal (plist-get issue :parent) epic))
              (should (equal (plist-get (car (plist-get issue :comments)) :text)
                             "A comment"))
              (should (equal (mapcar #'car (rat-kingdom-issue--links issue))
                             '("blocks"))))
            (should (assoc task (rat-kingdom-issue-open-issues adapter)))
            (should-error (rat-kingdom-issue-read adapter "tt-nope")
                          :type 'rat-kingdom-issue-unknown)))
      (delete-directory directory t))))

;;;; Loading and reloading

(ert-deftest rat-kingdom-issue-test-loading-does-not-need-a2ui ()
  (let* ((directory (rat-kingdom--directory))
         (output
          (with-temp-buffer
            (call-process
             (expand-file-name invocation-name invocation-directory) nil t nil
             "-Q" "--batch" "-L" directory
             "--eval"
             "(progn (setq load-path (seq-remove (lambda (dir) \
(string-search \"a2ui\" dir)) load-path)) (require 'rat-kingdom) \
(princ (format \"loaded:%s a2ui:%s \" (featurep 'rat-kingdom-issue) \
(featurep 'a2ui))))")
            (buffer-string))))
    (should (string-search "loaded:t a2ui:nil" output))))

(ert-deftest rat-kingdom-issue-test-reload ()
  (rat-kingdom-reload-test--isolated
    (rat-kingdom-reload)
    (rat-kingdom-reload)
    (should (member "rat-kingdom-issue" rat-kingdom--files))
    (should (eql (cl-count "issue_show" rat-kingdom-mcp--tools
                           :key (lambda (tool) (plist-get tool :name))
                           :test #'equal)
                 1))
    (should (eql (cl-count #'rat-kingdom-issue--on-change
                           (default-value 'rat-kingdom-space-change-functions))
                 1))))

(ert-deftest rat-kingdom-issue-test-king-is-told ()
  (should (member "issue_show" (rat-kingdom-mcp-tool-names 'king)))
  (should (string-search "`issue_show`" (rat-kingdom-king-instructions))))

;;;; With the real a2ui

(declare-function a2ui-surface-refresh "a2ui-vui" (&rest _))
(declare-function a2ui-set "a2ui-core" (surface path value &optional scope))

(defconst rat-kingdom-issue-test--buffer "*a2ui: Issue inspector*"
  "The name of the buffer a2ui shows the inspector in.")

(defun rat-kingdom-issue-test--text ()
  "Return the text of the inspector's buffer, once a2ui has drawn it."
  (with-current-buffer rat-kingdom-issue-test--buffer
    (a2ui-surface-refresh)
    ;; a2ui draws on a timer.
    (accept-process-output nil 0.1)
    (buffer-substring-no-properties (point-min) (point-max))))

(defmacro rat-kingdom-issue-test-with-a2ui (vars &rest body)
  "Run BODY with VARS, (SPACE PATH), the stub tracker and the real a2ui."
  (declare (indent 1) (debug t))
  `(rat-kingdom-story-test-with-repo ,vars
     (let* ((rat-kingdom-issue-test--adapter
             (rat-kingdom-issue-test-adapter--create
              :issues (copy-tree rat-kingdom-issue-test--issues)))
            (rat-kingdom-task-adapter-function
             (lambda (_record) rat-kingdom-issue-test--adapter))
            (rat-kingdom-space-change-functions
             (list #'rat-kingdom-issue--on-change))
            (rat-kingdom-issue--session nil)
            (rat-kingdom-issue--space nil)
            (rat-kingdom-issue--repo nil)
            (rat-kingdom-issue--id nil)
            (rat-kingdom-issue--model nil)
            (rat-kingdom-issue--collapsed nil)
            (rat-kingdom-issue--buffer nil)
            (rat-kingdom-issue--timer nil)
            (rat-kingdom-issue--last 0)
            (rat-kingdom-issue--defer #'funcall))
       (unwind-protect
           (save-window-excursion ,@body)
         (rat-kingdom-issue--stop)
         (when (get-buffer rat-kingdom-issue-test--buffer)
           (kill-buffer rat-kingdom-issue-test--buffer))))))

(ert-deftest rat-kingdom-issue-test-a2ui ()
  (skip-unless (rat-kingdom-plan-a2ui-p))
  (rat-kingdom-issue-test-with-a2ui (space path)
    (rat-kingdom-issue-test--stories space)
    (let ((before (selected-window)))
      (rat-kingdom-issue "demo" "demo-1.1")
      ;; It took the place of the selected window's buffer.
      (should (eq (selected-window) before))
      (should (equal (buffer-name (window-buffer before))
                     rat-kingdom-issue-test--buffer)))
    (with-current-buffer rat-kingdom-issue-test--buffer
      (should rat-kingdom-issue-mode)
      (should (eq (key-binding "q") #'quit-window))
      (should (eq (key-binding "g") #'rat-kingdom-issue-refresh)))
    (let ((text (rat-kingdom-issue-test--text)))
      (dolist (expected '("demo-1.1 · P1 · task · open" "epic demo-1"
                          "Inspect one issue in full"
                          "▾ Description" "Show everything." "The end."
                          "▾ Acceptance (1/3 done)" "draw it" "And the docs say so."
                          "▾ Design" "Use a2ui Sections." "▾ Notes"
                          "▾ Dependencies (2)" "blocked by · closed · The base"
                          "▾ Stories (2)" "S-old.1, S-old.2" "0123456"
                          "Draw the comments too."
                          "▾ Comments (2)" "with two lines"
                          "Open parent epic" "Refresh" "Close"))
        (should (string-search expected text)))
      (should (< (string-search "first" text)
                 (string-search "with two lines" text))))
    ;; The user folds Comments; it stays folded when drawn again.
    (a2ui-set (rat-kingdom-issue--surface) "/collapsed/comments" t)
    (should (equal (alist-get 'comments rat-kingdom-issue--collapsed) t))
    (rat-kingdom-issue-refresh)
    (let ((text (rat-kingdom-issue-test--text)))
      (should (string-search "▸ Comments (2)" text))
      (should-not (string-search "with two lines" text))
      (should (string-search "▾ Notes" text)))
    ;; A dependency's button inspects it, with the fold kept.
    (rat-kingdom-issue-test--press "open" "demo-3")
    (let ((text (rat-kingdom-issue-test--text)))
      (should (string-search "Built on it" text))
      (should-not (string-search "Dependencies" text)))
    ;; Close deletes the surface.
    (rat-kingdom-issue-test--press "close")
    (should-not (rat-kingdom-issue--live-p))
    (should-not rat-kingdom-issue--collapsed)
    (should-not (get-buffer rat-kingdom-issue-test--buffer))))

(provide 'rat-kingdom-issue-test)
;;; rat-kingdom-issue-test.el ends here
