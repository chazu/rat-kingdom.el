;;; rat-kingdom-git-test.el --- Tests for registering repositories -*- lexical-binding: t; -*-

;;; Commentary:

;; Registering a repository makes its br workspace, kept out of Git
;; unless :track says otherwise, when it has none, and turning on `rat-kingdom-mode' does the same
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
      (should (equal (with-temp-buffer
                       (insert-file-contents
                        (expand-file-name ".beads/issues.jsonl" other))
                       (buffer-string))
                     ""))
      ;; br init never runs there, but the exclude line follows :track,
      ;; whose default keeps .beads (and .rk) out of Git.
      (should (equal (rat-kingdom-task-test--exclude other)
                     (concat exclude "/.rk/\n/.beads/\n")))
      (should (equal (rat-kingdom-task-test--status other) "")))))

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

;;;; :track

(defun rat-kingdom-git-test--exclude-lines (path)
  "Return the lines of the info/exclude of the checkout PATH that are not comments."
  (seq-remove (lambda (line) (string-prefix-p "#" line))
              (split-string (or (rat-kingdom-task-test--exclude path) "")
                            "\n" t)))

(defun rat-kingdom-git-test--global-config (text)
  "Write TEXT as the global configuration file."
  (let ((file (expand-file-name "config.eld" rat-kingdom-directory)))
    (make-directory (file-name-directory file) t)
    (with-temp-file file (insert text))
    (set-file-times file (time-subtract nil (random 1000)))))

(ert-deftest rat-kingdom-git-test-register-applies-track ()
  (rat-kingdom-story-test-with-repo (space path)
    ;; By default both are kept out: br init adds its line, then :track
    ;; the other.
    (should (equal (rat-kingdom-git-test--exclude-lines path)
                   '("/.beads/" "/.rk/")))
    ;; :track (:beads t): br init adds no line, and none is left.
    (rat-kingdom-git-test--global-config "(:track (:beads t))")
    (let* ((other (rat-kingdom-git-test--repo space "other"))
           (repo (rat-kingdom-repo-add space other)))
      (should (plist-get repo :task-initialized))
      (should-not (plist-get repo :track-warnings))
      (should (equal (rat-kingdom-git-test--exclude-lines other) '("/.rk/")))
      (should (equal (rat-kingdom-task-test--status other) "?? .beads/"))
      ;; Registered again with the line there by hand: it is taken out.
      (with-temp-buffer
        (insert-file-contents
         (expand-file-name ".git/info/exclude" other))
        (goto-char (point-max))
        (insert "/.beads/\n")
        (write-region nil nil (expand-file-name ".git/info/exclude" other)))
      (rat-kingdom-repo-add space other)
      (should (equal (rat-kingdom-git-test--exclude-lines other) '("/.rk/"))))))

(ert-deftest rat-kingdom-git-test-register-warns-of-tracked-beads ()
  (rat-kingdom-story-test-with-repo (space _path)
    (rat-kingdom-king-test--start space)
    (let* ((other (rat-kingdom-git-test--repo space "other"))
           (head nil)
           (warnings nil))
      (make-directory (expand-file-name ".beads" other))
      (with-temp-file (expand-file-name ".beads/issues.jsonl" other))
      (rat-kingdom-git other "add" ".beads")
      (rat-kingdom-git other "commit" "-q" "-m" "Track beads")
      (setq head (rat-kingdom-git other "rev-parse" "HEAD"))
      (cl-letf (((symbol-function 'display-warning)
                 (lambda (_type message &rest _) (push message warnings))))
        (let ((text (rat-kingdom-king-test--ok "repo_add" `(path . ,other))))
          (should (string-match-p
                   "Warning: Git already tracks 1 file in \\.beads of other"
                   text))))
      (should (equal (length warnings) 1))
      (should (string-match-p "other at .*warning (tell the user): Git \
already tracks 1 file in \\.beads"
                              (rat-kingdom-king-status space)))
      ;; br was not run, nothing left the index, nothing was committed.
      (should (equal (rat-kingdom-git-test--inits) '("init --prefix demo")))
      (should (equal (rat-kingdom-git other "ls-files" "--" ".beads")
                     ".beads/issues.jsonl"))
      (should (equal (rat-kingdom-git other "rev-parse" "HEAD") head))
      (should (equal (rat-kingdom-git other "diff" "--cached" "--name-only")
                     ""))
      (should (equal (rat-kingdom-git-test--exclude-lines other)
                     '("/.rk/" "/.beads/"))))))

(ert-deftest rat-kingdom-git-test-mode-applies-track ()
  (rat-kingdom-story-test-with-repo (space path)
    (let ((rat-kingdom-mode nil)
          (rat-kingdom--watch-timer nil))
      (should (equal (rat-kingdom-git-test--exclude-lines path)
                     '("/.beads/" "/.rk/")))
      (rat-kingdom-git-test--global-config "(:track (:rk t))")
      (unwind-protect
          (rat-kingdom-mode 1)
        (rat-kingdom-mode -1))
      (should (equal (rat-kingdom-git-test--exclude-lines path)
                     '("/.beads/")))
      (should (equal (rat-kingdom-task-test--status path) "")))))

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
