;;; rat-kingdom-king.el --- The agent the user talks to -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Chaz Straney

;; Author: Chaz Straney <chaz.straney@gmail.com>
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;;; Commentary:

;; The king is a long-lived agent the user talks to (DESIGN.md, section
;; 9).  It captures work as stories, hands them to workers, reviews what
;; comes back and tells the user what happened.  It does none of the
;; chores: starting workers, checking, merging and cleaning up are the
;; engine's reactions.
;;
;; `rat-kingdom-king' starts the king, or shows it if it is running.
;; The king is a run like any other, called \"king\", in the role
;; `king'.  If its session ended, the same command takes that session up
;; again, so the king keeps what it knew.
;;
;; The engine tells the king what happens to stories.  Each piece of
;; news is a `message' tuple addressed to it.  Messages are given to the
;; king as a prompt when it is between turns and the user has nothing
;; half typed there, so they never cut into a conversation.  Until then
;; they wait in the space, and they survive a restart.  News of an
;; epic's stories goes to the epic's foreman instead, while one runs
;; (`rat-kingdom-king-route', rat-kingdom-foreman.el); it is given the
;; news the same way (`rat-kingdom-king-deliver-to').
;;
;; The king's tools are defined at the end of this file.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'rat-kingdom-space)
(require 'rat-kingdom-reaction)
(require 'rat-kingdom-git)
(require 'rat-kingdom-mcp)
(require 'rat-kingdom-run)
(require 'rat-kingdom-workflow)
(require 'rat-kingdom-story)
(require 'rat-kingdom-task)

(defconst rat-kingdom-king-id "king"
  "The id of the king's run.")

(defcustom rat-kingdom-king-directory nil
  "The directory the king's session runs in.
Nil means `rat-kingdom-directory'."
  :type '(choice (const :tag "The rat-kingdom directory" nil) directory)
  :group 'rat-kingdom)

(defcustom rat-kingdom-king-instructions
  "You are the king of a rat-kingdom swarm, running inside the user's Emacs. \
The user talks to you. You turn what they want into stories, hand each story \
to a worker, review what comes back, and tell the user what happened.

How the kingdom works:
- A story is one task for one worker in one registered repository. A worker \
is a separate agent in its own Git worktree and branch. You never see its \
session; you see what it reports.
- The engine does the chores without you: it starts the worker, merges its \
commit into a scratch candidate, runs the repository's check, and moves the \
repository's target branch (rk/integration unless the repository says \
otherwise). Nothing is pushed unless the user asks, and the user's checkout \
is never touched. The user merges the target branch into their own branch \
when they choose.
- Each story follows a workflow. `story` has a review by you before the \
merge; `story-lite` has none. Use `workflow_list` to see them.
- Every repository has a task tracker, a br (Rust Beads) workspace in the \
user's checkout, which repo_add creates, kept out of Git, if it is \
missing. `status` lists its ready tasks under Available tasks. A story started for one of them should pass its id \
as `task` to `story_start`, so that the task is claimed, closed when the \
story is merged, and the tasks that depend on it become available. A task \
may name the agent and workflow its story should have; `story_start` uses \
them unless you give others.
- A story that fails its check or your review goes back to a new worker in \
the same worktree, with the reason. A story that cannot go on is parked at \
`blocked` with a reason until you or the user move it.

Your tools are those of the rat-kingdom server: {tools}.

To plan an epic, prefer `epic_propose`: it shows the plan to the user in \
Emacs, where they review and edit it, then approve it, send it back to you \
with notes, or dismiss it, and you are told which. Approving creates the \
epic, and starts it if they ask, so do not call `epic_create` for a plan you \
proposed; when they send it back, revise it and propose it again. Use \
`epic_create` directly only when the user has agreed to the plan in \
conversation, or `epic_propose` says the plan surface is unavailable: \
propose the stories and the dependencies between them to the user first, \
and call `epic_create` only once they agree. `epic_create` \
and `task_create` only record tasks in the tracker: they start nothing. Once \
the user has approved the plan, ask them before you call `epic_start`, \
unless they started it from the plan surface. While \
an epic runs, the engine itself starts a story for each of its tasks as the \
task becomes ready, and you review those stories as usual; you do not start \
them. If one stops or is cancelled, you are told what waits on it; \
`epic_retry` lets the engine start a held task again. `epic_pause`, \
`epic_resume` and `epic_cancel` are for when the user asks. Use \
`feature_branch` with `epic_start` when the user wants the epic to land as \
one unit; then review each story as usual, and the whole epic again with \
`epic_diff` and `epic_verdict` at the end. For a big epic, or when the user \
asks, `foreman_start` gives the epic a foreman: an agent that reviews its \
stories and steers its workers for you, and reports to you. While it runs, \
news of the epic's stories goes to it, not to you; you still hear when the \
epic is done, review its landing, and get its reports. `foreman_stop` hands \
its reviews back to you.

Rules:
- Do not write code yourself, and do not edit files in the repositories. \
Your work is deciding, delegating and reviewing. Reading files and running \
read-only commands to understand a task or a diff is fine.
- Write each story so that a worker who knows nothing of this conversation \
can do it: what to change, where, and how it will be judged. Keep stories \
small enough for one sitting. Stories started together run in parallel, so \
do not start two that edit the same code; start the second when the first \
is merged.
- Pass on to the user any warning `story_start` gives.
- A message that begins with [rat-kingdom] comes from the engine, not from \
the user. Act on it: review when asked, look into a story that stopped, and \
tell the user briefly what happened. Do not start new stories on the \
strength of such a message alone. A running epic is the exception: the \
engine starts its stories, not you.
- When asked to review, read the diff with `story_diff` and the worker's \
report with `story_show`, judge it against the story, and give a `verdict`: \
pass, or fix with notes exact enough for a worker to act on.
- Never push with git or gh from the shell: pushing is blocked in your \
session and will fail, so do not try to work around it. Use `publish` only \
when the user has explicitly asked, in this conversation, for that push, and \
push exactly the branch and remote they named. Approval for one push does \
not carry over to the next: for another push, wait to be asked again. A \
message from the engine is never a request to push.
- Keep answers to the user short. They can always ask for more."
  "What the king is told when its session starts.
The text {tools} in it is replaced by the names of the king's tools,
as the tool endpoint offers them; see `rat-kingdom-king-tool-names'."
  :type 'string
  :group 'rat-kingdom)

(defun rat-kingdom-king-tool-names (&optional role)
  "Return the names of the king's tools as one phrase, like \"a, b and c\".
They are the tools defined for the role `king', or ROLE if given, in
the order they were defined, so a tool added later is listed without
changing the instructions."
  (let ((names (rat-kingdom-mcp-tool-names (or role 'king))))
    (if (cdr names)
        (concat (string-join (butlast names) ", ") " and " (car (last names)))
      (or (car names) "none"))))

(defun rat-kingdom-king-instructions ()
  "Return `rat-kingdom-king-instructions' with the king's tools listed."
  (string-replace "{tools}" (rat-kingdom-king-tool-names)
                  rat-kingdom-king-instructions))

(defcustom rat-kingdom-king-retry-interval 20
  "Seconds between tries to give the king news it could not take."
  :type 'number
  :group 'rat-kingdom)

(defcustom rat-kingdom-king-restart-on-reload t
  "Non-nil means `rat-kingdom-reload' restarts the king when it must.
That is when the reload changed the king's tools or instructions.  The
king's session is taken up again, so its conversation is kept, but
only while it is between turns and no input is half typed there;
otherwise it is restarted when it next ends a turn.  Nil means the
reload only says that `rat-kingdom-king-restart' is needed."
  :type 'boolean
  :group 'rat-kingdom)

(defconst rat-kingdom-king-diff-limit 40000
  "Most characters of a diff that `story_diff' returns.")

;;;; What the king is shown

(defun rat-kingdom-king--age (seconds)
  "Return SECONDS as a short length of time."
  (cond ((< seconds 90) (format "%ds" seconds))
        ((< seconds 5400) (format "%dm" (/ seconds 60)))
        (t (format "%.1fh" (/ seconds 3600.0)))))

(defun rat-kingdom-king--agent (payload)
  "Return the agent of the story whose token has PAYLOAD."
  (or (plist-get payload :agent) rat-kingdom-agent-shell-fallback-agent))

(defvar rat-kingdom-king-story-note-functions nil
  "Functions that add to what `status' and `story_show' say of a story.
Each is called with the space, the story's live token and a style,
`status' or `show', and returns a string or nil.  A `status' note is
added to the story's line, after its agent; a `show' note is a line, or
lines, of the story's entry.  Add to it with `add-hook', so that
reloading does not add a function twice.")

(defun rat-kingdom-king--story-notes (space story style)
  "Return the notes on the token STORY in SPACE, in STYLE, as a list.
See `rat-kingdom-king-story-note-functions'."
  (let (notes)
    (dolist (function rat-kingdom-king-story-note-functions)
      (with-demoted-errors "rat-kingdom: story note function: %S"
        (when-let* ((note (funcall function space story style)))
          (push note notes))))
    (nreverse notes)))

(defun rat-kingdom-king--story-line (space story)
  "Return one line describing the token STORY in SPACE."
  (let* ((payload (plist-get story :payload))
         (run (and (plist-get payload :run)
                   (rat-kingdom-run-get space (plist-get payload :run))))
         (now (funcall rat-kingdom-space-now-function)))
    (format "- %s [%s] %s%s, %s, %s%s: %s%s%s"
            (plist-get story :identity) (plist-get story :scope)
            (plist-get payload :at)
            (pcase (plist-get payload :phase)
              ("wait" (format " (waiting for %s%s)"
                              (plist-get payload :awaiting)
                              (if (and run (equal (plist-get payload :awaiting)
                                                  "worker"))
                                  (format " %s, %s" (plist-get run :id)
                                          (plist-get run :state))
                                "")))
              ("parked" " (stopped)")
              (_ ""))
            (rat-kingdom-king--age
             (- now (or (plist-get payload :entered) now)))
            (concat (rat-kingdom-king--agent payload)
                    (if-let* ((epic (plist-get payload :epic)))
                        (format ", epic %s" epic)
                      ""))
            (mapconcat (lambda (note) (concat ", " note))
                       (rat-kingdom-king--story-notes space story 'status) "")
            (plist-get payload :title)
            (if-let* ((reason (plist-get payload :reason))
                      ((equal (plist-get payload :phase) "parked")))
                (format "\n    reason: %s" (car (split-string reason "\n")))
              "")
            (if (rat-kingdom-space-rd
                 space (list 'stuck :identity (plist-get story :identity)))
                "\n    STUCK; see story_show"
              ""))))

(defun rat-kingdom-king--available (space repos)
  "Return lines listing the tasks available in SPACE.
REPOS are the records of the registered repositories."
  (let ((tasks (sort (rat-kingdom-space-scan space '(available))
                     (lambda (a b)
                       (let ((pa (or (plist-get (plist-get a :payload)
                                                :priority)
                                     most-positive-fixnum))
                             (pb (or (plist-get (plist-get b :payload)
                                                :priority)
                                     most-positive-fixnum)))
                         (if (= pa pb)
                             (string< (plist-get a :identity)
                                      (plist-get b :identity))
                           (< pa pb)))))))
    (cond
     (tasks
      (mapconcat
       (lambda (task)
         (let* ((payload (plist-get task :payload))
                (notes (delq nil
                             (list (and (plist-get payload :parent)
                                        (format "epic %s"
                                                (plist-get payload :parent)))
                                   (and (rat-kingdom-task-agent payload)
                                        (format "agent %s"
                                                (rat-kingdom-task-agent
                                                 payload)))))))
           (format "- %s [%s] P%s %s: %s%s"
                   (plist-get task :identity) (plist-get task :scope)
                   (or (plist-get payload :priority) "?")
                   (or (plist-get payload :type) "task")
                   (plist-get payload :title)
                   (if notes (format " (%s)" (string-join notes ", ")) ""))))
       tasks "\n"))
     ((cl-some (lambda (repo)
                 (rat-kingdom-task-adapter space (plist-get repo :name)))
               repos)
      "- none")
     (t "- none (no repository has a task tracker)"))))

(defvar rat-kingdom-king-status-functions nil
  "Functions that add sections to what `status' says.
Each is called with the space and returns a section, a heading line and
its lines, or nil.  The sections follow the stories in progress, in the
order of this list.  Add to it with `add-hook', so that reloading does
not add a function twice.")

(defun rat-kingdom-king--status-sections (space)
  "Return the sections `rat-kingdom-king-status-functions' give for SPACE."
  (let (sections)
    (dolist (function rat-kingdom-king-status-functions)
      (with-demoted-errors "rat-kingdom: status function: %S"
        (when-let* ((section (funcall function space)))
          (push section sections))))
    (nreverse sections)))

(defun rat-kingdom-king-status (space)
  "Return a text describing the repositories, stories and tasks in SPACE.
The ready tasks of every repository are projected first; a tracker
that fails is reported and otherwise ignored."
  (with-demoted-errors "rat-kingdom: projecting tasks: %S"
    (rat-kingdom-task-project-all space))
  (let ((repos (rat-kingdom-repo-list space))
        (stories (rat-kingdom-story-list space))
        (failures (rat-kingdom-reaction-failures space)))
    (concat
     "Repositories:\n"
     (if repos
         (mapconcat
          (lambda (repo)
            (format "- %s at %s; target %s; check %s%s; workflow %s%s"
                    (plist-get repo :name) (plist-get repo :path)
                    (plist-get repo :target)
                    (if (plist-get repo :check)
                        (combine-and-quote-strings (plist-get repo :check))
                      "none")
                    (if (plist-get repo :setup)
                        (concat "; setup " (combine-and-quote-strings
                                            (plist-get repo :setup)))
                      "")
                    (or (plist-get repo :workflow)
                        rat-kingdom-story-default-workflow)
                    (if-let* ((problem (rat-kingdom-task-workspace-error
                                        (plist-get repo :name))))
                        (format "; it has no br workspace, so no tasks (tell \
the user): %s" problem)
                      "")))
          repos "\n")
       "- none registered; use repo_add")
     (format "\n\nAgents: %s. New stories' workers run %s \
(rat-kingdom-default-agent) unless story_start names another."
             (string-join (rat-kingdom-agent-names) ", ")
             rat-kingdom-default-agent)
     "\n\nStories in progress:\n"
     (if stories
         (mapconcat (lambda (story) (rat-kingdom-king--story-line space story))
                    stories "\n")
       "- none")
     (mapconcat (lambda (section) (concat "\n\n" (string-trim-right section)))
                (rat-kingdom-king--status-sections space) "")
     "\n\nAvailable tasks:\n"
     (rat-kingdom-king--available space repos)
     (if failures
         (concat "\n\nReactions that failed (tell the user):\n"
                 (mapconcat (lambda (failure)
                              (format "- %s: %s" (plist-get failure :reaction)
                                      (plist-get failure :error)))
                            failures "\n"))
       ""))))

(defun rat-kingdom-king--find-story (space id)
  "Return the token of the story ID in SPACE, live or archived.
The second value, in a cons, is non-nil if it is archived."
  (if-let* ((story (rat-kingdom-story-get space id)))
      (cons story nil)
    (if-let* ((story (cl-find 'story (reverse (rat-kingdom-space-archived
                                               space id))
                              :key (lambda (tuple)
                                     (plist-get tuple :category)))))
        (cons story t)
      (error "There is no story called %s" id))))

(defun rat-kingdom-king--show (space id &optional check)
  "Return a text with everything recorded about the story ID in SPACE.
CHECK, if given, is a scope check called with the story's token first;
see `rat-kingdom-king-story-start'."
  (pcase-let* ((`(,story . ,archived) (rat-kingdom-king--find-story space id))
               (_ (when check (funcall check 'story story)))
               (payload (plist-get story :payload))
               (others (if archived
                           (rat-kingdom-space-archived space id)
                         (rat-kingdom-space-scan space (list '_ :owner id)))))
    (cl-flet ((of (category)
                (plist-get (cl-find category (reverse others)
                                    :key (lambda (tuple)
                                           (plist-get tuple :category)))
                           :payload)))
      (let ((checked (of 'checked))
            (stuck (of 'stuck)))
        (string-join
         (delq nil
               (list
                (format "%s in %s: %s" id (plist-get story :scope)
                        (plist-get payload :title))
                (and (plist-get payload :description)
                     (format "Description: %s" (plist-get payload :description)))
                (and (plist-get payload :task)
                     (format "Task: %s%s" (plist-get payload :task)
                             (if-let* ((epic (plist-get payload :epic)))
                                 (format ", of the epic %s%s" epic
                                         (if-let* ((record
                                                    (rat-kingdom-space-rd
                                                     space
                                                     (list 'epic
                                                           :scope
                                                           (plist-get story :scope)
                                                           :identity epic))))
                                             (format " (%s)"
                                                     (plist-get
                                                      (plist-get record :payload)
                                                      :title))
                                           ""))
                               "")))
                (format "Agent: %s" (rat-kingdom-king--agent payload))
                (format "Workflow %s; at %s%s%s"
                        (plist-get payload :workflow) (plist-get payload :at)
                        (pcase (plist-get payload :phase)
                          ("wait" (format ", waiting for %s in step %s"
                                          (plist-get payload :awaiting)
                                          (plist-get payload :step)))
                          ("parked" ", stopped until it is moved")
                          ("cancelled" ", cancelled")
                          (_ ""))
                        (if archived " (archived)" ""))
                (and (plist-get payload :reason)
                     (format "Reason: %s" (plist-get payload :reason)))
                (and stuck (format "Stuck: %s" (plist-get stuck :reason)))
                (and (plist-get payload :attempt)
                     (format "Workers so far: %s" (plist-get payload :attempt)))
                (and (plist-get payload :run)
                     (let ((run (cl-find (plist-get payload :run)
                                         (mapcar #'rat-kingdom-run--record
                                                 (cl-remove-if-not
                                                  (lambda (tuple)
                                                    (eq (plist-get tuple :category)
                                                        'run))
                                                  others))
                                         :key (lambda (run) (plist-get run :id))
                                         :test #'equal)))
                       (format "Worker %s: %s" (plist-get payload :run)
                               (or (plist-get run :state) "unknown"))))
                (and (not archived)
                     (when-let* ((notes (rat-kingdom-king--story-notes
                                         space story 'show)))
                       (string-join notes "\n")))
                (and (plist-get payload :worktree)
                     (not (plist-get payload :integrated))
                     (format "Worktree %s on branch %s"
                             (plist-get payload :worktree)
                             (plist-get payload :branch)))
                (and (plist-get payload :commit)
                     (format "Commit: %s" (plist-get payload :commit)))
                (and (plist-get payload :summary)
                     (format "Worker's summary: %s" (plist-get payload :summary)))
                (and (plist-get payload :checks)
                     (format "Checks the worker ran: %s"
                             (plist-get payload :checks)))
                (and checked
                     (format "Check: %s%s%s"
                             (plist-get checked :value)
                             (if (plist-get checked :check)
                                 (format " (%s)" (combine-and-quote-strings
                                                  (plist-get checked :check)))
                               " (the repository has no check; the merge was \
clean)")
                             (if (and (equal (plist-get checked :value) "fail")
                                      (plist-get checked :output))
                                 (format "\n%s" (plist-get checked :output))
                               "")))
                (and (plist-get payload :integrated)
                     (format "Merged into %s at %s"
                             (or (rat-kingdom-story-target space story)
                                 "the target")
                             (plist-get payload :integrated)))))
         "\n")))))

(defun rat-kingdom-king-diff-text (path from tip)
  "Return the commits and the diff TIP makes against FROM, or nil if none.
PATH is the repository.  The commits are those in TIP that FROM lacks;
the diff is from where the two meet, with a summary first.  A diff
longer than `rat-kingdom-king-diff-limit' is cut short, saying how to
read the rest."
  (let* ((range (format "%s...%s" from tip))
         (log (rat-kingdom-git path "log" "--format=%h %s"
                               (format "%s..%s" from tip))))
    (unless (string-empty-p log)
      (let ((diff (rat-kingdom-git path "diff" range)))
        (concat log "\n\n"
                (rat-kingdom-git path "diff" "--stat" range)
                "\n\n"
                (if (> (length diff) rat-kingdom-king-diff-limit)
                    (format "%s\n[The diff is %d characters; this is the first \
%d. Read the rest with git in %s: git diff %s]"
                            (substring diff 0 rat-kingdom-king-diff-limit)
                            (length diff) rat-kingdom-king-diff-limit path range)
                  diff))))))

(defun rat-kingdom-king--diff (space id &optional check)
  "Return the changes the story ID in SPACE makes, as a diff with a summary.
They are taken against the base of its last check, or else its target.
CHECK, if given, is a scope check called with the story's token first;
see `rat-kingdom-king-story-start'."
  (pcase-let* ((`(,story . ,_) (rat-kingdom-king--find-story space id))
               (_ (when check (funcall check 'story story)))
               (payload (plist-get story :payload))
               (repo (or (rat-kingdom-repo-get space (plist-get story :scope))
                         (error "Repository %s is no longer registered"
                                (plist-get story :scope))))
               (path (plist-get repo :path))
               (tip (or (plist-get payload :commit)
                        (and (plist-get payload :branch)
                             (rat-kingdom-git-ok-p
                              path "rev-parse" "--verify" "--quiet"
                              (concat "refs/heads/" (plist-get payload :branch)))
                             (plist-get payload :branch))
                        (error "%s has no commits yet" id)))
               (from (or (plist-get payload :base)
                         (rat-kingdom-story-target space story))))
    (or (rat-kingdom-king-diff-text path from tip)
        (format "%s has no commits of its own yet." id))))

;;;; News for the king

(defvar rat-kingdom-king-news-functions nil
  "Functions that add to the king's news of what happened to a story.
Each is called with the space, the event and the story's token, as
`rat-kingdom-story-event-functions' are, inside the same transaction,
and returns a paragraph to add to the news, or nil.  For an event the
king is not otherwise told of, such as `cancelled', a paragraph makes
news of it.  Add to it with `add-hook', so that reloading does not add
a function twice.")

(defun rat-kingdom-king--news-notes (space event story)
  "Return the paragraphs `rat-kingdom-king-news-functions' add.
Each is called with SPACE, EVENT and STORY."
  (let (notes)
    (dolist (function rat-kingdom-king-news-functions)
      (with-demoted-errors "rat-kingdom: news function: %S"
        (when-let* ((note (funcall function space event story)))
          (push note notes))))
    (nreverse notes)))

(defconst rat-kingdom-foreman-id-prefix "F-"
  "The start of the id of a foreman's run; its epic's id follows.
A foreman is an agent that runs one epic for the king; see
rat-kingdom-foreman.el.")

(defvar rat-kingdom-king-route-functions nil
  "Functions that send news of an epic's work to another run than the king.
Each is called with the space, the repository and the epic's id, and
returns nil to leave the choice to the next, or (TO . NOTE): TO is the
id of the run to tell, nil meaning the king, and NOTE is nil or a
paragraph to add to the news, such as why it is not going where it
usually would.  rat-kingdom-foreman.el puts one here, which sends news
of an epic's stories to its foreman while one is running.  Add to it
with `add-hook', so that reloading does not add a function twice.")

(defun rat-kingdom-king-route (space repo epic)
  "Return who is told in SPACE of the work of the epic EPIC of REPO.
The value is (TO . NOTE): TO is the id of a run, the king's unless a
function of `rat-kingdom-king-route-functions' chooses another, and
NOTE is nil or a paragraph to add to the news.  With EPIC nil, the news
is the king's."
  (or (and epic
           (cl-loop for function in rat-kingdom-king-route-functions
                    thereis (when-let* ((route
                                         (with-demoted-errors
                                             "rat-kingdom: route function: %S"
                                           (funcall function space repo epic))))
                              (cons (or (car route) rat-kingdom-king-id)
                                    (cdr route)))))
      (cons rat-kingdom-king-id nil)))

(defun rat-kingdom-king--news (space event story)
  "Leave the king a message in SPACE that EVENT happened to the token STORY.
The paragraphs of `rat-kingdom-king-news-functions' are added to it.
News of a story of an epic goes where `rat-kingdom-king-route' says:
to the epic's foreman while it has one running."
  (let* ((payload (plist-get story :payload))
         (id (plist-get story :identity))
         (name (rat-kingdom-story--title story))
         (route (rat-kingdom-king-route space (plist-get story :scope)
                                        (plist-get payload :epic)))
         (to (car route))
         (notes (rat-kingdom-king--news-notes space event story))
         (text
          (pcase event
            ('done
             (if (plist-get payload :integrated)
                 (format "%s is merged into %s of %s at %s."
                         name (or (rat-kingdom-story-target space story)
                                  "the target")
                         (plist-get story :scope)
                         (substring (plist-get payload :integrated) 0 10))
               (format "%s is over." name)))
            ('parked
             (if (equal to rat-kingdom-king-id)
                 (format "%s has stopped at %s. Reason: %s\nLook with story_show. \
Then move it with story_move (to its first place for a new worker, with a \
note saying what to do differently), or end it with story_cancel."
                         name (plist-get payload :at)
                         (or (plist-get payload :reason) "none given"))
               (format "%s has stopped at %s. Reason: %s\nLook with story_show. \
Only the king can move or end it: if a new worker should try again, or it \
should be ended, say so with report; or add a task with task_create to do \
the work another way."
                       name (plist-get payload :at)
                       (or (plist-get payload :reason) "none given"))))
            ('review
             (when (equal (plist-get (rat-kingdom-story--step story) :with)
                          'king)
               (format "%s passed its check and waits for your review. Read \
story_diff and story_show for %s, then give a verdict."
                       name id)))
            ('stuck
             (format "%s looks stuck. %s" name (plist-get payload :reason)))
            ('cancelled
             (and notes (format "%s was cancelled." name)))))
         (text (if (and text notes)
                   (string-join (cons text notes) "\n")
                 text))
         (text (if (and text (cdr route))
                   (concat text "\n" (cdr route))
                 text)))
    (when text
      (rat-kingdom-space-out space 'message :scope (plist-get story :scope)
                             :payload (list :to to :story id :text text)
                             :actor "engine"))))

(add-hook 'rat-kingdom-story-event-functions #'rat-kingdom-king--news)

;;;; Giving news to the king, and to foremen

;; Messages are given the same way to the king and to the foreman of an
;; epic: every `message' tuple addressed with `:to' to the run, as one
;; prompt, when the run is between turns.  Each is retracted only after
;; the agent took the prompt, so a crash repeats news and never loses it.

(defvar rat-kingdom-king--retry nil
  "The timer for another try at delivering news to the king, or nil.")

(defvar rat-kingdom-king--retries (make-hash-table :test #'equal)
  "Hash table from the id of a run other than the king to its retry timer.")

(defun rat-kingdom-king--retry-timer (to)
  "Return the timer for another try at giving the run TO its news, or nil."
  (if (equal to rat-kingdom-king-id)
      rat-kingdom-king--retry
    (gethash to rat-kingdom-king--retries)))

(defun rat-kingdom-king--set-retry-timer (to timer)
  "Make TIMER, or nil, the one for another try at giving the run TO its news."
  (cond ((equal to rat-kingdom-king-id) (setq rat-kingdom-king--retry timer))
        (timer (puthash to timer rat-kingdom-king--retries))
        (t (remhash to rat-kingdom-king--retries))))

(defun rat-kingdom-king-deliver-to (space to)
  "Give the run TO the messages addressed to it in SPACE, if it can take them.
They are the `message' tuples with `:to' TO, given as one prompt headed
as news from the engine.  Return how many were given.  If the run is
running and could not take them, try again in
`rat-kingdom-king-retry-interval' seconds.  A run that is not running
in this Emacs keeps its messages in the space."
  (let ((messages (and (rat-kingdom-space-db space)
                       (rat-kingdom-run-live-p to)
                       (rat-kingdom-space-scan space (list 'message :to to)))))
    (when-let* ((timer (rat-kingdom-king--retry-timer to)))
      (when (timerp timer)
        (cancel-timer timer))
      (rat-kingdom-king--set-retry-timer to nil))
    (cond
     ((null messages) 0)
     ((rat-kingdom-run-send
       to
       (concat "[rat-kingdom] News from the engine:\n\n"
               (mapconcat (lambda (message)
                            (plist-get (plist-get message :payload) :text))
                          messages "\n\n")))
      (rat-kingdom-space-with-transaction space
        (dolist (message messages)
          (rat-kingdom-space-retract space (list 'message
                                                 :id (plist-get message :id))
                                     :actor to)))
      (length messages))
     (t
      (rat-kingdom-king--set-retry-timer
       to (run-at-time rat-kingdom-king-retry-interval nil
                       #'rat-kingdom-king-deliver-to space to))
      0))))

(defun rat-kingdom-king-deliver (&optional space)
  "Give the king the messages waiting for it in SPACE, if it can take them.
Return how many were given.  If the king is running and could not take
them, try again in `rat-kingdom-king-retry-interval' seconds."
  (rat-kingdom-king-deliver-to (or space (rat-kingdom-space-default))
                               rat-kingdom-king-id))

(defun rat-kingdom-king--on-change (space op subject)
  "Deliver news soon after a message for the king, or a foreman, is written.
SPACE is where; OP and SUBJECT are as for
`rat-kingdom-space-change-functions'."
  (when-let* (((eq op 'out))
              ((eq (plist-get subject :category) 'message))
              (to (plist-get (plist-get subject :payload) :to)))
    (run-at-time 0 nil #'rat-kingdom-king-deliver-to space to)))

(defun rat-kingdom-king--on-idle (run)
  "Deliver news when RUN, the king or a foreman, has ended a turn."
  (rat-kingdom-king-deliver-to (rat-kingdom-space-default) run))

(add-hook 'rat-kingdom-space-change-functions #'rat-kingdom-king--on-change)
(add-hook 'rat-kingdom-run-idle-functions #'rat-kingdom-king--on-idle)

;;;; Starting the king

(defun rat-kingdom-king-fingerprint ()
  "Return a hash of what the king is given when its session starts.
That is its tools, as `tools/list' serves them, and its
instructions, from the function `rat-kingdom-king-instructions'.  If
the hash a running king was started with differs, its tools or
instructions are out of date."
  (secure-hash
   'sha256
   (json-serialize
    (vector (vconcat (sort (rat-kingdom-mcp-tool-list 'king)
                           (lambda (a b)
                             (string< (plist-get a :name)
                                      (plist-get b :name)))))
            (rat-kingdom-king-instructions)))))

(defun rat-kingdom-king--prompt (space resumed &optional changed)
  "Return the first prompt for the king in SPACE.
RESUMED is non-nil if its earlier session is being taken up again.
CHANGED is non-nil if that session was started with other tools or
instructions; the king is then given the current instructions."
  (concat
   (if resumed
       (concat
        "[rat-kingdom] Your session was restarted; you are still the king. \
Tools you called before the restart may need calling again."
        (if changed
            (concat "\n\nThese instructions replace the ones you were given \
earlier:\n\n"
                    (rat-kingdom-king-instructions)
                    "\n\nYour tools may have changed too. Rely on the tool \
list you have now, not on what you remember of the earlier one.\n\n")
          " ")
        "This is how things stand now:\n\n")
     (concat (rat-kingdom-king-instructions)
             "\n\nThis is how things stand now:\n\n"))
   (rat-kingdom-king-status space)
   "\n\nSay in a line or two that you are ready and what, if anything, needs \
attention. Then wait for the user."))

(defun rat-kingdom-king-start (space &optional fresh)
  "Record the king's run in SPACE so that it is started.
Take up its earlier session again unless FRESH is non-nil or there was
none.  Signal an error if the king is already running."
  (when (rat-kingdom-run-live-p rat-kingdom-king-id)
    (error "The king is already running"))
  (let* ((old (rat-kingdom-run-get space rat-kingdom-king-id))
         (session (and (not fresh) (plist-get old :session-id)))
         (fingerprint (rat-kingdom-king-fingerprint))
         (prompt (rat-kingdom-king--prompt
                  space session
                  (not (equal (plist-get old :fingerprint) fingerprint))))
         (directory (file-name-as-directory
                     (expand-file-name (or rat-kingdom-king-directory
                                           rat-kingdom-directory)))))
    (make-directory directory t)
    (rat-kingdom-space-with-transaction space
      (rat-kingdom-space-retract space (list 'run :identity rat-kingdom-king-id)
                                 :actor "user")
      (rat-kingdom-run-create
       space :id rat-kingdom-king-id :role 'king :worktree directory
       ;; A session is taken up by the agent that started it.
       :agent (and session (plist-get old :agent))
       :resume session :prompt prompt)
      (rat-kingdom-run-update space rat-kingdom-king-id
                              :fingerprint fingerprint))))

;;;; Restarting the king in place

;; The king's tools and instructions are fixed when its session starts.
;; After a reload changes them, the king is stopped and its session
;; taken up again, which keeps the conversation but has its tools
;; fetched afresh, and it is given the new instructions.  News for the
;; king waits in the space meanwhile and is delivered when the new
;; session ends its first turn.

(defun rat-kingdom-king-stale-p (space)
  "Return non-nil if the running king in SPACE has out-of-date tools.
That is, if it was started with other tools or instructions than
`rat-kingdom-king-fingerprint' describes.  A king that is not running
is not stale: it is given the current ones when it starts."
  (and (rat-kingdom-run-live-p rat-kingdom-king-id)
       (not (equal (plist-get (rat-kingdom-run-get space rat-kingdom-king-id)
                              :fingerprint)
                   (rat-kingdom-king-fingerprint)))))

(defun rat-kingdom-king--why-not-restart (space)
  "Return why the king in SPACE cannot be restarted now, or nil if it can."
  (cond ((not (rat-kingdom-run-live-p rat-kingdom-king-id))
         "The king is not running")
        ((not (plist-get (rat-kingdom-run-get space rat-kingdom-king-id)
                         :session-id))
         "The king's session has not started yet; try again in a moment")
        ((rat-kingdom-run-busy-p rat-kingdom-king-id)
         "The king is in the middle of a turn, or has input you have not \
sent; try again when it is idle")))

(defun rat-kingdom-king-restart-session (space)
  "Stop the king in SPACE and start it again in the same session.
Its conversation is kept, its tools are fetched afresh, and if they or
its instructions changed it is given the current instructions.  Signal
a `user-error' if the king is not running, has no session yet, is in
the middle of a turn, or has input in its buffer that is not sent."
  (when-let* ((reason (rat-kingdom-king--why-not-restart space)))
    (user-error "%s" reason))
  (rat-kingdom-run-stop space rat-kingdom-king-id)
  (rat-kingdom-king-start space)
  (rat-kingdom-reaction-run space))

(defvar rat-kingdom-king--restart-pending nil
  "Non-nil if the king is to be restarted when it next ends a turn.")

(defun rat-kingdom-king-refresh (space)
  "Give the running king in SPACE its current tools and instructions.
Do nothing unless it is stale; see `rat-kingdom-king-stale-p'.  Return
nil if nothing was needed, `restarted' if the king was restarted now,
`deferred' if it will be when it next ends a turn, or `changed' if
`rat-kingdom-king-restart-on-reload' is nil and nothing was done."
  (setq rat-kingdom-king--restart-pending nil)
  (when (rat-kingdom-king-stale-p space)
    (cond ((not rat-kingdom-king-restart-on-reload) 'changed)
          ((rat-kingdom-king--why-not-restart space)
           (setq rat-kingdom-king--restart-pending t)
           'deferred)
          (t (rat-kingdom-king-restart-session space)
             'restarted))))

(defun rat-kingdom-king--restart-on-idle (run)
  "Restart the king if RUN is the king and a restart is pending."
  (when (and rat-kingdom-king--restart-pending
             (equal run rat-kingdom-king-id))
    (let ((space (rat-kingdom-space-default)))
      (cond ((not (rat-kingdom-king-stale-p space))
             (setq rat-kingdom-king--restart-pending nil))
            ((not (rat-kingdom-king--why-not-restart space))
             (setq rat-kingdom-king--restart-pending nil)
             (rat-kingdom-king-restart-session space)
             (message "rat-kingdom: restarted the king's session in place, \
to give it its new tools and instructions"))))))

(add-hook 'rat-kingdom-run-idle-functions #'rat-kingdom-king--restart-on-idle)

;;;; The king's tools

(defun rat-kingdom-king--arg (arguments name)
  "Return the argument NAME, a symbol, from ARGUMENTS, or nil if it is blank."
  (let ((value (alist-get name arguments)))
    (and value (not (and (stringp value) (string-blank-p value))) value)))

(defmacro rat-kingdom-king--deftool (name description args &rest body)
  "Define the king's tool NAME with DESCRIPTION and ARGS.
BODY is run with `space' bound to the default space, `context' to the
caller's context and `arg' to a function that returns an argument by
name.  BODY may begin with `:roles ROLES', the roles offered the tool,
evaluated; the default is the king's alone."
  (declare (indent 3))
  (let ((roles ''(king)))
    (when (eq (car body) :roles)
      (setq roles (cadr body)
            body (cddr body)))
    `(rat-kingdom-mcp-define-tool
      ,name :description ,description :roles ,roles :args ,args
      :function
      (lambda (context arguments)
        (let ((space (rat-kingdom-space-default)))
          (cl-flet ((arg (name) (rat-kingdom-king--arg arguments name)))
            (ignore space context #'arg)
            ,@body))))))

;; Some of the king's tools are a foreman's too, limited to its epic
;; (rat-kingdom-foreman.el).  Their work is done by functions that take
;; an optional scope check: a function called with what is about to be
;; acted on, which signals an error if the caller may not act on it.
;; It is called as (CHECK \='story TOKEN) with a story's token, live or
;; archived, and as (CHECK \='task REPO TASK FOUND) with a task's id, the
;; repository and the task as `rat-kingdom-story-task' finds it, or nil.
;; The king's tools pass none.

(defun rat-kingdom-king-story-start (space options &optional check)
  "Start a story in SPACE as `story_start' does, and return its answer.
OPTIONS is a property list of the tool's arguments: `:repo',
`:title', `:description', `:task', `:workflow', `:agent' and
`:target'.  CHECK, if given, is a scope check, called with the task
before anything is started; see above."
  (let* ((repo (plist-get options :repo))
         (task (plist-get options :task))
         (found (and task (rat-kingdom-story-task space repo task)))
         (_ (when check (funcall check 'task repo task found)))
         (labelled (and found (list :agent (and (not (plist-get options :agent))
                                                (rat-kingdom-task-agent found))
                                    :workflow (and (not (plist-get options
                                                                   :workflow))
                                                   (rat-kingdom-task-workflow
                                                    found)))))
         ;; A task of an epic that has been run is counted with it, and
         ;; while the epic has not ended its stories merge into its
         ;; feature branch, if it has one.
         (record (when-let* ((parent (plist-get found :parent)))
                   (rat-kingdom-space-rd space (list 'epic :scope repo
                                                     :identity parent))))
         (epic (and record (plist-get record :identity)))
         (target (or (plist-get options :target)
                     (let ((payload (plist-get record :payload)))
                       (and (not (member (plist-get payload :state)
                                         '("done" "cancelled")))
                            (plist-get payload :branch)))))
         (warnings (progn
                     (when target
                       (rat-kingdom-story-check-target space repo target))
                     (rat-kingdom-story-warnings space repo target)))
         (id (if task
                 (rat-kingdom-story-start-for-task
                  space repo task :found found
                  :title (plist-get options :title)
                  :description (plist-get options :description)
                  :agent (plist-get options :agent)
                  :workflow (plist-get options :workflow) :epic epic
                  :target target)
               (rat-kingdom-story-start
                space repo
                (or (plist-get options :title)
                    (error "Give a title, or a task to take it from"))
                (or (plist-get options :description)
                    (error "Give a description, or a task to take it from"))
                nil (plist-get options :workflow) nil
                (plist-get options :agent) nil target)))
         (payload (plist-get (rat-kingdom-story-get space id) :payload))
         (from-labels (delq nil (list (and (plist-get labelled :workflow)
                                           "workflow")
                                      (and (plist-get labelled :agent)
                                           "agent")))))
    (string-join
     (cons (format "Started %s%s with the workflow %s and the agent %s%s. You \
will be told when it needs you or is merged."
                   id (if task (format " for the task %s" task) "")
                   (plist-get payload :workflow)
                   (plist-get payload :agent)
                   (concat
                    (if from-labels
                        (format " (the %s from the task's labels)"
                                (string-join from-labels " and "))
                      "")
                    (if epic (format ", as a story of the epic %s" epic) "")
                    (if target
                        (format "; it is cut from and merges into %s" target)
                      "")))
           warnings)
     "\nWarning: ")))

(defun rat-kingdom-king-verdict (space story value notes actor &optional check)
  "Record the verdict VALUE on STORY in SPACE with NOTES, as ACTOR.
Return what `verdict' answers.  CHECK, if given, is a scope check,
called with the story's token first; see above."
  (when check
    (funcall check 'story (car (rat-kingdom-king--find-story space story))))
  (pcase (rat-kingdom-story-verdict space story value notes actor)
    ("pass" (format "Recorded. %s will be merged now." story))
    (_ (format "Recorded. %s goes back to a worker with your notes." story))))

(rat-kingdom-king--deftool "status"
    "Show the registered repositories, every story in progress (where \
each is, what it waits for, and why any has stopped) and the tracker tasks \
available to start stories from."
    nil
  (rat-kingdom-king-status space))

(rat-kingdom-king--deftool "workflow_list"
    "List the workflows a story can follow, with their steps."
    nil
  (mapconcat #'rat-kingdom-workflow-describe (rat-kingdom-workflow-list)
             "\n\n"))

(rat-kingdom-king--deftool "repo_add"
    "Register a Git repository so that stories can be started in it, or \
change the settings of one already registered. Creates the target branch \
from HEAD if it does not exist. Every repository needs a br (Rust Beads) \
workspace for its tasks: if the checkout has no .beads directory one is \
initialized, kept out of Git through info/exclude, and the answer says so. \
An existing .beads is left alone. If br is missing or fails, nothing is \
registered."
    '((:name "path" :type string
       :description "Absolute path of the repository's checkout.")
      (:name "check" :type string :optional t
       :description "The command that must succeed before work is merged, \
for example \"make test\". It is run without a shell in a scratch worktree \
that has the work merged in. Leave out for no check.")
      (:name "setup" :type string :optional t
       :description "Command run without a shell in each fresh worktree \
before a worker starts and before the check, e.g. \"npm ci\". Leave out \
for none.")
      (:name "target" :type string :optional t
       :description "The branch finished work is merged into. Default \
rk/integration. It must not be a branch that is checked out.")
      (:name "workflow" :type string :optional t
       :description "The workflow stories here follow by default.")
      (:name "task_prefix" :type string :optional t
       :description "The issue prefix of the br workspace, if one has to \
be created. Default the repository's name."))
  (when (and (arg 'workflow) (not (rat-kingdom-workflow-get (arg 'workflow))))
    (error "There is no workflow called %s" (arg 'workflow)))
  (let ((repo (rat-kingdom-repo-add
               space (expand-file-name (arg 'path))
               :check (and (arg 'check) (split-string-and-unquote (arg 'check)))
               :setup (and (arg 'setup) (split-string-and-unquote (arg 'setup)))
               :target (arg 'target) :workflow (arg 'workflow)
               :task-prefix (arg 'task_prefix))))
    (string-join
     (cons (format "Registered %s at %s. Finished work is merged into %s.%s"
                   (plist-get repo :name) (plist-get repo :path)
                   (plist-get repo :target)
                   (if (plist-get repo :task-initialized)
                       (format " Initialized a br workspace there with the \
prefix %s, kept out of Git." (rat-kingdom-task-br-prefix repo))
                     ""))
           (rat-kingdom-story-warnings space (plist-get repo :name)))
     "\nWarning: ")))

(rat-kingdom-king--deftool "repo_sync"
    "Move a repository's target branch forward to the HEAD of the user's \
checkout, so that new workers see what the user has committed since. Only \
ever moves the target forward."
    '((:name "repo" :type string :description "The repository's name."))
  (rat-kingdom-story-sync space (arg 'repo)))

(rat-kingdom-king--deftool "story_start"
    "Start a story: one task for one worker in one repository. The worker \
starts at once in its own worktree. Returns the story's id and any warnings \
the user should hear."
    '((:name "repo" :type string :description "The repository's name.")
      (:name "title" :type string :optional t
       :description "What to do, in one line. Required unless task is \
given.")
      (:name "description" :type string :optional t
       :description "Everything the worker needs: what to change, where, \
constraints, and how the result will be judged. The worker knows nothing \
else. Required unless task is given.")
      (:name "task" :type string :optional t
       :description "The id of a tracker task, as listed under Available \
tasks in status. Title and description default to the task's.")
      (:name "workflow" :type string :optional t
       :description "The workflow to follow. Default the task's \
rk-workflow: label if it has one, else the repository's own.")
      (:name "agent" :type string :optional t
       :description "Chooses the agent the story's workers run: claude \
for Claude Code, or codex for OpenAI Codex in full-access mode. Every \
worker the story is given, after a failed check or a review too, runs it. \
Default the task's rk-agent: label if it has one, else \
rat-kingdom-default-agent, the user's setting, which status shows.")
      (:name "target" :type string :optional t
       :description "Rarely needed; leave it out. The branch the worker's \
worktree is cut from and the work is merged into, instead of the \
repository's target. It must be an existing local branch that is not \
checked out. A task of an epic run with a feature branch gets the epic's \
branch without this."))
  (rat-kingdom-king-story-start
   space (list :repo (arg 'repo) :title (arg 'title)
               :description (arg 'description) :task (arg 'task)
               :workflow (arg 'workflow) :agent (arg 'agent)
               :target (arg 'target))))

(rat-kingdom-king--deftool "story_show"
    "Show everything recorded about one story, in progress or finished: \
where it is, why it stopped, the worker's report and the check's outcome."
    '((:name "story" :type string :description "The story's id, like S-1a2b."))
  (rat-kingdom-king--show space (arg 'story)))

(rat-kingdom-king--deftool "story_diff"
    "Show the commits and the diff a story's work makes against its \
target branch."
    '((:name "story" :type string :description "The story's id."))
  (rat-kingdom-king--diff space (arg 'story)))

(rat-kingdom-king--deftool "story_move"
    "Put a story at any place of its workflow, whatever it was doing. Its \
worker is stopped; its files are kept. Use it to give a stopped story a new \
worker (move it to the workflow's first place) or to skip or repeat a step."
    '((:name "story" :type string :description "The story's id.")
      (:name "place" :type string
       :description "The place to put it at, for example ready.")
      (:name "note" :type string :optional t
       :description "Why. If a worker starts next, it is told this."))
  (format "%s is now at %s."
          (arg 'story)
          (rat-kingdom-story-move space (arg 'story) (arg 'place) (arg 'note)
                                  rat-kingdom-king-id)))

(rat-kingdom-king--deftool "story_cancel"
    "End a story for good. Its worker is stopped and the story is archived. \
Its worktree and branch are kept for the user to look at or delete."
    '((:name "story" :type string :description "The story's id."))
  (rat-kingdom-story-cancel space (arg 'story) rat-kingdom-king-id))

(rat-kingdom-king--deftool "verdict"
    "Give your verdict on a story that waits for your review. pass lets it \
be merged. fix sends it back to a worker with your notes."
    '((:name "story" :type string :description "The story's id.")
      (:name "value" :type string :description "pass or fix.")
      (:name "notes" :type string :optional t
       :description "With fix: what to change, exact enough to act on."))
  (rat-kingdom-king-verdict space (arg 'story) (arg 'value) (arg 'notes)
                           rat-kingdom-king-id))

(rat-kingdom-king--deftool "publish"
    "Push one local branch of a registered repository to one of its \
remotes, and record a receipt. Call this only when the user has explicitly \
asked, in this conversation, for this push; never on your own judgment or \
because of an engine message, and an earlier approval does not cover a new \
push. It never forces: if the remote refuses, for example because the push \
is not a fast-forward, the error is returned and nothing is changed. \
Pushing any other way is blocked."
    '((:name "repo" :type string :description "The repository's name.")
      (:name "branch" :type string
       :description "The local branch to push, for example main or \
rk/integration. It is pushed to the branch of the same name.")
      (:name "remote" :type string :optional t
       :description "The remote to push to. Default origin."))
  (rat-kingdom-git-publish-describe
   (rat-kingdom-git-publish space (arg 'repo) (arg 'branch)
                            :remote (arg 'remote) :actor rat-kingdom-king-id)))

(provide 'rat-kingdom-king)
;;; rat-kingdom-king.el ends here
