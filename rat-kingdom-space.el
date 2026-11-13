;;; rat-kingdom-space.el --- The rat-kingdom tuplespace, in SQLite -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Chaz Straney

;; Author: Chaz Straney <chaz.straney@gmail.com>
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A tuplespace kept in one SQLite file (DESIGN.md, section 5).
;;
;; A tuple is a property list:
;;
;;   (:id 7 :category result :scope "myrepo" :identity "S-12"
;;    :payload (:commit "abc123" :summary "done")
;;    :modality persistent :owner "S-12" :created 1.7e9 :expires nil)
;;
;; A pattern names a category and constrains any of the fields.  `:id',
;; `:scope', `:identity', `:owner' and `:modality' are the tuple's own
;; fields; every other keyword is a payload key.  A symbol that starts
;; with `$' is a variable, and `_' matches anything.  (The reader takes
;; `?x' for a character, so `?' cannot mark one.)
;;
;;   (result :scope $repo :identity $story :commit $c)
;;
;; Four operations, as in Linda:
;;
;;   `rat-kingdom-space-out'   write a tuple
;;   `rat-kingdom-space-in'    take one match (never a persistent tuple)
;;   `rat-kingdom-space-rd'    read one match
;;   `rat-kingdom-space-scan'  read every match
;;
;; plus `rat-kingdom-space-put' and `rat-kingdom-space-retract' for persistent tuples,
;; `rat-kingdom-space-sweep' to archive everything an owner holds, and
;; `rat-kingdom-space-expire' to archive tuples past their time.
;;
;; Payloads are stored as JSON so that other processes can write tuples
;; into the same file.  A symbol in a payload is stored as its name, so
;; (:at ready) reads back as (:at "ready"); patterns are compared the
;; same way, so (story :at ready) still matches it.
;;
;; Every write is appended to an operations log, and functions on
;; `rat-kingdom-space-change-functions' run after each transaction
;; commits.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

;;;; Vocabulary

(defvar rat-kingdom-space-categories
  '((story . linear)
    (available . linear)
    (run . persistent)
    (result . persistent)
    (blocked . persistent)
    (checked . persistent)
    (review . linear)
    (verdict . linear)
    (message . linear)
    (doc . persistent)
    (fact . persistent)
    (policy . persistent)
    (event . affine)
    (stuck . persistent)
    (repo . persistent))
  "Alist of tuple categories and the modality each one defaults to.
Writing a tuple in a category that is not listed here is an error.
Add to it with `rat-kingdom-space-define-category'.")

(defconst rat-kingdom-space-modalities '(linear persistent affine)
  "The modalities a tuple can have.
A linear tuple is consumed once.  A persistent tuple stays until it is
retracted or its owner is swept, and `rat-kingdom-space-in' never takes it.
An affine tuple is consumed at most once and otherwise expires.")

(defconst rat-kingdom-space-reserved-keys '(:id :scope :identity :owner :modality)
  "Pattern keys that name a tuple's own fields, so no payload may use them.")

(defun rat-kingdom-space-define-category (category modality)
  "Add CATEGORY to the vocabulary, defaulting to MODALITY."
  (unless (memq modality rat-kingdom-space-modalities)
    (error "Unknown modality: %S" modality))
  (setf (alist-get category rat-kingdom-space-categories) modality))

;;;; The space

(cl-defstruct (rat-kingdom-space (:constructor rat-kingdom-space--create)
				 (:copier nil))
  "An open tuplespace."
  (db nil :documentation "The SQLite connection.")
  (file nil :documentation "The database file.")
  (depth 0 :documentation "Non-zero inside a transaction.")
  (pending nil :documentation "Changes to announce at commit, newest first."))

(defvar rat-kingdom-space-change-functions nil
  "Functions called after a transaction that changed a space commits.
Each is called with three arguments, once per change and in order: the
space, the operation and its subject.  For the operations `out', `in'
and `retract' the subject is the tuple.  For `sweep' and `expire' it
is a property list with `:count', and `:owner' for a sweep.

Changes made by another process are not announced; compare
`rat-kingdom-space-data-version' over time to notice those.")

(defvar rat-kingdom-space-now-function #'float-time
  "Function returning the current time in seconds.  Tests replace it.")

(defconst rat-kingdom-space--schema-version 1)

(defconst rat-kingdom-space--columns
  "id, category, scope, identity, payload, modality, owner, created, expires")

(defconst rat-kingdom-space--schema
  '("CREATE TABLE tuples (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       category TEXT NOT NULL,
       scope TEXT NOT NULL,
       identity TEXT,
       payload TEXT NOT NULL DEFAULT '{}',
       modality TEXT NOT NULL,
       owner TEXT,
       created REAL NOT NULL,
       expires REAL)"
    "CREATE INDEX tuples_key ON tuples (category, scope, identity)"
    "CREATE INDEX tuples_owner ON tuples (owner)"
    "CREATE TABLE archive (
       id INTEGER PRIMARY KEY,
       category TEXT NOT NULL,
       scope TEXT NOT NULL,
       identity TEXT,
       payload TEXT NOT NULL,
       modality TEXT NOT NULL,
       owner TEXT,
       created REAL NOT NULL,
       expires REAL,
       archived REAL NOT NULL,
       reason TEXT NOT NULL)"
    "CREATE INDEX archive_owner ON archive (owner)"
    "CREATE TABLE ops (
       id INTEGER PRIMARY KEY AUTOINCREMENT,
       op TEXT NOT NULL,
       tuple_id INTEGER NOT NULL,
       category TEXT NOT NULL,
       scope TEXT NOT NULL,
       identity TEXT,
       payload TEXT NOT NULL,
       actor TEXT,
       at REAL NOT NULL)"))

;;;; Transactions

(defun rat-kingdom-space--call-in-transaction (space function)
  "Call FUNCTION in a transaction on SPACE and return its value.
Inside another transaction on SPACE, join that one."
  (if (> (rat-kingdom-space-depth space) 0)
      (funcall function)
    (let ((db (rat-kingdom-space-db space))
          (committed nil)
          result)
      (sqlite-execute db "BEGIN IMMEDIATE")
      (setf (rat-kingdom-space-depth space) 1
            (rat-kingdom-space-pending space) nil)
      (unwind-protect
          (progn
            (setq result (funcall function))
            (sqlite-execute db "COMMIT")
            (setq committed t))
        (setf (rat-kingdom-space-depth space) 0)
        (unless committed
          (setf (rat-kingdom-space-pending space) nil)
          (ignore-errors (sqlite-execute db "ROLLBACK"))))
      (let ((changes (nreverse (rat-kingdom-space-pending space))))
        (setf (rat-kingdom-space-pending space) nil)
        (dolist (change changes)
          (dolist (function rat-kingdom-space-change-functions)
            (with-demoted-errors "rat-kingdom-space change function: %S"
              (funcall function space (car change) (cdr change))))))
      result)))

(defmacro rat-kingdom-space-with-transaction (space &rest body)
  "Run BODY in one transaction on SPACE and return its value.
If BODY exits non-locally, nothing it wrote is kept and nothing is
announced.  A transaction inside another one joins it."
  (declare (indent 1) (debug t))
  `(rat-kingdom-space--call-in-transaction ,space (lambda () ,@body)))

(defun rat-kingdom-space--announce (space op subject)
  "Record that OP happened to SUBJECT in SPACE, to announce at commit."
  (push (cons op subject) (rat-kingdom-space-pending space)))

(defun rat-kingdom-space--now ()
  "Return the current time."
  (funcall rat-kingdom-space-now-function))

(defun rat-kingdom-space-open (file)
  "Open the tuplespace in FILE, creating it if needed."
  (unless (and (fboundp 'sqlite-available-p) (sqlite-available-p))
    (error "This Emacs was built without SQLite support"))
  (let* ((file (expand-file-name file))
         (db (progn (make-directory (file-name-directory file) t)
                    (sqlite-open file)))
         (space (rat-kingdom-space--create :db db :file file)))
    (sqlite-pragma db "journal_mode = WAL")
    (sqlite-pragma db "busy_timeout = 5000")
    (let ((version (caar (sqlite-select db "PRAGMA user_version"))))
      (cond
       ((eql version 0)
        (rat-kingdom-space--call-in-transaction
         space
         (lambda ()
           (dolist (statement rat-kingdom-space--schema)
             (sqlite-execute db statement))
           (sqlite-execute db (format "PRAGMA user_version = %d"
                                      rat-kingdom-space--schema-version)))))
       ((eql version rat-kingdom-space--schema-version))
       (t
        (sqlite-close db)
        (error "%s has schema version %s; this rat-kingdom reads version %d"
               file version rat-kingdom-space--schema-version))))
    space))

(defcustom rat-kingdom-directory (locate-user-emacs-file "rat-kingdom/")
  "Directory for rat-kingdom's own files: the space, worktrees, candidates."
  :type 'directory
  :group 'rat-kingdom)

(defcustom rat-kingdom-space-default-file
  (expand-file-name "space.db" rat-kingdom-directory)
  "The file holding the space that rat-kingdom works in."
  :type 'file
  :group 'rat-kingdom)

(defvar rat-kingdom-space--default nil
  "The open default space, or nil.")

(defun rat-kingdom-space-default ()
  "Return the space in `rat-kingdom-space-default-file', opening it if needed."
  (unless (and rat-kingdom-space--default
               (rat-kingdom-space-db rat-kingdom-space--default))
    (setq rat-kingdom-space--default
          (rat-kingdom-space-open rat-kingdom-space-default-file)))
  rat-kingdom-space--default)

(defun rat-kingdom-space-close (space)
  "Close SPACE."
  (when-let* ((db (rat-kingdom-space-db space)))
    (sqlite-close db)
    (setf (rat-kingdom-space-db space) nil)))

(defun rat-kingdom-space-data-version (space)
  "Return a number that changes when another process writes to SPACE."
  (caar (sqlite-select (rat-kingdom-space-db space) "PRAGMA data_version")))

;;;; Values

(defun rat-kingdom-space--json-value (value)
  "Return VALUE in the form `json-serialize' takes."
  (cond
   ((memq value '(t :false :null)) value)
   ((null value) :null)
   ((keywordp value) (error "A keyword is not a payload value: %S" value))
   ((symbolp value) (symbol-name value))
   ((or (stringp value) (numberp value)) value)
   ((vectorp value) (cl-map 'vector #'rat-kingdom-space--json-value value))
   ((and (consp value) (keywordp (car value)))
    (let (object)
      (while value
        (unless (and (keywordp (car value)) (cdr value))
          (error "Malformed property list in payload: %S" value))
        (push (pop value) object)
        (push (rat-kingdom-space--json-value (pop value)) object))
      (nreverse object)))
   ((proper-list-p value) (cl-map 'vector #'rat-kingdom-space--json-value value))
   (t (error "Not a payload value: %S" value))))

(defun rat-kingdom-space--canon (value)
  "Return VALUE as it would read back from the space."
  (cond
   ((memq value '(t :false)) value)
   ((memq value '(nil :null)) nil)
   ((symbolp value) (symbol-name value))
   ((vectorp value) (mapcar #'rat-kingdom-space--canon value))
   ((and (consp value) (keywordp (car value)))
    (let (object)
      (while value
        (push (pop value) object)
        (push (rat-kingdom-space--canon (pop value)) object))
      (nreverse object)))
   ((consp value) (mapcar #'rat-kingdom-space--canon value))
   (t value)))

(defun rat-kingdom-space--encode (payload)
  "Return PAYLOAD, a property list, as JSON text."
  (if (null payload)
      "{}"
    (json-serialize (rat-kingdom-space--json-value payload))))

(defun rat-kingdom-space--decode (text)
  "Return the payload property list in the JSON TEXT."
  (json-parse-string text :object-type 'plist :array-type 'list
                     :null-object nil :false-object :false))

(defun rat-kingdom-space--field (value)
  "Return VALUE as a scope, identity or owner is stored."
  (cond ((null value) nil)
        ((stringp value) value)
        ((symbolp value) (symbol-name value))
        (t (format "%s" value))))

(defun rat-kingdom-space--row-tuple (row)
  "Return the tuple in ROW, a row of `rat-kingdom-space--columns'."
  (pcase-let ((`(,id ,category ,scope ,identity ,payload ,modality
                     ,owner ,created ,expires)
               row))
    (list :id id :category (intern category) :scope scope
          :identity identity :payload (rat-kingdom-space--decode payload)
          :modality (intern modality) :owner owner
          :created created :expires expires)))

;;;; Patterns

(defconst rat-kingdom-space-no-bindings '((t . t))
  "What a successful match with no variables returns.")

(defun rat-kingdom-space-variable-p (term)
  "Return non-nil if TERM is a pattern variable such as `$story'."
  (and (symbolp term) (not (keywordp term))
       (string-prefix-p "$" (symbol-name term))))

(defun rat-kingdom-space--open-p (term)
  "Return non-nil if TERM is a variable or the wildcard `_'."
  (or (eq term '_) (rat-kingdom-space-variable-p term)))

(defun rat-kingdom-space--check-pattern (pattern)
  "Signal an error unless PATTERN is well formed."
  (unless (and (consp pattern) (symbolp (car pattern))
               (not (keywordp (car pattern))) (car pattern))
    (error "A pattern starts with a category: %S" pattern))
  (let ((fields (cdr pattern)))
    (while fields
      (unless (and (keywordp (car fields)) (cdr fields))
        (error "Malformed pattern: %S" pattern))
      (setq fields (cddr fields)))))

(defun rat-kingdom-space--match-term (term actual bindings)
  "Match pattern TERM against ACTUAL under BINDINGS.
Return the bindings, extended if TERM is a new variable, or nil."
  (cond
   ((eq term '_) bindings)
   ((rat-kingdom-space-variable-p term)
    (let ((bound (assq term bindings)))
      (cond ((null bound) (cons (cons term actual) bindings))
            ((equal (cdr bound) actual) bindings))))
   ((equal (rat-kingdom-space--canon term) actual) bindings)))

(defun rat-kingdom-space-match (pattern tuple &optional bindings)
  "Match PATTERN against TUPLE.
Return an alist of variable bindings, starting from BINDINGS, or nil
if TUPLE does not match.  A match with no variables returns
`rat-kingdom-space-no-bindings', which is not nil.

A variable does not match a payload key the tuple lacks, nor a nil
scope, identity or owner; the wildcard `_' matches both."
  (rat-kingdom-space--check-pattern pattern)
  (let ((bindings (or bindings rat-kingdom-space-no-bindings))
        (fields (cdr pattern))
        (payload (plist-get tuple :payload)))
    (setq bindings
          (if (rat-kingdom-space--open-p (car pattern))
              (rat-kingdom-space--match-term (car pattern)
					     (plist-get tuple :category) bindings)
            (and (eq (car pattern) (plist-get tuple :category)) bindings)))
    (while (and bindings fields)
      (let* ((key (pop fields))
             (term (pop fields))
             (own (memq key rat-kingdom-space-reserved-keys))
             (actual (cond ((eq key :modality)
                            (symbol-name (plist-get tuple :modality)))
                           (own (plist-get tuple key))
                           (t (plist-get payload key))))
             (present (if own actual (plist-member payload key))))
        (setq bindings
              (if (and (rat-kingdom-space-variable-p term) (not present))
                  nil
                (rat-kingdom-space--match-term term actual bindings)))))
    bindings))

(defun rat-kingdom-space--candidates (space pattern)
  "Return the live tuples in SPACE that PATTERN's fixed fields allow.
Oldest first.  The caller still has to match each one."
  (rat-kingdom-space--check-pattern pattern)
  (let ((where (list "(expires IS NULL OR expires > ?)"))
        (arguments (list (rat-kingdom-space--now)))
        (fields (cdr pattern)))
    (unless (rat-kingdom-space--open-p (car pattern))
      (push "category = ?" where)
      (push (symbol-name (car pattern)) arguments))
    (dolist (column '((:id . "id") (:scope . "scope") (:identity . "identity")
                      (:owner . "owner") (:modality . "modality")))
      (when (plist-member fields (car column))
        (let ((term (plist-get fields (car column))))
          (cond ((rat-kingdom-space--open-p term))
                ((null term)
                 (push (format "%s IS NULL" (cdr column)) where))
                (t
                 (push (format "%s = ?" (cdr column)) where)
                 (push (if (eq (car column) :id) term (rat-kingdom-space--field term))
                       arguments))))))
    (mapcar #'rat-kingdom-space--row-tuple
            (sqlite-select
             (rat-kingdom-space-db space)
             (format "SELECT %s FROM tuples WHERE %s ORDER BY id"
                     rat-kingdom-space--columns
                     (string-join (nreverse where) " AND "))
             (nreverse arguments)))))

;;;; Writing

(defun rat-kingdom-space--log (space op tuple actor)
  "Append OP on TUPLE by ACTOR to SPACE's operations log."
  (sqlite-execute
   (rat-kingdom-space-db space)
   "INSERT INTO ops (op, tuple_id, category, scope, identity, payload, actor, at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
   (list (symbol-name op)
         (plist-get tuple :id)
         (symbol-name (plist-get tuple :category))
         (plist-get tuple :scope)
         (plist-get tuple :identity)
         (rat-kingdom-space--encode (plist-get tuple :payload))
         (rat-kingdom-space--field actor)
         (rat-kingdom-space--now))))

(defun rat-kingdom-space--check-payload (payload)
  "Signal an error unless PAYLOAD is a property list a tuple can carry."
  (let ((rest payload))
    (while rest
      (unless (and (keywordp (car rest)) (consp (cdr rest)))
        (error "A payload is a property list with keyword keys: %S" payload))
      (when (memq (car rest) rat-kingdom-space-reserved-keys)
        (error "%s names a tuple field and cannot be a payload key"
               (car rest)))
      (setq rest (cddr rest)))))

(cl-defun rat-kingdom-space-out (space category
				       &key (scope "system") identity payload
				       modality owner ttl actor)
  "Write a tuple of CATEGORY to SPACE and return it.
SCOPE is a repository name and defaults to \"system\".  IDENTITY names
what the tuple is about.  PAYLOAD is a property list.  MODALITY
defaults to the category's own.  OWNER is the story or epic whose
lifetime the tuple shares.  TTL is how many seconds the tuple lives;
an affine tuple must have one.  ACTOR is recorded in the log."
  (let ((default (alist-get category rat-kingdom-space-categories)))
    (unless default
      (error "Unknown tuple category: %S" category))
    (setq modality (or modality default)))
  (unless (memq modality rat-kingdom-space-modalities)
    (error "Unknown modality: %S" modality))
  (when (and (eq modality 'affine) (not ttl))
    (error "An affine tuple needs a :ttl"))
  (when (and ttl (not (and (numberp ttl) (> ttl 0))))
    (error "A :ttl is a positive number of seconds: %S" ttl))
  (rat-kingdom-space--check-payload payload)
  (let* ((now (rat-kingdom-space--now))
         (json (rat-kingdom-space--encode payload))
         (tuple (list :id nil :category category
                      :scope (rat-kingdom-space--field scope)
                      :identity (rat-kingdom-space--field identity)
                      :payload (rat-kingdom-space--canon payload)
                      :modality modality
                      :owner (rat-kingdom-space--field owner)
                      :created now
                      :expires (and ttl (+ now ttl))))
         (db (rat-kingdom-space-db space)))
    (unless (plist-get tuple :scope)
      (error "A tuple needs a scope"))
    (rat-kingdom-space-with-transaction space
      (sqlite-execute
       db
       "INSERT INTO tuples (category, scope, identity, payload, modality,
                            owner, created, expires)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
       (list (symbol-name category) (plist-get tuple :scope)
             (plist-get tuple :identity) json (symbol-name modality)
             (plist-get tuple :owner) now (plist-get tuple :expires)))
      (setq tuple (plist-put tuple :id
                             (caar (sqlite-select
                                    db "SELECT last_insert_rowid()"))))
      (rat-kingdom-space--log space 'out tuple actor)
      (rat-kingdom-space--announce space 'out tuple))
    tuple))

(defun rat-kingdom-space--delete (space tuple op actor)
  "Delete TUPLE from SPACE, logging and announcing it as OP by ACTOR."
  (sqlite-execute (rat-kingdom-space-db space) "DELETE FROM tuples WHERE id = ?"
                  (list (plist-get tuple :id)))
  (rat-kingdom-space--log space op tuple actor)
  (rat-kingdom-space--announce space op tuple))

(cl-defun rat-kingdom-space-put (space category
				       &rest keys
				       &key (scope "system") identity
				       &allow-other-keys)
  "Write a tuple of CATEGORY to SPACE, replacing any with the same key.
The key is CATEGORY, SCOPE and IDENTITY, and IDENTITY is required.
KEYS are as for `rat-kingdom-space-out'.  Return the new tuple."
  (unless identity
    (error "rat-kingdom-space-put needs an :identity"))
  (rat-kingdom-space-with-transaction space
    (rat-kingdom-space-retract space (list category :scope scope :identity identity)
			       :actor (plist-get keys :actor))
    (apply #'rat-kingdom-space-out space category keys)))

(cl-defun rat-kingdom-space-retract (space pattern &key actor)
  "Remove every tuple in SPACE matching PATTERN, of any modality.
Return how many were removed.  ACTOR is recorded in the log."
  (rat-kingdom-space-with-transaction space
    (let ((count 0))
      (dolist (tuple (rat-kingdom-space--candidates space pattern))
        (when (rat-kingdom-space-match pattern tuple)
          (rat-kingdom-space--delete space tuple 'retract actor)
          (cl-incf count)))
      count)))

;;;; Reading

(defun rat-kingdom-space-scan (space pattern)
  "Return every tuple in SPACE matching PATTERN, oldest first."
  (cl-remove-if-not (lambda (tuple) (rat-kingdom-space-match pattern tuple))
                    (rat-kingdom-space--candidates space pattern)))

(defun rat-kingdom-space-matches (space pattern &optional bindings)
  "Return every match of PATTERN in SPACE that agrees with BINDINGS.
Each element is (TUPLE . BINDINGS), the bindings extended with
PATTERN's variables.  Oldest tuple first.  Reactions build joins
from this."
  (let (matches)
    (dolist (tuple (rat-kingdom-space--candidates space pattern))
      (when-let* ((extended (rat-kingdom-space-match pattern tuple bindings)))
        (push (cons tuple extended) matches)))
    (nreverse matches)))

(defun rat-kingdom-space-rd (space pattern)
  "Return the oldest tuple in SPACE matching PATTERN, or nil."
  (cl-find-if (lambda (tuple) (rat-kingdom-space-match pattern tuple))
              (rat-kingdom-space--candidates space pattern)))

(cl-defun rat-kingdom-space-in (space pattern &key actor)
  "Take the oldest tuple matching PATTERN out of SPACE and return it.
Return nil if there is none.  Persistent tuples are never taken; use
`rat-kingdom-space-retract' for those.  ACTOR is recorded in the log."
  (rat-kingdom-space-with-transaction space
    (when-let* ((tuple (cl-find-if
                        (lambda (tuple)
                          (and (not (eq (plist-get tuple :modality) 'persistent))
                               (rat-kingdom-space-match pattern tuple)))
                        (rat-kingdom-space--candidates space pattern))))
      (rat-kingdom-space--delete space tuple 'in actor)
      tuple)))

;;;; Lifetime

(defun rat-kingdom-space--archive (space condition arguments reason)
  "Move the tuples in SPACE satisfying CONDITION to the archive.
CONDITION is SQL with ARGUMENTS for its parameters.  REASON, a symbol,
is recorded with each tuple and as the operation in the log.  Return
how many tuples moved."
  (let ((db (rat-kingdom-space-db space))
        (now (rat-kingdom-space--now))
        (reason (symbol-name reason)))
    (sqlite-execute
     db
     (format "INSERT INTO ops (op, tuple_id, category, scope, identity,
                               payload, actor, at)
              SELECT ?, id, category, scope, identity, payload, NULL, ?
              FROM tuples WHERE %s ORDER BY id"
             condition)
     (append (list reason now) arguments))
    (sqlite-execute
     db
     (format "INSERT INTO archive SELECT %s, ?, ? FROM tuples WHERE %s"
             rat-kingdom-space--columns condition)
     (append (list now reason) arguments))
    (sqlite-execute db (format "DELETE FROM tuples WHERE %s" condition)
                    arguments)))

(defun rat-kingdom-space-sweep (space owner)
  "Archive every tuple in SPACE that OWNER holds.  Return how many."
  (let ((owner (rat-kingdom-space--field owner)))
    (unless owner
      (error "rat-kingdom-space-sweep needs an owner"))
    (rat-kingdom-space-with-transaction space
      (let ((count (rat-kingdom-space--archive space "owner = ?" (list owner) 'sweep)))
        (when (> count 0)
          (rat-kingdom-space--announce space 'sweep (list :owner owner :count count)))
        count))))

(defun rat-kingdom-space-expire (space)
  "Archive every tuple in SPACE whose time has passed.  Return how many."
  (rat-kingdom-space-with-transaction space
    (let ((count (rat-kingdom-space--archive space "expires IS NOT NULL AND expires <= ?"
					     (list (rat-kingdom-space--now)) 'expire)))
      (when (> count 0)
        (rat-kingdom-space--announce space 'expire (list :count count)))
      count)))

;;;; Inspection

(defun rat-kingdom-space-counts (space)
  "Return an alist of category and live tuple count for SPACE.
Categories with no tuples are left out.  Sorted by category name."
  (mapcar (lambda (row) (cons (intern (car row)) (cadr row)))
          (sqlite-select
           (rat-kingdom-space-db space)
           "SELECT category, COUNT(*) FROM tuples
            WHERE expires IS NULL OR expires > ?
            GROUP BY category ORDER BY category"
           (list (rat-kingdom-space--now)))))

(defun rat-kingdom-space-archived (space &optional owner)
  "Return the archived tuples of SPACE, oldest first.
With OWNER, only those it held.  Each tuple also has `:archived', the
time it was archived, and `:reason', `sweep' or `expire'."
  (mapcar
   (lambda (row)
     (append (rat-kingdom-space--row-tuple (butlast row 2))
             (list :archived (nth 9 row) :reason (intern (nth 10 row)))))
   (sqlite-select
    (rat-kingdom-space-db space)
    (format "SELECT %s, archived, reason FROM archive %s ORDER BY id"
            rat-kingdom-space--columns (if owner "WHERE owner = ?" ""))
    (and owner (list (rat-kingdom-space--field owner))))))

(defun rat-kingdom-space-ops (space &optional limit)
  "Return the operations log of SPACE, oldest first.
With LIMIT, only the newest LIMIT entries.  Each entry is a property
list: `:op', `:tuple-id', `:category', `:scope', `:identity',
`:payload', `:actor' and `:at'."
  (nreverse
   (mapcar
    (pcase-lambda (`(,op ,tuple-id ,category ,scope ,identity ,payload
                         ,actor ,at))
      (list :op (intern op) :tuple-id tuple-id :category (intern category)
            :scope scope :identity identity
            :payload (rat-kingdom-space--decode payload) :actor actor :at at))
    (sqlite-select
     (rat-kingdom-space-db space)
     (concat "SELECT op, tuple_id, category, scope, identity, payload, actor, at
              FROM ops ORDER BY id DESC"
             (and limit " LIMIT ?"))
     (and limit (list limit))))))

(provide 'rat-kingdom-space)
;;; rat-kingdom-space.el ends here
