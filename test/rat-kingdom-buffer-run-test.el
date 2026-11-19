;;; rat-kingdom-buffer-run-test.el --- Tests for rat-kingdom-buffer-run -*- lexical-binding: t; -*-

;;; Commentary:

;; Batch tests for `rat-kingdom-buffer-run', which tells other packages
;; which run an agent-shell buffer belongs to.  Runs, stories and epics
;; are recorded straight into the space of the repository fixture of
;; rat-kingdom-story-test.el, and buffers are plain buffers marked as
;; the agent-shell backend marks them; no agent is started.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'rat-kingdom)
(require 'rat-kingdom-agent-shell)
(require 'rat-kingdom-story-test)
(require 'rat-kingdom-reload-test)

(defmacro rat-kingdom-buffer-run-test--with-buffer (var id &rest body)
  "Run BODY with VAR bound to a new buffer marked as the run ID's."
  (declare (indent 2) (debug t))
  `(let ((,var (generate-new-buffer " *rat-kingdom-buffer-run-test*")))
     (unwind-protect
         (progn
           (with-current-buffer ,var
             (setq-local rat-kingdom-run-buffer-id ,id))
           ,@body)
       (kill-buffer ,var))))

(defun rat-kingdom-buffer-run-test--runs (space)
  "Record a run in each role in SPACE, with a story, an epic and a topic."
  (rat-kingdom-space-put space 'story :scope "demo" :identity "S-3a9c"
                         :payload (list :title "Fix the parser"))
  (rat-kingdom-space-put space 'story :scope "demo" :identity "S-4b0d"
                         :payload (list :title "Survey the tests"))
  (rat-kingdom-space-put space 'epic :scope "demo" :identity "T-1"
                         :payload (list :title "Faster builds"
                                        :state "running"))
  (rat-kingdom-run-create space :id "king" :role 'king :worktree "/tmp/")
  (rat-kingdom-run-create space :id "S-3a9c.1" :repo "demo" :story "S-3a9c"
                          :role 'rat :worktree "/tmp/")
  (rat-kingdom-run-create space :id "S-4b0d.1" :repo "demo" :story "S-4b0d"
                          :role 'researcher :worktree "/tmp/")
  (rat-kingdom-run-create space :id "F-T-1" :repo "demo" :role 'foreman
                          :worktree "/tmp/")
  (rat-kingdom-run-update space "F-T-1" :epic "T-1")
  (rat-kingdom-run-create space :id "C-5c1e" :repo "demo" :role 'consul
                          :worktree "/tmp/")
  (rat-kingdom-run-update space "C-5c1e" :topic "The release plan"
                          :state "working"))

(ert-deftest rat-kingdom-buffer-run-test-each-role ()
  (rat-kingdom-story-test-with-repo (space _path)
    (rat-kingdom-buffer-run-test--runs space)
    (cl-flet ((describe (id)
                (rat-kingdom-buffer-run-test--with-buffer buffer id
                  (should (equal (with-current-buffer buffer
                                   (rat-kingdom-buffer-run))
                                 (rat-kingdom-buffer-run buffer)))
                  (rat-kingdom-buffer-run (buffer-name buffer)))))
      (should (equal (describe "king")
                     '(:role king :id "king" :name nil :story nil :title nil
                             :repo nil :state "starting")))
      (should (equal (describe "S-3a9c.1")
                     '(:role rat :id "S-3a9c.1" :name "Pip-3a9c"
                             :story "S-3a9c" :title "Fix the parser"
                             :repo "demo" :state "starting")))
      (should (equal (describe "S-4b0d.1")
                     '(:role researcher :id "S-4b0d.1" :name "Nibbles-4b0d"
                             :story "S-4b0d" :title "Survey the tests"
                             :repo "demo" :state "starting")))
      (should (equal (describe "F-T-1")
                     '(:role foreman :id "F-T-1" :name "Whiskers-T-1"
                             :story nil :title "Faster builds"
                             :repo "demo" :state "starting")))
      (should (equal (describe "C-5c1e")
                     '(:role consul :id "C-5c1e" :name "Scamper-5c1e"
                             :story nil :title "The release plan"
                             :repo "demo" :state "working")))
      ;; Read when called: a new title shows at once.
      (rat-kingdom-space-put space 'story :scope "demo" :identity "S-3a9c"
                             :payload (list :title "Fix the lexer"))
      (should (equal (plist-get (describe "S-3a9c.1") :title)
                     "Fix the lexer"))
      ;; A run with no record left is not described.
      (should-not (describe "S-ffff.1")))))

(ert-deftest rat-kingdom-buffer-run-test-plain-and-dead-buffers ()
  (rat-kingdom-story-test-with-repo (space _path)
    (rat-kingdom-buffer-run-test--runs space)
    (with-temp-buffer
      (should-not (rat-kingdom-buffer-run))
      (should-not (rat-kingdom-buffer-run (current-buffer))))
    (let (dead)
      (rat-kingdom-buffer-run-test--with-buffer buffer "S-3a9c.1"
        (setq dead buffer))
      (should-not (rat-kingdom-buffer-run dead)))
    (should-not (rat-kingdom-buffer-run "no such buffer"))))

(ert-deftest rat-kingdom-buffer-run-test-not-started ()
  ;; No space is open, and a plain buffer opens none.
  (let ((rat-kingdom-space--default nil))
    (cl-letf (((symbol-function 'rat-kingdom-space-default)
               (lambda () (error "The space was opened"))))
      (with-temp-buffer
        (should-not (rat-kingdom-buffer-run))))))

(ert-deftest rat-kingdom-buffer-run-test-agent-shell-marks-its-buffer ()
  (rat-kingdom-story-test-with-repo (space path)
    (rat-kingdom-buffer-run-test--runs space)
    (let ((buffer (generate-new-buffer " *rat-kingdom-buffer-run-shell*"))
          (require (symbol-function 'require)))
      (unwind-protect
          (cl-letf (((symbol-function 'require)
                     (lambda (feature &rest args)
                       (or (eq feature 'agent-shell)
                           (apply require feature args))))
                    ((symbol-function 'rat-kingdom-agent-shell-run-config)
                     #'ignore)
                    ((symbol-function 'agent-shell--start)
                     (lambda (&rest _) buffer))
                    ((symbol-function 'agent-shell-subscribe-to) #'ignore))
            (should (eq (rat-kingdom-agent-shell-start
                         (plist-put (rat-kingdom-run-get space "S-3a9c.1")
                                    :worktree path)
                         "Go")
                        buffer))
            (should (equal (plist-get (rat-kingdom-buffer-run buffer) :id)
                           "S-3a9c.1"))
            ;; A change of major mode keeps it.
            (with-current-buffer buffer (text-mode))
            (should (equal (plist-get (rat-kingdom-buffer-run buffer) :role)
                           'rat)))
        (kill-buffer buffer)))))

(ert-deftest rat-kingdom-buffer-run-test-survives-reload ()
  (rat-kingdom-story-test-with-repo (space _path)
    (rat-kingdom-buffer-run-test--runs space)
    (rat-kingdom-buffer-run-test--with-buffer buffer "C-5c1e"
      (let ((before (rat-kingdom-buffer-run buffer)))
        (should before)
        (rat-kingdom-reload-test--isolated
          (rat-kingdom-reload))
        (should (equal (buffer-local-value 'rat-kingdom-run-buffer-id buffer)
                       "C-5c1e"))
        (should (equal (rat-kingdom-buffer-run buffer) before))))))

(provide 'rat-kingdom-buffer-run-test)
;;; rat-kingdom-buffer-run-test.el ends here
