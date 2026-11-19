;;; rat-kingdom-child-test.el --- :workflow steps and child stories -*- lexical-binding: t; -*-

;;; Commentary:

;; Batch tests of the `:workflow' step of DESIGN.md section 7.1: a step
;; that runs a child story in its parent's worktree and waits for it.
;; They use disposable repositories and the fake agents of
;; rat-kingdom-story-test.el, with commands named in the repository's
;; .rk/config.eld as in rat-kingdom-steps-test.el.

;;; Code:

(require 'ert)
(require 'rat-kingdom-test-helper)
(require 'rat-kingdom-story-test)
(require 'rat-kingdom-steps-test)
(require 'rat-kingdom-task-test)

(defun rat-kingdom-child-test--define-lint ()
  "Define the workflow lint: a `:run' of fmt, then a `:check' of test."
  (rat-kingdom-workflow-define
   'lint
   :places '(formatting checking done blocked)
   :start 'formatting :final '(done)
   :steps '((format :from formatting :run (fmt) :pass checking :fail blocked)
            (check :from checking :check (test) :pass done :fail blocked))))

(defun rat-kingdom-child-test--define-parent (&optional fail)
  "Define the workflow parent, which runs lint as its step lint.
Its step lint fails to FAIL, by default ready."
  (rat-kingdom-workflow-define
   'parent
   :places '(ready linting integrating done blocked)
   :start 'ready :final '(done)
   :steps `((implement :from ready :spawn rat :to linting)
            (lint :from linting :workflow lint :to integrating
                  :fail ,(or fail 'ready))
            (integrate :from integrating :merge t :to done
                       :stale linting))))

(defun rat-kingdom-child-test--archived (space id)
  "Return the last archived token of the story ID in SPACE."
  (cl-find 'story (reverse (rat-kingdom-space-archived space id))
           :key (lambda (tuple) (plist-get tuple :category))))

(defun rat-kingdom-child-test--king (tool &rest arguments)
  "Call the king's TOOL with ARGUMENTS, an alist, and return its text."
  (car (apply #'rat-kingdom-steps-test--king tool arguments)))

;;;; A child that passes

(ert-deftest rat-kingdom-child-test-child-passes ()
  (rat-kingdom-steps-test-with-repo (space path)
    (rat-kingdom-child-test--define-lint)
    (rat-kingdom-child-test--define-parent)
    (rat-kingdom-steps-test--commands
     path '(:fmt ("sh" "-c" "for f in *.txt; do tr a-z A-Z < $f > $f.new \
&& mv $f.new $f; done")
            :test ("sh" "-c" "grep -q WORK feature.txt")))
    (rat-kingdom-story-start space "demo" "Add a file" "Add feature.txt."
                             "S-1" 'parent)
    (rat-kingdom-reaction-run space)
    (rat-kingdom-story-test--work space "S-1" "feature.txt")
    (rat-kingdom-reaction-run space)
    (let* ((worktree (rat-kingdom-story-test--get space "S-1" :worktree))
           (branch (rat-kingdom-story-test--get space "S-1" :branch))
           (commit (rat-kingdom-story-test--get space "S-1" :commit))
           (child (plist-get (rat-kingdom-story-get space "S-1/lint")
                             :payload)))
      ;; The parent waits for its child, which has its worktree, branch
      ;; and commit, and is one deeper.
      (should (equal (rat-kingdom-story-test--get space "S-1" :awaiting)
                     "child"))
      (should (equal (rat-kingdom-story-test--get space "S-1" :child)
                     "S-1/lint"))
      (should (equal (plist-get child :parent) "S-1"))
      (should (eql (plist-get child :depth) 1))
      (should (equal (plist-get child :workflow) "lint"))
      (should (equal (plist-get child :title) "Add a file (lint)"))
      (should (equal (plist-get child :description) "Add feature.txt."))
      (should (equal (plist-get child :worktree) worktree))
      (should (equal (plist-get child :branch) branch))
      (should (equal (plist-get child :commit) commit))
      (should (equal (plist-get child :target) "rk/integration"))
      (should-not (plist-get child :task))
      (should-not (plist-get child :epic))
      ;; It is listed under its parent, and each names the other.
      (let ((status (rat-kingdom-child-test--king "status")))
        (should (string-match-p "^- S-1 \\[demo\\] linting (waiting for \
child: the child story S-1/lint, at formatting)" status))
        (should (string-match-p "^- S-1 .*\n  - S-1/lint \\[demo\\]" status)))
      (should (string-search "Child stories: S-1/lint (at formatting)"
                             (rat-kingdom-king--show space "S-1")))
      (should (string-search "Child story of S-1"
                             (rat-kingdom-king--show space "S-1/lint")))
      ;; Its :run formats the file and commits in the shared worktree.
      (rat-kingdom-steps-test--settle-run space "S-1/lint")
      (should (equal (rat-kingdom-story-test--place space "S-1/lint")
                     "checking"))
      (should (string-search
               "candidates/demo/S-1+lint"
               (rat-kingdom-story-test--get space "S-1/lint" :candidate)))
      (let ((formatted (rat-kingdom-git-rev worktree "HEAD")))
        (should-not (equal formatted commit))
        (rat-kingdom-story-test--settle space "S-1/lint")
        ;; The child is archived, and the parent took its commit and
        ;; merge, and was merged.
        (should-not (rat-kingdom-story-get space "S-1/lint"))
        (should (equal (plist-get (plist-get (rat-kingdom-child-test--archived
                                              space "S-1/lint")
                                             :payload)
                                  :phase)
                       "done"))
        (should-not (rat-kingdom-story-get space "S-1"))
        (let ((parent (plist-get (rat-kingdom-child-test--archived space "S-1")
                                 :payload)))
          (should (equal (plist-get parent :commit) formatted))
          (should (plist-get parent :integrated))
          (should (equal (plist-get parent :children) '("S-1/lint"))))
        (should (equal (rat-kingdom-story-test--git
                        path "show" "rk/integration:feature.txt")
                       "WORK"))
        ;; The child's candidate is gone; the parent's merge removed
        ;; the worktree.
        (should-not (file-exists-p
                     (expand-file-name "candidates/demo/S-1+lint"
                                       rat-kingdom-directory)))
        (should-not (file-exists-p worktree))))
    (should (member '(done . "S-1/lint") rat-kingdom-story-test--events))
    (should-not (rat-kingdom-reaction-failures space))))

;;;; A child that fails

(ert-deftest rat-kingdom-child-test-child-fails ()
  (rat-kingdom-steps-test-with-repo (space path)
    (rat-kingdom-child-test--define-lint)
    (rat-kingdom-child-test--define-parent)
    (rat-kingdom-steps-test--commands
     path '(:fmt ("sh" "-c" "echo too many words; exit 3")
            :test ("true")))
    (rat-kingdom-story-start space "demo" "Add a file" nil "S-1" 'parent)
    (rat-kingdom-reaction-run space)
    (rat-kingdom-story-test--work space "S-1" "feature.txt")
    (rat-kingdom-reaction-run space)
    (let ((worktree (rat-kingdom-story-test--get space "S-1" :worktree)))
      (rat-kingdom-steps-test--settle-run space "S-1/lint")
      ;; The child is archived at its failure place, and the parent's
      ;; step failed with its reason, back to a new worker.
      (should-not (rat-kingdom-story-get space "S-1/lint"))
      (should (equal (plist-get (plist-get (rat-kingdom-child-test--archived
                                            space "S-1/lint")
                                           :payload)
                                :at)
                     "blocked"))
      (should (equal (rat-kingdom-story-test--place space "S-1") "ready"))
      (should (equal (rat-kingdom-story-test--get space "S-1" :run) "S-1.2"))
      (let ((prompt (rat-kingdom-story-test--prompt "S-1.2")))
        (should (string-search "The child S-1/lint stopped at blocked: run \
failed: the command fmt (sh -c" prompt))
        (should (string-search "too many words" prompt)))
      ;; The worktree is left as it was; the child's park is not news.
      (should (file-directory-p worktree))
      (should-not (member '(parked . "S-1/lint") rat-kingdom-story-test--events))
      ;; The step run again has a new child.
      (rat-kingdom-steps-test--commands path '(:fmt ("true") :test ("true")))
      (rat-kingdom-story-test--work space "S-1" "more.txt")
      (rat-kingdom-reaction-run space)
      (should (equal (rat-kingdom-story-test--get space "S-1" :child)
                     "S-1/lint-2"))
      (rat-kingdom-steps-test--settle-run space "S-1/lint-2")
      (rat-kingdom-story-test--settle space "S-1/lint-2")
      (should-not (rat-kingdom-story-get space "S-1"))
      (should (equal (plist-get (plist-get (rat-kingdom-child-test--archived
                                            space "S-1")
                                           :payload)
                                :children)
                     '("S-1/lint" "S-1/lint-2"))))
    (should-not (rat-kingdom-reaction-failures space))))

;;;; Cancelling and moving

(defun rat-kingdom-child-test--define-waiting ()
  "Define held, a workflow whose child waits at a gate, and its parent."
  (rat-kingdom-workflow-define
   'held
   :places '(waiting done blocked)
   :start 'waiting :final '(done)
   :steps '((hold :from waiting :gate (:signal go) :to done)))
  (rat-kingdom-workflow-define
   'holder
   :places '(ready holding done blocked)
   :start 'ready :final '(done)
   :steps '((implement :from ready :spawn rat :to holding)
            (hold :from holding :workflow held :to done :fail blocked))))

(ert-deftest rat-kingdom-child-test-cancelling-the-parent ()
  (rat-kingdom-steps-test-with-repo (space path)
    (rat-kingdom-child-test--define-lint)
    (rat-kingdom-child-test--define-parent)
    (rat-kingdom-steps-test--commands
     path '(:fmt ("sleep" "30") :test ("true")))
    (rat-kingdom-story-start space "demo" "Add a file" nil "S-1" 'parent)
    (rat-kingdom-reaction-run space)
    (rat-kingdom-story-test--work space "S-1" "feature.txt")
    (rat-kingdom-reaction-run space)
    (let ((worktree (rat-kingdom-story-test--get space "S-1" :worktree))
          (branch (rat-kingdom-story-test--get space "S-1" :branch)))
      ;; The child's run is in progress.
      (should (equal (rat-kingdom-story-test--get space "S-1/lint" :awaiting)
                     "run"))
      (should (equal (car (rat-kingdom-story-running "S-1/lint")) "fmt"))
      (rat-kingdom-story-cancel space "S-1")
      (rat-kingdom-reaction-run space)
      ;; Both are archived, the child cancelled, its run stopped; the
      ;; worktree and branch are kept.
      (should-not (rat-kingdom-story-get space "S-1"))
      (should-not (rat-kingdom-story-get space "S-1/lint"))
      (should-not (rat-kingdom-story-running "S-1/lint"))
      (should-not (gethash "S-1/lint" rat-kingdom-story--checks))
      (should (equal (plist-get (plist-get (rat-kingdom-child-test--archived
                                            space "S-1/lint")
                                           :payload)
                                :phase)
                     "cancelled"))
      (should (file-directory-p worktree))
      (should (rat-kingdom-git-ok-p path "rev-parse" "--verify" "--quiet"
                                    (concat "refs/heads/" branch))))
    (should-not (rat-kingdom-reaction-failures space))))

(ert-deftest rat-kingdom-child-test-moving-parent-and-child ()
  (rat-kingdom-steps-test-with-repo (space _path)
    (rat-kingdom-child-test--define-waiting)
    (rat-kingdom-story-start space "demo" "Add a file" nil "S-1" 'holder)
    (rat-kingdom-reaction-run space)
    (rat-kingdom-story-test--work space "S-1" "feature.txt")
    (rat-kingdom-reaction-run space)
    (should (equal (rat-kingdom-story-test--get space "S-1/hold" :awaiting)
                   "gate"))
    ;; Moving the parent cancels the child.
    (rat-kingdom-story-move space "S-1" "holding")
    (rat-kingdom-reaction-run space)
    (should-not (rat-kingdom-story-get space "S-1/hold"))
    (should (equal (rat-kingdom-story-test--get space "S-1" :child)
                   "S-1/hold-2"))
    ;; Moving the child by hand works as for any story: to its final
    ;; place, which moves the parent on by :to.
    (rat-kingdom-story-move space "S-1/hold-2" "done")
    (rat-kingdom-reaction-run space)
    (should-not (rat-kingdom-story-get space "S-1/hold-2"))
    (should-not (rat-kingdom-story-get space "S-1"))
    (should (equal (plist-get (plist-get (rat-kingdom-child-test--archived
                                          space "S-1")
                                         :payload)
                              :at)
                   "done"))
    ;; Cancelling the child alone fails the parent's step.
    (rat-kingdom-story-start space "demo" "Another" nil "S-2" 'holder)
    (rat-kingdom-reaction-run space)
    (rat-kingdom-story-test--work space "S-2" "other.txt")
    (rat-kingdom-reaction-run space)
    ;; Its gate opens by a signal to its own id.
    (should (rat-kingdom-story-get space "S-2/hold"))
    (rat-kingdom-story-cancel space "S-2/hold")
    (rat-kingdom-reaction-run space)
    (should (equal (rat-kingdom-story-test--place space "S-2") "blocked"))
    (should (equal (rat-kingdom-story-test--get space "S-2" :reason)
                   "The child S-2/hold was cancelled"))
    (should-not (rat-kingdom-reaction-failures space))))

;;;; Limits

(defun rat-kingdom-child-test--define-chain (from to)
  "Define the workflows nFROM to nTO, each running the next as a child.
nTO waits at a gate for the signal go."
  (cl-loop for n from from to to
           do (rat-kingdom-workflow-define
               (intern (format "n%d" n))
               :places '(waiting done blocked)
               :start 'waiting :final '(done)
               :steps (if (< n to)
                          `((next :from waiting
                                  :workflow ,(intern (format "n%d" (1+ n)))
                                  :to done))
                        '((go :from waiting :gate (:signal go) :to done))))))

(ert-deftest rat-kingdom-child-test-nesting-limit ()
  (rat-kingdom-steps-test-with-repo (space _path)
    (rat-kingdom-child-test--define-chain 0 5)
    ;; n1 nests four deep: allowed.
    (rat-kingdom-story-start space "demo" "Deep" nil "S-1" 'n1)
    (rat-kingdom-reaction-run space)
    (let ((deepest "S-1/next/next/next/next"))
      (should (eql (rat-kingdom-story-test--get space deepest :depth) 4))
      (should (equal (rat-kingdom-story-test--get space deepest :awaiting)
                     "gate"))
      (should (string-match-p
               "\n        - S-1/next/next/next/next \\[demo\\]"
               (rat-kingdom-child-test--king "status")))
      ;; The signal ends the deepest, and each parent in turn.
      (rat-kingdom-story-signal space deepest "go")
      (rat-kingdom-reaction-run space)
      (should-not (rat-kingdom-story-list space)))
    ;; n0 would nest five deep: its step fails to begin.
    (rat-kingdom-story-start space "demo" "Deeper" nil "S-2" 'n0)
    (rat-kingdom-reaction-run space)
    (should (equal (rat-kingdom-story-test--place space "S-2") "blocked"))
    (should (string-search "Step next could not be begun: a story would be \
nested 5 deep, and the limit is 4"
                           (rat-kingdom-story-test--get space "S-2" :reason)))
    (should-not (rat-kingdom-story-children space "S-2"))
    (should-not (rat-kingdom-reaction-failures space))))

(ert-deftest rat-kingdom-child-test-recursion ()
  (rat-kingdom-steps-test-with-repo (space _path)
    (rat-kingdom-workflow-define
     'ping
     :places '(waiting done blocked) :start 'waiting :final '(done)
     :steps '((call :from waiting :workflow pong :to done)))
    (rat-kingdom-workflow-define
     'pong
     :places '(waiting done blocked) :start 'waiting :final '(done)
     :steps '((call :from waiting :workflow ping :to done)))
    (rat-kingdom-workflow-define
     'selfish
     :places '(waiting done blocked) :start 'waiting :final '(done)
     :steps '((call :from waiting :workflow selfish :to done)))
    (rat-kingdom-workflow-define
     'lost
     :places '(waiting done blocked) :start 'waiting :final '(done)
     :steps '((call :from waiting :workflow nowhere :to done)))
    (dolist (case '(("S-1" ping "the workflow ping would contain itself")
                    ("S-2" pong "the workflow pong would contain itself")
                    ("S-3" selfish "the workflow selfish would contain itself")
                    ("S-4" lost "there is no workflow called nowhere")))
      (rat-kingdom-story-start space "demo" "Loop" nil (car case) (nth 1 case))
      (rat-kingdom-reaction-run space)
      (should (equal (rat-kingdom-story-test--place space (car case))
                     "blocked"))
      (should (string-search (concat "Step call could not be begun: "
                                     (nth 2 case))
                             (rat-kingdom-story-test--get space (car case)
                                                          :reason)))
      (should-not (rat-kingdom-story-children space (car case))))
    (should-not (rat-kingdom-reaction-failures space))))

;;;; Merging, epics and tasks

(ert-deftest rat-kingdom-child-test-child-that-merges ()
  (rat-kingdom-steps-test-with-repo (space path)
    (rat-kingdom-workflow-define
     'land
     :places '(checking integrating done blocked)
     :start 'checking :final '(done)
     :steps '((check :from checking :check t :pass integrating :fail blocked)
              (integrate :from integrating :merge t :to done
                         :stale checking)))
    (rat-kingdom-workflow-define
     'delegate
     :places '(ready landing waiting done blocked)
     :start 'ready :final '(done)
     :steps '((implement :from ready :spawn rat :to landing)
              (land :from landing :workflow land :to waiting :fail blocked)
              (wait :from waiting :gate (:signal go) :to done)))
    (rat-kingdom-story-start space "demo" "Add a file" nil "S-1" 'delegate)
    (rat-kingdom-reaction-run space)
    (rat-kingdom-story-test--work space "S-1" "feature.txt")
    (rat-kingdom-reaction-run space)
    (let ((worktree (rat-kingdom-story-test--get space "S-1" :worktree))
          (branch (rat-kingdom-story-test--get space "S-1" :branch)))
      (rat-kingdom-story-test--settle space "S-1/land")
      ;; The child moved the target, but left the shared worktree and
      ;; branch; the parent has :integrated.
      (should-not (rat-kingdom-story-get space "S-1/land"))
      (should (equal (rat-kingdom-story-test--git
                      path "show" "rk/integration:feature.txt")
                     "work"))
      (should (equal (rat-kingdom-story-test--get space "S-1" :awaiting)
                     "gate"))
      (should (equal (rat-kingdom-story-test--get space "S-1" :integrated)
                     (rat-kingdom-git-rev path "rk/integration")))
      (should (file-directory-p worktree))
      (should (rat-kingdom-git-ok-p path "rev-parse" "--verify" "--quiet"
                                    (concat "refs/heads/" branch)))
      ;; When the parent is done, they go, as after its own merge.
      (rat-kingdom-story-signal space "S-1" "go")
      (rat-kingdom-reaction-run space)
      (should-not (rat-kingdom-story-get space "S-1"))
      (should-not (file-exists-p worktree))
      (should-not (rat-kingdom-git-ok-p path "rev-parse" "--verify" "--quiet"
                                        (concat "refs/heads/" branch))))
    (should-not (rat-kingdom-reaction-failures space))))

(ert-deftest rat-kingdom-child-test-child-under-an-epic ()
  (rat-kingdom-task-test-with-tracker (space fake)
    (let ((rat-kingdom-workflow--table (copy-alist rat-kingdom-workflow--table))
          (rat-kingdom-story-event-functions
           (cons #'rat-kingdom-doc--story-event
                 rat-kingdom-story-event-functions)))
      (rat-kingdom-workflow-define
       'verify
       :places '(holding checking done blocked)
       :start 'holding :final '(done)
       :steps '((hold :from holding :gate (:signal go) :to checking)
                (check :from checking :check t :pass done :fail blocked)))
      (rat-kingdom-workflow-define
       'verified
       :places '(ready verifying integrating done blocked)
       :start 'ready :final '(done)
       :steps '((implement :from ready :spawn rat :to verifying)
                (verify :from verifying :workflow verify :to integrating
                        :fail ready)
                (integrate :from integrating :merge t :to done
                           :stale verifying)))
      (rat-kingdom-task-project space "demo")
      (rat-kingdom-story-start space "demo" "First" nil "S-1" 'verified "T-1"
                               nil "E-1")
      (rat-kingdom-reaction-run space)
      (let ((worktree (rat-kingdom-story-test--get space "S-1" :worktree)))
        (rat-kingdom-story-test--work space "S-1" "feature.txt")
        (rat-kingdom-reaction-run space)
        ;; The child has the parent's epic and task for configuration
        ;; only; the task and the epic are the parent's.
        (let ((child (plist-get (rat-kingdom-story-get space "S-1/verify")
                                :payload)))
          (should (equal (plist-get child :config-task) "T-1"))
          (should (equal (plist-get child :config-epic) "E-1"))
          (should-not (plist-get child :task))
          (should-not (plist-get child :epic)))
        (should (equal (mapcar (lambda (story) (plist-get story :identity))
                               (rat-kingdom-space-scan
                                space '(story :scope "demo" :task "T-1")))
                       '("S-1")))
        (should (equal (mapcar (lambda (story) (plist-get story :identity))
                               (rat-kingdom-epic--stories space "demo" "E-1"))
                       '("S-1")))
        (should (equal (rat-kingdom-story-config
                        space (rat-kingdom-story-get space "S-1/verify")
                        :workflow)
                       (rat-kingdom-story-config
                        space (rat-kingdom-story-get space "S-1") :workflow)))
        ;; Its end neither closes the task nor removes the worktree,
        ;; though its workflow merges nothing.
        (let* ((seen nil)
               (rat-kingdom-story-event-functions
                (append
                 rat-kingdom-story-event-functions
                 (list (lambda (_space event story)
                         (when (and (eq event 'done)
                                    (equal (plist-get story :identity)
                                           "S-1/verify"))
                           (setq seen
                                 (list (file-directory-p worktree)
                                       (rat-kingdom-story-complete-p
                                        space story)))))))))
          (rat-kingdom-story-signal space "S-1/verify" "go")
          (rat-kingdom-story-test--settle space "S-1/verify")
          (rat-kingdom-story-test--settle space "S-1")
          (should (equal seen '(t nil)))))
      (should-not (rat-kingdom-story-get space "S-1"))
      (rat-kingdom-task-test--drain fake 'close)
      (should (equal (cl-remove-if-not (lambda (call) (eq (car call) 'close))
                                       (rat-kingdom-task-test-fake-calls fake))
                     (list (list 'close "T-1"
                                 (format "Merged into rk/integration at %s"
                                         (substring (rat-kingdom-git-rev
                                                     (plist-get
                                                      (rat-kingdom-repo-get
                                                       space "demo")
                                                      :path)
                                                     "rk/integration")
                                                    0 7))))))
      (should-not (rat-kingdom-reaction-failures space)))))

;;;; Recovering

(ert-deftest rat-kingdom-child-test-parent-whose-child-is-gone ()
  (rat-kingdom-steps-test-with-repo (space _path)
    (rat-kingdom-child-test--define-waiting)
    (rat-kingdom-story-start space "demo" "Add a file" nil "S-1" 'holder)
    (rat-kingdom-reaction-run space)
    (rat-kingdom-story-test--work space "S-1" "feature.txt")
    (rat-kingdom-reaction-run space)
    ;; The child's token goes, as if lost.
    (should (rat-kingdom-space-in space '(story :identity "S-1/hold")))
    (rat-kingdom-story-watch space)
    (should (equal (plist-get (plist-get (rat-kingdom-space-rd
                                          space '(stuck :identity "S-1"))
                                         :payload)
                              :reason)
                   "Its child S-1/hold is gone."))
    (rat-kingdom-story-reconcile space)
    (rat-kingdom-reaction-run space)
    (should (equal (rat-kingdom-story-test--place space "S-1") "blocked"))
    (should (string-search "The child S-1/hold is gone"
                           (rat-kingdom-story-test--get space "S-1" :reason)))
    (should-not (rat-kingdom-reaction-failures space))))

(provide 'rat-kingdom-child-test)
;;; rat-kingdom-child-test.el ends here
