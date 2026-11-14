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
;;   M-x rat-kingdom-reload       load changed source into this Emacs
;;   M-x rat-kingdom-king-restart restart the king's session in place,
;;                                so it has its current tools
;;
;; A worker is a Claude Code or Codex session in an agent-shell buffer,
;; in its own worktree; the story chooses which, by default
;; `rat-kingdom-default-agent'.  When it reports that it is done, its commit is merged in a
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
(require 'rat-kingdom-fact)
(require 'rat-kingdom-epic)

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
worktree, and a check or setup that was running is run again.  Turning on
`rat-kingdom-mode' does this, so it is seldom needed by hand."
  (interactive)
  (let* ((space (rat-kingdom-space-default))
         (found (rat-kingdom-story-reconcile space))
         (runs (plist-get found :runs))
         (checks (plist-get found :checks))
         (setups (plist-get found :setups)))
    (when (and rat-kingdom-mode (or runs checks setups))
      (rat-kingdom-reaction-run space))
    (if (or runs checks setups)
        (message "rat-kingdom: recovering: %d interrupted (%s), %d to check \
again (%s), %d to set up again (%s)"
                 (length runs) (string-join runs ", ")
                 (length checks) (string-join checks ", ")
                 (length setups) (string-join setups ", "))
      (when (called-interactively-p 'interactive)
        (message "rat-kingdom: nothing was interrupted")))
    found))

(defun rat-kingdom--watch ()
  "Look for stuck stories in the default space."
  (let ((space (rat-kingdom-space-default)))
    (when (rat-kingdom-space-db space)
      (rat-kingdom-story-watch space))))

(defun rat-kingdom--start-watch ()
  "Start the timer that looks for stuck stories, replacing any."
  (when (timerp rat-kingdom--watch-timer)
    (cancel-timer rat-kingdom--watch-timer))
  (setq rat-kingdom--watch-timer
        (run-at-time rat-kingdom-story-watch-interval
                     rat-kingdom-story-watch-interval
                     #'rat-kingdom--watch)))

;;;###autoload
(define-minor-mode rat-kingdom-mode
  "React to what is written to the rat-kingdom space.
While this is on, stories move: workers are started, their results
checked, reviewed and merged.  Turning it on first recovers whatever
an earlier Emacs left in flight, makes sure every registered repository
has a br workspace, then shows each repository's ready tasks as
`available' in the space.  A repository whose workspace cannot be made
is reported and skipped."
  :global t
  :group 'rat-kingdom
  (when (timerp rat-kingdom--watch-timer)
    (cancel-timer rat-kingdom--watch-timer)
    (setq rat-kingdom--watch-timer nil))
  (if rat-kingdom-mode
      (let ((space (rat-kingdom-space-default)))
        (rat-kingdom-reaction--ensure-table space)
        (rat-kingdom-reconcile)
        (with-demoted-errors "rat-kingdom: making br workspaces: %S"
          (rat-kingdom-task-ensure-all space))
        (with-demoted-errors "rat-kingdom: projecting tasks: %S"
          (rat-kingdom-task-project-all space))
        (rat-kingdom-reaction-attach space)
        (rat-kingdom--start-watch))
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

;;;###autoload
(defun rat-kingdom-king-restart ()
  "Restart the king's session in place.
The king is stopped and its session taken up again, so it keeps the
conversation but fetches its tools afresh and, if they or its
instructions changed, is given the current instructions.  This is
refused while the king is in the middle of a turn or you have typed
something in its buffer that is not sent."
  (interactive)
  (rat-kingdom-king-restart-session (rat-kingdom-space-default))
  (message "rat-kingdom: restarted the king's session in place"))

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
(defun rat-kingdom-add-repo (path &optional check setup task-prefix)
  "Register the repository at PATH, with CHECK as its merge check.
CHECK is a command as a list of strings, run without a shell in a
candidate worktree; work is merged only if it succeeds.  SETUP is a
command of the same kind run in each new worktree before a worker
starts and before the check, such as one that installs dependencies.
If the checkout has no br workspace, one is created with TASK-PREFIX,
by default the repository's name, as its issue prefix, and kept out
of Git; see `rat-kingdom-task-br-ensure'."
  (interactive
   (let ((path (read-directory-name "Repository: " nil nil t)))
     (list path
           (rat-kingdom--read-command
            "Check before merging (empty for none), e.g. make check: ")
           (rat-kingdom--read-command
            "Setup in each new worktree (empty for none), e.g. npm ci: ")
           (unless (file-directory-p
                    (expand-file-name
                     ".beads" (rat-kingdom-git path "rev-parse"
                                               "--show-toplevel")))
             (let ((prefix (read-string
                            "Prefix of the new br workspace (empty for the \
repository's name): ")))
               (and (not (string-blank-p prefix)) prefix))))))
  (let ((repo (rat-kingdom-repo-add (rat-kingdom-space-default) path
                                    :check check :setup setup
                                    :task-prefix task-prefix)))
    (message "Registered %s; finished work is merged into %s%s"
             (plist-get repo :name) (plist-get repo :target)
             (if (plist-get repo :task-initialized)
                 (format "; created its br workspace, prefix %s, kept out of Git"
                         (rat-kingdom-task-br-prefix repo))
               ""))))

;;;###autoload
(defun rat-kingdom-start-story (repo title description &optional agent)
  "Give a worker in REPO one task: TITLE, with DESCRIPTION as its criteria.
AGENT names the agent the story's workers run, \"claude\" or \"codex\";
nil means `rat-kingdom-default-agent'."
  (interactive
   (let ((names (mapcar (lambda (repo) (plist-get repo :name))
                        (rat-kingdom-repo-list (rat-kingdom-space-default))))
         (default (rat-kingdom-agent-name nil)))
     (unless names
       (user-error "Register a repository first: M-x rat-kingdom-add-repo"))
     (list (completing-read "Repository: " names nil t)
           (read-string "Task: ")
           (read-string "Acceptance criteria: ")
           (completing-read (format-prompt "Agent" default)
                            (rat-kingdom-agent-names) nil t nil nil
                            default))))
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
                                           description)
                                      nil nil nil agent))))

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

;;;###autoload
(defun rat-kingdom-publish (repo branch &optional remote)
  "Push BRANCH of the registered repository REPO to REMOTE, never forcing.
REMOTE defaults to \"origin\".  A receipt is written to the space.
See `rat-kingdom-git-publish'."
  (interactive
   (let* ((space (rat-kingdom-space-default))
          (names (mapcar (lambda (repo) (plist-get repo :name))
                         (rat-kingdom-repo-list space))))
     (unless names
       (user-error "Register a repository first: M-x rat-kingdom-add-repo"))
     (let* ((repo (rat-kingdom-repo-get
                   space (completing-read "Repository: " names nil t)))
            (path (plist-get repo :path))
            (branch (completing-read
                     "Branch: "
                     (split-string (rat-kingdom-git path "for-each-ref"
                                                    "--format=%(refname:short)"
                                                    "refs/heads")
                                   "\n" t)
                     nil t nil nil (plist-get repo :target)))
            (remote (completing-read
                     "Remote: " (split-string (rat-kingdom-git path "remote")
                                              "\n" t)
                     nil t nil nil "origin")))
       (unless (yes-or-no-p (format "Push %s of %s to %s? " branch
                                    (plist-get repo :name) remote))
         (user-error "Not pushed"))
       (list (plist-get repo :name) branch remote))))
  (message "%s" (rat-kingdom-git-publish-describe
                 (rat-kingdom-git-publish (rat-kingdom-space-default) repo branch
                                          :remote remote :actor "user"))))

;;;; Reloading

(defconst rat-kingdom--files
  '("rat-kingdom-space" "rat-kingdom-reaction" "rat-kingdom-git"
    "rat-kingdom-mcp" "rat-kingdom-inspector" "rat-kingdom-agent-shell"
    "rat-kingdom-run" "rat-kingdom-workflow" "rat-kingdom-task"
    "rat-kingdom-story" "rat-kingdom-king" "rat-kingdom-fact"
    "rat-kingdom-epic" "rat-kingdom")
  "The package's files, each after the files it requires.")

(defun rat-kingdom--directory ()
  "Return the directory rat-kingdom was loaded from."
  (file-name-directory (or (symbol-file 'rat-kingdom--directory 'defun)
                           (locate-library "rat-kingdom")
                           (error "Cannot tell where rat-kingdom is"))))

(defun rat-kingdom--options-at-default ()
  "Return the rat-kingdom user options whose value is still their default."
  (let (options)
    (mapatoms
     (lambda (symbol)
       (when (and (string-prefix-p "rat-kingdom-" (symbol-name symbol))
                  (default-boundp symbol)
                  (get symbol 'standard-value)
                  (equal (default-value symbol)
                         (ignore-errors
                           (eval (car (get symbol 'standard-value)) t))))
         (push symbol options))))
    options))

(defun rat-kingdom--load-files (directory)
  "Load the source of every rat-kingdom file in DIRECTORY again.
Variables keep their values, as `defvar' does, but a user option that
was at its default takes its new default, and the inspector's keymap is
made again.  Return the files loaded."
  (let ((options (rat-kingdom--options-at-default)))
    (makunbound 'rat-kingdom-inspector-mode-map)
    (prog1 (mapcar (lambda (name)
                     (let ((file (expand-file-name (concat name ".el")
                                                   directory)))
                       (load file nil t t)
                       file))
                   rat-kingdom--files)
      (dolist (option options)
        (let ((value (eval (car (get option 'standard-value)) t)))
          (unless (equal value (default-value option))
            (set-default option value)))))))

;;;###autoload
(defun rat-kingdom-reload ()
  "Load rat-kingdom's source files again, after they have changed.
Run this after pulling or merging changes to rat-kingdom.  What is
running keeps running: agents, the open space, the tool endpoint and
the king.  If `rat-kingdom-mode' is on, the reactions are attached
again, so that new definitions take effect, and the watch is
restarted.  If the reload changed the king's tools or instructions,
the king is restarted in place, keeping its conversation; see
`rat-kingdom-king-refresh' and `rat-kingdom-king-restart-on-reload'."
  (interactive)
  (let* ((directory (rat-kingdom--directory))
         (files (rat-kingdom--load-files directory))
         (king nil))
    (when rat-kingdom-mode
      (let ((space (rat-kingdom-space-default)))
        (rat-kingdom-reaction-detach space)
        (rat-kingdom-reaction-attach space))
      (rat-kingdom--start-watch))
    (when (rat-kingdom-run-live-p rat-kingdom-king-id)
      (setq king (rat-kingdom-king-refresh (rat-kingdom-space-default))))
    (message "rat-kingdom: reloaded %d files from %s%s%s"
             (length files) (abbreviate-file-name directory)
             (if rat-kingdom-mode "; reactions attached again" "")
             (pcase king
               ('restarted "; the king's tools or instructions changed, so \
its session was restarted in place, keeping the conversation")
               ('deferred "; the king's tools or instructions changed: it \
will be restarted in place when it next ends a turn, or run M-x \
rat-kingdom-king-restart once it is idle")
               ('changed "; the king's tools or instructions changed: M-x \
rat-kingdom-king-restart gives them to it once it is idle")
               (_ "")))))

(provide 'rat-kingdom)
;;; rat-kingdom.el ends here
