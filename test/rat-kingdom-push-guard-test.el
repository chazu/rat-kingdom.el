;;; rat-kingdom-push-guard-test.el --- Tests for guarding the user's own pushes -*- lexical-binding: t; -*-

;;; Commentary:

;; Batch tests for the fourth push layer (DESIGN.md, section 12): the
;; branches rat-kingdom makes have a pushRemote Git cannot use, so a
;; `git push' that names no remote on them fails, while `publish',
;; which names its remote, still pushes.  Pushes go to a disposable
;; bare repository in a temporary directory, with a real Git.

;;; Code:

(require 'ert)
(require 'rat-kingdom-test-helper)
(require 'rat-kingdom)
(require 'rat-kingdom-push-test)
(require 'rat-kingdom-config-set-test)

(defmacro rat-kingdom-push-guard-test-with-remote (vars &rest body)
  "Run BODY as `rat-kingdom-push-test-with-remote' does, with VARS.
Git runs without the GIT_CONFIG_ variables of an agent's session, so
that only the repository's own configuration can refuse a push."
  (declare (indent 1) (debug t))
  `(let ((process-environment (rat-kingdom-push-test--without-git-config
                               process-environment)))
     (cl-letf (((symbol-function 'display-warning) #'ignore))
       (rat-kingdom-push-test-with-remote ,vars ,@body))))

(defun rat-kingdom-push-guard-test--push (directory &rest options)
  "Run `git push', naming no remote, in DIRECTORY with the -c OPTIONS.
Return (EXIT OUTPUT ERRORS)."
  (rat-kingdom-git--run
   directory (append (mapcan (lambda (option) (list "-c" option)) options)
                     '("push"))))

(defun rat-kingdom-push-guard-test--refused (directory remote branch)
  "Check that `git push' of BRANCH, checked out in DIRECTORY, is refused.
It must fail, naming rat-kingdom, whatever push.default says, and
leave REMOTE, a bare repository, without BRANCH."
  (dolist (default '("simple" "current" "matching" "upstream"))
    (pcase-let ((`(,exit ,_ ,errors)
                 (rat-kingdom-push-guard-test--push
                  directory (concat "push.default=" default))))
      (should-not (eql exit 0))
      (should (string-search "rat-kingdom-refuses-to-push" errors))))
  (should-not (rat-kingdom-push-test--remote-commit remote branch)))

(defun rat-kingdom-push-guard-test--config (path)
  "Return the bytes of the Git configuration of the checkout PATH."
  (rat-kingdom-config-set-test--bytes
   (expand-file-name "config" (rat-kingdom-git path "rev-parse"
                                               "--absolute-git-dir"))))

(ert-deftest rat-kingdom-push-guard-test-guard ()
  (rat-kingdom-push-guard-test-with-remote (_space path _remote)
    (rat-kingdom-git path "branch" "spare")
    (let ((before (rat-kingdom-push-guard-test--config path)))
      (should-not (rat-kingdom-git-push-guarded-p path "spare"))
      (should (rat-kingdom-git-push-guard path "spare"))
      ;; Idempotent.
      (should-not (rat-kingdom-git-push-guard path "spare"))
      (should (rat-kingdom-git-push-guarded-p path "spare"))
      (should (equal (rat-kingdom-git path "config" "--local" "--get"
                                      "branch.spare.pushRemote")
                     "rat-kingdom-refuses-to-push::spare"))
      (should (member "spare" (rat-kingdom-git-push-guarded-branches path)))
      (should (rat-kingdom-git-push-unguard path "spare"))
      (should-not (rat-kingdom-git-push-unguard path "spare"))
      (should-not (rat-kingdom-git-push-guarded-p path "spare"))
      ;; Nothing else in the configuration changed.
      (should (equal (rat-kingdom-push-guard-test--config path) before))
      ;; A pushRemote of the user's own is not the guard, and stays.
      (rat-kingdom-git path "config" "branch.spare.pushRemote" "origin")
      (should-not (rat-kingdom-git-push-unguard path "spare"))
      (should (equal (rat-kingdom-git path "config" "--get"
                                      "branch.spare.pushRemote")
                     "origin"))
      (should-not (member "spare"
                          (rat-kingdom-git-push-guarded-branches path))))))

(ert-deftest rat-kingdom-push-guard-test-pushes ()
  (rat-kingdom-push-guard-test-with-remote (space path remote)
    ;; The user has a branch of their own, with a setting of its own.
    (rat-kingdom-git path "branch" "feature")
    (rat-kingdom-git path "config" "branch.feature.description" "Mine")
    (progn
      ;; repo_add guarded the target.
      (should (rat-kingdom-git-push-guarded-p path "rk/integration"))
      ;; A story's branch is guarded when it is cut.
      (rat-kingdom-story-start space "demo" "Task" nil "S-1")
      (rat-kingdom-reaction-run space)
      (let ((worktree (rat-kingdom-story-test--get space "S-1" :worktree))
            (branch (rat-kingdom-story-test--get space "S-1" :branch)))
        (should (equal branch "rats/S-1"))
        (should (rat-kingdom-git-push-guarded-p path branch))
        (rat-kingdom-story-test--commit worktree "work" "work\n" "Work")
        (rat-kingdom-push-guard-test--refused worktree remote branch)
        ;; The target, checked out by the user, is refused too.
        (rat-kingdom-git path "checkout" "-q" "rk/integration")
        (rat-kingdom-push-guard-test--refused path remote "rk/integration")
        (rat-kingdom-git path "checkout" "-q" "main")
        ;; A push that names the remote goes through: that is publish.
        (let ((receipt (rat-kingdom-git-publish space "demo" "rk/integration")))
          (should (equal (rat-kingdom-push-test--remote-commit
                          remote "rk/integration")
                         (plist-get (plist-get receipt :payload) :new))))
        (rat-kingdom-git-publish space "demo" branch)
        (should (equal (rat-kingdom-push-test--remote-commit remote branch)
                       (rat-kingdom-git-rev path branch)))
        ;; The user's branches push as before.
        (rat-kingdom-git path "checkout" "-q" "feature")
        (rat-kingdom-story-test--commit path "mine" "mine\n" "Mine")
        (should (eql (car (rat-kingdom-push-guard-test--push
                           path "push.default=current"))
                     0))
        (should (equal (rat-kingdom-push-test--remote-commit remote "feature")
                       (rat-kingdom-git-rev path "feature")))
        (rat-kingdom-git path "checkout" "-q" "main")
        (should-not (rat-kingdom-git-push-guarded-p path "main"))
        (should-not (rat-kingdom-git-push-guarded-p path "feature"))
        (should (equal (rat-kingdom-git path "config" "--local"
                                        "--get-regexp" "^branch\\.feature\\.")
                       "branch.feature.description Mine"))
        (should-not (rat-kingdom-git-ok-p path "config" "--local" "--get-regexp"
                                          "^branch\\.main\\."))
        (should (equal (sort (rat-kingdom-git-push-guarded-branches path)
                             #'string<)
                       (list branch "rk/integration")))))))

(ert-deftest rat-kingdom-push-guard-test-configuration ()
  (rat-kingdom-push-guard-test-with-remote (space path _remote)
    (rat-kingdom-git path "branch" "feature")
    (rat-kingdom-git path "branch" "rats/S-old")
    ;; The default is t, and config_show says where it came from.
    (should (rat-kingdom-config-push-guard-p space "demo"))
    (should (string-search "- :git :push-guard t (defaults)"
                           (rat-kingdom-config-show space "demo")))
    ;; It may be set at the global and repo layers only.
    (should-error (rat-kingdom-config-set space 'repo :git '(:push-guard maybe)
                                          :repo "demo"))
    (should-error (rat-kingdom-config-set space 'epic :git '(:push-guard nil)
                                          :repo "demo" :epic "E-1"))
    (should-error (rat-kingdom-repo-add space path :git '(:push-guard nil)))
    ;; Applying it guards the rats/* branches there are already.
    (should (equal (rat-kingdom-config-push-guard-apply space "demo")
                   '(:guarded ("rats/S-old") :unguarded nil)))
    ;; nil takes the guard off the target and the rats/* branches.
    (should (rat-kingdom-git-push-guarded-p path "rk/integration"))
    (should (rat-kingdom-git-push-guarded-p path "rats/S-old"))
    (let ((answer (rat-kingdom-config-set space 'repo :git '(:push-guard nil)
                                          :repo "demo")))
      (should (string-search "Applied :git :push-guard to demo: took the \
guard off" answer)))
    (should (string-search "- :git :push-guard nil (repo)"
                           (rat-kingdom-config-show space "demo")))
    (should-not (rat-kingdom-git-push-guarded-branches path))
    ;; Then a story's branch is not guarded.
    (rat-kingdom-story-start space "demo" "Task" nil "S-1")
    (rat-kingdom-reaction-run space)
    (should-not (rat-kingdom-git-push-guarded-p path "rats/S-1"))
    ;; t puts it back, on the branches rat-kingdom made and no other.
    (let ((answer (rat-kingdom-config-set space 'global :git '(:push-guard t))))
      ;; The repo layer still says nil.
      (should (string-search "its branches already were so" answer)))
    (should-not (rat-kingdom-git-push-guarded-branches path))
    (rat-kingdom-config-set space 'repo :git nil :repo "demo")
    (should (equal (sort (rat-kingdom-git-push-guarded-branches path)
                         #'string<)
                   '("rats/S-1" "rats/S-old" "rk/integration")))
    (should-not (rat-kingdom-git-push-guarded-p path "feature"))
    (should-not (rat-kingdom-git-push-guarded-p path "main"))
    ;; Turning the mode on applies it to every repository.
    (rat-kingdom-git-push-unguard path "rats/S-old")
    (should (equal (rat-kingdom-config-push-guard-apply-all space)
                   '(("demo" :guarded ("rats/S-old") :unguarded nil))))))

(ert-deftest rat-kingdom-push-guard-test-sync ()
  (rat-kingdom-push-guard-test-with-remote (space path _remote)
    (rat-kingdom-git-push-unguard path "rk/integration")
    (rat-kingdom-story-test--commit path "more" "more\n" "More")
    (should (string-search "Moved rk/integration forward"
                           (rat-kingdom-story-sync space "demo")))
    (should (rat-kingdom-git-push-guarded-p path "rk/integration"))))

(ert-deftest rat-kingdom-push-guard-test-existing-target ()
  ;; A target the user made before registering is guarded too.
  (rat-kingdom-push-guard-test-with-remote (space path _remote)
    (rat-kingdom-git path "branch" "staging")
    (rat-kingdom-repo-add space path :name "other" :target "staging")
    (should (rat-kingdom-git-push-guarded-p path "staging"))))

(ert-deftest rat-kingdom-push-guard-test-documented ()
  (cl-flet ((flat (text) (replace-regexp-in-string "[ \n]+" " " text)))
    (let ((description (flat (plist-get (cl-find "config_set"
                                                 rat-kingdom-mcp--tools
                                                 :key (lambda (tool)
                                                        (plist-get tool :name))
                                                 :test #'equal)
                                        :description))))
      (should (string-search "push-guard" description)))))

(provide 'rat-kingdom-push-guard-test)
;;; rat-kingdom-push-guard-test.el ends here
