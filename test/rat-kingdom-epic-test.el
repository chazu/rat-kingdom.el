;;; rat-kingdom-epic-test.el --- Tests for planning epics -*- lexical-binding: t; -*-

;;; Commentary:

;; Batch tests for the king's `task_create' and `epic_create', and for
;; what they leave on tasks for `status' and `story_start'.  Most use
;; the in-memory tracker of rat-kingdom-task-test.el; those about what
;; br is asked, and about br failing partway, use the fake br of
;; rat-kingdom-story-test.el.  The tools are called over JSON-RPC, with
;; arguments parsed from JSON as the endpoint parses them.

;;; Code:

(require 'ert)
(require 'rat-kingdom-epic)
(require 'rat-kingdom-story-test)
(require 'rat-kingdom-task-test)
(require 'rat-kingdom-king-test)

(defun rat-kingdom-epic-test--json (text)
  "Return the JSON TEXT parsed as the tool endpoint parses arguments."
  (json-parse-string text :object-type 'alist :array-type 'list
                     :null-object nil :false-object nil))

(defconst rat-kingdom-epic-test--diamond
  "[{\"key\":\"d\",\"title\":\"Join\",\"description\":\"Join b and c.\",
     \"depends_on\":[\"b\",\"c\"]},
    {\"key\":\"b\",\"title\":\"Left\",\"description\":\"The left side.\",
     \"depends_on\":[\"a\"],\"agent\":\"codex\"},
    {\"key\":\"a\",\"title\":\"Base\",\"description\":\"The base.\",
     \"priority\":1},
    {\"key\":\"c\",\"title\":\"Right\",\"description\":\"The right side.\",
     \"depends_on\":[\"a\"],\"workflow\":\"story\"}]"
  "A diamond, given out of order: b and c depend on a, d on b and c.")

(defun rat-kingdom-epic-test--epic (stories)
  "Call epic_create as the king for demo with STORIES, a JSON text.
Return (TEXT . FAILED)."
  (rat-kingdom-king-test--call
   "epic_create" '(repo . "demo") '(title . "Plan")
   '(description . "The goal, judged as a whole.")
   (cons 'stories (rat-kingdom-epic-test--json stories))))

(defun rat-kingdom-epic-test--writes (fake)
  "Return the creates and dependencies FAKE was asked for, oldest first."
  (reverse (cl-remove-if-not (lambda (call) (memq (car call) '(create depend)))
                             (rat-kingdom-task-test-fake-calls fake))))

(defmacro rat-kingdom-epic-test-with-empty-tracker (vars &rest body)
  "Run BODY with VARS, (SPACE FAKE), as the tracker fixture has them.
The tracker starts with no tasks, and the king is running."
  (declare (indent 1) (debug t))
  `(rat-kingdom-task-test-with-tracker ,vars
     (setf (rat-kingdom-task-test-fake-tasks ,(cadr vars)) nil)
     (rat-kingdom-king-test--start ,(car vars))
     ,@body))

;;;; epic_create

(ert-deftest rat-kingdom-epic-test-diamond ()
  (rat-kingdom-epic-test-with-empty-tracker (space fake)
    (let ((text (rat-kingdom-king-test--ok
                 "epic_create" '(repo . "demo") '(title . "Plan")
                 '(description . "The goal, judged as a whole.")
                 (cons 'stories (rat-kingdom-epic-test--json
                                 rat-kingdom-epic-test--diamond)))))
      ;; The epic first, then each task after those it depends on, then
      ;; the dependencies, each from the task that waits.
      (should (equal (rat-kingdom-epic-test--writes fake)
                     '((create "Plan" :type "epic" :parent nil :labels nil
                               :priority nil)
                       (create "Base" :type nil :parent "T-1" :labels nil
                               :priority 1)
                       (create "Left" :type nil :parent "T-1"
                               :labels ("rk-agent:codex") :priority nil)
                       (create "Right" :type nil :parent "T-1"
                               :labels ("rk-workflow:story") :priority nil)
                       (create "Join" :type nil :parent "T-1" :labels nil
                               :priority nil)
                       (depend "T-3" "T-2")
                       (depend "T-4" "T-2")
                       (depend "T-5" "T-3")
                       (depend "T-5" "T-4"))))
      (should (equal (plist-get (rat-kingdom-task-test--task fake "T-1")
                                :description)
                     "The goal, judged as a whole."))
      (should (equal (plist-get (rat-kingdom-task-test--task fake "T-5")
                                :description)
                     "Join b and c."))
      (should (equal (mapcar (lambda (task) (plist-get task :id))
                             (rat-kingdom-task-children fake "T-1"))
                     '("T-2" "T-3" "T-4" "T-5")))
      (should (string-prefix-p "Created the epic T-1 in demo: Plan. Nothing \
has been started.\n\n| key | task | title | depends on | agent | workflow |\n"
                               text))
      (dolist (row '("| a | T-2 | Base | - | default (claude) | the repository's |"
                     "| b | T-3 | Left | a | codex | the repository's |"
                     "| c | T-4 | Right | a | default (claude) | story |"
                     "| d | T-5 | Join | b, c | default (claude) | the \
repository's |"))
        (should (string-search row text)))
      ;; In the order they were created.
      (should (< (string-search "| a |" text) (string-search "| b |" text)
                 (string-search "| c |" text) (string-search "| d |" text)))
      (should (string-search "Ready now: a (T-2)." text)))
    ;; Only a is available, and the epic never is.
    (should (equal (rat-kingdom-task-test--available space) '("T-2")))
    ;; Nothing was started.
    (should-not (rat-kingdom-story-list space))
    (should (equal (mapcar (lambda (entry) (plist-get (car entry) :id))
                           rat-kingdom-story-test--started)
                   '("king")))
    (should (string-search "- T-2 [demo] P1 task: Base (epic T-1)"
                           (rat-kingdom-king-test--ok "status")))
    ;; When a is closed, b and c are ready, and d still waits.
    (rat-kingdom-task-test--set fake "T-2" "closed")
    (rat-kingdom-task-project space "demo")
    (should (equal (sort (rat-kingdom-task-test--available space) #'string<)
                   '("T-3" "T-4")))
    (should (string-search "- T-3 [demo] P? task: Left (epic T-1, agent codex)"
                           (rat-kingdom-king-test--ok "status")))
    (rat-kingdom-task-test--set fake "T-3" "closed")
    (rat-kingdom-task-project space "demo")
    (should (equal (rat-kingdom-task-test--available space) '("T-4")))
    (rat-kingdom-task-test--set fake "T-4" "closed")
    (rat-kingdom-task-project space "demo")
    (should (equal (rat-kingdom-task-test--available space) '("T-5")))
    (should-not (rat-kingdom-reaction-failures space))))

(ert-deftest rat-kingdom-epic-test-validation-creates-nothing ()
  (rat-kingdom-epic-test-with-empty-tracker (space fake)
    (dolist (case
             '(("cycle"
                "[{\"key\":\"a\",\"title\":\"A\",\"description\":\"A.\",
                   \"depends_on\":[\"c\"]},
                  {\"key\":\"b\",\"title\":\"B\",\"description\":\"B.\",
                   \"depends_on\":[\"a\"]},
                  {\"key\":\"c\",\"title\":\"C\",\"description\":\"C.\",
                   \"depends_on\":[\"b\"]}]"
                "the dependencies have a cycle: a depends on c depends on b \
depends on a")
               ("self"
                "[{\"key\":\"a\",\"title\":\"A\",\"description\":\"A.\",
                   \"depends_on\":[\"a\"]}]"
                "the dependencies have a cycle: a depends on a")
               ("unknown key"
                "[{\"key\":\"a\",\"title\":\"A\",\"description\":\"A.\",
                   \"depends_on\":[\"zz\"]}]"
                "story a: it depends on zz, which is not a key of this plan")
               ("unknown agent"
                "[{\"key\":\"a\",\"title\":\"A\",\"description\":\"A.\",
                   \"agent\":\"gpt\"}]"
                "story a: there is no agent called gpt; there are: claude, codex")
               ("duplicate key"
                "[{\"key\":\"a\",\"title\":\"A\",\"description\":\"A.\"},
                  {\"key\":\"a\",\"title\":\"B\",\"description\":\"B.\"}]"
                "story a: the key a is used by more than one story")
               ("unknown workflow"
                "[{\"key\":\"a\",\"title\":\"A\",\"description\":\"A.\",
                   \"workflow\":\"nope\"}]"
                "story a: there is no workflow called nope")
               ("blank title"
                "[{\"key\":\"a\",\"title\":\" \",\"description\":\"A.\"}]"
                "story a: its title is blank")
               ("no key"
                "[{\"title\":\"A\",\"description\":\"A.\"}]"
                "story 1: it has no key")
               ("priority"
                "[{\"key\":\"a\",\"title\":\"A\",\"description\":\"A.\",
                   \"priority\":7}]"
                "story a: priority must be a whole number from 0 to 4, not 7")
               ("not an object"
                "[\"a\"]"
                "story 1 is not an object")))
      (let ((answer (rat-kingdom-epic-test--epic (nth 1 case))))
        (should (cdr answer))
        (should (string-search "Nothing was created" (car answer)))
        (unless (string-search (nth 2 case) (car answer))
          (ert-fail (list (car case) (car answer))))))
    ;; Every problem is named at once.
    (let ((answer (rat-kingdom-epic-test--epic
                   "[{\"key\":\"a\",\"title\":\"\",\"description\":\"A.\",
                      \"agent\":\"gpt\",\"depends_on\":[\"q\"]}]")))
      (should (cdr answer))
      (should (string-search "The plan has 3 problems" (car answer))))
    ;; The epic itself needs a title, and a repository with a tracker.
    (should (cdr (rat-kingdom-king-test--call
                  "epic_create" '(repo . "demo") '(title . " ")
                  '(description . "Goal")
                  (cons 'stories (rat-kingdom-epic-test--json
                                  rat-kingdom-epic-test--diamond)))))
    (let ((answer (rat-kingdom-king-test--call
                   "epic_create" '(repo . "nowhere") '(title . "Plan")
                   '(description . "Goal")
                   (cons 'stories (rat-kingdom-epic-test--json
                                   rat-kingdom-epic-test--diamond)))))
      (should (cdr answer))
      (should (string-search "No repository called nowhere" (car answer))))
    (should-not (rat-kingdom-epic-test--writes fake))
    (should-not (rat-kingdom-task-test-fake-tasks fake))
    (should-not (rat-kingdom-space-scan space '(available)))))

(ert-deftest rat-kingdom-epic-test-check ()
  ;; A plan already in order keeps it; one that is not is put in order,
  ;; the first given first among those that can go.
  (should (equal (mapcar (lambda (plan) (plist-get plan :key))
                         (rat-kingdom-epic-check
                          (rat-kingdom-epic-test--json
                           rat-kingdom-epic-test--diamond)))
                 '("a" "b" "c" "d")))
  ;; Stories may come as a JSON text, and dependencies as a string.
  (let ((plans (rat-kingdom-epic-check
                "[{\"key\":\"x\",\"title\":\"X\",\"description\":\"X.\",
                   \"depends_on\":\"y, z\"},
                  {\"key\":\"y\",\"title\":\"Y\",\"description\":\"Y.\",
                   \"priority\":\"0\"},
                  {\"key\":\"z\",\"title\":\"Z\",\"description\":\"Z.\"}]")))
    (should (equal (mapcar (lambda (plan) (plist-get plan :key)) plans)
                   '("y" "z" "x")))
    (should (equal (plist-get (car (last plans)) :depends-on) '("y" "z")))
    (should (eql (plist-get (car plans) :priority) 0)))
  (should-error (rat-kingdom-epic-check "[") :type 'error)
  (should-error (rat-kingdom-epic-check nil) :type 'error)
  (should (equal (rat-kingdom-epic--cycle '("a" "b" "c")
                                          (lambda (key)
                                            (pcase key
                                              ("a" '("b")) ("b" '("c"))
                                              ("c" '("b")))))
                 '("b" "c" "b")))
  (should-not (rat-kingdom-epic--cycle '("a" "b")
                                       (lambda (key)
                                         (and (equal key "b") '("a"))))))

(ert-deftest rat-kingdom-epic-test-br-calls ()
  (rat-kingdom-story-test-with-repo (space _path)
    (rat-kingdom-king-test--start space)
    (let ((before (length (rat-kingdom-story-test-br-calls
                           rat-kingdom-story-test--br)))
          (text (car (rat-kingdom-epic-test--epic
                      "[{\"key\":\"b\",\"title\":\"B\",\"description\":\"Do b\",
                         \"depends_on\":[\"a\"],\"priority\":0},
                        {\"key\":\"a\",\"title\":\"A\",\"description\":\"Do a\",
                         \"agent\":\"codex\",\"workflow\":\"story\"}]"))))
      (should (equal (nthcdr before (rat-kingdom-story-test-br-calls
                                     rat-kingdom-story-test--br))
                     '("create --title=Plan --description=The goal, judged as \
a whole. --type epic --json"
                       "create --title=A --description=Do a --parent demo-1 \
--labels=rk-agent:codex,rk-workflow:story --json"
                       "create --title=B --description=Do b --priority 0 \
--parent demo-1 --json"
                       ;; br dep add takes the task that waits first.
                       "dep add demo-3 demo-2 --json"
                       "ready --json")))
      (should (string-search "Created the epic demo-1 in demo: Plan." text))
      (should (string-search "| a | demo-2 | A | - | codex | story |" text))
      (should (string-search "| b | demo-3 | B | a | default (claude) | the \
repository's |" text))
      ;; The fake br reports nothing ready.
      (should (string-search "Ready now: none that the tracker reports" text)))))

(ert-deftest rat-kingdom-epic-test-br-fails-partway ()
  (rat-kingdom-story-test-with-repo (space _path)
    (rat-kingdom-king-test--start space)
    (let ((plan "[{\"key\":\"a\",\"title\":\"A\",\"description\":\"Do a\"},
                  {\"key\":\"b\",\"title\":\"B\",\"description\":\"Do b\",
                   \"depends_on\":[\"a\"]},
                  {\"key\":\"c\",\"title\":\"C\",\"description\":\"Do c\"}]")
          (fails-at (expand-file-name "create-fails-at"
                                      rat-kingdom-story-test--br)))
      ;; The third create, story b's, fails.
      (with-temp-file fails-at (insert "3"))
      (let ((answer (rat-kingdom-epic-test--epic plan)))
        (should (cdr answer))
        (should (string-search "The tracker failed while creating the task \
for story b: br create --title=B" (car answer)))
        (should (string-search "database is locked" (car answer)))
        (should (string-search "the epic demo-1, and the tasks demo-2 (story a)."
                               (car answer)))
        (should (string-search "br has no clean delete" (car answer)))
        (should (string-search "No dependencies were recorded." (car answer)))
        (should-not (string-search "demo-3" (car answer))))
      ;; No story c was created after the failure.
      (should-not (cl-find-if (lambda (call) (string-prefix-p "create --title=C"
                                                              call))
                              (rat-kingdom-story-test-br-calls
                               rat-kingdom-story-test--br)))
      ;; Now a dependency fails: every task is named.
      (delete-file fails-at)
      (with-temp-file (expand-file-name "dep-fails" rat-kingdom-story-test--br))
      (let ((answer (rat-kingdom-epic-test--epic plan)))
        (should (cdr answer))
        (should (string-search "while recording that b (demo-6) depends on a \
(demo-5)" (car answer)))
        (should (string-search "the epic demo-4, and the tasks demo-5 (story \
a), demo-6 (story b), demo-7 (story c)." (car answer)))
        (should (string-search "No dependencies were recorded." (car answer))))
      ;; The epic is the first create: if it fails, nothing was made.
      (delete-file (expand-file-name "dep-fails" rat-kingdom-story-test--br))
      (with-temp-file fails-at (insert "8"))
      (let ((answer (rat-kingdom-epic-test--epic plan)))
        (should (cdr answer))
        (should (string-search "while creating the epic" (car answer)))
        (should (string-suffix-p "Nothing was created." (car answer))))
      (should-not (rat-kingdom-story-list space)))))

;;;; task_create

(ert-deftest rat-kingdom-epic-test-task-create ()
  (rat-kingdom-task-test-with-tracker (space fake)
    (setf (rat-kingdom-task-test-fake-tasks fake)
          (append (rat-kingdom-task-test-fake-tasks fake)
                  (list (list :id "E-1" :title "Epic" :status "open"
                              :type "epic"))))
    (rat-kingdom-king-test--start space)
    ;; An epic with no tasks is ready in br, but never available.
    (should (equal (rat-kingdom-task-test--available space) '("T-1")))
    (let ((text (rat-kingdom-king-test--ok
                 "task_create" '(repo . "demo") '(title . "Third")
                 '(description . "Do the third thing.") '(priority . 1)
                 '(type . "feature") '(parent . "E-1")
                 '(depends_on . "T-1, T-2") '(agent . "codex")
                 '(workflow . "story"))))
      (should (equal text "Created the task T-4 in demo: Third. Epic: E-1. \
Depends on: T-1, T-2. Agent: codex. Workflow: story. It is not ready yet. \
Nothing has been started."))
      (should (equal (rat-kingdom-epic-test--writes fake)
                     '((create "Third" :type "feature" :parent "E-1"
                               :labels ("rk-agent:codex" "rk-workflow:story")
                               :priority 1)
                       (depend "T-4" "T-1")
                       (depend "T-4" "T-2"))))
      ;; The parent and every task depended on were looked up first.
      (dolist (id '("E-1" "T-1" "T-2"))
        (should (member (list 'show id) (rat-kingdom-task-test-fake-calls fake))))
      (let ((task (rat-kingdom-task-test--task fake "T-4")))
        (should (equal (rat-kingdom-task-agent task) "codex"))
        (should (equal (rat-kingdom-task-workflow task) "story"))
        (should (equal (plist-get task :depends-on) '("T-1" "T-2")))))
    ;; Ready once both are closed, with its epic and agent in status.
    (rat-kingdom-task-test--set fake "T-1" "closed")
    (rat-kingdom-task-test--set fake "T-2" "closed")
    (should (string-search "- T-4 [demo] P1 feature: Third (epic E-1, agent \
codex)"
                           (rat-kingdom-king-test--ok "status")))
    ;; One with nothing to wait for is ready at once.
    (should (string-suffix-p "It is ready now. Nothing has been started."
                             (rat-kingdom-king-test--ok
                              "task_create" '(repo . "demo") '(title . "Fifth")
                              '(description . "Go."))))
    (should (member "T-5" (rat-kingdom-task-test--available space)))
    (should-not (rat-kingdom-story-list space))))

(ert-deftest rat-kingdom-epic-test-task-create-checks-first ()
  (rat-kingdom-task-test-with-tracker (space fake)
    (rat-kingdom-king-test--start space)
    (dolist (case '(((agent . "gpt") "there is no agent called gpt")
                    ((workflow . "nope") "there is no workflow called nope")
                    ((parent . "E-9") "the parent E-9 is not in the tracker")
                    ((depends_on . "T-1 T-9") "the task T-9 is not in the tracker")
                    ((type . "story") "type must be one of task, bug, feature, \
chore")
                    ((priority . 9) "priority must be a whole number")))
      (let ((answer (rat-kingdom-king-test--call
                     "task_create" '(repo . "demo") '(title . "New")
                     '(description . "Do it.") (car case))))
        (should (cdr answer))
        (should (string-prefix-p "Error: Nothing was created: " (car answer)))
        (unless (string-search (cadr case) (car answer))
          (ert-fail (list case (car answer))))))
    (should-not (rat-kingdom-epic-test--writes fake))
    (should (eql (length (rat-kingdom-task-test-fake-tasks fake)) 2))))

;;;; story_start from a labelled task

(ert-deftest rat-kingdom-epic-test-story-start-takes-the-labels ()
  (rat-kingdom-task-test-with-tracker (space fake)
    (setf (rat-kingdom-task-test-fake-tasks fake)
          (append (rat-kingdom-task-test-fake-tasks fake)
                  (list (list :id "T-3" :title "Labelled" :description "Do it."
                              :status "open" :priority 2 :type "task"
                              :labels (rat-kingdom-task-labels "codex" "story"))
                        (list :id "T-4" :title "Also" :description "Again."
                              :status "open" :priority 2 :type "task"
                              :labels (rat-kingdom-task-labels "codex" nil)))))
    (let ((rat-kingdom-default-agent 'claude))
      (rat-kingdom-king-test--start space)
      (should (string-search "- T-3 [demo] P2 task: Labelled (agent codex)"
                             (rat-kingdom-king-test--ok "status")))
      (let* ((answer (rat-kingdom-king-test--ok "story_start" '(repo . "demo")
                                                '(task . "T-3")))
             (id (progn (string-match "Started \\(S-[0-9a-f]+\\)" answer)
                        (match-string 1 answer))))
        (should (string-search "with the workflow story and the agent codex \
(the workflow and agent from the task's labels)" answer))
        (should (equal (rat-kingdom-story-test--get space id :agent) "codex"))
        (should (equal (rat-kingdom-story-test--get space id :workflow) "story"))
        ;; Its worker runs Codex.
        (rat-kingdom-reaction-run space)
        (should (equal (rat-kingdom-story-test--agent (concat id ".1")) "codex")))
      ;; An agent given explicitly wins over the label.
      (let* ((answer (rat-kingdom-king-test--ok "story_start" '(repo . "demo")
                                                '(task . "T-4")
                                                '(agent . "claude")))
             (id (progn (string-match "Started \\(S-[0-9a-f]+\\)" answer)
                        (match-string 1 answer))))
        (should (string-search "and the agent claude. You" answer))
        (should (equal (rat-kingdom-story-test--get space id :agent) "claude"))
        (should (equal (rat-kingdom-story-test--get space id :workflow)
                       "story-lite"))))))

;;;; The tools as the king sees them

(ert-deftest rat-kingdom-epic-test-schema ()
  (let* ((tools (rat-kingdom-mcp-tool-list 'king))
         (epic (cl-find "epic_create" tools
                        :key (lambda (tool) (plist-get tool :name))
                        :test #'equal))
         (schema (plist-get epic :inputSchema))
         (stories (gethash "stories" (plist-get schema :properties)))
         (items (plist-get stories :items))
         (depends (gethash "depends_on" (plist-get items :properties))))
    (should (equal (plist-get schema :required)
                   ["repo" "title" "description" "stories"]))
    (should (equal (plist-get stories :type) "array"))
    (should (stringp (plist-get stories :description)))
    (should (equal (plist-get items :type) "object"))
    (should (equal (plist-get items :required) ["key" "title" "description"]))
    (should (equal (plist-get depends :type) "array"))
    (should (equal (plist-get depends :items) '(:type "string")))
    (should (equal (plist-get (gethash "priority" (plist-get items :properties))
                              :type)
                   "integer"))
    ;; It serializes to real JSON Schema.
    (let ((json (json-parse-string (json-serialize schema)
                                   :object-type 'alist :array-type 'list)))
      (should (equal (let-alist json .properties.stories.items.type) "object"))
      (should (equal (let-alist json
                       .properties.stories.items.properties.depends_on.items.type)
                     "string"))
      (should (equal (let-alist json .properties.stories.items.required)
                     '("key" "title" "description")))))
  ;; A plain argument is as it was.
  (should (equal (json-serialize
                  (rat-kingdom-mcp--schema
                   '((:name "a" :type string :description "A.")
                     (:name "b" :type integer :optional t :description "B."))))
                 (concat "{\"type\":\"object\",\"properties\":"
                         "{\"a\":{\"type\":\"string\",\"description\":\"A.\"},"
                         "\"b\":{\"type\":\"integer\",\"description\":\"B.\"}},"
                         "\"required\":[\"a\"]}")))
  ;; Both tools are the king's alone.
  (dolist (name '("task_create" "epic_create"))
    (should (member name (rat-kingdom-mcp-tool-names 'king)))
    (should-not (member name (rat-kingdom-mcp-tool-names 'rat)))))

(ert-deftest rat-kingdom-epic-test-instructions-list-the-tools ()
  (let ((rat-kingdom-mcp--tools (copy-sequence rat-kingdom-mcp--tools))
        (rat-kingdom-king-instructions rat-kingdom-king-instructions))
    (cl-flet ((flat (text) (replace-regexp-in-string "[ \n]+" " " text)))
      (let ((text (flat (rat-kingdom-king-instructions)))
            (names (rat-kingdom-mcp-tool-names 'king)))
        (should-not (string-search "{tools}" text))
        (should (string-search
                 (concat "Your tools are those of the rat-kingdom server: "
                         (string-join (butlast names) ", ") " and "
                         (car (last names)) ".")
                 text))
        (dolist (name '("status" "story_start" "publish" "task_create"
                        "epic_create"))
          (should (member name names)))
        ;; The paragraph on planning an epic.
        (should (string-search "propose its stories and the dependencies \
between them to the user first, and call `epic_create` only once they agree"
                               text))
        (should (string-search "they start nothing" text)))
      ;; A tool defined later is listed; a worker's is not.
      (rat-kingdom-mcp-define-tool "later" :description "Later."
                                   :roles '(king) :function #'ignore)
      (rat-kingdom-mcp-define-tool "rat_only" :description "Other."
                                   :roles '(rat) :function #'ignore)
      (let ((text (flat (rat-kingdom-king-instructions))))
        (should (string-search ", epic_create and later." text))
        (should-not (string-search "rat_only" text)))
      ;; Instructions with no place for the list are left as they are.
      (setq rat-kingdom-king-instructions "Be brief.")
      (should (equal (rat-kingdom-king-instructions) "Be brief.")))
    (let ((rat-kingdom-mcp--tools nil))
      (should (equal (rat-kingdom-king-tool-names) "none")))))

(ert-deftest rat-kingdom-epic-test-king-is-told-its-tools ()
  (rat-kingdom-story-test-with-repo (space _path)
    (rat-kingdom-king-test--start space)
    (let ((prompt (rat-kingdom-story-test--prompt "king")))
      (should (string-search "task_create and epic_create" prompt))
      (should-not (string-search "{tools}" prompt)))))

(provide 'rat-kingdom-epic-test)
;;; rat-kingdom-epic-test.el ends here
