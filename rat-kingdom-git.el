;;; rat-kingdom-git.el --- Git, and the repositories in use -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Chaz Straney

;; Author: Chaz Straney <chaz.straney@gmail.com>
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Short Git commands, run synchronously, and the registry of
;; repositories rat-kingdom works in.
;;
;; A registered repository is a `repo' tuple.  Registering one creates
;; its target branch, by default rk/integration, from HEAD, and its br
;; workspace, kept out of Git, if it has none (see rat-kingdom-task.el).
;; Finished work is merged into the target and nowhere else: the user's
;; checkout, index, stash and hooks are never touched.
;;
;; The one push is `rat-kingdom-git-publish', which the user, or the king
;; on the user's explicit request, calls to push one branch to one
;; remote.  It never forces, and it writes a `published' tuple as a
;; receipt.  The branches rat-kingdom makes are guarded, in the
;; repository's Git configuration, from a push that names no remote
;; (`rat-kingdom-git-push-guard'), so that the user does not push them
;; by accident; `publish' names its remote, and is not affected.
;;
;; Everything here returns quickly, except a push, which waits for the
;; remote.  A repository's own check is run as a separate process by
;; rat-kingdom-story.el.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'rat-kingdom-space)

(defcustom rat-kingdom-git-program "git"
  "The Git executable."
  :type 'string
  :group 'rat-kingdom)

(defcustom rat-kingdom-git-default-target "rk/integration"
  "The branch finished work is merged into, unless a repository says otherwise."
  :type 'string
  :group 'rat-kingdom)

(define-error 'rat-kingdom-git-error "Git failed")

;;;; Running Git

(defun rat-kingdom-git--run (directory args)
  "Run Git with ARGS in DIRECTORY.
Return (EXIT OUTPUT ERRORS), the texts trimmed."
  (let ((default-directory (file-name-as-directory (expand-file-name directory)))
        (process-environment
         (append '("GIT_TERMINAL_PROMPT=0" "GIT_EDITOR=true" "LC_ALL=C")
                 (cl-remove-if
                  (lambda (entry)
                    (string-match-p
                     "\\`GIT_\\(DIR\\|WORK_TREE\\|INDEX_FILE\\|COMMON_DIR\\)="
                     entry))
                  process-environment)))
        (errors (make-temp-file "rat-kingdom-git")))
    (unwind-protect
        (with-temp-buffer
          (let ((exit (apply #'call-process rat-kingdom-git-program nil
                             (list t errors) nil args)))
            (list exit
                  (string-trim (buffer-string))
                  (with-temp-buffer
                    (insert-file-contents errors)
                    (string-trim (buffer-string))))))
      (delete-file errors))))

(defun rat-kingdom-git (directory &rest args)
  "Run Git with ARGS in DIRECTORY and return what it printed.
Signal `rat-kingdom-git-error' if it fails."
  (pcase-let ((`(,exit ,output ,errors) (rat-kingdom-git--run directory args)))
    (unless (eql exit 0)
      (signal 'rat-kingdom-git-error
              (list (format "git %s: %s" (string-join args " ")
                            (if (string-empty-p errors) output errors)))))
    output))

(defun rat-kingdom-git-ok-p (directory &rest args)
  "Run Git with ARGS in DIRECTORY and return non-nil if it succeeds."
  (eql (car (rat-kingdom-git--run directory args)) 0))

(defun rat-kingdom-git-rev (directory revision)
  "Return the commit REVISION names in DIRECTORY."
  (rat-kingdom-git directory "rev-parse" "--verify" "--quiet"
                   (concat revision "^{commit}")))

(defun rat-kingdom-git-checked-out-p (directory branch)
  "Return non-nil if BRANCH is checked out in any worktree of DIRECTORY."
  (member (concat "branch refs/heads/" branch)
          (split-string (rat-kingdom-git directory "worktree" "list" "--porcelain")
                        "\n")))

(defun rat-kingdom-git-ancestor-p (directory ancestor descendant)
  "Return non-nil if ANCESTOR is DESCENDANT or one of its ancestors."
  (rat-kingdom-git-ok-p directory "merge-base" "--is-ancestor"
                        ancestor descendant))

;;;; info/exclude

;; rat-kingdom keeps its own directories out of Git with lines in
;; info/exclude, never in .gitignore.  These functions add and remove
;; one exact line and leave every other byte of the file as it was: the
;; file is read and written without any decoding or conversion.

(defun rat-kingdom-git-exclude-file (directory)
  "Return the info/exclude file of the Git repository DIRECTORY is in.
It is in the common Git directory, which linked worktrees share."
  (let ((top (rat-kingdom-git directory "rev-parse" "--show-toplevel")))
    (expand-file-name "info/exclude"
                      (expand-file-name
                       (rat-kingdom-git top "rev-parse" "--git-common-dir")
                       top))))

(defun rat-kingdom-git--exclude-read (file)
  "Insert the bytes of FILE, if it exists, into a unibyte current buffer."
  (set-buffer-multibyte nil)
  (when (file-exists-p file)
    (insert-file-contents-literally file)))

(defun rat-kingdom-git--exclude-write (file)
  "Write the current buffer's bytes to FILE as they are."
  (let ((coding-system-for-write 'no-conversion))
    (write-region nil nil file nil 'silent)))

(defun rat-kingdom-git-excluded-p (file line)
  "Return non-nil if the exclude FILE has LINE, exactly, as one of its lines."
  (and (file-exists-p file)
       (with-temp-buffer
         (rat-kingdom-git--exclude-read file)
         (member (encode-coding-string line 'utf-8)
                 (split-string (buffer-string) "\n")))))

(defun rat-kingdom-git-exclude (file line)
  "Add LINE to the end of the exclude FILE unless it has it.
Create FILE and its directory if need be.  If FILE does not end in a
newline, one is added before LINE.  Nothing else changes.  Return
non-nil if LINE was added."
  (unless (rat-kingdom-git-excluded-p file line)
    (make-directory (file-name-directory file) t)
    (with-temp-buffer
      (rat-kingdom-git--exclude-read file)
      (goto-char (point-max))
      (unless (or (bobp) (eq (char-before) ?\n))
        (insert "\n"))
      (insert (encode-coding-string line 'utf-8) "\n")
      (rat-kingdom-git--exclude-write file))
    t))

(defun rat-kingdom-git-unexclude (file line)
  "Take every line of the exclude FILE that is exactly LINE out of it.
Each goes with its newline; nothing else changes.  Return non-nil if
there was one."
  (when (file-exists-p file)
    (with-temp-buffer
      (rat-kingdom-git--exclude-read file)
      (goto-char (point-min))
      (let ((pattern (concat "^" (regexp-quote (encode-coding-string line 'utf-8))
                             "\\(?:\n\\|\\'\\)"))
            (case-fold-search nil)
            (removed nil))
        (while (re-search-forward pattern nil t)
          (replace-match "" t t)
          (setq removed t))
        (when removed
          (rat-kingdom-git--exclude-write file))
        removed))))

;;;; Guarding branches from the user's pushes

;; The agents cannot push (rat-kingdom-agent-shell.el), but the user
;; can, from their own checkout.  So that a bare `git push', or magit's
;; push to the push-remote, on the target or a worker's branch fails
;; instead of sending it to the work repository's remote, the branch's
;; pushRemote, in the repository's own configuration in the common Git
;; directory, is a URL Git cannot use.  A push that names its remote,
;; as `rat-kingdom-git-publish' does, is unaffected.

(defconst rat-kingdom-git-push-guard-prefix "rat-kingdom-refuses-to-push::"
  "What a guarded branch's pushRemote begins with; the branch's name follows.
It is `rat-kingdom-agent-shell-push-block': Git reads the part before
\"::\" as the name of a remote helper, which does not exist, so the
push fails and the error names rat-kingdom.")

(defun rat-kingdom-git-push-guard-url (branch)
  "Return the pushRemote that guards BRANCH."
  (concat rat-kingdom-git-push-guard-prefix branch))

(defun rat-kingdom-git--push-remote (directory branch)
  "Return BRANCH's pushRemote in the repository's own configuration, or nil.
DIRECTORY is in the repository."
  (pcase-let ((`(,exit ,output ,_)
               (rat-kingdom-git--run
                directory (list "config" "--local" "--get"
                                (format "branch.%s.pushRemote" branch)))))
    (and (eql exit 0) output)))

(defun rat-kingdom-git-push-guarded-p (directory branch)
  "Return non-nil if BRANCH of the repository DIRECTORY is in is guarded."
  (equal (rat-kingdom-git--push-remote directory branch)
         (rat-kingdom-git-push-guard-url branch)))

(defun rat-kingdom-git-push-guard (directory branch)
  "Guard BRANCH of the repository DIRECTORY is in from a push with no remote.
Set its branch.BRANCH.pushRemote, in the repository's configuration
in the common Git directory, to `rat-kingdom-git-push-guard-url'.
Nothing else in the configuration changes.  Return non-nil if it was
not guarded before."
  (unless (rat-kingdom-git-push-guarded-p directory branch)
    (rat-kingdom-git directory "config" "--local"
                     (format "branch.%s.pushRemote" branch)
                     (rat-kingdom-git-push-guard-url branch))
    t))

(defun rat-kingdom-git-push-unguard (directory branch)
  "Take the guard of `rat-kingdom-git-push-guard' off BRANCH.
DIRECTORY is in the repository.  A pushRemote that is not the guard
is left alone.  If the branch's section of the configuration is then
empty, it goes too, so that guarding and unguarding a branch leaves
the configuration as it was.  Return non-nil if BRANCH was guarded."
  (when (rat-kingdom-git-push-guarded-p directory branch)
    (let ((section (format "branch.%s." branch)))
      (rat-kingdom-git directory "config" "--local" "--unset"
                       (concat section "pushRemote"))
      (unless (cl-some (lambda (name) (string-prefix-p section name t))
                       (split-string (rat-kingdom-git directory "config"
                                                      "--local" "--list"
                                                      "--name-only")
                                     "\n" t))
        (rat-kingdom-git-ok-p directory "config" "--local" "--remove-section"
                              (substring section 0 -1))))
    t))

(defun rat-kingdom-git-push-guarded-branches (directory)
  "Return the branches of the repository DIRECTORY is in that are guarded.
They are those whose pushRemote is the guard of their own name."
  (pcase-let ((`(,_ ,output ,_)
               (rat-kingdom-git--run
                directory (list "config" "--local" "--get-regexp"
                                "^branch\\..*\\.pushremote$"))))
    (cl-loop for line in (split-string output "\n" t)
             for (key value) = (split-string line " ")
             for branch = (and (string-prefix-p "branch." key)
                               (string-suffix-p ".pushremote" key)
                               (substring key 7 -11))
             when (and branch
                       (equal value (rat-kingdom-git-push-guard-url branch)))
             collect branch)))

;;;; Repositories

(declare-function rat-kingdom-task-br-ensure "rat-kingdom-task"
                  (repo &optional space))
(declare-function rat-kingdom-config-validate "rat-kingdom-config"
                  (plist layer))
(declare-function rat-kingdom-config-track-apply "rat-kingdom-config"
                  (space repo))
(declare-function rat-kingdom-config-push-guard-apply "rat-kingdom-config"
                  (space repo))

(cl-defun rat-kingdom-repo-add (space path
                                      &key name target check setup workflow
                                      task-prefix git mixins)
  "Register the repository at PATH in SPACE and return its record.
NAME defaults to the directory's name.  TARGET is the branch finished
work is merged into, by default `rat-kingdom-git-default-target'; it
is created from HEAD if it does not exist.  CHECK is the command, a
list of strings, that must succeed before work is merged; it is run
without a shell.  SETUP is a command of the same kind run in each new
worktree before a worker starts in it and before the check, for example
to install dependencies.  WORKFLOW names the workflow its stories follow
unless they say otherwise.  GIT is the :git configuration of the
registration layer, a property list with `:branch' and `:integrate'
\(rat-kingdom-config.el).  MIXINS is a list of mixin names, symbols,
applied to every workflow its stories follow (the registration layer's
`:mixins').  Registering a name again replaces its record.

Every registered repository has a br workspace for its tasks.  If the
checkout has none, one is created by `rat-kingdom-task-br-ensure',
with TASK-PREFIX, by default NAME, as its issue prefix, and kept out of
Git unless the configuration's :track :beads says to track it; the
record returned then has `:task-initialized' t, which is not stored.
If that fails, nothing is registered, no target branch is created, and
the error is signalled.

The configuration's :track is then applied, by
`rat-kingdom-config-track-apply': /.rk/ and /.beads/ are added to or
taken out of the repository's info/exclude.  If it warns that Git
already tracks files in a directory meant to be kept out, the record
returned has the warnings as `:track-warnings', which is not stored.

Last, the configuration's :git :push-guard is applied, by
`rat-kingdom-config-push-guard-apply': the target, whether it was
created now or was there already, and every rats/* branch are guarded
from a push that names no remote, or not."
  (require 'rat-kingdom-task)
  (require 'rat-kingdom-config)
  (let* ((top (rat-kingdom-git path "rev-parse" "--show-toplevel"))
         (name (or name (file-name-nondirectory (directory-file-name top))))
         (target (or target rat-kingdom-git-default-target))
         (task-prefix (and task-prefix (format "%s" task-prefix))))
    (unless (string-match-p "\\`[[:alnum:]][[:alnum:]._-]*\\'" name)
      (error "A repository name is letters, digits, dots, dashes: %S" name))
    (unless (and (listp check) (cl-every #'stringp check))
      (error "A check is a list of strings: %S" check))
    (unless (and (listp setup) (cl-every #'stringp setup))
      (error "A setup is a list of strings: %S" setup))
    (unless (and (proper-list-p mixins)
                 (cl-every (lambda (name)
                             (and name (symbolp name) (not (eq name t))
                                  (not (keywordp name))))
                           mixins))
      (error "Mixins are a list of names such as (no-review): %S" mixins))
    (when (and task-prefix (string-empty-p task-prefix))
      (error "A task prefix may not be empty"))
    (when-let* ((problems (and git (rat-kingdom-config-validate
                                    (list :git git) 'registration))))
      (error "%s" (string-join problems "; ")))
    (unless (rat-kingdom-git-ok-p top "rev-parse" "--verify" "--quiet" "HEAD")
      (error "%s has no commits yet" top))
    (let* ((record (list :name name :path top :task-prefix task-prefix))
           (initialized (rat-kingdom-task-br-ensure record space))
           (warnings (plist-get (rat-kingdom-config-track-apply space record)
                                :warnings)))
      (unless (rat-kingdom-git-ok-p top "rev-parse" "--verify" "--quiet"
                                    (concat "refs/heads/" target))
        (rat-kingdom-git top "branch" target "HEAD"))
      (rat-kingdom-space-put space 'repo :scope name :identity name
                             :payload (append
                                       (list :path top :target target
                                             :check check :setup setup
                                             :workflow (and workflow
                                                            (format "%s"
                                                                    workflow))
                                             :task-prefix task-prefix
                                             :mixins (mapcar #'symbol-name
                                                             mixins))
                                       (and git (list :git git)))
                             :actor "user")
      (rat-kingdom-config-push-guard-apply space name)
      (append (rat-kingdom-repo-get space name)
              (and initialized (list :task-initialized t))
              (and warnings (list :track-warnings warnings))))))

(defun rat-kingdom-repo-get (space name)
  "Return the record of the repository NAME in SPACE, or nil.
The record is a property list: `:name', `:path', `:target', `:check',
`:setup', `:workflow', `:git' and `:task-prefix', the issue prefix its br
workspace was created with, or nil for its name."
  (when-let* ((tuple (rat-kingdom-space-rd
                      space (list 'repo :scope name :identity name))))
    (append (list :name (plist-get tuple :identity))
            (plist-get tuple :payload))))

(defun rat-kingdom-repo-list (space)
  "Return the records of every repository registered in SPACE."
  (mapcar (lambda (tuple)
            (append (list :name (plist-get tuple :identity))
                    (plist-get tuple :payload)))
          (rat-kingdom-space-scan space '(repo))))

(defun rat-kingdom-repo-remove (space name)
  "Forget the repository NAME in SPACE.  Its files are not touched."
  (rat-kingdom-space-retract space (list 'repo :scope name :identity name)
                             :actor "user"))

;;;; Publishing

(defun rat-kingdom-git--remote-commit (path remote branch)
  "Return the commit BRANCH is at on REMOTE of the repository at PATH.
Return nil if REMOTE has no such branch."
  (when-let* ((line (car (split-string
                          (rat-kingdom-git path "ls-remote" "--heads" remote
                                           (concat "refs/heads/" branch))
                          "\n" t))))
    (car (split-string line))))

(cl-defun rat-kingdom-git-publish (space name branch &key remote actor)
  "Push BRANCH of the repository NAME in SPACE to REMOTE, and return a receipt.
BRANCH is a local branch.  REMOTE is one of the repository's remotes,
by default \"origin\".  The commit BRANCH is at is pushed to the
branch of the same name on REMOTE.  The push is never forced: if Git
refuses it, for example because it is not a fast-forward, Git's error
is signalled as `rat-kingdom-git-error'.

Git is run here, in Emacs, with the user's own configuration, hooks
and credentials.  It waits for the remote.

The receipt is a `published' tuple in SPACE, scoped to NAME, with
`:remote', `:url', `:branch', `:old' (the commit the remote had, or nil
if the branch is new there), `:new', `:actor' (ACTOR, by default
\"user\") and `:time'."
  (let* ((repo (or (rat-kingdom-repo-get space name)
                   (error "There is no repository called %s" name)))
         (path (plist-get repo :path))
         (remote (or remote "origin"))
         (actor (or actor "user"))
         (ref (concat "refs/heads/" (or branch ""))))
    (unless (and (stringp branch)
                 (not (string-empty-p branch))
                 (rat-kingdom-git-ok-p path "check-ref-format" ref))
      (error "Not a branch name: %S" branch))
    (unless (member remote (split-string (rat-kingdom-git path "remote") "\n" t))
      (error "%s has no remote called %s" name remote))
    (let ((new (if (rat-kingdom-git-ok-p path "rev-parse" "--verify" "--quiet" ref)
                   (rat-kingdom-git-rev path ref)
                 (error "%s has no branch %s" name branch)))
          (old (rat-kingdom-git--remote-commit path remote branch)))
      ;; The commit, not the branch, so that exactly what was looked at
      ;; is pushed.  No `+', no --force.
      (pcase-let ((`(,exit ,output ,errors)
                   (rat-kingdom-git--run path (list "push" remote
                                                    (concat new ":" ref)))))
        (unless (eql exit 0)
          (signal 'rat-kingdom-git-error
                  (list (format "Pushing %s of %s to %s failed; nothing was \
forced:\n%s"
                                branch name remote
                                (string-trim
                                 (string-join (list errors output) "\n")))))))
      (rat-kingdom-space-out
       space 'published :scope name :identity branch
       :payload (list :remote remote
                      :url (ignore-errors
                             (rat-kingdom-git path "remote" "get-url" "--push"
                                              remote))
                      :branch branch :old old :new new :actor actor
                      :time (format-time-string "%FT%T%z"))
       :actor actor))))

(defun rat-kingdom-git-publish-describe (receipt)
  "Return a line saying what the `published' tuple RECEIPT records."
  (let ((payload (plist-get receipt :payload)))
    (format "Pushed %s of %s to %s (%s): %s."
            (plist-get payload :branch) (plist-get receipt :scope)
            (plist-get payload :remote) (or (plist-get payload :url) "no URL")
            (let ((old (plist-get payload :old))
                  (new (plist-get payload :new)))
              (cond ((null old)
                     (format "new branch at %s" (substring new 0 12)))
                    ((equal old new)
                     (format "already at %s; nothing changed"
                             (substring new 0 12)))
                    (t (format "%s..%s" (substring old 0 12)
                               (substring new 0 12))))))))

(provide 'rat-kingdom-git)
;;; rat-kingdom-git.el ends here
