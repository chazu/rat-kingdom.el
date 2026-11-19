;;; rat-kingdom-steps-test.el --- The engine's :run and :gate steps, :check names and :brief -*- lexical-binding: t; -*-

;;; Commentary:

;; Batch tests of the step kinds of DESIGN.md section 7.1 that the
;; engine runs beyond spawning, checking, reviewing and merging: a
;; `:run' step that runs named commands in the story's worktree and
;; commits what they change, `:check' with command names, `:gate' by
;; time and by signal, and a spawn step's `:brief'.  They use disposable
;; repositories and the fake agents of rat-kingdom-story-test.el, and
;; name commands in the repository's .rk/config.eld.

;;; Code:

(require 'ert)
(require 'rat-kingdom-test-helper)
(require 'rat-kingdom-story-test)
(require 'rat-kingdom-config-engine-test)

(defmacro rat-kingdom-steps-test-with-repo (vars &rest body)
  "Run BODY as `rat-kingdom-config-engine-test-with-repo' does, with VARS.
Workflows defined in BODY are forgotten afterwards."
  (declare (indent 1) (debug t))
  `(let ((rat-kingdom-workflow--table (copy-alist rat-kingdom-workflow--table))
         (rat-kingdom-story--gate-timers (make-hash-table :test #'equal)))
     (unwind-protect
         (rat-kingdom-config-engine-test-with-repo ,vars ,@body)
       (maphash (lambda (_id timer) (cancel-timer timer))
                rat-kingdom-story--gate-timers))))

(defun rat-kingdom-steps-test--commands (path commands &rest more)
  "Make COMMANDS the :commands of the repository at PATH, with MORE keys."
  (rat-kingdom-config-engine-test--repo
   path (append (list :commands commands) more)))

(defun rat-kingdom-steps-test--king (tool &rest arguments)
  "Call the king's TOOL with ARGUMENTS, an alist.  Return (TEXT . FAILED)."
  (rat-kingdom-mcp-call '(:run "king" :role king) tool arguments))

(defun rat-kingdom-steps-test--settle-run (space id &optional stay)
  "Run reactions in SPACE until the `:run' of the story ID has come out.
With STAY, stop when it has, before the story moves on."
  (rat-kingdom-reaction-run space)
  (let ((tries 0))
    (while (and (rat-kingdom-space-rd space (list 'story :identity id
                                                  :awaiting "run"))
                (not (rat-kingdom-space-rd space (list 'ran :identity id)))
                (< (cl-incf tries) 200))
      (accept-process-output nil 0.05)))
  (unless stay
    (rat-kingdom-reaction-run space)))

(defun rat-kingdom-steps-test--ran (space id)
  "Return the payload of the `ran' tuple of the story ID in SPACE.
It is looked for in the archive too, once the story is over."
  (plist-get (or (rat-kingdom-space-rd space (list 'ran :identity id))
                 (cl-find 'ran (reverse (rat-kingdom-space-archived space id))
                          :key (lambda (tuple) (plist-get tuple :category))))
             :payload))

(defun rat-kingdom-steps-test--set-up (space id)
  "Run reactions in SPACE until the setup of the story ID is over."
  (rat-kingdom-reaction-run space)
  (let ((tries 0))
    (while (and (rat-kingdom-space-rd space (list 'story :identity id
                                                  :awaiting "setup"))
                (< (cl-incf tries) 200))
      (accept-process-output nil 0.05)
      (rat-kingdom-reaction-run space))))

;;;; :run

(ert-deftest rat-kingdom-steps-test-run-formats-and-commits ()
  (rat-kingdom-steps-test-with-repo (space path)
    (rat-kingdom-workflow-define
     'formatted
     :places '(ready formatting checking integrating done blocked)
     :start 'ready :final '(done)
     :steps '((implement :from ready :spawn rat :to formatting
                         :brief "Write the file in lower case.")
              (format :from formatting :run (fmt) :pass checking :fail ready)
              (check :from checking :check t :pass integrating :fail ready)
              (integrate :from integrating :merge t :to done :stale checking)))
    (rat-kingdom-steps-test--commands
     path '(:fmt ("sh" "-c" "for f in *.txt; do tr a-z A-Z < $f > $f.new \
&& mv $f.new $f; done")))
    (rat-kingdom-story-start space "demo" "Add a file" "Add feature.txt."
                             "S-1" 'formatted)
    (rat-kingdom-reaction-run space)
    ;; The step's brief is its own section of the worker's prompt.
    (let ((prompt (rat-kingdom-story-test--prompt "S-1.1")))
      (should (string-search
               "Add feature.txt.\n\nFor this step (implement):\nWrite the file \
in lower case.\n"
               prompt)))
    (rat-kingdom-story-test--work space "S-1" "feature.txt")
    (rat-kingdom-reaction-run space)
    (let ((commit (rat-kingdom-story-test--get space "S-1" :commit))
          (worktree (rat-kingdom-story-test--get space "S-1" :worktree)))
      (rat-kingdom-steps-test--settle-run space "S-1" t)
      ;; The run's change was committed on the story's branch.
      (let ((ran (rat-kingdom-steps-test--ran space "S-1"))
            (head (rat-kingdom-git-rev worktree "HEAD")))
        (should (equal (plist-get ran :value) "pass"))
        (should (equal (plist-get ran :names) '("fmt")))
        (should (equal (plist-get ran :command) "fmt"))
        (should (eql (plist-get ran :exit) 0))
        (should (equal (plist-get ran :commit) head))
        (should-not (equal head commit))
        (should (equal (rat-kingdom-git-rev worktree "HEAD~1") commit))
        (should (equal (rat-kingdom-story-test--git worktree "log" "-1"
                                                    "--format=%s")
                       "rat-kingdom: run fmt"))
        (should (equal (rat-kingdom-story-test--git worktree "rev-parse"
                                                    "--abbrev-ref" "HEAD")
                       "rats/S-1"))
        (should (string-empty-p (rat-kingdom-story-test--git
                                 worktree "status" "--porcelain")))))
    (rat-kingdom-story-test--settle space "S-1")
    ;; The check took the new commit, and it was merged.
    (should-not (rat-kingdom-story-get space "S-1"))
    (should (equal (rat-kingdom-story-test--git
                    path "show" "rk/integration:feature.txt")
                   "WORK"))
    (should-not (rat-kingdom-reaction-failures space))))

(ert-deftest rat-kingdom-steps-test-run-that-changes-nothing-keeps-the-commit ()
  (rat-kingdom-steps-test-with-repo (space path)
    (rat-kingdom-workflow-define
     'formatted
     :places '(ready formatting checking integrating done blocked)
     :start 'ready :final '(done)
     :steps '((implement :from ready :spawn rat :to formatting)
              (format :from formatting :run (fmt) :pass checking :fail ready)
              (check :from checking :check t :pass integrating :fail ready)
              (integrate :from integrating :merge t :to done :stale checking)))
    (rat-kingdom-steps-test--commands path '(:fmt ("true")))
    (rat-kingdom-story-start space "demo" "Add a file" nil "S-1" 'formatted)
    (rat-kingdom-reaction-run space)
    (rat-kingdom-story-test--work space "S-1" "feature.txt")
    (rat-kingdom-reaction-run space)
    (let ((commit (rat-kingdom-story-test--get space "S-1" :commit)))
      ;; No brief, no section.
      (should-not (string-search "For this step"
                                 (rat-kingdom-story-test--prompt "S-1.1")))
      (rat-kingdom-steps-test--settle-run space "S-1")
      (should-not (rat-kingdom-story-get space "S-1"))
      (should (equal (plist-get (rat-kingdom-steps-test--ran space "S-1")
                                :commit)
                     commit))
      (should (string-search
               commit
               (rat-kingdom-story-test--git path "log" "--format=%H"
                                            "rk/integration"))))))

(ert-deftest rat-kingdom-steps-test-run-that-fails ()
  (rat-kingdom-steps-test-with-repo (space path)
    (rat-kingdom-workflow-define
     'formatted
     :places '(ready formatting checking integrating done blocked)
     :start 'ready :final '(done)
     :steps '((implement :from ready :spawn rat :to formatting)
              (format :from formatting :run (fmt lint) :pass checking
                      :fail ready)
              (check :from checking :check t :pass integrating :fail ready)
              (integrate :from integrating :merge t :to done :stale checking)))
    (rat-kingdom-steps-test--commands
     path '(:fmt ("sh" "-c" "echo formatted > fmt-stamp")
            :lint ("sh" "-c" "echo too many words; exit 3")))
    (rat-kingdom-story-start space "demo" "Add a file" nil "S-1" 'formatted)
    (rat-kingdom-reaction-run space)
    (rat-kingdom-story-test--work space "S-1" "feature.txt")
    (rat-kingdom-reaction-run space)
    (let ((commit (rat-kingdom-story-test--get space "S-1" :commit))
          (worktree (rat-kingdom-story-test--get space "S-1" :worktree)))
      (rat-kingdom-steps-test--settle-run space "S-1")
      (let ((ran (rat-kingdom-steps-test--ran space "S-1")))
        (should (equal (plist-get ran :value) "fail"))
        (should (equal (plist-get ran :names) '("fmt" "lint")))
        (should (equal (plist-get ran :command) "lint"))
        (should (eql (plist-get ran :exit) 3)))
      ;; Nothing was committed, and a new worker is told why.
      (should (equal (rat-kingdom-git-rev worktree "HEAD") commit))
      (should (equal (rat-kingdom-story-test--get space "S-1" :commit) commit))
      (should (equal (rat-kingdom-story-test--get space "S-1" :run) "S-1.2"))
      (let ((prompt (rat-kingdom-story-test--prompt "S-1.2")))
        (should (string-search "run failed: the command lint (sh -c" prompt))
        (should (string-search "exited with 3" prompt))
        (should (string-search "too many words" prompt)))
      (should (string-search "Last run: fail (lint (sh -c"
                             (rat-kingdom-king--show space "S-1")))
      ;; A run does not begin in a worktree with changes.
      (should (file-exists-p (expand-file-name "fmt-stamp" worktree)))
      (rat-kingdom-story-move space "S-1" "formatting")
      (rat-kingdom-reaction-run space)
      (should (equal (rat-kingdom-story-test--place space "S-1") "blocked"))
      (let ((reason (rat-kingdom-story-test--get space "S-1" :reason)))
        (should (string-search "Step format could not be begun" reason))
        (should (string-search "fmt-stamp" reason)))
      ;; Nor in one that is not at the story's commit.
      (delete-file (expand-file-name "fmt-stamp" worktree))
      (rat-kingdom-story-test--commit worktree "more.txt" "more\n" "More")
      (rat-kingdom-story-move space "S-1" "formatting")
      (rat-kingdom-reaction-run space)
      (should (string-search "the commit of the story"
                             (rat-kingdom-story-test--get space "S-1" :reason)))
      (should-not (rat-kingdom-reaction-failures space)))))

(ert-deftest rat-kingdom-steps-test-moving-kills-a-run ()
  (rat-kingdom-steps-test-with-repo (space path)
    (rat-kingdom-workflow-define
     'slow
     :places '(ready running checking integrating done blocked)
     :start 'ready :final '(done)
     :steps '((implement :from ready :spawn rat :to running)
              (slowly :from running :run (slow) :pass checking :fail ready)
              (check :from checking :check t :pass integrating :fail ready)
              (integrate :from integrating :merge t :to done :stale checking)))
    (rat-kingdom-steps-test--commands path '(:slow ("sleep" "30")))
    (rat-kingdom-story-start space "demo" "Add a file" nil "S-1" 'slow)
    (rat-kingdom-story-start space "demo" "Add another" nil "S-2" 'slow)
    (rat-kingdom-reaction-run space)
    (rat-kingdom-story-test--work space "S-1" "one.txt")
    (rat-kingdom-story-test--work space "S-2" "two.txt")
    (rat-kingdom-reaction-run space)
    (should (equal (rat-kingdom-story-test--get space "S-1" :awaiting) "run"))
    (let ((process (gethash "S-1" rat-kingdom-story--checks)))
      (should (process-live-p process))
      ;; status and story_show say what it runs.
      (should (string-search "S-1 [demo] running (waiting for run: slow; \
running slow (sleep 30))"
                             (rat-kingdom-king-status space)))
      (should (string-search "Run: slow; running slow (sleep 30)"
                             (rat-kingdom-king--show space "S-1")))
      ;; Moving the story kills it, and nothing is recorded.
      (rat-kingdom-story-move space "S-1" "ready")
      (should-not (process-live-p process))
      (should-not (gethash "S-1" rat-kingdom-story--checks))
      (rat-kingdom-reaction-run space)
      (accept-process-output nil 0.1)
      (should-not (rat-kingdom-steps-test--ran space "S-1"))
      (should (equal (rat-kingdom-story-test--get space "S-1" :run) "S-1.2")))
    ;; Cancelling does too.
    (let ((process (gethash "S-2" rat-kingdom-story--checks)))
      (should (process-live-p process))
      (rat-kingdom-story-cancel space "S-2")
      (should-not (process-live-p process))
      (should-not (gethash "S-2" rat-kingdom-story--checks)))
    (should-not (rat-kingdom-reaction-failures space))))

(ert-deftest rat-kingdom-steps-test-interrupted-run-is-run-again ()
  (rat-kingdom-steps-test-with-repo (space path)
    (setq rat-kingdom-story-test--now 1000.0)
    (rat-kingdom-workflow-define
     'slow
     :places '(ready running checking integrating done blocked)
     :start 'ready :final '(done)
     :steps '((implement :from ready :spawn rat :to running)
              (slowly :from running :run (slow) :pass checking :fail ready)
              (check :from checking :check t :pass integrating :fail ready)
              (integrate :from integrating :merge t :to done :stale checking)))
    (rat-kingdom-steps-test--commands path '(:slow ("sleep" "30")))
    (rat-kingdom-story-start space "demo" "Add a file" nil "S-1" 'slow)
    (rat-kingdom-reaction-run space)
    (rat-kingdom-story-test--work space "S-1" "one.txt")
    (rat-kingdom-reaction-run space)
    (should (equal (rat-kingdom-story-test--get space "S-1" :awaiting) "run"))
    ;; A running run is not disturbed.
    (should (equal (rat-kingdom-story-reconcile space)
                   '(:runs nil :checks nil :setups nil)))
    ;; Emacs stops, taking the run with it, and leaving a half-made file.
    (rat-kingdom-story--abandon-check "S-1")
    (with-temp-file (expand-file-name
                     "half" (rat-kingdom-story-test--get space "S-1" :worktree))
      (insert "half\n"))
    (setq rat-kingdom-story-test--now 1010.0)
    (should (eql (rat-kingdom-story-watch space) 1))
    (should (string-search "Its run is not running"
                           (plist-get (plist-get (rat-kingdom-space-rd
                                                  space '(stuck :identity "S-1"))
                                                 :payload)
                                      :reason)))
    ;; Reconciling runs it again, in the worktree as it is.
    (rat-kingdom-steps-test--commands
     path '(:slow ("sh" "-c" "echo done >> half")))
    (should (equal (rat-kingdom-story-reconcile space)
                   '(:runs nil :checks ("S-1") :setups nil)))
    (rat-kingdom-steps-test--settle-run space "S-1")
    (should-not (rat-kingdom-story-get space "S-1"))
    (should (equal (rat-kingdom-story-test--git path "show"
                                                "rk/integration:half")
                   "half\ndone"))))

;;;; :check with names

(ert-deftest rat-kingdom-steps-test-check-with-names ()
  (rat-kingdom-steps-test-with-repo (space path)
    (rat-kingdom-workflow-define
     'named
     :places '(ready checking integrating done blocked)
     :start 'ready :final '(done)
     :steps '((implement :from ready :spawn rat :to checking)
              (check :from checking :check (lint test) :pass integrating
                     :fail ready)
              (integrate :from integrating :merge t :to done :stale checking)))
    ;; The configured check would always fail; the names replace it, and
    ;; the setup still runs first.
    (let ((log (expand-file-name "setup.log" rat-kingdom-story-test--br)))
      (rat-kingdom-steps-test--commands
       path `(:lint ("sh" "-c" ,(format "test -s %s && echo linting" log))
              :test ("sh" "-c" "test -f wanted.txt")
              :prepare ("sh" "-c" ,(format "pwd >> %s" log))
              :never ("false"))
       :check '(never) :setup '(prepare)))
    (rat-kingdom-story-start space "demo" "Add the wanted file" nil "S-1"
                             'named)
    (rat-kingdom-steps-test--set-up space "S-1")
    (rat-kingdom-story-test--work space "S-1" "other.txt")
    (rat-kingdom-story-test--settle space "S-1")
    (let ((checked (rat-kingdom-config-engine-test--checked space "S-1")))
      (should (equal (plist-get checked :value) "fail"))
      (should (equal (plist-get checked :names) '("lint" "test")))
      (should (equal (plist-get checked :command) "test")))
    (should (string-search "candidates/demo/S-1"
                           (with-temp-buffer
                             (insert-file-contents
                              (expand-file-name "setup.log"
                                                rat-kingdom-story-test--br))
                             (buffer-string))))
    (should (string-search "check failed: after your branch was merged, the \
command test (sh -c"
                           (rat-kingdom-story-test--prompt "S-1.2")))
    (rat-kingdom-story-test--work space "S-1" "wanted.txt")
    (rat-kingdom-story-test--settle space "S-1")
    (should-not (rat-kingdom-story-get space "S-1"))
    (should (equal (rat-kingdom-story-test--git
                    path "show" "rk/integration:wanted.txt")
                   "work"))))

(ert-deftest rat-kingdom-steps-test-unknown-name ()
  (rat-kingdom-steps-test-with-repo (space path)
    (rat-kingdom-workflow-define
     'bad-check
     :places '(ready checking done blocked)
     :start 'ready :final '(done)
     :steps '((implement :from ready :spawn rat :to checking)
              (check :from checking :check (lint nope) :pass done :fail ready)))
    (rat-kingdom-workflow-define
     'bad-run
     :places '(ready running done blocked)
     :start 'ready :final '(done)
     :steps '((implement :from ready :spawn rat :to running)
              (tidy :from running :run (nope) :pass done :fail ready)))
    (rat-kingdom-steps-test--commands path '(:lint ("true") :test ("true")))
    (rat-kingdom-story-start space "demo" "One" nil "S-1" 'bad-check)
    (rat-kingdom-story-start space "demo" "Two" nil "S-2" 'bad-run)
    (rat-kingdom-reaction-run space)
    (rat-kingdom-story-test--work space "S-1" "one.txt")
    (rat-kingdom-story-test--work space "S-2" "two.txt")
    (rat-kingdom-reaction-run space)
    (should (equal (rat-kingdom-story-test--place space "S-1") "blocked"))
    (should (equal (rat-kingdom-story-test--get space "S-1" :reason)
                   "Step check could not be begun: nope is not a command; \
the commands are lint, test"))
    (should (equal (rat-kingdom-story-test--place space "S-2") "blocked"))
    (should (equal (rat-kingdom-story-test--get space "S-2" :reason)
                   "Step tidy could not be begun: nope is not a command; \
the commands are lint, test"))
    (should-not (gethash "S-1" rat-kingdom-story--checks))
    (should-not (gethash "S-2" rat-kingdom-story--checks))
    (should-not (rat-kingdom-reaction-failures space))))

;;;; :gate

(ert-deftest rat-kingdom-steps-test-timed-gate ()
  (rat-kingdom-steps-test-with-repo (space _path)
    (setq rat-kingdom-story-test--now 1000.0)
    (rat-kingdom-workflow-define
     'later
     :places '(waiting ready checking integrating done blocked)
     :start 'waiting :final '(done)
     :steps '((pause :from waiting :gate (:after 600) :to ready)
              (implement :from ready :spawn rat :to checking)
              (check :from checking :check t :pass integrating :fail ready)
              (integrate :from integrating :merge t :to done :stale checking)))
    (rat-kingdom-story-start space "demo" "Add a file" nil "S-1" 'later)
    (rat-kingdom-reaction-run space)
    (should (equal (rat-kingdom-story-test--get space "S-1" :awaiting) "gate"))
    (should (= (rat-kingdom-story-test--get space "S-1" :until) 1600))
    (should (gethash "S-1" rat-kingdom-story--gate-timers))
    (should-not rat-kingdom-story-test--started)
    (should (string-search "(waiting for gate: until "
                           (rat-kingdom-king-status space)))
    (should (string-search "in 10m" (rat-kingdom-king-status space)))
    (should (string-search "Gate: until "
                           (rat-kingdom-king--show space "S-1")))
    ;; A gate with no process is not stuck, however long it waits.
    (setq rat-kingdom-story-test--now 1599.0)
    (should (zerop (rat-kingdom-story-watch space)))
    (should (equal (rat-kingdom-story-test--get space "S-1" :awaiting) "gate"))
    (should-not (rat-kingdom-story-open-gates space))
    ;; Once its time has passed the watchdog opens it.
    (setq rat-kingdom-story-test--now 1601.0)
    (should (zerop (rat-kingdom-story-watch space)))
    (should-not (gethash "S-1" rat-kingdom-story--gate-timers))
    (should (equal (rat-kingdom-story-test--get space "S-1" :at) "ready"))
    (should-not (rat-kingdom-story-test--get space "S-1" :until))
    (rat-kingdom-reaction-run space)
    (should (equal (rat-kingdom-story-test--get space "S-1" :awaiting) "worker"))
    (should-not (rat-kingdom-reaction-failures space))))

(ert-deftest rat-kingdom-steps-test-timed-gate-opens-by-its-timer ()
  (rat-kingdom-steps-test-with-repo (space _path)
    (rat-kingdom-workflow-define
     'soon
     :places '(waiting ready checking integrating done blocked)
     :start 'waiting :final '(done)
     :steps '((pause :from waiting :gate (:after 0.2) :to ready)
              (implement :from ready :spawn rat :to checking)
              (check :from checking :check t :pass integrating :fail ready)
              (integrate :from integrating :merge t :to done :stale checking)))
    (rat-kingdom-story-start space "demo" "Add a file" nil "S-1" 'soon)
    (rat-kingdom-reaction-run space)
    (should (equal (rat-kingdom-story-test--get space "S-1" :awaiting) "gate"))
    (let ((tries 0))
      (while (and (rat-kingdom-space-rd space '(story :identity "S-1"
                                                      :awaiting "gate"))
                  (< (cl-incf tries) 100))
        (accept-process-output nil 0.05)))
    (rat-kingdom-reaction-run space)
    (should (equal (rat-kingdom-story-test--get space "S-1" :awaiting) "worker"))))

(ert-deftest rat-kingdom-steps-test-timed-gate-after-a-restart ()
  (rat-kingdom-steps-test-with-repo (space _path)
    (setq rat-kingdom-story-test--now 1000.0)
    (rat-kingdom-workflow-define
     'later
     :places '(waiting ready checking integrating done blocked)
     :start 'waiting :final '(done)
     :steps '((pause :from waiting :gate (:after 600) :to ready)
              (implement :from ready :spawn rat :to checking)
              (check :from checking :check t :pass integrating :fail ready)
              (integrate :from integrating :merge t :to done :stale checking)))
    (rat-kingdom-story-start space "demo" "One" nil "S-1" 'later)
    (rat-kingdom-story-start space "demo" "Two" nil "S-2" 'later)
    (rat-kingdom-reaction-run space)
    (setq rat-kingdom-story-test--now 1100.0)
    (rat-kingdom-story-start space "demo" "Three" nil "S-3" 'later)
    (rat-kingdom-reaction-run space)
    ;; Emacs stops: the timers go.
    (maphash (lambda (_id timer) (cancel-timer timer))
             rat-kingdom-story--gate-timers)
    (clrhash rat-kingdom-story--gate-timers)
    ;; Reconciling opens the overdue gates and times the rest again.
    (setq rat-kingdom-story-test--now 1650.0)
    (rat-kingdom-story-reconcile space)
    (should (equal (rat-kingdom-story-test--get space "S-1" :at) "ready"))
    (should (equal (rat-kingdom-story-test--get space "S-2" :at) "ready"))
    (should (equal (rat-kingdom-story-test--get space "S-3" :awaiting) "gate"))
    (should (gethash "S-3" rat-kingdom-story--gate-timers))
    ;; Moving a story out of its gate stops its timer.
    (rat-kingdom-story-move space "S-3" "ready")
    (should-not (gethash "S-3" rat-kingdom-story--gate-timers))
    (should-not (rat-kingdom-story-test--get space "S-3" :until))
    (rat-kingdom-reaction-run space)
    (should (equal (rat-kingdom-story-test--get space "S-3" :awaiting)
                   "worker"))))

(ert-deftest rat-kingdom-steps-test-signal-gate ()
  (rat-kingdom-steps-test-with-repo (space _path)
    (setq rat-kingdom-story-test--now 1000.0)
    (rat-kingdom-workflow-define
     'approved
     :places '(waiting ready checking integrating done blocked)
     :start 'waiting :final '(done)
     :steps '((approval :from waiting :gate (:signal go-ahead) :to ready)
              (implement :from ready :spawn rat :to checking)
              (check :from checking :check t :pass integrating :fail ready)
              (integrate :from integrating :merge t :to done :stale checking)))
    (rat-kingdom-story-start space "demo" "Add a file" nil "S-1" 'approved)
    (rat-kingdom-reaction-run space)
    (should (equal (rat-kingdom-story-test--get space "S-1" :awaiting) "gate"))
    (should (equal (rat-kingdom-story-test--get space "S-1" :signal) "go-ahead"))
    (should (string-search "(waiting for gate: the signal go-ahead"
                           (rat-kingdom-king-status space)))
    (should (string-search "Gate: the signal go-ahead"
                           (rat-kingdom-king--show space "S-1")))
    ;; Not stuck, however long it waits.
    (setq rat-kingdom-story-test--now 100000.0)
    (should (zerop (rat-kingdom-story-watch space)))
    ;; Refused: an unknown story and a blank name.
    (should (cdr (rat-kingdom-steps-test--king
                  "story_signal" '(story . "S-9") '(name . "go-ahead"))))
    (should (cdr (rat-kingdom-steps-test--king
                  "story_signal" '(story . "S-1") '(name . " "))))
    ;; Another name is kept, but opens nothing.
    (let ((answer (rat-kingdom-steps-test--king
                   "story_signal" '(story . "S-1") '(name . "other"))))
      (should-not (cdr answer))
      (should (string-search "not waiting at a gate for other" (car answer))))
    (rat-kingdom-reaction-run space)
    (should (equal (rat-kingdom-story-test--get space "S-1" :awaiting) "gate"))
    ;; The right one opens it, and is taken.
    (let ((answer (rat-kingdom-steps-test--king
                   "story_signal" '(story . "S-1") '(name . "go-ahead"))))
      (should-not (cdr answer))
      (should (string-search "so the gate opens" (car answer))))
    (rat-kingdom-reaction-run space)
    (should (equal (rat-kingdom-story-test--get space "S-1" :awaiting) "worker"))
    (should-not (rat-kingdom-story-test--get space "S-1" :signal))
    (should-not (rat-kingdom-space-rd space '(signal :identity "S-1"
                                                     :name "go-ahead")))
    (should (rat-kingdom-space-rd space '(signal :identity "S-1" :name "other")))
    ;; What is left is swept with the story.
    (rat-kingdom-story-cancel space "S-1")
    (should-not (rat-kingdom-space-rd space '(signal :identity "S-1")))
    (should-not (rat-kingdom-reaction-failures space))))

(ert-deftest rat-kingdom-steps-test-signal-sent-early ()
  (rat-kingdom-steps-test-with-repo (space path)
    (rat-kingdom-workflow-define
     'approved
     :places '(ready approving checking integrating done blocked)
     :start 'ready :final '(done)
     :steps '((implement :from ready :spawn rat :to approving)
              (approval :from approving :gate (:signal "go-ahead") :to checking)
              (check :from checking :check t :pass integrating :fail ready)
              (integrate :from integrating :merge t :to done :stale checking)))
    (rat-kingdom-story-start space "demo" "Add a file" nil "S-1" 'approved)
    (rat-kingdom-reaction-run space)
    ;; Sent while the worker works: kept.
    (let ((answer (rat-kingdom-steps-test--king
                   "story_signal" '(story . "S-1") '(name . "go-ahead"))))
      (should-not (cdr answer))
      (should (string-search "not waiting at a gate for go-ahead" (car answer)))
      (should (string-search "kept" (car answer))))
    ;; When it reaches the gate, the gate opens at once.
    (rat-kingdom-story-test--work space "S-1" "feature.txt")
    (rat-kingdom-story-test--settle space "S-1")
    (should-not (rat-kingdom-story-get space "S-1"))
    (should (equal (rat-kingdom-story-test--git
                    path "show" "rk/integration:feature.txt")
                   "work"))
    (should-not (rat-kingdom-reaction-failures space))))

(provide 'rat-kingdom-steps-test)
;;; rat-kingdom-steps-test.el ends here
