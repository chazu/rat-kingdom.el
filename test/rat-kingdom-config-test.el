;;; rat-kingdom-config-test.el --- Tests for configuration layers -*- lexical-binding: t; -*-

;;; Commentary:

;; Batch tests for rat-kingdom-config.el: reading .eld files, policy
;; tuples, the layers and their merge, and resolving command names.
;; Each test has its own space, `rat-kingdom-directory' and repository
;; in a temporary directory, and its own caches.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'rat-kingdom)
(require 'rat-kingdom-config)

(defvar rat-kingdom-config-test--messages nil
  "What `message' was asked to show during a test, oldest last.")

(defun rat-kingdom-config-test--git (directory &rest args)
  "Run Git with ARGS in DIRECTORY, signalling if it fails."
  (apply #'rat-kingdom-git directory args))

(defmacro rat-kingdom-config-test-with-repo (vars &rest body)
  "Run BODY with a fresh space and a registered repository.
VARS is (SPACE PATH): the space and the repository's checkout, a Git
repository with the branches main and rk/integration, registered as
\"demo\" with nothing but its path and target.  The user options the
defaults come from have their standard values."
  (declare (indent 1) (debug t))
  (let ((root (make-symbol "root"))
        (space (car vars))
        (path (cadr vars)))
    `(let* ((,root (file-name-as-directory
                    (file-truename (make-temp-file "rat-kingdom-config" t))))
            (rat-kingdom-directory (expand-file-name "state/" ,root))
            (rat-kingdom-config--files (make-hash-table :test #'equal))
            (rat-kingdom-config--errors (make-hash-table :test #'equal))
            (rat-kingdom-config-test--messages nil)
            (rat-kingdom-space-change-functions nil)
            (rat-kingdom-story-default-workflow "story")
            (rat-kingdom-git-default-target "rk/integration")
            (rat-kingdom-default-agent 'claude)
            (rat-kingdom-story-timeouts '((:spawn . 7200) (:check . 1800)))
            (rat-kingdom-story-attempts 5)
            (rat-kingdom-story-max-workers 3)
            (rat-kingdom-task-br-untracked t)
            (,path (expand-file-name "demo/" ,root))
            (,space (rat-kingdom-space-open
                     (expand-file-name "space.db" rat-kingdom-directory))))
       (make-directory ,path t)
       (rat-kingdom-config-test--git ,path "init" "-q" "-b" "main")
       (rat-kingdom-config-test--git ,path "config" "user.name" "Test")
       (rat-kingdom-config-test--git ,path "config" "user.email"
                                     "test@example.com")
       (rat-kingdom-config-test--git ,path "commit" "-q" "--allow-empty"
                                     "-m" "Initial commit")
       (rat-kingdom-config-test--git ,path "branch" "rk/integration")
       (rat-kingdom-space-put ,space 'repo :scope "demo" :identity "demo"
                              :payload (list :path ,path
                                             :target "rk/integration"))
       (unwind-protect
           (cl-letf (((symbol-function 'message)
                      (lambda (format-string &rest args)
                        (push (apply #'format format-string args)
                              rat-kingdom-config-test--messages))))
             ,@body)
         (rat-kingdom-space-close ,space)
         (delete-directory ,root t)))))

(defun rat-kingdom-config-test--write (file text &optional age)
  "Write TEXT to FILE, making its directory, and return FILE.
Its modification time is AGE seconds ago, by default none, so that a
file written twice in one test has two different times."
  (make-directory (file-name-directory file) t)
  (with-temp-file file (insert text))
  (set-file-times file (time-subtract nil (or age 0)))
  file)

(defun rat-kingdom-config-test--global (text &optional age)
  "Write TEXT as the global configuration file, AGE seconds old."
  (rat-kingdom-config-test--write (rat-kingdom-config-global-file) text age))

(defun rat-kingdom-config-test--repo-file (path text &optional age)
  "Write TEXT as the configuration file of the checkout PATH."
  (rat-kingdom-config-test--write (expand-file-name ".rk/config.eld" path)
                                  text age))

(defun rat-kingdom-config-test--register (space path &rest fields)
  "Register demo at PATH in SPACE again, with FIELDS on its record."
  (rat-kingdom-space-put space 'repo :scope "demo" :identity "demo"
                         :payload (append (list :path path
                                                :target "rk/integration")
                                          fields)))

(defun rat-kingdom-config-test--origin (space key &rest arguments)
  "Return the layer KEY's value came from in SPACE, given ARGUMENTS."
  (nth 2 (assq key (apply #'rat-kingdom-config-explain space arguments))))

;;;; The defaults

(ert-deftest rat-kingdom-config-test-defaults-come-from-the-user-options ()
  (rat-kingdom-config-test-with-repo (space _path)
    (should (equal (rat-kingdom-config-get space :workflow :repo "demo")
                   "story"))
    (should (equal (rat-kingdom-config-get space :timeouts)
                   '(:worker 7200 :check 1800)))
    (should (equal (rat-kingdom-config-get space :agents)
                   '(:worker claude :foreman claude)))
    (should (equal (rat-kingdom-config-get space :track) '(:rk nil :beads nil)))
    (should (eql (rat-kingdom-config-get space :attempts) 5))
    (should (eql (rat-kingdom-config-get space :max-workers) 3))
    (should-not (rat-kingdom-config-get space :commands))
    (should-not (rat-kingdom-config-get space :check :repo "demo"))
    (let ((rat-kingdom-story-timeouts '((:spawn . 60)))
          (rat-kingdom-task-br-untracked nil)
          (rat-kingdom-story-max-workers nil)
          (rat-kingdom-default-agent 'codex))
      (should (equal (rat-kingdom-config-get space :timeouts) '(:worker 60)))
      (should (equal (rat-kingdom-config-get space :track) '(:rk nil :beads t)))
      (should-not (rat-kingdom-config-get space :max-workers))
      (should (eq (plist-get (rat-kingdom-config-get space :agents) :worker)
                  'codex)))
    (should (eq (rat-kingdom-config-test--origin space :workflow) 'defaults))
    (should-error (rat-kingdom-config-get space :nonsense)
                  :type 'rat-kingdom-config-error)))

;;;; Layers

(ert-deftest rat-kingdom-config-test-each-layer-wins-over-the-one-below ()
  (rat-kingdom-config-test-with-repo (space path)
    (let ((arguments '(:repo "demo" :epic "E-1" :task "T-1")))
      (cl-flet ((workflow () (apply #'rat-kingdom-config-get space :workflow
                                    arguments))
                (origin () (apply #'rat-kingdom-config-test--origin
                                  space :workflow arguments)))
        (should (equal (workflow) "story"))
        (should (eq (origin) 'defaults))
        (rat-kingdom-config-test--global "(:workflow global-flow)")
        (should (equal (workflow) "global-flow"))
        (should (eq (origin) 'global))
        (rat-kingdom-config-test--register space path :workflow "registered")
        (should (equal (workflow) "registered"))
        (should (eq (origin) 'registration))
        (rat-kingdom-config-test--repo-file path ";; The repo's own.
(:workflow repo-flow)
;; Done.
")
        (should (equal (workflow) "repo-flow"))
        (should (eq (origin) 'repo))
        (rat-kingdom-config-policy-set space "demo" 'epic "E-1"
                                       '(:workflow epic-flow))
        (should (equal (workflow) "epic-flow"))
        (should (eq (origin) 'epic))
        (rat-kingdom-config-policy-set space "demo" 'task "T-1"
                                       '(:workflow "task-flow"))
        (should (equal (workflow) "task-flow"))
        (should (eq (origin) 'task))
        ;; Without the task, the epic's is back.
        (should (equal (rat-kingdom-config-get space :workflow :repo "demo"
                                               :epic "E-1")
                       "epic-flow"))
        ;; Without the repository, only the defaults and global count.
        (should (equal (rat-kingdom-config-get space :workflow :epic "E-1")
                       "global-flow"))))))

(ert-deftest rat-kingdom-config-test-registration-gives-check-and-target ()
  (rat-kingdom-config-test-with-repo (space path)
    (rat-kingdom-config-test--global "(:check (\"make\" \"all\") \
:target \"global-target\")")
    (rat-kingdom-config-test--register space path :check '("make" "check")
                                      :setup '("npm" "ci"))
    (should (equal (rat-kingdom-config-get space :check :repo "demo")
                   '("make" "check")))
    (should (equal (rat-kingdom-config-get space :setup :repo "demo")
                   '("npm" "ci")))
    (should (equal (rat-kingdom-config-get space :target :repo "demo")
                   "rk/integration"))
    (should (eq (rat-kingdom-config-test--origin space :target :repo "demo")
                'registration))
    ;; A nil in the record is as if left out.
    (rat-kingdom-config-test--register space path :check nil)
    (should (equal (rat-kingdom-config-get space :check :repo "demo")
                   '("make" "all")))))

(ert-deftest rat-kingdom-config-test-plist-keys-merge-sub-key-by-sub-key ()
  (rat-kingdom-config-test-with-repo (space path)
    (rat-kingdom-config-test--global "(:commands (:lint (\"eslint\" \".\") \
:test (\"npm\" \"test\")) :timeouts (:check 600) :agents (:foreman codex))")
    (rat-kingdom-config-test--repo-file path "(:commands (:test (\"make\" \
\"test\")) :track (:rk t))")
    (rat-kingdom-config-policy-set space "demo" 'epic "E-1"
                                   '(:timeouts (:worker 100)))
    (let ((explained (rat-kingdom-config-explain space :repo "demo"
                                                 :epic "E-1")))
      (should (equal (assq :commands explained)
                     '(:commands (:lint ("eslint" ".") :test ("make" "test"))
                                 (:lint global :test repo))))
      (should (equal (assq :timeouts explained)
                     '(:timeouts (:worker 100 :check 600)
                                 (:worker epic :check global))))
      (should (equal (assq :agents explained)
                     '(:agents (:worker claude :foreman codex)
                               (:worker defaults :foreman global))))
      (should (equal (assq :track explained)
                     '(:track (:rk t :beads nil) (:rk repo :beads defaults))))
      ;; Every key is there, set or not.
      (should (equal (mapcar #'car explained)
                     (mapcar #'car rat-kingdom-config-schema)))
      (should (equal (assq :setup explained) '(:setup nil nil))))
    (should (equal (rat-kingdom-config-get space :commands :repo "demo")
                   '(:lint ("eslint" ".") :test ("make" "test"))))))

(ert-deftest rat-kingdom-config-test-layer-restrictions ()
  (should-not (rat-kingdom-config-validate '(:max-workers 2) 'global))
  (should (string-match-p
           ":max-workers cannot be set at the repo layer"
           (car (rat-kingdom-config-validate '(:max-workers 2) 'repo))))
  (should (rat-kingdom-config-validate '(:target "x") 'epic))
  (should (rat-kingdom-config-validate '(:commands (:a ("b"))) 'task))
  (should (rat-kingdom-config-validate '(:setup ("b")) 'epic))
  (should-not (rat-kingdom-config-validate '(:check (lint)) 'task))
  (should-not (rat-kingdom-config-validate '(:track (:beads t)) 'repo))
  (should (rat-kingdom-config-validate '(:track (:beads t)) 'epic))
  (should-error (rat-kingdom-config-validate '() 'nowhere))
  (rat-kingdom-config-test-with-repo (space path)
    ;; A repo file that sets a key it may not is ignored as a whole.
    (rat-kingdom-config-test--repo-file path "(:attempts 9 :max-workers 1)")
    (should (eql (rat-kingdom-config-get space :attempts :repo "demo") 5))
    (should (eql (rat-kingdom-config-get space :max-workers :repo "demo") 3))
    (should (string-match-p
             "max-workers cannot be set at the repo layer"
             (cadr (car (rat-kingdom-config-errors "demo")))))
    ;; A policy that sets a key it may not is refused, and nothing is
    ;; written.
    (should-error (rat-kingdom-config-policy-set space "demo" 'epic "E-1"
                                                 '(:target "elsewhere"))
                  :type 'rat-kingdom-config-error)
    (should-not (rat-kingdom-config-policy-tuple space "demo" 'epic "E-1"))))

(ert-deftest rat-kingdom-config-test-values-are-validated ()
  (dolist (bad '((:workflow 7)
                 (:target story)
                 (:commands (:lint "eslint"))
                 (:commands (lint ("eslint")))
                 (:setup ("npm" install))
                 (:check (:lint))
                 (:agents (:king claude))
                 (:timeouts (:worker -1))
                 (:attempts 0)
                 (:attempts 1.5)
                 (:track (:rk yes))
                 (:nonsense 1)
                 (:attempts 2 :attempts 3)
                 (:attempts)
                 "not a list"))
    (should (rat-kingdom-config-validate bad 'global)))
  (should-not (rat-kingdom-config-validate
               '(:workflow story :target "main"
                 :commands (:install ("npm" "ci") :lint ("npx" "eslint" "."))
                 :setup (install) :check (lint test)
                 :agents (:worker codex :foreman "claude")
                 :timeouts (:worker 7200 :check 1800)
                 :attempts 5 :max-workers 3 :track (:rk t :beads nil))
               'global)))

;;;; Files

(ert-deftest rat-kingdom-config-test-invalid-file-is-ignored-with-an-error ()
  (rat-kingdom-config-test-with-repo (space path)
    (let ((file (rat-kingdom-config-test--global "(:attempts 7)"))
          (age 0))
      (should (eql (rat-kingdom-config-get space :attempts) 7))
      (should-not (rat-kingdom-config-errors))
      (dolist (case '(("(:attempts 7" . "not closed")
                      ("(:attempts 7) (:attempts 8)" . "more after")
                      ("" . "no property list")
                      ("(:attempts \"seven\")" . "positive integer")
                      (";; only a comment\n" . "no property list")
                      ("(:unknown 1)" . "not a configuration key")
                      ("story" . "property list")))
        (setq rat-kingdom-config-test--messages nil)
        (rat-kingdom-config-test--write file (car case) (cl-incf age))
        ;; The whole file is ignored, so the default is back.
        (should (eql (rat-kingdom-config-get space :attempts) 5))
        (let ((errors (rat-kingdom-config-errors)))
          (should (eql (length errors) 1))
          (should (equal (car (car errors)) file))
          (should (string-match-p (cdr case) (cadr (car errors)))))
        ;; Shown once in *Messages*, however often it is read.
        (rat-kingdom-config-get space :attempts)
        (should (eql (length rat-kingdom-config-test--messages) 1))
        (should (string-match-p (regexp-quote file)
                                (car rat-kingdom-config-test--messages))))
      ;; The global file's error affects every repository; a repo
      ;; file's only its own.
      (rat-kingdom-config-test--repo-file path "(:bad 1)")
      (rat-kingdom-config-get space :attempts :repo "demo")
      (should (eql (length (rat-kingdom-config-errors "demo")) 2))
      (should (eql (length (rat-kingdom-config-errors "other")) 1))
      ;; Fixing a file is enough; removing it is no error.
      (rat-kingdom-config-test--write file "(:attempts 8)")
      (delete-file (expand-file-name ".rk/config.eld" path))
      (should (eql (rat-kingdom-config-get space :attempts :repo "demo") 8))
      (should-not (rat-kingdom-config-errors)))))

(ert-deftest rat-kingdom-config-test-file-is-read-again-when-it-changes ()
  (rat-kingdom-config-test-with-repo (space _path)
    (let ((file (rat-kingdom-config-test--global "(:attempts 7)" 100))
          (reads 0))
      (advice-add 'rat-kingdom-config--parse :before
                  (lambda (&rest _) (cl-incf reads))
                  '((name . rat-kingdom-config-test--count)))
      (unwind-protect
          (progn
            (should (eql (rat-kingdom-config-get space :attempts) 7))
            (should (eql (rat-kingdom-config-get space :attempts) 7))
            (should (eql reads 1))
            ;; Same size, new time.
            (rat-kingdom-config-test--write file "(:attempts 8)" 50)
            (should (eql (rat-kingdom-config-get space :attempts) 8))
            (should (eql reads 2))
            ;; A change that keeps the time and size is not seen.
            (let ((time (file-attribute-modification-time
                         (file-attributes file))))
              (with-temp-file file (insert "(:attempts 9)"))
              (set-file-times file time))
            (should (eql (rat-kingdom-config-get space :attempts) 8))
            (should (eql reads 2)))
        (advice-remove 'rat-kingdom-config--parse
                       'rat-kingdom-config-test--count)))))

(ert-deftest rat-kingdom-config-test-file-is-never-evaluated ()
  (rat-kingdom-config-test-with-repo (space _path)
    (let ((file (expand-file-name "evaluated" rat-kingdom-directory)))
      (rat-kingdom-config-test--global
       (format "(:workflow (progn (write-region \"\" nil %S) 'x))" file))
      (should (equal (rat-kingdom-config-get space :workflow) "story"))
      (should (rat-kingdom-config-errors))
      (should-not (file-exists-p file)))))

;;;; Policies

(ert-deftest rat-kingdom-config-test-policy-tuples ()
  (rat-kingdom-config-test-with-repo (space _path)
    (should-not (rat-kingdom-config-policy space "demo" 'epic "E-1"))
    (let ((tuple (rat-kingdom-config-policy-set
                  space "demo" 'epic "E-1"
                  '(:check (lint test) :agents (:worker "codex") :attempts nil))))
      (should (eq (plist-get tuple :category) 'policy))
      (should (eq (plist-get tuple :modality) 'persistent))
      (should (equal (plist-get tuple :scope) "demo"))
      (should (equal (plist-get tuple :identity) "epic:E-1"))
      (should (equal (plist-get tuple :owner) "E-1"))
      (should (equal (plist-get (plist-get tuple :payload) :layer) "epic")))
    ;; Command names stay symbols, kinds become symbols, nil is left out.
    (should (equal (rat-kingdom-config-policy space "demo" "epic" "E-1")
                   '(:check (lint test) :agents (:worker codex))))
    ;; An epic and a task with the same id each have their own.
    (rat-kingdom-config-policy-set space "demo" 'task "E-1" '(:attempts 2))
    (should (equal (rat-kingdom-config-policy space "demo" 'task "E-1")
                   '(:attempts 2)))
    (should (equal (rat-kingdom-config-policy space "demo" 'epic "E-1")
                   '(:check (lint test) :agents (:worker codex))))
    ;; Replaced whole.
    (rat-kingdom-config-policy-set space "demo" 'epic "E-1" '(:attempts 3))
    (should (equal (rat-kingdom-config-policy space "demo" 'epic "E-1")
                   '(:attempts 3)))
    (should (eql (length (rat-kingdom-space-scan space '(policy :scope "demo")))
                 2))
    ;; Emptied, it is removed.
    (should-not (rat-kingdom-config-policy-set space "demo" 'epic "E-1"
                                               '(:attempts nil)))
    (should-not (rat-kingdom-config-policy-tuple space "demo" 'epic "E-1"))
    ;; Swept with its owner.
    (rat-kingdom-space-sweep space "E-1")
    (should-not (rat-kingdom-config-policy space "demo" 'task "E-1"))
    (should-error (rat-kingdom-config-policy-set space "demo" 'story "S-1"
                                                 '(:attempts 1)))))

(ert-deftest rat-kingdom-config-test-invalid-policy-is-ignored ()
  (rat-kingdom-config-test-with-repo (space _path)
    ;; Written by another process, past the validation.
    (rat-kingdom-space-put space 'policy :scope "demo" :identity "task:T-1"
                           :owner "T-1"
                           :payload '(:layer "task" :of "T-1"
                                      :config "(:max-workers 9)"))
    (should (eql (rat-kingdom-config-get space :max-workers :repo "demo"
                                         :task "T-1")
                 3))
    (should (string-match-p "max-workers cannot be set at the task layer"
                            (cadr (car (rat-kingdom-config-errors "demo")))))
    (rat-kingdom-config-policy-set space "demo" 'task "T-1" '(:attempts 1))
    (should-not (rat-kingdom-config-errors))
    (should (eql (rat-kingdom-config-get space :attempts :repo "demo"
                                         :task "T-1")
                 1))))

;;;; Commands

(ert-deftest rat-kingdom-config-test-resolving-commands ()
  (let ((commands '(:lint ("npx" "eslint" ".") :test ("npm" "test"))))
    (should-not (rat-kingdom-config-resolve-commands nil commands))
    (should (equal (rat-kingdom-config-resolve-commands '("make" "test")
                                                        commands)
                   '(("make" "test"))))
    (should (equal (rat-kingdom-config-resolve-commands '(test lint) commands)
                   '(("npm" "test") ("npx" "eslint" "."))))
    (let ((err (should-error (rat-kingdom-config-resolve-commands
                              '(lint build) commands)
                             :type 'rat-kingdom-config-error)))
      (should (string-match-p "build is not defined.*lint, test"
                              (cadr err))))
    (should-error (rat-kingdom-config-resolve-commands '(lint) nil)
                  :type 'rat-kingdom-config-error)
    (should-error (rat-kingdom-config-resolve-commands '("make" lint) commands)
                  :type 'rat-kingdom-config-error))
  ;; Names in a global check, commands from the repository's own file.
  (rat-kingdom-config-test-with-repo (space path)
    (rat-kingdom-config-test--global "(:check (lint test) :setup (install))")
    (should-error (rat-kingdom-config-commands space :check :repo "demo")
                  :type 'rat-kingdom-config-error)
    (rat-kingdom-config-test--repo-file path "(:commands (:lint (\"lint\") \
:test (\"make\" \"test\") :install (\"npm\" \"ci\")))")
    (should (equal (rat-kingdom-config-commands space :check :repo "demo")
                   '(("lint") ("make" "test"))))
    (should (equal (rat-kingdom-config-commands space :setup :repo "demo")
                   '(("npm" "ci"))))
    (rat-kingdom-config-policy-set space "demo" 'task "T-1" '(:check (test)))
    (should (equal (rat-kingdom-config-commands space :check :repo "demo"
                                                :task "T-1")
                   '(("make" "test"))))
    (should-error (rat-kingdom-config-commands space :attempts :repo "demo"))))

;;;; The merged result

(ert-deftest rat-kingdom-config-test-validate-merged ()
  (rat-kingdom-config-test-with-repo (space path)
    (should-not (rat-kingdom-config-validate-merged space "demo"))
    (rat-kingdom-config-test--global "(:check (lint))")
    (should (string-match-p ":check: The command lint is not defined"
                            (car (rat-kingdom-config-validate-merged
                                  space "demo"))))
    (rat-kingdom-config-test--repo-file path "(:commands (:lint (\"lint\")))")
    (should-not (rat-kingdom-config-validate-merged space "demo"))
    ;; A change tried before it is made.
    (let ((problems (rat-kingdom-config-validate-merged
                     space "demo" :layer 'repo
                     :plist '(:workflow nowhere :target "missing"
                              :agents (:worker nobody)))))
      (should (eql (length problems) 4))
      (should (cl-some (lambda (p) (string-match-p "no workflow called nowhere"
                                                   p))
                       problems))
      (should (cl-some (lambda (p) (string-match-p "no agent called nobody" p))
                       problems))
      (should (cl-some (lambda (p) (string-match-p "lint is not defined" p))
                       problems))
      (should (cl-some (lambda (p) (string-match-p "missing is not a local \
branch of demo" p))
                       problems)))
    (should (string-match-p
             "At the epic layer: :target cannot be set"
             (car (rat-kingdom-config-validate-merged
                   space "demo" :epic "E-1" :layer 'epic
                   :plist '(:target "main")))))
    ;; Nothing was written by trying.
    (should-not (rat-kingdom-config-policy-tuple space "demo" 'epic "E-1"))
    (should-not (rat-kingdom-config-validate-merged space "demo"))))

(provide 'rat-kingdom-config-test)
;;; rat-kingdom-config-test.el ends here
