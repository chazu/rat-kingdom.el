;;; rat-kingdom-agent-shell.el --- Run agents in agent-shell -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Chaz Straney

;; Author: Chaz Straney <chaz.straney@gmail.com>
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;;; Commentary:

;; The backend that runs each agent as an agent-shell buffer, which
;; speaks the Agent Client Protocol to Claude Code or to Codex.  Every
;; use of agent-shell is in this file, because two of the things used,
;; `agent-shell--start' and `agent-shell--state', are internal to it.
;;
;; agent-shell is not a dependency of the package.  It is loaded when the
;; first agent is started, and that fails with a clear error without it.
;; agent-shell-anthropic or agent-shell-openai is loaded only when an
;; agent of its kind is started.
;;
;; Which agent a run gets is its `:agent', the name of an agent kind:
;; "claude" or "codex" built in, more with
;; `rat-kingdom-agent-shell-define-agent'.  A run that names none, such as
;; the king's, gets Claude Code.  A story's workers run the agent the
;; story was started with, `rat-kingdom-default-agent' unless it named
;; one.  Codex runs in its full-access mode, approval policy never and
;; no sandbox, the equivalent of `codex --yolo'.
;;
;; Each run's shell is given the rat-kingdom tool endpoint with the run's
;; own token, ahead of the servers in `agent-shell-mcp-servers'.  Requests
;; to use rat-kingdom's tools are approved without asking.
;;
;; No agent rat-kingdom starts can push, in three layers (DESIGN.md,
;; section 12):
;;
;; 1. The agent's process gets Git configuration in its environment,
;;    through GIT_CONFIG_COUNT, that rewrites every push URL to one Git
;;    cannot use.  This holds whatever the agent's permission mode, and
;;    `git push --no-verify' too.  Nothing is written to any Git config
;;    file, so the user's own pushes are not affected.  It is the same
;;    for every agent kind, and for Codex it is the only layer.
;; 2. The session is started with Claude tool rules that deny `git push'
;;    and `gh'.  Deny rules apply in every permission mode.  Only
;;    Claude's adapter reads them.
;; 3. A permission request to run such a command is refused here,
;;    before any other responder sees it.  Codex in full-access mode
;;    never asks.
;;
;; Pushing is left to the king's `publish' tool, which runs Git in Emacs
;; itself (rat-kingdom-git.el).

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
(declare-function shell-maker-busy "shell-maker")
(declare-function agent-shell-anthropic-make-claude-code-config
                  "agent-shell-anthropic")
(declare-function agent-shell-openai-make-codex-config "agent-shell-openai")
(declare-function rat-kingdom-run-exited "rat-kingdom-run")
(declare-function rat-kingdom-run-update "rat-kingdom-run")
(defvar rat-kingdom-run-idle-functions)

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

;;;; Agent kinds

(defcustom rat-kingdom-default-agent 'claude
  "The agent a story's workers run when the story names none.
A name from `rat-kingdom-agent-shell-agents': `claude' for Claude Code
or `codex' for OpenAI Codex, in full-access mode.  It is read when a
story starts, and the story keeps the agent it was given.  The king is
always Claude Code."
  :type '(choice (const :tag "Claude Code" claude)
                 (const :tag "Codex, in full-access mode" codex)
                 (symbol :tag "Another defined agent kind"))
  :group 'rat-kingdom)

(defconst rat-kingdom-agent-shell-fallback-agent "claude"
  "The agent of a run that names none.
That is the king's, and any run recorded before agents could be chosen.")

(defconst rat-kingdom-agent-shell-codex-mode "agent-full-access"
  "The codex-acp session mode Codex runs in: approval never, no sandbox.
It is what `codex --yolo' does.  codex-acp's other modes are
read-only, workspace-write and agent.")

(defconst rat-kingdom-agent-shell-builtin-agents
  '((claude . rat-kingdom-agent-shell-claude-config)
    (codex . rat-kingdom-agent-shell-codex-config))
  "The agent kinds built in, as an alist from name to config function.
Each function takes no arguments and returns an agent-shell config.")

(defvar rat-kingdom-agent-shell--defined-agents nil
  "Agent kinds defined by `rat-kingdom-agent-shell-define-agent'.
An alist like `rat-kingdom-agent-shell-builtin-agents', whose entries
come before, and hide, built-in ones of the same name.")

(defun rat-kingdom-agent-shell-define-agent (name function)
  "Define the agent kind NAME, a symbol, whose config FUNCTION returns.
FUNCTION takes no arguments and returns an agent-shell config, such as
`agent-shell-anthropic-make-claude-code-config' does.  A kind of the
same name, built in or defined before, is replaced."
  (setf (alist-get name rat-kingdom-agent-shell--defined-agents) function)
  name)

(defun rat-kingdom-agent-shell-agents ()
  "Return every agent kind, as an alist from name to config function.
Defined kinds come first; a built-in one they replace is left out."
  (append rat-kingdom-agent-shell--defined-agents
          (cl-remove-if (lambda (entry)
                          (assq (car entry)
                                rat-kingdom-agent-shell--defined-agents))
                        rat-kingdom-agent-shell-builtin-agents)))

(defun rat-kingdom-agent-names ()
  "Return the names of the agent kinds, as strings."
  (mapcar (lambda (entry) (symbol-name (car entry)))
          (rat-kingdom-agent-shell-agents)))

(defun rat-kingdom-agent-name (agent)
  "Return the agent AGENT, a string or symbol, as a known agent's name.
Nil and the empty string mean `rat-kingdom-default-agent'.  Signal an
error naming the known agents if there is no such agent."
  (let ((name (format "%s" (if (or (null agent) (equal agent ""))
                               rat-kingdom-default-agent
                             agent))))
    (if (member name (rat-kingdom-agent-names))
        name
      (error "There is no agent called %s; there are: %s"
             name (string-join (rat-kingdom-agent-names) ", ")))))

(defun rat-kingdom-agent-shell--override (config &rest pairs)
  "Return CONFIG with the entries of the property list PAIRS set.
CONFIG is an agent config, an alist; it is not changed."
  (let ((keys (cl-loop for (key) on pairs by #'cddr collect key)))
    (append (cl-loop for (key value) on pairs by #'cddr
                     collect (cons key value))
            (cl-remove-if (lambda (entry) (memq (car-safe entry) keys))
                          config))))

(defun rat-kingdom-agent-shell-claude-config ()
  "Return the agent-shell config for Claude Code."
  (require 'agent-shell-anthropic)
  (agent-shell-anthropic-make-claude-code-config))

(defun rat-kingdom-agent-shell-codex-config ()
  "Return the agent-shell config for Codex, in full-access mode.
The session is put in `rat-kingdom-agent-shell-codex-mode' twice over:
the config's default session mode is it, which agent-shell sets once
the session is up, and the client's environment has INITIAL_AGENT_MODE
set to it, which codex-acp reads when it makes, loads or resumes a
session.  `agent-shell-openai-default-session-mode-id' is left alone."
  (require 'agent-shell-openai)
  (let* ((config (agent-shell-openai-make-codex-config))
         (maker (map-elt config :client-maker)))
    (rat-kingdom-agent-shell--override
     config
     :default-session-mode-id (lambda () rat-kingdom-agent-shell-codex-mode)
     :client-maker
     (lambda (buffer)
       (let ((client (funcall maker buffer)))
         (setf (map-elt client :environment-variables)
               (cons (concat "INITIAL_AGENT_MODE="
                             rat-kingdom-agent-shell-codex-mode)
                     (map-elt client :environment-variables)))
         client)))))

(defun rat-kingdom-agent-shell-config (agent)
  "Return the agent-shell config of the agent kind AGENT, a name.
Nil means `rat-kingdom-agent-shell-fallback-agent'."
  (let* ((name (intern (rat-kingdom-agent-name
                        (or agent rat-kingdom-agent-shell-fallback-agent))))
         (function (alist-get name (rat-kingdom-agent-shell-agents))))
    (funcall function)))

;;;; Keeping agents from pushing

(defconst rat-kingdom-agent-shell-push-block "rat-kingdom-refuses-to-push::"
  "What every push URL in an agent's session is rewritten to begin with.
Git reads the part before \"::\" as the name of a remote helper,
git-remote-rat-kingdom-refuses-to-push, which does not exist, so the
push fails and the error names rat-kingdom.  No path is involved, so
no relative remote can make the rewritten URL point somewhere real.")

(defconst rat-kingdom-agent-shell-push-prefixes
  '("https://" "http://" "ssh://" "git+ssh://" "ssh+git://" "git://"
    "file://" "git@" "/" "./" "../" "~" "")
  "The URL prefixes whose pushes are rewritten in an agent's session.
The empty prefix alone matches every URL, host:path forms and relative
paths included.  The others are kept in case a Git ignores an empty
one.  Git does not rewrite the URL of a remote with an explicit
pushurl; layers 2 and 3 cover that case.")

(defconst rat-kingdom-agent-shell-denied-tools
  ["Bash(git push:*)" "Bash(git -C * push:*)" "Bash(gh:*)"]
  "Claude tool rules every agent's session is started with as denied.
Deny rules apply in every permission mode, bypass included.")

(defun rat-kingdom-agent-shell-environment-entries (run-id &optional environment)
  "Return the variables an agent's session for RUN-ID adds to ENVIRONMENT.
ENVIRONMENT is a list like `process-environment', which it defaults
to.  The variables are, first, GIT_CONFIG_COUNT and the
GIT_CONFIG_KEY_n and GIT_CONFIG_VALUE_n pairs that make Git rewrite
every push URL to `rat-kingdom-agent-shell-push-block'.  They are
numbered after the pairs ENVIRONMENT already has, which are kept.
Then GH_PROMPT_DISABLED, and RAT_KINGDOM_RUN with RUN-ID, so that
tools can tell they run in a managed session."
  (let* ((environment (or environment process-environment))
         (given (getenv-internal "GIT_CONFIG_COUNT" environment))
         (index (if (and given (string-match-p "\\`[0-9]+\\'" given))
                    (string-to-number given)
                  0))
         (pairs nil))
    (dolist (prefix rat-kingdom-agent-shell-push-prefixes)
      (push (format "GIT_CONFIG_KEY_%d=url.%s%s.pushInsteadOf"
                    index rat-kingdom-agent-shell-push-block prefix)
            pairs)
      (push (format "GIT_CONFIG_VALUE_%d=%s" index prefix) pairs)
      (cl-incf index))
    (append (list (format "GIT_CONFIG_COUNT=%d" index)
                  "GH_PROMPT_DISABLED=1"
                  (format "RAT_KINGDOM_RUN=%s" run-id))
            (nreverse pairs))))

(defun rat-kingdom-agent-shell-environment (run-id &optional environment)
  "Return ENVIRONMENT as an agent's session for RUN-ID sees it.
ENVIRONMENT defaults to `process-environment'.  See
`rat-kingdom-agent-shell-environment-entries'."
  (let ((environment (or environment process-environment)))
    (append (rat-kingdom-agent-shell-environment-entries run-id environment)
            environment)))

(defun rat-kingdom-agent-shell--session-meta (meta)
  "Return the session META with `rat-kingdom-agent-shell-denied-tools' added.
META is an agent config's `:session-meta'; it is not changed.  The
rules go to `_meta.claudeCode.options.disallowedTools', which Claude's
ACP adapter hands to Claude Code."
  (let* ((claude (alist-get 'claudeCode meta))
         (options (alist-get 'options claude))
         (denied (seq-uniq (append (alist-get 'disallowedTools options)
                                   rat-kingdom-agent-shell-denied-tools
                                   nil))))
    (cons (cons 'claudeCode
                (cons (cons 'options
                            (cons (cons 'disallowedTools (vconcat denied))
                                  (cl-remove 'disallowedTools options :key #'car)))
                      (cl-remove 'options claude :key #'car)))
          (cl-remove 'claudeCode meta :key #'car))))

(defun rat-kingdom-agent-shell--guard (config run-id)
  "Return the agent CONFIG with the push guards for RUN-ID.
Its client is given `rat-kingdom-agent-shell-environment-entries' as
environment variables, which the client's process is started with,
and its session meta the denied tools.  CONFIG is not changed.  It is
the same for every agent kind: a Codex session's meta carries the
Claude rules too, which codex-acp ignores."
  (let ((maker (map-elt config :client-maker)))
    (append
     (list (cons :client-maker
                 (lambda (buffer)
                   (let* ((client (funcall maker buffer))
                          (own (map-elt client :environment-variables)))
                     (setf (map-elt client :environment-variables)
                           (append (rat-kingdom-agent-shell-environment-entries
                                    run-id (append own process-environment))
                                   own))
                     client)))
           (cons :session-meta (rat-kingdom-agent-shell--session-meta
                                (map-elt config :session-meta))))
     (cl-remove-if (lambda (entry)
                     (memq (car-safe entry) '(:client-maker :session-meta)))
                   config))))

(defun rat-kingdom-agent-shell--shell-commands (text)
  "Split the shell TEXT, roughly, into simple commands.
Return a list of commands, each a list of words.  Quotes and
backslashes are honoured.  A newline, `;', `&', `|', a parenthesis, a
backquote and `$(' end a command."
  (let ((commands nil) (words nil) (word nil) (started nil) (quote nil)
        (i 0) (n (length text)))
    (cl-flet* ((end-word ()
                 (when started
                   (push (concat (nreverse word)) words)
                   (setq word nil started nil)))
               (end-command ()
                 (end-word)
                 (when words
                   (push (nreverse words) commands)
                   (setq words nil))))
      (while (< i n)
        (let ((c (aref text i)))
          (cond
           ((eq quote ?\')
            (if (eq c ?\') (setq quote nil) (push c word)))
           ((eq quote ?\")
            (cond ((eq c ?\") (setq quote nil))
                  ((and (eq c ?\\) (< (1+ i) n))
                   (cl-incf i)
                   (push (aref text i) word))
                  (t (push c word))))
           ((memq c '(?\' ?\")) (setq quote c started t))
           ((eq c ?\\)
            (cl-incf i)
            (when (< i n)
              (push (aref text i) word)
              (setq started t)))
           ((memq c '(?\s ?\t)) (end-word))
           ((memq c '(?\n ?\; ?& ?| ?\( ?\) ?`)) (end-command))
           ((and (eq c ?$) (< (1+ i) n) (eq (aref text (1+ i)) ?\())
            (end-command)
            (cl-incf i))
           (t (push c word) (setq started t))))
        (cl-incf i))
      (end-command))
    (nreverse commands)))

(defconst rat-kingdom-agent-shell--prefix-words
  '("env" "sudo" "doas" "command" "builtin" "exec" "nohup" "time" "nice"
    "timeout" "xargs" "then" "do" "else" "if" "elif" "while" "until" "!" "{")
  "Words that can come before the name of the command a shell runs.")

(defconst rat-kingdom-agent-shell--git-options-with-argument
  '("-C" "-c" "--git-dir" "--work-tree" "--namespace" "--super-prefix"
    "--config-env")
  "Git's global options that take the next word as their argument.")

(defun rat-kingdom-agent-shell--git-pushes-p (words)
  "Return non-nil if WORDS, the arguments after `git', run a push."
  (while (and words (string-prefix-p "-" (car words)))
    (when (member (car words) rat-kingdom-agent-shell--git-options-with-argument)
      (pop words))
    (pop words))
  (member (car words) '("push" "send-pack")))

(defun rat-kingdom-agent-shell--publishes-p (words depth)
  "Return non-nil if the simple command WORDS pushes or runs gh.
DEPTH is how many shells deep WORDS is."
  (let ((all words))
    ;; Skip assignments, and the words that come before a command's name.
    (while (and words
                (or (string-match-p "\\`[A-Za-z_][A-Za-z0-9_]*=" (car words))
                    (member (car words) rat-kingdom-agent-shell--prefix-words)
                    (and (not (eq words all))
                         (string-match-p "\\`\\(-.*\\|[0-9.]+[smhd]?\\)\\'"
                                         (car words)))))
      (pop words))
    (let ((name (and words (file-name-nondirectory (car words)))))
      (or (equal name "gh")
          ;; git anywhere, so that `xargs -n1 git push' is seen too.
          (cl-loop for tail on all
                   thereis (and (equal (file-name-nondirectory (car tail)) "git")
                                (rat-kingdom-agent-shell--git-pushes-p
                                 (cdr tail))))
          (and (member name '("sh" "bash" "zsh" "dash" "ksh"))
               (cl-loop for tail on (cdr words)
                        thereis (and (string-match-p "\\`-[[:alpha:]]*c[[:alpha:]]*\\'"
                                                     (car tail))
                                     (cadr tail)
                                     (rat-kingdom-agent-shell-publishing-command-p
                                      (cadr tail) (1+ depth)))))
          (and (equal name "eval")
               (rat-kingdom-agent-shell-publishing-command-p
                (string-join (cdr words) " ") (1+ depth)))))))

(defun rat-kingdom-agent-shell-publishing-command-p (text &optional depth)
  "Return non-nil if the shell command TEXT would push or run gh.
This is a guard, not a parser: it sees `git push' with Git's global
options before it, after `cd x &&', in a pipe, in `$(...)', and in
`sh -c'.  DEPTH is how many shells deep TEXT is."
  (let ((depth (or depth 0)))
    (and (< depth 4)
         (or (cl-some (lambda (words)
                        (rat-kingdom-agent-shell--publishes-p words depth))
                      (rat-kingdom-agent-shell--shell-commands text))
             ;; A command substituted inside double quotes.
             (let ((start 0) (found nil))
               (while (and (not found)
                           (string-match "\\$(\\|`" text start))
                 (setq start (match-end 0))
                 (setq found (when-let* ((words (car (rat-kingdom-agent-shell--shell-commands
                                                      (substring text start)))))
                               (rat-kingdom-agent-shell--publishes-p
                                words (1+ depth)))))
               found)))))

(defun rat-kingdom-agent-shell--command (permission)
  "Return the shell command PERMISSION asks to run, or nil."
  (let* ((call (map-elt permission :tool-call))
         (input (map-elt call :raw-input))
         (command (and (mapp input)
                       (or (map-elt input 'command) (map-elt input "command")))))
    (cond ((stringp command) command)
          ((equal (map-elt call :kind) "execute")
           (format "%s" (or (map-elt call :title) ""))))))

(defun rat-kingdom-agent-shell--refuse (permission)
  "Refuse PERMISSION if it asks to run a command that pushes or runs gh.
Return `refused' if it was refused, `unanswered' if it should have
been but offers no way to refuse, and nil if it is none of these."
  (when-let* ((command (rat-kingdom-agent-shell--command permission))
              ((rat-kingdom-agent-shell-publishing-command-p command)))
    (let* ((options (map-elt permission :options))
           (choice (or (seq-find (lambda (option)
                                   (equal (map-elt option :kind) "reject_once"))
                                 options)
                       (seq-find (lambda (option)
                                   (string-prefix-p
                                    "reject" (format "%s" (map-elt option :kind))))
                                 options))))
      (if (not choice)
          'unanswered
        (funcall (map-elt permission :respond) (map-elt choice :option-id))
        'refused))))

(defun rat-kingdom-agent-shell--respond (permission previous)
  "Answer PERMISSION in a rat-kingdom session, or leave it to PREVIOUS.
A command that pushes or runs gh is refused; a rat-kingdom tool is
approved.  Anything else goes to PREVIOUS, the responder the session
had before, if it is a function.  Return non-nil if it was answered."
  (pcase (rat-kingdom-agent-shell--refuse permission)
    ('refused t)
    ;; Show it to the user rather than let another responder approve it.
    ('unanswered nil)
    (_ (or (rat-kingdom-agent-shell--approve permission)
           (and (functionp previous)
                (funcall previous permission))))))

(defun rat-kingdom-agent-shell--buffer-name (run)
  "Return the name for the shell buffer of RUN."
  (if (equal (plist-get run :role) "rat")
      (format "rat %s" (plist-get run :id))
    (plist-get run :id)))

(defun rat-kingdom-agent-shell-run-config (run token)
  "Return the agent config for RUN, whose tool endpoint token is TOKEN.
It is the config of RUN's `:agent', with the push guards, the run's
buffer name and its MCP servers."
  (rat-kingdom-agent-shell--override
   (rat-kingdom-agent-shell--guard
    (rat-kingdom-agent-shell-config (plist-get run :agent))
    (plist-get run :id))
   :buffer-name (rat-kingdom-agent-shell--buffer-name run)
   :mcp-servers (rat-kingdom-agent-shell--servers token)))

(defun rat-kingdom-agent-shell-start (run prompt)
  "Start an agent-shell for RUN, send it PROMPT and return its buffer.
The agent is RUN's `:agent'; see `rat-kingdom-agent-shell-config'.  If
RUN has `:resume', take that session up again, with the same agent."
  (unless (require 'agent-shell nil t)
    (error "Starting an agent needs the agent-shell package"))
  (let* ((id (plist-get run :id))
         (worktree (file-name-as-directory (plist-get run :worktree)))
         (token (rat-kingdom-mcp-grant id (intern (plist-get run :role))))
         (config (rat-kingdom-agent-shell-run-config run token))
         (buffer (with-temp-buffer
                   (setq default-directory worktree)
                   (let ((agent-shell-cwd-function (lambda () worktree)))
                     (if-let* ((session (plist-get run :resume)))
                         (agent-shell--start :config config :no-focus t
                                             :new-session t
                                             :session-id session)
                       (agent-shell--start :config config :no-focus t
                                           :new-session t
                                           :session-strategy 'new)))))
         (sent nil))
    (with-current-buffer buffer
      (let ((previous (bound-and-true-p
                       agent-shell-permission-responder-function)))
        (setq-local agent-shell-permission-responder-function
                    (lambda (permission)
                      (rat-kingdom-agent-shell--respond permission
                                                        previous)))))
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
     :shell-buffer buffer :event 'turn-complete
     :on-event (lambda (_event)
                 ;; Not from inside agent-shell's own handling of the turn.
                 (run-at-time 0 nil #'run-hook-with-args
                              'rat-kingdom-run-idle-functions id)))
    (agent-shell-subscribe-to
     :shell-buffer buffer :event 'clean-up
     :on-event (lambda (_event) (rat-kingdom-run-exited id)))
    buffer))

(defun rat-kingdom-agent-shell--input-pending-p ()
  "Return non-nil if the current shell has text typed but not sent."
  (when-let* ((process (get-buffer-process (current-buffer)))
              (mark (process-mark process))
              ((marker-position mark)))
    (not (string-blank-p
          (buffer-substring-no-properties mark (point-max))))))

(defun rat-kingdom-agent-shell-busy-p (buffer)
  "Return non-nil if the agent in BUFFER is in a turn or has input not sent.
Input not sent is text the user has typed in BUFFER.  A buffer that is
gone is not busy."
  (and (buffer-live-p buffer)
       (with-current-buffer buffer
         (or (ignore-errors (shell-maker-busy))
             (rat-kingdom-agent-shell--input-pending-p)))))

(defun rat-kingdom-agent-shell-send (buffer text)
  "Give the agent in BUFFER TEXT as its next prompt.
Return non-nil if it was sent.  Nothing is sent, and nil is returned,
while the agent is in a turn, has no session yet, or the user has
typed something there that is not yet sent."
  (when (and (buffer-live-p buffer)
             (not (rat-kingdom-agent-shell-busy-p buffer)))
    (with-current-buffer buffer
      (when (map-nested-elt agent-shell--state '(:session :id))
        (let ((agent-shell-prefer-viewport-interaction nil))
          (agent-shell-insert :text text :submit t :no-focus t
                              :shell-buffer buffer))
        t))))

(defun rat-kingdom-agent-shell-stop (buffer)
  "Stop the agent in BUFFER by killing the buffer."
  (when (buffer-live-p buffer)
    (let ((kill-buffer-query-functions nil))
      (kill-buffer buffer))))

(provide 'rat-kingdom-agent-shell)
;;; rat-kingdom-agent-shell.el ends here
