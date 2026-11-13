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
;; The first adapter is Rust Beads, the `br' program.  Its workspace is
;; a directory, by default the repository's own; br is run there,
;; synchronously and without a shell, with --json.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

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

(defun rat-kingdom-task-br--run (adapter &rest args)
  "Run br with ARGS and --json in ADAPTER's workspace.
Return what it printed, parsed, with objects as property lists and
arrays as lists.  Signal `rat-kingdom-task-error' if it fails."
  (let ((default-directory (file-name-as-directory
                            (expand-file-name
                             (rat-kingdom-task-br-directory adapter))))
        (process-environment (cons "RUST_LOG=error" process-environment))
        (args (append args '("--json")))
        (errors (make-temp-file "rat-kingdom-br")))
    (unwind-protect
        (with-temp-buffer
          (let ((exit (apply #'call-process rat-kingdom-task-br-program nil
                             (list t errors) nil args))
                (output (string-trim (buffer-string))))
            (unless (eql exit 0)
              (signal 'rat-kingdom-task-error
                      (list (format "br %s: %s" (string-join args " ")
                                    (with-temp-buffer
                                      (insert-file-contents errors)
                                      (let ((text (string-trim (buffer-string))))
                                        (if (string-empty-p text) output text)))))))
            (and (not (string-empty-p output))
                 (json-parse-string output :object-type 'plist
                                    :array-type 'list
                                    :null-object nil :false-object nil))))
      (delete-file errors))))

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

(provide 'rat-kingdom-task)
;;; rat-kingdom-task.el ends here
