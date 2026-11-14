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
;; receipt.
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

;;;; Repositories

(declare-function rat-kingdom-task-br-ensure "rat-kingdom-task" (repo))

(cl-defun rat-kingdom-repo-add (space path
                                      &key name target check setup workflow
                                      task-prefix)
  "Register the repository at PATH in SPACE and return its record.
NAME defaults to the directory's name.  TARGET is the branch finished
work is merged into, by default `rat-kingdom-git-default-target'; it
is created from HEAD if it does not exist.  CHECK is the command, a
list of strings, that must succeed before work is merged; it is run
without a shell.  SETUP is a command of the same kind run in each new
worktree before a worker starts in it and before the check, for example
to install dependencies.  WORKFLOW names the workflow its stories follow
unless they say otherwise.  Registering a name again replaces its
record.

Every registered repository has a br workspace for its tasks.  If the
checkout has none, one is created by `rat-kingdom-task-br-ensure',
with TASK-PREFIX, by default NAME, as its issue prefix, and kept out of
Git; the record returned then has `:task-initialized' t, which is not
stored.  If that fails, nothing is registered, no target branch is
created, and the error is signalled."
  (require 'rat-kingdom-task)
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
    (when (and task-prefix (string-empty-p task-prefix))
      (error "A task prefix may not be empty"))
    (unless (rat-kingdom-git-ok-p top "rev-parse" "--verify" "--quiet" "HEAD")
      (error "%s has no commits yet" top))
    (let ((initialized (rat-kingdom-task-br-ensure
                        (list :name name :path top :task-prefix task-prefix))))
      (unless (rat-kingdom-git-ok-p top "rev-parse" "--verify" "--quiet"
                                    (concat "refs/heads/" target))
        (rat-kingdom-git top "branch" target "HEAD"))
      (rat-kingdom-space-put space 'repo :scope name :identity name
                             :payload (list :path top :target target
                                            :check check :setup setup
                                            :workflow (and workflow
                                                           (format "%s" workflow))
                                            :task-prefix task-prefix)
                             :actor "user")
      (append (rat-kingdom-repo-get space name)
              (and initialized (list :task-initialized t))))))

(defun rat-kingdom-repo-get (space name)
  "Return the record of the repository NAME in SPACE, or nil.
The record is a property list: `:name', `:path', `:target', `:check',
`:setup', `:workflow' and `:task-prefix', the issue prefix its br
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
