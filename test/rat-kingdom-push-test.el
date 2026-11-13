;;; rat-kingdom-push-test.el --- Tests for the push guards and publish -*- lexical-binding: t; -*-

;;; Commentary:

;; Batch tests for keeping agents from pushing, and for the one push
;; there is, `publish'.  No agent is started and nothing leaves the
;; machine: pushes go to disposable bare repositories in a temporary
;; directory.

;;; Code:

(require 'ert)
(require 'rat-kingdom-agent-shell)
(require 'rat-kingdom-king)
(require 'rat-kingdom-story-test)
(require 'rat-kingdom-king-test)

;;;; The environment

(defun rat-kingdom-push-test--pairs (environment)
  "Return the Git configuration ENVIRONMENT gives, as (KEY . VALUE)."
  (let ((count (string-to-number (getenv-internal "GIT_CONFIG_COUNT"
                                                  environment))))
    (cl-loop for i below count
             collect (cons (getenv-internal (format "GIT_CONFIG_KEY_%d" i)
                                            environment)
                           (getenv-internal (format "GIT_CONFIG_VALUE_%d" i)
                                            environment)))))

(ert-deftest rat-kingdom-push-test-environment ()
  (let* ((environment (rat-kingdom-agent-shell-environment
                       "S-1" '("PATH=/bin" "HOME=/home/someone")))
         (pairs (rat-kingdom-push-test--pairs environment)))
    (should (equal (getenv-internal "RAT_KINGDOM_RUN" environment) "S-1"))
    (should (equal (getenv-internal "GH_PROMPT_DISABLED" environment) "1"))
    (should (equal (getenv-internal "PATH" environment) "/bin"))
    (should (= (length pairs)
               (length rat-kingdom-agent-shell-push-prefixes)))
    (dolist (prefix '("https://" "http://" "ssh://" "git@" "git://"
                      "file://" "/" ""))
      (should (member (cons (format "url.rat-kingdom-refuses-to-push::%s.pushInsteadOf"
                                    prefix)
                            prefix)
                      pairs)))))

(ert-deftest rat-kingdom-push-test-environment-keeps-existing-config ()
  (let* ((given '("GIT_CONFIG_COUNT=2"
                  "GIT_CONFIG_KEY_0=user.name" "GIT_CONFIG_VALUE_0=Someone"
                  "GIT_CONFIG_KEY_1=core.editor" "GIT_CONFIG_VALUE_1=true"))
         (environment (rat-kingdom-agent-shell-environment "king" given))
         (pairs (rat-kingdom-push-test--pairs environment)))
    (should (= (length pairs)
               (+ 2 (length rat-kingdom-agent-shell-push-prefixes))))
    (should (equal (nth 0 pairs) '("user.name" . "Someone")))
    (should (equal (nth 1 pairs) '("core.editor" . "true")))
    (should (string-prefix-p "url.rat-kingdom-refuses-to-push::"
                             (car (nth 2 pairs))))
    ;; The entries are only added, so the given ones are all still there.
    (should (equal (last environment (length given)) given))
    ;; A count that is not a number is not built on.
    (should (equal (getenv-internal
                    "GIT_CONFIG_KEY_0"
                    (rat-kingdom-agent-shell-environment
                     "king" '("GIT_CONFIG_COUNT=lots")))
                   (format "url.%s%s.pushInsteadOf"
                           rat-kingdom-agent-shell-push-block
                           (car rat-kingdom-agent-shell-push-prefixes))))))

(ert-deftest rat-kingdom-push-test-session-meta ()
  (let* ((given '((claudeCode
                   . ((options . ((thinking . ((type . "adaptive")))))))))
         (meta (rat-kingdom-agent-shell--session-meta given))
         (options (alist-get 'options (alist-get 'claudeCode meta))))
    (should (equal (alist-get 'thinking options) '((type . "adaptive"))))
    (should (vectorp (alist-get 'disallowedTools options)))
    (should (seq-contains-p (alist-get 'disallowedTools options)
                            "Bash(git push:*)"))
    (should (seq-contains-p (alist-get 'disallowedTools options) "Bash(gh:*)"))
    ;; The config's own meta is left alone.
    (should-not (alist-get 'disallowedTools
                           (alist-get 'options (alist-get 'claudeCode given))))
    ;; It serializes as the adapter expects.
    (should (string-search "\"disallowedTools\":[\"Bash(git push:*)\""
                           (json-serialize meta)))))

(ert-deftest rat-kingdom-push-test-guarded-client ()
  (let* ((config (list (cons :buffer-name "x")
                       (cons :client-maker
                             (lambda (_buffer)
                               (list (cons :command "agent")
                                     (cons :environment-variables
                                           '("ANTHROPIC_API_KEY=k")))))
                       (cons :session-meta nil)))
         (guarded (rat-kingdom-agent-shell--guard config "S-2"))
         (client (funcall (map-elt guarded :client-maker) nil))
         (variables (map-elt client :environment-variables)))
    (should (equal (map-elt guarded :buffer-name) "x"))
    (should (= (length (seq-filter (lambda (entry) (eq (car entry) :client-maker))
                                   guarded))
               1))
    (should (equal (getenv-internal "RAT_KINGDOM_RUN" variables) "S-2"))
    (should (equal (getenv-internal "ANTHROPIC_API_KEY" variables) "k"))
    (should (getenv-internal "GIT_CONFIG_COUNT" variables))))

;;;; A real push, with and without the environment

(defmacro rat-kingdom-push-test-with-remote (vars &rest body)
  "Run BODY with a repository that has a bare remote.
VARS is (SPACE PATH REMOTE): the space, the repository's directory,
registered as \"demo\", and the bare remote's directory, which is the
repository's remote origin."
  (declare (indent 1) (debug t))
  `(rat-kingdom-story-test-with-repo (,(nth 0 vars) ,(nth 1 vars))
     (let ((,(nth 2 vars) (expand-file-name "../remote.git" ,(nth 1 vars))))
       (rat-kingdom-git ,(nth 1 vars) "init" "-q" "--bare" ,(nth 2 vars))
       (rat-kingdom-git ,(nth 1 vars) "remote" "add" "origin" ,(nth 2 vars))
       ,@body)))

(defun rat-kingdom-push-test--remote-commit (remote branch)
  "Return the commit BRANCH is at in the bare repository REMOTE, or nil."
  (and (rat-kingdom-git-ok-p remote "rev-parse" "--verify" "--quiet"
                             (concat "refs/heads/" branch))
       (rat-kingdom-git-rev remote (concat "refs/heads/" branch))))

(ert-deftest rat-kingdom-push-test-environment-blocks-push ()
  (rat-kingdom-push-test-with-remote (_space path remote)
    (let ((head (rat-kingdom-git-rev path "HEAD"))
          (relative (file-relative-name remote path)))
      ;; In a session's environment every form of push fails, and says why.
      (let ((process-environment (rat-kingdom-agent-shell-environment
                                  "S-1" process-environment)))
        (dolist (args `(("push" "origin" "main")
                        ("push" "--no-verify" "origin" "main")
                        ("push" ,remote "main")
                        ("push" ,relative "main")
                        ("push" ,(concat "file://" remote) "main")
                        ("-C" ,path "push" "origin" "main")))
          (pcase-let ((`(,exit ,_ ,errors) (rat-kingdom-git--run path args)))
            (should-not (eql exit 0))
            (should (string-search "rat-kingdom-refuses-to-push" errors))))
        (should-not (rat-kingdom-push-test--remote-commit remote "main"))
        ;; Fetching still works.
        (should (rat-kingdom-git-ok-p path "fetch" "origin")))
      ;; Outside it, the same push goes through.
      (should (rat-kingdom-git-ok-p path "push" "--no-verify" "origin" "main"))
      (should (equal (rat-kingdom-push-test--remote-commit remote "main") head))
      ;; The repository's configuration was not touched.
      (should-not (rat-kingdom-git-ok-p path "config" "--get-regexp"
                                        "pushinsteadof")))))

;;;; Refusing permission

(ert-deftest rat-kingdom-push-test-publishing-commands ()
  (dolist (command '("git push"
                     "git push origin main"
                     "git -C x push origin main"
                     "git -c user.name=x --no-pager push"
                     "cd x && git push"
                     "cd x; git push --no-verify"
                     "/usr/bin/git push"
                     "GIT_CONFIG_COUNT=0 git push"
                     "env -u GIT_CONFIG_COUNT git push"
                     "echo main | xargs git push origin"
                     "echo \"$(git push)\""
                     "bash -c 'git push origin main'"
                     "sh -lc \"cd x && git push\""
                     "git send-pack ../r main"
                     "gh pr create --fill"
                     "cd x && gh pr create"
                     "GH_TOKEN=t gh api repos"
                     "timeout 10 gh pr list"))
    (should (rat-kingdom-agent-shell-publishing-command-p command)))
  (dolist (command '("git status"
                     "git commit -m 'Explain how to push'"
                     "git commit -m \"git push is blocked\""
                     "git log --grep push"
                     "git -C x status"
                     "grep -rn 'git push' ."
                     "rg \"gh pr\" README.md"
                     "ls ~/.config/gh"
                     "cd x && git add -A && git commit -m done"
                     "eldev test"))
    (should-not (rat-kingdom-agent-shell-publishing-command-p command))))

(defun rat-kingdom-push-test--permission (command &optional title)
  "Return a permission request to run COMMAND, and the list it answers into.
TITLE is the tool call's title; without it, the request has COMMAND as
raw input."
  (let ((answers (list nil)))
    (list (list (cons :tool-call
                      (append (list (cons :title (or title command))
                                    (cons :kind "execute"))
                              (unless title
                                (list (cons :raw-input
                                            `((command . ,command)))))))
                (cons :options
                      (list (list (cons :kind "allow_always")
                                  (cons :option-id "always"))
                            (list (cons :kind "allow_once")
                                  (cons :option-id "once"))
                            (list (cons :kind "reject_once")
                                  (cons :option-id "reject"))))
                (cons :respond (lambda (id) (push id (car answers)) t)))
          answers)))

(ert-deftest rat-kingdom-push-test-refuses-permission ()
  (let* ((asked nil)
         (previous (lambda (permission)
                     (push permission asked)
                     (funcall (map-elt permission :respond) "always")
                     t)))
    ;; A push is refused, and the previous responder never sees it.
    (pcase-let ((`(,permission ,answers)
                 (rat-kingdom-push-test--permission "cd x && git push")))
      (should (rat-kingdom-agent-shell--respond permission previous))
      (should (equal (car answers) '("reject")))
      (should-not asked))
    ;; Known only by its title, too.
    (pcase-let ((`(,permission ,answers)
                 (rat-kingdom-push-test--permission nil "`gh pr create`")))
      (should (rat-kingdom-agent-shell--respond permission previous))
      (should (equal (car answers) '("reject")))
      (should-not asked))
    ;; Anything else goes to the previous responder.
    (pcase-let ((`(,permission ,answers)
                 (rat-kingdom-push-test--permission "git status")))
      (should (rat-kingdom-agent-shell--respond permission previous))
      (should (equal (car answers) '("always")))
      (should (= (length asked) 1)))
    ;; A push that cannot be refused goes to the user, not to the
    ;; previous responder.
    (pcase-let ((`(,permission ,answers)
                 (rat-kingdom-push-test--permission "git push")))
      (setf (map-elt permission :options)
            (seq-remove (lambda (option)
                          (equal (map-elt option :kind) "reject_once"))
                        (map-elt permission :options)))
      (should-not (rat-kingdom-agent-shell--respond permission previous))
      (should-not (car answers))
      (should (= (length asked) 1)))))

;;;; Publishing

(ert-deftest rat-kingdom-push-test-publish ()
  (rat-kingdom-push-test-with-remote (space path remote)
    (let ((first (rat-kingdom-git-rev path "main")))
      ;; A new branch on the remote.
      (let* ((receipt (rat-kingdom-git-publish space "demo" "main"))
             (payload (plist-get receipt :payload)))
        (should (equal (rat-kingdom-push-test--remote-commit remote "main") first))
        (should (eq (plist-get receipt :category) 'published))
        (should (eq (plist-get receipt :modality) 'persistent))
        (should (equal (plist-get receipt :scope) "demo"))
        (should (equal (plist-get payload :branch) "main"))
        (should (equal (plist-get payload :remote) "origin"))
        (should (equal (plist-get payload :url) remote))
        (should-not (plist-get payload :old))
        (should (equal (plist-get payload :new) first))
        (should (equal (plist-get payload :actor) "user"))
        (should (plist-get payload :time))
        (should (string-search "new branch"
                               (rat-kingdom-git-publish-describe receipt))))
      ;; A fast-forward, by the king's tool.
      (rat-kingdom-story-test--commit path "a" "a\n" "Second")
      (let ((second (rat-kingdom-git-rev path "main")))
        (rat-kingdom-king-test--start space)
        (should (string-search
                 (format "%s..%s" (substring first 0 12) (substring second 0 12))
                 (rat-kingdom-king-test--ok "publish" '(repo . "demo")
                                            '(branch . "main"))))
        (should (equal (rat-kingdom-push-test--remote-commit remote "main")
                       second))
        (let ((receipt (car (last (rat-kingdom-space-scan
                                   space '(published :scope "demo"))))))
          (should (equal (plist-get (plist-get receipt :payload) :old) first))
          (should (equal (plist-get (plist-get receipt :payload) :new) second))
          (should (equal (plist-get (plist-get receipt :payload) :actor)
                         "king")))
        (should (= (length (rat-kingdom-space-scan space '(published))) 2))
        ;; Unknown repositories, branches and remotes are refused.
        (should (cdr (rat-kingdom-king-test--call "publish" '(repo . "nope")
                                                  '(branch . "main"))))
        (should-error (rat-kingdom-git-publish space "demo" "no-such-branch"))
        (should-error (rat-kingdom-git-publish space "demo" "main"
                                               :remote "elsewhere"))
        (should-error (rat-kingdom-git-publish space "demo" "main"
                                               :remote "--force"))
        (should-error (rat-kingdom-git-publish space "demo" "+main"))
        (should (= (length (rat-kingdom-space-scan space '(published))) 2))
        ;; The local branch is rewritten: the push is not a fast-forward,
        ;; and is refused, not forced.
        (rat-kingdom-git path "reset" "-q" "--hard" first)
        (rat-kingdom-story-test--commit path "b" "b\n" "Diverged")
        (let ((answer (rat-kingdom-king-test--call "publish" '(repo . "demo")
                                                   '(branch . "main"))))
          (should (cdr answer))
          (should (string-match-p "rejected\\|non-fast-forward\\|fetch first"
                                  (car answer))))
        (should (equal (rat-kingdom-push-test--remote-commit remote "main")
                       second))
        (should (= (length (rat-kingdom-space-scan space '(published))) 2))))))

(ert-deftest rat-kingdom-push-test-king-is-told-when-to-push ()
  (cl-flet ((flat (text) (replace-regexp-in-string "[ \n]+" " " text)))
    (let ((king (flat rat-kingdom-king-instructions)))
      (should (string-search "explicitly asked, in this conversation" king))
      (should (string-search "does not carry over to the next" king))
      (should (string-search "Never push with git or gh" king)))
    (should (string-search "Pushing is blocked"
                           (flat rat-kingdom-run-rat-instructions)))
    (should (string-search "explicitly asked"
                           (plist-get (cl-find "publish" rat-kingdom-mcp--tools
                                               :key (lambda (tool)
                                                      (plist-get tool :name))
                                               :test #'equal)
                                      :description)))))

(provide 'rat-kingdom-push-test)
;;; rat-kingdom-push-test.el ends here
