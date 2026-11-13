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
;; its target branch, by default rk/integration, from HEAD.  Finished
;; work is merged into the target and nowhere else: the user's checkout,
;; index, stash and hooks are never touched, and nothing here pushes.
;;
;; Everything here returns quickly.  A repository's own check, which may
;; not, is run as a separate process by rat-kingdom-story.el.

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

(cl-defun rat-kingdom-repo-add (space path
                                      &key name target check setup workflow)
  "Register the repository at PATH in SPACE and return its record.
NAME defaults to the directory's name.  TARGET is the branch finished
work is merged into, by default `rat-kingdom-git-default-target'; it
is created from HEAD if it does not exist.  CHECK is the command, a
list of strings, that must succeed before work is merged; it is run
without a shell.  SETUP is a command of the same kind run in each new
worktree before a worker starts in it and before the check, for example
to install dependencies.  WORKFLOW names the workflow its stories follow
unless they say otherwise.  Registering a name again replaces its
record."
  (let* ((top (rat-kingdom-git path "rev-parse" "--show-toplevel"))
         (name (or name (file-name-nondirectory (directory-file-name top))))
         (target (or target rat-kingdom-git-default-target)))
    (unless (string-match-p "\\`[[:alnum:]][[:alnum:]._-]*\\'" name)
      (error "A repository name is letters, digits, dots, dashes: %S" name))
    (unless (and (listp check) (cl-every #'stringp check))
      (error "A check is a list of strings: %S" check))
    (unless (and (listp setup) (cl-every #'stringp setup))
      (error "A setup is a list of strings: %S" setup))
    (unless (rat-kingdom-git-ok-p top "rev-parse" "--verify" "--quiet" "HEAD")
      (error "%s has no commits yet" top))
    (unless (rat-kingdom-git-ok-p top "rev-parse" "--verify" "--quiet"
                                  (concat "refs/heads/" target))
      (rat-kingdom-git top "branch" target "HEAD"))
    (rat-kingdom-space-put space 'repo :scope name :identity name
                           :payload (list :path top :target target
                                          :check check :setup setup
                                          :workflow (and workflow
                                                         (format "%s" workflow)))
                           :actor "user")
    (rat-kingdom-repo-get space name)))

(defun rat-kingdom-repo-get (space name)
  "Return the record of the repository NAME in SPACE, or nil.
The record is a property list: `:name', `:path', `:target', `:check',
`:setup' and `:workflow'."
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

(provide 'rat-kingdom-git)
;;; rat-kingdom-git.el ends here
