;;; rat-kingdom-epic-branch-test.el --- Tests for epics with a feature branch -*- lexical-binding: t; -*-

;;; Commentary:

;; Batch tests for a story's own target and for an epic run with a
;; feature branch: its stories merge into rk/epic/ID, the target moves
;; only after the epic's landing check and `epic_verdict' pass, and a
;; review that asks for changes, a target that moved and a check that
;; fails each come back as a task on the epic's branch.  They use real
;; Git in a disposable repository, the in-memory tracker, and the
;; backend that starts no agent; the tests play the workers.

;;; Code:

(require 'ert)
(require 'rat-kingdom)
(require 'rat-kingdom-epic)
(require 'rat-kingdom-story-test)
(require 'rat-kingdom-task-test)
(require 'rat-kingdom-king-test)
(require 'rat-kingdom-epic-test)
(require 'rat-kingdom-epic-dispatch-test)

(defconst rat-kingdom-epic-branch-test--pair
  "[{\"key\":\"a\",\"title\":\"Left\",\"description\":\"The left side.\"},
    {\"key\":\"b\",\"title\":\"Right\",\"description\":\"The right side.\"}]"
  "Two tasks that depend on nothing.
epic_create makes the epic T-1 and the tasks T-2 (a) and T-3 (b).")

(defmacro rat-kingdom-epic-branch-test-with-pair (vars &rest body)
  "Run BODY with VARS, (SPACE FAKE PATH), and the pair planned as the epic T-1.
PATH is the repository's checkout.  The king is running and has been
given nothing yet; story events reach the epic."
  (declare (indent 1) (debug t))
  `(rat-kingdom-epic-test-with-empty-tracker (,(nth 0 vars) ,(nth 1 vars))
     (let ((rat-kingdom-story-event-functions
            (cons #'rat-kingdom-epic--story-event
                  rat-kingdom-story-event-functions))
           (,(nth 2 vars) (plist-get (rat-kingdom-repo-get ,(nth 0 vars) "demo")
                                     :path)))
       (should-not (cdr (rat-kingdom-epic-test--epic
                         rat-kingdom-epic-branch-test--pair)))
       (rat-kingdom-space-retract ,(nth 0 vars) '(message))
       ,@body)))

(defun rat-kingdom-epic-branch-test--start (&rest arguments)
  "Call epic_start for T-1 of demo with a feature branch and ARGUMENTS."
  (apply #'rat-kingdom-epic-dispatch-test--start '(feature_branch . t)
         arguments))

(defun rat-kingdom-epic-branch-test--epic (space key)
  "Return what the record of the epic T-1 in SPACE has under KEY."
  (plist-get (plist-get (rat-kingdom-epic-record space "T-1") :payload) key))

(defun rat-kingdom-epic-branch-test--rev (path ref)
  "Return the commit REF names in the repository at PATH, or nil."
  (ignore-errors (rat-kingdom-git-rev path ref)))

(defun rat-kingdom-epic-branch-test--show (path ref file)
  "Return FILE as it is at REF in the repository at PATH, or nil."
  (ignore-errors (rat-kingdom-git path "show" (concat ref ":" file))))

(defun rat-kingdom-epic-branch-test--until (space predicate)
  "Run reactions in SPACE and wait until PREDICATE returns non-nil."
  (let ((tries 0))
    (while (and (not (funcall predicate)) (< (cl-incf tries) 300))
      (rat-kingdom-reaction-run space)
      (accept-process-output nil 0.02)))
  (rat-kingdom-reaction-run space)
  (should (funcall predicate)))

(defun rat-kingdom-epic-branch-test--landing (space value)
  "Wait until the epic T-1 in SPACE is landing and waits for VALUE."
  (rat-kingdom-epic-branch-test--until
   space (lambda ()
           (equal (rat-kingdom-epic-branch-test--epic space :landing) value))))

(defun rat-kingdom-epic-branch-test--set-check (space check)
  "Give the repository demo in SPACE the CHECK, a list of strings."
  (let ((tuple (rat-kingdom-space-rd space '(repo :identity "demo"))))
    (rat-kingdom-space-put space 'repo :scope "demo" :identity "demo"
                           :payload (plist-put (copy-sequence
                                                (plist-get tuple :payload))
                                               :check check)
                           :actor "user")))

(defun rat-kingdom-epic-branch-test--commit-on (path branch file text)
  "Commit FILE with TEXT on BRANCH of the repository at PATH, from aside."
  (let ((directory (make-temp-file "rat-kingdom-aside" t)))
    (delete-directory directory)
    (rat-kingdom-git path "worktree" "add" directory branch)
    (rat-kingdom-story-test--commit directory file text (concat "Aside: " file))
    (rat-kingdom-git path "worktree" "remove" "--force" directory)))

(defun rat-kingdom-epic-branch-test--merge-target (space fake task fix)
  "Play the worker of TASK's story in SPACE, which merges the target in.
It merges rk/integration into its branch, calls FIX in its worktree to
put right what that broke, commits, finishes, and is merged.  Wait
until FAKE has the task closed."
  (let ((story (or (rat-kingdom-epic-dispatch-test--story space task)
                   (error "No story for %s" task))))
    (rat-kingdom-reaction-run space)
    (let* ((payload (plist-get (rat-kingdom-story-get space story) :payload))
           (worktree (plist-get payload :worktree)))
      (rat-kingdom-git-ok-p worktree "merge" "--no-edit" "rk/integration")
      (funcall fix worktree)
      (rat-kingdom-git worktree "add" "-A")
      (rat-kingdom-git worktree "commit" "-m" "Merge rk/integration and fix it")
      (should-not (cdr (rat-kingdom-story-test--call
                        (plist-get payload :run) "finish"
                        '(summary . "Merged the target in.")
                        '(checks . "none run")))))
    (rat-kingdom-story-test--settle space story)
    (should-not (rat-kingdom-story-get space story))
    (rat-kingdom-epic-dispatch-test--drain
     (lambda () (equal (plist-get (rat-kingdom-task-test--task fake task)
                                  :status)
                       "closed")))
    (rat-kingdom-reaction-run space)
    story))

;;;; A story's own target

(ert-deftest rat-kingdom-epic-branch-test-story-start-with-a-target ()
  (rat-kingdom-story-test-with-repo (space path)
    (rat-kingdom-king-test--start space)
    (rat-kingdom-git path "branch" "feature" "rk/integration")
    (let ((integration (rat-kingdom-epic-branch-test--rev path "rk/integration")))
      ;; A branch that does not exist, or is checked out, is refused.
      (dolist (case '(("nope" "demo has no local branch nope")
                      ("main" "The branch main is checked out in a worktree \
of demo")))
        (let ((answer (rat-kingdom-king-test--call
                       "story_start" '(repo . "demo") '(title . "Add a file")
                       '(description . "Add it.") (cons 'target (car case)))))
          (should (cdr answer))
          (should (string-search (cadr case) (car answer)))))
      (should-not (rat-kingdom-story-list space))
      (should-error (rat-kingdom-story-start space "demo" "Add" "Add it." nil nil
                                             nil nil nil "nope"))
      ;; A story with a target of its own is cut from it and merged into it.
      (let* ((answer (rat-kingdom-king-test--ok
                      "story_start" '(repo . "demo") '(title . "Add a file")
                      '(description . "Add it.") '(target . "feature")))
             (id (progn (string-match "Started \\(S-[0-9a-f]+\\)" answer)
                        (match-string 1 answer))))
        (should (string-search "; it is cut from and merges into feature"
                               answer))
        (should (equal (rat-kingdom-story-test--get space id :target) "feature"))
        (should (equal (rat-kingdom-story-target
                        space (rat-kingdom-story-get space id))
                       "feature"))
        (rat-kingdom-reaction-run space)
        (should (string-search (format "Branch: rats/%s (cut from feature)" id)
                               (rat-kingdom-story-test--prompt
                                (concat id ".1"))))
        (rat-kingdom-story-test--commit path "local.txt" "local\n" "Local")
        (rat-kingdom-story-test--work space id "feature.txt")
        (rat-kingdom-story-test--settle space id)
        (should-not (rat-kingdom-story-get space id))
        (should (equal (rat-kingdom-epic-branch-test--show path "feature"
                                                           "feature.txt")
                       "work"))
        ;; The repository's target did not move.
        (should (equal (rat-kingdom-epic-branch-test--rev path "rk/integration")
                       integration))
        (should (string-search (format "is merged into feature of demo")
                               (car (rat-kingdom-king-test--news space))))
        (should (string-search "Merged into feature at"
                               (rat-kingdom-king-test--ok "story_show"
                                                          `(story . ,id))))))
    ;; Warnings are about the story's own target.
    (should (string-search "commits that feature lacks"
                           (car (rat-kingdom-story-warnings space "demo"
                                                            "feature"))))
    (should-not (rat-kingdom-reaction-failures space))))

;;;; Landing

(ert-deftest rat-kingdom-epic-branch-test-lands-after-the-verdict ()
  (rat-kingdom-epic-branch-test-with-pair (space fake path)
    (let ((log (expand-file-name "checks" rat-kingdom-directory))
          (integration (rat-kingdom-epic-branch-test--rev path "rk/integration")))
      (rat-kingdom-epic-branch-test--set-check
       space (list "sh" "-c" (format "echo ran >> %s"
                                     (shell-quote-argument log))))
      (let ((answer (rat-kingdom-epic-branch-test--start)))
        (should (string-search "Its stories merge into its feature branch \
rk/epic/T-1; rk/integration lands only after every task is closed" answer))
        (should (string-search "for T-2 (Left)" answer))
        (should (string-search "for T-3 (Right)" answer)))
      (should (equal (rat-kingdom-epic-branch-test--rev path "rk/epic/T-1")
                     integration))
      (should (equal (rat-kingdom-epic-branch-test--epic space :branch)
                     "rk/epic/T-1"))
      (should (equal (rat-kingdom-epic-branch-test--epic space :target)
                     "rk/integration"))
      (rat-kingdom-reaction-run space)
      ;; Both stories are cut from the epic's branch, and merge into it.
      (dolist (task '("T-2" "T-3"))
        (let ((story (rat-kingdom-epic-dispatch-test--story space task)))
          (should (equal (rat-kingdom-story-test--get space story :target)
                         "rk/epic/T-1"))
          (should (string-search "(cut from rk/epic/T-1)"
                                 (rat-kingdom-story-test--prompt
                                  (concat story ".1"))))))
      (should (string-search "    branch rk/epic/T-1, landing on \
rk/integration: once every task is closed, after one check and epic_verdict"
                             (rat-kingdom-king-test--ok "status")))
      (rat-kingdom-epic-dispatch-test--merge space fake "T-2")
      (should (equal (rat-kingdom-epic-dispatch-test--state space) "running"))
      (rat-kingdom-epic-dispatch-test--merge space fake "T-3")
      (dolist (task '("T-2" "T-3"))
        (should (cl-find-if (lambda (call)
                              (and (eq (car call) 'close)
                                   (equal (cadr call) task)
                                   (string-prefix-p "Merged into rk/epic/T-1 at"
                                                    (caddr call))))
                            (rat-kingdom-task-test-fake-calls fake))))
      ;; The target has not moved; the branch has both.
      (should (equal (rat-kingdom-epic-branch-test--rev path "rk/integration")
                     integration))
      (should (equal (rat-kingdom-epic-branch-test--show path "rk/epic/T-1"
                                                         "T-3.txt")
                     "work"))
      ;; Every task is closed: the epic lands, through a check, and asks
      ;; for a review rather than being done.
      (should (equal (rat-kingdom-epic-dispatch-test--state space) "landing"))
      (rat-kingdom-epic-branch-test--landing space "review")
      (should (eql (length (split-string
                            (with-temp-buffer (insert-file-contents log)
                                              (buffer-string))
                            "\n" t))
                   3))
      (should (member "Epic T-1 (Plan) is ready to land on rk/integration: 2 \
stories, review with epic_diff and give epic_verdict."
                      (rat-kingdom-king-test--news space)))
      (should-not (assoc "T-1" (cl-remove-if-not
                                (lambda (call) (eq (car call) 'close))
                                (rat-kingdom-task-test-fake-calls fake))))
      (should (equal (rat-kingdom-epic-branch-test--rev path "rk/integration")
                     integration))
      (should (string-search "- T-1 [demo] Plan: landing, 2/2 merged
    branch rk/epic/T-1, landing on rk/integration: waiting for your review \
(epic_diff, then epic_verdict)"
                             (rat-kingdom-king-test--ok "status")))
      (should (string-search "Feature branch rk/epic/T-1, landing on \
rk/integration: waiting for your review"
                             (rat-kingdom-king-test--ok "epic_show"
                                                        '(epic . "T-1"))))
      ;; epic_diff shows the whole of it against the target.
      (let ((diff (rat-kingdom-king-test--ok "epic_diff" '(epic . "T-1"))))
        (should (string-prefix-p "Epic T-1 (Plan): its branch rk/epic/T-1 \
against rk/integration, with 2 stories merged." diff))
        (should (string-search "Add T-2.txt" diff))
        (should (string-search "Add T-3.txt" diff))
        (should (string-match-p "T-2.txt | 1 \\+" diff))
        (should (string-search "+++ b/T-3.txt" diff))
        (should (string-search "+work" diff)))
      ;; A verdict needs a value it knows, and fix needs notes.
      (dolist (case '((((value . "maybe")) "A verdict is pass or fix")
                      (((value . "fix")) "needs notes")))
        (let ((answer (apply #'rat-kingdom-king-test--call "epic_verdict"
                             '(epic . "T-1") (car case))))
          (should (cdr answer))
          (should (string-search (cadr case) (car answer)))))
      ;; Pass moves the target, once, and the epic is done.
      (let ((answer (rat-kingdom-king-test--ok "epic_verdict" '(epic . "T-1")
                                               '(value . "pass")))
            (landed (rat-kingdom-epic-branch-test--rev path "rk/integration")))
        (should (string-search (format "Landed the epic T-1 (Plan) on \
rk/integration at %s. It is done and the br epic is closed. Its branch \
rk/epic/T-1 is kept" (substring landed 0 7))
                               answer))
        (should (equal (rat-kingdom-git path "rev-parse" (concat landed "^1"))
                       integration))
        (should (equal (rat-kingdom-git path "rev-parse" (concat landed "^2"))
                       (rat-kingdom-epic-branch-test--rev path "rk/epic/T-1")))
        (should (member (list 'close "T-1" (format "Landed on rk/integration \
at %s" (substring landed 0 7)))
                        (rat-kingdom-task-test-fake-calls fake)))
        (should (cl-find-if (lambda (text)
                              (string-prefix-p (format "Epic T-1 (Plan) landed \
on rk/integration at %s: 2 stories. The br epic T-1 is closed. Its branch \
rk/epic/T-1 is kept" (substring landed 0 7))
                                               text))
                            (rat-kingdom-king-test--news space))))
      (dolist (file '("T-2.txt" "T-3.txt"))
        (should (equal (rat-kingdom-epic-branch-test--show
                        path "rk/integration" file)
                       "work")))
      (should (equal (rat-kingdom-epic-dispatch-test--state space) "done"))
      (should (rat-kingdom-epic-branch-test--rev path "rk/epic/T-1"))
      (should-not (file-exists-p (rat-kingdom-epic--candidate "demo" "T-1")))
      (should-not (rat-kingdom-space-rd space '(checked :identity "T-1")))
      ;; A verdict once it is done is refused.
      (should (cdr (rat-kingdom-king-test--call "epic_verdict" '(epic . "T-1")
                                                '(value . "pass")))))
    (should-not (rat-kingdom-reaction-failures space))))

(ert-deftest rat-kingdom-epic-branch-test-verdict-fix ()
  (rat-kingdom-epic-branch-test-with-pair (space fake path)
    (rat-kingdom-epic-branch-test--start)
    (rat-kingdom-epic-dispatch-test--merge space fake "T-2")
    (rat-kingdom-epic-dispatch-test--merge space fake "T-3")
    (rat-kingdom-epic-branch-test--landing space "review")
    (let ((integration (rat-kingdom-epic-branch-test--rev path "rk/integration"))
          (answer (rat-kingdom-king-test--ok "epic_verdict" '(epic . "T-1")
                                             '(value . "fix")
                                             '(notes . "Add a fourth file."))))
      (should (string-match "Created the task T-4 in the epic with your notes. \
Started \\(S-[0-9a-f]+\\) for it on rk/epic/T-1." answer))
      (should (equal (match-string 1 answer)
                     (rat-kingdom-epic-dispatch-test--story space "T-4")))
      (let ((task (rat-kingdom-task-test--task fake "T-4")))
        (should (equal (plist-get task :parent) "T-1"))
        (should (equal (plist-get task :description) "Add a fourth file.")))
      (should (equal (rat-kingdom-epic-dispatch-test--state space) "running"))
      (should (equal (rat-kingdom-epic-branch-test--epic space :fix-task) "T-4"))
      (should (string-search "landing on rk/integration: waiting for the task \
T-4 to be merged, then checked again"
                             (rat-kingdom-king-test--ok "status")))
      (should (equal (rat-kingdom-story-test--get
                      space (rat-kingdom-epic-dispatch-test--story space "T-4")
                      :target)
                     "rk/epic/T-1"))
      ;; Once it is merged into the branch, the epic lands again.
      (rat-kingdom-epic-dispatch-test--merge space fake "T-4")
      (should (equal (rat-kingdom-epic-branch-test--show path "rk/epic/T-1"
                                                         "T-4.txt")
                     "work"))
      (should (equal (rat-kingdom-epic-branch-test--rev path "rk/integration")
                     integration))
      (rat-kingdom-epic-branch-test--landing space "review")
      (should (member "Epic T-1 (Plan) is ready to land on rk/integration: 3 \
stories, review with epic_diff and give epic_verdict."
                      (rat-kingdom-king-test--news space)))
      (rat-kingdom-king-test--ok "epic_verdict" '(epic . "T-1")
                                 '(value . "pass"))
      (should (equal (rat-kingdom-epic-branch-test--show path "rk/integration"
                                                         "T-4.txt")
                     "work"))
      (should (equal (rat-kingdom-epic-dispatch-test--state space) "done")))
    (should-not (rat-kingdom-reaction-failures space))))

(ert-deftest rat-kingdom-epic-branch-test-target-moved-with-a-conflict ()
  (rat-kingdom-epic-branch-test-with-pair (space fake path)
    (rat-kingdom-epic-branch-test--start)
    (rat-kingdom-epic-dispatch-test--merge space fake "T-2")
    ;; Meanwhile someone changes the same file on the target.
    (rat-kingdom-epic-branch-test--commit-on path "rk/integration" "T-2.txt"
                                             "other\n")
    (let ((moved (rat-kingdom-epic-branch-test--rev path "rk/integration")))
      (rat-kingdom-epic-dispatch-test--merge space fake "T-3")
      ;; The merge conflicts: that is a task on the epic's branch.
      (rat-kingdom-epic-branch-test--landing space "fix")
      (should (equal (rat-kingdom-epic-dispatch-test--state space) "running"))
      (let ((task (rat-kingdom-task-test--task fake "T-4")))
        (should (equal (plist-get task :title)
                       "Merge rk/integration into the epic branch and fix what \
breaks"))
        (should (equal (plist-get task :parent) "T-1"))
        (should (string-search "its branch rk/epic/T-1 no longer merges \
cleanly into rk/integration" (plist-get task :description)))
        (should (string-search "Merge rk/integration into your branch (git \
merge rk/integration), resolve the conflicts"
                               (plist-get task :description)))
        (should (string-suffix-p "Files in conflict:\nT-2.txt"
                                 (plist-get task :description))))
      (should (cl-find-if (lambda (text)
                            (string-prefix-p "Epic T-1 (Plan) cannot land on \
rk/integration yet: its branch no longer merges cleanly into rk/integration, \
which has moved on (in conflict: T-2.txt). Created the task T-4" text))
                          (rat-kingdom-king-test--news space)))
      (let ((story (rat-kingdom-epic-dispatch-test--story space "T-4")))
        (should story)
        (rat-kingdom-reaction-run space)
        (should (string-search "(cut from rk/epic/T-1)"
                               (rat-kingdom-story-test--prompt
                                (concat story ".1")))))
      ;; Its worker merges the target in and resolves the conflict; its
      ;; story merges into the epic's branch, and the epic lands again.
      (rat-kingdom-epic-branch-test--merge-target
       space fake "T-4"
       (lambda (worktree)
         (with-temp-file (expand-file-name "T-2.txt" worktree)
           (insert "both\n"))))
      (should (equal (rat-kingdom-epic-branch-test--rev path "rk/integration")
                     moved))
      (rat-kingdom-epic-branch-test--landing space "review")
      (rat-kingdom-king-test--ok "epic_verdict" '(epic . "T-1")
                                 '(value . "pass"))
      (should (equal (rat-kingdom-epic-branch-test--show path "rk/integration"
                                                         "T-2.txt")
                     "both"))
      (should (rat-kingdom-epic-branch-test--show path "rk/integration"
                                                  "T-3.txt"))
      (should (equal (rat-kingdom-epic-dispatch-test--state space) "done")))
    (should-not (rat-kingdom-reaction-failures space))))

(ert-deftest rat-kingdom-epic-branch-test-failing-check-on-landing ()
  (rat-kingdom-epic-branch-test-with-pair (space fake path)
    (rat-kingdom-epic-branch-test--set-check space '("sh" "-c" "test ! -e bad"))
    (rat-kingdom-epic-branch-test--start)
    ;; The target gains something that breaks the check, which the
    ;; stories, checked on the epic's branch, do not see.
    (rat-kingdom-epic-branch-test--commit-on path "rk/integration" "bad" "x\n")
    (rat-kingdom-epic-dispatch-test--merge space fake "T-2")
    (rat-kingdom-epic-dispatch-test--merge space fake "T-3")
    (rat-kingdom-epic-branch-test--landing space "fix")
    (let ((task (rat-kingdom-task-test--task fake "T-4")))
      (should (equal (plist-get task :title)
                     "Merge rk/integration into the epic branch and fix what \
breaks"))
      (should (string-search "with its branch rk/epic/T-1 merged into \
rk/integration, the check sh -c \"test ! -e bad\" exited with 1"
                             (plist-get task :description)))
      (should (string-search "fix what breaks, make sure the repository's \
check passes" (plist-get task :description))))
    (should (cl-find-if (lambda (text)
                          (string-search "cannot land on rk/integration yet: \
the check failed with the branch merged (exit 1)" text))
                        (rat-kingdom-king-test--news space)))
    (should (equal (rat-kingdom-story-test--get
                    space (rat-kingdom-epic-dispatch-test--story space "T-4")
                    :target)
                   "rk/epic/T-1"))
    ;; Its worker merges the target in and fixes it; the epic lands.
    (rat-kingdom-epic-branch-test--merge-target
     space fake "T-4"
     (lambda (worktree) (delete-file (expand-file-name "bad" worktree))))
    (rat-kingdom-epic-branch-test--landing space "review")
    (rat-kingdom-king-test--ok "epic_verdict" '(epic . "T-1") '(value . "pass"))
    (should-not (rat-kingdom-epic-branch-test--show path "rk/integration" "bad"))
    (should (equal (rat-kingdom-epic-dispatch-test--state space) "done"))
    (should-not (rat-kingdom-reaction-failures space))))

(ert-deftest rat-kingdom-epic-branch-test-target-moved-after-the-check ()
  (rat-kingdom-epic-branch-test-with-pair (space fake path)
    (rat-kingdom-epic-branch-test--start)
    (rat-kingdom-epic-dispatch-test--merge space fake "T-2")
    (rat-kingdom-epic-dispatch-test--merge space fake "T-3")
    (rat-kingdom-epic-branch-test--landing space "review")
    ;; The target moves, without a conflict, after the check.
    (rat-kingdom-epic-branch-test--commit-on path "rk/integration" "side.txt"
                                             "side\n")
    (let ((answer (rat-kingdom-king-test--ok "epic_verdict" '(epic . "T-1")
                                             '(value . "pass"))))
      (should (string-search "so the epic is checked again on top of it; if \
that passes it lands without another review" answer)))
    ;; It is checked again and lands without asking again.
    (rat-kingdom-epic-branch-test--until
     space (lambda () (equal (rat-kingdom-epic-dispatch-test--state space)
                             "done")))
    (dolist (file '("side.txt" "T-2.txt" "T-3.txt"))
      (should (rat-kingdom-epic-branch-test--show path "rk/integration" file)))
    (should (eql (cl-count-if (lambda (text) (string-search "is ready to land"
                                                            text))
                              (rat-kingdom-king-test--news space))
                 1))
    (should-not (rat-kingdom-reaction-failures space))))

;;;; Recovery

(ert-deftest rat-kingdom-epic-branch-test-recovers-an-interrupted-landing ()
  (rat-kingdom-epic-branch-test-with-pair (space fake path)
    (rat-kingdom-epic-branch-test--start)
    ;; The stories merge while nothing moves the epic on.
    (let ((rat-kingdom-task-settled-functions nil))
      (rat-kingdom-epic-dispatch-test--merge space fake "T-2")
      (rat-kingdom-epic-dispatch-test--merge space fake "T-3"))
    ;; Landing begins with a check that takes its time.
    (rat-kingdom-epic-branch-test--set-check space '("sleep" "30"))
    (should (rat-kingdom-epic--finish-if-done space "demo" "T-1"))
    (should (equal (rat-kingdom-epic-dispatch-test--state space) "landing"))
    (should (equal (rat-kingdom-epic-branch-test--epic space :landing) "check"))
    (should (process-live-p (gethash "T-1" rat-kingdom-story--checks)))
    (should (string-search "waiting for the check of the branch merged into it"
                           (rat-kingdom-epic-show space "T-1")))
    ;; A check that runs is not run again.
    (should-not (rat-kingdom-epic-reconcile space))
    ;; Emacs stops: the check dies with it, and nothing in memory
    ;; survives.
    (let ((file (expand-file-name "space.db" rat-kingdom-directory)))
      (rat-kingdom-story--abandon-check "T-1")
      (rat-kingdom-space-close space)
      (setq space (rat-kingdom-space-open file)
            rat-kingdom-space--default space)
      (clrhash rat-kingdom-run--handles)
      (clrhash rat-kingdom-mcp--grants))
    (should (equal (rat-kingdom-epic-dispatch-test--state space) "landing"))
    (rat-kingdom-epic-branch-test--set-check space nil)
    ;; Reconciling runs the landing check again.
    (should (equal (plist-get (rat-kingdom-reconcile) :landings) '("T-1")))
    (rat-kingdom-epic-branch-test--landing space "review")
    (should (member "Epic T-1 (Plan) is ready to land on rk/integration: 2 \
stories, review with epic_diff and give epic_verdict."
                    (rat-kingdom-king-test--news space)))
    (should-not (rat-kingdom-epic-reconcile space))
    (should (string-prefix-p "Landed the epic T-1 (Plan) on rk/integration"
                             (rat-kingdom-epic-verdict space "T-1" "pass")))
    (should (rat-kingdom-epic-branch-test--show path "rk/integration" "T-3.txt"))
    (should (equal (rat-kingdom-epic-dispatch-test--state space) "done"))
    (should-not (rat-kingdom-reaction-failures space))))

;;;; Starting, joining and cancelling

(ert-deftest rat-kingdom-epic-branch-test-without-a-feature-branch ()
  (rat-kingdom-epic-branch-test-with-pair (space fake path)
    (let ((answer (rat-kingdom-epic-dispatch-test--start
                   '(feature_branch . :false))))
      (should-not (string-search "feature branch" answer)))
    (should-not (rat-kingdom-epic-branch-test--epic space :branch))
    (should-not (rat-kingdom-epic-branch-test--rev path "rk/epic/T-1"))
    (should-not (rat-kingdom-story-test--get
                 space (rat-kingdom-epic-dispatch-test--story space "T-2")
                 :target))
    (should-not (string-search "landing" (rat-kingdom-king-test--ok "status")))
    (let ((answer (rat-kingdom-king-test--call "epic_diff" '(epic . "T-1"))))
      (should (cdr answer))
      (should (string-search "has no feature branch" (car answer))))
    (rat-kingdom-epic-dispatch-test--merge space fake "T-2")
    ;; Each story merges into the target as it passes.
    (should (equal (rat-kingdom-epic-branch-test--show path "rk/integration"
                                                       "T-2.txt")
                   "work"))
    (rat-kingdom-epic-dispatch-test--merge space fake "T-3")
    (rat-kingdom-epic-dispatch-test--drain
     (lambda () (equal (rat-kingdom-epic-dispatch-test--state space) "done")))
    (should (equal (rat-kingdom-epic-dispatch-test--state space) "done"))
    (should (member '(close "T-1" "All 2 tasks merged")
                    (rat-kingdom-task-test-fake-calls fake)))
    (let ((answer (rat-kingdom-king-test--call "epic_verdict" '(epic . "T-1")
                                               '(value . "pass"))))
      (should (cdr answer))
      (should (string-search "is not waiting for a verdict" (car answer))))
    (should-not (rat-kingdom-reaction-failures space))))

(ert-deftest rat-kingdom-epic-branch-test-existing-branch ()
  (rat-kingdom-epic-branch-test-with-pair (space _fake path)
    ;; A branch that has diverged from the target is refused.
    (rat-kingdom-git path "branch" "rk/epic/T-1" "rk/integration")
    (rat-kingdom-epic-branch-test--commit-on path "rk/epic/T-1" "mine.txt" "m\n")
    (rat-kingdom-epic-branch-test--commit-on path "rk/integration" "theirs.txt"
                                             "t\n")
    (let ((answer (rat-kingdom-king-test--call "epic_start" '(repo . "demo")
                                               '(epic . "T-1")
                                               '(feature_branch . t))))
      (should (cdr answer))
      (should (string-search "The branch rk/epic/T-1 already exists and has \
diverged from rk/integration" (car answer))))
    (should-not (rat-kingdom-epic-record space "T-1"))
    (should-not (rat-kingdom-story-list space))
    ;; One that continues from the target is kept as it is.
    (rat-kingdom-git path "branch" "-f" "rk/epic/T-1" "rk/integration")
    (rat-kingdom-epic-branch-test--commit-on path "rk/epic/T-1" "mine.txt" "m\n")
    (should (equal (rat-kingdom-epic--prepare-branch
                    path "rk/epic/T-1" "rk/integration")
                   "Kept the branch rk/epic/T-1, which already continues from \
rk/integration."))
    ;; One behind the target with nothing of its own is moved forward.
    (rat-kingdom-git path "branch" "-f" "rk/epic/T-1" "rk/integration~1")
    (should (string-prefix-p "Moved the branch rk/epic/T-1"
                             (rat-kingdom-epic--prepare-branch
                              path "rk/epic/T-1" "rk/integration")))
    (should (equal (rat-kingdom-epic-branch-test--rev path "rk/epic/T-1")
                   (rat-kingdom-epic-branch-test--rev path "rk/integration")))
    (rat-kingdom-epic-branch-test--start)
    (should (equal (rat-kingdom-story-test--get
                    space (rat-kingdom-epic-dispatch-test--story space "T-2")
                    :target)
                   "rk/epic/T-1"))
    (should-not (rat-kingdom-reaction-failures space))))

(ert-deftest rat-kingdom-epic-branch-test-story-start-joins-the-branch ()
  (rat-kingdom-epic-branch-test-with-pair (space fake path)
    (rat-kingdom-epic-branch-test--start '(max_parallel . 1))
    (rat-kingdom-king-test--ok "epic_pause" '(epic . "T-1"))
    ;; The king starts the other task itself: it gets the epic's branch.
    (let* ((answer (rat-kingdom-king-test--ok "story_start" '(repo . "demo")
                                              '(task . "T-3")))
           (story (rat-kingdom-epic-dispatch-test--story space "T-3")))
      (should (string-search ", as a story of the epic T-1; it is cut from \
and merges into rk/epic/T-1." answer))
      (should (equal (rat-kingdom-story-test--get space story :target)
                     "rk/epic/T-1")))
    (rat-kingdom-epic-dispatch-test--merge space fake "T-3")
    (should (rat-kingdom-epic-branch-test--show path "rk/epic/T-1" "T-3.txt"))
    (should-not (rat-kingdom-epic-branch-test--show path "rk/integration"
                                                    "T-3.txt"))
    (should-not (rat-kingdom-reaction-failures space))))

(ert-deftest rat-kingdom-epic-branch-test-cancel-keeps-the-branch ()
  (rat-kingdom-epic-branch-test-with-pair (space fake path)
    (rat-kingdom-epic-branch-test--start)
    (rat-kingdom-epic-dispatch-test--merge space fake "T-2")
    (let ((answer (rat-kingdom-king-test--ok "epic_cancel" '(epic . "T-1"))))
      (should (string-search "Its feature branch rk/epic/T-1 is kept, with \
what its stories merged; rk/integration has not moved for it." answer)))
    (should (equal (rat-kingdom-epic-dispatch-test--state space) "cancelled"))
    (should (equal (rat-kingdom-epic-branch-test--show path "rk/epic/T-1"
                                                       "T-2.txt")
                   "work"))
    (should-not (rat-kingdom-epic-branch-test--show path "rk/integration"
                                                    "T-2.txt"))
    (should-not (rat-kingdom-reaction-failures space))))

(provide 'rat-kingdom-epic-branch-test)
;;; rat-kingdom-epic-branch-test.el ends here
