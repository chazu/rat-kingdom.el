;;; rat-kingdom-agent-shell-test.el --- Tests for the agent-shell backend -*- lexical-binding: t; -*-

;;; Commentary:

;; Batch tests for the part of the agent-shell backend that needs no
;; agent: finding a session's Claude Code transcript and giving it to
;; the session-end command when the agent is stopped.  Transcripts are
;; files in a temporary CLAUDE_CONFIG_DIR, and the command is a stub, so
;; nothing is started.  The push guards are tested in
;; rat-kingdom-push-test.el.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'rat-kingdom-agent-shell)

;;;; The slug

(ert-deftest rat-kingdom-agent-shell-test-slug ()
  (should (equal (rat-kingdom-agent-shell-project-slug
                  "/Users/chaz/.emacs.d/rat-kingdom/worktrees/cli/S-b93a")
                 "-Users-chaz--emacs-d-rat-kingdom-worktrees-cli-S-b93a"))
  (should (equal (rat-kingdom-agent-shell-project-slug
                  "/Users/chaz/.emacs.d/rat-kingdom/worktrees/cli/S-b93a/")
                 "-Users-chaz--emacs-d-rat-kingdom-worktrees-cli-S-b93a"))
  (should (equal (rat-kingdom-agent-shell-project-slug "/tmp/my_app/v1.2")
                 "-tmp-my-app-v1-2")))

;;;; The transcript

(defmacro rat-kingdom-agent-shell-test-with-session (vars &rest body)
  "Run BODY with a fake agent buffer and a Claude Code configuration dir.
VARS is (BUFFER PROJECT): the buffer, whose directory is a fresh
worktree, and the transcript directory of that worktree's slug, not
yet made.  CLAUDE_CONFIG_DIR is set for BODY."
  (declare (indent 1) (debug t))
  (let ((root (make-symbol "root")))
    `(let* ((,root (file-name-as-directory
                    (file-truename (make-temp-file "rat-kingdom-agent-shell" t))))
            (process-environment
             (cons (concat "CLAUDE_CONFIG_DIR=" ,root "claude")
                   process-environment))
            (,(nth 0 vars) (generate-new-buffer " rat-kingdom-agent-shell-test"))
            (,(nth 1 vars) (expand-file-name
                            (rat-kingdom-agent-shell-project-slug
                             (concat ,root "worktree"))
                            (concat ,root "claude/projects"))))
       (make-directory (concat ,root "worktree"))
       (with-current-buffer ,(nth 0 vars)
         (setq default-directory (concat ,root "worktree/")))
       (unwind-protect
           (progn ,@body)
         (when (buffer-live-p ,(nth 0 vars))
           (kill-buffer ,(nth 0 vars)))
         (delete-directory ,root t)))))

(defun rat-kingdom-agent-shell-test--transcript (project name &optional age)
  "Write the transcript NAME in the directory PROJECT, AGE seconds old."
  (make-directory project t)
  (let ((file (expand-file-name (concat name ".jsonl") project)))
    (with-temp-file file (insert "{}\n"))
    (set-file-times file (time-subtract nil (or age 0)))
    file))

(defun rat-kingdom-agent-shell-test--set-session (buffer id)
  "Give BUFFER an agent-shell state whose session is ID."
  (with-current-buffer buffer
    (setq-local agent-shell--state `((:session . ((:id . ,id)))))))

(ert-deftest rat-kingdom-agent-shell-test-transcript-by-session-id ()
  (rat-kingdom-agent-shell-test-with-session (buffer project)
    (rat-kingdom-agent-shell-test--transcript project "other")
    (let ((mine (rat-kingdom-agent-shell-test--transcript project "abc-123" 60)))
      (rat-kingdom-agent-shell-test--set-session buffer "abc-123")
      (should (equal (rat-kingdom-agent-shell-transcript buffer) mine)))))

(ert-deftest rat-kingdom-agent-shell-test-transcript-newest-without-id ()
  (rat-kingdom-agent-shell-test-with-session (buffer project)
    (rat-kingdom-agent-shell-test--transcript project "old" 120)
    (let ((newest (rat-kingdom-agent-shell-test--transcript project "new" 0)))
      (rat-kingdom-agent-shell-test--transcript project "older" 240)
      (should (equal (rat-kingdom-agent-shell-transcript buffer) newest))
      ;; An id with no file of its own falls back the same way.
      (rat-kingdom-agent-shell-test--set-session buffer "gone")
      (should (equal (rat-kingdom-agent-shell-transcript buffer) newest)))))

(ert-deftest rat-kingdom-agent-shell-test-transcript-missing ()
  (rat-kingdom-agent-shell-test-with-session (buffer project)
    (should-not (file-exists-p project))
    (should-not (rat-kingdom-agent-shell-transcript buffer))
    (rat-kingdom-agent-shell-test--set-session buffer "abc-123")
    (should-not (rat-kingdom-agent-shell-transcript buffer))
    (make-directory project t)
    (should-not (rat-kingdom-agent-shell-transcript buffer))
    (kill-buffer buffer)
    (should-not (rat-kingdom-agent-shell-transcript buffer))))

;;;; Stopping

(defvar rat-kingdom-agent-shell-test--calls nil
  "What the stubbed `call-process' was given, newest first.")

(defmacro rat-kingdom-agent-shell-test-with-stubs (found &rest body)
  "Run BODY with `executable-find' answering FOUND and `call-process' stubbed.
The stub records its arguments in `rat-kingdom-agent-shell-test--calls'
and starts nothing."
  (declare (indent 1) (debug t))
  `(let ((rat-kingdom-agent-shell-test--calls nil)
         (inhibit-message t))
     (cl-letf (((symbol-function 'executable-find)
                (lambda (&rest _) ,found))
               ((symbol-function 'call-process)
                (lambda (&rest args)
                  (push args rat-kingdom-agent-shell-test--calls)
                  0)))
       ,@body)))

(ert-deftest rat-kingdom-agent-shell-test-stop-runs-command ()
  (rat-kingdom-agent-shell-test-with-session (buffer project)
    (let ((mine (rat-kingdom-agent-shell-test--transcript project "abc-123"))
          (rat-kingdom-agent-shell-session-end-command
           '("cm" "hook" "session-end" "--transcript")))
      (rat-kingdom-agent-shell-test--set-session buffer "abc-123")
      (rat-kingdom-agent-shell-test-with-stubs "/usr/local/bin/cm"
        (rat-kingdom-agent-shell-stop buffer)
        (should-not (buffer-live-p buffer))
        (should (equal (length rat-kingdom-agent-shell-test--calls) 1))
        (let ((args (car rat-kingdom-agent-shell-test--calls)))
          (should (equal (car args) "cm"))
          ;; Discarded output, not waited for.
          (should (equal (nth 2 args) 0))
          (should (equal (nthcdr 4 args)
                         (list "hook" "session-end" "--transcript" mine))))))))

(ert-deftest rat-kingdom-agent-shell-test-stop-without-command ()
  (rat-kingdom-agent-shell-test-with-session (buffer project)
    (rat-kingdom-agent-shell-test--transcript project "abc-123")
    (rat-kingdom-agent-shell-test--set-session buffer "abc-123")
    (let ((rat-kingdom-agent-shell-session-end-command nil))
      (rat-kingdom-agent-shell-test-with-stubs "/usr/local/bin/cm"
        (rat-kingdom-agent-shell-stop buffer)
        (should-not (buffer-live-p buffer))
        (should-not rat-kingdom-agent-shell-test--calls)))))

(ert-deftest rat-kingdom-agent-shell-test-stop-without-program ()
  (rat-kingdom-agent-shell-test-with-session (buffer project)
    (rat-kingdom-agent-shell-test--transcript project "abc-123")
    (rat-kingdom-agent-shell-test--set-session buffer "abc-123")
    (let ((rat-kingdom-agent-shell-session-end-command '("cm" "hook")))
      (rat-kingdom-agent-shell-test-with-stubs nil
        (rat-kingdom-agent-shell-stop buffer)
        (should-not (buffer-live-p buffer))
        (should-not rat-kingdom-agent-shell-test--calls)))))

(ert-deftest rat-kingdom-agent-shell-test-stop-without-transcript ()
  (rat-kingdom-agent-shell-test-with-session (buffer _project)
    (let ((rat-kingdom-agent-shell-session-end-command '("cm" "hook")))
      (rat-kingdom-agent-shell-test-with-stubs "/usr/local/bin/cm"
        (rat-kingdom-agent-shell-stop buffer)
        (should-not (buffer-live-p buffer))
        (should-not rat-kingdom-agent-shell-test--calls)))))

(ert-deftest rat-kingdom-agent-shell-test-stop-survives-failure ()
  (rat-kingdom-agent-shell-test-with-session (buffer project)
    (rat-kingdom-agent-shell-test--transcript project "abc-123")
    (rat-kingdom-agent-shell-test--set-session buffer "abc-123")
    (let ((rat-kingdom-agent-shell-session-end-command '("cm" "hook"))
          (inhibit-message t))
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (&rest _) "/usr/local/bin/cm"))
                ((symbol-function 'call-process)
                 (lambda (&rest _) (error "No such process"))))
        (rat-kingdom-agent-shell-stop buffer)
        (should-not (buffer-live-p buffer))))))

(ert-deftest rat-kingdom-agent-shell-test-stop-dead-buffer ()
  (let ((buffer (generate-new-buffer " rat-kingdom-agent-shell-test")))
    (kill-buffer buffer)
    (rat-kingdom-agent-shell-test-with-stubs "/usr/local/bin/cm"
      (rat-kingdom-agent-shell-stop buffer)
      (should-not rat-kingdom-agent-shell-test--calls))))

(provide 'rat-kingdom-agent-shell-test)
;;; rat-kingdom-agent-shell-test.el ends here
