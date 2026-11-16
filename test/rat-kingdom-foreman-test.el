;;; rat-kingdom-foreman-test.el --- Tests for the foreman -*- lexical-binding: t; -*-

;;; Commentary:

;; Batch tests for an epic's foreman: starting it, its tools and how far
;; they reach, news of the epic's stories going to it instead of the
;; king, and back to the king when it stops or dies, its own end with
;; the epic's, and recovery.  They use the diamond epic of
;; rat-kingdom-epic-dispatch-test.el, with the in-memory tracker, a real
;; repository and the backend that starts no agent; the tests play the
;; workers and the foreman.

;;; Code:

(require 'ert)
(require 'rat-kingdom)
(require 'rat-kingdom-foreman)
(require 'rat-kingdom-story-test)
(require 'rat-kingdom-task-test)
(require 'rat-kingdom-king-test)
(require 'rat-kingdom-epic-test)
(require 'rat-kingdom-epic-dispatch-test)
(require 'rat-kingdom-reload-test)

(defconst rat-kingdom-foreman-test--id "F-T-1"
  "The id of the foreman of the diamond epic T-1.")

(defmacro rat-kingdom-foreman-test-with-epic (vars &rest body)
  "Run BODY with VARS, (SPACE FAKE), and the diamond running as the epic T-1.
Its stories follow the workflow story, which the king, or its foreman,
reviews.  No foreman is running yet."
  (declare (indent 1) (debug t))
  `(rat-kingdom-epic-dispatch-test-with-diamond ,vars
     (let ((rat-kingdom-story-default-workflow "story")
           (rat-kingdom-king--retries (make-hash-table :test #'equal)))
       (rat-kingdom-epic-dispatch-test--start)
       (rat-kingdom-space-retract ,(car vars) '(message))
       ,@body)))

(defun rat-kingdom-foreman-test--start (space &rest arguments)
  "Start the foreman of T-1 in SPACE with `foreman_start' and ARGUMENTS.
Run reactions, so that its agent is started, and return the answer."
  (prog1 (apply #'rat-kingdom-king-test--ok "foreman_start" '(epic . "T-1")
                arguments)
    (rat-kingdom-reaction-run space)))

(defun rat-kingdom-foreman-test--call (tool &rest arguments)
  "Call TOOL as the foreman of T-1 with ARGUMENTS.  Return (TEXT . FAILED)."
  (apply #'rat-kingdom-story-test--call rat-kingdom-foreman-test--id tool
         arguments))

(defun rat-kingdom-foreman-test--ok (tool &rest arguments)
  "Call TOOL as the foreman with ARGUMENTS and return its text.
Fail the test if the call failed."
  (let ((answer (apply #'rat-kingdom-foreman-test--call tool arguments)))
    (should-not (cdr answer))
    (car answer)))

(defun rat-kingdom-foreman-test--refused (pattern tool &rest arguments)
  "Call TOOL as the foreman with ARGUMENTS; it must fail, matching PATTERN."
  (let ((answer (apply #'rat-kingdom-foreman-test--call tool arguments)))
    (should (cdr answer))
    (should (string-match-p pattern (car answer)))))

(defun rat-kingdom-foreman-test--news (space)
  "Return the texts of the messages waiting for the foreman of T-1 in SPACE."
  (mapcar (lambda (message) (plist-get (plist-get message :payload) :text))
          (rat-kingdom-space-scan
           space (list 'message :to rat-kingdom-foreman-test--id))))

(defun rat-kingdom-foreman-test--to-review (space task)
  "Play the worker of TASK's story in SPACE until it waits for a review.
Return the story's id."
  (let ((story (rat-kingdom-epic-dispatch-test--story space task)))
    (rat-kingdom-reaction-run space)
    (rat-kingdom-story-test--work space story (format "%s.txt" task))
    (rat-kingdom-story-test--settle space story)
    (should (equal (rat-kingdom-story-test--get space story :awaiting)
                   "review"))
    story))

(defun rat-kingdom-foreman-test--second-epic (space)
  "Plan and start in SPACE a second epic, T-6, with one task, T-7.
Return the id of the story started for T-7."
  (should-not (cdr (rat-kingdom-king-test--call
                    "epic_create" '(repo . "demo") '(title . "Other")
                    '(description . "Another goal.")
                    (cons 'stories (rat-kingdom-epic-test--json
                                    "[{\"key\":\"x\",\"title\":\"Elsewhere\",
                                       \"description\":\"Other work.\"}]")))))
  (rat-kingdom-king-test--ok "epic_start" '(repo . "demo") '(epic . "T-6"))
  (rat-kingdom-reaction-run space)
  (or (rat-kingdom-epic-dispatch-test--story space "T-7")
      (error "No story for T-7")))

;;;; Starting

(ert-deftest rat-kingdom-foreman-test-start-makes-a-foreman-run ()
  (rat-kingdom-foreman-test-with-epic (space _fake)
    (let* ((rat-kingdom-default-agent 'codex)
           (answer (rat-kingdom-foreman-test--start space))
           (run (rat-kingdom-run-get space rat-kingdom-foreman-test--id))
           (prompt (rat-kingdom-story-test--prompt
                    rat-kingdom-foreman-test--id)))
      (should (string-search "Started the foreman F-T-1 (claude) for the epic \
T-1 (Plan)" answer))
      ;; A run of its own, in the role foreman, for the epic, in the
      ;; repository's checkout, running Claude Code whatever workers run.
      (should (equal (plist-get run :role) "foreman"))
      (should (equal (plist-get run :epic) "T-1"))
      (should (equal (plist-get run :repo) "demo"))
      (should-not (plist-get run :story))
      (should (equal (plist-get run :agent) "claude"))
      (should (equal (plist-get run :state) "working"))
      (should (equal (plist-get run :worktree)
                     (plist-get (rat-kingdom-repo-get space "demo") :path)))
      (should (rat-kingdom-run-live-p rat-kingdom-foreman-test--id))
      (should (equal (rat-kingdom-epic--payload
                      (rat-kingdom-epic-record space "T-1") :foreman)
                     rat-kingdom-foreman-test--id))
      ;; Its first prompt: the instructions, filled in, and the epic.
      (should (string-search "You are the foreman of the epic T-1 (Plan) in \
the repository demo" prompt))
      (should (string-search "The goal, judged as a whole." prompt))
      (should (string-search "never edit files" prompt))
      (should (string-search "Never push" prompt))
      (should (string-search "Epic T-1 in demo: Plan" prompt))
      (should (string-search "| T-2 | Base |" prompt))
      (should (string-search "report" prompt))
      (should-not (string-search "{" prompt))
      ;; One at a time.
      (let ((again (rat-kingdom-king-test--call "foreman_start"
                                                '(epic . "T-1"))))
        (should (cdr again))
        (should (string-search "already has a foreman running" (car again)))))))

(ert-deftest rat-kingdom-foreman-test-tools-are-the-foremans ()
  (rat-kingdom-foreman-test-with-epic (space _fake)
    (rat-kingdom-foreman-test--start space)
    (let ((names (rat-kingdom-mcp-tool-names 'foreman)))
      (should (equal (sort (copy-sequence names) #'string<)
                     (sort (list "status" "story_show" "story_diff" "verdict"
                                 "tell" "query" "task_create" "epic_retry"
                                 "story_start" "report")
                           #'string<)))
      (dolist (refused '("publish" "repo_add" "repo_sync" "epic_create"
                         "epic_start" "epic_cancel" "epic_verdict"
                         "foreman_start" "foreman_stop" "story_move"
                         "story_cancel" "fact_forget" "finish" "block"))
        (should-not (member refused names))
        (rat-kingdom-foreman-test--refused "unknown tool" refused))
      ;; The tools listed in its instructions are its own.
      (should (string-search (rat-kingdom-king-tool-names 'foreman)
                             (rat-kingdom-story-test--prompt
                              rat-kingdom-foreman-test--id))))
    ;; The king's tools are unchanged, with the two to start and stop one.
    (let ((names (rat-kingdom-mcp-tool-names 'king)))
      (dolist (name '("publish" "status" "verdict" "tell" "query"
                      "foreman_start" "foreman_stop"))
        (should (member name names)))
      (should-not (member "report" names)))
    ;; Its status is its epic's, with the lines of its stories.
    (let ((status (rat-kingdom-foreman-test--ok "status")))
      (should (string-search "Epic T-1 in demo: Plan" status))
      (should (string-search "foreman F-T-1 (claude, " status))
      (should (string-match-p "Its stories in progress:\n- S-[0-9a-f]+ \
\\[demo\\] ready" status))
      (should-not (string-search "Repositories:" status)))
    ;; Its query is the king's, read-only and unrestricted.
    (should (string-search "repo" (rat-kingdom-foreman-test--ok
                                   "query" '(category . "repo"))))))

(ert-deftest rat-kingdom-foreman-test-shown-in-status-and-epic-show ()
  (rat-kingdom-foreman-test-with-epic (space _fake)
    (should-not (string-search "foreman" (rat-kingdom-king-test--ok "status")))
    (rat-kingdom-foreman-test--start space '(agent . "codex"))
    ;; The fake backend has no :busy, so an agent is taken to be working.
    (should (string-search "    foreman F-T-1 (codex, working)"
                           (rat-kingdom-king-test--ok "status")))
    (should (string-search "It has a foreman F-T-1 (codex, working)."
                           (rat-kingdom-king-test--ok "epic_show"
                                                      '(epic . "T-1"))))
    (let ((rat-kingdom-run-backend (append (list :busy #'ignore)
                                           rat-kingdom-run-backend)))
      (should (string-search "foreman F-T-1 (codex, idle)"
                             (rat-kingdom-king-test--ok "status"))))
    (rat-kingdom-king-test--ok "foreman_stop" '(epic . "T-1"))
    (should (string-search "foreman F-T-1 (codex, stopped)"
                           (rat-kingdom-king-test--ok "status")))))

(ert-deftest rat-kingdom-foreman-test-start-needs-a-running-or-paused-epic ()
  (rat-kingdom-foreman-test-with-epic (space _fake)
    (let ((answer (rat-kingdom-king-test--call "foreman_start"
                                               '(epic . "T-9"))))
      (should (cdr answer))
      (should (string-search "has not been started" (car answer))))
    (let ((answer (rat-kingdom-king-test--call "foreman_start" '(epic . "T-1")
                                               '(agent . "nobody"))))
      (should (cdr answer))
      (should (string-search "nobody" (car answer))))
    (rat-kingdom-king-test--ok "epic_pause" '(epic . "T-1"))
    (rat-kingdom-foreman-test--start space)
    (rat-kingdom-king-test--ok "foreman_stop" '(epic . "T-1"))
    (rat-kingdom-king-test--ok "epic_cancel" '(epic . "T-1"))
    (let ((answer (rat-kingdom-king-test--call "foreman_start"
                                               '(epic . "T-1"))))
      (should (cdr answer))
      (should (string-search "is cancelled" (car answer))))))

(ert-deftest rat-kingdom-foreman-test-epic-start-with-a-foreman ()
  (rat-kingdom-epic-dispatch-test-with-diamond (space _fake)
    (let ((answer (rat-kingdom-epic-dispatch-test--start '(foreman . t))))
      (should (string-search "Started the foreman F-T-1 for it" answer)))
    (rat-kingdom-reaction-run space)
    (should (equal (plist-get (rat-kingdom-run-get space "F-T-1") :role)
                   "foreman"))
    (should (rat-kingdom-run-live-p "F-T-1"))))

;;;; News goes to the foreman

(ert-deftest rat-kingdom-foreman-test-reviews-go-to-the-foreman ()
  (rat-kingdom-foreman-test-with-epic (space fake)
    (rat-kingdom-foreman-test--start space)
    (let ((story (rat-kingdom-foreman-test--to-review space "T-2")))
      ;; The review is asked of the foreman, not of the king.
      (should (equal (rat-kingdom-foreman-test--news space)
                     (list (format "%s (Base) passed its check and waits for \
your review. Read story_diff and story_show for %s, then give a verdict."
                                   story story))))
      (should-not (rat-kingdom-king-test--news space))
      ;; It is given to the foreman between its turns, as the king's news
      ;; is to the king, and only then removed.
      (setq rat-kingdom-story-test--busy t)
      (should (zerop (rat-kingdom-king-deliver-to space "F-T-1")))
      (should (timerp (gethash "F-T-1" rat-kingdom-king--retries)))
      (should (rat-kingdom-foreman-test--news space))
      (setq rat-kingdom-story-test--busy nil)
      (rat-kingdom-king--on-idle "king")
      (should-not rat-kingdom-story-test--sent)
      (rat-kingdom-king--on-idle "F-T-1")
      (should (equal (caar rat-kingdom-story-test--sent) "F-T-1"))
      (should (string-prefix-p "[rat-kingdom] News from the engine:\n\n"
                               (cdar rat-kingdom-story-test--sent)))
      (should (string-search "waits for your review"
                             (cdar rat-kingdom-story-test--sent)))
      (should-not (rat-kingdom-foreman-test--news space))
      (should-not (gethash "F-T-1" rat-kingdom-king--retries))
      ;; The foreman reads it and passes it, and it is merged.
      (should (string-search "Base" (rat-kingdom-foreman-test--ok
                                     "story_show" (cons 'story story))))
      (should (string-search "T-2.txt" (rat-kingdom-foreman-test--ok
                                        "story_diff" (cons 'story story))))
      (should (equal (rat-kingdom-foreman-test--ok
                      "verdict" (cons 'story story) '(value . "pass"))
                     (format "Recorded. %s will be merged now." story)))
      (should (equal (plist-get (plist-get (rat-kingdom-foreman-test--verdict
                                            space story)
                                           :payload)
                                :value)
                     "pass"))
      (rat-kingdom-reaction-run space)
      (should-not (rat-kingdom-story-get space story))
      (rat-kingdom-epic-dispatch-test--drain
       (lambda () (equal (plist-get (rat-kingdom-task-test--task fake "T-2")
                                    :status)
                         "closed")))
      (rat-kingdom-reaction-run space)
      ;; The merge is the foreman's news too; the king hears nothing.
      (should (cl-some (lambda (text)
                         (string-search (format "%s (Base) is merged" story)
                                        text))
                       (rat-kingdom-foreman-test--news space)))
      (should-not (rat-kingdom-king-test--news space))
      ;; The next stories start by themselves.
      (should (equal (rat-kingdom-epic-dispatch-test--tasks-with-stories space)
                     '("T-3" "T-4"))))))

(defun rat-kingdom-foreman-test--verdict (space story)
  "Return the newest `verdict' tuple of STORY in SPACE, live or archived."
  (or (rat-kingdom-space-rd space (list 'verdict :identity story))
      (cl-find 'verdict (reverse (rat-kingdom-space-archived space story))
               :key (lambda (tuple) (plist-get tuple :category)))))

(ert-deftest rat-kingdom-foreman-test-tools-refuse-other-stories ()
  (rat-kingdom-foreman-test-with-epic (space _fake)
    (rat-kingdom-foreman-test--start space)
    (let ((other (rat-kingdom-foreman-test--second-epic space))
          (loose (rat-kingdom-story-start space "demo" "Loose" "Not of an \
epic.")))
      (rat-kingdom-reaction-run space)
      (dolist (story (list other loose))
        (dolist (call `(("story_show" (story . ,story))
                        ("story_diff" (story . ,story))
                        ("verdict" (story . ,story) (value . "pass"))
                        ("tell" (story . ,story) (text . "Stop."))))
          (apply #'rat-kingdom-foreman-test--refused
                 (format "%s is not a story of your epic T-1" story)
                 call)))
      ;; Nothing was written for them.
      (should-not (rat-kingdom-space-scan space '(message :to-story _)))
      (should-not (rat-kingdom-space-scan space '(verdict)))
      ;; A verdict on another epic's story waiting for review is refused
      ;; too, and the story keeps waiting.
      (rat-kingdom-reaction-run space)
      (rat-kingdom-story-test--work space other "other.txt")
      (rat-kingdom-story-test--settle space other)
      (should (equal (rat-kingdom-story-test--get space other :awaiting)
                     "review"))
      (rat-kingdom-foreman-test--refused "not a story of your epic"
                                         "verdict" (cons 'story other)
                                         '(value . "pass"))
      (should (equal (rat-kingdom-story-test--get space other :awaiting)
                     "review"))
      ;; Its review was the king's: T-6 has no foreman.
      (should (cl-some (lambda (text) (string-search other text))
                       (rat-kingdom-king-test--news space)))
      ;; An unknown story is refused as for the king.
      (rat-kingdom-foreman-test--refused "There is no story called S-0"
                                         "story_show" '(story . "S-0")))))

(ert-deftest rat-kingdom-foreman-test-tell-says-who-it-is-from ()
  (rat-kingdom-foreman-test-with-epic (space _fake)
    (rat-kingdom-foreman-test--start space)
    (let* ((story (rat-kingdom-epic-dispatch-test--story space "T-2"))
           (worker (rat-kingdom-story-test--get space story :run)))
      (rat-kingdom-reaction-run space)
      (should (string-search (format "Delivered now to worker %s" worker)
                             (rat-kingdom-foreman-test--ok
                              "tell" (cons 'story story)
                              '(text . "Use tabs."))))
      (let ((sent (car rat-kingdom-story-test--sent)))
        (should (equal (car sent) worker))
        (should (equal (cdr sent) "[rat-kingdom] Message from foreman F-T-1:
Use tabs."))))))

(ert-deftest rat-kingdom-foreman-test-task-create-is-in-its-epic ()
  (rat-kingdom-foreman-test-with-epic (space fake)
    (rat-kingdom-foreman-test--start space)
    (let ((answer (rat-kingdom-foreman-test--ok
                   "task_create" '(title . "Extra") '(description . "More.")
                   '(depends_on . "T-2")
                   ;; Not an argument it has: the parent is its epic.
                   '(parent . "T-99"))))
      (should (string-search "Created the task T-6 in demo: Extra. Epic: T-1. \
Depends on: T-2." answer)))
    (should (equal (car (rat-kingdom-foreman-test--writes fake))
                   '(depend "T-6" "T-2")))
    (should (equal (plist-get (rat-kingdom-task-test--task fake "T-6") :parent)
                   "T-1"))
    ;; A task of another epic is not one it may depend on.
    (rat-kingdom-foreman-test--refused "Nothing was created: T-0 is not of \
your epic T-1"
                                       "task_create" '(title . "Bad")
                                       '(description . "Bad.")
                                       '(depends_on . "T-0"))
    (should-not (rat-kingdom-task-test--task fake "T-7"))))

(defun rat-kingdom-foreman-test--writes (fake)
  "Return the creates and dependencies FAKE was asked for, newest first."
  (reverse (rat-kingdom-epic-test--writes fake)))

(ert-deftest rat-kingdom-foreman-test-story-start-only-for-its-tasks ()
  (rat-kingdom-foreman-test-with-epic (space _fake)
    (rat-kingdom-foreman-test--start space)
    (rat-kingdom-foreman-test--second-epic space)
    ;; Hold back dispatch, so that new tasks wait.
    (rat-kingdom-king-test--ok "epic_pause" '(epic . "T-1"))
    (rat-kingdom-king-test--ok "epic_pause" '(epic . "T-6"))
    (rat-kingdom-foreman-test--ok "task_create" '(title . "Now")
                                  '(description . "Do it now."))
    (rat-kingdom-king-test--ok "task_create" '(repo . "demo")
                               '(title . "Theirs") '(description . "Of T-6.")
                               '(parent . "T-6"))
    (rat-kingdom-king-test--ok "task_create" '(repo . "demo")
                               '(title . "Nobody's")
                               '(description . "Of no epic."))
    (rat-kingdom-foreman-test--refused "Missing argument: task" "story_start"
                                       '(title . "Loose")
                                       '(description . "No task."))
    ;; T-9 is the other epic's task, and T-10 is of no epic.
    (dolist (task '("T-9" "T-10"))
      (rat-kingdom-foreman-test--refused
       (format "%s is not a task of your epic T-1" task)
       "story_start" (cons 'task task))
      (should-not (rat-kingdom-epic-dispatch-test--story space task)))
    (let ((answer (rat-kingdom-foreman-test--ok "story_start"
                                                '(task . "T-8"))))
      (should (string-search "for the task T-8" answer))
      (should (string-search "as a story of the epic T-1" answer)))
    (let ((story (rat-kingdom-epic-dispatch-test--story space "T-8")))
      (should (equal (rat-kingdom-story-test--get space story :epic) "T-1")))))

(ert-deftest rat-kingdom-foreman-test-held-tasks-and-retry ()
  (rat-kingdom-foreman-test-with-epic (space _fake)
    (rat-kingdom-foreman-test--start space)
    (let ((story (rat-kingdom-epic-dispatch-test--story space "T-2")))
      ;; The king cancels the story; the held task is the foreman's news.
      (rat-kingdom-king-test--ok "story_cancel" (cons 'story story))
      (should (cl-some (lambda (text)
                         (string-search "Its task T-2 of the epic T-1 (Plan) \
is now held" text))
                       (rat-kingdom-foreman-test--news space)))
      (should-not (rat-kingdom-king-test--news space)))
    (rat-kingdom-foreman-test--second-epic space)
    (rat-kingdom-foreman-test--refused "T-6 is not your epic"
                                       "epic_retry" '(task . "T-7")
                                       '(epic . "T-6"))
    (should (string-search "The task T-2 of the epic T-1 (Plan) is no longer \
held."
                           (rat-kingdom-foreman-test--ok "epic_retry"
                                                         '(task . "T-2"))))
    (should-not (rat-kingdom-epic--held
                 (rat-kingdom-epic-record space "T-1")))))

(ert-deftest rat-kingdom-foreman-test-report-reaches-the-king ()
  (rat-kingdom-foreman-test-with-epic (space _fake)
    (rat-kingdom-foreman-test--start space)
    (should (string-search "Sent to the king"
                           (rat-kingdom-foreman-test--ok
                            "report" '(text . "Half of it is merged."))))
    (should (equal (rat-kingdom-king-test--news space)
                   '("[rat-kingdom] Report from the foreman of epic T-1 \
(Plan): Half of it is merged.")))
    (rat-kingdom-foreman-test--refused "needs some text" "report"
                                       '(text . "  "))
    ;; It reaches the king as its news does.
    (rat-kingdom-king-deliver space)
    (should (equal (caar rat-kingdom-story-test--sent) "king"))
    (should (string-search "Report from the foreman of epic T-1"
                           (cdar rat-kingdom-story-test--sent)))))

;;;; When the foreman or its epic ends

(ert-deftest rat-kingdom-foreman-test-stops-when-the-epic-is-done ()
  (rat-kingdom-epic-dispatch-test-with-diamond (space fake)
    ;; story-lite: merged without review, so the merges are its news.
    (rat-kingdom-epic-dispatch-test--start)
    (rat-kingdom-foreman-test--start space)
    (rat-kingdom-space-retract space '(message))
    (dolist (task '("T-2" "T-3" "T-4"))
      (rat-kingdom-epic-dispatch-test--merge space fake task))
    (should (rat-kingdom-run-live-p "F-T-1"))
    (should (cl-some (lambda (text) (string-search "(Base) is merged" text))
                     (rat-kingdom-foreman-test--news space)))
    (should-not (rat-kingdom-king-test--news space))
    (rat-kingdom-epic-dispatch-test--merge space fake "T-5")
    (rat-kingdom-epic-dispatch-test--drain
     (lambda () (equal (rat-kingdom-epic-dispatch-test--state space) "done")))
    ;; The epic is done: its foreman is stopped, and the king told.
    (should (equal (rat-kingdom-epic-dispatch-test--state space) "done"))
    (should-not (rat-kingdom-run-live-p "F-T-1"))
    (should (member "F-T-1" rat-kingdom-story-test--stopped))
    (should (equal (plist-get (rat-kingdom-run-get space "F-T-1") :state)
                   "stopped"))
    (let ((news (rat-kingdom-king-test--news space)))
      (should (cl-some (lambda (text) (string-prefix-p "Epic T-1 (Plan) is done"
                                                       text))
                       news))
      (should (member "The foreman F-T-1 of the epic T-1 (Plan) has stopped, \
as the epic is done." news))
      ;; What it had not read is the king's now: nothing is lost.
      (should (cl-some (lambda (text)
                         (string-search "(This was for the foreman F-T-1, \
which stopped when the epic was done before it read it.)" text))
                       news)))
    (should-not (rat-kingdom-foreman-test--news space))))

(ert-deftest rat-kingdom-foreman-test-stops-when-the-epic-is-cancelled ()
  (rat-kingdom-foreman-test-with-epic (space _fake)
    (rat-kingdom-foreman-test--start space)
    (rat-kingdom-king-test--ok "epic_cancel" '(epic . "T-1"))
    (should-not (rat-kingdom-run-live-p "F-T-1"))
    (should (member "The foreman F-T-1 of the epic T-1 (Plan) has stopped, \
as the epic is cancelled."
                    (rat-kingdom-king-test--news space)))
    (should-not (rat-kingdom-foreman-test--news space))))

(ert-deftest rat-kingdom-foreman-test-stop-hands-reviews-back ()
  (rat-kingdom-foreman-test-with-epic (space fake)
    (rat-kingdom-foreman-test--start space)
    (let ((first (rat-kingdom-foreman-test--to-review space "T-2")))
      (should (rat-kingdom-foreman-test--news space))
      (let ((answer (rat-kingdom-king-test--ok "foreman_stop"
                                               '(epic . "T-1"))))
        (should (string-search "Stopped the foreman F-T-1 of the epic T-1 \
(Plan). News of its stories comes to you again" answer))
        (should (string-search (format "Waiting for your review now: %s."
                                       first)
                               answer))
        (should (string-search "1 message that waited for the foreman will \
be given to you." answer)))
      (should (member "F-T-1" rat-kingdom-story-test--stopped))
      ;; The review it had not read is the king's now.
      (should-not (rat-kingdom-foreman-test--news space))
      (should (equal (rat-kingdom-king-test--news space)
                     (list (format "(This was for the foreman F-T-1, which \
was stopped before it read it.)
%s (Base) passed its check and waits for your review. Read story_diff and \
story_show for %s, then give a verdict." first first))))
      ;; The king passes it; the next reviews are the king's, with no note.
      (rat-kingdom-space-retract space '(message))
      (rat-kingdom-king-test--ok "verdict" (cons 'story first)
                                 '(value . "pass"))
      (rat-kingdom-reaction-run space)
      (rat-kingdom-epic-dispatch-test--drain
       (lambda () (equal (plist-get (rat-kingdom-task-test--task fake "T-2")
                                    :status)
                         "closed")))
      (rat-kingdom-reaction-run space)
      (rat-kingdom-space-retract space '(message))
      (let ((next (rat-kingdom-foreman-test--to-review space "T-3")))
        (should (equal (rat-kingdom-king-test--news space)
                       (list (format "%s (Left) passed its check and waits \
for your review. Read story_diff and story_show for %s, then give a verdict."
                                     next next)))))
      (should-not (rat-kingdom-foreman-test--news space))
      ;; Stopping it again is an error.
      (let ((answer (rat-kingdom-king-test--call "foreman_stop"
                                                 '(epic . "T-1"))))
        (should (cdr answer))
        (should (string-search "has no foreman running" (car answer)))))))

(ert-deftest rat-kingdom-foreman-test-a-dead-foreman-routes-to-the-king ()
  (rat-kingdom-foreman-test-with-epic (space _fake)
    (let ((rat-kingdom-space-change-functions
           (list #'rat-kingdom-foreman--on-change)))
      (rat-kingdom-foreman-test--start space)
      (let ((first (rat-kingdom-foreman-test--to-review space "T-2")))
        (should (rat-kingdom-foreman-test--news space))
        ;; Its session ends by itself.
        (rat-kingdom-run-exited "F-T-1")
        (should (equal (plist-get (rat-kingdom-run-get space "F-T-1") :state)
                       "exited"))
        (rat-kingdom-epic-dispatch-test--drain
         (lambda () (null (rat-kingdom-foreman-test--news space))))
        ;; What waited for it is the king's, and the king is told.
        (should-not (rat-kingdom-foreman-test--news space))
        (let ((news (rat-kingdom-king-test--news space)))
          (should (cl-some (lambda (text)
                             (string-prefix-p "(This was for the foreman \
F-T-1, which exited before it read it.)" text))
                           news))
          (should (member (format "The foreman F-T-1 of the epic T-1 (Plan) \
exited. News of the epic's stories comes to you again, and you review them, \
until foreman_start starts another. Waiting for your review now: %s." first)
                          news)))
        ;; News written now goes to the king, saying why.
        (rat-kingdom-space-retract space '(message))
        (rat-kingdom-king-test--ok "story_cancel" (cons 'story first))
        (let ((news (rat-kingdom-king-test--news space)))
          (should news)
          (should (cl-every (lambda (text)
                              (string-search "(This comes to you because the \
foreman F-T-1 of the epic T-1 exited; foreman_start starts another.)" text))
                            news)))
        (should-not (rat-kingdom-foreman-test--news space))
        ;; Another can be started.
        (rat-kingdom-foreman-test--start space)
        (should (rat-kingdom-run-live-p "F-T-1"))))))

;;;; Recovery

(ert-deftest rat-kingdom-foreman-test-taken-up-again-on-reconcile ()
  (rat-kingdom-foreman-test-with-epic (space _fake)
    (rat-kingdom-foreman-test--start space '(agent . "codex"))
    (rat-kingdom-run-update space "F-T-1" :session-id "foreman-session")
    (let ((story (rat-kingdom-foreman-test--to-review space "T-2")))
      ;; Emacs stops: the foreman's agent is gone, its run still working.
      (remhash "F-T-1" rat-kingdom-run--handles)
      (rat-kingdom-space-retract space '(message))
      (setq rat-kingdom-story-test--started nil)
      (let ((found (rat-kingdom-reconcile)))
        (should (member "F-T-1" (plist-get found :runs)))
        (should (equal (plist-get found :foremen) '("F-T-1"))))
      (rat-kingdom-reaction-run space)
      ;; It takes its session up again, with the same agent.
      (let ((run (car (cl-find "F-T-1" rat-kingdom-story-test--started
                               :key (lambda (entry)
                                      (plist-get (car entry) :id))
                               :test #'equal)))
            (prompt (rat-kingdom-story-test--prompt "F-T-1")))
        (should (equal (plist-get run :resume) "foreman-session"))
        (should (equal (plist-get run :agent) "codex"))
        (should (equal (plist-get run :role) "foreman"))
        (should (equal (plist-get run :epic) "T-1"))
        (should (string-prefix-p "[rat-kingdom] Your session was restarted; \
you are still the foreman of the epic T-1 (Plan)." prompt))
        (should (string-search (format "Waiting for your review now: %s."
                                       story)
                               prompt)))
      (should (rat-kingdom-run-live-p "F-T-1"))
      ;; Reconciling again changes nothing.
      (should-not (plist-get (rat-kingdom-reconcile) :foremen))
      ;; Its tools work again, and news goes to it again.
      (should (string-search "Recorded."
                             (rat-kingdom-foreman-test--ok
                              "verdict" (cons 'story story)
                              '(value . "fix") '(notes . "Again.")))))))

(ert-deftest rat-kingdom-foreman-test-not-taken-up-once-its-epic-ended ()
  (rat-kingdom-foreman-test-with-epic (space _fake)
    (rat-kingdom-foreman-test--start space)
    (rat-kingdom-run-update space "F-T-1" :session-id "foreman-session")
    (rat-kingdom-foreman-test--to-review space "T-2")
    (remhash "F-T-1" rat-kingdom-run--handles)
    ;; The epic ended while the foreman was cut off.
    (rat-kingdom-epic--update space "demo" "T-1"
                              (lambda (payload)
                                (plist-put payload :state "cancelled")))
    (setq rat-kingdom-story-test--started nil)
    (should-not (plist-get (rat-kingdom-reconcile) :foremen))
    (rat-kingdom-reaction-run space)
    (should-not (rat-kingdom-story-test--prompt "F-T-1"))
    (should (equal (plist-get (rat-kingdom-run-get space "F-T-1") :state)
                   "stopped"))
    ;; Its news is the king's.
    (should-not (rat-kingdom-foreman-test--news space))
    (should (cl-some (lambda (text)
                       (string-prefix-p "(This was for the foreman F-T-1" text))
                     (rat-kingdom-king-test--news space)))))

;;;; Reloading

(ert-deftest rat-kingdom-foreman-test-reload-keeps-one-of-each ()
  (rat-kingdom-reload-test--isolated
    (let ((rat-kingdom-king-route-functions
           (copy-sequence rat-kingdom-king-route-functions))
          (rat-kingdom-epic-ended-functions
           (copy-sequence rat-kingdom-epic-ended-functions)))
      (rat-kingdom-reload)
      (rat-kingdom-reload)
      (dolist (entry '((rat-kingdom-king-route-functions
                        . rat-kingdom-foreman--route)
                       (rat-kingdom-epic-ended-functions
                        . rat-kingdom-foreman--epic-ended)
                       (rat-kingdom-space-change-functions
                        . rat-kingdom-foreman--on-change)
                       (rat-kingdom-space-change-functions
                        . rat-kingdom-king--on-change)
                       (rat-kingdom-run-idle-functions
                        . rat-kingdom-king--on-idle)))
        (should (eql (cl-count (cdr entry) (symbol-value (car entry))) 1)))
      (should (member "rat-kingdom-foreman" rat-kingdom--files))
      (should (eql (length (rat-kingdom-mcp-tool-names 'foreman)) 10))
      (dolist (role '(king foreman))
        (should (rat-kingdom-reload-test--once-each
                 (rat-kingdom-mcp-tool-names role))))
      (dolist (name '("foreman_start" "foreman_stop"))
        (should (eql (cl-count name (rat-kingdom-mcp-tool-names 'king)
                               :test #'equal)
                     1))))))

(provide 'rat-kingdom-foreman-test)
;;; rat-kingdom-foreman-test.el ends here
