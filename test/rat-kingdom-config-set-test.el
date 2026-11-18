;;; rat-kingdom-config-set-test.el --- The king's config_show and config_set -*- lexical-binding: t; -*-

;;; Commentary:

;; Batch tests for the king's configuration tools (DESIGN.md, section
;; 7.3): config_show says where each value came from; config_set
;; writes the global file, a repository's .rk/config.eld or an epic's or
;; task's policy, refuses a change that would break the configuration
;; and then writes nothing, applies a change to :track at once, and is
;; offered to the king alone.

;;; Code:

(require 'ert)
(require 'rat-kingdom)
(require 'rat-kingdom-config)
(require 'rat-kingdom-config-engine-test)

(defun rat-kingdom-config-set-test--call (tool &rest arguments)
  "Call TOOL as the king with ARGUMENTS, an alist.  Return (TEXT . FAILED)."
  (rat-kingdom-mcp-call '(:run "king" :role king) tool arguments))

(defun rat-kingdom-config-set-test--ok (tool &rest arguments)
  "Call TOOL as the king with ARGUMENTS and return its text, which must not fail."
  (let ((answer (apply #'rat-kingdom-config-set-test--call tool arguments)))
    (should-not (cdr answer))
    (car answer)))

(defun rat-kingdom-config-set-test--refused (tool &rest arguments)
  "Call TOOL as the king with ARGUMENTS and return its text, which must fail."
  (let ((answer (apply #'rat-kingdom-config-set-test--call tool arguments)))
    (should (cdr answer))
    (car answer)))

(defun rat-kingdom-config-set-test--bytes (file)
  "Return the contents of FILE, or nil if it is missing."
  (and (file-exists-p file)
       (with-temp-buffer
         (insert-file-contents-literally file)
         (buffer-string))))

(defun rat-kingdom-config-set-test--read (file)
  "Return the one form in FILE."
  (rat-kingdom-config--parse file))

(defun rat-kingdom-config-set-test--exclude (path)
  "Return the lines of the info/exclude of the checkout PATH."
  (split-string (rat-kingdom-config-set-test--bytes
                 (rat-kingdom-git-exclude-file path))
                "\n" t))

(defmacro rat-kingdom-config-set-test-with-repo (vars &rest body)
  "Run BODY as `rat-kingdom-config-engine-test-with-repo' does, with VARS.
:track warnings are forgotten too, and display-warning shows nothing."
  (declare (indent 1) (debug t))
  `(let ((rat-kingdom-config--track-warnings (make-hash-table :test #'equal)))
     (cl-letf (((symbol-function 'display-warning) #'ignore))
       (rat-kingdom-config-engine-test-with-repo ,vars ,@body))))

;;;; config_show

(ert-deftest rat-kingdom-config-set-test-show-gives-each-layer ()
  (rat-kingdom-config-set-test-with-repo (space path)
    (rat-kingdom-config-engine-test--write
     (rat-kingdom-config-global-file)
     '(:attempts 7 :commands (:lint ("make" "lint"))))
    (rat-kingdom-config-engine-test--repo
     path '(:check (lint test) :commands (:test ("make" "test"))))
    (rat-kingdom-config-policy-set space "demo" 'epic "E-1" '(:attempts 2))
    (let ((text (rat-kingdom-config-set-test--ok
                 "config_show" '(repo . "demo") '(epic . "E-1"))))
      (should (string-search "Configuration of demo, epic E-1" text))
      (dolist (line '("- :workflow story-lite (defaults)"
                      "- :target \"rk/integration\" (registration)"
                      "- :commands :lint (\"make\" \"lint\") (global)"
                      "- :commands :test (\"make\" \"test\") (repo)"
                      "- :setup not set"
                      "- :check (lint test) (repo)"
                      "- :agents :foreman claude (defaults)"
                      "- :attempts 2 (epic)"
                      "- :track :rk nil (defaults)"
                      "- :track :a2ui nil (defaults)"))
        (should (string-search (concat line "\n") (concat text "\n"))))
      (should (string-search (format "- global: %s\n"
                                     (rat-kingdom-config-global-file))
                             text))
      (should-not (string-search "Ignored" text))
      (should-not (string-search "Problems" text)))
    ;; Without the epic, the global layer's attempts.
    (should (string-search "- :attempts 7 (global)"
                           (rat-kingdom-config-set-test--ok
                            "config_show" '(repo . "demo"))))))

(ert-deftest rat-kingdom-config-set-test-show-gives-errors ()
  (rat-kingdom-config-set-test-with-repo (space path)
    (rat-kingdom-config-engine-test--write (rat-kingdom-config-global-file)
                                           "(:bogus 1)")
    (rat-kingdom-config-engine-test--repo path '(:check (lint)))
    (let ((text (rat-kingdom-config-set-test--ok
                 "config_show" '(repo . "demo"))))
      (should (string-search "Ignored" text))
      (should (string-search ":bogus is not a configuration key" text))
      (should (string-search "Problems with the merged configuration" text))
      (should (string-search "The command lint is not defined" text)))
    (should (string-search "There is no repository called nope"
                           (rat-kingdom-config-set-test--refused
                            "config_show" '(repo . "nope"))))))

;;;; config_set at each layer

(ert-deftest rat-kingdom-config-set-test-global ()
  (rat-kingdom-config-set-test-with-repo (space _path)
    (let ((file (rat-kingdom-config-global-file))
          (text (rat-kingdom-config-set-test--ok
                 "config_set" '(layer . "global") '(key . "attempts")
                 '(value . "4"))))
      (should (string-search "Set :attempts at the global layer" text))
      (should (string-search "- :attempts 4 (global)" text))
      (should (string-prefix-p rat-kingdom-config-file-header
                               (rat-kingdom-config-set-test--bytes file)))
      (should (equal (rat-kingdom-config-set-test--read file) '(:attempts 4)))
      (should (eql (rat-kingdom-config-get space :attempts :repo "demo") 4))
      ;; A second key is added; the first is kept.
      (rat-kingdom-config-set-test--ok
       "config_set" '(layer . "global") '(key . ":max-workers") '(value . "2"))
      (should (equal (rat-kingdom-config-set-test--read file)
                     '(:attempts 4 :max-workers 2)))
      ;; null removes the key.
      (should (string-search
               "Removed :attempts from the global layer"
               (rat-kingdom-config-set-test--ok
                "config_set" '(layer . "global") '(key . "attempts")
                '(value . "nil"))))
      (should (equal (rat-kingdom-config-set-test--read file)
                     '(:max-workers 2)))
      (should (eql (rat-kingdom-config-get space :attempts :repo "demo")
                   rat-kingdom-story-attempts))
      ;; Unchanged: nothing is written.
      (let ((before (rat-kingdom-config-set-test--bytes file)))
        (should (string-search "nothing was written"
                               (rat-kingdom-config-set-test--ok
                                "config_set" '(layer . "global")
                                '(key . "max-workers") '(value . "2"))))
        (should (equal (rat-kingdom-config-set-test--bytes file) before))))))

(ert-deftest rat-kingdom-config-set-test-repo ()
  (rat-kingdom-config-set-test-with-repo (space path)
    (let ((file (expand-file-name ".rk/config.eld" path)))
      (should-not (file-exists-p (expand-file-name ".rk" path)))
      (rat-kingdom-config-set-test--ok
       "config_set" '(layer . "repo") '(repo . "demo") '(key . "commands")
       '(value . "(:lint (\"make\" \"lint\") :test (\"make\" \"test\"))"))
      (rat-kingdom-config-set-test--ok
       "config_set" '(layer . "repo") '(repo . "demo") '(key . "check")
       '(value . "(lint test)"))
      (rat-kingdom-config-set-test--ok
       "config_set" '(layer . "repo") '(repo . "demo") '(key . "setup")
       '(value . "(\"npm\" \"ci\")"))
      (rat-kingdom-config-set-test--ok
       "config_set" '(layer . "repo") '(repo . "demo") '(key . "workflow")
       '(value . "story"))
      (rat-kingdom-config-set-test--ok
       "config_set" '(layer . "repo") '(repo . "demo") '(key . "timeouts")
       '(value . "(:worker 600)"))
      ;; The file reads back as what was set, in the shape of 7.3.
      (should (equal (rat-kingdom-config-set-test--read file)
                     '(:commands (:lint ("make" "lint") :test ("make" "test"))
                       :check (lint test)
                       :setup ("npm" "ci")
                       :workflow story
                       :timeouts (:worker 600))))
      (should-not (rat-kingdom-config-errors "demo"))
      (should (equal (rat-kingdom-config-commands space :check :repo "demo")
                     '(("make" "lint") ("make" "test"))))
      (should (equal (rat-kingdom-config-get space :workflow :repo "demo")
                     "story"))
      (should (equal (rat-kingdom-config-get space :timeouts :repo "demo")
                     '(:worker 600 :check 1800)))
      ;; .rk is kept out of Git, so the checkout stays clean.
      (should (equal (rat-kingdom-git path "status" "--porcelain") ""))
      ;; Sub-keys left out fall back to the layers below.
      (should (string-search "- :timeouts :check 1800 (defaults)"
                             (rat-kingdom-config-set-test--ok
                              "config_show" '(repo . "demo")))))))

(ert-deftest rat-kingdom-config-set-test-epic-and-task ()
  (rat-kingdom-config-set-test-with-repo (space _path)
    (let ((text (rat-kingdom-config-set-test--ok
                 "config_set" '(layer . "epic") '(repo . "demo")
                 '(epic . "E-1") '(key . "agents")
                 '(value . "(:worker codex)"))))
      (should (string-search "Set :agents at the policy of epic E-1 in demo"
                             text))
      (should (string-search "In effect now for demo, epic E-1" text))
      (should (string-search "- :agents :worker codex (epic)" text)))
    (should (equal (rat-kingdom-config-policy space "demo" 'epic "E-1")
                   '(:agents (:worker codex))))
    (should (equal (rat-kingdom-config-get space :agents :repo "demo"
                                           :epic "E-1")
                   '(:worker codex :foreman claude :consul claude)))
    (rat-kingdom-config-set-test--ok
     "config_set" '(layer . "task") '(repo . "demo") '(task . "T-1")
     '(key . "workflow") '(value . "story"))
    (should (equal (rat-kingdom-config-get space :workflow :repo "demo"
                                           :task "T-1")
                   "story"))
    (should (equal (rat-kingdom-config-get space :workflow :repo "demo")
                   "story-lite"))
    ;; Emptied, the policy is removed.
    (rat-kingdom-config-set-test--ok
     "config_set" '(layer . "task") '(repo . "demo") '(task . "T-1")
     '(key . "workflow") '(value . "nil"))
    (should-not (rat-kingdom-config-policy-tuple space "demo" 'task "T-1"))
    ;; Each needs its id and its repository.
    (should (string-search "Give the id of the epic"
                           (rat-kingdom-config-set-test--refused
                            "config_set" '(layer . "epic") '(repo . "demo")
                            '(key . "attempts") '(value . "2"))))
    (should (string-search "Give the name of the repository"
                           (rat-kingdom-config-set-test--refused
                            "config_set" '(layer . "repo")
                            '(key . "attempts") '(value . "2"))))))

(ert-deftest rat-kingdom-config-set-test-file-reads-back ()
  (let ((plist '(:workflow story
                 :target "rk/integration"
                 :commands (:install ("npm" "ci") :lint ("npx" "eslint" ".")
                            :test ("npm" "test"))
                 :setup (install)
                 :check (lint test)
                 :agents (:worker codex :foreman claude)
                 :timeouts (:worker 7200 :check 1800)
                 :attempts 5
                 :max-workers 3
                 :track (:rk t :beads nil)))
        (file (make-temp-file "rat-kingdom-config" nil ".eld")))
    (unwind-protect
        (progn
          (rat-kingdom-config--write-file file plist)
          (should (equal (rat-kingdom-config--parse file) plist))
          (should-not (rat-kingdom-config--comments-p file))
          ;; One key to a line.
          (should (eql (length (split-string
                                (rat-kingdom-config-set-test--bytes file)
                                "\n" t))
                       (+ 2 10 2 1 1 1))))
      (delete-file file))))

(ert-deftest rat-kingdom-config-set-test-comments-are-not-kept ()
  (rat-kingdom-config-set-test-with-repo (_space path)
    (let ((file (expand-file-name ".rk/config.eld" path)))
      (rat-kingdom-config-engine-test--repo
       path ";; The user's note.\n(:attempts 3) ; three\n")
      (should (string-search
               "The file had comments; they were not kept."
               (rat-kingdom-config-set-test--ok
                "config_set" '(layer . "repo") '(repo . "demo")
                '(key . "workflow") '(value . "story"))))
      (should-not (string-search "The user's note"
                                 (rat-kingdom-config-set-test--bytes file)))
      (should (equal (rat-kingdom-config-set-test--read file)
                     '(:attempts 3 :workflow story)))
      ;; rat-kingdom's own header is not counted.
      (should-not (string-search
                   "comments"
                   (rat-kingdom-config-set-test--ok
                    "config_set" '(layer . "repo") '(repo . "demo")
                    '(key . "attempts") '(value . "4")))))))

;;;; Refusals

(ert-deftest rat-kingdom-config-set-test-refusals-write-nothing ()
  (rat-kingdom-config-set-test-with-repo (space path)
    (let ((global (rat-kingdom-config-global-file))
          (repo (expand-file-name ".rk/config.eld" path)))
      ;; Nothing there yet: a refusal makes neither file nor .rk.
      (should (string-search
               "There is no workflow called nope"
               (rat-kingdom-config-set-test--refused
                "config_set" '(layer . "repo") '(repo . "demo")
                '(key . "workflow") '(value . "nope"))))
      (should-not (file-exists-p (expand-file-name ".rk" path)))
      ;; Now with files of their own.
      (rat-kingdom-config-set-test--ok
       "config_set" '(layer . "global") '(key . "commands")
       '(value . "(:lint (\"make\" \"lint\"))"))
      (rat-kingdom-config-set-test--ok
       "config_set" '(layer . "repo") '(repo . "demo") '(key . "check")
       '(value . "(lint)"))
      (let ((global-bytes (rat-kingdom-config-set-test--bytes global))
            (repo-bytes (rat-kingdom-config-set-test--bytes repo))
            (exclude (rat-kingdom-config-set-test--exclude path)))
        (dolist (case
                 `(;; An unknown workflow.
                   ("no workflow called nope"
                    (layer . "repo") (repo . "demo") (key . "workflow")
                    (value . "nope"))
                   ("no workflow called nope"
                    (layer . "global") (key . "workflow") (value . "nope"))
                   ;; An undefined command name.
                   ("The command missing is not defined"
                    (layer . "repo") (repo . "demo") (key . "check")
                    (value . "(lint missing)"))
                   ("The command missing is not defined"
                    (layer . "epic") (repo . "demo") (epic . "E-1")
                    (key . "check") (value . "(missing)"))
                   ;; Removing a command the repository's check needs.
                   ("The command lint is not defined"
                    (layer . "global") (key . "commands") (value . "nil"))
                   ;; A key not allowed at the layer.
                   (":max-workers cannot be set at the repo layer"
                    (layer . "repo") (repo . "demo") (key . "max-workers")
                    (value . "2"))
                   (":target cannot be set at the epic layer"
                    (layer . "epic") (repo . "demo") (epic . "E-1")
                    (key . "target") (value . "\"main\""))
                   (":track cannot be set at the task layer"
                    (layer . "task") (repo . "demo") (task . "T-1")
                    (key . "track") (value . "(:rk t)"))
                   ;; A value of the wrong shape.
                   (":attempts is a positive integer"
                    (layer . "global") (key . "attempts") (value . "\"three\""))
                   (":timeouts :worker is a positive number"
                    (layer . "repo") (repo . "demo") (key . "timeouts")
                    (value . "(:worker \"long\")"))
                   ("is an argument list"
                    (layer . "repo") (repo . "demo") (key . "commands")
                    (value . "(:lint \"make lint\")"))
                   (":track :rk is t or nil"
                    (layer . "repo") (repo . "demo") (key . "track")
                    (value . "(:rk yes)"))
                   ;; A target that is not a branch.
                   ("not a local branch"
                    (layer . "repo") (repo . "demo") (key . "target")
                    (value . "\"nowhere\""))
                   ;; Text that is not one form.
                   ("is not complete"
                    (layer . "repo") (repo . "demo") (key . "check")
                    (value . "(lint"))
                   ("holds more than one form"
                    (layer . "repo") (repo . "demo") (key . "check")
                    (value . "lint test"))
                   ;; An unknown key and layer.
                   (":bogus is not a configuration key"
                    (layer . "global") (key . "bogus") (value . "1"))
                   ("The layer is global, repo, epic or task"
                    (layer . "registration") (repo . "demo")
                    (key . "check") (value . "(\"make\")"))))
          (let ((text (apply #'rat-kingdom-config-set-test--refused
                             "config_set" (cdr case))))
            (should (string-search (car case) text)))
          (should (equal (rat-kingdom-config-set-test--bytes global)
                         global-bytes))
          (should (equal (rat-kingdom-config-set-test--bytes repo)
                         repo-bytes))
          (should (equal (rat-kingdom-config-set-test--exclude path) exclude))
          (should-not (rat-kingdom-space-scan space '(policy))))))))

(ert-deftest rat-kingdom-config-set-test-old-problems-do-not-block ()
  (rat-kingdom-config-set-test-with-repo (space path)
    ;; Hand-edited: a check that names a command defined nowhere.
    (rat-kingdom-config-engine-test--repo path '(:check (lint)))
    (should (rat-kingdom-config-validate-merged space "demo"))
    ;; An unrelated change is still made; fixing it is too.
    (rat-kingdom-config-set-test--ok
     "config_set" '(layer . "repo") '(repo . "demo") '(key . "attempts")
     '(value . "2"))
    (rat-kingdom-config-set-test--ok
     "config_set" '(layer . "repo") '(repo . "demo") '(key . "commands")
     '(value . "(:lint (\"true\"))"))
    (should-not (rat-kingdom-config-validate-merged space "demo"))))

;;;; :track

(ert-deftest rat-kingdom-config-set-test-track-is-applied ()
  (rat-kingdom-config-set-test-with-repo (_space path)
    (should (equal (last (rat-kingdom-config-set-test--exclude path) 3)
                   '("/.beads/" "/.rk/" "/.a2ui/")))
    (let ((text (rat-kingdom-config-set-test--ok
                 "config_set" '(layer . "repo") '(repo . "demo")
                 '(key . "track") '(value . "(:rk t)"))))
      (should (string-search "Applied :track to demo: removed /.rk/" text)))
    (should-not (member "/.rk/" (rat-kingdom-config-set-test--exclude path)))
    (should (equal (rat-kingdom-config-set-test--read
                    (expand-file-name ".rk/config.eld" path))
                   '(:track (:rk t))))
    ;; The repo file is untracked now, and shows.
    (should (string-search ".rk/" (rat-kingdom-git path "status"
                                                   "--porcelain")))
    ;; At the global layer, every repository.
    (should (string-search
             "Applied :track to demo: removed /.beads/"
             (rat-kingdom-config-set-test--ok
              "config_set" '(layer . "global") '(key . "track")
              '(value . "(:beads t)"))))
    (should-not (member "/.beads/"
                        (rat-kingdom-config-set-test--exclude path)))
    ;; false keeps it out again.
    (should (string-search
             "added /.rk/"
             (rat-kingdom-config-set-test--ok
              "config_set" '(layer . "repo") '(repo . "demo")
              '(key . "track") '(value . "(:rk nil)"))))
    (should (member "/.rk/" (rat-kingdom-config-set-test--exclude path)))
    ;; :a2ui t keeps .a2ui in Git, and touches no other line.
    (let ((before (rat-kingdom-config-set-test--exclude path)))
      (should (string-search
               "Applied :track to demo: removed /.a2ui/"
               (rat-kingdom-config-set-test--ok
                "config_set" '(layer . "global") '(key . "track")
                '(value . "(:beads t :a2ui t)"))))
      (should (equal (rat-kingdom-config-set-test--exclude path)
                     (remove "/.a2ui/" before))))
    (should (string-search
             ":track :a2ui is t or nil"
             (rat-kingdom-config-set-test--refused
              "config_set" '(layer . "global") '(key . "track")
              '(value . "(:a2ui yes)"))))))

;;;; Roles

(ert-deftest rat-kingdom-config-set-test-king-only ()
  (should (member "config_show" (rat-kingdom-mcp-tool-names 'king)))
  (should (member "config_set" (rat-kingdom-mcp-tool-names 'king)))
  (dolist (role '(rat foreman))
    (should-not (member "config_show" (rat-kingdom-mcp-tool-names role)))
    (should-not (member "config_set" (rat-kingdom-mcp-tool-names role)))
    (should (equal (rat-kingdom-mcp-call (list :run "R-1" :role role)
                                         "config_set"
                                         '((layer . "global")
                                           (key . "attempts") (value . "2")))
                   '("Error: unknown tool config_set" . t))))
  ;; The king's instructions list them, generated from the tools.
  (should (string-search "config_show" (rat-kingdom-king-instructions)))
  (let ((schema (plist-get (cl-find "config_set"
                                    (rat-kingdom-mcp-tool-list 'king)
                                    :key (lambda (tool) (plist-get tool :name))
                                    :test #'equal)
                           :inputSchema)))
    (should (equal (plist-get schema :required) ["layer" "key" "value"]))))

(provide 'rat-kingdom-config-set-test)
;;; rat-kingdom-config-set-test.el ends here
