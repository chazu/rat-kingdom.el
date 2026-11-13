;;; rat-kingdom-king-test.el --- Tests for the king -*- lexical-binding: t; -*-

;;; Commentary:

;; Batch tests for the king's run, its tools and the news it is given.
;; No agent is started: the fixture of rat-kingdom-story-test.el plays
;; the backend, and the tests call the king's tools over JSON-RPC.

;;; Code:

(require 'ert)
(require 'rat-kingdom-king)
(require 'rat-kingdom-story-test)
(require 'rat-kingdom-task-test)

(defun rat-kingdom-king-test--start (space)
  "Start the king in SPACE with the fake backend."
  (rat-kingdom-king-start space)
  (rat-kingdom-reaction-run space))

(defun rat-kingdom-king-test--call (tool &rest arguments)
  "Call TOOL as the king with ARGUMENTS.  Return (TEXT . FAILED)."
  (apply #'rat-kingdom-story-test--call "king" tool arguments))

(defun rat-kingdom-king-test--ok (tool &rest arguments)
  "Call TOOL as the king with ARGUMENTS and return its text.
Fail the test if the call failed."
  (let ((answer (apply #'rat-kingdom-king-test--call tool arguments)))
    (should-not (cdr answer))
    (car answer)))

(defun rat-kingdom-king-test--news (space)
  "Return the texts of the messages waiting for the king in SPACE."
  (mapcar (lambda (message) (plist-get (plist-get message :payload) :text))
          (rat-kingdom-space-scan space '(message :to "king"))))

(ert-deftest rat-kingdom-king-test-starts-and-resumes ()
  (rat-kingdom-story-test-with-repo (space _path)
    (rat-kingdom-king-test--start space)
    (let ((run (rat-kingdom-run-get space "king"))
          (prompt (rat-kingdom-story-test--prompt "king")))
      (should (equal (plist-get run :state) "working"))
      (should (equal (plist-get run :role) "king"))
      (should-not (plist-get run :story))
      (should-not (plist-get run :resume))
      (should (file-directory-p (plist-get run :worktree)))
      (should (string-search "You are the king" prompt))
      (should (string-search "- demo at " prompt))
      (should (string-search "Stories in progress:\n- none" prompt)))
    (should (rat-kingdom-run-live-p "king"))
    (should-error (rat-kingdom-king-start space))
    ;; Its session ends; started again, it takes that session up.
    (rat-kingdom-run-update space "king" :session-id "session-1")
    (rat-kingdom-run-exited "king")
    (should-not (rat-kingdom-run-live-p "king"))
    (setq rat-kingdom-story-test--started nil)
    (rat-kingdom-king-test--start space)
    (let ((run (car (car rat-kingdom-story-test--started)))
          (prompt (rat-kingdom-story-test--prompt "king")))
      (should (equal (plist-get run :resume) "session-1"))
      (should (string-search "Your session was restarted" prompt))
      (should-not (string-search "You are the king of" prompt)))
    ;; Asked for a fresh session, it gets one.
    (rat-kingdom-run-update space "king" :session-id "session-2")
    (rat-kingdom-run-exited "king")
    (setq rat-kingdom-story-test--started nil)
    (rat-kingdom-king-start space t)
    (rat-kingdom-reaction-run space)
    (should-not (plist-get (car (car rat-kingdom-story-test--started)) :resume))
    (should (string-search "You are the king of"
                           (rat-kingdom-story-test--prompt "king")))
    ;; The king's run is no story's worker.
    (should-not (rat-kingdom-story-list space))
    (should-not (rat-kingdom-reaction-failures space))))

(ert-deftest rat-kingdom-king-test-runs-a-story-with-its-tools ()
  (rat-kingdom-story-test-with-repo (space path)
    (rat-kingdom-king-test--start space)
    (should (string-search "story-lite:"
                           (rat-kingdom-king-test--ok "workflow_list")))
    ;; Starting a story passes on what the user should know.
    (with-temp-file (expand-file-name "scratch" path) (insert "x"))
    (let* ((answer (rat-kingdom-king-test--ok
                    "story_start" '(repo . "demo") '(title . "Add a file")
                    '(description . "Call it feature.txt.")
                    '(workflow . "story")))
           (id (progn (string-match "Started \\(S-[0-9a-f]+\\)" answer)
                      (match-string 1 answer))))
      (should id)
      (should (string-search "Warning: The checkout" answer))
      (should (string-search "uncommitted changes" answer))
      (delete-file (expand-file-name "scratch" path))
      (should (cdr (rat-kingdom-king-test--call
                    "story_start" '(repo . "nowhere") '(title . "T")
                    '(description . "D"))))
      (should (cdr (rat-kingdom-king-test--call
                    "story_start" '(repo . "demo") '(title . "T"))))
      (rat-kingdom-reaction-run space)
      (let ((status (rat-kingdom-king-test--ok "status")))
        (should (string-search (format "- %s [demo] ready (waiting for worker \
%s.1, working)" id id)
                               status))
        (should (string-search "Add a file" status)))
      (should (string-search "no commits of its own yet"
                             (rat-kingdom-king-test--ok "story_diff"
                                                        `(story . ,id))))
      (should (cdr (rat-kingdom-king-test--call "verdict" `(story . ,id)
                                                '(value . "pass"))))
      ;; The worker reports; the king is told a review is wanted.
      (rat-kingdom-story-test--work space id "feature.txt")
      (rat-kingdom-story-test--settle space id)
      (should (cl-some (lambda (text)
                         (string-search "waits for your review" text))
                       (rat-kingdom-king-test--news space)))
      (let ((show (rat-kingdom-king-test--ok "story_show" `(story . ,id)))
            (diff (rat-kingdom-king-test--ok "story_diff" `(story . ,id))))
        (should (string-search "waiting for review in step review" show))
        (should (string-search "Worker's summary: Added the file." show))
        (should (string-search "Check: pass (the repository has no check"
                               show))
        (should (string-search "Add feature.txt" diff))
        (should (string-search "+work" diff))
        (should (string-search "1 file changed" diff)))
      ;; A fix needs notes; with them the story goes back to a worker.
      (should (cdr (rat-kingdom-king-test--call "verdict" `(story . ,id)
                                                '(value . "fix"))))
      (should (string-search
               "goes back to a worker"
               (rat-kingdom-king-test--ok "verdict" `(story . ,id)
                                          '(value . "fix")
                                          '(notes . "Add a newline."))))
      (rat-kingdom-reaction-run space)
      (should (string-search "Add a newline."
                             (rat-kingdom-story-test--prompt
                              (concat id ".2"))))
      (rat-kingdom-story-test--work space id "second.txt")
      (rat-kingdom-story-test--settle space id)
      (should (string-search
               "will be merged"
               (rat-kingdom-king-test--ok "verdict" `(story . ,id)
                                          '(value . "pass"))))
      (rat-kingdom-story-test--settle space id)
      (should-not (rat-kingdom-story-get space id))
      (should (equal (rat-kingdom-story-test--git
                      path "show" "rk/integration:second.txt")
                     "work"))
      ;; The verdict is recorded as the king's.
      (should (cl-find-if (lambda (op)
                            (and (eq (plist-get op :category) 'verdict)
                                 (eq (plist-get op :op) 'out)
                                 (equal (plist-get op :actor) "king")))
                          (rat-kingdom-space-ops space)))
      ;; A finished story can still be shown and its diff read.
      (let ((show (rat-kingdom-king-test--ok "story_show" `(story . ,id))))
        (should (string-search "(archived)" show))
        (should (string-search "Merged into rk/integration at" show)))
      (should (string-search "second.txt"
                             (rat-kingdom-king-test--ok "story_diff"
                                                        `(story . ,id))))
      (should (cl-some (lambda (text)
                         (string-search "is merged into rk/integration of demo"
                                        text))
                       (rat-kingdom-king-test--news space)))
      (should (cdr (rat-kingdom-king-test--call "story_show"
                                                '(story . "S-none")))))))

(ert-deftest rat-kingdom-king-test-moves-and-cancels ()
  (rat-kingdom-story-test-with-repo (space _path)
    (rat-kingdom-king-test--start space)
    (rat-kingdom-story-start space "demo" "Add a file" nil "S-1")
    (rat-kingdom-reaction-run space)
    (rat-kingdom-story-test--call "S-1.1" "block" '(summary . "Which file?"))
    (rat-kingdom-reaction-run space)
    ;; The king hears that it stopped, and why.
    (let ((news (car (rat-kingdom-king-test--news space))))
      (should (string-search "S-1 (Add a file) has stopped at blocked" news))
      (should (string-search "Which file?" news)))
    (let ((status (rat-kingdom-king-test--ok "status")))
      (should (string-search "blocked (stopped)" status))
      (should (string-search "reason: The worker S-1.1 is blocked: Which file?"
                             status)))
    (should (cdr (rat-kingdom-king-test--call "story_move" '(story . "S-1")
                                              '(place . "nowhere"))))
    (should (string-search
             "S-1 is now at ready"
             (rat-kingdom-king-test--ok "story_move" '(story . "S-1")
                                        '(place . "ready")
                                        '(note . "feature.txt"))))
    (rat-kingdom-reaction-run space)
    (should (string-search "feature.txt"
                           (rat-kingdom-story-test--prompt "S-1.2")))
    (should (string-search "Cancelled S-1"
                           (rat-kingdom-king-test--ok "story_cancel"
                                                      '(story . "S-1"))))
    (should-not (rat-kingdom-story-get space "S-1"))
    (should (member "S-1.2" rat-kingdom-story-test--stopped))))

(ert-deftest rat-kingdom-king-test-registers-and-syncs-repositories ()
  (rat-kingdom-story-test-with-repo (space path)
    (rat-kingdom-king-test--start space)
    (let ((other (expand-file-name "../other/" path)))
      (make-directory other)
      (rat-kingdom-story-test--git other "init" "-q" "-b" "main")
      (rat-kingdom-story-test--git other "config" "user.name" "Test")
      (rat-kingdom-story-test--git other "config" "user.email" "t@example.com")
      (rat-kingdom-story-test--commit other "README" "other\n" "Initial")
      (should (string-search
               "Registered other"
               (rat-kingdom-king-test--ok
                "repo_add" `(path . ,other) '(check . "make \"the test\"")
                '(workflow . "story-lite"))))
      (let ((repo (rat-kingdom-repo-get space "other")))
        (should (equal (plist-get repo :check) '("make" "the test")))
        (should (equal (plist-get repo :workflow) "story-lite")))
      (should (cdr (rat-kingdom-king-test--call
                    "repo_add" `(path . ,other) '(workflow . "nonsense"))))
      (should (cdr (rat-kingdom-king-test--call
                    "repo_add" '(path . "/nowhere/at/all"))))
      (should (string-search "check make \"the test\"; workflow story-lite"
                             (rat-kingdom-king-test--ok "status")))
      (rat-kingdom-story-test--commit other "more" "x\n" "More")
      (should (string-search "Moved rk/integration forward"
                             (rat-kingdom-king-test--ok "repo_sync"
                                                        '(repo . "other"))))
      (should (cdr (rat-kingdom-king-test--call "repo_sync"
                                                '(repo . "nowhere")))))))

(ert-deftest rat-kingdom-king-test-repo-add-sets-and-clears-setup ()
  (rat-kingdom-story-test-with-repo (space path)
    (rat-kingdom-king-test--start space)
    (should-not (string-search "setup" (rat-kingdom-king-test--ok "status")))
    (rat-kingdom-king-test--ok "repo_add" `(path . ,path)
                               '(check . "make test") '(setup . "npm ci"))
    (should (equal (plist-get (rat-kingdom-repo-get space "demo") :setup)
                   '("npm" "ci")))
    (should (string-search "check make test; setup npm ci; workflow"
                           (rat-kingdom-king-test--ok "status")))
    ;; Registering again without it clears it.
    (rat-kingdom-king-test--ok "repo_add" `(path . ,path))
    (should-not (plist-get (rat-kingdom-repo-get space "demo") :setup))
    (should-not (string-search "setup" (rat-kingdom-king-test--ok "status")))
    (should-error (rat-kingdom-repo-add space path :setup "npm ci"))))

(ert-deftest rat-kingdom-king-test-news-waits-for-a-quiet-king ()
  (rat-kingdom-story-test-with-repo (space _path)
    (rat-kingdom-story-start space "demo" "Add a file" nil "S-1")
    (rat-kingdom-reaction-run space)
    (rat-kingdom-story-test--work space "S-1" "feature.txt")
    (rat-kingdom-story-test--settle space "S-1")
    ;; With no king running the news waits in the space.
    (should (eql (length (rat-kingdom-king-test--news space)) 1))
    (should (zerop (rat-kingdom-king-deliver space)))
    (should-not rat-kingdom-king--retry)
    (rat-kingdom-king-test--start space)
    ;; A king in the middle of a turn is not interrupted; another try is set.
    (setq rat-kingdom-story-test--busy t)
    (should (zerop (rat-kingdom-king-deliver space)))
    (should (timerp rat-kingdom-king--retry))
    (should (eql (length (rat-kingdom-king-test--news space)) 1))
    (should-not rat-kingdom-story-test--sent)
    ;; More news arrives meanwhile.
    (rat-kingdom-story-start space "demo" "Another" nil "S-2")
    (rat-kingdom-reaction-run space)
    (rat-kingdom-story-test--call "S-2.1" "block" '(summary . "Stuck here."))
    (rat-kingdom-reaction-run space)
    ;; When its turn ends it gets all of it at once, and only once.
    (setq rat-kingdom-story-test--busy nil)
    (rat-kingdom-king--on-idle "S-2.1")
    (should-not rat-kingdom-story-test--sent)
    (rat-kingdom-king--on-idle "king")
    (should (eql (length rat-kingdom-story-test--sent) 1))
    (let ((sent (car rat-kingdom-story-test--sent)))
      (should (equal (car sent) "king"))
      (should (string-prefix-p "[rat-kingdom] " (cdr sent)))
      (should (string-search "S-1 (Add a file) is merged" (cdr sent)))
      (should (string-search "S-2 (Another) has stopped at blocked" (cdr sent)))
      (should (string-search "Stuck here." (cdr sent))))
    (should-not (rat-kingdom-king-test--news space))
    (should-not rat-kingdom-king--retry)
    (should (zerop (rat-kingdom-king-deliver space)))
    (should (eql (length rat-kingdom-story-test--sent) 1))))

(ert-deftest rat-kingdom-king-test-a-review-by-the-user-is-not-the-kings ()
  (rat-kingdom-story-test-with-repo (space _path)
    (let ((rat-kingdom-workflow--table (copy-alist rat-kingdom-workflow--table)))
      (rat-kingdom-workflow-define
       'by-user
       :places '(ready checking review integrating done blocked)
       :start 'ready :final '(done)
       :steps '((implement :from ready :spawn rat :to checking)
                (check :from checking :check t :pass review :fail ready)
                (review :from review :review user :pass integrating :fix ready)
                (integrate :from integrating :merge t :to done
                           :stale checking)))
      (rat-kingdom-story-start space "demo" "Add a file" nil "S-1" 'by-user)
      (rat-kingdom-reaction-run space)
      (rat-kingdom-story-test--work space "S-1" "feature.txt")
      (rat-kingdom-story-test--settle space "S-1")
      (should (equal (rat-kingdom-story-test--get space "S-1" :awaiting)
                     "review"))
      (should-not (rat-kingdom-king-test--news space))
      (should (equal (car rat-kingdom-story-test--events) '(review . "S-1"))))))

;;;; Tasks

(ert-deftest rat-kingdom-king-test-status-lists-available-tasks ()
  (rat-kingdom-task-test-with-tracker (space fake)
    (rat-kingdom-king-test--start space)
    (setf (rat-kingdom-task-test-fake-tasks fake)
          (append (rat-kingdom-task-test-fake-tasks fake)
                  (list (list :id "T-0" :title "Zeroth" :status "open"
                              :priority 3 :type "task")
                        (list :id "T-3" :title "Third" :status "open"
                              :priority 1 :type "bug"))))
    ;; Status projects the tracker's ready tasks and lists them by
    ;; priority, then id.
    (should (string-search "Stories in progress:\n- none\n\nAvailable tasks:
- T-1 [demo] P1 task: First
- T-3 [demo] P1 bug: Third
- T-0 [demo] P3 task: Zeroth"
                           (rat-kingdom-king-test--ok "status")))
    ;; A tracker that fails does not stop status.
    (setf (rat-kingdom-task-test-fake-fail fake) t)
    (should (string-search "- T-0 [demo] P3 task: Zeroth"
                           (rat-kingdom-king-test--ok "status")))
    (setf (rat-kingdom-task-test-fake-fail fake) nil)
    ;; Nothing ready.
    (dolist (task (rat-kingdom-task-test-fake-tasks fake))
      (plist-put task :status "closed"))
    (let ((status (rat-kingdom-king-test--ok "status")))
      (should (string-suffix-p "Available tasks:\n- none" status)))
    ;; No tracker at all.
    (let ((rat-kingdom-task-adapter-function #'ignore))
      (should (string-suffix-p
               "Available tasks:\n- none (no repository has a task tracker)"
               (rat-kingdom-king-test--ok "status"))))))

(ert-deftest rat-kingdom-king-test-starts-a-story-from-a-task ()
  (rat-kingdom-task-test-with-tracker (space fake)
    (rat-kingdom-king-test--start space)
    (should (rat-kingdom-task-test--available space))
    (let* ((answer (rat-kingdom-king-test--ok "story_start" '(repo . "demo")
                                              '(task . "T-1")))
           (id (progn (string-match "Started \\(S-[0-9a-f]+\\) for the task \
T-1 with the workflow" answer)
                      (match-string 1 answer))))
      (should id)
      (should (equal (rat-kingdom-story-test--get space id :task) "T-1"))
      (should (equal (rat-kingdom-story-test--get space id :title) "First"))
      (should (equal (rat-kingdom-story-test--get space id :description)
                     "Do it"))
      (should-not (rat-kingdom-task-test--available space))
      (should (member (list 'claim "T-1" id)
                      (rat-kingdom-task-test-fake-calls fake)))
      ;; A task can have only one live story.
      (let ((answer (rat-kingdom-king-test--call "story_start" '(repo . "demo")
                                                 '(task . "T-1"))))
        (should (cdr answer))
        (should (string-search (format "The story %s already works on the \
task T-1" id)
                               (car answer)))))))

(ert-deftest rat-kingdom-king-test-a-task-with-the-kings-description ()
  (rat-kingdom-task-test-with-tracker (space fake)
    (rat-kingdom-king-test--start space)
    ;; T-2 is not ready, so it is looked up in the tracker.
    (let* ((answer (rat-kingdom-king-test--ok
                    "story_start" '(repo . "demo") '(task . "T-2")
                    '(description . "Fix it this way.")))
           (id (progn (string-match "Started \\(S-[0-9a-f]+\\)" answer)
                      (match-string 1 answer))))
      (should (member '(show "T-2") (rat-kingdom-task-test-fake-calls fake)))
      (should (equal (rat-kingdom-story-test--get space id :title) "Second"))
      (should (equal (rat-kingdom-story-test--get space id :description)
                     "Fix it this way.\n\nThis story works on the tracker \
task T-2: Second"))
      (should (equal (rat-kingdom-story-test--get space id :task) "T-2")))))

(ert-deftest rat-kingdom-king-test-story-start-errors-for-tasks ()
  (rat-kingdom-task-test-with-tracker (space fake)
    (rat-kingdom-king-test--start space)
    (let ((answer (rat-kingdom-king-test--call "story_start" '(repo . "demo")
                                               '(task . "T-9"))))
      (should (cdr answer))
      (should (string-search "The tracker of demo has no task T-9"
                             (car answer))))
    (let* ((rat-kingdom-task-adapter-function #'ignore)
           (answer (rat-kingdom-king-test--call "story_start" '(repo . "demo")
                                                '(task . "T-1"))))
      (should (cdr answer))
      (should (string-search "The repository demo has no task tracker"
                             (car answer))))
    ;; Without a task, a title and a description are needed.
    (let ((answer (rat-kingdom-king-test--call "story_start" '(repo . "demo")
                                               '(description . "D"))))
      (should (cdr answer))
      (should (string-search "Give a title" (car answer))))
    (should (cdr (rat-kingdom-king-test--call "story_start" '(repo . "demo")
                                              '(title . "T"))))
    (should-not (rat-kingdom-story-list space))))

(provide 'rat-kingdom-king-test)
;;; rat-kingdom-king-test.el ends here
