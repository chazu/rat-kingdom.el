;;; rat-kingdom-doc.el --- Research, docs and the researcher -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Chaz Straney

;; Author: Chaz Straney <chaz.straney@gmail.com>
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Research and docs (DESIGN.md, sections 7.1, 8.3 and 9).
;;
;; The built-in `research' workflow gives a story to a researcher, a
;; worker that writes docs instead of committing code, and then to the
;; king for review.  A pass ends the story; nothing is merged.  A fix
;; sends it back to a new researcher, who is told of its drafts and
;; revises them.
;;
;; A doc is a persistent `doc' tuple scoped to its repository, with no
;; owner, so it outlives the story that wrote it.  Its identity is `D-'
;; and four hex digits, and its payload `:title :body :topic :status
;; :story :run :updated'; `:status' is "draft" or "approved", and
;; `:story' and `:run' are the story and run that last wrote it.
;;
;; The researcher's tools are `write_doc', `read_doc', `note_fact',
;; `inbox', `block' and its own `finish', which needs a doc rather than
;; a commit.  A rat has `read_doc' too.  The king has `doc_list',
;; `doc_show' and `doc_forget', and sees a story's docs in `story_show'
;; and `story_diff'.  A consul (rat-kingdom-consul.el) has `write_doc'
;; and `read_doc'; its docs are approved when written, since the user
;; asked for them, and belong to no story.
;;
;; A pass verdict on a story approves its drafts, in the transaction
;; that moves the story on (`rat-kingdom-story-verdict-functions').
;; Every worker's brief lists the repository's approved docs, after the
;; facts and before the messages, and a story's own drafts, so that a
;; researcher sent back by a review revises them.
;;
;; A story that ends at a final place of a workflow with no merge step,
;; as a research story does, has its worktree removed and its branch
;; deleted, unless the branch has commits of its own; then both are
;; kept, and the king's news says so.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'rat-kingdom-space)
(require 'rat-kingdom-git)
(require 'rat-kingdom-mcp)
(require 'rat-kingdom-run)
(require 'rat-kingdom-workflow)
(require 'rat-kingdom-story)
(require 'rat-kingdom-king)
(require 'rat-kingdom-fact)

(defcustom rat-kingdom-doc-max-length 100000
  "Most characters the body of a doc may have."
  :type 'natnum
  :group 'rat-kingdom)

(defcustom rat-kingdom-doc-brief-max-count 40
  "Most approved docs a worker's brief lists."
  :type 'natnum
  :group 'rat-kingdom)

(defcustom rat-kingdom-doc-brief-max-chars 4000
  "Most characters the approved docs in a worker's brief take up together.
The newest docs that fit are listed; the older ones are left out."
  :type 'natnum
  :group 'rat-kingdom)

(defconst rat-kingdom-doc-statuses '("draft" "approved")
  "The statuses a doc can have.")

;;;; The workflow

(rat-kingdom-workflow-define
 'research
 :doc "A researcher writes docs and the king reviews them. No code is merged."
 :places '(ready review done blocked)
 :start 'ready
 :final '(done)
 :steps '((research :from ready :spawn researcher :to review)
          (review :from review :review king :pass done :fix ready)))

;;;; Docs

(defun rat-kingdom-doc--text (value)
  "Return VALUE trimmed, or nil if it is nil or blank."
  (rat-kingdom-fact--blank-to-nil value))

(defun rat-kingdom-doc--id (value)
  "Return VALUE, a doc's id as an argument gives it, trimmed.
Signal an error if it is blank."
  (or (rat-kingdom-doc--text value)
      (error "Give a doc's id, like D-1a2b")))

(defun rat-kingdom-doc--used-p (space id)
  "Return non-nil if ID names a doc in SPACE, live or archived."
  (or (rat-kingdom-space-rd space (list 'doc :identity id))
      (sqlite-select (rat-kingdom-space-db space)
                     "SELECT 1 FROM archive WHERE category = 'doc'
                      AND identity = ? LIMIT 1"
                     (list id))))

(defun rat-kingdom-doc--new-id (space)
  "Return a doc id not in use in SPACE, live or archived."
  (let (id)
    (while (or (null id) (rat-kingdom-doc--used-p space id))
      (setq id (format "D-%04x" (random 65536))))
    id))

(defun rat-kingdom-doc-get (space id)
  "Return the live doc ID in SPACE, a tuple, or nil."
  (rat-kingdom-space-rd space (list 'doc :identity id)))

(cl-defun rat-kingdom-doc-list (space &key repo status story)
  "Return the live docs in SPACE, newest first.
With REPO, only that repository's; with STATUS, only those of that
status; with STORY, only those that story last wrote."
  (let ((docs (rat-kingdom-space-scan
               space (append (list 'doc)
                             (and repo (list :scope repo))
                             (and status (list :status status))
                             (and story (list :story story))))))
    (sort docs (lambda (a b) (> (plist-get a :id) (plist-get b :id))))))

(defun rat-kingdom-doc--field (doc key)
  "Return the payload field KEY of the doc tuple DOC."
  (plist-get (plist-get doc :payload) key))

(defun rat-kingdom-doc--replace (space doc actor &rest changes)
  "Write the doc tuple DOC back to SPACE with CHANGES in its payload.
ACTOR is recorded as who wrote it.  Return the new tuple."
  (let ((payload (copy-sequence (plist-get doc :payload))))
    (while changes
      (setq payload (plist-put payload (pop changes) (pop changes))))
    (rat-kingdom-space-put space 'doc :scope (plist-get doc :scope)
                           :identity (plist-get doc :identity)
                           :payload payload :actor actor)))

(cl-defun rat-kingdom-doc-write (space run &key title body topic id)
  "Write a doc in SPACE for RUN, a run record, and return its tuple.
TITLE and BODY are required; TOPIC is a few words.  Without ID the doc
is new; with it, the doc ID of RUN's repository is replaced whole,
keeping its id.  Either way it is a draft of RUN's story.  RUN must be
its story's working run, or a consul (rat-kingdom-consul.el), whose
docs, written with the user, are approved at once and belong to no
story."
  (let ((title (rat-kingdom-doc--text title))
        (body (rat-kingdom-doc--text body))
        (repo (plist-get run :repo))
        (consul (equal (plist-get run :role) "consul")))
    (unless (or consul
                (and (plist-get run :story)
                     (rat-kingdom-run--story-waiting-p space run)))
      (error "You are not this task's working worker, or you have already \
reported, so you cannot write docs for it"))
    (unless title
      (error "A doc needs a title"))
    (unless body
      (error "A doc needs a body"))
    (when (> (length body) rat-kingdom-doc-max-length)
      (error "A doc's body may have at most %d characters; this one has %d. \
Make it shorter, or split it into several docs"
             rat-kingdom-doc-max-length (length body)))
    (let ((id (if id
                  (let* ((id (rat-kingdom-doc--id id))
                         (doc (rat-kingdom-doc-get space id)))
                    (unless (and doc (equal (plist-get doc :scope) repo))
                      (error "There is no doc %s in %s" id repo))
                    id)
                (rat-kingdom-doc--new-id space))))
      (rat-kingdom-space-put
       space 'doc :scope repo :identity id
       :payload (list :title (replace-regexp-in-string "[\n\t ]+" " " title)
                      :body body
                      :topic (rat-kingdom-doc--text topic)
                      :status (if consul "approved" "draft")
                      :story (plist-get run :story)
                      :run (plist-get run :id)
                      :updated (funcall rat-kingdom-space-now-function))
       :actor (plist-get run :id)))))

(defun rat-kingdom-doc-forget (space id)
  "Move the doc ID of SPACE to the archive, so no worker is told of it.
Return the doc's tuple.  Signal an error if ID is not a live doc."
  (let ((tuple (or (rat-kingdom-space-rd space (list '_ :identity id))
                   (error "There is no live doc %s" id))))
    (unless (eq (plist-get tuple :category) 'doc)
      (error "%s is a %s, not a doc; only docs can be forgotten here"
             id (plist-get tuple :category)))
    (rat-kingdom-space-archive space (plist-get tuple :id) 'forget)))

;;;; The researcher's and the worker's tools

(defun rat-kingdom-doc--write-tool (context arguments)
  "Write the doc in ARGUMENTS for the run CONTEXT names."
  (pcase-let* ((`(,space ,run) (rat-kingdom-run--calling context))
               (revising (rat-kingdom-doc--text (alist-get 'id arguments)))
               (doc (rat-kingdom-doc-write
                     space run
                     :title (alist-get 'title arguments)
                     :body (alist-get 'body arguments)
                     :topic (alist-get 'topic arguments)
                     :id revising)))
    (if (equal (plist-get run :role) "consul")
        (format "%s doc %s: %s. It is approved, so every later worker in %s \
is told of it. To revise it, call write_doc again with the id %s."
                (if revising "Revised" "Wrote")
                (plist-get doc :identity) (rat-kingdom-doc--field doc :title)
                (plist-get doc :scope) (plist-get doc :identity))
      (format "%s doc %s, a draft: %s. To revise it, call write_doc again with \
the id %s. Call finish when your docs are written."
              (if revising "Revised" "Wrote")
              (plist-get doc :identity) (rat-kingdom-doc--field doc :title)
              (plist-get doc :identity)))))

(defun rat-kingdom-doc--describe (doc)
  "Return the doc tuple DOC as `read_doc' shows it."
  (format "%s: %s\nTopic: %s\nStatus: %s\n\n%s"
          (plist-get doc :identity) (rat-kingdom-doc--field doc :title)
          (or (rat-kingdom-doc--field doc :topic) "none")
          (rat-kingdom-doc--field doc :status)
          (rat-kingdom-doc--field doc :body)))

(defun rat-kingdom-doc--read-tool (context arguments)
  "Return the doc in ARGUMENTS, if it is of the repository of CONTEXT's run."
  (pcase-let* ((`(,space ,run) (rat-kingdom-run--calling context))
               (id (rat-kingdom-doc--id (alist-get 'id arguments)))
               (doc (rat-kingdom-doc-get space id)))
    (unless (and doc (equal (plist-get doc :scope) (plist-get run :repo)))
      (error "There is no doc %s in %s" id (plist-get run :repo)))
    (rat-kingdom-doc--describe doc)))

(defun rat-kingdom-doc--finish (context arguments)
  "Record that the calling researcher's work is done.
CONTEXT names the run; ARGUMENTS has `summary' and `checks'.  The
story must have at least one doc; no commit is needed."
  (pcase-let* ((`(,space ,run) (rat-kingdom-run--calling context))
               (story (plist-get run :story)))
    (unless (rat-kingdom-run--story-waiting-p space run)
      (error "This task is no longer waiting for work"))
    (let ((ids (mapcar (lambda (doc) (plist-get doc :identity))
                       (reverse (rat-kingdom-doc-list
                                 space :repo (plist-get run :repo)
                                 :story story)))))
      (unless ids
        (error "You have written no doc for this task. Write what you found \
with write_doc, then finish"))
      (rat-kingdom-space-with-transaction space
        (rat-kingdom-space-put
         space 'result :scope (plist-get run :repo)
         :identity story :owner story
         :payload (list :commit nil :docs ids :run (plist-get run :id)
                        :summary (alist-get 'summary arguments)
                        :checks (alist-get 'checks arguments))
         :actor (plist-get run :id))
        (rat-kingdom-run-update space (plist-get run :id) :state "ready"))
      (format "Recorded your %s: %s. Your task is finished. Stop here; do not \
start other work."
              (if (cdr ids) "docs" "doc") (string-join ids ", ")))))

(rat-kingdom-mcp-define-tool
 "write_doc"
 :description "Write a doc: what you found, for the king to review and, \
once approved, for every later worker in this repository to read. It answers \
with the doc's id. Give id to revise a doc instead of writing a new one; the \
doc is replaced whole."
 :roles '(researcher consul)
 :args '((:name "title" :type string
          :description "The doc's title, one line.")
         (:name "body" :type string
          :description "The doc itself, in Markdown. Make it stand on its \
own: a reader knows nothing of your task.")
         (:name "topic" :type string :optional t
          :description "A few words saying what it is about, e.g. storage.")
         (:name "id" :type string :optional t
          :description "The id of a doc of this repository to revise, like \
D-1a2b. Leave it out to write a new doc."))
 :function #'rat-kingdom-doc--write-tool)

(rat-kingdom-mcp-define-tool
 "read_doc"
 :description "Read a doc of this repository by its id: its title, topic, \
status and text. Your brief lists the approved docs."
 :roles '(rat researcher consul)
 :args '((:name "id" :type string :description "The doc's id, like D-1a2b."))
 :function #'rat-kingdom-doc--read-tool)

(rat-kingdom-mcp-define-tool
 "finish"
 :description "Report that your task is done. Call this once your findings \
are written with write_doc. It fails, and tells you why, if you have written \
no doc. No commit is needed. After it succeeds, stop."
 :roles '(researcher)
 :args '((:name "summary" :type string
          :description "What you found and which docs say it, in a few \
sentences.")
         (:name "checks" :type string
          :description "The checks or experiments you ran and how each came \
out. Say so if you ran none."))
 :function #'rat-kingdom-doc--finish)

;;;; Review

(defun rat-kingdom-doc--approve (space story verdict)
  "Approve the drafts of the token STORY in SPACE if VERDICT is a pass.
For `rat-kingdom-story-verdict-functions'.  On a fix the drafts stay
drafts, for the next worker to revise."
  (when (equal (plist-get verdict :value) "pass")
    (dolist (doc (rat-kingdom-doc-list space :repo (plist-get story :scope)
                                       :status "draft"
                                       :story (plist-get story :identity)))
      (rat-kingdom-doc--replace space doc "engine" :status "approved"))))

(add-hook 'rat-kingdom-story-verdict-functions #'rat-kingdom-doc--approve)

(defun rat-kingdom-doc--line (doc)
  "Return the doc tuple DOC as one line, with its id, title and topic."
  (format "%s: %s%s" (plist-get doc :identity)
          (rat-kingdom-doc--field doc :title)
          (if-let* ((topic (rat-kingdom-doc--field doc :topic)))
              (format " (%s)" topic)
            "")))

(defun rat-kingdom-doc--story-docs (space story)
  "Return the live docs the token STORY in SPACE last wrote, oldest first."
  (reverse (rat-kingdom-doc-list space :repo (plist-get story :scope)
                                 :story (plist-get story :identity))))

(defun rat-kingdom-doc--show (space story tool)
  "Return what the king's TOOL shows of the docs of the token STORY in SPACE.
For `rat-kingdom-king-show-functions'.  For `show' a list of the docs,
with each one's status and length; for `diff' the docs in full."
  (when-let* ((docs (rat-kingdom-doc--story-docs space story)))
    (pcase tool
      ('show
       (concat "Docs:\n"
               (mapconcat
                (lambda (doc)
                  (format "  %s, %s, %d characters"
                          (rat-kingdom-doc--line doc)
                          (rat-kingdom-doc--field doc :status)
                          (length (rat-kingdom-doc--field doc :body))))
                docs "\n")))
      ('diff
       (mapconcat (lambda (doc)
                    (concat "=== Doc " (rat-kingdom-doc--describe doc)))
                  docs "\n\n")))))

(add-hook 'rat-kingdom-king-show-functions #'rat-kingdom-doc--show)

;;;; The brief

(defun rat-kingdom-doc--approved-section (docs)
  "Return the brief's section listing DOCS, approved, newest first."
  (let ((room rat-kingdom-doc-brief-max-chars)
        (count 0)
        entries)
    (cl-loop for doc in docs
             for entry = (concat (rat-kingdom-doc--line doc) "\n")
             while (and (< count rat-kingdom-doc-brief-max-count)
                        (<= (length entry) room))
             do (push entry entries)
             (cl-decf room (length entry))
             (cl-incf count))
    (concat "Approved docs for this repository (read one with read_doc):\n"
            (apply #'concat (nreverse entries))
            (let ((left (- (length docs) count)))
              (if (> left 0)
                  (format "(%d older %s left out.)\n"
                          left (if (= left 1) "doc is" "docs are"))
                "")))))

(defun rat-kingdom-doc-brief (space story _run-id)
  "Return the section of a worker's brief listing docs it should know of.
That is the approved docs of the repository of the token STORY in
SPACE, and the drafts STORY itself last wrote, to be revised.  Return
nil if there are neither."
  (let* ((repo (plist-get story :scope))
         (approved (rat-kingdom-doc-list space :repo repo :status "approved"))
         (drafts (rat-kingdom-doc-list space :repo repo :status "draft"
                                       :story (plist-get story :identity)))
         (sections
          (delq nil
                (list (and approved
                           (rat-kingdom-doc--approved-section approved))
                      (and drafts
                           (concat "Your drafts, to revise with write_doc:\n"
                                   (mapconcat (lambda (doc)
                                                (concat (rat-kingdom-doc--line doc)
                                                        "\n"))
                                              drafts "")))))))
    (and sections (string-join sections "\n"))))

(defun rat-kingdom-doc--add-brief-function ()
  "Put `rat-kingdom-doc-brief' after the facts in a worker's brief.
It goes after `rat-kingdom-fact-brief' in
`rat-kingdom-story-brief-functions', and so before the messages."
  (unless (memq #'rat-kingdom-doc-brief rat-kingdom-story-brief-functions)
    (if (memq #'rat-kingdom-fact-brief rat-kingdom-story-brief-functions)
        (setq rat-kingdom-story-brief-functions
              (cl-mapcan (lambda (function)
                           (if (eq function #'rat-kingdom-fact-brief)
                               (list function #'rat-kingdom-doc-brief)
                             (list function)))
                         rat-kingdom-story-brief-functions))
      (add-hook 'rat-kingdom-story-brief-functions #'rat-kingdom-doc-brief t))))

(rat-kingdom-doc--add-brief-function)

;;;; When a story with nothing to merge ends

(defun rat-kingdom-doc--own-commits-p (path branch target)
  "Return non-nil if BRANCH of the repository at PATH has commits TARGET lacks."
  (not (equal (rat-kingdom-git path "rev-list" "--count"
                               (format "%s..refs/heads/%s" target branch))
              "0")))

(defun rat-kingdom-doc--unmerged-done-p (space story)
  "Return non-nil if the token STORY in SPACE is done with nothing merged."
  (and (not (plist-get (plist-get story :payload) :integrated))
       (rat-kingdom-story-complete-p space story)))

(defun rat-kingdom-doc--clean-up (space story)
  "Remove the worktree and branch of the token STORY in SPACE, if it may.
STORY is done in a workflow that merges nothing.  A branch with commits
of its own is kept, with its worktree.  A worktree with changes is not
removed, and then neither is its branch.  Failures are reported and
otherwise ignored."
  (let* ((payload (plist-get story :payload))
         (worktree (plist-get payload :worktree))
         (branch (plist-get payload :branch))
         (repo (rat-kingdom-repo-get space (plist-get story :scope)))
         (path (plist-get repo :path))
         (target (rat-kingdom-story-target space story)))
    (when (and worktree branch path target (file-directory-p worktree))
      (with-demoted-errors "rat-kingdom: cleaning up: %S"
        (unless (rat-kingdom-doc--own-commits-p path branch target)
          (rat-kingdom-git path "worktree" "remove" worktree)
          (rat-kingdom-git path "branch" "-D" branch))))))

(defun rat-kingdom-doc--story-event (space event story)
  "Clean up after the token STORY in SPACE if EVENT ends it with nothing merged.
For `rat-kingdom-story-event-functions'."
  (when (and (eq event 'done) (rat-kingdom-doc--unmerged-done-p space story))
    (rat-kingdom-doc--clean-up space story)))

;; Before the king's news, which says what was kept.
(add-hook 'rat-kingdom-story-event-functions #'rat-kingdom-doc--story-event -50)

(defun rat-kingdom-doc--news (space event story)
  "Return what the king should hear of the docs of STORY after EVENT in SPACE.
For `rat-kingdom-king-news-functions'.  When it waits for review, its
docs; when it is done with nothing merged, its approved docs and what
became of its worktree."
  (let ((docs (rat-kingdom-doc--story-docs space story))
        (payload (plist-get story :payload)))
    (pcase event
      ('review
       (and docs
            (format "Its docs, which story_diff shows in full: %s."
                    (mapconcat #'rat-kingdom-doc--line docs "; "))))
      ((and 'done (guard (rat-kingdom-doc--unmerged-done-p space story)))
       (let* ((worktree (plist-get payload :worktree))
              (branch (plist-get payload :branch))
              (kept (and worktree (file-directory-p worktree))))
         (string-join
          (delq nil
                (list
                 (and docs
                      (format "Its docs: %s."
                              (mapconcat
                               (lambda (doc)
                                 (format "%s, %s" (rat-kingdom-doc--line doc)
                                         (rat-kingdom-doc--field doc :status)))
                               docs "; ")))
                 (cond
                  ((null worktree) nil)
                  (kept
                   (format "Its worktree %s and branch %s are kept: %s"
                           worktree branch
                           (if (when-let* ((repo (rat-kingdom-repo-get
                                                  space (plist-get story :scope)))
                                           (target (rat-kingdom-story-target
                                                    space story)))
                                 (ignore-errors
                                   (rat-kingdom-doc--own-commits-p
                                    (plist-get repo :path) branch target)))
                               "the branch has commits of its own, which \
nothing merges. Look at them with story_diff."
                             "the worktree could not be removed, perhaps \
because it has changes.")))
                  (t "Its worktree and branch are removed."))))
          " "))))))

(add-hook 'rat-kingdom-king-news-functions #'rat-kingdom-doc--news)

;;;; The king's tools

(defun rat-kingdom-doc--status (value)
  "Return VALUE, the `status' argument, as a status, or nil if blank."
  (when-let* ((status (rat-kingdom-doc--text value)))
    (unless (member status rat-kingdom-doc-statuses)
      (error "A doc's status is draft or approved, not %s" status))
    status))

(defun rat-kingdom-doc--when (doc)
  "Return when the doc tuple DOC was last written, as a local time."
  (rat-kingdom-fact--time (or (rat-kingdom-doc--field doc :updated)
                              (plist-get doc :created))))

(rat-kingdom-king--deftool "doc_list"
    "List the docs of a repository, newest first: id, status, title, topic, \
the story that last wrote it, and when. Researchers write docs; a pass on \
their story approves them, and every worker is told of the approved ones."
    '((:name "repo" :type string :description "The repository's name.")
      (:name "status" :type string :optional t
       :description "Only docs of this status: draft or approved."))
  (let* ((repo (arg 'repo))
         (status (rat-kingdom-doc--status (arg 'status)))
         (_ (unless (rat-kingdom-repo-get space repo)
              (error "No repository called %s is registered" repo)))
         (docs (rat-kingdom-doc-list space :repo repo :status status)))
    (if (null docs)
        (format "%s has no %sdocs." repo (if status (concat status " ") ""))
      (concat
       (format "%d %s in %s, newest first:\n" (length docs)
               (if (cdr docs) "docs" "doc") repo)
       (mapconcat (lambda (doc)
                    (format "%s [%s] %s%s; by %s, %s"
                            (plist-get doc :identity)
                            (rat-kingdom-doc--field doc :status)
                            (rat-kingdom-doc--field doc :title)
                            (if-let* ((topic (rat-kingdom-doc--field doc :topic)))
                                (format " (%s)" topic)
                              "")
                            (or (rat-kingdom-doc--field doc :story) "-")
                            (rat-kingdom-doc--when doc)))
                  docs "\n")))))

(rat-kingdom-king--deftool "doc_show"
    "Show one doc in full: its text and its fields, and who wrote it."
    '((:name "id" :type string :description "The doc's id, like D-1a2b."))
  (let* ((id (rat-kingdom-doc--id (arg 'id)))
         (doc (or (rat-kingdom-doc-get space id)
                  (error "There is no live doc %s; see doc_list" id))))
    (format "%s in %s: %s\nStatus: %s\nTopic: %s\nStory: %s\nRun: %s\n\
Written: %s\nRecorded by: %s\n\n%s"
            id (plist-get doc :scope) (rat-kingdom-doc--field doc :title)
            (rat-kingdom-doc--field doc :status)
            (or (rat-kingdom-doc--field doc :topic) "none")
            (or (rat-kingdom-doc--field doc :story) "-")
            (or (rat-kingdom-doc--field doc :run) "-")
            (rat-kingdom-doc--when doc)
            (or (rat-kingdom-fact--actor space (plist-get doc :id)) "-")
            (rat-kingdom-doc--field doc :body))))

(rat-kingdom-king--deftool "doc_forget"
    "Remove one doc, by its id, when it is wrong or no longer wanted. \
Workers are no longer told of it. It is archived, so query with archived \
true still finds it."
    '((:name "id" :type string :description "The doc's id, like D-1a2b."))
  (let* ((id (rat-kingdom-doc--id (arg 'id)))
         (doc (rat-kingdom-doc-forget space id)))
    (format "Forgot doc %s of %s: %s" id (plist-get doc :scope)
            (rat-kingdom-doc--field doc :title))))

(provide 'rat-kingdom-doc)
;;; rat-kingdom-doc.el ends here
