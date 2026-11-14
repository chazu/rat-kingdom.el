;;; rat-kingdom-epic-dispatch-test.el --- Tests for running epics -*- lexical-binding: t; -*-

;;; Commentary:

;; Batch tests for running an epic: `epic_start' and the engine starting
;; a story for each task as it becomes ready, pausing, resuming,
;; cancelling, holding and retrying, the king's news, the views, and
;; recovery.  They use the in-memory tracker of rat-kingdom-task-test.el,
;; whose `ready' honours dependencies, with a real repository and the
;; backend that starts no agent; the tests play the workers.

;;; Code:

(require 'ert)
(require 'rat-kingdom-epic)
(require 'rat-kingdom-story-test)
(require 'rat-kingdom-task-test)
(require 'rat-kingdom-king-test)
(require 'rat-kingdom-epic-test)
(require 'rat-kingdom-reload-test)

(defconst rat-kingdom-epic-dispatch-test--diamond
  "[{\"key\":\"a\",\"title\":\"Base\",\"description\":\"The base.\"},
    {\"key\":\"b\",\"title\":\"Left\",\"description\":\"The left side.\",
     \"depends_on\":[\"a\"]},
    {\"key\":\"c\",\"title\":\"Right\",\"description\":\"The right side.\",
     \"depends_on\":[\"a\"]},
    {\"key\":\"d\",\"title\":\"Join\",\"description\":\"Join b and c.\",
     \"depends_on\":[\"b\",\"c\"]}]"
  "A diamond: b and c depend on a, d on b and c.
epic_create makes the epic T-1 and the tasks T-2 (a), T-3 (b), T-4 (c)
and T-5 (d).")

(defmacro rat-kingdom-epic-dispatch-test-with-diamond (vars &rest body)
  "Run BODY with VARS, (SPACE FAKE), and the diamond planned as the epic T-1.
The king is running and has been given nothing yet; story events reach
the epic."
  (declare (indent 1) (debug t))
  `(rat-kingdom-epic-test-with-empty-tracker ,vars
     (let ((rat-kingdom-story-event-functions
            (cons #'rat-kingdom-epic--story-event
                  rat-kingdom-story-event-functions)))
       (should-not (cdr (rat-kingdom-epic-test--epic
                         rat-kingdom-epic-dispatch-test--diamond)))
       (rat-kingdom-space-retract ,(car vars) '(message))
       ,@body)))

(defun rat-kingdom-epic-dispatch-test--drain (predicate)
  "Run timers until PREDICATE returns non-nil, or give up."
  (let ((tries 0))
    (while (and (not (funcall predicate)) (< (cl-incf tries) 200))
      (accept-process-output nil 0.01))
    (accept-process-output nil 0.01)))

(defun rat-kingdom-epic-dispatch-test--story (space task)
  "Return the id of the story in progress in SPACE for TASK, or nil."
  (plist-get (rat-kingdom-space-rd space (list 'story :task task)) :identity))

(defun rat-kingdom-epic-dispatch-test--tasks-with-stories (space)
  "Return the tasks in SPACE that have a story in progress, sorted."
  (sort (mapcar (lambda (story) (plist-get (plist-get story :payload) :task))
                (rat-kingdom-story-list space))
        #'string<))

(defun rat-kingdom-epic-dispatch-test--merge (space fake task)
  "Play the worker of TASK's story in SPACE through to the merge.
Wait until FAKE has the task closed and the epic has been told, then
run reactions."
  (let ((story (or (rat-kingdom-epic-dispatch-test--story space task)
                   (error "No story for %s" task))))
    (rat-kingdom-reaction-run space)
    (rat-kingdom-story-test--work space story (format "%s.txt" task))
    (rat-kingdom-story-test--settle space story)
    (should-not (rat-kingdom-story-get space story))
    (rat-kingdom-epic-dispatch-test--drain
     (lambda () (equal (plist-get (rat-kingdom-task-test--task fake task)
                                  :status)
                       "closed")))
    (rat-kingdom-reaction-run space)
    story))

(defun rat-kingdom-epic-dispatch-test--state (space)
  "Return the state of the epic T-1 in SPACE."
  (plist-get (plist-get (rat-kingdom-epic-record space "T-1") :payload) :state))

(defun rat-kingdom-epic-dispatch-test--claims (fake task)
  "Return how many times FAKE was asked to claim TASK."
  (cl-count-if (lambda (call) (and (eq (car call) 'claim)
                                   (equal (cadr call) task)))
               (rat-kingdom-task-test-fake-calls fake)))

(defun rat-kingdom-epic-dispatch-test--start (&rest arguments)
  "Call epic_start for the epic T-1 of demo with ARGUMENTS and return its text."
  (apply #'rat-kingdom-king-test--ok "epic_start" '(repo . "demo")
         '(epic . "T-1") arguments))

;;;; Running an epic

(ert-deftest rat-kingdom-epic-dispatch-test-diamond-to-the-end ()
  (rat-kingdom-epic-dispatch-test-with-diamond (space fake)
    (let ((answer (rat-kingdom-epic-dispatch-test--start)))
      ;; Only a starts; the others wait, and say on what.
      (should (string-search "The epic T-1 (Plan) in demo is running." answer))
      (should (string-match "Stories started now:\n- \\(S-[0-9a-f]+\\) for \
T-2 (Base), at ready (waiting for worker)" answer))
      (should (equal (match-string 1 answer)
                     (rat-kingdom-epic-dispatch-test--story space "T-2")))
      (should (string-search "Waiting on other tasks:
- T-3 (Left) waits on T-2
- T-4 (Right) waits on T-2
- T-5 (Join) waits on T-3, T-4" answer)))
    (should (equal (rat-kingdom-epic-dispatch-test--tasks-with-stories space)
                   '("T-2")))
    (let ((story (rat-kingdom-story-get
                  space (rat-kingdom-epic-dispatch-test--story space "T-2"))))
      (should (equal (plist-get (plist-get story :payload) :epic) "T-1"))
      (should (equal (plist-get (plist-get story :payload) :title) "Base"))
      (should (equal (plist-get (plist-get story :payload) :description)
                     "The base.")))
    ;; When a is merged, b and c start together; d waits for both.
    (rat-kingdom-epic-dispatch-test--merge space fake "T-2")
    (should (equal (rat-kingdom-epic-dispatch-test--tasks-with-stories space)
                   '("T-3" "T-4")))
    (rat-kingdom-epic-dispatch-test--merge space fake "T-3")
    (should (equal (rat-kingdom-epic-dispatch-test--tasks-with-stories space)
                   '("T-4")))
    (rat-kingdom-epic-dispatch-test--merge space fake "T-4")
    (should (equal (rat-kingdom-epic-dispatch-test--tasks-with-stories space)
                   '("T-5")))
    (should (equal (rat-kingdom-epic-dispatch-test--state space) "running"))
    (rat-kingdom-epic-dispatch-test--merge space fake "T-5")
    ;; Every task merged: the epic is done, the br epic closed, and the
    ;; king told, once.
    (rat-kingdom-epic-dispatch-test--drain
     (lambda () (equal (rat-kingdom-epic-dispatch-test--state space) "done")))
    (should (equal (rat-kingdom-epic-dispatch-test--state space) "done"))
    (should (plist-get (plist-get (rat-kingdom-epic-record space "T-1") :payload)
                       :finished))
    (should (member '(close "T-1" "All 4 tasks merged")
                    (rat-kingdom-task-test-fake-calls fake)))
    (should (eql (cl-count-if
                  (lambda (text) (string-search "is done" text))
                  (rat-kingdom-king-test--news space))
                 1))
    (should (member "Epic T-1 (Plan) is done: 4 stories merged. The br epic \
T-1 is closed."
                    (rat-kingdom-king-test--news space)))
    ;; One story and one claim per task, and every one merged.
    (dolist (task '("T-2" "T-3" "T-4" "T-5"))
      (should (eql (rat-kingdom-epic-dispatch-test--claims fake task) 1)))
    (should (eql (length rat-kingdom-story-test--started) 5))
    (should (equal (rat-kingdom-story-test--git
                    (plist-get (rat-kingdom-repo-get space "demo") :path)
                    "show" "rk/integration:T-5.txt")
                   "work"))
    ;; A done epic leaves status, and cannot be started again.
    (should-not (string-search "Epics" (rat-kingdom-king-test--ok "status")))
    (let ((answer (rat-kingdom-king-test--call "epic_start" '(repo . "demo")
                                               '(epic . "T-1"))))
      (should (cdr answer))
      (should (string-search "The epic T-1 is done" (car answer))))
    (should-not (rat-kingdom-reaction-failures space))))

(ert-deftest rat-kingdom-epic-dispatch-test-max-parallel ()
  (rat-kingdom-epic-dispatch-test-with-diamond (space fake)
    (should (string-search "with at most 1 stories at once"
                           (rat-kingdom-epic-dispatch-test--start
                            '(max_parallel . 1))))
    (rat-kingdom-epic-dispatch-test--merge space fake "T-2")
    ;; b and c are both ready, and only b starts.
    (should (equal (rat-kingdom-epic-dispatch-test--tasks-with-stories space)
                   '("T-3")))
    (should (equal (rat-kingdom-task-test--available space) '("T-4")))
    (should (string-search "    waiting on other tasks: 1"
                           (rat-kingdom-king-test--ok "status")))
    (should (string-search "| T-4 | Right | open, ready | - |"
                           (rat-kingdom-king-test--ok "epic_show"
                                                      '(epic . "T-1"))))
    ;; Dispatching again changes nothing.
    (should-not (rat-kingdom-epic-dispatch space))
    (rat-kingdom-epic-dispatch-test--merge space fake "T-3")
    (should (equal (rat-kingdom-epic-dispatch-test--tasks-with-stories space)
                   '("T-4")))
    (rat-kingdom-epic-dispatch-test--merge space fake "T-4")
    (should (equal (rat-kingdom-epic-dispatch-test--tasks-with-stories space)
                   '("T-5")))
    (should-not (rat-kingdom-reaction-failures space))))

(ert-deftest rat-kingdom-epic-dispatch-test-worker-cap ()
  (rat-kingdom-epic-dispatch-test-with-diamond (space fake)
    (let ((rat-kingdom-story-max-workers 1))
      (rat-kingdom-epic-dispatch-test--start)
      (rat-kingdom-epic-dispatch-test--merge space fake "T-2")
      ;; Both stories are started; one waits for the only worker.
      (should (equal (rat-kingdom-epic-dispatch-test--tasks-with-stories space)
                     '("T-3" "T-4")))
      (let ((b (rat-kingdom-epic-dispatch-test--story space "T-3"))
            (c (rat-kingdom-epic-dispatch-test--story space "T-4")))
        (should (equal (rat-kingdom-story-test--get space b :awaiting)
                       "worker"))
        (should (rat-kingdom-story-test--queued-p space c))
        (should (string-search (format "in progress: %s for T-3 at ready \
(waiting for worker), %s for T-4 at ready (waiting for a free worker)" b c)
                               (rat-kingdom-king-test--ok "status")))
        (rat-kingdom-epic-dispatch-test--merge space fake "T-3")
        (should (equal (rat-kingdom-story-test--get space c :awaiting)
                       "worker"))))
    ;; epic_start says which of its stories wait for a worker.
    (should-not (rat-kingdom-reaction-failures space))))

(ert-deftest rat-kingdom-epic-dispatch-test-start-answers-queued-stories ()
  (rat-kingdom-epic-dispatch-test-with-diamond (space fake)
    (setf (rat-kingdom-task-test-fake-tasks fake)
          (mapcar (lambda (task) (plist-put task :depends-on nil))
                  (rat-kingdom-task-test-fake-tasks fake)))
    (let* ((rat-kingdom-story-max-workers 2)
           (answer (rat-kingdom-epic-dispatch-test--start
                    '(max_parallel . 3))))
      (should (string-search "for T-2 (Base), at ready (waiting for worker)"
                             answer))
      (should (string-search "for T-3 (Left), at ready (waiting for worker)"
                             answer))
      (should (string-search "for T-4 (Right), queued for a free worker: at \
most 2 workers run at once" answer))
      (should (string-search "Ready, queued behind max_parallel (3):
- T-5 (Join)" answer)))))

(ert-deftest rat-kingdom-epic-dispatch-test-pause-and-resume ()
  (rat-kingdom-epic-dispatch-test-with-diamond (space fake)
    (rat-kingdom-epic-dispatch-test--start)
    (let ((a (rat-kingdom-epic-dispatch-test--story space "T-2")))
      (should (equal (rat-kingdom-king-test--ok "epic_pause" '(epic . "T-1"))
                     (format "Paused the epic T-1 (Plan). No new story of it \
starts until epic_resume. Its stories in progress carry on: %s." a))))
    (should (string-search "- T-1 [demo] Plan: paused, 0/4 merged"
                           (rat-kingdom-king-test--ok "status")))
    ;; The running story carries on and is merged; nothing new starts.
    (rat-kingdom-epic-dispatch-test--merge space fake "T-2")
    (should-not (rat-kingdom-story-list space))
    (should (equal (sort (rat-kingdom-task-test--available space) #'string<)
                   '("T-3" "T-4")))
    (should-not (rat-kingdom-epic-dispatch space))
    (should (cdr (rat-kingdom-king-test--call "epic_pause" '(epic . "T-1"))))
    (let ((answer (rat-kingdom-king-test--call "epic_start" '(repo . "demo")
                                               '(epic . "T-1"))))
      (should (cdr answer))
      (should (string-search "is paused; resume it with epic_resume"
                             (car answer))))
    ;; Resuming starts what is ready.
    (let ((answer (rat-kingdom-king-test--ok "epic_resume" '(epic . "T-1"))))
      (should (string-prefix-p "Resumed the epic T-1 (Plan)." answer))
      (should (string-search "for T-3 (Left)" answer))
      (should (string-search "for T-4 (Right)" answer)))
    (should (equal (rat-kingdom-epic-dispatch-test--tasks-with-stories space)
                   '("T-3" "T-4")))
    (should (cdr (rat-kingdom-king-test--call "epic_resume" '(epic . "T-1"))))
    (let ((answer (rat-kingdom-king-test--call "epic_start" '(repo . "demo")
                                               '(epic . "T-1"))))
      (should (cdr answer))
      (should (string-search "is already running" (car answer))))
    (should-not (rat-kingdom-reaction-failures space))))

(ert-deftest rat-kingdom-epic-dispatch-test-cancel ()
  (rat-kingdom-epic-dispatch-test-with-diamond (space fake)
    (rat-kingdom-epic-dispatch-test--start)
    (rat-kingdom-epic-dispatch-test--merge space fake "T-2")
    (rat-kingdom-reaction-run space)
    (rat-kingdom-space-retract space '(message))
    (let ((b (rat-kingdom-epic-dispatch-test--story space "T-3"))
          (c (rat-kingdom-epic-dispatch-test--story space "T-4")))
      (let ((answer (rat-kingdom-king-test--ok "epic_cancel" '(epic . "T-1"))))
        (should (string-search (format "Cancelled its stories %s (task T-3), \
%s (task T-4)" b c)
                               answer))
        (should (string-search "The br epic T-1 and its tasks are left open"
                               answer))))
    (should (equal (rat-kingdom-epic-dispatch-test--state space) "cancelled"))
    (should-not (rat-kingdom-story-list space))
    ;; Their tasks are released and become available, and nothing starts.
    (rat-kingdom-epic-dispatch-test--drain
     (lambda () (eql (length (rat-kingdom-task-test--available space)) 2)))
    (rat-kingdom-reaction-run space)
    (should (equal (sort (rat-kingdom-task-test--available space) #'string<)
                   '("T-3" "T-4")))
    (should-not (rat-kingdom-story-list space))
    (should-not (rat-kingdom-epic-dispatch space))
    ;; The epic's tasks are not held, nor is the king told of each.
    (should-not (plist-get (plist-get (rat-kingdom-epic-record space "T-1")
                                      :payload)
                           :held))
    (should-not (rat-kingdom-king-test--news space))
    (should-not (assoc "T-1" (cl-remove-if-not
                              (lambda (call) (eq (car call) 'close))
                              (rat-kingdom-task-test-fake-calls fake))))
    (should-not (string-search "Epics" (rat-kingdom-king-test--ok "status")))
    (should (cdr (rat-kingdom-king-test--call "epic_resume" '(epic . "T-1"))))
    ;; It can be run again.
    (should (string-search "for T-3 (Left)"
                           (rat-kingdom-epic-dispatch-test--start)))
    (should (equal (rat-kingdom-epic-dispatch-test--tasks-with-stories space)
                   '("T-3" "T-4")))
    (should-not (rat-kingdom-reaction-failures space))))

;;;; Holdups

(ert-deftest rat-kingdom-epic-dispatch-test-parked-story-tells-the-king ()
  (rat-kingdom-epic-dispatch-test-with-diamond (space fake)
    (rat-kingdom-epic-dispatch-test--start)
    (rat-kingdom-reaction-run space)
    (let ((a (rat-kingdom-epic-dispatch-test--story space "T-2")))
      (rat-kingdom-story-test--call (concat a ".1") "block"
                                    '(summary . "The base is unclear."))
      (rat-kingdom-reaction-run space)
      (should (equal (rat-kingdom-story-test--get space a :phase) "parked"))
      ;; One message, which says what waits on it.
      (let ((news (rat-kingdom-king-test--news space)))
        (should (eql (length news) 1))
        (should (string-prefix-p (format "%s (Base) has stopped at blocked. \
Reason: The worker %s.1 is blocked: The base is unclear." a a)
                                 (car news)))
        (should (string-search "It is the story of the task T-2 of the epic \
T-1 (Plan). Tasks of the epic now waiting on it: T-3 (directly), T-4 \
(directly), T-5 (through T-3). None of them starts until it is merged."
                               (car news))))
      (should (string-search (format "    held up behind the stopped %s (T-2): \
T-3 (directly), T-4 (directly), T-5 (through T-3)" a)
                             (rat-kingdom-king-test--ok "status")))
      (should (string-search (format "%s (T-2) has stopped: The worker %s.1 is \
blocked: The base is unclear. Waiting on it: T-3" a a)
                             (rat-kingdom-king-test--ok "epic_show"
                                                        '(epic . "T-1"))))
      ;; Nothing else starts, and the parked task is not held.
      (should-not (rat-kingdom-epic-dispatch space))
      (should-not (plist-get (plist-get (rat-kingdom-epic-record space "T-1")
                                        :payload)
                             :held)))
    (should-not (rat-kingdom-reaction-failures space))))

(ert-deftest rat-kingdom-epic-dispatch-test-cancelled-story-is-held ()
  (rat-kingdom-epic-dispatch-test-with-diamond (space fake)
    (rat-kingdom-epic-dispatch-test--start)
    (rat-kingdom-reaction-run space)
    (let ((a (rat-kingdom-epic-dispatch-test--story space "T-2")))
      (rat-kingdom-king-test--ok "story_cancel" `(story . ,a))
      (should (equal (rat-kingdom-king-test--news space)
                     (list (format "%s (Base) was cancelled.
Its task T-2 of the epic T-1 (Plan) is now held: the engine will not start it \
again by itself. If it should be done after all, call epic_retry with T-1 and \
T-2." a))))
      (should (equal (plist-get (plist-get (rat-kingdom-epic-record space "T-1")
                                           :payload)
                                :held)
                     (list (list :task "T-2"
                                 :reason (format "its story %s was cancelled"
                                                 a))))))
    ;; The task is released and available again, and is not restarted.
    (rat-kingdom-epic-dispatch-test--drain
     (lambda () (rat-kingdom-task-test--available space)))
    (rat-kingdom-reaction-run space)
    (should (equal (rat-kingdom-task-test--available space) '("T-2")))
    (should-not (rat-kingdom-story-list space))
    (should-not (rat-kingdom-epic-dispatch space))
    (should (string-search "    held (epic_retry starts one again): T-2, its \
story"
                           (rat-kingdom-king-test--ok "status")))
    (should (string-search "| T-2 | Base | open, held: its story"
                           (rat-kingdom-king-test--ok "epic_show"
                                                      '(epic . "T-1"))))
    ;; Only a held task can be retried.
    (let ((answer (rat-kingdom-king-test--call "epic_retry" '(epic . "T-1")
                                               '(task . "T-3"))))
      (should (cdr answer))
      (should (string-search "The task T-3 is not held by the epic T-1; held \
are T-2" (car answer))))
    ;; Retrying starts it again.
    (let ((answer (rat-kingdom-king-test--ok "epic_retry" '(epic . "T-1")
                                             '(task . "T-2"))))
      (should (string-match "The task T-2 of the epic T-1 (Plan) is no longer \
held. Started \\(S-[0-9a-f]+\\) for it." answer))
      (should (equal (match-string 1 answer)
                     (rat-kingdom-epic-dispatch-test--story space "T-2"))))
    (should (eql (rat-kingdom-epic-dispatch-test--claims fake "T-2") 2))
    (should-not (plist-get (plist-get (rat-kingdom-epic-record space "T-1")
                                      :payload)
                           :held))
    (should-not (rat-kingdom-reaction-failures space))))

(ert-deftest rat-kingdom-epic-dispatch-test-story-ended-unmerged-is-held ()
  (rat-kingdom-epic-dispatch-test-with-diamond (space fake)
    (rat-kingdom-epic-dispatch-test--start)
    (rat-kingdom-reaction-run space)
    (let ((a (rat-kingdom-epic-dispatch-test--story space "T-2")))
      ;; Moved to its final place by hand: over, but not merged.
      (rat-kingdom-story-move space a 'done)
      (rat-kingdom-reaction-run space)
      (should-not (rat-kingdom-story-get space a))
      (should (string-search "Its task T-2 of the epic T-1 (Plan) is now held"
                             (car (rat-kingdom-king-test--news space))))
      (should (string-search (format "its story %s ended at done without \
being merged" a)
                             (rat-kingdom-epic--held-reason
                              (rat-kingdom-epic-record space "T-1") "T-2"))))
    (rat-kingdom-epic-dispatch-test--drain
     (lambda () (rat-kingdom-task-test--available space)))
    (rat-kingdom-reaction-run space)
    (should-not (rat-kingdom-story-list space))
    (should-not (rat-kingdom-reaction-failures space))))

(ert-deftest rat-kingdom-epic-dispatch-test-a-task-that-cannot-start-is-held ()
  (rat-kingdom-epic-dispatch-test-with-diamond (space fake)
    (plist-put (rat-kingdom-task-test--task fake "T-2") :labels
               '("rk-workflow:nonesuch"))
    (rat-kingdom-task-project space "demo")
    (rat-kingdom-space-retract space '(available))
    (rat-kingdom-task-project space "demo")
    (let ((answer (rat-kingdom-epic-dispatch-test--start)))
      (should (string-search "No story was started now." answer))
      (should (string-search "Held, until epic_retry:
- T-2 (Base): a story could not be started for it: There is no workflow \
called nonesuch" answer)))
    (should (string-search "The epic T-1 (Plan) could not start a story for \
its task T-2 (Base): There is no workflow called nonesuch"
                           (car (rat-kingdom-king-test--news space))))
    ;; It is not tried again by itself, nor is the king told twice.
    (rat-kingdom-reaction-run space)
    (should-not (rat-kingdom-epic-dispatch space))
    (should (eql (length (rat-kingdom-king-test--news space)) 1))
    (should-not (rat-kingdom-story-list space))
    (should-not (rat-kingdom-reaction-failures space))))

;;;; Exactly once

(ert-deftest rat-kingdom-epic-dispatch-test-never-twice ()
  (rat-kingdom-epic-dispatch-test-with-diamond (space fake)
    (rat-kingdom-epic-dispatch-test--start)
    (let ((a (rat-kingdom-epic-dispatch-test--story space "T-2")))
      ;; Dispatching again, twice in one transaction, from the reaction
      ;; on a replaced epic tuple, and from a story's end, all at once.
      (rat-kingdom-space-with-transaction space
        (should-not (rat-kingdom-epic-dispatch space))
        (should-not (rat-kingdom-epic-dispatch space "demo" "T-1"))
        (rat-kingdom-epic--update space "demo" "T-1"
                                  (lambda (payload) payload)))
      (rat-kingdom-epic--story-settled
       space (list :scope "demo" :identity "S-gone"
                   :payload (list :epic "T-1" :task "T-2")))
      (rat-kingdom-reaction-run space)
      (should-not (rat-kingdom-epic-dispatch space))
      ;; A task released meanwhile is projected again, but its story
      ;; keeps it.
      (rat-kingdom-task-test--set fake "T-2" "open")
      (rat-kingdom-task-project space "demo")
      (should-not (rat-kingdom-task-test--available space))
      ;; Even a stray available tuple does not give it a second story.
      (rat-kingdom-space-out space 'available :scope "demo" :identity "T-2"
                             :payload '(:title "Base" :parent "T-1"))
      (rat-kingdom-reaction-run space)
      (should-not (rat-kingdom-epic-dispatch space))
      (should (equal (mapcar (lambda (story) (plist-get story :identity))
                             (rat-kingdom-story-list space))
                     (list a))))
    (should (eql (rat-kingdom-epic-dispatch-test--claims fake "T-2") 1))
    (should (eql (length rat-kingdom-story-test--started) 2))
    ;; story_start refuses a task with a story too.
    (let ((answer (rat-kingdom-king-test--call "story_start" '(repo . "demo")
                                               '(task . "T-2"))))
      (should (cdr answer))
      (should (string-search "already works on the task T-2" (car answer))))
    (should-not (rat-kingdom-reaction-failures space))))

;;;; Recovery

(ert-deftest rat-kingdom-epic-dispatch-test-recovers-after-a-restart ()
  (rat-kingdom-epic-dispatch-test-with-diamond (space fake)
    (rat-kingdom-epic-dispatch-test--start '(max_parallel . 1))
    (rat-kingdom-epic-dispatch-test--merge space fake "T-2")
    (let ((b (rat-kingdom-epic-dispatch-test--story space "T-3"))
          (file (expand-file-name "space.db" rat-kingdom-directory)))
      (should (equal (rat-kingdom-task-test--available space) '("T-4")))
      ;; Emacs stops: the space is closed and nothing in memory survives.
      (rat-kingdom-space-close space)
      (setq space (rat-kingdom-space-open file)
            rat-kingdom-space--default space)
      (clrhash rat-kingdom-run--handles)
      (clrhash rat-kingdom-mcp--grants)
      (should (equal (rat-kingdom-epic-dispatch-test--state space) "running"))
      ;; As `rat-kingdom-mode' starts: reconcile, project, recover.
      (should (member (concat b ".1")
                      (plist-get (rat-kingdom-story-reconcile space) :runs)))
      (rat-kingdom-task-project-all space)
      (should-not (rat-kingdom-epic-recover space))
      (rat-kingdom-reaction-run space)
      ;; b's worker is replaced; nothing new starts, c still waits its turn.
      (should (equal (rat-kingdom-story-test--get space b :run)
                     (concat b ".2")))
      (should (equal (rat-kingdom-epic-dispatch-test--tasks-with-stories space)
                     '("T-3")))
      (should-not (rat-kingdom-epic-recover space))
      ;; Dispatch carries on when b is merged.
      (rat-kingdom-epic-dispatch-test--merge space fake "T-3")
      (should (equal (rat-kingdom-epic-dispatch-test--tasks-with-stories space)
                     '("T-4")))
      (rat-kingdom-epic-dispatch-test--merge space fake "T-4")
      (rat-kingdom-epic-dispatch-test--merge space fake "T-5")
      (rat-kingdom-epic-dispatch-test--drain
       (lambda () (equal (rat-kingdom-epic-dispatch-test--state space)
                         "done")))
      (should (equal (rat-kingdom-epic-dispatch-test--state space) "done"))
      (dolist (task '("T-2" "T-3" "T-4" "T-5"))
        (should (eql (rat-kingdom-epic-dispatch-test--claims fake task) 1)))
      (should-not (rat-kingdom-reaction-failures space)))))

(ert-deftest rat-kingdom-epic-dispatch-test-recovery-finishes-and-dispatches ()
  (rat-kingdom-epic-dispatch-test-with-diamond (space fake)
    (rat-kingdom-epic-dispatch-test--start)
    (rat-kingdom-epic-dispatch-test--merge space fake "T-2")
    (rat-kingdom-king-test--ok "epic_pause" '(epic . "T-1"))
    (rat-kingdom-king-test--ok "epic_resume" '(epic . "T-1"))
    (rat-kingdom-king-test--ok "epic_pause" '(epic . "T-1"))
    ;; Stories that ended, and a task closed by hand, while Emacs was
    ;; away: the epic heard nothing of it.
    (let ((rat-kingdom-task-settled-functions nil))
      (dolist (task '("T-3" "T-4"))
        (rat-kingdom-epic-dispatch-test--merge space fake task)))
    (should-not (rat-kingdom-story-list space))
    (rat-kingdom-task-test--set fake "T-5" "closed")
    (should (equal (rat-kingdom-epic-dispatch-test--state space) "paused"))
    (should-not (rat-kingdom-epic-recover space))
    (should (equal (rat-kingdom-epic-dispatch-test--state space) "done"))
    (should (member '(close "T-1" "All 4 tasks closed, 3 merged by its \
stories")
                    (rat-kingdom-task-test-fake-calls fake)))
    (should (member "Epic T-1 (Plan) is done: all 4 tasks are closed, 3 of \
them by merged stories. The br epic T-1 is closed."
                    (rat-kingdom-king-test--news space)))))

;;;; Stories the king starts for an epic's tasks

(ert-deftest rat-kingdom-epic-dispatch-test-story-start-joins-the-epic ()
  (rat-kingdom-epic-dispatch-test-with-diamond (space fake)
    (rat-kingdom-epic-dispatch-test--start)
    (rat-kingdom-king-test--ok "epic_pause" '(epic . "T-1"))
    (rat-kingdom-epic-dispatch-test--merge space fake "T-2")
    ;; The king starts one of the epic's tasks itself: it counts as a
    ;; story of the epic.
    (let* ((answer (rat-kingdom-king-test--ok "story_start" '(repo . "demo")
                                              '(task . "T-3")))
           (b (rat-kingdom-epic-dispatch-test--story space "T-3")))
      (should (string-search ", as a story of the epic T-1. You" answer))
      (should (equal (rat-kingdom-story-test--get space b :epic) "T-1"))
      ;; Resuming starts only the other.
      (rat-kingdom-king-test--ok "epic_resume" '(epic . "T-1"))
      (should (equal (rat-kingdom-epic-dispatch-test--tasks-with-stories space)
                     '("T-3" "T-4")))
      (should (equal (rat-kingdom-epic-dispatch-test--story space "T-3") b)))
    (should (eql (rat-kingdom-epic-dispatch-test--claims fake "T-3") 1))
    (should-not (rat-kingdom-reaction-failures space))))

(ert-deftest rat-kingdom-epic-dispatch-test-mode-dispatches-after-reconciling ()
  (let ((calls nil)
        (rat-kingdom-mode nil)
        (rat-kingdom--watch-timer nil))
    (cl-letf (((symbol-function 'rat-kingdom-space-default) (lambda () 'space))
              ((symbol-function 'rat-kingdom-reaction--ensure-table) #'ignore)
              ((symbol-function 'rat-kingdom-reconcile)
               (lambda () (push 'reconcile calls)))
              ((symbol-function 'rat-kingdom-task-ensure-all)
               (lambda (_space) (push 'ensure calls)))
              ((symbol-function 'rat-kingdom-task-project-all)
               (lambda (_space) (push 'project calls)))
              ((symbol-function 'rat-kingdom-epic-recover)
               (lambda (space) (push (list 'epics space) calls)))
              ((symbol-function 'rat-kingdom-reaction-attach)
               (lambda (_space) (push 'attach calls)))
              ((symbol-function 'rat-kingdom--start-watch) #'ignore)
              ((symbol-function 'rat-kingdom-reaction-detach) #'ignore)
              ((symbol-function 'rat-kingdom-mcp-stop) #'ignore))
      (unwind-protect
          (progn
            (rat-kingdom-mode 1)
            (should (equal (reverse calls)
                           '(reconcile ensure project (epics space) attach))))
        (rat-kingdom-mode -1)))))

;;;; Views

(ert-deftest rat-kingdom-epic-dispatch-test-status-and-show ()
  (rat-kingdom-epic-dispatch-test-with-diamond (space fake)
    ;; Not running: no Epics section, and epic_show says so.
    (should-not (string-search "Epics" (rat-kingdom-king-test--ok "status")))
    (let ((answer (rat-kingdom-king-test--call "epic_show" '(epic . "T-1"))))
      (should (cdr answer))
      (should (string-search "has not been started" (car answer))))
    (rat-kingdom-epic-dispatch-test--start)
    (rat-kingdom-epic-dispatch-test--merge space fake "T-2")
    (rat-kingdom-reaction-run space)
    (let ((b (rat-kingdom-epic-dispatch-test--story space "T-3"))
          (c (rat-kingdom-epic-dispatch-test--story space "T-4")))
      (rat-kingdom-king-test--ok "story_cancel" `(story . ,c))
      (rat-kingdom-epic-dispatch-test--drain
       (lambda () (equal (plist-get (rat-kingdom-task-test--task fake "T-4")
                                    :status)
                         "open")))
      (rat-kingdom-story-test--call (concat b ".1") "block"
                                    '(summary . "Unclear."))
      (rat-kingdom-reaction-run space)
      (let ((status (rat-kingdom-king-test--ok "status")))
        (should (string-search (format "Epics (epic_show gives one in full):
- T-1 [demo] Plan: running, 1/4 merged
    in progress: %s for T-3 at blocked (stopped)
    held up behind the stopped %s (T-3): T-5 (directly)
    held (epic_retry starts one again): T-4, its story %s was cancelled
    waiting on other tasks: 1

Available tasks:" b b c)
                               status))
        ;; The story's own line names its epic.
        (should (string-search (format "- %s [demo] blocked (stopped), " b)
                               status))
        (should (string-search ", claude, epic T-1: Left" status)))
      (let ((show (rat-kingdom-king-test--ok "epic_show" '(epic . "T-1"))))
        (should (string-prefix-p "Epic T-1 in demo: Plan
State: running, started " show))
        (should (string-search ". 1/4 merged.

| task | title | status | story | agent | waits on |
|---|---|---|---|---|---|
| T-2 | Base | closed (merged) | - | default (claude) | - |" show))
        (should (string-search (format "| T-3 | Left | in_progress, story in \
progress | %s at blocked (stopped) | default (claude) | - |" b)
                               show))
        (should (string-search (format "| T-4 | Right | open, held: its story \
%s was cancelled | - | default (claude) | - |" c)
                               show))
        (should (string-search "| T-5 | Join | open, waiting | - | default \
(claude) | T-3, T-4 |" show)))
      (should (string-search "Task: T-3, of the epic T-1 (Plan)"
                             (rat-kingdom-king-test--ok "story_show"
                                                        `(story . ,b))))
      ;; An archived story still says it.
      (should (string-search "Task: T-4, of the epic T-1 (Plan)"
                             (rat-kingdom-king-test--ok "story_show"
                                                        `(story . ,c)))))
    (should-not (rat-kingdom-reaction-failures space))))

(ert-deftest rat-kingdom-epic-dispatch-test-start-checks-the-epic ()
  (rat-kingdom-epic-dispatch-test-with-diamond (space fake)
    (dolist (case '((((epic . "T-2")) "T-2 is a task, not an epic")
                    (((epic . "T-9")) "The tracker of demo has no epic T-9")
                    (((epic . "T-1") (max_parallel . 0))
                     "max_parallel must be a whole number of at least 1")))
      (let ((answer (apply #'rat-kingdom-king-test--call "epic_start"
                           '(repo . "demo") (car case))))
        (should (cdr answer))
        (should (string-search (cadr case) (car answer)))))
    (let ((answer (rat-kingdom-king-test--call "epic_pause" '(epic . "T-1"))))
      (should (cdr answer))
      (should (string-search "The epic T-1 has not been started" (car answer))))
    (should-not (rat-kingdom-epic-record space "T-1"))
    (should-not (rat-kingdom-story-list space))))

;;;; Reloading

(ert-deftest rat-kingdom-epic-dispatch-test-reload-keeps-one-of-each ()
  (rat-kingdom-reload-test--isolated
    (let ((rat-kingdom-king-news-functions
           (copy-sequence rat-kingdom-king-news-functions))
          (rat-kingdom-king-status-functions
           (copy-sequence rat-kingdom-king-status-functions))
          (rat-kingdom-task-settled-functions
           (copy-sequence rat-kingdom-task-settled-functions)))
      (rat-kingdom-reload)
      (rat-kingdom-reload)
      (dolist (entry '((rat-kingdom-story-event-functions
                        . rat-kingdom-epic--story-event)
                       (rat-kingdom-king-news-functions
                        . rat-kingdom-epic--news)
                       (rat-kingdom-king-status-functions
                        . rat-kingdom-epic-status)
                       (rat-kingdom-task-settled-functions
                        . rat-kingdom-epic--story-settled)))
        (should (eql (cl-count (cdr entry) (symbol-value (car entry))) 1)))
      (dolist (reaction '(rat-kingdom-epic-dispatch-ready
                          rat-kingdom-epic-landing-checked))
        (should (eql (cl-count reaction rat-kingdom-reaction--registry
                               :key #'rat-kingdom-reaction-name)
                     1)))
      (dolist (name '("epic_start" "epic_pause" "epic_resume" "epic_cancel"
                      "epic_retry" "epic_show" "epic_diff" "epic_verdict"))
        (should (eql (cl-count name rat-kingdom-mcp--tools
                               :key (lambda (tool) (plist-get tool :name))
                               :test #'equal)
                     1)))
      (should (eq (rat-kingdom-space-category-modality 'epic) 'persistent)))))

(provide 'rat-kingdom-epic-dispatch-test)
;;; rat-kingdom-epic-dispatch-test.el ends here
