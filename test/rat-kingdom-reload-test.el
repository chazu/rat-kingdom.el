;;; rat-kingdom-reload-test.el --- Tests for reloading -*- lexical-binding: t; -*-

;;; Commentary:

;; Reloading loads every source file again, as `rat-kingdom-reload'
;; does, with the state it touches bound so that other tests are not
;; affected.  It checks that stale defaults are replaced, that nothing
;; is registered twice and that live runs are kept.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'rat-kingdom)

(defun rat-kingdom-reload-test--once-each (list)
  "Return non-nil if no element of LIST occurs twice."
  (equal (length list) (length (cl-remove-duplicates list :test #'equal))))

(defmacro rat-kingdom-reload-test--isolated (&rest body)
  "Run BODY with the state reloading changes bound to copies."
  (declare (indent 0) (debug t))
  `(let ((rat-kingdom-run-backend nil)
         (rat-kingdom-story-event-functions rat-kingdom-story-event-functions)
         (rat-kingdom-space-change-functions rat-kingdom-space-change-functions)
         (rat-kingdom-run-idle-functions rat-kingdom-run-idle-functions)
         (kill-emacs-hook kill-emacs-hook)
         (rat-kingdom-reaction--registry
          (copy-sequence rat-kingdom-reaction--registry))
         (rat-kingdom-workflow--table
          (copy-alist rat-kingdom-workflow--table))
         (rat-kingdom-mcp--tools (copy-sequence rat-kingdom-mcp--tools))
         (rat-kingdom-agent-shell--defined-agents
          (copy-alist rat-kingdom-agent-shell--defined-agents))
         (rat-kingdom-run--handles (make-hash-table :test #'equal))
         (rat-kingdom-mode nil)
         (inhibit-message t))
     ,@body))

(ert-deftest rat-kingdom-reload-test-lists-every-file ()
  (let ((directory (rat-kingdom--directory)))
    (should (file-exists-p (expand-file-name "rat-kingdom.el" directory)))
    (should (equal (sort (mapcar #'file-name-base
                                 (directory-files directory nil
                                                  "\\`rat-kingdom.*\\.el\\'"))
                         #'string<)
                   (sort (copy-sequence rat-kingdom--files) #'string<)))))

(ert-deftest rat-kingdom-reload-test-replaces-stale-defaults ()
  (rat-kingdom-reload-test--isolated
    ;; What an Emacs that loaded an older version holds.
    (setq rat-kingdom-run-backend
          (list :start #'rat-kingdom-agent-shell-start
                :stop #'rat-kingdom-agent-shell-stop)
          rat-kingdom-story-event-functions nil)
    (puthash "S-1.1" 'handle rat-kingdom-run--handles)
    (let ((handles rat-kingdom-run--handles)
          (reactions (length rat-kingdom-reaction--registry))
          (workflows (length rat-kingdom-workflow--table))
          (tools (length rat-kingdom-mcp--tools)))
      (rat-kingdom-reload)
      (rat-kingdom-reload)
      (should-not rat-kingdom-run-backend)
      (should (eq (rat-kingdom-run--backend :send)
                  #'rat-kingdom-agent-shell-send))
      (dolist (function '(rat-kingdom-story--announce
                          rat-kingdom-task-story-event
                          rat-kingdom-king--news))
        (should (eql (cl-count function rat-kingdom-story-event-functions)
                     1)))
      (dolist (hook (list rat-kingdom-story-event-functions
                          rat-kingdom-space-change-functions
                          rat-kingdom-run-idle-functions
                          kill-emacs-hook))
        (should (rat-kingdom-reload-test--once-each hook)))
      (should (memq #'rat-kingdom-run--note-dying kill-emacs-hook))
      (should (rat-kingdom-reload-test--once-each
               (mapcar #'rat-kingdom-reaction-name
                       rat-kingdom-reaction--registry)))
      (should (rat-kingdom-reload-test--once-each
               (mapcar #'car rat-kingdom-workflow--table)))
      (should (rat-kingdom-reload-test--once-each
               (mapcar (lambda (tool) (plist-get tool :name))
                       rat-kingdom-mcp--tools)))
      (should (eql (length rat-kingdom-reaction--registry) reactions))
      (should (eql (length rat-kingdom-workflow--table) workflows))
      (should (eql (length rat-kingdom-mcp--tools) tools))
      (should (eq rat-kingdom-run--handles handles))
      (should (eq (rat-kingdom-run-handle "S-1.1") 'handle)))))

(ert-deftest rat-kingdom-reload-test-keeps-agent-kinds ()
  (rat-kingdom-reload-test--isolated
    (setq rat-kingdom-agent-shell--defined-agents nil)
    (rat-kingdom-agent-shell-define-agent 'other #'ignore)
    (rat-kingdom-agent-shell-define-agent 'other #'identity)
    (rat-kingdom-reload)
    (rat-kingdom-reload)
    ;; The built-in kinds are there once each, and so is one defined
    ;; before the reload, as last defined.
    (should (equal (rat-kingdom-agent-names) '("other" "claude" "codex")))
    (should (eq (alist-get 'other (rat-kingdom-agent-shell-agents))
                #'identity))
    (should (eq (alist-get 'codex (rat-kingdom-agent-shell-agents))
                'rat-kingdom-agent-shell-codex-config))
    ;; Loading the package does not load Codex's or Claude's adapter.
    (should-not (featurep 'agent-shell-openai))
    (should (equal (rat-kingdom-agent-name nil) "claude"))))

(ert-deftest rat-kingdom-reload-test-says-what-happened-to-the-king ()
  (rat-kingdom-reload-test--isolated
    (let (said)
      (cl-letf (((symbol-function 'rat-kingdom--load-files) #'ignore)
                ((symbol-function 'rat-kingdom-space-default) #'ignore)
                ((symbol-function 'message)
                 (lambda (format &rest args)
                   (setq said (apply #'format format args)))))
        ;; No king running: refresh is not even asked.
        (cl-letf (((symbol-function 'rat-kingdom-king-refresh)
                   (lambda (_space) (error "Not expected"))))
          (rat-kingdom-reload)
          (should (string-prefix-p "rat-kingdom: reloaded" said))
          (should-not (string-search "the king" said)))
        (puthash "king" 'handle rat-kingdom-run--handles)
        (dolist (case '((nil . nil)
                        (restarted . "its session was restarted in place")
                        (deferred . "will be restarted in place when it \
next ends a turn")
                        (changed . "M-x rat-kingdom-king-restart gives them")))
          (cl-letf (((symbol-function 'rat-kingdom-king-refresh)
                     (lambda (_space) (car case))))
            (rat-kingdom-reload)
            (if (cdr case)
                (should (string-search (cdr case) said))
              (should-not (string-search "the king" said)))))))))

(ert-deftest rat-kingdom-reload-test-keeps-a-custom-backend ()
  (rat-kingdom-reload-test--isolated
    (setq rat-kingdom-run-backend (list :start #'ignore :stop #'ignore))
    (rat-kingdom--load-files (rat-kingdom--directory))
    (should (eq (rat-kingdom-run--backend :start) #'ignore))))

(ert-deftest rat-kingdom-reload-test-redefining-keeps-reaction-state ()
  (rat-kingdom-reload-test--isolated
    (setq rat-kingdom-reaction--registry nil)
    (rat-kingdom-defreaction rat-kingdom-reload-test-eat :take (available) nil)
    (let ((reaction (rat-kingdom-reaction-get 'rat-kingdom-reload-test-eat)))
      (setf (rat-kingdom-reaction-enabled reaction) nil
            (rat-kingdom-reaction-fired reaction) 3))
    (rat-kingdom-defreaction rat-kingdom-reload-test-eat :take (story) nil)
    (let ((reaction (rat-kingdom-reaction-get 'rat-kingdom-reload-test-eat)))
      (should (equal (rat-kingdom-reaction-take reaction) '((story))))
      (should-not (rat-kingdom-reaction-enabled reaction))
      (should (eql (rat-kingdom-reaction-fired reaction) 3)))))

(ert-deftest rat-kingdom-reload-test-send-without-send-warns-once ()
  (rat-kingdom-reload-test--isolated
    (let ((rat-kingdom-run-backend (list :start #'ignore :stop #'ignore))
          (rat-kingdom-run--warned-no-send nil)
          (warnings 0))
      (puthash "S-1.1" 'handle rat-kingdom-run--handles)
      (cl-letf (((symbol-function 'display-warning)
                 (lambda (&rest _) (cl-incf warnings))))
        (should-not (rat-kingdom-run-send "S-1.1" "hello"))
        (should-not (rat-kingdom-run-send "S-1.1" "hello")))
      (should (eql warnings 1)))))

(ert-deftest rat-kingdom-reload-test-categories ()
  (should (eq (rat-kingdom-space-category-modality 'story) 'linear))
  (should-not (rat-kingdom-space-category-modality 'no-such-category))
  (let ((rat-kingdom-space-categories nil))
    (rat-kingdom-space-define-category 'tick 'affine)
    (should (eq (rat-kingdom-space-category-modality 'tick) 'affine))
    (should (eq (rat-kingdom-space-category-modality 'story) 'linear))))

(provide 'rat-kingdom-reload-test)
;;; rat-kingdom-reload-test.el ends here
