;;; rat-kingdom-story.el --- One story from start to merge -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Chaz Straney

;; Author: Chaz Straney <chaz.straney@gmail.com>
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A story is one piece of work for one worker.  Its state is a single
;; `story' tuple, the token, whose `:at' says where it is:
;;
;;   ready         waiting for a worktree and a worker
;;   implementing  a worker has it
;;   checking      merged into a candidate; the repository's check runs
;;   done          merged into the target branch; then archived
;;   blocked       stopped; `:reason' says why, and everything is kept
;;
;; Five reactions move the token.  This is the hand-written form of what
;; the workflow engine will compile from data (DESIGN.md, section 7);
;; there is no review step yet, so a story whose check passes is merged.
;;
;; Merging follows rk2.  The worker's commit is merged in a detached
;; candidate worktree, the repository's check runs there, and only then
;; is the target branch moved, and only if it has not moved meanwhile.
;; A failed merge or check keeps the worker's worktree and the candidate.
;; Nothing is pushed.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'rat-kingdom-space)
(require 'rat-kingdom-reaction)
(require 'rat-kingdom-git)
(require 'rat-kingdom-run)

(defconst rat-kingdom-story-output-limit 4000
  "Most characters of a check's output that are kept.")

;;;; Starting a story

(defun rat-kingdom-story--new-id (space)
  "Return a story id not in use in SPACE."
  (let (id)
    (while (or (null id)
               (rat-kingdom-space-rd space (list 'story :identity id)))
      (setq id (format "S-%04x" (random 65536))))
    id))

(defun rat-kingdom-story-start (space repo title &optional description id)
  "Start a story in SPACE for the repository REPO and return its id.
TITLE says what to do in a line; DESCRIPTION gives the acceptance
criteria.  ID names the story; one is made up if it is nil."
  (unless (rat-kingdom-repo-get space repo)
    (error "No repository called %s is registered" repo))
  (let ((id (or id (rat-kingdom-story--new-id space))))
    (when (rat-kingdom-space-rd space (list 'story :identity id))
      (error "There is already a story called %s" id))
    (rat-kingdom-space-out
     space 'story :scope repo :identity id :owner id
     :payload (list :at "ready" :title title :description description)
     :actor "user")
    id))

(defun rat-kingdom-story-get (space id)
  "Return the token of the story ID in SPACE, or nil."
  (rat-kingdom-space-rd space (list 'story :identity id)))

(defun rat-kingdom-story--move (space story place &rest more)
  "Put the taken token STORY back in SPACE at PLACE.
MORE is a property list merged into its payload."
  (let ((payload (plist-put (copy-sequence (plist-get story :payload))
                            :at place)))
    (while more
      (setq payload (plist-put payload (pop more) (pop more))))
    (rat-kingdom-space-out space 'story :scope (plist-get story :scope)
                           :identity (plist-get story :identity)
                           :owner (plist-get story :owner)
                           :payload payload :actor "engine")))

;;;; ready -> implementing

(defun rat-kingdom-story--prompt (story run-id worktree branch)
  "Return what the worker RUN-ID is told about STORY.
It works in WORKTREE on BRANCH."
  (let ((payload (plist-get story :payload)))
    (concat rat-kingdom-run-rat-instructions
            (format "\n\nYou are %s.\nWorktree: %s\nBranch: %s\n\nTask %s: %s\n"
                    run-id worktree branch (plist-get story :identity)
                    (plist-get payload :title))
            (when-let* ((description (plist-get payload :description)))
              (concat "\n" description "\n")))))

(defun rat-kingdom-story--implement (space story)
  "Give the taken token STORY a worktree and a worker in SPACE."
  (let* ((id (plist-get story :identity))
         (repo (or (rat-kingdom-repo-get space (plist-get story :scope))
                   (error "Repository %s is no longer registered"
                          (plist-get story :scope))))
         (path (plist-get repo :path))
         (target (plist-get repo :target))
         (branch (concat "rats/" id))
         (run-id (format "%s.%d" id
                         (1+ (length (rat-kingdom-run-list space id)))))
         (worktree (expand-file-name
                    (format "worktrees/%s/%s" (plist-get repo :name) id)
                    rat-kingdom-directory)))
    (make-directory (file-name-directory worktree) t)
    (rat-kingdom-git path "worktree" "add" "-b" branch worktree target)
    (condition-case err
        (progn
          (rat-kingdom-run-create
           space :id run-id :repo (plist-get repo :name) :story id :role 'rat
           :worktree worktree :branch branch :target target
           :prompt (rat-kingdom-story--prompt story run-id worktree branch))
          (rat-kingdom-story--move space story "implementing"
                                   :run run-id :branch branch
                                   :worktree worktree))
      (error
       ;; The transaction will be rolled back; take the worktree with it.
       (ignore-errors
         (rat-kingdom-git path "worktree" "remove" "--force" worktree))
       (ignore-errors (rat-kingdom-git path "branch" "-D" branch))
       (signal (car err) (cdr err))))))

(rat-kingdom-defreaction rat-kingdom-story-implement
  "Give a ready story a worktree and a worker."
  :take (story :at ready)
  (rat-kingdom-story--implement rat-kingdom-reaction-space
                                (car rat-kingdom-reaction-tuples)))

;;;; implementing -> checking

(defun rat-kingdom-story--record-check (space story value &rest more)
  "Record in SPACE that the check of the token STORY came out as VALUE.
VALUE is \"pass\" or \"fail\".  MORE is a property list for the payload."
  (rat-kingdom-space-put space 'checked :scope (plist-get story :scope)
                         :identity (plist-get story :identity)
                         :owner (plist-get story :owner)
                         :payload (append (list :value value)
                                          (and (equal value "fail")
                                               (not (plist-member more :reason))
                                               (list :reason "check failed"))
                                          more)
                         :actor "engine"))

(defun rat-kingdom-story--run-check (space story command candidate more)
  "Run COMMAND in CANDIDATE and record how it came out for STORY in SPACE.
MORE is a property list recorded with the outcome.  Return at once;
the outcome is recorded when the command exits."
  (let ((buffer (generate-new-buffer " *rat-kingdom check*"))
        (default-directory (file-name-as-directory candidate)))
    (condition-case err
        (make-process
         :name "rat-kingdom-check" :buffer buffer :command command
         :connection-type 'pipe :noquery t
         :sentinel
         (lambda (process _event)
           (unless (process-live-p process)
             (let ((exit (process-exit-status process))
                   (output (with-current-buffer buffer
                             (buffer-substring-no-properties
                              (max (point-min)
                                   (- (point-max)
                                      rat-kingdom-story-output-limit))
                              (point-max)))))
               (kill-buffer buffer)
               (when (rat-kingdom-space-db space)
                 (apply #'rat-kingdom-story--record-check space story
                        (if (eql exit 0) "pass" "fail")
                        :check command :exit exit :output output more))))))
      (error
       (kill-buffer buffer)
       (signal (car err) (cdr err))))))

(defun rat-kingdom-story--check (space story)
  "Merge the result of the taken token STORY in a candidate and check it.
The check's outcome is recorded in SPACE as a `checked' tuple."
  (let* ((id (plist-get story :identity))
         (repo (or (rat-kingdom-repo-get space (plist-get story :scope))
                   (error "Repository %s is no longer registered"
                          (plist-get story :scope))))
         (path (plist-get repo :path))
         (target (plist-get repo :target))
         (result (rat-kingdom-space-rd
                  space (list 'result :scope (plist-get story :scope)
                              :identity id)))
         (commit (plist-get (plist-get result :payload) :commit))
         (base (rat-kingdom-git-rev path target))
         (candidate (expand-file-name
                     (format "candidates/%s/%s-%s" (plist-get repo :name) id
                             (substring commit 0 10))
                     rat-kingdom-directory))
         (check (plist-get repo :check))
         (title (plist-get (plist-get story :payload) :title)))
    (when (file-exists-p candidate)
      (error "The candidate %s is left from an earlier attempt; \
look at it, then remove it" candidate))
    (make-directory (file-name-directory candidate) t)
    (rat-kingdom-git path "worktree" "add" "--detach" candidate base)
    (condition-case err
        (if (not (rat-kingdom-git-ok-p
                  candidate "merge" "--no-ff" "-m"
                  (format "Merge %s: %s" id title) commit))
            (progn
              (rat-kingdom-story--record-check
               space story "fail" :reason "merge conflict"
               :commit commit :base base :candidate candidate)
              (rat-kingdom-story--move space story "checking"
                                       :candidate candidate))
          (let ((facts (list :commit commit :base base :candidate candidate
                             :head (rat-kingdom-git-rev candidate "HEAD"))))
            (rat-kingdom-story--move space story "checking"
                                     :candidate candidate)
            (if check
                (rat-kingdom-story--run-check space story check candidate
                                              facts)
              (apply #'rat-kingdom-story--record-check space story "pass"
                     :check nil facts))))
      (error
       (ignore-errors
         (rat-kingdom-git path "worktree" "remove" "--force" candidate))
       (signal (car err) (cdr err))))))

(rat-kingdom-defreaction rat-kingdom-story-check
  "Merge a reported result in a candidate and run the repository's check."
  :take (story :scope $repo :identity $story :at implementing)
  :read (result :scope $repo :identity $story)
  (rat-kingdom-story--check rat-kingdom-reaction-space
                            (car rat-kingdom-reaction-tuples)))

;;;; checking -> done

(defun rat-kingdom-story--clean-up (space story path head)
  "Remove what the integrated token STORY left behind in SPACE.
PATH is its repository, whose target branch is now at HEAD.  Failures
are reported and otherwise ignored: the work is already merged."
  (let ((payload (plist-get story :payload)))
    (with-demoted-errors "rat-kingdom: cleaning up: %S"
      (rat-kingdom-git path "worktree" "remove" "--force"
                       (plist-get payload :candidate)))
    (with-demoted-errors "rat-kingdom: cleaning up: %S"
      (rat-kingdom-run-stop space (plist-get payload :run)))
    (with-demoted-errors "rat-kingdom: cleaning up: %S"
      ;; Not forced: a worktree the worker dirtied after reporting stays.
      (rat-kingdom-git path "worktree" "remove" (plist-get payload :worktree))
      (when (rat-kingdom-git-ancestor-p
             path (concat "refs/heads/" (plist-get payload :branch)) head)
        (rat-kingdom-git path "branch" "-D" (plist-get payload :branch))))))

(defun rat-kingdom-story--integrate (space story)
  "Move the target branch to the checked merge of the taken token STORY.
Then clean up and archive everything the story owned in SPACE."
  (let* ((id (plist-get story :identity))
         (repo (or (rat-kingdom-repo-get space (plist-get story :scope))
                   (error "Repository %s is no longer registered"
                          (plist-get story :scope))))
         (path (plist-get repo :path))
         (target (plist-get repo :target))
         (checked (plist-get (rat-kingdom-space-rd
                              space (list 'checked
                                          :scope (plist-get story :scope)
                                          :identity id))
                             :payload))
         (head (plist-get checked :head))
         (base (plist-get checked :base)))
    (unless (equal (rat-kingdom-git-rev path target) head)
      (when (rat-kingdom-git-checked-out-p path target)
        (error "%s is checked out in a worktree of %s; it must be free \
to be moved" target (plist-get repo :name)))
      ;; Moves the branch only if it is still where the merge started.
      (rat-kingdom-git path "update-ref" "-m"
                       (format "rat-kingdom: integrate %s" id)
                       (concat "refs/heads/" target) head base))
    (rat-kingdom-story--clean-up space story path head)
    (rat-kingdom-story--move space story "done" :integrated head)
    (rat-kingdom-space-sweep space (plist-get story :owner))
    (message "rat-kingdom: %s is merged into %s of %s"
             id target (plist-get repo :name))))

(rat-kingdom-defreaction rat-kingdom-story-integrate
  "Merge a story whose check passed, then archive it."
  :take (story :scope $repo :identity $story :at checking)
  :read (checked :scope $repo :identity $story :value pass)
  (rat-kingdom-story--integrate rat-kingdom-reaction-space
                                (car rat-kingdom-reaction-tuples)))

;;;; -> blocked

(rat-kingdom-defreaction rat-kingdom-story-check-failed
  "Stop a story whose merge or check failed, keeping everything."
  :take (story :scope $repo :identity $story :at checking)
  :read (checked :scope $repo :identity $story :value fail :reason $why)
  (rat-kingdom-story--move rat-kingdom-reaction-space
                           (car rat-kingdom-reaction-tuples)
                           "blocked" :reason $why))

(rat-kingdom-defreaction rat-kingdom-story-worker-blocked
  "Stop a story whose worker reported that it cannot go on."
  :take (story :scope $repo :identity $story :at implementing)
  :read (blocked :scope $repo :identity $story :summary $why)
  (rat-kingdom-story--move rat-kingdom-reaction-space
                           (car rat-kingdom-reaction-tuples)
                           "blocked" :reason $why))

(provide 'rat-kingdom-story)
;;; rat-kingdom-story.el ends here
