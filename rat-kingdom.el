;;; rat-kingdom.el --- Swarm orchestration for coding agents -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Chaz Straney

;; Author: Chaz Straney <chaz.straney@gmail.com>
;; Maintainer: Chaz Straney <chaz.straney@gmail.com>
;; URL: https://github.com/chazu/rat-kingdom.el
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1"))
;; Keywords: tools, processes
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; rat-kingdom runs a swarm of coding agents from inside Emacs: a king
;; the user talks to, workers in their own Git worktrees, and a
;; tuplespace they coordinate through.  DESIGN.md describes the whole
;; system and says how much of it is built.
;;
;; To try what there is:
;;
;;   M-x rat-kingdom-mode         start reacting to the space
;;   M-x rat-kingdom-add-repo     register a repository
;;   M-x rat-kingdom-start-story  give a worker one task there
;;   M-x rat-kingdom-inspect      watch the space
;;
;; A worker is a Claude Code session in an agent-shell buffer, in its own
;; worktree.  When it reports that it is done, its commit is merged in a
;; candidate worktree, the repository's check runs, and the repository's
;; target branch (rk/integration unless you say otherwise) is moved.
;; Your checkout is never touched and nothing is pushed.

;;; Code:

(require 'rat-kingdom-space)
(require 'rat-kingdom-reaction)
(require 'rat-kingdom-inspector)
(require 'rat-kingdom-git)
(require 'rat-kingdom-mcp)
(require 'rat-kingdom-run)
(require 'rat-kingdom-story)

(defgroup rat-kingdom nil
  "Swarm orchestration for coding agents."
  :group 'tools
  :prefix "rat-kingdom-")

;;;###autoload
(define-minor-mode rat-kingdom-mode
  "React to what is written to the rat-kingdom space.
While this is on, stories move: workers are started, their results
checked and merged."
  :global t
  :group 'rat-kingdom
  (if rat-kingdom-mode
      (rat-kingdom-reaction-attach (rat-kingdom-space-default))
    (rat-kingdom-reaction-detach (rat-kingdom-space-default))
    (rat-kingdom-mcp-stop)))

(defun rat-kingdom--read-command (prompt)
  "Read a command with PROMPT and return it as a list of strings, or nil."
  (let ((text (read-string prompt)))
    (and (not (string-blank-p text)) (split-string-and-unquote text))))

;;;###autoload
(defun rat-kingdom-add-repo (path &optional check)
  "Register the repository at PATH, with CHECK as its merge check.
CHECK is a command as a list of strings, run without a shell in a
candidate worktree; work is merged only if it succeeds."
  (interactive
   (list (read-directory-name "Repository: " nil nil t)
         (rat-kingdom--read-command
          "Check before merging (empty for none), e.g. make check: ")))
  (let ((repo (rat-kingdom-repo-add (rat-kingdom-space-default) path
                                    :check check)))
    (message "Registered %s; finished work is merged into %s"
             (plist-get repo :name) (plist-get repo :target))))

;;;###autoload
(defun rat-kingdom-start-story (repo title description)
  "Give a worker in REPO one task: TITLE, with DESCRIPTION as its criteria."
  (interactive
   (let ((names (mapcar (lambda (repo) (plist-get repo :name))
                        (rat-kingdom-repo-list (rat-kingdom-space-default)))))
     (unless names
       (user-error "Register a repository first: M-x rat-kingdom-add-repo"))
     (list (completing-read "Repository: " names nil t)
           (read-string "Task: ")
           (read-string "Acceptance criteria: "))))
  (unless rat-kingdom-mode
    (rat-kingdom-mode 1))
  (message "Started %s"
           (rat-kingdom-story-start (rat-kingdom-space-default) repo title
                                    (and (not (string-blank-p description))
                                         description))))

(provide 'rat-kingdom)
;;; rat-kingdom.el ends here
