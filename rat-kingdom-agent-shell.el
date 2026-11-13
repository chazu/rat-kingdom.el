;;; rat-kingdom-agent-shell.el --- Run agents in agent-shell -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Chaz Straney

;; Author: Chaz Straney <chaz.straney@gmail.com>
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;;; Commentary:

;; The backend that runs each agent as an agent-shell buffer, which
;; speaks the Agent Client Protocol to Claude Code.  Every use of
;; agent-shell is in this file, because two of the things used,
;; `agent-shell--start' and `agent-shell--state', are internal to it.
;;
;; agent-shell is not a dependency of the package.  It is loaded when the
;; first agent is started, and that fails with a clear error without it.
;;
;; Each run's shell is given the rat-kingdom tool endpoint with the run's
;; own token, ahead of the servers in `agent-shell-mcp-servers'.  Requests
;; to use rat-kingdom's tools are approved without asking.

;;; Code:

(require 'cl-lib)
(require 'map)
(require 'seq)
(require 'rat-kingdom-space)
(require 'rat-kingdom-mcp)

(defvar agent-shell-mcp-servers)
(defvar agent-shell-cwd-function)
(defvar agent-shell-prefer-viewport-interaction)
(defvar agent-shell-permission-responder-function)
(defvar agent-shell--state)
(declare-function agent-shell--start "agent-shell")
(declare-function agent-shell-insert "agent-shell")
(declare-function agent-shell-subscribe-to "agent-shell")
(declare-function agent-shell-anthropic-make-claude-code-config
                  "agent-shell-anthropic")
(declare-function rat-kingdom-run-exited "rat-kingdom-run")
(declare-function rat-kingdom-run-update "rat-kingdom-run")

(defun rat-kingdom-agent-shell--servers (token)
  "Return the MCP servers for a run holding TOKEN.
The rat-kingdom endpoint comes first, then the user's own servers."
  (cons `((name . ,rat-kingdom-mcp-server-name)
          (type . "http")
          (headers . [])
          (url . ,(rat-kingdom-mcp-url token)))
        (seq-remove (lambda (server)
                      (equal (alist-get 'name server)
                             rat-kingdom-mcp-server-name))
                    (bound-and-true-p agent-shell-mcp-servers))))

(defun rat-kingdom-agent-shell--approve (permission)
  "Approve PERMISSION if it asks to use a rat-kingdom tool.
Return non-nil if it was answered."
  (let ((title (format "%s" (map-elt (map-elt permission :tool-call) :title))))
    (when (string-search (format "mcp__%s__" rat-kingdom-mcp-server-name) title)
      (when-let* ((choice (seq-find
                           (lambda (option)
                             (equal (map-elt option :kind) "allow_once"))
                           (map-elt permission :options))))
        (funcall (map-elt permission :respond) (map-elt choice :option-id))
        t))))

(defun rat-kingdom-agent-shell-start (run prompt)
  "Start an agent-shell for RUN, send it PROMPT and return its buffer."
  (unless (require 'agent-shell nil t)
    (error "Starting an agent needs the agent-shell package"))
  (require 'agent-shell-anthropic)
  (let* ((id (plist-get run :id))
         (worktree (file-name-as-directory (plist-get run :worktree)))
         (token (rat-kingdom-mcp-grant id (intern (plist-get run :role))))
         (config (append
                  (list (cons :buffer-name (format "rat %s" id))
                        (cons :mcp-servers
                              (rat-kingdom-agent-shell--servers token)))
                  (agent-shell-anthropic-make-claude-code-config)))
         (buffer (with-temp-buffer
                   (setq default-directory worktree)
                   (let ((agent-shell-cwd-function (lambda () worktree)))
                     (agent-shell--start :config config :no-focus t
                                         :new-session t
                                         :session-strategy 'new))))
         (sent nil))
    (with-current-buffer buffer
      (let ((previous (bound-and-true-p
                       agent-shell-permission-responder-function)))
        (setq-local agent-shell-permission-responder-function
                    (lambda (permission)
                      (or (rat-kingdom-agent-shell--approve permission)
                          (and (functionp previous)
                               (funcall previous permission)))))))
    (agent-shell-subscribe-to
     :shell-buffer buffer :event 'prompt-ready
     :on-event
     (lambda (_event)
       (unless sent
         (setq sent t)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (when-let* ((session (map-nested-elt agent-shell--state
                                                  '(:session :id))))
               (rat-kingdom-run-update (rat-kingdom-space-default) id
                                       :session-id session))
             (let ((agent-shell-prefer-viewport-interaction nil))
               (agent-shell-insert :text prompt :submit t :no-focus t
                                   :shell-buffer buffer)))))))
    (agent-shell-subscribe-to
     :shell-buffer buffer :event 'clean-up
     :on-event (lambda (_event) (rat-kingdom-run-exited id)))
    buffer))

(defun rat-kingdom-agent-shell-stop (buffer)
  "Stop the agent in BUFFER by killing the buffer."
  (when (buffer-live-p buffer)
    (let ((kill-buffer-query-functions nil))
      (kill-buffer buffer))))

(provide 'rat-kingdom-agent-shell)
;;; rat-kingdom-agent-shell.el ends here
