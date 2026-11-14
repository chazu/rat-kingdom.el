;;; rat-kingdom-task.el --- Tasks, behind an adapter -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Chaz Straney

;; Author: Chaz Straney <chaz.straney@gmail.com>
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Tasks live in a tracker outside rat-kingdom and are reached through
;; an adapter.  An adapter belongs to one repository and answers seven
;; generic functions:
;;
;;   `rat-kingdom-task-ready'     the tasks ready to be worked on
;;   `rat-kingdom-task-show'      one task
;;   `rat-kingdom-task-create'    a new task; returns its id
;;   `rat-kingdom-task-close'     close a task, with a reason
;;   `rat-kingdom-task-claim'     mark a task as taken by a run
;;   `rat-kingdom-task-release'   give a claimed task back
;;   `rat-kingdom-task-comment'   add a comment to a task
;;
;; A task is a property list with at least `:id', `:title',
;; `:description', `:status' and `:priority', whatever the tracker
;; calls them.
;;
;; The adapter is Rust Beads, the `br' program, and br is required:
;; every registered repository has a br workspace, its checkout's .beads
;; directory, in the user's own checkout and never in a worker's
;; worktree.  br is run there, synchronously and without a shell, with
;; --json.  `rat-kingdom-task-adapter-function' can give a repository
;; another adapter, as the tests do.
;;
;; `rat-kingdom-task-br-ensure' makes the workspace of a repository that
;; has none: registering a repository does, and so does turning on
;; `rat-kingdom-mode' for those already registered.  It runs
;; `br init --prefix PREFIX', checks that the prefix took, and keeps
;; .beads out of Git by adding /.beads/ to info/exclude in the
;; repository's common Git directory, never to .gitignore, so that
;; `git status' does not change; `rat-kingdom-task-br-untracked' turns
;; that off.  A .beads directory that is already there is left exactly
;; as it is.
;;
;; `rat-kingdom-task-project' makes the space show a repository's ready
;; tasks as `available' tuples.  A story started from a task takes its
;; `available' tuple and claims the task.  When the story is merged the
;; task is closed; when it ends otherwise the task is released.  Either
;; way the repository is projected again, so dependents of a closed task
;; become available.  A tracker that fails never stops a story.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'rat-kingdom-space)
(require 'rat-kingdom-git)

(defcustom rat-kingdom-task-br-program "br"
  "The Rust Beads executable."
  :type 'string
  :group 'rat-kingdom)

(define-error 'rat-kingdom-task-error "Task tracker failed")

;;;; The interface

(cl-defgeneric rat-kingdom-task-ready (adapter)
  "Return the tasks ADAPTER's tracker says are ready to be worked on.")

(cl-defgeneric rat-kingdom-task-show (adapter id)
  "Return the task ID from ADAPTER's tracker.")

(cl-defgeneric rat-kingdom-task-create (adapter title &key description priority type parent)
  "Create a task called TITLE in ADAPTER's tracker and return its id.
DESCRIPTION is its text, PRIORITY a number from 0, the most urgent, to
4, TYPE its kind such as \"task\" or \"bug\", and PARENT the id of the
task it belongs to.")

(cl-defgeneric rat-kingdom-task-close (adapter id reason)
  "Close the task ID in ADAPTER's tracker, saying REASON.")

(cl-defgeneric rat-kingdom-task-claim (adapter id run)
  "Mark the task ID in ADAPTER's tracker as being worked on by RUN.")

(cl-defgeneric rat-kingdom-task-release (adapter id)
  "Mark the task ID in ADAPTER's tracker as no longer being worked on.")

(cl-defgeneric rat-kingdom-task-comment (adapter id text)
  "Add the comment TEXT to the task ID in ADAPTER's tracker.")

;;;; Rust Beads

(cl-defstruct (rat-kingdom-task-br (:constructor rat-kingdom-task-br--create)
                                   (:copier nil))
  "A Rust Beads workspace."
  (directory nil :documentation "The directory br is run in."))

(defun rat-kingdom-task-br (repo &optional directory)
  "Return a Rust Beads adapter for the repository record REPO.
Its workspace is DIRECTORY, by default the repository's path."
  (rat-kingdom-task-br--create
   :directory (or directory (plist-get repo :path)
                  (error "The repository %s has no path"
                         (plist-get repo :name)))))

(defun rat-kingdom-task-br--executable ()
  "Return the br executable to run.
Signal `rat-kingdom-task-error' saying br is required if there is none."
  (or (executable-find rat-kingdom-task-br-program)
      (signal 'rat-kingdom-task-error
              (list (format "rat-kingdom requires br, Rust Beads, for its \
tasks, and cannot find the program `%s'.  Install Rust Beads (beads_rust), \
which provides `br', and put it on `exec-path', or set \
`rat-kingdom-task-br-program'"
                            rat-kingdom-task-br-program)))))

(defun rat-kingdom-task-br--call (directory &rest args)
  "Run br with ARGS in DIRECTORY and return what it printed, trimmed.
Signal `rat-kingdom-task-error' with br's own message if it fails."
  (let ((default-directory (file-name-as-directory (expand-file-name directory)))
        (process-environment (cons "RUST_LOG=error" process-environment))
        (program (rat-kingdom-task-br--executable))
        (errors nil))
    (unless (file-directory-p default-directory)
      (signal 'rat-kingdom-task-error
              (list (format "br %s: the directory %s does not exist"
                            (string-join args " ") directory))))
    (setq errors (make-temp-file "rat-kingdom-br"))
    (unwind-protect
        (with-temp-buffer
          (let ((exit (apply #'call-process program nil (list t errors) nil
                             args))
                (output (string-trim (buffer-string))))
            (unless (eql exit 0)
              (signal 'rat-kingdom-task-error
                      (list (format "br %s: %s" (string-join args " ")
                                    (with-temp-buffer
                                      (insert-file-contents errors)
                                      (let ((text (string-trim (buffer-string))))
                                        (if (string-empty-p text) output text)))))))
            output))
      (delete-file errors))))

(defun rat-kingdom-task-br--run (adapter &rest args)
  "Run br with ARGS and --json in ADAPTER's workspace.
Return what it printed, parsed, with objects as property lists and
arrays as lists.  Signal `rat-kingdom-task-error' if it fails."
  (let ((output (apply #'rat-kingdom-task-br--call
                       (rat-kingdom-task-br-directory adapter)
                       (append args '("--json")))))
    (and (not (string-empty-p output))
         (json-parse-string output :object-type 'plist
                            :array-type 'list
                            :null-object nil :false-object nil))))

(defun rat-kingdom-task-br--task (issue)
  "Return the task the br ISSUE describes."
  (list :id (plist-get issue :id)
        :title (plist-get issue :title)
        :description (plist-get issue :description)
        :status (plist-get issue :status)
        :priority (plist-get issue :priority)
        :type (plist-get issue :issue_type)
        :assignee (plist-get issue :assignee)
        :labels (plist-get issue :labels)))

(cl-defmethod rat-kingdom-task-ready ((adapter rat-kingdom-task-br))
  "Return the tasks `br ready' lists in ADAPTER's workspace."
  (mapcar #'rat-kingdom-task-br--task
          (rat-kingdom-task-br--run adapter "ready")))

(cl-defmethod rat-kingdom-task-show ((adapter rat-kingdom-task-br) id)
  "Return the task ID from `br show' in ADAPTER's workspace."
  (rat-kingdom-task-br--task
   (or (car (rat-kingdom-task-br--run adapter "show" id))
       (signal 'rat-kingdom-task-error (list (format "br show %s: no such task" id))))))

(cl-defmethod rat-kingdom-task-create ((adapter rat-kingdom-task-br) title
                                       &key description priority type parent)
  "Create the task TITLE with `br create' in ADAPTER's workspace.
Return its id.  DESCRIPTION, PRIORITY, TYPE and PARENT are as for
the generic function.  Free text is passed as --option=value, so
text that begins with a dash is not taken for an option."
  (plist-get (apply #'rat-kingdom-task-br--run adapter "create"
                    (concat "--title=" title)
                    (append
                     (and description (list (concat "--description=" description)))
                     (and priority (list "--priority" (format "%s" priority)))
                     (and type (list "--type" type))
                     (and parent (list "--parent" parent))))
             :id))

(cl-defmethod rat-kingdom-task-close ((adapter rat-kingdom-task-br) id reason)
  "Close the task ID with `br close' in ADAPTER's workspace, saying REASON."
  (rat-kingdom-task-br--run adapter "close" id (concat "--reason=" reason))
  nil)

(cl-defmethod rat-kingdom-task-claim ((adapter rat-kingdom-task-br) id run)
  "Claim the task ID in ADAPTER's workspace for RUN.
br assigns it to RUN as actor and marks it in progress."
  (rat-kingdom-task-br--run adapter "update" id "--claim" (concat "--actor=" run))
  nil)

(cl-defmethod rat-kingdom-task-release ((adapter rat-kingdom-task-br) id)
  "Release the task ID in ADAPTER's workspace.
It is unassigned and open again."
  (rat-kingdom-task-br--run adapter "update" id "--status" "open" "--assignee=")
  nil)

(cl-defmethod rat-kingdom-task-comment ((adapter rat-kingdom-task-br) id text)
  "Add the comment TEXT to the task ID in ADAPTER's workspace."
  (rat-kingdom-task-br--run adapter "comments" "add" id (concat "--message=" text))
  nil)

;;;; The workspace of a repository

(defcustom rat-kingdom-task-br-untracked t
  "Non-nil means a br workspace rat-kingdom creates is kept out of Git.
When rat-kingdom initializes br in a repository that has no .beads
directory, it adds the line /.beads/ to the info/exclude file in the
repository's common Git directory, so that nothing br writes shows in
`git status'.  Nothing is written to .gitignore, and no tracked file
changes.  Set this to nil to track .beads yourself.  A workspace that
already exists is never touched, whatever this says."
  :type 'boolean
  :group 'rat-kingdom)

(defun rat-kingdom-task-br--exclude-file (top)
  "Return the info/exclude file of the Git repository whose checkout is TOP.
It is in the common Git directory, which linked worktrees share."
  (expand-file-name "info/exclude"
                    (expand-file-name
                     (rat-kingdom-git top "rev-parse" "--git-common-dir")
                     top)))

(defconst rat-kingdom-task-br--exclude-line "/.beads/"
  "The line that keeps a br workspace out of Git.")

(defun rat-kingdom-task-br--excluded-p (file)
  "Return non-nil if the exclude FILE already has the .beads line."
  (and (file-exists-p file)
       (with-temp-buffer
         (insert-file-contents file)
         (member rat-kingdom-task-br--exclude-line
                 (split-string (buffer-string) "\n")))))

(defun rat-kingdom-task-br--exclude (file)
  "Add the .beads line to the exclude FILE unless it has it.
Create FILE and its directory if need be.  Return non-nil if the line
was added."
  (unless (rat-kingdom-task-br--excluded-p file)
    (make-directory (file-name-directory file) t)
    (with-temp-buffer
      (when (file-exists-p file)
        (insert-file-contents file))
      (goto-char (point-max))
      (unless (or (bobp) (eq (char-before) ?\n))
        (insert "\n"))
      (insert rat-kingdom-task-br--exclude-line "\n")
      (let ((coding-system-for-write 'utf-8-unix))
        (write-region nil nil file nil 'silent)))
    t))

(defun rat-kingdom-task-br--unexclude (file)
  "Take the .beads line out of the exclude FILE again."
  (when (file-exists-p file)
    (with-temp-buffer
      (insert-file-contents file)
      (goto-char (point-max))
      (when (re-search-backward
             (concat "^" (regexp-quote rat-kingdom-task-br--exclude-line)
                     "\n")
             nil t)
        (replace-match "")
        (let ((coding-system-for-write 'utf-8-unix))
          (write-region nil nil file nil 'silent))))))

(defun rat-kingdom-task-br-prefix (repo)
  "Return the issue prefix for a br workspace of the repository record REPO.
It is REPO's `:task-prefix', else its name."
  (or (plist-get repo :task-prefix)
      (plist-get repo :name)
      (file-name-nondirectory (directory-file-name (plist-get repo :path)))))

(defvar rat-kingdom-task--workspace-errors nil
  "Repositories whose br workspace could not be made, as (NAME . MESSAGE).")

(defun rat-kingdom-task-workspace-error (repo)
  "Return why the br workspace of the repository REPO could not be made.
Return nil if it was made, or found, the last time it was ensured."
  (cdr (assoc repo rat-kingdom-task--workspace-errors)))

(defun rat-kingdom-task-br-ensure (repo)
  "Make sure the repository REPO has a br workspace.
REPO is a repository record or the path of a checkout.  br is
required: if it cannot be found, signal `rat-kingdom-task-error'
saying so.

If the checkout has a .beads directory, leave it as it is, tracked,
ignored or neither, and return nil.  Otherwise run `br init' there
with the prefix `rat-kingdom-task-br-prefix' gives, check that br
took it, and, if `rat-kingdom-task-br-untracked' is non-nil, add
/.beads/ to the repository's info/exclude and check that `git status'
shows nothing under .beads.  Return non-nil.

If any of that fails, the .beads directory and the exclude line made
here are removed again, and the error, with br's or Git's message, is
signalled.  If REPO is a record, the error is also remembered for
`rat-kingdom-task-workspace-error' until REPO is ensured again."
  (let* ((repo (if (stringp repo) (list :path repo) repo))
         (name (plist-get repo :name)))
    (condition-case err
        (prog1 (rat-kingdom-task-br--ensure repo)
          (when name
            (setq rat-kingdom-task--workspace-errors
                  (assoc-delete-all name rat-kingdom-task--workspace-errors))))
      (error
       (when name
         (setf (alist-get name rat-kingdom-task--workspace-errors
                          nil nil #'equal)
               (error-message-string err)))
       (signal (car err) (cdr err))))))

(defun rat-kingdom-task-br--ensure (repo)
  "Make sure the repository record REPO has a br workspace.
See `rat-kingdom-task-br-ensure'."
  (let* ((path (or (plist-get repo :path)
                   (error "The repository %s has no path"
                          (plist-get repo :name))))
         (top (file-name-as-directory
               (rat-kingdom-git path "rev-parse" "--show-toplevel")))
         (beads (expand-file-name ".beads" top))
         (prefix (rat-kingdom-task-br-prefix repo)))
    (rat-kingdom-task-br--executable)
    (unless (file-directory-p beads)
      (let ((exclude (and rat-kingdom-task-br-untracked
                          (rat-kingdom-task-br--exclude-file top)))
            (added nil)
            (done nil))
        (unwind-protect
            (progn
              (rat-kingdom-task-br--call top "init" "--prefix" prefix)
              (let ((found (plist-get
                            (json-parse-string
                             (rat-kingdom-task-br--call
                              top "config" "get" "issue_prefix" "--json")
                             :object-type 'plist :null-object nil)
                            :value)))
                (unless (equal found prefix)
                  (signal 'rat-kingdom-task-error
                          (list (format "br init --prefix %s in %s left the \
prefix %S; a br configuration may be overriding it" prefix top found)))))
              (when exclude
                (setq added (rat-kingdom-task-br--exclude exclude))
                (let ((status (rat-kingdom-git top "status" "--porcelain"
                                               "--ignored=no" "--" ".beads")))
                  (unless (string-empty-p status)
                    (signal 'rat-kingdom-task-error
                            (list (format "The br workspace in %s still \
shows in git status after excluding it:\n%s" top status))))))
              (setq done t))
          (unless done
            (when (file-directory-p beads)
              (delete-directory beads t))
            (when added
              (rat-kingdom-task-br--unexclude exclude)))))
      t)))

(defun rat-kingdom-task-ensure-all (space)
  "Make sure every repository registered in SPACE has a br workspace.
A repository that fails is reported with a warning, and its reason
kept for `rat-kingdom-task-workspace-error'; the others are still
ensured.  Return the names of the repositories whose workspace was
created."
  (let (created)
    (dolist (repo (rat-kingdom-repo-list space))
      (let ((name (plist-get repo :name)))
        (condition-case err
            (when (rat-kingdom-task-br-ensure repo)
              (push name created)
              (message "rat-kingdom: created a br workspace for %s, kept out \
of Git" name))
          (error
           (display-warning
            'rat-kingdom
            (format "The repository %s has no br workspace, so no tasks: %s"
                    name (error-message-string err))
            :warning)))))
    (nreverse created)))

;;;; Tasks in the space

(defun rat-kingdom-task-default-adapter (repo)
  "Return a Rust Beads adapter for the repository record REPO.
Every registered repository has a br workspace; see
`rat-kingdom-task-br-ensure'."
  (rat-kingdom-task-br repo))

(defcustom rat-kingdom-task-adapter-function #'rat-kingdom-task-default-adapter
  "Function returning the task adapter of a repository.
It is called with the repository's record.  The default gives every
repository its br workspace.  Another function can give a repository
another adapter, such as an in-memory one in tests, or return nil to
leave it without tasks."
  :type 'function
  :group 'rat-kingdom)

(defun rat-kingdom-task-adapter (space repo)
  "Return the task adapter of the repository REPO in SPACE, or nil."
  (when-let* ((record (rat-kingdom-repo-get space repo)))
    (funcall rat-kingdom-task-adapter-function record)))

(defun rat-kingdom-task-project (space repo)
  "Make the `available' tuples of REPO in SPACE match its ready tasks.
A ready task gets one unless it has one or a story is working on it;
a tuple whose task is no longer ready is retracted.  Return how many
tasks are available, or nil if REPO has no adapter or its tracker
failed, in which case SPACE is not touched."
  (when-let* ((adapter (rat-kingdom-task-adapter space repo)))
    (condition-case result
        (rat-kingdom-task-ready adapter)
      (rat-kingdom-task-error
       (message "rat-kingdom: tasks of %s: %s"
                repo (error-message-string result))
       nil)
      (:success (rat-kingdom-task--project space repo result)))))

(defun rat-kingdom-task--project (space repo ready)
  "Make the `available' tuples of REPO in SPACE match the tasks READY.
Return how many there are."
  (rat-kingdom-space-with-transaction space
    (let ((ids (mapcar (lambda (task) (plist-get task :id)) ready)))
      (dolist (tuple (rat-kingdom-space-scan space (list 'available :scope repo)))
        (unless (member (plist-get tuple :identity) ids)
          (rat-kingdom-space-retract
           space (list 'available :id (plist-get tuple :id)) :actor "tasks"))))
    (dolist (task ready)
      (let ((id (plist-get task :id)))
        (unless (or (rat-kingdom-space-rd
                     space (list 'available :scope repo :identity id))
                    (rat-kingdom-space-rd
                     space (list 'story :scope repo :task id)))
          (rat-kingdom-space-out
           space 'available :scope repo :identity id
           :payload (list :title (plist-get task :title)
                          :description (plist-get task :description)
                          :priority (plist-get task :priority)
                          :type (plist-get task :type))
           :actor "tasks"))))
    (length (rat-kingdom-space-scan space (list 'available :scope repo)))))

(defun rat-kingdom-task-project-all (space)
  "Project the ready tasks of every repository in SPACE.
Return how many tasks are available in all."
  (let ((count 0))
    (dolist (repo (rat-kingdom-repo-list space))
      (cl-incf count (or (rat-kingdom-task-project space (plist-get repo :name))
                         0)))
    count))

;;;###autoload
(defun rat-kingdom-tasks-refresh ()
  "Show the ready tasks of every repository as `available' in the space.
First make sure every repository has a br workspace."
  (interactive)
  (let ((space (rat-kingdom-space-default)))
    (rat-kingdom-task-ensure-all space)
    (message "rat-kingdom: %d tasks available"
             (rat-kingdom-task-project-all space))))

;;;; Stories working on tasks

(defun rat-kingdom-task-claim-for-story (space repo task story)
  "Claim TASK of REPO in SPACE for the story STORY.
A tracker failure is reported and otherwise ignored."
  (with-demoted-errors "rat-kingdom: claiming a task: %S"
    (when-let* ((adapter (rat-kingdom-task-adapter space repo)))
      (rat-kingdom-task-claim adapter task story))))

(defun rat-kingdom-task--settle (space repo task reason)
  "Close TASK of REPO in SPACE saying REASON, or release it if REASON is nil.
Then project REPO again.  Errors are reported and otherwise ignored."
  (with-demoted-errors "rat-kingdom: settling a task: %S"
    (when (rat-kingdom-space-db space)
      (when-let* ((adapter (rat-kingdom-task-adapter space repo)))
        (if reason
            (rat-kingdom-task-close adapter task reason)
          (rat-kingdom-task-release adapter task))
        (rat-kingdom-task-project space repo)))))

(defun rat-kingdom-task-story-ended (space story)
  "Settle the task of the token STORY in SPACE, which has ended.
If it was merged, close the task; otherwise release it.  This is done
from a timer, outside any transaction in progress."
  (let ((payload (plist-get story :payload)))
    (when-let* ((task (plist-get payload :task)))
      (run-at-time 0 nil #'rat-kingdom-task--settle
                   space (plist-get story :scope) task
                   (when-let* ((head (plist-get payload :integrated)))
                     (format "Merged into %s at %s" (plist-get payload :target)
                             (substring head 0 (min 7 (length head)))))))))

(defun rat-kingdom-task-story-event (space event story)
  "Settle the task of the token STORY in SPACE if EVENT is `done'.
For `rat-kingdom-story-event-functions'."
  (when (eq event 'done)
    (rat-kingdom-task-story-ended space story)))

(provide 'rat-kingdom-task)
;;; rat-kingdom-task.el ends here
