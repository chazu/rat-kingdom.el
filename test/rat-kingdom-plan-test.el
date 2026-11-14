;;; rat-kingdom-plan-test.el --- Tests for the epic plan surface -*- lexical-binding: t; -*-

;;; Commentary:

;; Batch tests for the epic plan surface and the king's `epic_propose'.
;; Most run without a2ui: the surface is built as data, the calls into
;; a2ui are stubbed, and the tests press the buttons by handing the
;; handler the context a2ui would send.  They use the in-memory tracker
;; of rat-kingdom-task-test.el.
;;
;; The last tests draw the surface with the real a2ui and press its
;; buttons through a2ui.  They run only where a2ui and vui can be
;; loaded: put the directories that hold them in the environment
;; variable RAT_KINGDOM_TEST_A2UI, separated by `path-separator', e.g.
;;
;;   RAT_KINGDOM_TEST_A2UI=~/.emacs.d/straight/build/a2ui:~/.emacs.d/straight/build/vui eldev test

;;; Code:

(require 'ert)
(require 'rat-kingdom-plan)
(require 'rat-kingdom-story-test)
(require 'rat-kingdom-task-test)
(require 'rat-kingdom-king-test)
(require 'rat-kingdom-epic-test)
(require 'rat-kingdom-reload-test)

(dolist (directory (reverse (split-string (or (getenv "RAT_KINGDOM_TEST_A2UI")
                                              "")
                                          path-separator t)))
  (add-to-list 'load-path (expand-file-name directory)))

(defconst rat-kingdom-plan-test--diamond
  "[{\"key\":\"a\",\"title\":\"Base\",\"description\":\"The base.\",
     \"priority\":1},
    {\"key\":\"b\",\"title\":\"Left\",\"description\":\"The left side.\",
     \"depends_on\":[\"a\"],\"agent\":\"codex\"},
    {\"key\":\"c\",\"title\":\"Right\",\"description\":\"The right side.\",
     \"depends_on\":[\"a\"],\"workflow\":\"story\"},
    {\"key\":\"d\",\"title\":\"Join\",\"description\":\"Join b and c.\",
     \"depends_on\":[\"b\",\"c\"]}]"
  "A diamond: b and c depend on a, d on b and c.")

(defvar rat-kingdom-plan-test--sent nil
  "The A2UI messages sent to the stubbed a2ui, newest first.")

(defvar rat-kingdom-plan-test--shown nil
  "The surfaces the stubbed a2ui was asked to show, newest first.")

(defvar rat-kingdom-plan-test--deleted nil
  "The surfaces the stubbed a2ui was asked to delete, newest first.")

(defmacro rat-kingdom-plan-test--isolated (&rest body)
  "Run BODY with no plan shown and buttons handled at once."
  (declare (indent 0) (debug t))
  `(let ((rat-kingdom-plan--plans (make-hash-table :test #'equal))
         (rat-kingdom-plan--session nil)
         (rat-kingdom-plan--defer #'funcall)
         (rat-kingdom-plan-test--sent nil)
         (rat-kingdom-plan-test--shown nil)
         (rat-kingdom-plan-test--deleted nil))
     ,@body))

(defmacro rat-kingdom-plan-test-with-stubs (vars &rest body)
  "Run BODY with VARS, (SPACE FAKE), an empty tracker and a stubbed a2ui.
The king is running.  a2ui counts as loaded, and what is sent to it,
shown and deleted is recorded.  A surface counts as shown from when
its plan is recorded until it is deleted."
  (declare (indent 1) (debug t))
  `(rat-kingdom-epic-test-with-empty-tracker ,vars
     (rat-kingdom-plan-test--isolated
       (cl-letf (((symbol-function 'rat-kingdom-plan-a2ui-p) (lambda () t))
                 ((symbol-function 'rat-kingdom-plan--send)
                  (lambda (message) (push message rat-kingdom-plan-test--sent)))
                 ((symbol-function 'rat-kingdom-plan--live-p)
                  (lambda (id)
                    (and (gethash id rat-kingdom-plan--plans)
                         (not (member id rat-kingdom-plan-test--deleted)))))
                 ((symbol-function 'rat-kingdom-plan--display)
                  (lambda (id) (push id rat-kingdom-plan-test--shown)))
                 ((symbol-function 'rat-kingdom-plan--delete)
                  (lambda (id)
                    (when (rat-kingdom-plan--live-p id)
                      (push id rat-kingdom-plan-test--deleted)))))
         ,@body))))

(defun rat-kingdom-plan-test--propose (&optional stories)
  "Call epic_propose as the king for demo with STORIES, a JSON text.
STORIES is the diamond by default.  Return (TEXT . FAILED)."
  (rat-kingdom-king-test--call
   "epic_propose" '(repo . "demo") '(title . "Plan")
   '(description . "The goal, judged as a whole.")
   (cons 'stories (rat-kingdom-epic-test--json
                   (or stories rat-kingdom-plan-test--diamond)))))

(defun rat-kingdom-plan-test--body (message)
  "Return the body of the A2UI MESSAGE and its type, as (TYPE . BODY)."
  (let (found)
    (maphash (lambda (key value)
               (unless (equal key "version")
                 (setq found (cons key value))))
             message)
    found))

(defun rat-kingdom-plan-test--data ()
  "Return the data model the stubbed a2ui was last given whole."
  (cl-loop for message in rat-kingdom-plan-test--sent
           for (type . body) = (rat-kingdom-plan-test--body message)
           when (and (equal type "updateDataModel")
                     (equal (gethash "path" body) "/"))
           return (gethash "value" body)))

(defun rat-kingdom-plan-test--value (path)
  "Return the value last set at PATH of the surface's data model."
  (cl-loop for message in rat-kingdom-plan-test--sent
           for (type . body) = (rat-kingdom-plan-test--body message)
           when (and (equal type "updateDataModel")
                     (equal (gethash "path" body) path))
           return (gethash "value" body)
           finally return
           (let ((data (rat-kingdom-plan-test--data)))
             (and data (gethash (substring path 1) data)))))

(defun rat-kingdom-plan-test--copy (value)
  "Return a deep copy of the JSON VALUE."
  (cond ((hash-table-p value)
         (let ((copy (make-hash-table :test #'equal)))
           (maphash (lambda (key item)
                      (puthash key (rat-kingdom-plan-test--copy item) copy))
                    value)
           copy))
        ((vectorp value) (vconcat (mapcar #'rat-kingdom-plan-test--copy value)))
        (t value)))

(defun rat-kingdom-plan-test--context (&rest edits)
  "Return the context Approve sends, after EDITS to the surface's data.
EDITS alternate a path, as (KEY FIELD) for a story's field or (FIELD)
for an option, and its new value."
  (let* ((data (rat-kingdom-plan-test--data))
         (stories (rat-kingdom-plan-test--copy (gethash "stories" data)))
         (options (rat-kingdom-plan-test--copy (gethash "options" data))))
    (while edits
      (let ((path (pop edits))
            (value (pop edits)))
        (if (cdr path)
            (puthash (cadr path) value
                     (cl-find (car path) stories
                              :key (lambda (story) (gethash "key" story))
                              :test #'equal))
          (puthash (car path) value options))))
    (rat-kingdom-plan--obj "stories" stories "options" options)))

(defun rat-kingdom-plan-test--press (name &optional context)
  "Press the button NAME of the plan surface, which sends CONTEXT."
  (rat-kingdom-plan--receive
   (rat-kingdom-plan--obj
    "version" "v0.9"
    "action" (rat-kingdom-plan--obj
              "name" name "surfaceId" "Epic plan: Plan"
              "sourceComponentId" name
              "context" (or context (rat-kingdom-plan--obj))))))

(defun rat-kingdom-plan-test--creates (fake)
  "Return the tasks FAKE was asked to create, as (TITLE LABELS), oldest first."
  (mapcar (lambda (call) (list (nth 1 call) (plist-get (cddr call) :labels)))
          (cl-remove-if-not (lambda (call) (eq (car call) 'create))
                            (reverse (rat-kingdom-task-test-fake-calls fake)))))

;;;; Waves

(ert-deftest rat-kingdom-plan-test-waves ()
  (let ((waves (rat-kingdom-plan-waves
                (rat-kingdom-epic-check rat-kingdom-plan-test--diamond))))
    (should (equal (mapcar (lambda (wave)
                             (mapcar (lambda (story) (plist-get story :key))
                                     wave))
                           waves)
                   '(("a") ("b" "c") ("d")))))
  ;; Given out of order, the waves are the same, each in the order given.
  (let ((waves (rat-kingdom-plan-waves
                (rat-kingdom-epic-check rat-kingdom-epic-test--diamond))))
    (should (equal (mapcar (lambda (wave)
                             (mapcar (lambda (story) (plist-get story :key))
                                     wave))
                           waves)
                   '(("a") ("b" "c") ("d")))))
  ;; A story waits for the latest wave of those it depends on.
  (let ((waves (rat-kingdom-plan-waves
                (rat-kingdom-epic-check
                 "[{\"key\":\"x\",\"title\":\"X\",\"description\":\"X.\",
                    \"depends_on\":[\"a\",\"z\"]},
                   {\"key\":\"a\",\"title\":\"A\",\"description\":\"A.\"},
                   {\"key\":\"y\",\"title\":\"Y\",\"description\":\"Y.\"},
                   {\"key\":\"z\",\"title\":\"Z\",\"description\":\"Z.\",
                    \"depends_on\":[\"y\"]}]"))))
    (should (equal (mapcar (lambda (wave)
                             (mapcar (lambda (story) (plist-get story :key))
                                     wave))
                           waves)
                   '(("a" "y") ("z") ("x"))))))

;;;; The surface, as data

(ert-deftest rat-kingdom-plan-test-surface-data ()
  (let* ((stories (cl-sort (rat-kingdom-epic-check
                            rat-kingdom-plan-test--diamond)
                           #'< :key (lambda (story) (plist-get story :index))))
         (messages (rat-kingdom-plan-surface "Epic plan: Plan" "demo" "Plan"
                                             "The *goal*." stories))
         (bodies (mapcar #'rat-kingdom-plan-test--body messages))
         (components (append (gethash "components"
                                      (cdr (assoc "updateComponents" bodies)))
                             nil))
         (data (gethash "value" (cdr (assoc "updateDataModel" bodies))))
         (ids (mapcar (lambda (c) (gethash "id" c)) components)))
    (cl-flet ((component (id) (cl-find id components
                                       :key (lambda (c) (gethash "id" c))
                                       :test #'equal))
              (bound (c property) (gethash "path" (gethash property c))))
      (should (equal (mapcar #'car bodies)
                     '("createSurface" "updateComponents" "updateDataModel")))
      (dolist (body bodies)
        (should (equal (gethash "surfaceId" (cdr body)) "Epic plan: Plan")))
      (should (equal (gethash "catalogId" (cdr (car bodies)))
                     (rat-kingdom-plan--catalog)))
      ;; It serializes, with no nil left in it.
      (dolist (message messages)
        (should (json-serialize message)))
      ;; Every id is used once, and every child named is there.
      (should (equal (length ids) (length (delete-dups (copy-sequence ids)))))
      (dolist (c components)
        (dolist (child (append (gethash "children" c)
                               (and (gethash "child" c)
                                    (list (gethash "child" c)))
                               nil))
          (should (member child ids))))
      (should (equal (gethash "text" (component "heading")) "Epic plan: Plan"))
      (should (equal (bound (component "header") "text") "/header"))
      (let ((header (gethash "header" data)))
        (should (string-search "demo" header))
        (should (string-search "Plan" header))
        (should (string-search "The *goal*." header)))
      ;; A Section per wave, in order, each holding its stories' cards.
      (should (equal (append (gethash "children" (component "root")) nil)
                     '("heading" "header" "wave-1" "wave-2" "wave-3"
                       "options" "buttons" "back" "result")))
      (should (equal (mapcar (lambda (n)
                               (gethash "title"
                                        (component (format "wave-%d" n))))
                             '(1 2 3))
                     '("Wave 1: a" "Wave 2: b, c" "Wave 3: d")))
      (should (equal (append (gethash "children" (component "wave-2-stories"))
                             nil)
                     '("story-1-card" "story-2-card")))
      ;; Each story: include, title, description, what it depends on,
      ;; and pickers for the agent and the workflow, bound to its data.
      (should (equal (gethash "component" (component "story-1-include"))
                     "CheckBox"))
      (should (equal (bound (component "story-1-include") "value")
                     "/stories/1/include"))
      (should (equal (bound (component "story-1-title") "value")
                     "/stories/1/title"))
      (should (equal (gethash "variant" (component "story-1-description"))
                     "longText"))
      (should (equal (gethash "text" (component "story-3-depends"))
                     "Depends on: b, c"))
      (should (equal (gethash "text" (component "story-0-depends"))
                     "Depends on nothing"))
      (should (equal (gethash "component" (component "story-1-agent"))
                     "Picker"))
      (should (equal (bound (component "story-1-agent") "options") "/agents"))
      (should (equal (bound (component "story-2-workflow") "value")
                     "/stories/2/workflow"))
      ;; The proposed values are selected; blank means the default.
      (let ((entries (append (gethash "stories" data) nil)))
        (should (equal (mapcar (lambda (e) (gethash "key" e)) entries)
                       '("a" "b" "c" "d")))
        (should (cl-every (lambda (e) (eq (gethash "include" e) t)) entries))
        (should (equal (mapcar (lambda (e) (gethash "agent" e)) entries)
                       '("" "codex" "" "")))
        (should (equal (mapcar (lambda (e) (gethash "workflow" e)) entries)
                       '("" "" "story" "")))
        (should (equal (gethash "title" (nth 3 entries)) "Join")))
      (should (equal (mapcar (lambda (o) (gethash "value" o))
                             (gethash "agents" data))
                     (cons "" (rat-kingdom-agent-names))))
      (should (member "story-lite"
                      (mapcar (lambda (o) (gethash "value" o))
                              (gethash "workflows" data))))
      ;; Options: not started by default, no feature branch, no limit.
      (should (eq (gethash "start" (gethash "options" data)) :false))
      (should (eq (gethash "featureBranch" (gethash "options" data)) :false))
      (should (equal (gethash "maxParallel" (gethash "options" data)) ""))
      (should (equal (bound (component "start") "value") "/options/start"))
      (should (equal (append (gethash "children" (component "options-column"))
                             nil)
                     '("start" "feature-branch" "feature-branch-note"
                       "max-parallel")))
      (should (equal (gethash "component" (component "feature-branch"))
                     "CheckBox"))
      (should (equal (gethash "label" (component "feature-branch"))
                     "Feature branch: land the epic as one unit"))
      (should (equal (bound (component "feature-branch") "value")
                     "/options/featureBranch"))
      (should (string-prefix-p "Applies when the epic is started"
                               (gethash "text"
                                        (component "feature-branch-note"))))
      ;; Approve sends the stories and options; Send back the notes.
      (let ((event (gethash "event" (gethash "action" (component "approve")))))
        (should (equal (gethash "name" event) "approve"))
        (should (equal (gethash "path" (gethash "stories"
                                                (gethash "context" event)))
                       "/stories"))
        (should (equal (gethash "path" (gethash "options"
                                                (gethash "context" event)))
                       "/options")))
      (should (equal (gethash "name" (gethash "event"
                                              (gethash "action"
                                                       (component "send-back"))))
                     "send_back"))
      (should (equal (gethash "name" (gethash "event"
                                              (gethash "action"
                                                       (component "cancel"))))
                     "cancel"))
      (should (equal (bound (component "buttons") "visible") "/open")))))

;;;; epic_propose

(ert-deftest rat-kingdom-plan-test-propose-shows-and-creates-nothing ()
  (rat-kingdom-plan-test-with-stubs (space fake)
    (let ((text (rat-kingdom-king-test--ok
                 "epic_propose" '(repo . "demo") '(title . "Plan")
                 '(description . "The goal, judged as a whole.")
                 (cons 'stories (rat-kingdom-epic-test--json
                                 rat-kingdom-plan-test--diamond)))))
      (should (string-prefix-p "Shown to the user in the plan surface" text))
      (should (string-search "you'll be told what they decide. Do not call \
epic_create for this plan yourself." text))
      (should (string-search "4 stories in 3 waves" text)))
    (should (equal rat-kingdom-plan-test--shown '("Epic plan: Plan")))
    (should (rat-kingdom-plan-test--data))
    ;; Nothing is created, started or told before the user decides.
    (should-not (rat-kingdom-plan-test--creates fake))
    (should-not (rat-kingdom-story-list space))
    (should-not (rat-kingdom-king-test--news space))
    ;; A plan with a problem is not shown.
    (setq rat-kingdom-plan-test--shown nil)
    (let ((answer (rat-kingdom-plan-test--propose
                   "[{\"key\":\"a\",\"title\":\"A\",\"description\":\"A.\",
                      \"depends_on\":[\"zz\"]}]")))
      (should (cdr answer))
      (should (string-search "it depends on zz, which is not a key" (car answer))))
    (should-not rat-kingdom-plan-test--shown)
    (should-not (rat-kingdom-plan-test--creates fake))))

(ert-deftest rat-kingdom-plan-test-propose-without-a2ui ()
  (rat-kingdom-plan-test-with-stubs (space fake)
    (cl-letf (((symbol-function 'rat-kingdom-plan-a2ui-p) #'ignore))
      (let ((answer (rat-kingdom-plan-test--propose)))
        (should (cdr answer))
        (should (string-search "The epic plan surface is not available: a2ui \
is not installed" (car answer)))
        (should (string-search "Agree the plan with the user in conversation \
instead, and create it with epic_create once they agree" (car answer))))
      (should-error (rat-kingdom-plan-show space "demo" "Plan" "Goal."
                                           (rat-kingdom-epic-test--json
                                            rat-kingdom-plan-test--diamond))))
    (should-not rat-kingdom-plan-test--shown)
    (should-not rat-kingdom-plan-test--sent)
    (should-not (rat-kingdom-plan-test--creates fake))))

(ert-deftest rat-kingdom-plan-test-propose-is-a-king-tool ()
  (should (member "epic_propose" (rat-kingdom-mcp-tool-names 'king)))
  (should-not (member "epic_propose" (rat-kingdom-mcp-tool-names 'rat)))
  (let ((text (replace-regexp-in-string "[ \n]+" " "
                                        (rat-kingdom-king-instructions))))
    (should (string-search "To plan an epic, prefer `epic_propose`" text))
    (should (string-search "Use `epic_create` directly only when the user has \
agreed to the plan in conversation" text))
    (should (string-search "unless they started it from the plan surface"
                           text))))

;;;; Approve

(ert-deftest rat-kingdom-plan-test-approve-with-edits ()
  (rat-kingdom-plan-test-with-stubs (space fake)
    (should-not (cdr (rat-kingdom-plan-test--propose)))
    ;; A new title for a, c on codex, b back on the default agent, and
    ;; the leaf d left out.
    (rat-kingdom-plan-test--press
     "approve" (rat-kingdom-plan-test--context
                '("a" "title") "  Base, edited  "
                '("a" "description") "The base, edited."
                '("b" "agent") ""
                '("c" "agent") "codex"
                '("d" "include") :false))
    (should (equal (rat-kingdom-plan-test--creates fake)
                   '(("Plan" nil)
                     ("Base, edited" nil)
                     ("Left" nil)
                     ("Right" ("rk-agent:codex" "rk-workflow:story")))))
    (should (equal (plist-get (rat-kingdom-task-test--task fake "T-2")
                              :description)
                   "The base, edited."))
    (should (equal (plist-get (rat-kingdom-task-test--task fake "T-2")
                              :priority)
                   1))
    (should (equal (plist-get (rat-kingdom-task-test--task fake "T-4")
                              :depends-on)
                   '("T-2")))
    (should-not (rat-kingdom-story-list space))
    ;; The surface says what was made, and the plan is closed.
    (should (string-search "Created the epic T-1** in demo with 3 tasks: \
T-2 (a), T-3 (b), T-4 (c)."
                           (rat-kingdom-plan-test--value "/result")))
    (should (string-search "Not started"
                           (rat-kingdom-plan-test--value "/result")))
    (should (equal (rat-kingdom-plan-test--value "/resultTone") "success"))
    (should (eq (rat-kingdom-plan-test--value "/open") :false))
    ;; The king is told.
    (let ((news (rat-kingdom-king-test--news space)))
      (should (eql (length news) 1))
      (should (string-prefix-p "The user approved the epic plan Plan in the \
plan surface: created epic T-1 with 3 tasks; started: no." (car news)))
      (should (string-search "Tasks: T-2 (a), T-3 (b), T-4 (c)." (car news)))
      (should (string-search "Left out by the user: d." (car news)))
      (should (string-search "Ask the user before you call epic_start"
                             (car news))))
    ;; A second press does nothing.
    (rat-kingdom-plan-test--press "approve" (rat-kingdom-plan-test--context))
    (rat-kingdom-plan-test--press "cancel")
    (should (eql (length (rat-kingdom-plan-test--creates fake)) 4))
    (should (eql (length (rat-kingdom-king-test--news space)) 1))))

(ert-deftest rat-kingdom-plan-test-approve-refuses-a-dropped-dependency ()
  (rat-kingdom-plan-test-with-stubs (space fake)
    (should-not (cdr (rat-kingdom-plan-test--propose)))
    ;; d depends on b, which is left out.
    (rat-kingdom-plan-test--press
     "approve" (rat-kingdom-plan-test--context '("b" "include") :false))
    (should-not (rat-kingdom-plan-test--creates fake))
    (should-not (rat-kingdom-king-test--news space))
    (let ((result (rat-kingdom-plan-test--value "/result")))
      (should (string-prefix-p "Nothing was created." result))
      (should (string-search "story d depends on b, which is left out; \
include it or leave out d too" result)))
    (should (equal (rat-kingdom-plan-test--value "/resultTone") "error"))
    (should (eq (rat-kingdom-plan-test--value "/open") t))
    ;; So do a blank title, a bad limit, and leaving everything out.
    (dolist (case '(((("a" "title") "  ") "story a: its title is blank")
                    ((("maxParallel") "two") "Max parallel must be a whole \
number")
                    ((("a" "include") :false ("b" "include") :false
                      ("c" "include") :false ("d" "include") :false)
                     "every story is left out")))
      (rat-kingdom-plan-test--press
       "approve" (apply #'rat-kingdom-plan-test--context (car case)))
      (should (string-search (cadr case)
                             (rat-kingdom-plan-test--value "/result")))
      (should-not (rat-kingdom-plan-test--creates fake)))
    ;; The plan is still open: leaving d out too, it is created.
    (rat-kingdom-plan-test--press
     "approve" (rat-kingdom-plan-test--context '("b" "include") :false
                                               '("d" "include") :false))
    (should (equal (mapcar #'car (rat-kingdom-plan-test--creates fake))
                   '("Plan" "Base" "Right")))
    (should (string-search "created epic T-1 with 2 tasks"
                           (car (rat-kingdom-king-test--news space))))))

(ert-deftest rat-kingdom-plan-test-approve-and-start ()
  (rat-kingdom-plan-test-with-stubs (space fake)
    (should-not (cdr (rat-kingdom-plan-test--propose)))
    (let ((started nil))
      (advice-add 'rat-kingdom-epic-start :before
                  (lambda (&rest args) (push args started))
                  '((name . rat-kingdom-plan-test)))
      (unwind-protect
          (rat-kingdom-plan-test--press
           "approve" (rat-kingdom-plan-test--context
                      '("start") t '("maxParallel") " 1 "))
        (advice-remove 'rat-kingdom-epic-start 'rat-kingdom-plan-test))
      (should (equal started `((,space "demo" "T-1" 1 nil)))))
    (should (eql (length (rat-kingdom-plan-test--creates fake)) 5))
    (let ((record (rat-kingdom-epic-record space "T-1" "demo")))
      (should (equal (plist-get (plist-get record :payload) :state) "running"))
      (should (eql (plist-get (plist-get record :payload) :max-parallel) 1)))
    ;; a's story is started.
    (should (equal (mapcar (lambda (story)
                             (plist-get (plist-get story :payload) :task))
                           (rat-kingdom-story-list space))
                   '("T-2")))
    (let ((result (rat-kingdom-plan-test--value "/result")))
      (should (string-search "Started, at most 1 at once; stories started \
now: S-" result)))
    (let ((news (car (rat-kingdom-king-test--news space))))
      (should (string-prefix-p "The user approved the epic plan Plan in the \
plan surface: created epic T-1 with 4 tasks; started: yes." news))
      (should (string-search "The user started it from the plan surface, \
with at most 1 stories at once, so do not ask again" news))
      (should (string-search "It has no feature branch" news)))
    (should-not (plist-get (plist-get (rat-kingdom-epic-record space "T-1"
                                                               "demo")
                                      :payload)
                           :branch))))

(ert-deftest rat-kingdom-plan-test-approve-and-start-with-a-feature-branch ()
  (rat-kingdom-plan-test-with-stubs (space fake)
    (should-not (cdr (rat-kingdom-plan-test--propose)))
    (let ((path (plist-get (rat-kingdom-repo-get space "demo") :path))
          (started nil))
      (advice-add 'rat-kingdom-epic-start :before
                  (lambda (&rest args) (push args started))
                  '((name . rat-kingdom-plan-test)))
      (unwind-protect
          (rat-kingdom-plan-test--press
           "approve" (rat-kingdom-plan-test--context
                      '("start") t '("featureBranch") t))
        (advice-remove 'rat-kingdom-epic-start 'rat-kingdom-plan-test))
      (should (equal started `((,space "demo" "T-1" nil t))))
      (let ((payload (plist-get (rat-kingdom-epic-record space "T-1" "demo")
                                :payload)))
        (should (equal (plist-get payload :state) "running"))
        (should (equal (plist-get payload :branch) "rk/epic/T-1")))
      (should (equal (rat-kingdom-git-rev path "rk/epic/T-1")
                     (rat-kingdom-git-rev path "rk/integration"))))
    (should (string-search "Started on its feature branch rk/epic/T-1"
                           (rat-kingdom-plan-test--value "/result")))
    (let ((news (car (rat-kingdom-king-test--news space))))
      (should (string-search "started: yes." news))
      (should (string-search "so do not ask again" news))
      (should (string-search "It has a feature branch, rk/epic/T-1: its \
stories merge into it, and it lands on the target after one check and \
your epic_verdict." news))
      (should-not (string-search "pass feature_branch" news)))))

(ert-deftest rat-kingdom-plan-test-approve-feature-branch-without-start ()
  (rat-kingdom-plan-test-with-stubs (space fake)
    (should-not (cdr (rat-kingdom-plan-test--propose)))
    (let ((path (plist-get (rat-kingdom-repo-get space "demo") :path))
          (started nil))
      (advice-add 'rat-kingdom-epic-start :before
                  (lambda (&rest args) (push args started))
                  '((name . rat-kingdom-plan-test)))
      (unwind-protect
          (rat-kingdom-plan-test--press
           "approve" (rat-kingdom-plan-test--context '("featureBranch") t))
        (advice-remove 'rat-kingdom-epic-start 'rat-kingdom-plan-test))
      ;; Created, not started, and no branch made.
      (should-not started)
      (should (eql (length (rat-kingdom-plan-test--creates fake)) 5))
      (should-not (ignore-errors (rat-kingdom-git-rev path "rk/epic/T-1"))))
    (should (string-search "it is told to give it a feature branch"
                           (rat-kingdom-plan-test--value "/result")))
    (let ((news (car (rat-kingdom-king-test--news space))))
      (should (string-search "started: no." news))
      (should (string-search "Ask the user before you call epic_start. The \
user wants a feature branch: pass feature_branch to epic_start when you \
start it." news)))))

;;;; Send back and Cancel

(ert-deftest rat-kingdom-plan-test-send-back ()
  (rat-kingdom-plan-test-with-stubs (space fake)
    (should-not (cdr (rat-kingdom-plan-test--propose)))
    (rat-kingdom-plan-test--press
     "send_back" (rat-kingdom-plan--obj "notes" "Split b in two.\n"))
    (should-not (rat-kingdom-plan-test--creates fake))
    (should (equal (rat-kingdom-king-test--news space)
                   '("The user sent the epic plan Plan back with notes: Split \
b in two.\nNothing was created. Revise the plan and propose it again with \
epic_propose.")))
    (should (eq (rat-kingdom-plan-test--value "/open") :false))
    (should (string-prefix-p "Sent back to the king"
                             (rat-kingdom-plan-test--value "/result")))
    ;; It is decided: Approve does nothing now.
    (rat-kingdom-plan-test--press "approve" (rat-kingdom-plan-test--context))
    (should-not (rat-kingdom-plan-test--creates fake))
    ;; Proposed again, the same title gets a fresh surface.
    (should-not (cdr (rat-kingdom-plan-test--propose)))
    (should (equal rat-kingdom-plan-test--deleted '("Epic plan: Plan")))
    (should (eq (plist-get (gethash "Epic plan: Plan" rat-kingdom-plan--plans)
                           :state)
                'open))
    (should (eql (length (rat-kingdom-king-test--news space)) 1))))

(ert-deftest rat-kingdom-plan-test-cancel ()
  (rat-kingdom-plan-test-with-stubs (space fake)
    (should-not (cdr (rat-kingdom-plan-test--propose)))
    (rat-kingdom-plan-test--press "cancel")
    (should (equal rat-kingdom-plan-test--deleted '("Epic plan: Plan")))
    (should-not (rat-kingdom-plan-test--creates fake))
    (should (equal (rat-kingdom-king-test--news space)
                   '("The user dismissed the epic plan Plan in the plan \
surface. Nothing was created.")))))

;;;; Reloading

(ert-deftest rat-kingdom-plan-test-reload ()
  (rat-kingdom-reload-test--isolated
    (let ((plans rat-kingdom-plan--plans)
          (a2ui (featurep 'a2ui)))
      (rat-kingdom-reload)
      (rat-kingdom-reload)
      (should (member "rat-kingdom-plan" rat-kingdom--files))
      (should (eq rat-kingdom-plan--plans plans))
      (should (eql (cl-count "epic_propose" rat-kingdom-mcp--tools
                             :key (lambda (tool) (plist-get tool :name))
                             :test #'equal)
                   1))
      ;; Reloading does not load a2ui.
      (should (eq (featurep 'a2ui) a2ui)))))

(ert-deftest rat-kingdom-plan-test-loading-does-not-need-a2ui ()
  ;; A fresh Emacs that cannot find a2ui loads rat-kingdom, and is told
  ;; plainly that the surface needs it.
  (let* ((directory (rat-kingdom--directory))
         (output
          (with-temp-buffer
            (call-process
             (expand-file-name invocation-name invocation-directory) nil t nil
             "-Q" "--batch" "-L" directory
             "--eval"
             "(progn (setq load-path (seq-remove (lambda (dir) \
(string-search \"a2ui\" dir)) load-path)) (require 'rat-kingdom) \
(princ (format \"loaded:%s a2ui:%s \" (featurep 'rat-kingdom) (featurep 'a2ui))) \
(princ (condition-case err (rat-kingdom-plan--require-a2ui) \
(error (error-message-string err)))))")
            (buffer-string))))
    (should (string-search "loaded:t a2ui:nil" output))
    (should (string-search "The epic plan surface needs a2ui" output))))

;;;; With the real a2ui

(defmacro rat-kingdom-plan-test-with-a2ui (vars &rest body)
  "Run BODY with VARS, (SPACE FAKE), an empty tracker and the real a2ui.
Skip the test if a2ui cannot be loaded.  The A2UI messages sent back
from a2ui are recorded in `rat-kingdom-plan-test--sent'."
  (declare (indent 1) (debug t))
  `(progn
     (skip-unless (rat-kingdom-plan-a2ui-p))
     (rat-kingdom-epic-test-with-empty-tracker ,vars
       (rat-kingdom-plan-test--isolated
         (let ((a2ui-message-functions
                (list (lambda (direction _session message _metadata)
                        (when (eq direction 'out)
                          (push message rat-kingdom-plan-test--sent))))))
           (unwind-protect
               (progn ,@body)
             (dolist (buffer (buffer-list))
               (when (string-prefix-p "*a2ui: Epic plan" (buffer-name buffer))
                 (kill-buffer buffer)))))))))

(defvar a2ui-message-functions)
(declare-function a2ui-set "a2ui-core" (surface path value &optional scope))
(declare-function a2ui-get "a2ui-core" (surface path &optional scope))
(declare-function a2ui-surface-component "a2ui-core" (surface id))
(declare-function a2ui-dispatch-action "a2ui-core"
                  (surface component &optional scope))

(defun rat-kingdom-plan-test--surface ()
  "Return the a2ui surface of the plan Plan."
  (a2ui-session-surface rat-kingdom-plan--session "Epic plan: Plan"))

(defun rat-kingdom-plan-test--click (id)
  "Press the button ID of the plan surface, through a2ui."
  (let ((surface (rat-kingdom-plan-test--surface)))
    (a2ui-dispatch-action surface (a2ui-surface-component surface id))))

(ert-deftest rat-kingdom-plan-test-a2ui-approve ()
  (rat-kingdom-plan-test-with-a2ui (space fake)
    (should-not (cdr (rat-kingdom-plan-test--propose)))
    (let ((surface (rat-kingdom-plan-test--surface)))
      (should surface)
      ;; It is drawn in a buffer of its own, and a2ui found nothing wrong.
      (should (get-buffer "*a2ui: Epic plan: Plan*"))
      (should-not rat-kingdom-plan-test--sent)
      (a2ui-set surface "/stories/0/title" "Base, edited")
      (a2ui-set surface "/stories/2/agent" "codex")
      (a2ui-set surface "/stories/3/include" :false)
      (rat-kingdom-plan-test--click "approve")
      (should (equal (rat-kingdom-plan-test--creates fake)
                     '(("Plan" nil)
                       ("Base, edited" nil)
                       ("Left" ("rk-agent:codex"))
                       ("Right" ("rk-agent:codex" "rk-workflow:story")))))
      (should (string-search "Created the epic T-1"
                             (a2ui-get surface "/result")))
      (should (eq (a2ui-get surface "/open") :false))
      (should (string-search "started: no"
                             (car (rat-kingdom-king-test--news space)))))
    ;; Only the action went out: no validation errors.
    (should (equal (mapcar (lambda (message)
                             (sort (hash-table-keys message) #'string<))
                           rat-kingdom-plan-test--sent)
                   '(("action" "version"))))))

(ert-deftest rat-kingdom-plan-test-a2ui-send-back-and-close ()
  (rat-kingdom-plan-test-with-a2ui (space fake)
    (should-not (cdr (rat-kingdom-plan-test--propose)))
    (a2ui-set (rat-kingdom-plan-test--surface) "/notes" "Smaller stories.")
    (rat-kingdom-plan-test--click "send-back")
    (should (string-search "back with notes: Smaller stories."
                           (car (rat-kingdom-king-test--news space))))
    (rat-kingdom-space-retract space '(message))
    ;; Proposed again, then closed by the user without a button.
    (should-not (cdr (rat-kingdom-plan-test--propose)))
    (should (rat-kingdom-plan-test--surface))
    (a2ui-delete-surface rat-kingdom-plan--session "Epic plan: Plan")
    (should (equal (rat-kingdom-king-test--news space)
                   '("The user dismissed the epic plan Plan in the plan \
surface. Nothing was created.")))
    (should-not (rat-kingdom-plan-test--creates fake))))

(provide 'rat-kingdom-plan-test)
;;; rat-kingdom-plan-test.el ends here
