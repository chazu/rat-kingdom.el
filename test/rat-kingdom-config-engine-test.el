;;; rat-kingdom-config-engine-test.el --- The engine reads its settings through configuration -*- lexical-binding: t; -*-

;;; Commentary:

;; Batch tests that the engine looks its settings up with
;; `rat-kingdom-config-get' (DESIGN.md, section 7.3): a repository's
;; .rk/config.eld, in a disposable repository, changes the workflow,
;; target, check and setup (by command names), agents, timeouts and
;; attempts a story gets; the global file sets the worker limit; an
;; epic's policy overrides the repository; and the king's status shows
;; configuration that is ignored.  With no configuration files the
;; engine behaves as before, which the rest of the suite shows.

;;; Code:

(require 'ert)
(require 'rat-kingdom)
(require 'rat-kingdom-config)
(require 'rat-kingdom-story-test)
(require 'rat-kingdom-king-test)
(require 'rat-kingdom-foreman-test)

(defmacro rat-kingdom-config-engine-test-with-repo (vars &rest body)
  "Run BODY as `rat-kingdom-story-test-with-repo' does, with VARS.
Configuration read and errors recorded are forgotten before and after."
  (declare (indent 1) (debug t))
  `(let ((rat-kingdom-config--files (make-hash-table :test #'equal))
         (rat-kingdom-config--errors (make-hash-table :test #'equal)))
     (rat-kingdom-story-test-with-repo ,vars ,@body)))

(defun rat-kingdom-config-engine-test--write (file config)
  "Write CONFIG to FILE, as text if it is a string, else printed."
  (make-directory (file-name-directory file) t)
  (with-temp-file file
    (if (stringp config)
        (insert config)
      (let ((print-length nil) (print-level nil))
        (prin1 config (current-buffer)))))
  ;; A file rewritten within the same tick and size would look unchanged.
  (clrhash rat-kingdom-config--files))

(defun rat-kingdom-config-engine-test--repo (path config)
  "Make CONFIG the .rk/config.eld of the repository at PATH."
  (rat-kingdom-config-engine-test--write
   (expand-file-name ".rk/config.eld" path) config))

(defun rat-kingdom-config-engine-test--checked (space id)
  "Return the payload of the outcome of the last check of the story ID in SPACE."
  (plist-get (rat-kingdom-space-rd space (list 'checked :identity id))
             :payload))

;;;; Workflow and target

(ert-deftest rat-kingdom-config-engine-test-workflow ()
  (rat-kingdom-config-engine-test-with-repo (space path)
    ;; No configuration: the default, story-lite in these tests.
    (rat-kingdom-story-start space "demo" "One" nil "S-1")
    (should (equal (rat-kingdom-story-test--get space "S-1" :workflow)
                   "story-lite"))
    ;; The repository's file names another.
    (rat-kingdom-config-engine-test--repo path '(:workflow story))
    (rat-kingdom-story-start space "demo" "Two" nil "S-2")
    (should (equal (rat-kingdom-story-test--get space "S-2" :workflow)
                   "story"))
    ;; The file is more specific than the registration.
    (rat-kingdom-repo-add space path :workflow 'story-lite)
    (rat-kingdom-story-start space "demo" "Three" nil "S-3")
    (should (equal (rat-kingdom-story-test--get space "S-3" :workflow)
                   "story"))
    ;; A workflow named when starting still wins.
    (rat-kingdom-story-start space "demo" "Four" nil "S-4" 'story-lite)
    (should (equal (rat-kingdom-story-test--get space "S-4" :workflow)
                   "story-lite"))
    (should (string-search "; workflow story\n"
                           (concat (rat-kingdom-king-status space) "\n")))))

(ert-deftest rat-kingdom-config-engine-test-target ()
  (rat-kingdom-config-engine-test-with-repo (space path)
    (rat-kingdom-story-test--git path "branch" "elsewhere")
    (should (equal (rat-kingdom-story-target space '(:scope "demo"))
                   "rk/integration"))
    (rat-kingdom-config-engine-test--repo path '(:target "elsewhere"))
    (should (equal (rat-kingdom-story-target space '(:scope "demo"))
                   "elsewhere"))
    ;; A story's own target still wins.
    (should (equal (rat-kingdom-story-target
                    space '(:scope "demo" :payload (:target "rk/integration")))
                   "rk/integration"))
    ;; A story is cut from and merged into the configured target.
    (rat-kingdom-story-test--commit path "base" "x\n" "On main")
    (rat-kingdom-story-test--git path "branch" "-f" "elsewhere" "main")
    (rat-kingdom-story-start space "demo" "Add a file" nil "S-1")
    (rat-kingdom-reaction-run space)
    (should (string-search "cut from elsewhere"
                           (rat-kingdom-story-test--prompt "S-1.1")))
    (rat-kingdom-story-test--work space "S-1" "feature.txt")
    (rat-kingdom-story-test--settle space "S-1")
    (should-not (rat-kingdom-story-get space "S-1"))
    (should (equal (rat-kingdom-story-test--git
                    path "show" "elsewhere:feature.txt")
                   "work"))
    (should (string-search "target elsewhere" (rat-kingdom-king-status space)))))

;;;; Check and setup

(ert-deftest rat-kingdom-config-engine-test-check-by-command-names ()
  (rat-kingdom-config-engine-test-with-repo (space path)
    (let* ((log (expand-file-name "../commands.log" path))
           (append-to (lambda (word)
                        (format "echo %s >> %s" word
                                (shell-quote-argument log)))))
      (rat-kingdom-config-engine-test--repo
       path `(:commands (:lint ("sh" "-c" ,(funcall append-to "lint"))
                        :test ("sh" "-c" ,(concat (funcall append-to "test")
                                                  "; echo testing; \
test -f wanted.txt")))
              :check (lint test)))
      (rat-kingdom-story-start space "demo" "Add the wanted file" nil "S-1")
      (rat-kingdom-reaction-run space)
      ;; Both run, in order; the second fails, and is named.
      (rat-kingdom-story-test--work space "S-1" "other.txt")
      (rat-kingdom-story-test--settle space "S-1")
      (should (equal (rat-kingdom-story-test--lines log) '("lint" "test")))
      (let ((checked (rat-kingdom-config-engine-test--checked space "S-1"))
            (prompt (rat-kingdom-story-test--prompt "S-1.2")))
        (should (equal (plist-get checked :value) "fail"))
        (should (equal (plist-get checked :command) "test"))
        (should (equal (plist-get checked :names) '("lint" "test")))
        (should (string-search "check failed" prompt))
        (should (string-search "the command test (sh -c" prompt))
        (should (string-search "exited with 1" prompt))
        (should (string-search "testing" prompt)))
      ;; The first that fails ends the check: the rest do not run.
      (rat-kingdom-config-engine-test--repo
       path `(:commands (:lint ("sh" "-c" ,(concat (funcall append-to "lint")
                                                  "; echo lint broke; exit 4"))
                        :test ("sh" "-c" ,(funcall append-to "test")))
              :check (lint test)))
      (rat-kingdom-story-test--work space "S-1" "wanted.txt")
      (rat-kingdom-story-test--settle space "S-1")
      (should (equal (rat-kingdom-story-test--lines log)
                     '("lint" "test" "lint")))
      (let ((prompt (rat-kingdom-story-test--prompt "S-1.3")))
        (should (string-search "the command lint (sh -c" prompt))
        (should (string-search "exited with 4" prompt))
        (should (string-search "lint broke" prompt)))
      ;; All pass, and the story is merged.
      (rat-kingdom-config-engine-test--repo
       path `(:commands (:lint ("sh" "-c" ,(funcall append-to "lint"))
                        :test ("sh" "-c" ,(funcall append-to "test")))
              :check (lint test)))
      (rat-kingdom-story-test--work space "S-1" "more.txt")
      (rat-kingdom-story-test--settle space "S-1")
      (should-not (rat-kingdom-story-get space "S-1"))
      (should (equal (rat-kingdom-story-test--lines log)
                     '("lint" "test" "lint" "lint" "test")))
      (should (string-search "check lint test" (rat-kingdom-king-status space)))
      (should-not (rat-kingdom-reaction-failures space)))))

(ert-deftest rat-kingdom-config-engine-test-setup-by-command-names ()
  (rat-kingdom-config-engine-test-with-repo (space path)
    (let ((log (shell-quote-argument (expand-file-name "../setup.log" path))))
      (rat-kingdom-config-engine-test--repo
       path `(:commands (:one ("sh" "-c" ,(format "echo one >> %s" log))
                       :two ("sh" "-c" "echo no network; exit 3")
                       :three ("sh" "-c" ,(format "echo three >> %s" log)))
              :setup (one two three)))
      (rat-kingdom-story-start space "demo" "Add a file" nil "S-1")
      (rat-kingdom-story-test--set-up space "S-1")
      ;; The second fails: the third does not run, and no worker starts.
      (let ((reason (rat-kingdom-story-test--get space "S-1" :reason)))
        (should (equal (rat-kingdom-story-test--place space "S-1") "blocked"))
        (should (string-search "setup failed" reason))
        (should (string-search "the setup command two (sh -c" reason))
        (should (string-search "exited with 3" reason))
        (should (string-search "no network" reason)))
      (should (equal (rat-kingdom-story-test--lines
                      (expand-file-name "../setup.log" path))
                     '("one")))
      (should-not rat-kingdom-story-test--started)
      ;; Put right, every command runs, in order, and the worker starts.
      (rat-kingdom-config-engine-test--repo
       path `(:commands (:one ("sh" "-c" ,(format "echo one >> %s" log))
                       :three ("sh" "-c" ,(format "echo three >> %s" log)))
              :setup (one three)))
      (rat-kingdom-story-move space "S-1" 'ready)
      (rat-kingdom-story-test--set-up space "S-1")
      (should (equal (rat-kingdom-story-test--get space "S-1" :run) "S-1.1"))
      (should (equal (rat-kingdom-story-test--lines
                      (expand-file-name "../setup.log" path))
                     '("one" "one" "three")))
      (should-not (rat-kingdom-reaction-failures space)))))

(ert-deftest rat-kingdom-config-engine-test-undefined-command-stops-the-story ()
  (rat-kingdom-config-engine-test-with-repo (space path)
    (rat-kingdom-config-engine-test--repo path '(:check (lint)))
    (should (string-search "its configuration is wrong"
                           (rat-kingdom-king-status space)))
    (rat-kingdom-story-start space "demo" "Add a file" nil "S-1")
    (rat-kingdom-reaction-run space)
    (rat-kingdom-story-test--work space "S-1" "feature.txt")
    (rat-kingdom-reaction-run space)
    (let ((reason (rat-kingdom-story-test--get space "S-1" :reason)))
      (should (equal (rat-kingdom-story-test--place space "S-1") "blocked"))
      (should (string-search "could not be begun" reason))
      (should (string-search "lint is not defined" reason)))))

;;;; Agents, timeouts, attempts and workers

(ert-deftest rat-kingdom-config-engine-test-worker-agent ()
  (rat-kingdom-config-engine-test-with-repo (space path)
    (let ((rat-kingdom-default-agent 'claude))
      (rat-kingdom-config-engine-test--repo path '(:agents (:worker codex)))
      (rat-kingdom-story-start space "demo" "One" nil "S-1")
      (should (equal (rat-kingdom-story-test--get space "S-1" :agent) "codex"))
      (rat-kingdom-reaction-run space)
      (should (equal (rat-kingdom-story-test--agent "S-1.1") "codex"))
      ;; An agent named when starting still wins.
      (rat-kingdom-story-start space "demo" "Two" nil "S-2" nil nil "claude")
      (should (equal (rat-kingdom-story-test--get space "S-2" :agent)
                     "claude"))
      (should (string-search "; workers run codex"
                             (rat-kingdom-king-status space))))))

(ert-deftest rat-kingdom-config-engine-test-timeouts ()
  (rat-kingdom-config-engine-test-with-repo (space path)
    (rat-kingdom-config-engine-test--repo path '(:timeouts (:worker 600)))
    (setq rat-kingdom-story-test--now 1000.0)
    (rat-kingdom-story-start space "demo" "Add a file" nil "S-1")
    (rat-kingdom-reaction-run space)
    (setq rat-kingdom-story-test--now 1500.0)
    (should (zerop (rat-kingdom-story-watch space)))
    (setq rat-kingdom-story-test--now 1700.0)
    (should (eql (rat-kingdom-story-watch space) 1))
    (should (string-search "Step implement has taken 11 minutes; its limit \
is 10"
                           (plist-get (plist-get (rat-kingdom-space-rd
                                                  space '(stuck :identity "S-1"))
                                                 :payload)
                                      :reason)))))

(ert-deftest rat-kingdom-config-engine-test-attempts ()
  (rat-kingdom-config-engine-test-with-repo (space path)
    (rat-kingdom-repo-add space path :check '("false"))
    (rat-kingdom-config-engine-test--repo path '(:attempts 1))
    (rat-kingdom-story-start space "demo" "Add a file" nil "S-1")
    (rat-kingdom-reaction-run space)
    (rat-kingdom-story-test--work space "S-1" "one.txt")
    (rat-kingdom-story-test--settle space "S-1")
    (should (equal (rat-kingdom-story-test--place space "S-1") "blocked"))
    (should (string-search "Gave up after 1 workers"
                           (rat-kingdom-story-test--get space "S-1" :reason)))
    (should (eql (length rat-kingdom-story-test--started) 1))))

(ert-deftest rat-kingdom-config-engine-test-max-workers ()
  (rat-kingdom-config-engine-test-with-repo (space _path)
    (rat-kingdom-config-engine-test--write
     (expand-file-name "config.eld" rat-kingdom-directory) '(:max-workers 1))
    (rat-kingdom-story-start space "demo" "One" nil "S-1")
    (rat-kingdom-story-start space "demo" "Two" nil "S-2")
    (rat-kingdom-reaction-run space)
    (should (equal (rat-kingdom-story-test--get space "S-1" :awaiting)
                   "worker"))
    (should (equal (rat-kingdom-story-test--get space "S-2" :awaiting)
                   rat-kingdom-story-free-worker))))

;;;; An epic's policy

(ert-deftest rat-kingdom-config-engine-test-epic-policy-overrides-the-repo ()
  (rat-kingdom-config-engine-test-with-repo (space path)
    (rat-kingdom-config-engine-test--repo
     path '(:workflow story :agents (:worker codex) :attempts 1
                      :timeouts (:worker 600)
                      :commands (:pass ("true") :fail ("false"))
                      :check (fail)))
    (rat-kingdom-config-policy-set
     space "demo" 'epic "E-1"
     '(:workflow story-lite :agents (:worker claude) :attempts 3
                 :timeouts (:worker 6000) :check (pass)))
    (setq rat-kingdom-story-test--now 1000.0)
    ;; A story of no epic follows the repository's file.
    (rat-kingdom-story-start space "demo" "Plain" nil "S-1")
    (should (equal (rat-kingdom-story-test--get space "S-1" :workflow) "story"))
    (should (equal (rat-kingdom-story-test--get space "S-1" :agent) "codex"))
    ;; A story of the epic follows its policy where it says something.
    (rat-kingdom-story-start space "demo" "Of the epic" nil "S-2" nil nil nil
                             "E-1")
    (should (equal (rat-kingdom-story-test--get space "S-2" :workflow)
                   "story-lite"))
    (should (equal (rat-kingdom-story-test--get space "S-2" :agent) "claude"))
    (rat-kingdom-reaction-run space)
    ;; Its timeout is the policy's.
    (setq rat-kingdom-story-test--now 1700.0)
    (should (eql (rat-kingdom-story-watch space) 1))
    (should (rat-kingdom-space-rd space '(stuck :identity "S-1")))
    (should-not (rat-kingdom-space-rd space '(stuck :identity "S-2")))
    ;; Its check is the policy's, using a command the repository defines.
    (rat-kingdom-story-test--work space "S-2" "epic.txt")
    (rat-kingdom-story-test--settle space "S-2")
    (should-not (rat-kingdom-story-get space "S-2"))
    (should (equal (rat-kingdom-story-test--git
                    path "show" "rk/integration:epic.txt")
                   "work"))
    ;; The other's check fails, and with one attempt it gives up.
    (rat-kingdom-story-test--work space "S-1" "plain.txt")
    (rat-kingdom-story-test--settle space "S-1")
    (should (string-search "Gave up after 1 workers"
                           (rat-kingdom-story-test--get space "S-1" :reason)))))

(ert-deftest rat-kingdom-config-engine-test-foreman-agent ()
  (let ((rat-kingdom-config--files (make-hash-table :test #'equal))
        (rat-kingdom-config--errors (make-hash-table :test #'equal)))
    (rat-kingdom-foreman-test-with-epic (space _fake)
      (let ((path (plist-get (rat-kingdom-repo-get space "demo") :path)))
        (rat-kingdom-config-engine-test--repo path '(:agents (:foreman codex)))
        (should (string-match-p "Started the foreman F-T-1 ([A-Za-z]+-T-1, \
codex)"
                                (rat-kingdom-foreman-test--start space)))
        (should (equal (plist-get (rat-kingdom-run-get
                                   space rat-kingdom-foreman-test--id)
                                  :agent)
                       "codex"))))))

;;;; Errors in status

(ert-deftest rat-kingdom-config-engine-test-status-shows-ignored-files ()
  (rat-kingdom-config-engine-test-with-repo (space path)
    (should-not (string-search "Configuration ignored"
                               (rat-kingdom-king-status space)))
    (rat-kingdom-config-engine-test--repo path "(:bogus 1)")
    (rat-kingdom-config-engine-test--write
     (expand-file-name "config.eld" rat-kingdom-directory) "(:attempts")
    (let ((status (rat-kingdom-king-status space)))
      (should (string-search "Configuration ignored" status))
      (should (string-search (expand-file-name ".rk/config.eld" path) status))
      (should (string-search ":bogus is not a configuration key" status))
      (should (string-search (expand-file-name "config.eld"
                                               rat-kingdom-directory)
                             status))
      (should (string-search "a list is not closed" status)))
    ;; Fixing the files is enough.
    (rat-kingdom-config-engine-test--repo path "(:attempts 2)")
    (rat-kingdom-config-engine-test--write
     (expand-file-name "config.eld" rat-kingdom-directory) "")
    (delete-file (expand-file-name "config.eld" rat-kingdom-directory))
    (should-not (string-search "Configuration ignored"
                               (rat-kingdom-king-status space)))))

(provide 'rat-kingdom-config-engine-test)
;;; rat-kingdom-config-engine-test.el ends here
