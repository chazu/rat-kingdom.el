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
;; To use it:
;;
;;   M-x rat-kingdom-king         start the king, or show it; then tell
;;                                it what you want done and where
;;   M-x rat-kingdom-inspect      watch the space
;;
;; Everything the king does can also be done by hand:
;;
;;   M-x rat-kingdom-mode         start reacting to the space
;;   M-x rat-kingdom-add-repo     register a repository
;;   M-x rat-kingdom-start-story  give a worker one task there
;;   M-x rat-kingdom-move-story   put a story at another place
;;   M-x rat-kingdom-review-story give a verdict on a story in review
;;   M-x rat-kingdom-cancel-story end a story
;;   M-x rat-kingdom-reconcile    recover work an Emacs restart cut off
;;   M-x rat-kingdom-tasks-refresh show the trackers' ready tasks as
;;                                `available' in the space
;;
;; A worker is a Claude Code session in an agent-shell buffer, in its own
;; worktree.  When it reports that it is done, its commit is merged in a
;; candidate worktree, the repository's check runs, the king reviews it
;; if the workflow says so, and the repository's target branch
;; (rk/integration unless you say otherwise) is moved.  Your checkout is
;; never touched and nothing is pushed.

;;; Code:

(require 'rat-kingdom-space)
(require 'rat-kingdom-reaction)
(require 'rat-kingdom-inspector)
(require 'rat-kingdom-git)
(require 'rat-kingdom-mcp)
(require 'rat-kingdom-run)
(require 'rat-kingdom-workflow)
(require 'rat-kingdom-task)
(require 'rat-kingdom-story)
(require 'rat-kingdom-king)

(defgroup rat-kingdom nil
  "Swarm orchestration for coding agents."
  :group 'tools
  :prefix "rat-kingdom-")

;;;; Recovery

(defvar rat-kingdom-mode)

(defvar rat-kingdom--watch-timer nil
  "The timer that looks for stuck stories while the mode is on.")

;;;###autoload
(defun rat-kingdom-reconcile ()
  "Recover the work that was in flight when Emacs last stopped.
A worker that was cut off is replaced by a new one in the same
worktree, and a check that was running is run again.  Turning on
`rat-kingdom-mode' does this, so it is seldom needed by hand."
  (interactive)
  (let* ((space (rat-kingdom-space-default))
         (found (rat-kingdom-story-reconcile space))
         (runs (plist-get found :runs))
         (checks (plist-get found :checks)))
    (when (and rat-kingdom-mode (or runs checks))
      (rat-kingdom-reaction-run space))
    (if (or runs checks)
        (message "rat-kingdom: recovering: %d interrupted (%s), %d to check \
again (%s)"
                 (length runs) (string-join runs ", ")
                 (length checks) (string-join checks ", "))
      (when (called-interactively-p 'interactive)
        (message "rat-kingdom: nothing was interrupted")))
    found))

(defun rat-kingdom--watch ()
  "Look for stuck stories in the default space."
  (let ((space (rat-kingdom-space-default)))
    (when (rat-kingdom-space-db space)
      (rat-kingdom-story-watch space))))

;;;###autoload
(define-minor-mode rat-kingdom-mode
  "React to what is written to the rat-kingdom space.
While this is on, stories move: workers are started, their results
checked, reviewed and merged.  Turning it on first recovers whatever
an earlier Emacs left in flight, then shows each repository's ready
tasks as `available' in the space."
  :global t
  :group 'rat-kingdom
  (when (timerp rat-kingdom--watch-timer)
    (cancel-timer rat-kingdom--watch-timer)
    (setq rat-kingdom--watch-timer nil))
  (if rat-kingdom-mode
      (let ((space (rat-kingdom-space-default)))
        (rat-kingdom-reaction--ensure-table space)
        (rat-kingdom-reconcile)
        (with-demoted-errors "rat-kingdom: projecting tasks: %S"
          (rat-kingdom-task-project-all space))
        (rat-kingdom-reaction-attach space)
        (setq rat-kingdom--watch-timer
              (run-at-time rat-kingdom-story-watch-interval
                           rat-kingdom-story-watch-interval
                           #'rat-kingdom--watch)))
    (rat-kingdom-reaction-detach (rat-kingdom-space-default))
    (rat-kingdom-mcp-stop)))

;;;; The king

;;;###autoload
(defun rat-kingdom-king (&optional fresh)
  "Show the king, starting it if it is not running.
If the king's earlier session ended, take it up again, so that it keeps
what it knew.  With a prefix argument FRESH, start a new session, after
stopping the king if it is running."
  (interactive "P")
  (unless rat-kingdom-mode
    (rat-kingdom-mode 1))
  (let ((space (rat-kingdom-space-default)))
    (when (and fresh (rat-kingdom-run-live-p rat-kingdom-king-id)
               (yes-or-no-p "Stop the king and start a new session? "))
      (rat-kingdom-run-stop space rat-kingdom-king-id))
    (unless (rat-kingdom-run-live-p rat-kingdom-king-id)
      (rat-kingdom-king-start space fresh)
      (rat-kingdom-reaction-run space))
    (let ((buffer (rat-kingdom-run-handle rat-kingdom-king-id)))
      (if (buffer-live-p buffer)
          (pop-to-buffer buffer)
        (error "The king could not be started: %s"
               (or (plist-get (rat-kingdom-run-get space rat-kingdom-king-id)
                              :error)
                   "no reason was recorded"))))))

;;;; By hand

(defun rat-kingdom--read-command (prompt)
  "Read a command with PROMPT and return it as a list of strings, or nil."
  (let ((text (read-string prompt)))
    (and (not (string-blank-p text)) (split-string-and-unquote text))))

(defun rat-kingdom--read-story (prompt &optional pattern)
  "Read the id of a story in progress with PROMPT.
PATTERN, if given, is a story pattern the story must match."
  (let ((stories (rat-kingdom-space-scan (rat-kingdom-space-default)
                                         (or pattern '(story)))))
    (unless stories
      (user-error "No story fits"))
    (car (split-string
          (completing-read
           prompt
           (mapcar (lambda (story)
                     (format "%s  %s: %s" (plist-get story :identity)
                             (plist-get (plist-get story :payload) :at)
                             (plist-get (plist-get story :payload) :title)))
                   stories)
           nil t)))))

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
  (let* ((space (rat-kingdom-space-default))
         (warnings (rat-kingdom-story-warnings space repo)))
    (when (and warnings (called-interactively-p 'interactive)
               (not (yes-or-no-p (concat (string-join warnings "\n")
                                         "\nStart the story anyway? "))))
      (user-error "Not started"))
    (message "Started %s"
             (rat-kingdom-story-start space repo title
                                      (and (not (string-blank-p description))
                                           description)))))

;;;###autoload
(defun rat-kingdom-move-story (story place &optional note)
  "Put STORY at PLACE of its workflow, with NOTE saying why."
  (interactive
   (let* ((story (rat-kingdom--read-story "Move story: "))
          (workflow (rat-kingdom-story--workflow
                     (rat-kingdom-story-get (rat-kingdom-space-default)
                                            story))))
     (list story
           (completing-read "To: " (plist-get workflow :places) nil t)
           (read-string "Note for the next worker (may be empty): "))))
  (rat-kingdom-story-move (rat-kingdom-space-default) story place
                          (and note (not (string-blank-p note)) note))
  (message "%s is now at %s" story place))

;;;###autoload
(defun rat-kingdom-review-story (story value &optional notes)
  "Give the verdict VALUE, pass or fix, on STORY, with NOTES for a fix."
  (interactive
   (let* ((story (rat-kingdom--read-story "Review story: "
                                          '(story :awaiting review)))
          (value (completing-read "Verdict: " '("pass" "fix") nil t)))
     (list story value
           (and (equal value "fix") (read-string "What to change: ")))))
  (rat-kingdom-story-verdict (rat-kingdom-space-default) story value notes)
  (message "Recorded %s for %s" value story))

;;;###autoload
(defun rat-kingdom-cancel-story (story)
  "End STORY for good, keeping its worktree and branch."
  (interactive (list (rat-kingdom--read-story "Cancel story: ")))
  (message "%s" (rat-kingdom-story-cancel (rat-kingdom-space-default) story)))

(provide 'rat-kingdom)
;;; rat-kingdom.el ends here
