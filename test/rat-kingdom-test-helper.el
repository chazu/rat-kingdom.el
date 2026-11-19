;;; rat-kingdom-test-helper.el --- Shared setup for the rat-kingdom tests -*- lexical-binding: t; -*-

;;; Commentary:

;; Every rat-kingdom test runs in the same environment, whatever the
;; machine and the process that runs the tests.  Each test file
;; requires this file.  It wraps each test whose name starts with
;; "rat-kingdom-" in `rat-kingdom-test-isolated', which:
;;
;; - gives Git an empty configuration of its own: GIT_CONFIG_GLOBAL is a
;;   temporary file that holds only a commit identity, and
;;   GIT_CONFIG_NOSYSTEM is set, so the user's and the system's Git
;;   configuration (such as push.autosetupremote) do not apply;
;;
;; - removes the variables of a rat-kingdom session (see
;;   `rat-kingdom-test-session-variables') and every other GIT_
;;   variable, such as the GIT_CONFIG_KEY_n push block of an agent's
;;   session, GIT_DIR or GIT_INDEX_FILE;
;;
;; - binds `native-comp-enable-subr-trampolines' to nil, so that a test
;;   that stubs a primitive such as `call-process' does not need a
;;   working native compiler.
;;
;; A test that needs a session's environment makes it itself, for
;; example with `rat-kingdom-agent-shell-environment'.

;;; Code:

(require 'ert)
(require 'seq)

(defvar native-comp-enable-subr-trampolines)

(defconst rat-kingdom-test-session-variables
  '("RAT_KINGDOM_RUN" "RK_AGENT" "GH_PROMPT_DISABLED")
  "Variables, other than GIT_ ones, that a rat-kingdom session can set.
`rat-kingdom-test-environment' removes them.")

(defconst rat-kingdom-test-git-identity '("rat-kingdom test" . "test@example.com")
  "The commit identity, (NAME . EMAIL), of the tests' Git configuration.
A repository's own user.name and user.email come before it.")

(defvar rat-kingdom-test--git-config nil
  "The Git configuration file of the tests, once it is made.")

(defun rat-kingdom-test-git-config ()
  "Return the file that is GIT_CONFIG_GLOBAL for the tests.
It holds only `rat-kingdom-test-git-identity'.  It is made the first
time, and made again if it was deleted."
  (unless (and rat-kingdom-test--git-config
               (file-exists-p rat-kingdom-test--git-config))
    (let ((file (make-temp-file "rat-kingdom-test-gitconfig")))
      (with-temp-file file
        (insert (format "[user]\n\tname = %s\n\temail = %s\n"
                        (car rat-kingdom-test-git-identity)
                        (cdr rat-kingdom-test-git-identity))))
      (setq rat-kingdom-test--git-config file)))
  rat-kingdom-test--git-config)

(defun rat-kingdom-test--session-entry-p (entry)
  "Return non-nil if ENTRY of an environment is for Git or a session."
  (or (string-prefix-p "GIT_" entry)
      (member (substring entry 0 (string-search "=" entry))
              rat-kingdom-test-session-variables)))

(defun rat-kingdom-test-environment (&optional environment)
  "Return ENVIRONMENT as the tests see it.
ENVIRONMENT is a list like `process-environment', which it defaults
to.  The result has no GIT_ variable and none of
`rat-kingdom-test-session-variables'.  It sets GIT_CONFIG_GLOBAL to
`rat-kingdom-test-git-config' and GIT_CONFIG_NOSYSTEM to 1."
  (append (list (concat "GIT_CONFIG_GLOBAL=" (rat-kingdom-test-git-config))
                "GIT_CONFIG_NOSYSTEM=1")
          (seq-remove #'rat-kingdom-test--session-entry-p
                      (or environment process-environment))))

(defmacro rat-kingdom-test-isolated (&rest body)
  "Run BODY in the environment of the tests.
See `rat-kingdom-test-environment'.  Stubbing a primitive in BODY does
not compile a native trampoline."
  (declare (indent 0) (debug t))
  `(let ((process-environment (rat-kingdom-test-environment))
         (native-comp-enable-subr-trampolines nil))
     ,@body))

(defun rat-kingdom-test--own-p (test)
  "Return non-nil if TEST, an `ert-test', is a rat-kingdom test."
  (let ((name (ert-test-name test)))
    (and name (symbolp name)
         (string-prefix-p "rat-kingdom-" (symbol-name name)))))

(defun rat-kingdom-test--run-isolated (run test &rest args)
  "Call RUN, which is `ert-run-test', with TEST and ARGS.
Run a rat-kingdom TEST in `rat-kingdom-test-isolated'."
  (if (rat-kingdom-test--own-p test)
      (rat-kingdom-test-isolated (apply run test args))
    (apply run test args)))

(advice-add 'ert-run-test :around #'rat-kingdom-test--run-isolated)

(provide 'rat-kingdom-test-helper)
;;; rat-kingdom-test-helper.el ends here
