;;; rat-kingdom-consul.el --- A rat the user talks to about one project -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Chaz Straney

;; Author: Chaz Straney <chaz.straney@gmail.com>
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A consul is a rat the user asks for in one registered repository, to
;; talk with about that project directly while the king is busy
;; (DESIGN.md, section 9).  The user talks to it in its own agent-shell
;; buffer.  The king does not drive it, review its turns or relay
;; messages to it, and no engine news goes to it: it has no story and
;; no epic, so nothing routes to it, and the king's tools that act on
;; stories never reach it.
;;
;; A consul is a run like a foreman's, with an id C-XXXX, the role
;; `consul', and `:name', `:topic', `:branch', `:worktree', `:target'
;; and `:started' in its record.  It works in a worktree of its own,
;; cut from the repository's target on a new branch named by the
;; configuration's :git :branch with the id consul-NAME-XXXX, guarded
;; from pushes like any rats/* branch; it never touches the user's
;; checkout.  It runs the agent it is started with, else the
;; configuration's `:agents' `:consul' for its repository, which is
;; `rat-kingdom-default-agent' unless configured, and the model it is
;; started with, else `rat-kingdom-worker-model'.
;;
;; Its tools are `write_doc', `read_doc' and `note_fact'.  Its docs are
;; approved when written (rat-kingdom-doc.el).  It may commit in its
;; worktree when the user asks.
;;
;; The king starts one with `consul_start' and ends one with
;; `consul_dismiss'; the user can with `rat-kingdom-consul-start' and
;; `rat-kingdom-consul-dismiss', which is bound in the consul's buffer.
;; Dismissing a consul stops its agent.  If its branch has commits the
;; target lacks, its work becomes a story in the repository's workflow,
;; at the place a worker's finished work goes
;; (`rat-kingdom-story-start-from-branch'), so the king reviews and
;; merges it as usual; otherwise its worktree and branch are removed.
;; Uncommitted changes stop a dismissal, unless it is forced, which
;; commits them first.  Its record is then archived.
;;
;; A consul lasts until it is dismissed.  One that Emacs cut off is
;; taken up again, in the same session, by `rat-kingdom-consul-reconcile'
;; when `rat-kingdom-mode' starts, and `rat-kingdom-consul-show' shows
;; its buffer, starting it again if its agent is gone.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'rat-kingdom-space)
(require 'rat-kingdom-reaction)
(require 'rat-kingdom-git)
(require 'rat-kingdom-mcp)
(require 'rat-kingdom-run)
(require 'rat-kingdom-agent-shell)
(require 'rat-kingdom-config)
(require 'rat-kingdom-story)
(require 'rat-kingdom-king)
(require 'rat-kingdom-fact)
(require 'rat-kingdom-doc)

(defvar rat-kingdom-mode)
(declare-function rat-kingdom-mode "rat-kingdom")

(defconst rat-kingdom-consul-id-prefix "C-"
  "The start of a consul's id; four hex digits follow.")

(defcustom rat-kingdom-consul-instructions
  "You are {name}, a consul for the repository {repo}, in a rat-kingdom \
swarm running inside the user's Emacs. The user will talk with you directly \
about this project, in your own buffer, while the king, the agent that runs \
the swarm, is busy with other work. The king does not read this \
conversation or pass messages to you.{topic}

Your workspace:
- Your worktree is {worktree}, on your own branch {branch}, cut from \
{target}. Both are yours alone.
- The user's own checkout of {repo} is {checkout}. Never edit it.

What to do:
- Explore and explain the code, answer the user's questions, and propose \
designs.
- Write docs with the write_doc tool of the rat-kingdom server when the \
user asks, or when a discussion reaches a decision worth keeping. Make each \
doc stand on its own: its readers know nothing of this conversation. Every \
later worker in {repo} is told of your docs. Read a doc with read_doc.
- When the user asks you to, change code and commit it in your worktree, \
on your branch. When the user dismisses you, the commits on your branch \
become a story, which the king reviews and merges as usual.
- Record with note_fact anything durable and non-obvious a later worker in \
{repo} would want to know.

Rules:
- Never push, with git, gh or any other way: pushing is blocked in your \
session and will fail, so do not try to work around it.
- Never start stories or epics, and do not try to direct the king or its \
workers. If the user wants work done by the swarm, tell them to ask the king.
- Commit or remove what you change before the user is done: uncommitted \
changes stop a dismissal.
- When the user is done, they dismiss you. Until then, wait for the user.

Your tools are those of the rat-kingdom server: {tools}."
  "What a consul is told when its session starts.
In it, {name} is replaced by the consul's name, {repo} by its
repository, {topic} by a sentence naming its topic, or nothing,
{worktree}, {branch} and {target} by its worktree, its branch and the
branch that was cut from, {checkout} by the user's checkout and {tools}
by the names of the consul's tools."
  :type 'string
  :group 'rat-kingdom)

;;;; Consuls

(defun rat-kingdom-consul--used-p (space id)
  "Return non-nil if ID names a run in SPACE, live or archived."
  (or (rat-kingdom-run-get space id)
      (sqlite-select (rat-kingdom-space-db space)
                     "SELECT 1 FROM archive WHERE category = 'run'
                      AND identity = ? LIMIT 1"
                     (list id))))

(defun rat-kingdom-consul--new-id (space)
  "Return a consul id not in use in SPACE, live or archived."
  (let (id)
    (while (or (null id) (rat-kingdom-consul--used-p space id))
      (setq id (format "%s%04x" rat-kingdom-consul-id-prefix (random 65536))))
    id))

(defun rat-kingdom-consul-list (space)
  "Return the run records of the consuls in SPACE, oldest first.
A consul is listed until it is dismissed."
  (sort (cl-remove-if-not (lambda (run)
                            (equal (plist-get run :role) "consul"))
                          (rat-kingdom-run-list space))
        (lambda (a b) (< (or (plist-get a :started) 0)
                         (or (plist-get b :started) 0)))))

(defun rat-kingdom-consul-get (space id)
  "Return the run record of the consul ID in SPACE, or nil.
ID may also be the consul's name, as Pip, or its display name."
  (let ((id (string-trim (format "%s" (or id "")))))
    (cl-find-if (lambda (run)
                  (or (equal (plist-get run :id) id)
                      (equal (plist-get run :name) id)
                      (equal (rat-kingdom-run-display-name run) id)))
                (rat-kingdom-consul-list space))))

(defun rat-kingdom-consul--require (space id)
  "Return the run record of the consul ID in SPACE, or signal an error."
  (or (rat-kingdom-consul-get space id)
      (error "There is no consul %s; status lists them" id)))

(defun rat-kingdom-consul--state (run)
  "Return the state of the consul RUN in words, as status shows it."
  (let ((id (plist-get run :id)))
    (cond ((rat-kingdom-run-live-p id)
           (if (rat-kingdom-run-busy-p id) "working" "idle"))
          ((equal (plist-get run :state) "starting") "starting")
          (t (format "%s, not running; rat-kingdom-consul-show starts it \
again" (plist-get run :state))))))

(defun rat-kingdom-consul--ahead (space run)
  "Return how many commits the branch of the consul RUN in SPACE has.
They are the commits its target lacks.  Return 0 if the branch is gone."
  (let ((path (plist-get (rat-kingdom-repo-get space (plist-get run :repo))
                         :path))
        (branch (plist-get run :branch)))
    (if (and path (rat-kingdom-git-ok-p path "rev-parse" "--verify" "--quiet"
                                        (concat "refs/heads/" branch)))
        (string-to-number
         (rat-kingdom-git path "rev-list" "--count"
                          (format "%s..%s" (plist-get run :target) branch)))
      0)))

(defun rat-kingdom-consul--line (space run)
  "Return the line of status that describes the consul RUN in SPACE."
  (let ((now (funcall rat-kingdom-space-now-function))
        (ahead (condition-case nil
                   (rat-kingdom-consul--ahead space run)
                 (error "?"))))
    (format "- %s %s [%s] %s, %s, %s%s; branch %s, %s %s ahead of %s"
            (plist-get run :id) (rat-kingdom-run-display-name run)
            (plist-get run :repo)
            (rat-kingdom-consul--state run)
            (rat-kingdom-king--age
             (round (- now (or (plist-get run :started) now))))
            (or (plist-get run :agent) rat-kingdom-agent-shell-fallback-agent)
            (if-let* ((topic (plist-get run :topic)))
                (format "; topic: %s" topic)
              "")
            (plist-get run :branch)
            ahead (if (equal ahead 1) "commit" "commits")
            (plist-get run :target))))

(defun rat-kingdom-consul-status (space)
  "Return the section of status that lists the consuls in SPACE, or nil.
For `rat-kingdom-king-status-functions'."
  (when-let* ((consuls (rat-kingdom-consul-list space)))
    (concat "Consuls (each talks with the user in its own buffer; you do not \
drive them; consul_dismiss ends one):\n"
            (mapconcat (lambda (run) (rat-kingdom-consul--line space run))
                       consuls "\n"))))

(add-hook 'rat-kingdom-king-status-functions #'rat-kingdom-consul-status)

;;;; What a consul is told

(defun rat-kingdom-consul-instructions (space run)
  "Return `rat-kingdom-consul-instructions' for the consul RUN in SPACE."
  (let ((text rat-kingdom-consul-instructions)
        (topic (plist-get run :topic)))
    (dolist (pair (list (cons "{tools}" (rat-kingdom-king-tool-names 'consul))
                        (cons "{name}" (rat-kingdom-run-display-name run))
                        (cons "{repo}" (plist-get run :repo))
                        (cons "{worktree}" (plist-get run :worktree))
                        (cons "{branch}" (plist-get run :branch))
                        (cons "{target}" (plist-get run :target))
                        (cons "{checkout}"
                              (plist-get (rat-kingdom-repo-get
                                          space (plist-get run :repo))
                                         :path))
                        ;; Last, so that nothing in it is replaced.
                        (cons "{topic}"
                              (if topic
                                  (format "\n\nThe user wants to talk about: %s"
                                          topic)
                                ""))))
      (setq text (string-replace (car pair) (format "%s" (cdr pair)) text)))
    text))

(defun rat-kingdom-consul--prompt (space run resumed)
  "Return the first prompt for the consul RUN in SPACE.
RESUMED is non-nil if its earlier session is being taken up again."
  (if resumed
      (format "[rat-kingdom] Your session was restarted; you are still the \
consul %s for %s, in the worktree %s on the branch %s. Tools you called \
before the restart may need calling again. Wait for the user."
              (rat-kingdom-run-display-name run) (plist-get run :repo)
              (plist-get run :worktree) (plist-get run :branch))
    (concat (rat-kingdom-consul-instructions space run)
            "\n\nSay in a line or two who you are and that you are ready, \
then wait for the user.")))

;;;; Starting

(defun rat-kingdom-consul--branch (space record id name)
  "Return a free branch name for the consul ID called NAME of RECORD in SPACE.
It is made from the configuration's :git :branch, with the id
consul-NAME-XXXX, as rats/consul-pip-3a9c; see
`rat-kingdom-story-branch-name'."
  (let* ((repo (plist-get record :name))
         (format-string (or (plist-get (rat-kingdom-config-get
                                        space :git :repo repo)
                                       :branch)
                            rat-kingdom-config-default-branch-format))
         (name (rat-kingdom-config-branch-name
                format-string
                (format "consul-%s-%s"
                        (rat-kingdom-config-branch-slug name)
                        (rat-kingdom-run-suffix id))
                (concat "consul " name) repo nil)))
    (unless (rat-kingdom-config-git-branch-ok-p name (plist-get record :path))
      (error "The branch name %S, made from the :git :branch %S, is not a \
valid branch name (git check-ref-format --branch); change :git :branch \
with config_set" name format-string))
    (rat-kingdom-story--free-branch (plist-get record :path) name)))

(defun rat-kingdom-consul--launch (space run prompt &optional session)
  "Record the run of the consul RUN in SPACE, to be started with PROMPT.
RUN is a property list of the consul's record: `:id', `:repo',
`:name', `:topic', `:agent', `:model', `:worktree', `:branch',
`:target' and `:started'.  SESSION, if given, is the session to take
up again.  An earlier run of the consul is replaced.  Return the id."
  (let ((id (plist-get run :id)))
    (rat-kingdom-space-with-transaction space
      (rat-kingdom-space-retract space (list 'run :identity id)
                                 :actor "engine")
      (rat-kingdom-run-create space :id id :repo (plist-get run :repo)
                              :role 'consul :name (plist-get run :name)
                              :agent (plist-get run :agent)
                              :model (plist-get run :model)
                              :worktree (plist-get run :worktree)
                              :branch (plist-get run :branch)
                              :target (plist-get run :target)
                              :prompt prompt :resume session)
      (rat-kingdom-run-update space id :topic (plist-get run :topic)
                              :started (plist-get run :started)))
    id))

(cl-defun rat-kingdom-consul-begin (space repo &key topic agent model)
  "Start a consul in SPACE for the registered repository REPO.
TOPIC, if given, is what the user wants to talk about, in a line.
AGENT, a name from `rat-kingdom-agent-names', defaults to the
configuration's `:agents' `:consul' for REPO; MODEL, a Claude model id,
to `rat-kingdom-worker-model'.  Its worktree and branch are made at
once, from REPO's target.  Return the consul's id.  Its agent is
started by the reaction `rat-kingdom-run-launch'."
  (let* ((record (or (rat-kingdom-repo-get space repo)
                     (error "No repository called %s is registered" repo)))
         (path (plist-get record :path))
         (target (rat-kingdom-story-repo-target space repo))
         (agent (rat-kingdom-agent-name
                 (if (or (null agent) (equal agent ""))
                     (plist-get (rat-kingdom-config-get space :agents :repo repo)
                                :consul)
                   agent)))
         (topic (when-let* ((text (and topic (format "%s" topic))))
                  (and (not (string-blank-p text))
                       (replace-regexp-in-string "[\n\t ]+" " "
                                                 (string-trim text)))))
         (model (and (stringp model) (not (string-blank-p model)) model))
         (id (rat-kingdom-consul--new-id space))
         (name (rat-kingdom-run-new-name space))
         (branch (rat-kingdom-consul--branch space record id name))
         (worktree (expand-file-name (format "worktrees/%s/%s" repo id)
                                     rat-kingdom-directory))
         (run (list :id id :repo repo :name name :topic topic :agent agent
                    :model model :worktree worktree :branch branch
                    :target target
                    :started (funcall rat-kingdom-space-now-function))))
    (unless (rat-kingdom-git-ok-p path "rev-parse" "--verify" "--quiet"
                                  (concat "refs/heads/" target))
      (error "%s has no local branch %s to cut a consul's branch from"
             repo target))
    (make-directory (file-name-directory worktree) t)
    (rat-kingdom-git path "worktree" "prune")
    (rat-kingdom-git path "worktree" "add" "-b" branch worktree target)
    (condition-case err
        (progn
          (rat-kingdom-config-push-guard-branch space record branch)
          (rat-kingdom-consul--launch
           space run (rat-kingdom-consul--prompt space run nil)))
      (error
       (ignore-errors
         (rat-kingdom-git path "worktree" "remove" "--force" worktree))
       (ignore-errors (rat-kingdom-git path "branch" "-D" branch))
       (signal (car err) (cdr err))))))

;;;; Its buffer

(defvar-local rat-kingdom-consul--buffer-id nil
  "The id of the consul whose agent runs in this buffer, or nil.")

(defvar-keymap rat-kingdom-consul-mode-map
  :doc "Keymap of `rat-kingdom-consul-mode'."
  "C-c ~ d" #'rat-kingdom-consul-dismiss)

(define-minor-mode rat-kingdom-consul-mode
  "Mark the buffer of a consul, where the user talks to it.
\\<rat-kingdom-consul-mode-map>\\[rat-kingdom-consul-dismiss] dismisses it."
  :lighter " Consul"
  :keymap rat-kingdom-consul-mode-map
  :group 'rat-kingdom)

(defun rat-kingdom-consul--buffer (id)
  "Return the live buffer of the consul ID's agent, or nil.
The buffer is put in `rat-kingdom-consul-mode'."
  (when-let* ((buffer (rat-kingdom-run-handle id))
              ((bufferp buffer))
              ((buffer-live-p buffer)))
    (with-current-buffer buffer
      (setq rat-kingdom-consul--buffer-id id)
      (unless rat-kingdom-consul-mode
        (rat-kingdom-consul-mode 1)))
    buffer))

(defun rat-kingdom-consul--buffer-name (space id)
  "Return the name of the buffer of the consul ID in SPACE."
  (if-let* ((buffer (rat-kingdom-consul--buffer id)))
      (buffer-name buffer)
    (rat-kingdom-agent-shell--buffer-name (rat-kingdom-run-get space id))))

(defun rat-kingdom-consul--on-change (_space op subject)
  "Mark the buffer of a consul whose agent has just started.
OP and SUBJECT are as for `rat-kingdom-space-change-functions'."
  (when-let* (((eq op 'out))
              ((eq (plist-get subject :category) 'run))
              (payload (plist-get subject :payload))
              ((equal (plist-get payload :role) "consul"))
              ((equal (plist-get payload :state) "working")))
    (run-at-time 0 nil #'rat-kingdom-consul--buffer
                 (plist-get subject :identity))))

(add-hook 'rat-kingdom-space-change-functions #'rat-kingdom-consul--on-change)

(defun rat-kingdom-consul-reopen (space id)
  "Start the agent of the consul ID in SPACE again if it is not running.
Its session is taken up again if it had one.  Return its buffer, or
nil if the backend gave none."
  (let ((run (rat-kingdom-consul--require space id)))
    (setq id (plist-get run :id))
    (unless (rat-kingdom-run-live-p id)
      (unless (file-directory-p (plist-get run :worktree))
        (error "The worktree %s of the consul %s is gone; dismiss it"
               (plist-get run :worktree) id))
      (let ((session (plist-get run :session-id)))
        (rat-kingdom-consul--launch
         space run (rat-kingdom-consul--prompt space run session) session))
      (rat-kingdom-reaction-run space))
    (rat-kingdom-consul--buffer id)))

;;;; Dismissing

(defun rat-kingdom-consul--commit-all (worktree message)
  "Commit everything changed in WORKTREE with MESSAGE.
Paths in `rat-kingdom-run-ignored-paths' are left out."
  (apply #'rat-kingdom-git worktree "add" "-A" "--" "."
         (mapcar (lambda (path) (concat ":(exclude)" path))
                 rat-kingdom-run-ignored-paths))
  (rat-kingdom-git worktree "commit" "-q" "--no-verify" "-m" message))

(defun rat-kingdom-consul--story (space run)
  "Make the work on the branch of the consul RUN in SPACE a story.
Return the story's id."
  (let* ((path (plist-get (rat-kingdom-repo-get space (plist-get run :repo))
                          :path))
         (range (format "%s..%s" (plist-get run :target)
                        (plist-get run :branch)))
         (log (rat-kingdom-git path "log" "--reverse" "--format=%h %s" range))
         (first (car (split-string
                      (rat-kingdom-git path "log" "--reverse" "--format=%s"
                                       range)
                      "\n" t)))
         (who (rat-kingdom-run-label run))
         (topic (plist-get run :topic)))
    (rat-kingdom-story-start-from-branch
     space (plist-get run :repo)
     (or topic (format "Consul %s: %s" (rat-kingdom-run-display-name run)
                       first))
     :description (format "Work the consul %s did with the user%s. It is \
committed on this story's branch; if the story comes back to a worker, \
carry on from those commits.\n\nIts commits:\n%s"
                          who
                          (if topic (format ", talking about: %s" topic) "")
                          log)
     :summary (format "Work of the consul %s:\n%s" who log)
     :branch (plist-get run :branch) :worktree (plist-get run :worktree)
     :target (plist-get run :target))))

(defun rat-kingdom-consul-end (space id &optional force)
  "Dismiss the consul ID in SPACE, and return a sentence saying what was done.
Its agent is stopped.  If its branch has commits its target lacks,
they become a story (`rat-kingdom-story-start-from-branch'); otherwise
its worktree and branch are removed.  Uncommitted changes in its
worktree are an error, which leaves the consul running, unless FORCE is
non-nil; then they are committed first, as work in progress.  Its docs
are kept.  Its run record is archived."
  (let* ((run (rat-kingdom-consul--require space id))
         (id (plist-get run :id))
         (repo (plist-get run :repo))
         (path (plist-get (or (rat-kingdom-repo-get space repo)
                              (error "The repository %s is no longer \
registered" repo))
                          :path))
         (worktree (plist-get run :worktree))
         (branch (plist-get run :branch))
         (who (rat-kingdom-run-label run))
         (exists (file-directory-p worktree))
         (dirty (and exists (rat-kingdom-run--dirty-paths worktree))))
    (when (and dirty (not force))
      (error "Not dismissed: the consul %s has uncommitted changes in %s: \
%s. Ask it to commit or remove them, or dismiss it with force, which commits \
them first as work in progress"
             who worktree (string-join dirty ", ")))
    (rat-kingdom-run-stop space id)
    (when dirty
      (rat-kingdom-consul--commit-all
       worktree (format "WIP: uncommitted work of the consul %s" who)))
    (let* ((ahead (rat-kingdom-consul--ahead space run))
           (docs (cl-remove-if-not
                  (lambda (doc) (equal (rat-kingdom-doc--field doc :run) id))
                  (rat-kingdom-doc-list space :repo repo)))
           (answer
            (if (> ahead 0)
                (let* ((story (rat-kingdom-consul--story space run))
                       (token (rat-kingdom-story-get space story)))
                  (format "Dismissed the consul %s.%s Its %d %s on %s became \
the story %s, which starts at %s of the workflow %s, as a worker's finished \
work would: you will be told when it needs your review or is merged."
                          who
                          (if dirty " Its uncommitted changes were committed \
first, as work in progress." "")
                          ahead (if (= ahead 1) "commit" "commits") branch
                          (rat-kingdom-story--title token)
                          (plist-get (plist-get token :payload) :at)
                          (plist-get (plist-get token :payload) :workflow)))
              (when exists
                (rat-kingdom-git path "worktree" "remove" "--force" worktree))
              (when (rat-kingdom-git-ok-p path "rev-parse" "--verify" "--quiet"
                                          (concat "refs/heads/" branch))
                (rat-kingdom-git path "branch" "-D" branch))
              (format "Dismissed the consul %s. It made no commits, so its \
worktree and its branch %s are removed." who branch))))
      (when-let* ((tuple (rat-kingdom-space-rd space (list 'run :identity id))))
        (rat-kingdom-space-archive space (plist-get tuple :id) 'dismiss))
      (concat answer
              (if docs
                  (format " Its docs stay: %s."
                          (mapconcat (lambda (doc) (plist-get doc :identity))
                                     docs ", "))
                "")))))

;;;; Recovery

(defun rat-kingdom-consul-reconcile (space)
  "Take up again in SPACE each consul that an Emacs that stopped cut off.
That is a consul whose run is `interrupted', as
`rat-kingdom-run-reconcile' leaves it, with no agent here.  It is
started again with the same agent and name, taking its session up again
if it had one.  One whose worktree is gone is left as it is.  Return
the ids of the consuls started again."
  (let (ids)
    (dolist (run (rat-kingdom-consul-list space))
      (let ((id (plist-get run :id)))
        (when (and (equal (plist-get run :state) "interrupted")
                   (not (rat-kingdom-run-live-p id)))
          (condition-case err
              (progn
                (unless (file-directory-p (plist-get run :worktree))
                  (error "Its worktree %s is gone" (plist-get run :worktree)))
                (let ((session (plist-get run :session-id)))
                  (rat-kingdom-consul--launch
                   space run (rat-kingdom-consul--prompt space run session)
                   session))
                (push id ids))
            (error
             (message "rat-kingdom: could not take up the consul %s again: %s"
                      id (error-message-string err)))))))
    (nreverse ids)))

;;;; The king's tools for consuls

(defun rat-kingdom-consul-start-answer (space id)
  "Return what `consul_start' answers once the consul ID in SPACE is started.
Its buffer is shown to the user, if it has one."
  (let ((run (rat-kingdom-run-get space id)))
    (when-let* ((buffer (rat-kingdom-consul--buffer id)))
      (display-buffer buffer))
    (format "Started the consul %s for %s, running %s, in the buffer %s, \
shown to the user%s. It works in %s on the branch %s, cut from %s. The user \
talks with it there; you do not drive it, and no news goes to it. When the \
user is done, consul_dismiss ends it."
            (rat-kingdom-run-label run) (plist-get run :repo)
            (plist-get run :agent)
            (rat-kingdom-consul--buffer-name space id)
            (if-let* ((topic (plist-get run :topic)))
                (format ", to talk about: %s" topic)
              "")
            (plist-get run :worktree) (plist-get run :branch)
            (plist-get run :target))))

(rat-kingdom-king--deftool "consul_start"
    "Start a consul: a rat in one registered repository whose only job is \
to talk with the user about that project, directly, in its own buffer, while \
you are busy. You do not drive it, review it or relay messages to it. It may \
write docs, and code on its own branch, which becomes a story for you to \
review when it is dismissed. Start one when the user asks for one."
    '((:name "repo" :type string :description "The repository's name.")
      (:name "topic" :type string :optional t
       :description "What the user wants to talk about, in a line.")
      (:name "agent" :type string :optional t
       :description "The agent it runs, claude or codex. Default the \
configured :agents :consul for the repository.")
      (:name "model" :type string :optional t
       :description "The Claude model it runs. Default the workers'."))
  (let ((id (rat-kingdom-consul-begin space (arg 'repo) :topic (arg 'topic)
                                      :agent (arg 'agent)
                                      :model (arg 'model))))
    (unless (memq space rat-kingdom-reaction--running)
      (rat-kingdom-reaction-run space))
    (rat-kingdom-consul-start-answer space id)))

(rat-kingdom-king--deftool "consul_dismiss"
    "Dismiss a consul when the user is done with it. Its agent is stopped. \
If it committed work, that becomes a story that you review and merge as \
usual; if not, its worktree and branch are removed. Its docs stay. It is \
refused if the consul has uncommitted changes, unless force is given, which \
commits them first."
    '((:name "consul" :type string
       :description "The consul's id, like C-1a2b, or its name.")
      (:name "force" :type string :optional t
       :description "true to commit uncommitted changes as work in \
progress and dismiss it anyway. Default false."))
  (prog1 (rat-kingdom-consul-end space (arg 'consul)
                                 (rat-kingdom-fact--boolean (arg 'force)
                                                            "force"))
    (unless (memq space rat-kingdom-reaction--running)
      (rat-kingdom-reaction-run space))))

;;;; Commands

(defun rat-kingdom-consul--read (prompt)
  "Read the id of a consul with PROMPT.
The consul of the current buffer, if it is one's, is the default."
  (let* ((consuls (rat-kingdom-consul-list (rat-kingdom-space-default)))
         (choices (mapcar (lambda (run)
                            (cons (format "%s  %s [%s]%s"
                                          (plist-get run :id)
                                          (rat-kingdom-run-display-name run)
                                          (plist-get run :repo)
                                          (if-let* ((topic (plist-get run :topic)))
                                              (concat ": " topic)
                                            ""))
                                  (plist-get run :id)))
                          consuls))
         (default (car (rassoc rat-kingdom-consul--buffer-id choices))))
    (unless choices
      (user-error "There is no consul"))
    (cdr (assoc (completing-read (format-prompt prompt default) choices nil t
                                 nil nil default)
                choices))))

;;;###autoload
(defun rat-kingdom-consul-start (repo &optional topic)
  "Start a consul for REPO, to talk with about the project, and show it.
TOPIC, if not empty, is what you want to talk about."
  (interactive
   (let ((names (mapcar (lambda (repo) (plist-get repo :name))
                        (rat-kingdom-repo-list (rat-kingdom-space-default)))))
     (unless names
       (user-error "Register a repository first: M-x rat-kingdom-add-repo"))
     (list (completing-read "Repository: " names nil t)
           (read-string "Topic (may be empty): "))))
  (unless rat-kingdom-mode
    (rat-kingdom-mode 1))
  (let* ((space (rat-kingdom-space-default))
         (id (rat-kingdom-consul-begin space repo :topic topic)))
    (rat-kingdom-reaction-run space)
    (if-let* ((buffer (rat-kingdom-consul--buffer id)))
        (pop-to-buffer buffer)
      (message "Started the consul %s, but it has no buffer: %s"
               (rat-kingdom-run-label (rat-kingdom-run-get space id))
               (or (plist-get (rat-kingdom-run-get space id) :error)
                   "no reason was recorded")))
    id))

;;;###autoload
(defun rat-kingdom-consul-show (consul)
  "Show the buffer of CONSUL, starting its agent again if it is not running."
  (interactive (list (rat-kingdom-consul--read "Show consul")))
  (if-let* ((buffer (rat-kingdom-consul-reopen (rat-kingdom-space-default)
                                               consul)))
      (pop-to-buffer buffer)
    (user-error "The consul %s has no buffer" consul)))

;;;###autoload
(defun rat-kingdom-consul-dismiss (consul &optional force)
  "Dismiss CONSUL: stop it, and make its commits a story for the king.
With a prefix argument FORCE, commit its uncommitted changes first, as
work in progress; without, they stop the dismissal.  In a consul's
buffer, that consul is the default."
  (interactive (list (rat-kingdom-consul--read "Dismiss consul")
                     current-prefix-arg))
  (let* ((space (rat-kingdom-space-default))
         (answer (rat-kingdom-consul-end space consul force)))
    (when rat-kingdom-mode
      (rat-kingdom-reaction-run space))
    (message "%s" answer)))

(provide 'rat-kingdom-consul)
;;; rat-kingdom-consul.el ends here
