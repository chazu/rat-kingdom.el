;;; rat-kingdom-git-test.el --- Tests for registering repositories -*- lexical-binding: t; -*-

;;; Commentary:

;; Registering a repository makes its br workspace, kept out of Git,
;; when it has none, and turning on `rat-kingdom-mode' does the same
;; for those already registered.  The tests use real Git in disposable
;; repositories and the fake br of rat-kingdom-story-test.el.

;;; Code:

(require 'ert)
(require 'rat-kingdom)
(require 'rat-kingdom-story-test)
(require 'rat-kingdom-task-test)
(require 'rat-kingdom-king-test)

(defun rat-kingdom-git-test--repo (space name)
  "Make a repository NAME beside the one SPACE's demo is in.
Return its directory.  It is not registered."
  (let ((path (expand-file-name
               (concat "../" name "/")
               (plist-get (rat-kingdom-repo-get space "demo") :path))))
    (make-directory path)
    (rat-kingdom-task-test--checkout path)
    path))

(defun rat-kingdom-git-test--inits ()
  "Return the `br init' calls the fake br was given."
  (seq-filter (lambda (call) (string-prefix-p "init " call))
              (rat-kingdom-story-test-br-calls rat-kingdom-story-test--br)))

(ert-deftest rat-kingdom-git-test-register-creates-untracked-workspace ()
  (rat-kingdom-story-test-with-repo (space path)
    ;; The fixture registered demo, so it has its workspace already.
    (should (equal (rat-kingdom-git-test--inits) '("init --prefix demo")))
    (should (file-directory-p (expand-file-name ".beads" path)))
    (should (eql (rat-kingdom-task-test--excluded path) 1))
    (should (equal (rat-kingdom-task-test--status path) ""))
    ;; A new repository: the record says it was initialized.
    (let* ((other (rat-kingdom-git-test--repo space "other"))
           (repo (rat-kingdom-repo-add space other :task-prefix "ot")))
      (should (plist-get repo :task-initialized))
      (should (equal (plist-get repo :task-prefix) "ot"))
      (should-not (plist-get (rat-kingdom-repo-get space "other")
                             :task-initialized))
      (should (equal (plist-get (rat-kingdom-repo-get space "other")
                                :task-prefix)
                     "ot"))
      (should (equal (rat-kingdom-git-test--inits)
                     '("init --prefix demo" "init --prefix ot")))
      (should (eql (rat-kingdom-task-test--excluded other) 1))
      (should (equal (rat-kingdom-task-test--status other) ""))
      ;; Registered twice: br is not run again, the line is not added
      ;; again, and the checkout is still clean.
      (let ((again (rat-kingdom-repo-add space other :check '("true"))))
        (should-not (plist-get again :task-initialized))
        (should (equal (plist-get again :check) '("true"))))
      (rat-kingdom-repo-add space path)
      (should (eql (length (rat-kingdom-git-test--inits)) 2))
      (should (eql (rat-kingdom-task-test--excluded other) 1))
      (should (eql (rat-kingdom-task-test--excluded path) 1))
      (should (equal (rat-kingdom-task-test--status other) ""))
      (should (equal (rat-kingdom-task-test--status path) "")))))

(ert-deftest rat-kingdom-git-test-register-linked-worktree ()
  (rat-kingdom-story-test-with-repo (space path)
    (let ((main (rat-kingdom-git-test--repo space "main"))
          (linked nil))
      (setq linked (expand-file-name "../linked/" main))
      (rat-kingdom-git main "worktree" "add" "-q" "-b" "side" linked)
      (should (plist-get (rat-kingdom-repo-add space linked) :task-initialized))
      (should (file-directory-p (expand-file-name ".beads" linked)))
      (should (eql (rat-kingdom-task-test--excluded main) 1))
      (should-not (file-exists-p
                   (expand-file-name ".git/worktrees/linked/info/exclude" main)))
      (should (equal (rat-kingdom-task-test--status linked) ""))
      (should (equal (rat-kingdom-task-test--status main) ""))
      (ignore path))))

(ert-deftest rat-kingdom-git-test-register-keeps-existing-workspace ()
  (rat-kingdom-story-test-with-repo (space _path)
    (let* ((other (rat-kingdom-git-test--repo space "other"))
           (exclude (rat-kingdom-task-test--exclude other)))
      (make-directory (expand-file-name ".beads" other))
      (with-temp-file (expand-file-name ".beads/issues.jsonl" other))
      (should-not (plist-get (rat-kingdom-repo-add space other)
                             :task-initialized))
      (should (equal (rat-kingdom-git-test--inits) '("init --prefix demo")))
      (should (equal (rat-kingdom-task-test--exclude other) exclude))
      (should (equal (rat-kingdom-task-test--status other) "?? .beads/")))))

(ert-deftest rat-kingdom-git-test-register-fails-cleanly ()
  (rat-kingdom-story-test-with-repo (space _path)
    (let ((other (rat-kingdom-git-test--repo space "other")))
      ;; Without br, nothing is registered and nothing is made.
      (let* ((rat-kingdom-task-br-program "rat-kingdom-no-such-br")
             (err (should-error (rat-kingdom-repo-add space other)
                                :type 'rat-kingdom-task-error)))
        (should (string-match-p "requires br" (cadr err))))
      (should-not (rat-kingdom-repo-get space "other"))
      (should-not (rat-kingdom-git-ok-p other "rev-parse" "--verify" "--quiet"
                                        "refs/heads/rk/integration"))
      (should-not (file-exists-p (expand-file-name ".beads" other)))
      (should (eql (rat-kingdom-task-test--excluded other) 0))
      ;; A prefix br does not keep is an error, and leaves nothing.
      (with-temp-file (expand-file-name "force-prefix"
                                        rat-kingdom-story-test--br)
        (insert "bd"))
      (let ((err (should-error (rat-kingdom-repo-add space other)
                               :type 'rat-kingdom-task-error)))
        (should (string-match-p "left the prefix \"bd\"" (cadr err))))
      (should-not (rat-kingdom-repo-get space "other"))
      (should-not (file-exists-p (expand-file-name ".beads" other)))
      (should (eql (rat-kingdom-task-test--excluded other) 0))
      (should (equal (rat-kingdom-task-test--status other) ""))
      (should (eql (length (rat-kingdom-repo-list space)) 1)))))

(ert-deftest rat-kingdom-git-test-register-tracked-when-asked ()
  (rat-kingdom-story-test-with-repo (space _path)
    (let ((other (rat-kingdom-git-test--repo space "other"))
          (rat-kingdom-task-br-untracked nil))
      (should (plist-get (rat-kingdom-repo-add space other) :task-initialized))
      (should (eql (rat-kingdom-task-test--excluded other) 0))
      (should (equal (rat-kingdom-task-test--status other) "?? .beads/")))))

(ert-deftest rat-kingdom-git-test-repo-add-tool-reports-init ()
  (rat-kingdom-story-test-with-repo (space _path)
    (rat-kingdom-king-test--start space)
    (let ((other (rat-kingdom-git-test--repo space "other")))
      (let ((text (rat-kingdom-king-test--ok
                   "repo_add" `(path . ,other) '(task_prefix . "ot"))))
        (should (string-search "Initialized a br workspace there with the \
prefix ot, kept out of Git." text)))
      (should (equal (rat-kingdom-git-test--inits)
                     '("init --prefix demo" "init --prefix ot")))
      ;; Again: nothing to initialize, so it is not mentioned.
      (should-not (string-search "br workspace"
                                 (rat-kingdom-king-test--ok
                                  "repo_add" `(path . ,other))))
      ;; Without br the tool fails and registers nothing.
      (let* ((third (rat-kingdom-git-test--repo space "third"))
             (rat-kingdom-task-br-program "rat-kingdom-no-such-br")
             (answer (rat-kingdom-king-test--call "repo_add" `(path . ,third))))
        (should (cdr answer))
        (should (string-search "requires br" (car answer)))
        (should-not (rat-kingdom-repo-get space "third"))))))

(ert-deftest rat-kingdom-git-test-mode-ensures-registered-repos ()
  (rat-kingdom-story-test-with-repo (space path)
    (let* ((good (rat-kingdom-git-test--repo space "good"))
           (bad (rat-kingdom-git-test--repo space "bad"))
           (rat-kingdom-mode nil)
           (rat-kingdom--watch-timer nil)
           (warnings nil))
      (rat-kingdom-repo-add space bad)
      (rat-kingdom-repo-add space good)
      ;; The failing one is ensured before the good one.
      (should (equal (mapcar (lambda (repo) (plist-get repo :name))
                             (rat-kingdom-repo-list space))
                     '("demo" "bad" "good")))
      ;; Registered before br was required: no workspaces.
      (dolist (checkout (list path good bad))
        (delete-directory (expand-file-name ".beads" checkout) t))
      ;; One of them can no longer be ensured.
      (delete-directory bad t)
      (cl-letf (((symbol-function 'display-warning)
                 (lambda (_type message &rest _)
                   (push message warnings))))
        (unwind-protect
            (rat-kingdom-mode 1)
          (rat-kingdom-mode -1)))
      ;; The others got theirs, untracked, and the failure was reported.
      (should (file-directory-p (expand-file-name ".beads" path)))
      (should (file-directory-p (expand-file-name ".beads" good)))
      (should (equal (rat-kingdom-task-test--status path) ""))
      (should (equal (rat-kingdom-task-test--status good) ""))
      (should (eql (rat-kingdom-task-test--excluded good) 1))
      (should (equal (length warnings) 1))
      (should (string-match-p "The repository bad has no br workspace"
                              (car warnings)))
      (should (rat-kingdom-task-workspace-error "bad"))
      (should-not (rat-kingdom-task-workspace-error "good"))
      (should (string-search "- bad at " (rat-kingdom-king-status space)))
      (should (string-match-p "bad at .*no br workspace, so no tasks"
                              (rat-kingdom-king-status space)))
      ;; Refreshing the tasks ensures them too.
      (delete-directory (expand-file-name ".beads" good) t)
      (rat-kingdom-tasks-refresh)
      (should (file-directory-p (expand-file-name ".beads" good)))
      (should (eql (rat-kingdom-task-test--excluded good) 1)))))

(provide 'rat-kingdom-git-test)
;;; rat-kingdom-git-test.el ends here
