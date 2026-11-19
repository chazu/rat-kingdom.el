;;; rat-kingdom-ledger-test.el --- Tests for the epic ledger -*- lexical-binding: t; -*-

;;; Commentary:

;; Batch tests for the epic ledger.  Most run without a2ui: the epics
;; and their tasks come from the in-memory tracker of
;; rat-kingdom-task-test.el, given a method for
;; `rat-kingdom-ledger-read-epics' here, and the engine's state from
;; `epic' and `story' tuples written to the space.  The ledger is built
;; as data, the calls into a2ui are stubbed, and the tests press the
;; buttons by handing the handler the message a2ui would send.  The br
;; method is tested with the real br, if it is installed.  The last
;; tests draw the ledger with the real a2ui, where it can be loaded;
;; see rat-kingdom-plan-test.el for RAT_KINGDOM_TEST_A2UI.

;;; Code:

(require 'ert)
(require 'rat-kingdom-test-helper)
(require 'iso8601)
(require 'rat-kingdom)
(require 'rat-kingdom-ledger)
(require 'rat-kingdom-story-test)
(require 'rat-kingdom-task-test)
(require 'rat-kingdom-reload-test)
(require 'rat-kingdom-plan-test)

;;;; A stub tracker

(cl-defmethod rat-kingdom-ledger-read-epics ((fake rat-kingdom-task-test-fake) closed)
  "Return the epics of FAKE, closed if CLOSED, as br lists them."
  (rat-kingdom-task-test--call fake 'epics closed)
  (cl-loop for task in (rat-kingdom-task-test-fake-tasks fake)
           when (and (equal (plist-get task :type) "epic")
                     (eq (and closed t)
                         (and (rat-kingdom-epic--closed-p task) t)))
           collect (list :id (plist-get task :id) :title (plist-get task :title)
                         :status (plist-get task :status)
                         :priority (plist-get task :priority)
                         :created_at (plist-get task :created-at)
                         :updated_at (plist-get task :updated-at)
                         :closed_at (plist-get task :closed-at))))

(defconst rat-kingdom-ledger-test--now
  (float-time (encode-time (iso8601-parse "2026-11-19T12:00:00Z")))
  "The time the tests run at.")

(defun rat-kingdom-ledger-test--ago (days)
  "Return the time DAYS days before the tests' now, as ISO 8601."
  (format-time-string "%FT%TZ" (- rat-kingdom-ledger-test--now (* days 86400)) t))

(defun rat-kingdom-ledger-test--epic (id title priority &rest more)
  "Return the epic ID called TITLE of PRIORITY, made 10 days ago, with MORE."
  (append more
          (list :id id :title title :status "open" :priority priority
                :type "epic" :created-at (rat-kingdom-ledger-test--ago 10)
                :updated-at (rat-kingdom-ledger-test--ago 3))))

(defun rat-kingdom-ledger-test--task (id parent title &rest more)
  "Return the open task ID of the epic PARENT called TITLE, with MORE."
  (append more
          (list :id id :title title :status "open" :priority 2 :type "task"
                :parent parent :depends-on nil)))

(defun rat-kingdom-ledger-test--tasks ()
  "Return the stub tracker's epics and tasks.
E-1 is running with E-1.2 held.  E-2 has only blocked tasks.  E-3 is
running, with a story for E-3.1 and a foreman.  E-4 is not started and
the most urgent.  E-5 is paused.  E-6 was closed two days ago, and E-7
a month ago."
  (list
   (rat-kingdom-ledger-test--epic "E-1" "Held epic" 2)
   (rat-kingdom-ledger-test--task "E-1.1" "E-1" "Done first" :status "closed"
                                  :closed-at (rat-kingdom-ledger-test--ago 1)
                                  :updated-at (rat-kingdom-ledger-test--ago 1))
   (rat-kingdom-ledger-test--task "E-1.2" "E-1" "Stopped one" :priority 1)
   (rat-kingdom-ledger-test--task "E-1.3" "E-1" "Next one")
   (rat-kingdom-ledger-test--epic "E-2" "Blocked epic" 1)
   (rat-kingdom-ledger-test--task "E-2.1" "E-2" "Waits" :depends-on '("E-2.2"))
   (rat-kingdom-ledger-test--task "E-2.2" "E-2" "Blocked in br" :status "blocked")
   (rat-kingdom-ledger-test--epic "E-3" "Running epic" 3)
   (rat-kingdom-ledger-test--task "E-3.1" "E-3" "Being built"
                                  :status "in_progress")
   (rat-kingdom-ledger-test--task "E-3.2" "E-3" "Ready too" :priority 1)
   (rat-kingdom-ledger-test--epic "E-4" "Fresh epic" 0)
   (rat-kingdom-ledger-test--task "E-4.1" "E-4" "Start here")
   (rat-kingdom-ledger-test--epic "E-5" "Paused epic" 2)
   (rat-kingdom-ledger-test--task "E-5.1" "E-5" "Waits for resume")
   (rat-kingdom-ledger-test--epic "E-6" "Closed lately" 2 :status "closed"
                                  :closed-at (rat-kingdom-ledger-test--ago 2))
   (rat-kingdom-ledger-test--epic "E-7" "Closed long ago" 2 :status "closed"
                                  :closed-at (rat-kingdom-ledger-test--ago 30))))

(defun rat-kingdom-ledger-test--engine (space)
  "Give SPACE the engine's state of the stub tracker's epics."
  (rat-kingdom-space-put space 'epic :scope "demo" :identity "E-1"
                         :payload (list :state "running" :title "Held epic"
                                        :held '((:task "E-1.2" :reason "Parked")))
                         :actor "engine")
  (rat-kingdom-space-put space 'epic :scope "demo" :identity "E-3"
                         :payload (list :state "running" :title "Running epic"
                                        :foreman "F-1")
                         :actor "engine")
  (rat-kingdom-space-put space 'epic :scope "demo" :identity "E-5"
                         :payload (list :state "paused" :title "Paused epic")
                         :actor "engine")
  (rat-kingdom-space-out space 'story :scope "demo" :identity "S-1"
                         :payload (list :epic "E-3" :task "E-3.1" :phase "enter"
                                        :at "implement" :title "Being built")
                         :actor "engine")
  (rat-kingdom-task-project space "demo"))

(defvar rat-kingdom-ledger-test--sent nil
  "The A2UI messages sent to the stubbed a2ui, newest first.")

(defvar rat-kingdom-ledger-test--shown nil
  "Whether the stubbed a2ui shows the ledger.")

(defmacro rat-kingdom-ledger-test-with-stubs (vars &rest body)
  "Run BODY with VARS, (SPACE FAKE), the stub epics and a stubbed a2ui.
The repository \"demo\" has the stub tracker and the engine's state,
the ledger's state is fresh, it follows the space, and what it sends
to a2ui is recorded in `rat-kingdom-ledger-test--sent'."
  (declare (indent 1) (debug t))
  `(rat-kingdom-task-test-with-tracker ,vars
     (setf (rat-kingdom-task-test-fake-tasks ,(cadr vars))
           (rat-kingdom-ledger-test--tasks))
     (let ((rat-kingdom-story-test--now rat-kingdom-ledger-test--now)
           (rat-kingdom-space-change-functions
            (list #'rat-kingdom-ledger--on-change))
           (rat-kingdom-ledger--session nil)
           (rat-kingdom-ledger--space nil)
           (rat-kingdom-ledger--filter (list :repo nil :closed nil))
           (rat-kingdom-ledger--model nil)
           (rat-kingdom-ledger--expanded nil)
           (rat-kingdom-ledger--buffer nil)
           (rat-kingdom-ledger--timer nil)
           (rat-kingdom-ledger--last 0)
           (rat-kingdom-ledger--defer #'funcall)
           (rat-kingdom-ledger--now #'float-time)
           (rat-kingdom-ledger-test--sent nil)
           (rat-kingdom-ledger-test--shown nil))
       (rat-kingdom-ledger-test--engine ,(car vars))
       (cl-letf (((symbol-function 'rat-kingdom-plan-a2ui-p) (lambda () t))
                 ((symbol-function 'rat-kingdom-ledger--send)
                  (lambda (message)
                    (setq rat-kingdom-ledger-test--shown t)
                    (push message rat-kingdom-ledger-test--sent)))
                 ((symbol-function 'rat-kingdom-ledger--live-p)
                  (lambda () rat-kingdom-ledger-test--shown))
                 ((symbol-function 'rat-kingdom-ledger--display) #'ignore))
         (unwind-protect
             (progn ,@body)
           (rat-kingdom-ledger--cancel-timer))))))

(defun rat-kingdom-ledger-test--updates ()
  "Return the updateDataModel messages sent, oldest first, as (PATH . VALUE)."
  (cl-loop for message in (reverse rat-kingdom-ledger-test--sent)
           for (type . body) = (rat-kingdom-plan-test--body message)
           when (equal type "updateDataModel")
           collect (cons (gethash "path" body) (gethash "value" body))))

(defun rat-kingdom-ledger-test--data ()
  "Return the data model last sent whole."
  (cdr (cl-find "/" (reverse (rat-kingdom-ledger-test--updates))
                :key #'car :test #'equal)))

(defun rat-kingdom-ledger-test--rows ()
  "Return the rows of the data model last sent, as a list."
  (append (gethash "rows" (rat-kingdom-ledger-test--data)) nil))

(defun rat-kingdom-ledger-test--row (id)
  "Return the row of the epic ID in the data model last sent."
  (cl-find id (rat-kingdom-ledger-test--rows)
           :key (lambda (row) (gethash "id" row)) :test #'equal))

(defun rat-kingdom-ledger-test--entry (model id)
  "Return the row of MODEL for the epic ID."
  (cl-find id (plist-get model :entries)
           :key (lambda (entry) (plist-get entry :id)) :test #'equal))

(defun rat-kingdom-ledger-test--press (name context)
  "Press the button NAME of the ledger with CONTEXT, an alist, as a2ui does."
  (let ((object (rat-kingdom-plan--obj)))
    (pcase-dolist (`(,key . ,value) context)
      (puthash key value object))
    (rat-kingdom-ledger--receive
     (rat-kingdom-plan--obj
      "version" "v0.9"
      "action" (rat-kingdom-plan--obj
                "name" name "surfaceId" rat-kingdom-ledger-surface-id
                "context" object)))))

(defun rat-kingdom-ledger-test--call (&optional repo)
  "Call `ledger_show' as the king, with REPO if given.  Return (TEXT . FAILED)."
  (rat-kingdom-mcp-call '(:run "king" :role king) "ledger_show"
                        (and repo `((repo . ,repo)))))

(defun rat-kingdom-ledger-test--add-repo (space name tasks)
  "Register the repository NAME in SPACE, with a fake tracker holding TASKS.
Return the fake.  The repository has no checkout; nothing here reads
one."
  (let ((fake (rat-kingdom-task-test-fake--create :tasks tasks))
        (old rat-kingdom-task-adapter-function))
    (rat-kingdom-space-put space 'repo :scope name :identity name
                           :payload (list :path (expand-file-name name
                                                                  temporary-file-directory))
                           :actor "user")
    (setq rat-kingdom-task-adapter-function
                (lambda (record)
                  (if (equal (plist-get record :name) name)
                      fake
                    (funcall old record))))
    fake))

;;;; Counts and states

(ert-deftest rat-kingdom-ledger-test-counts ()
  (rat-kingdom-ledger-test-with-stubs (space _fake)
    (let ((model (rat-kingdom-ledger-gather space '(:repo nil :closed nil))))
      (should (equal (plist-get (rat-kingdom-ledger-test--entry model "E-1") :counts)
                     '(:closed 1 :progress 0 :ready 1 :blocked 1 :total 3)))
      (should (equal (plist-get (rat-kingdom-ledger-test--entry model "E-2") :counts)
                     '(:closed 0 :progress 0 :ready 0 :blocked 2 :total 2)))
      (should (equal (plist-get (rat-kingdom-ledger-test--entry model "E-3") :counts)
                     '(:closed 0 :progress 1 :ready 1 :blocked 0 :total 2)))
      (should-not (plist-get model :problems)))
    (rat-kingdom-ledger-show space)
    (let ((row (rat-kingdom-ledger-test--row "E-1")))
      (should (equal (gethash "counts" row) "1/0/1/1"))
      (should (< (abs (- (gethash "done" row) (/ 1.0 3))) 0.001))
      (should (equal (gethash "next" row) "E-1.3 Next one"))
      ;; Its epic tuple was written just now.
      (should (equal (gethash "age" row) "10d/0s")))
    (should (equal (gethash "age" (rat-kingdom-ledger-test--row "E-4")) "10d/3d"))
    (should (equal (gethash "next" (rat-kingdom-ledger-test--row "E-2")) "-"))
    ;; E-3.2 is the next ready, E-3.1 having a story.
    (should (equal (gethash "next" (rat-kingdom-ledger-test--row "E-3"))
                   "E-3.2 Ready t…"))
    (let ((overall (gethash "overall" (rat-kingdom-ledger-test--data))))
      (should (equal (gethash "closed" overall) 1))
      (should (equal (gethash "total" overall) 9))
      (should (equal (gethash "text" overall) "1/9")))))

(ert-deftest rat-kingdom-ledger-test-engine-states ()
  (rat-kingdom-ledger-test-with-stubs (space _fake)
    (let ((model (rat-kingdom-ledger-gather space '(:repo nil :closed t))))
      (should (equal (mapcar (lambda (id)
                               (rat-kingdom-ledger-state-text
                                (rat-kingdom-ledger-test--entry model id)))
                             '("E-1" "E-2" "E-3" "E-4" "E-5" "E-6"))
                     '("held E-1.2" "not started" "running 1 +F" "not started"
                       "paused" "closed")))
      (should (equal (plist-get (rat-kingdom-ledger-test--entry model "E-3") :running)
                     1)))
    ;; Landing, and more than one held task.
    (rat-kingdom-space-put space 'epic :scope "demo" :identity "E-5"
                           :payload (list :state "landing" :title "Paused epic"))
    (rat-kingdom-space-put space 'epic :scope "demo" :identity "E-2"
                           :payload (list :state "paused"
                                          :held '((:task "E-2.1" :reason "x")
                                                  (:task "E-2.2" :reason "y"))))
    (let ((model (rat-kingdom-ledger-gather space '(:repo nil :closed nil))))
      (should (equal (rat-kingdom-ledger-state-text
                      (rat-kingdom-ledger-test--entry model "E-5"))
                     "landing"))
      (should (equal (rat-kingdom-ledger-state-text
                      (rat-kingdom-ledger-test--entry model "E-2"))
                     "held E-2.1 +1")))
    ;; An epic the engine ended is not held, whatever it kept.
    (rat-kingdom-space-put space 'epic :scope "demo" :identity "E-1"
                           :payload (list :state "cancelled"
                                          :held '((:task "E-1.2" :reason "x"))))
    (let ((entry (rat-kingdom-ledger-test--entry
                  (rat-kingdom-ledger-gather space '(:repo nil :closed nil))
                  "E-1")))
      (should-not (plist-get entry :held))
      (should (equal (rat-kingdom-ledger-state-text entry) "cancelled")))))

(ert-deftest rat-kingdom-ledger-test-sort-order ()
  (rat-kingdom-ledger-test-with-stubs (space _fake)
    ;; Held, then blocked with nothing ready, then running, then by
    ;; priority; closed last.
    (rat-kingdom-ledger-show space '(:repo nil :closed t))
    (should (equal (mapcar (lambda (row) (gethash "id" row))
                           (rat-kingdom-ledger-test--rows))
                   '("E-1" "E-2" "E-3" "E-4" "E-5" "E-6")))
    (should (equal (mapcar (lambda (row) (gethash "tone" row))
                           (rat-kingdom-ledger-test--rows))
                   '("error" "warning" "success" "" "" "muted")))
    ;; E-7 was closed too long ago.
    (should-not (rat-kingdom-ledger-test--row "E-7"))
    (should (equal (gethash "summary" (rat-kingdom-ledger-test--data))
                   "5 open epics, 1 held, 1 blocked with nothing ready, \
1 closed in the last 7 days"))
    ;; Without the check box, no closed epic.
    (rat-kingdom-ledger-show space '(:repo nil :closed nil))
    (should-not (rat-kingdom-ledger-test--row "E-6"))
    (should (equal (gethash "summary" (rat-kingdom-ledger-test--data))
                   "5 open epics, 1 held, 1 blocked with nothing ready"))))

(ert-deftest rat-kingdom-ledger-test-sparkline ()
  (rat-kingdom-ledger-test-with-stubs (space fake)
    (let ((closed (rat-kingdom-task-test--task fake "E-3.2")))
      (plist-put closed :status "closed")
      (plist-put closed :closed-at (rat-kingdom-ledger-test--ago 0)))
    (plist-put (rat-kingdom-task-test--task fake "E-3.1")
               :closed-at (rat-kingdom-ledger-test--ago 20))
    (rat-kingdom-ledger-show space)
    ;; E-1.1 was closed yesterday: the 13th of 14 days.
    (should (equal (gethash "spark" (rat-kingdom-ledger-test--row "E-1"))
                   [0 0 0 0 0 0 0 0 0 0 0 0 1 0]))
    (should (equal (gethash "spark" (rat-kingdom-ledger-test--row "E-3"))
                   [0 0 0 0 0 0 0 0 0 0 0 0 0 1]))
    ;; No task of E-2 has a closed_at: no sparkline.
    (should (equal (gethash "spark" (rat-kingdom-ledger-test--row "E-2")) ""))
    (let ((overall (gethash "overall" (rat-kingdom-ledger-test--data))))
      (should (equal (gethash "spark" overall) [0 0 0 0 0 0 0 0 0 0 0 0 1 1]))
      (should (eq (gethash "hasSpark" overall) t))))
  ;; Closures older than the window draw a flat line.
  (should (equal (rat-kingdom-ledger--spark-value (make-vector 3 0)) "▁▁▁")))

(ert-deftest rat-kingdom-ledger-test-repo-filter ()
  (rat-kingdom-ledger-test-with-stubs (space _fake)
    (rat-kingdom-ledger-test--add-repo
     space "other"
     (list (rat-kingdom-ledger-test--epic "O-1" "Other epic" 2)
           (rat-kingdom-ledger-test--task "O-1.1" "O-1" "Its task")))
    (rat-kingdom-ledger-show space '(:repo nil :closed nil))
    (should (rat-kingdom-ledger-test--row "O-1"))
    ;; With every repository, the title says which.
    (should (equal (gethash "title" (rat-kingdom-ledger-test--row "O-1"))
                   "other · Other epic"))
    (should (equal (gethash "key" (rat-kingdom-ledger-test--row "O-1"))
                   "other/O-1"))
    (rat-kingdom-ledger-show space '(:repo "other" :closed nil))
    (should (equal (mapcar (lambda (row) (gethash "id" row))
                           (rat-kingdom-ledger-test--rows))
                   '("O-1")))
    (should (equal (gethash "title" (rat-kingdom-ledger-test--row "O-1"))
                   "Other epic"))
    (let ((filter (gethash "filter" (rat-kingdom-ledger-test--data))))
      (should (equal (gethash "repo" filter) "other"))
      (should (eq (gethash "closed" filter) :false)))
    (should (equal (mapcar (lambda (option) (gethash "value" option))
                           (gethash "repos" (rat-kingdom-ledger-test--data)))
                   '("" "demo" "other")))
    ;; The picker and the check box, through the Apply button.
    (rat-kingdom-ledger-test--press "filter" '(("repo" . "demo") ("closed" . t)))
    (should (equal rat-kingdom-ledger--filter '(:repo "demo" :closed t)))
    (should (rat-kingdom-ledger-test--row "E-6"))
    (should-not (rat-kingdom-ledger-test--row "O-1"))
    (rat-kingdom-ledger-test--press "filter" '(("repo" . "") ("closed" . :false)))
    (should (equal rat-kingdom-ledger--filter '(:repo nil :closed nil)))
    (should (rat-kingdom-ledger-test--row "O-1"))
    (should-error (rat-kingdom-ledger-gather space '(:repo "nope")))))

(ert-deftest rat-kingdom-ledger-test-tracker-fails ()
  (rat-kingdom-ledger-test-with-stubs (space fake)
    (setf (rat-kingdom-task-test-fake-fail fake) t)
    (rat-kingdom-ledger-show space)
    (should-not (rat-kingdom-ledger-test--rows))
    (let ((data (rat-kingdom-ledger-test--data)))
      (should (string-search "The tracker of demo failed" (gethash "result" data)))
      (should (eq (gethash "hasResult" data) t))
      (should (eq (gethash "isEmpty" data) t)))))

;;;; Expanding, and the inspector

(ert-deftest rat-kingdom-ledger-test-expanded-children ()
  (rat-kingdom-ledger-test-with-stubs (space _fake)
    (rat-kingdom-ledger-show space)
    (let ((details (append (gethash "details" (rat-kingdom-ledger-test--data)) nil)))
      (should (equal (mapcar (lambda (detail) (gethash "visible" detail)) details)
                     '(:false :false :false :false :false)))
      (let* ((detail (nth 2 details))
             (children (append (gethash "children" detail) nil)))
        (should (equal (gethash "key" detail) "demo/E-3"))
        (should (equal (gethash "title" detail) "E-3 · Running epic (2 tasks)"))
        (should (equal (mapcar (lambda (child)
                                 (list (gethash "id" child) (gethash "priority" child)
                                       (gethash "status" child) (gethash "title" child)
                                       (gethash "story" child)))
                               children)
                       '(("E-3.1" "P2" "in progress" "Being built"
                          "S-1 at implement (starting)")
                         ("E-3.2" "P1" "ready" "Ready too" ""))))
        (should (equal (gethash "repo" (car children)) "demo"))))
    ;; The user selects E-3 and E-1: their tasks are shown.
    (setq rat-kingdom-ledger-test--sent nil)
    (cl-letf (((symbol-function 'rat-kingdom-ledger--read-expanded)
               (lambda () '("demo/E-3" "demo/E-1"))))
      (rat-kingdom-ledger--changed rat-kingdom-ledger-surface-id))
    (should (equal rat-kingdom-ledger--expanded '("demo/E-3" "demo/E-1")))
    (should (equal (rat-kingdom-ledger-test--updates)
                   '(("/expanded" . ["demo/E-3" "demo/E-1"])
                     ("/details/0/visible" . t) ("/details/1/visible" . :false)
                     ("/details/2/visible" . t) ("/details/3/visible" . :false)
                     ("/details/4/visible" . :false))))
    ;; The same selection again sends nothing.
    (setq rat-kingdom-ledger-test--sent nil)
    (should-not (rat-kingdom-ledger-expand '("demo/E-3" "demo/E-1")))
    ;; A redraw keeps them expanded.
    (rat-kingdom-ledger-refresh)
    (let ((data (rat-kingdom-ledger-test--data)))
      (should (equal (gethash "expanded" data) ["demo/E-3" "demo/E-1"]))
      (should (equal (gethash "visible" (aref (gethash "details" data) 2)) t)))))

(ert-deftest rat-kingdom-ledger-test-inspector-link ()
  (rat-kingdom-ledger-test-with-stubs (space _fake)
    (rat-kingdom-ledger-show space)
    (let (opened)
      (cl-letf (((symbol-function 'rat-kingdom-issue-show)
                 (lambda (&rest args) (push args opened))))
        ;; RET on an epic's id, and on a task's.
        (rat-kingdom-ledger-test--press "open" '(("repo" . "demo") ("id" . "E-3")))
        (rat-kingdom-ledger-test--press "open" '(("repo" . "demo") ("id" . "E-3.2"))))
      (should (equal (reverse opened)
                     (list (list space "demo" "E-3" t)
                           (list space "demo" "E-3.2" t)))))
    ;; Both tables send the row's repo and id.
    (let* ((components (rat-kingdom-ledger-components))
           (table (lambda (id)
                    (cl-find id components
                             :key (lambda (component) (gethash "id" component))
                             :test #'equal))))
      (dolist (id '("epics" "detail-tasks"))
        (let ((context (gethash "context"
                                (gethash "event"
                                         (gethash "rowAction"
                                                  (funcall table id))))))
          (should (equal (gethash "path" (gethash "repo" context)) "repo"))
          (should (equal (gethash "path" (gethash "id" context)) "id"))))
      (should (equal (gethash "selectable" (funcall table "epics")) "multiple"))
      ;; No button runs an epic.
      (should-not (cl-some (lambda (component)
                             (let ((action (gethash "action" component)))
                               (and action
                                    (not (member (gethash "name"
                                                          (gethash "event" action))
                                                 '("filter"))))))
                           components)))))

(ert-deftest rat-kingdom-ledger-test-open-parent-epic ()
  (should (eq (default-value 'rat-kingdom-issue-open-epic-function)
              #'rat-kingdom-ledger-open-epic))
  (rat-kingdom-ledger-test-with-stubs (space _fake)
    (rat-kingdom-ledger-test--add-repo
     space "other" (list (rat-kingdom-ledger-test--epic "O-1" "Other epic" 2)))
    ;; The inspector's Open parent epic shows the ledger of the
    ;; repository, with the epic expanded.
    (let ((rat-kingdom-issue-open-epic-function #'rat-kingdom-ledger-open-epic)
          (rat-kingdom-issue--space space)
          (rat-kingdom-issue--repo "demo")
          (inspected nil))
      (cl-letf (((symbol-function 'rat-kingdom-issue-open)
                 (lambda (id) (push id inspected))))
        (rat-kingdom-issue-open-parent "E-3")
        (should-not inspected)
        (should (equal rat-kingdom-ledger--filter '(:repo "demo" :closed nil)))
        (should (equal rat-kingdom-ledger--expanded '("demo/E-3")))
        (let ((data (rat-kingdom-ledger-test--data)))
          (should (equal (gethash "expanded" data) ["demo/E-3"]))
          (should (equal (gethash "visible" (aref (gethash "details" data) 2)) t)))
        ;; An epic closed lately is found with the check box.
        (rat-kingdom-issue-open-parent "E-6")
        (should-not inspected)
        (should (equal rat-kingdom-ledger--filter '(:repo "demo" :closed t)))
        ;; One the ledger cannot show is left to the inspector.
        (setq rat-kingdom-ledger-test--sent nil)
        (rat-kingdom-issue-open-parent "E-7")
        (should (equal inspected '("E-7")))
        (should-not rat-kingdom-ledger-test--sent)))))

;;;; Keeping it up to date

(ert-deftest rat-kingdom-ledger-test-follows-the-space ()
  (rat-kingdom-ledger-test-with-stubs (space _fake)
    (let ((now 100.0))
      (setq rat-kingdom-ledger--now (lambda () now))
      (rat-kingdom-ledger-show space)
      (should-not rat-kingdom-ledger--timer)
      ;; A tuple of no epic changes nothing.
      (rat-kingdom-space-out space 'message :scope "demo" :payload '(:to "king"))
      (should-not rat-kingdom-ledger--timer)
      ;; The engine pauses E-3: the ledger is drawn again.
      (rat-kingdom-space-put space 'epic :scope "demo" :identity "E-3"
                             :payload (list :state "paused" :title "Running epic"))
      (should (timerp rat-kingdom-ledger--timer))
      (setq rat-kingdom-ledger-test--sent nil)
      (rat-kingdom-ledger-flush)
      (should-not rat-kingdom-ledger--timer)
      (should (equal (gethash "state" (rat-kingdom-ledger-test--row "E-3")) "paused"))
      ;; A story of an epic, and a task of an epic made available.
      (rat-kingdom-space-out space 'story :scope "demo" :identity "S-2"
                             :payload (list :epic "E-4" :task "E-4.1"))
      (should (timerp rat-kingdom-ledger--timer))
      (rat-kingdom-ledger--cancel-timer)
      (rat-kingdom-space-out space 'available :scope "demo" :identity "E-9.1"
                             :payload (list :parent "E-9"))
      (should (timerp rat-kingdom-ledger--timer))
      (rat-kingdom-ledger--cancel-timer)
      ;; A story whose task is settled.
      (rat-kingdom-ledger--on-settled
       space (list :scope "demo" :payload (list :epic "E-4" :task "E-4.1")))
      (should (timerp rat-kingdom-ledger--timer))
      (rat-kingdom-ledger--cancel-timer)
      ;; Showing one repository, another's changes do not count.
      (rat-kingdom-ledger-show space '(:repo "demo" :closed nil))
      (rat-kingdom-space-put space 'epic :scope "other" :identity "O-1"
                             :payload (list :state "running"))
      (should-not rat-kingdom-ledger--timer)
      ;; Once the surface is deleted, the ledger stops following.
      (setq rat-kingdom-ledger-test--shown nil)
      (rat-kingdom-ledger--changed rat-kingdom-ledger-surface-id)
      (should-not rat-kingdom-ledger--space)
      (rat-kingdom-space-put space 'epic :scope "demo" :identity "E-3"
                             :payload (list :state "running"))
      (should-not rat-kingdom-ledger--timer))))

;;;; The layout

(ert-deftest rat-kingdom-ledger-test-fits ()
  (rat-kingdom-ledger-test-with-stubs (space fake)
    (plist-put (rat-kingdom-task-test--task fake "E-4") :title
               "A very long title for an epic, much longer than any row can hold")
    (rat-kingdom-ledger-show space)
    (let* ((rows (rat-kingdom-ledger-test--rows))
           (width (rat-kingdom-ledger-title-width
                   (plist-get rat-kingdom-ledger--model :entries))))
      (should (>= width rat-kingdom-ledger-min-title-width))
      (dolist (row rows)
        (should (<= (string-width (gethash "title" row)) width))
        (should (<= (string-width (gethash "state" row)) 12))
        (should (<= (string-width (gethash "next" row)) 14)))
      (should (string-suffix-p "…" (gethash "title" (rat-kingdom-ledger-test--row
                                                      "E-4"))))))
  (should (equal (mapcar #'rat-kingdom-ledger-age-text '(5 300 7300 200000))
                 '("5s" "5m" "2h" "2d"))))

;;;; The king's tool

(ert-deftest rat-kingdom-ledger-test-tool ()
  (rat-kingdom-ledger-test-with-stubs (space _fake)
    (let ((answer (rat-kingdom-ledger-test--call)))
      (should-not (cdr answer))
      (should (equal (car answer)
                     "Shown to the user: the epic ledger of all repositories: \
5 open epics, 1 held, 1 blocked with nothing ready.")))
    (should (eq rat-kingdom-ledger--space space))
    (let ((answer (rat-kingdom-ledger-test--call "demo")))
      (should-not (cdr answer))
      (should (string-prefix-p "Shown to the user: the epic ledger of demo: 5 open"
                               (car answer))))
    (should (equal (plist-get rat-kingdom-ledger--filter :repo) "demo"))
    (let ((answer (rat-kingdom-ledger-test--call "nope")))
      (should (cdr answer))
      (should (string-search "There is no repository called nope" (car answer))))
    (cl-letf (((symbol-function 'rat-kingdom-plan-a2ui-p) #'ignore))
      (let ((answer (rat-kingdom-ledger-test--call)))
        (should (cdr answer))
        (should (string-search "not available" (car answer)))))))

(ert-deftest rat-kingdom-ledger-test-king-is-told ()
  (should (member "ledger_show" (rat-kingdom-mcp-tool-names 'king)))
  (should (string-search "`ledger_show`" (rat-kingdom-king-instructions))))

;;;; br

(ert-deftest rat-kingdom-ledger-test-real-br ()
  (skip-unless (executable-find "br"))
  (let* ((directory (make-temp-file "rat-kingdom-ledger-br" t))
         (rat-kingdom-task-br-program "br")
         (adapter (rat-kingdom-task-br (list :name "tt" :path directory))))
    (unwind-protect
        (progn
          (rat-kingdom-task-br--call directory "init" "--prefix" "tt")
          (let* ((epic (rat-kingdom-task-create adapter "Epic" :type "epic"))
                 (done (rat-kingdom-task-create adapter "Done" :parent epic))
                 (old (rat-kingdom-task-create adapter "Old" :type "epic")))
            (rat-kingdom-task-create adapter "Open" :parent epic)
            (rat-kingdom-task-close adapter done "done")
            (rat-kingdom-task-close adapter old "done")
            (should (equal (mapcar (lambda (issue) (plist-get issue :id))
                                   (rat-kingdom-ledger-read-epics adapter nil))
                           (list epic)))
            (should (equal (mapcar (lambda (issue) (plist-get issue :id))
                                   (rat-kingdom-ledger-read-epics adapter t))
                           (list old)))
            (should (plist-get (car (rat-kingdom-ledger-read-epics adapter t))
                               :closed_at))
            ;; The tasks keep br's times, for the sparkline.
            (let ((children (rat-kingdom-task-children adapter epic)))
              (should (plist-get (car children) :closed-at))
              (should (plist-get (car children) :updated-at))
              (should-not (plist-get (cadr children) :closed-at)))))
      (delete-directory directory t))))

;;;; Loading and reloading

(ert-deftest rat-kingdom-ledger-test-loading-does-not-need-a2ui ()
  (let* ((directory (rat-kingdom--directory))
         (output
          (with-temp-buffer
            (call-process
             (expand-file-name invocation-name invocation-directory) nil t nil
             "-Q" "--batch" "-L" directory
             "--eval"
             "(progn (setq load-path (seq-remove (lambda (dir) \
(string-search \"a2ui\" dir)) load-path)) (require 'rat-kingdom) \
(princ (format \"loaded:%s a2ui:%s \" (featurep 'rat-kingdom-ledger) \
(featurep 'a2ui))))")
            (buffer-string))))
    (should (string-search "loaded:t a2ui:nil" output))))

(ert-deftest rat-kingdom-ledger-test-reload ()
  (rat-kingdom-reload-test--isolated
    (rat-kingdom-reload)
    (rat-kingdom-reload)
    (should (member "rat-kingdom-ledger" rat-kingdom--files))
    (should (eql (cl-count "ledger_show" rat-kingdom-mcp--tools
                           :key (lambda (tool) (plist-get tool :name))
                           :test #'equal)
                 1))
    (should (eql (cl-count #'rat-kingdom-ledger--on-change
                           (default-value 'rat-kingdom-space-change-functions))
                 1))
    (should (eql (cl-count #'rat-kingdom-ledger--on-settled
                           (default-value 'rat-kingdom-task-settled-functions))
                 1))))

;;;; With the real a2ui

(declare-function a2ui-surface-refresh "a2ui-vui" (&rest _))
(declare-function a2ui-set "a2ui-core" (surface path value &optional scope))

(defconst rat-kingdom-ledger-test--buffer "*a2ui: Epic ledger*"
  "The name of the buffer a2ui shows the ledger in.")

(defun rat-kingdom-ledger-test--text ()
  "Return the text of the ledger's buffer, once a2ui has drawn it."
  (with-current-buffer rat-kingdom-ledger-test--buffer
    (a2ui-surface-refresh)
    ;; a2ui draws on a timer.
    (accept-process-output nil 0.1)
    (buffer-substring-no-properties (point-min) (point-max))))

(defmacro rat-kingdom-ledger-test-with-a2ui (vars &rest body)
  "Run BODY with VARS, (SPACE FAKE), the stub epics and the real a2ui."
  (declare (indent 1) (debug t))
  `(rat-kingdom-task-test-with-tracker ,vars
     (setf (rat-kingdom-task-test-fake-tasks ,(cadr vars))
           (rat-kingdom-ledger-test--tasks))
     (let ((rat-kingdom-story-test--now rat-kingdom-ledger-test--now)
           (rat-kingdom-space-change-functions
            (list #'rat-kingdom-ledger--on-change))
           (rat-kingdom-ledger--session nil)
           (rat-kingdom-ledger--space nil)
           (rat-kingdom-ledger--filter (list :repo nil :closed nil))
           (rat-kingdom-ledger--model nil)
           (rat-kingdom-ledger--expanded nil)
           (rat-kingdom-ledger--buffer nil)
           (rat-kingdom-ledger--timer nil)
           (rat-kingdom-ledger--last 0)
           (rat-kingdom-ledger--defer #'funcall))
       (rat-kingdom-ledger-test--engine ,(car vars))
       (unwind-protect
           (save-window-excursion ,@body)
         (rat-kingdom-ledger--stop)
         (when (get-buffer rat-kingdom-ledger-test--buffer)
           (kill-buffer rat-kingdom-ledger-test--buffer))))))

(defun rat-kingdom-ledger-test--line (text id)
  "Return the line of TEXT that holds the row of the epic ID."
  (cl-find-if (lambda (line) (string-match-p (format "\\_<%s\\_>" (regexp-quote id))
                                             line))
              (split-string text "\n")))

(ert-deftest rat-kingdom-ledger-test-a2ui ()
  (skip-unless (rat-kingdom-plan-a2ui-p))
  (rat-kingdom-ledger-test-with-a2ui (space _fake)
    (let ((before (selected-window)))
      (rat-kingdom-ledger)
      ;; It took the place of the selected window's buffer.
      (should (eq (selected-window) before))
      (should (equal (buffer-name (window-buffer before))
                     rat-kingdom-ledger-test--buffer)))
    (with-current-buffer rat-kingdom-ledger-test--buffer
      (should rat-kingdom-ledger-mode)
      (should (eq (key-binding "q") #'quit-window))
      (should (eq (key-binding "g") #'rat-kingdom-ledger-refresh)))
    (let* ((text (rat-kingdom-ledger-test--text))
           (lines (split-string text "\n")))
      (dolist (expected '("Epic ledger" "5 open epics, 1 held"
                          "Tasks closed" "Closed per day, 14 days"
                          "Closed in the last 7 days" "C/P/R/B"
                          "held E-1.2" "running 1 +F" "paused"
                          "E-3.2 Ready t" "demo · Held epic"))
        (should (string-search expected text)))
      ;; One line per epic, in the ledger's order, each within the width.
      (let ((rows (mapcar (lambda (id) (rat-kingdom-ledger-test--line text id))
                          '("E-1" "E-2" "E-3" "E-4" "E-5"))))
        (should (cl-every #'identity rows))
        (should (equal (mapcar (lambda (row) (cl-position row lines :test #'equal))
                               rows)
                       (number-sequence (cl-position (car rows) lines :test #'equal)
                                        (+ 4 (cl-position (car rows) lines
                                                          :test #'equal)))))
        (dolist (row rows)
          (should (<= (string-width row) rat-kingdom-ledger-width)))
        (should (string-search "1/0/1/1" (car rows)))
        (should (string-search "▁" (car rows))))
      ;; Nothing is expanded yet.
      (should-not (string-search "Being built" text)))
    ;; The user selects E-3: its tasks are shown under the table.
    (a2ui-set (rat-kingdom-ledger--surface) "/expanded" ["demo/E-3"])
    (should (equal rat-kingdom-ledger--expanded '("demo/E-3")))
    (let ((text (rat-kingdom-ledger-test--text)))
      (dolist (expected '("E-3 · Running epic (2 tasks)" "Being built"
                          "S-1 at implement" "ready"))
        (should (string-search expected text)))
      (should-not (string-search "Stopped one" text))
      (dolist (line (split-string text "\n"))
        (should (<= (string-width line) rat-kingdom-ledger-width))))
    ;; g keeps it expanded.
    (rat-kingdom-ledger-refresh)
    (should (string-search "Being built" (rat-kingdom-ledger-test--text)))
    ;; RET on a task's id shows it in the inspector.
    (let (opened)
      (cl-letf (((symbol-function 'rat-kingdom-issue-show)
                 (lambda (&rest args) (push args opened))))
        (rat-kingdom-ledger-test--press "open" '(("repo" . "demo") ("id" . "E-3.1"))))
      (should (equal opened (list (list space "demo" "E-3.1" t)))))))

(provide 'rat-kingdom-ledger-test)
;;; rat-kingdom-ledger-test.el ends here
