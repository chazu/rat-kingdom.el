;;; rat-kingdom-fact.el --- What workers learn, and the king's look into the space -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Chaz Straney

;; Author: Chaz Straney <chaz.straney@gmail.com>
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Facts (DESIGN.md, sections 5.4, 8.3 and 9).
;;
;; A worker that learns something durable and non-obvious about its
;; repository records it with the `note_fact' tool.  The fact is a
;; persistent `fact' tuple scoped to the repository with no owner, so
;; it outlives the story that wrote it and is never swept with it.
;;
;; Every worker started later in the same repository is told the
;; repository's facts, newest first, in its brief: this file adds a
;; section to `rat-kingdom-story-brief-functions'.  The section is
;; capped by `rat-kingdom-fact-brief-max-count' and
;; `rat-kingdom-fact-brief-max-chars'.
;;
;; Agents write and rules read (section 5.5), but the king is the
;; exception: it has `query', a read-only look into the space, and
;; `fact_forget', which removes a fact that turned out to be wrong.

;;; Code:

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'rat-kingdom-space)
(require 'rat-kingdom-mcp)
(require 'rat-kingdom-run)
(require 'rat-kingdom-story)
(require 'rat-kingdom-king)

(defcustom rat-kingdom-fact-max-length 1500
  "Most characters a fact's text may have."
  :type 'natnum
  :group 'rat-kingdom)

(defcustom rat-kingdom-fact-brief-max-count 40
  "Most facts a worker's brief lists."
  :type 'natnum
  :group 'rat-kingdom)

(defcustom rat-kingdom-fact-brief-max-chars 8000
  "Most characters the facts in a worker's brief take up together.
The newest facts that fit are listed; the older ones are left out."
  :type 'natnum
  :group 'rat-kingdom)

(defcustom rat-kingdom-fact-query-default-limit 20
  "How many tuples `query' shows when it is not told."
  :type 'natnum
  :group 'rat-kingdom)

(defconst rat-kingdom-fact-query-max-limit 200
  "Most tuples `query' shows at once.")

(defcustom rat-kingdom-fact-query-payload-limit 1500
  "Most characters of a tuple's payload that `query' shows."
  :type 'natnum
  :group 'rat-kingdom)

;;;; Recording

(defun rat-kingdom-fact--blank-to-nil (value)
  "Return VALUE trimmed, or nil if it is nil or blank."
  (when value
    (let ((text (string-trim (format "%s" value))))
      (and (not (string-empty-p text)) text))))

(defun rat-kingdom-fact--files (value)
  "Return the paths in VALUE, a comma-separated string or a list, or nil."
  (delq nil (mapcar #'rat-kingdom-fact--blank-to-nil
                    (if (listp value) value (split-string value ",")))))

(cl-defun rat-kingdom-fact-note (space run text &key topic files)
  "Record in SPACE the fact TEXT learned by RUN, a run record.
TOPIC is a few words, FILES a list of paths it concerns.  The fact is
scoped to RUN's repository and has no owner, so it outlives RUN's
story.  Return the tuple."
  (let ((text (rat-kingdom-fact--blank-to-nil text)))
    (unless text
      (error "A fact needs some text"))
    (when (> (length text) rat-kingdom-fact-max-length)
      (error "A fact may have at most %d characters; this one has %d. \
Make it shorter, or record it as several facts"
             rat-kingdom-fact-max-length (length text)))
    (rat-kingdom-space-out
     space 'fact :scope (plist-get run :repo)
     :payload (list :text text
                    :topic (rat-kingdom-fact--blank-to-nil topic)
                    :files files
                    :story (plist-get run :story)
                    :run (plist-get run :id))
     :actor (plist-get run :id))))

(defun rat-kingdom-fact--note-tool (context arguments)
  "Record the fact in ARGUMENTS for the run CONTEXT names."
  (pcase-let* ((`(,space ,run) (rat-kingdom-run--calling context))
               (files (alist-get 'files arguments))
               (tuple (rat-kingdom-fact-note
                       space run (alist-get 'fact arguments)
                       :topic (alist-get 'topic arguments)
                       :files (and files (rat-kingdom-fact--files files)))))
    (format "Recorded fact %d. Workers started later in %s will be told it."
            (plist-get tuple :id) (plist-get tuple :scope))))

(rat-kingdom-mcp-define-tool
 "note_fact"
 :description "Record something durable and non-obvious you learned about \
this repository, for the workers who come after you: a convention, a pitfall, \
how to build or test something, where something lives. Every later worker in \
this repository is told it. Do not use it to report progress on your task."
 :roles '(rat)
 :args '((:name "fact" :type string
          :description "The fact, as a self-contained statement that makes \
sense without your task, e.g. \"Tests need the ELDEV_LOCAL variable set; run \
them with eldev -dtT test.\"")
         (:name "topic" :type string :optional t
          :description "A few words saying what it is about, e.g. testing.")
         (:name "files" :type string :optional t
          :description "Paths it concerns, relative to the repository, \
separated by commas."))
 :function #'rat-kingdom-fact--note-tool)

;;;; The brief

(defun rat-kingdom-fact-list (space repo)
  "Return the facts of REPO in SPACE, newest first."
  (reverse (rat-kingdom-space-scan space (list 'fact :scope repo))))

(defun rat-kingdom-fact--entry (fact)
  "Return the tuple FACT as an entry of a worker's brief."
  (let* ((payload (plist-get fact :payload))
         (topic (plist-get payload :topic))
         (files (plist-get payload :files)))
    (concat "- " (if topic (format "[%s] " topic) "")
            (string-replace "\n" "\n  " (plist-get payload :text))
            (if files
                (format "\n  Files: %s" (string-join files ", "))
              "")
            "\n")))

(defun rat-kingdom-fact-brief (space story _run-id)
  "Return the section of a worker's brief listing the facts of STORY's repo.
SPACE holds them.  Return nil if the repository has none."
  (when-let* ((facts (rat-kingdom-fact-list space (plist-get story :scope))))
    (let ((room rat-kingdom-fact-brief-max-chars)
          (count 0)
          entries)
      (cl-loop for fact in facts
               for entry = (rat-kingdom-fact--entry fact)
               while (and (< count rat-kingdom-fact-brief-max-count)
                          (<= (length entry) room))
               do (push entry entries)
               (cl-decf room (length entry))
               (cl-incf count))
      (concat "Facts recorded by earlier workers in this repository \
(newest first):\n"
              (apply #'concat (nreverse entries))
              (let ((left (- (length facts) count)))
                (if (> left 0)
                    (format "(%d older %s left out.)\n"
                            left (if (= left 1) "fact is" "facts are"))
                  ""))))))

(add-hook 'rat-kingdom-story-brief-functions #'rat-kingdom-fact-brief t)

;;;; The king's query

(defun rat-kingdom-fact--categories ()
  "Return the names of every known tuple category, sorted."
  (sort (delete-dups
         (mapcar (lambda (entry) (symbol-name (car entry)))
                 (append rat-kingdom-space-builtin-categories
                         rat-kingdom-space-categories)))
        #'string<))

(defun rat-kingdom-fact--category (name)
  "Return the category NAME as a symbol, or signal an error naming the known."
  (let ((category (intern (string-trim (format "%s" name)))))
    (unless (rat-kingdom-space-category-modality category)
      (error "There is no category %s; the categories are: %s"
             name (string-join (rat-kingdom-fact--categories) ", ")))
    category))

(defun rat-kingdom-fact--boolean (value name)
  "Return VALUE, the argument NAME, as t or nil.  Nil and blank are nil."
  (pcase (if (stringp value) (downcase (string-trim value)) value)
    ((or 'nil :false "" "false" "no" "0" "nil") nil)
    ((or 't "true" "yes" "1" "t") t)
    (_ (error "%s is true or false, not %s" name value))))

(defun rat-kingdom-fact--limit (value)
  "Return VALUE, the `limit' argument, as a number of tuples to show."
  (let ((limit (cond ((null value) rat-kingdom-fact-query-default-limit)
                     ((numberp value) value)
                     ((string-match-p "\\`[ \t]*[0-9]+[ \t]*\\'" value)
                      (string-to-number value))
                     (t (error "limit is a number, not %s" value)))))
    (max 1 (min (truncate limit) rat-kingdom-fact-query-max-limit))))

(defun rat-kingdom-fact--actor (space id)
  "Return who wrote the tuple ID in SPACE, from its operations log, or nil."
  (caar (sqlite-select (rat-kingdom-space-db space)
                       "SELECT actor FROM ops WHERE tuple_id = ? AND op = 'out'
                        ORDER BY id LIMIT 1"
                       (list id))))

(defun rat-kingdom-fact--payload-text (payload)
  "Return PAYLOAD, a property list, printed one key a line."
  (let (lines)
    (while payload
      (let ((key (pop payload))
            (value (pop payload)))
        (push (format "  %s %s" key
                      (if (stringp value)
                          (string-replace "\n" "\n    " value)
                        (prin1-to-string value)))
              lines)))
    (string-join (nreverse lines) "\n")))

(defun rat-kingdom-fact--truncate (text limit)
  "Return TEXT cut to LIMIT characters, saying how much was cut."
  (if (<= (length text) limit)
      text
    (format "%s… (%d more characters)" (substring text 0 limit)
            (- (length text) limit))))

(defun rat-kingdom-fact--time (time)
  "Return TIME, in seconds, as a local date and time, or \"-\"."
  (if time (format-time-string "%Y-%m-%d %H:%M:%S" time) "-"))

(defun rat-kingdom-fact--describe (space tuple)
  "Return TUPLE of SPACE as a block of `query''s answer."
  (string-join
   (delq nil
         (list (format "id: %s" (plist-get tuple :id))
               (format "category: %s" (plist-get tuple :category))
               (format "scope: %s" (plist-get tuple :scope))
               (format "identity: %s" (or (plist-get tuple :identity) "-"))
               (format "owner: %s" (or (plist-get tuple :owner) "-"))
               (format "actor: %s" (or (rat-kingdom-fact--actor
                                        space (plist-get tuple :id))
                                       "-"))
               (format "time: %s" (rat-kingdom-fact--time
                                   (plist-get tuple :created)))
               (and (plist-get tuple :archived)
                    (format "archived: %s (%s)"
                            (rat-kingdom-fact--time (plist-get tuple :archived))
                            (plist-get tuple :reason)))
               (if (plist-get tuple :payload)
                   (concat "payload:\n"
                           (rat-kingdom-fact--truncate
                            (rat-kingdom-fact--payload-text
                             (plist-get tuple :payload))
                            rat-kingdom-fact-query-payload-limit))
                 "payload: none")))
   "\n"))

(cl-defun rat-kingdom-fact-query (space category &key scope identity owner
                                        contains archived limit)
  "Return the tuples of CATEGORY in SPACE that match, newest first.
SCOPE, IDENTITY and OWNER, when given, must equal the tuple's.
CONTAINS, when given, must occur in the printed payload, ignoring
case.  With ARCHIVED, archived tuples are searched too.  Return a
property list: `:tuples', at most LIMIT of them, and `:total', how
many matched.  Nothing is written."
  (let* ((pattern (append (list category)
                          (and scope (list :scope scope))
                          (and identity (list :identity identity))
                          (and owner (list :owner owner))))
         (needle (and contains (downcase contains)))
         (tuples
          (cl-remove-if-not
           (lambda (tuple)
             (or (null needle)
                 (string-search needle
                                (downcase (prin1-to-string
                                           (plist-get tuple :payload))))))
           (append (rat-kingdom-space-scan space pattern)
                   (and archived
                        (cl-remove-if-not
                         (lambda (tuple) (rat-kingdom-space-match pattern tuple))
                         (rat-kingdom-space-archived space owner))))))
         (tuples (sort tuples (lambda (a b) (> (plist-get a :id)
                                               (plist-get b :id))))))
    (list :tuples (seq-take tuples (or limit (length tuples)))
          :total (length tuples))))

(rat-kingdom-king--deftool "query"
    "Look into the space, read-only: list the tuples of one category, newest \
first, with their fields and payload. Use it to see facts workers recorded, a \
story's results, runs, or anything else in the space."
    '((:name "category" :type string
       :description "The tuple category, e.g. fact, story, run, result, \
blocked, checked, message, repo.")
      (:name "scope" :type string :optional t
       :description "Only tuples of this scope: a repository's name, or \
system.")
      (:name "identity" :type string :optional t
       :description "Only tuples with this identity, e.g. a story or run id.")
      (:name "owner" :type string :optional t
       :description "Only tuples this owner holds, e.g. a story id.")
      (:name "contains" :type string :optional t
       :description "Only tuples whose printed payload contains this text, \
ignoring case.")
      (:name "archived" :type string :optional t
       :description "true to include archived tuples, those of finished \
stories. Default false: live tuples only.")
      (:name "limit" :type string :optional t
       :description "Most tuples to show. Default 20, at most 200."))
  (let* ((category (rat-kingdom-fact--category (arg 'category)))
         (limit (rat-kingdom-fact--limit (arg 'limit)))
         (archived (rat-kingdom-fact--boolean (arg 'archived) "archived"))
         (found (rat-kingdom-fact-query
                 space category
                 :scope (arg 'scope) :identity (arg 'identity)
                 :owner (arg 'owner) :contains (arg 'contains)
                 :archived archived :limit limit))
         (tuples (plist-get found :tuples))
         (total (plist-get found :total)))
    (if (null tuples)
        (format "No %s%s tuples match." (if archived "live or archived " "")
                category)
      (concat
       (format "%d %s match%s, newest first.%s\n\n"
               total (if (= total 1) "tuple" "tuples")
               (if (= total 1) "es" "")
               (if (< (length tuples) total)
                   (format " The list is cut off: showing the newest %d. \
Narrow the query or raise limit to see more." (length tuples))
                 ""))
       (mapconcat (lambda (tuple) (rat-kingdom-fact--describe space tuple))
                  tuples "\n\n")))))

(rat-kingdom-king--deftool "fact_forget"
    "Remove one fact from the space, by its id, when it has turned out to \
be wrong or stale. Workers are no longer told it. Find ids with query, \
category fact."
    '((:name "id" :type string :description "The fact's id, a number."))
  (let* ((text (format "%s" (arg 'id)))
         (id (if (string-match-p "\\`[ \t]*[0-9]+[ \t]*\\'" text)
                 (string-to-number text)
               (error "A fact's id is a number, not %s" text)))
         (tuple (or (rat-kingdom-space-rd space (list '_ :id id))
                    (error "There is no live tuple %d" id))))
    (unless (eq (plist-get tuple :category) 'fact)
      (error "Tuple %d is a %s, not a fact; only facts can be forgotten"
             id (plist-get tuple :category)))
    (rat-kingdom-space-retract space (list 'fact :id id)
                               :actor rat-kingdom-king-id)
    (format "Forgot fact %d of %s: %s" id (plist-get tuple :scope)
            (truncate-string-to-width
             (plist-get (plist-get tuple :payload) :text) 200 nil nil "…"))))

(provide 'rat-kingdom-fact)
;;; rat-kingdom-fact.el ends here
