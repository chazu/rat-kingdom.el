;;; rk3-space.el --- The rk3 tuplespace, in SQLite -*- lexical-binding: t; -*-

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
;;   `rk3-space-out'   write a tuple
;;   `rk3-space-in'    take one match (never a persistent tuple)
;;   `rk3-space-rd'    read one match
;;   `rk3-space-scan'  read every match
;;
;; plus `rk3-space-put' and `rk3-space-retract' for persistent tuples,
;; `rk3-space-sweep' to archive everything an owner holds, and
;; `rk3-space-expire' to archive tuples past their time.
;;
;; Payloads are stored as JSON so that other processes can write tuples
;; into the same file.  A symbol in a payload is stored as its name, so
;; (:at ready) reads back as (:at "ready"); patterns are compared the
;; same way, so (story :at ready) still matches it.
;;
;; Every write is appended to an operations log, and functions on
;; `rk3-space-change-functions' run after each transaction commits.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

;;;; Vocabulary

(defvar rk3-space-categories
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
    (stuck . persistent))
  "Alist of tuple categories and the modality each one defaults to.
Writing a tuple in a category that is not listed here is an error.
Add to it with `rk3-space-define-category'.")

(defconst rk3-space-modalities '(linear persistent affine)
  "The modalities a tuple can have.
A linear tuple is consumed once.  A persistent tuple stays until it is
retracted or its owner is swept, and `rk3-space-in' never takes it.
An affine tuple is consumed at most once and otherwise expires.")

(defconst rk3-space-reserved-keys '(:id :scope :identity :owner :modality)
  "Pattern keys that name a tuple's own fields, so no payload may use them.")

(defun rk3-space-define-category (category modality)
  "Add CATEGORY to the vocabulary, defaulting to MODALITY."
  (unless (memq modality rk3-space-modalities)
    (error "Unknown modality: %S" modality))
  (setf (alist-get category rk3-space-categories) modality))

;;;; The space

(cl-defstruct (rk3-space (:constructor rk3-space--create)
                         (:copier nil))
  "An open tuplespace."
  (db nil :documentation "The SQLite connection.")
  (file nil :documentation "The database file.")
  (depth 0 :documentation "Non-zero inside a transaction.")
  (pending nil :documentation "Changes to announce at commit, newest first."))

(defvar rk3-space-change-functions nil
  "Functions called after a transaction that changed a space commits.
Each is called with three arguments, once per change and in order: the
space, the operation and its subject.  For the operations `out', `in'
and `retract' the subject is the tuple.  For `sweep' and `expire' it
is a property list with `:count', and `:owner' for a sweep.

Changes made by another process are not announced; compare
`rk3-space-data-version' over time to notice those.")

(defvar rk3-space-now-function #'float-time
  "Function returning the current time in seconds.  Tests replace it.")

(defconst rk3-space--schema-version 1)

(defconst rk3-space--columns
  "id, category, scope, identity, payload, modality, owner, created, expires")

(defconst rk3-space--schema
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

(defun rk3-space--call-in-transaction (space function)
  "Call FUNCTION in a transaction on SPACE and return its value.
Inside another transaction on SPACE, join that one."
  (if (> (rk3-space-depth space) 0)
      (funcall function)
    (let ((db (rk3-space-db space))
          (committed nil)
          result)
      (sqlite-execute db "BEGIN IMMEDIATE")
      (setf (rk3-space-depth space) 1
            (rk3-space-pending space) nil)
      (unwind-protect
          (progn
            (setq result (funcall function))
            (sqlite-execute db "COMMIT")
            (setq committed t))
        (setf (rk3-space-depth space) 0)
        (unless committed
          (setf (rk3-space-pending space) nil)
          (ignore-errors (sqlite-execute db "ROLLBACK"))))
      (let ((changes (nreverse (rk3-space-pending space))))
        (setf (rk3-space-pending space) nil)
        (dolist (change changes)
          (dolist (function rk3-space-change-functions)
            (with-demoted-errors "rk3-space change function: %S"
              (funcall function space (car change) (cdr change))))))
      result)))

(defmacro rk3-space-with-transaction (space &rest body)
  "Run BODY in one transaction on SPACE and return its value.
If BODY exits non-locally, nothing it wrote is kept and nothing is
announced.  A transaction inside another one joins it."
  (declare (indent 1) (debug t))
  `(rk3-space--call-in-transaction ,space (lambda () ,@body)))

(defun rk3-space--announce (space op subject)
  "Record that OP happened to SUBJECT in SPACE, to announce at commit."
  (push (cons op subject) (rk3-space-pending space)))

(defun rk3-space--now ()
  "Return the current time."
  (funcall rk3-space-now-function))

(defun rk3-space-open (file)
  "Open the tuplespace in FILE, creating it if needed."
  (unless (and (fboundp 'sqlite-available-p) (sqlite-available-p))
    (error "This Emacs was built without SQLite support"))
  (let* ((file (expand-file-name file))
         (db (progn (make-directory (file-name-directory file) t)
                    (sqlite-open file)))
         (space (rk3-space--create :db db :file file)))
    (sqlite-pragma db "journal_mode = WAL")
    (sqlite-pragma db "busy_timeout = 5000")
    (let ((version (caar (sqlite-select db "PRAGMA user_version"))))
      (cond
       ((eql version 0)
        (rk3-space--call-in-transaction
         space
         (lambda ()
           (dolist (statement rk3-space--schema)
             (sqlite-execute db statement))
           (sqlite-execute db (format "PRAGMA user_version = %d"
                                      rk3-space--schema-version)))))
       ((eql version rk3-space--schema-version))
       (t
        (sqlite-close db)
        (error "%s has schema version %s; this rk3 reads version %d"
               file version rk3-space--schema-version))))
    space))

(defun rk3-space-close (space)
  "Close SPACE."
  (when-let* ((db (rk3-space-db space)))
    (sqlite-close db)
    (setf (rk3-space-db space) nil)))

(defun rk3-space-data-version (space)
  "Return a number that changes when another process writes to SPACE."
  (caar (sqlite-select (rk3-space-db space) "PRAGMA data_version")))

;;;; Values

(defun rk3-space--json-value (value)
  "Return VALUE in the form `json-serialize' takes."
  (cond
   ((memq value '(t :false :null)) value)
   ((null value) :null)
   ((keywordp value) (error "A keyword is not a payload value: %S" value))
   ((symbolp value) (symbol-name value))
   ((or (stringp value) (numberp value)) value)
   ((vectorp value) (cl-map 'vector #'rk3-space--json-value value))
   ((and (consp value) (keywordp (car value)))
    (let (object)
      (while value
        (unless (and (keywordp (car value)) (cdr value))
          (error "Malformed property list in payload: %S" value))
        (push (pop value) object)
        (push (rk3-space--json-value (pop value)) object))
      (nreverse object)))
   ((proper-list-p value) (cl-map 'vector #'rk3-space--json-value value))
   (t (error "Not a payload value: %S" value))))

(defun rk3-space--canon (value)
  "Return VALUE as it would read back from the space."
  (cond
   ((memq value '(t :false)) value)
   ((memq value '(nil :null)) nil)
   ((symbolp value) (symbol-name value))
   ((vectorp value) (mapcar #'rk3-space--canon value))
   ((and (consp value) (keywordp (car value)))
    (let (object)
      (while value
        (push (pop value) object)
        (push (rk3-space--canon (pop value)) object))
      (nreverse object)))
   ((consp value) (mapcar #'rk3-space--canon value))
   (t value)))

(defun rk3-space--encode (payload)
  "Return PAYLOAD, a property list, as JSON text."
  (if (null payload)
      "{}"
    (json-serialize (rk3-space--json-value payload))))

(defun rk3-space--decode (text)
  "Return the payload property list in the JSON TEXT."
  (json-parse-string text :object-type 'plist :array-type 'list
                     :null-object nil :false-object :false))

(defun rk3-space--field (value)
  "Return VALUE as a scope, identity or owner is stored."
  (cond ((null value) nil)
        ((stringp value) value)
        ((symbolp value) (symbol-name value))
        (t (format "%s" value))))

(defun rk3-space--row-tuple (row)
  "Return the tuple in ROW, a row of `rk3-space--columns'."
  (pcase-let ((`(,id ,category ,scope ,identity ,payload ,modality
                     ,owner ,created ,expires)
               row))
    (list :id id :category (intern category) :scope scope
          :identity identity :payload (rk3-space--decode payload)
          :modality (intern modality) :owner owner
          :created created :expires expires)))

;;;; Patterns

(defconst rk3-space-no-bindings '((t . t))
  "What a successful match with no variables returns.")

(defun rk3-space-variable-p (term)
  "Return non-nil if TERM is a pattern variable such as `$story'."
  (and (symbolp term) (not (keywordp term))
       (string-prefix-p "$" (symbol-name term))))

(defun rk3-space--open-p (term)
  "Return non-nil if TERM is a variable or the wildcard `_'."
  (or (eq term '_) (rk3-space-variable-p term)))

(defun rk3-space--check-pattern (pattern)
  "Signal an error unless PATTERN is well formed."
  (unless (and (consp pattern) (symbolp (car pattern))
               (not (keywordp (car pattern))) (car pattern))
    (error "A pattern starts with a category: %S" pattern))
  (let ((fields (cdr pattern)))
    (while fields
      (unless (and (keywordp (car fields)) (cdr fields))
        (error "Malformed pattern: %S" pattern))
      (setq fields (cddr fields)))))

(defun rk3-space--match-term (term actual bindings)
  "Match pattern TERM against ACTUAL under BINDINGS.
Return the bindings, extended if TERM is a new variable, or nil."
  (cond
   ((eq term '_) bindings)
   ((rk3-space-variable-p term)
    (let ((bound (assq term bindings)))
      (cond ((null bound) (cons (cons term actual) bindings))
            ((equal (cdr bound) actual) bindings))))
   ((equal (rk3-space--canon term) actual) bindings)))

(defun rk3-space-match (pattern tuple &optional bindings)
  "Match PATTERN against TUPLE.
Return an alist of variable bindings, starting from BINDINGS, or nil
if TUPLE does not match.  A match with no variables returns
`rk3-space-no-bindings', which is not nil.

A variable does not match a payload key the tuple lacks, nor a nil
scope, identity or owner; the wildcard `_' matches both."
  (rk3-space--check-pattern pattern)
  (let ((bindings (or bindings rk3-space-no-bindings))
        (fields (cdr pattern))
        (payload (plist-get tuple :payload)))
    (setq bindings
          (if (rk3-space--open-p (car pattern))
              (rk3-space--match-term (car pattern)
                                     (plist-get tuple :category) bindings)
            (and (eq (car pattern) (plist-get tuple :category)) bindings)))
    (while (and bindings fields)
      (let* ((key (pop fields))
             (term (pop fields))
             (own (memq key rk3-space-reserved-keys))
             (actual (cond ((eq key :modality)
                            (symbol-name (plist-get tuple :modality)))
                           (own (plist-get tuple key))
                           (t (plist-get payload key))))
             (present (if own actual (plist-member payload key))))
        (setq bindings
              (if (and (rk3-space-variable-p term) (not present))
                  nil
                (rk3-space--match-term term actual bindings)))))
    bindings))

(defun rk3-space--candidates (space pattern)
  "Return the live tuples in SPACE that PATTERN's fixed fields allow.
Oldest first.  The caller still has to match each one."
  (rk3-space--check-pattern pattern)
  (let ((where (list "(expires IS NULL OR expires > ?)"))
        (arguments (list (rk3-space--now)))
        (fields (cdr pattern)))
    (unless (rk3-space--open-p (car pattern))
      (push "category = ?" where)
      (push (symbol-name (car pattern)) arguments))
    (dolist (column '((:id . "id") (:scope . "scope") (:identity . "identity")
                      (:owner . "owner") (:modality . "modality")))
      (when (plist-member fields (car column))
        (let ((term (plist-get fields (car column))))
          (cond ((rk3-space--open-p term))
                ((null term)
                 (push (format "%s IS NULL" (cdr column)) where))
                (t
                 (push (format "%s = ?" (cdr column)) where)
                 (push (if (eq (car column) :id) term (rk3-space--field term))
                       arguments))))))
    (mapcar #'rk3-space--row-tuple
            (sqlite-select
             (rk3-space-db space)
             (format "SELECT %s FROM tuples WHERE %s ORDER BY id"
                     rk3-space--columns
                     (string-join (nreverse where) " AND "))
             (nreverse arguments)))))

;;;; Writing

(defun rk3-space--log (space op tuple actor)
  "Append OP on TUPLE by ACTOR to SPACE's operations log."
  (sqlite-execute
   (rk3-space-db space)
   "INSERT INTO ops (op, tuple_id, category, scope, identity, payload, actor, at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
   (list (symbol-name op)
         (plist-get tuple :id)
         (symbol-name (plist-get tuple :category))
         (plist-get tuple :scope)
         (plist-get tuple :identity)
         (rk3-space--encode (plist-get tuple :payload))
         (rk3-space--field actor)
         (rk3-space--now))))

(defun rk3-space--check-payload (payload)
  "Signal an error unless PAYLOAD is a property list a tuple can carry."
  (let ((rest payload))
    (while rest
      (unless (and (keywordp (car rest)) (consp (cdr rest)))
        (error "A payload is a property list with keyword keys: %S" payload))
      (when (memq (car rest) rk3-space-reserved-keys)
        (error "%s names a tuple field and cannot be a payload key"
               (car rest)))
      (setq rest (cddr rest)))))

(cl-defun rk3-space-out (space category
                               &key (scope "system") identity payload
                               modality owner ttl actor)
  "Write a tuple of CATEGORY to SPACE and return it.
SCOPE is a repository name and defaults to \"system\".  IDENTITY names
what the tuple is about.  PAYLOAD is a property list.  MODALITY
defaults to the category's own.  OWNER is the story or epic whose
lifetime the tuple shares.  TTL is how many seconds the tuple lives;
an affine tuple must have one.  ACTOR is recorded in the log."
  (let ((default (alist-get category rk3-space-categories)))
    (unless default
      (error "Unknown tuple category: %S" category))
    (setq modality (or modality default)))
  (unless (memq modality rk3-space-modalities)
    (error "Unknown modality: %S" modality))
  (when (and (eq modality 'affine) (not ttl))
    (error "An affine tuple needs a :ttl"))
  (when (and ttl (not (and (numberp ttl) (> ttl 0))))
    (error "A :ttl is a positive number of seconds: %S" ttl))
  (rk3-space--check-payload payload)
  (let* ((now (rk3-space--now))
         (json (rk3-space--encode payload))
         (tuple (list :id nil :category category
                      :scope (rk3-space--field scope)
                      :identity (rk3-space--field identity)
                      :payload (rk3-space--canon payload)
                      :modality modality
                      :owner (rk3-space--field owner)
                      :created now
                      :expires (and ttl (+ now ttl))))
         (db (rk3-space-db space)))
    (unless (plist-get tuple :scope)
      (error "A tuple needs a scope"))
    (rk3-space-with-transaction space
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
      (rk3-space--log space 'out tuple actor)
      (rk3-space--announce space 'out tuple))
    tuple))

(defun rk3-space--delete (space tuple op actor)
  "Delete TUPLE from SPACE, logging and announcing it as OP by ACTOR."
  (sqlite-execute (rk3-space-db space) "DELETE FROM tuples WHERE id = ?"
                  (list (plist-get tuple :id)))
  (rk3-space--log space op tuple actor)
  (rk3-space--announce space op tuple))

(cl-defun rk3-space-put (space category
                               &rest keys
                               &key (scope "system") identity
                               &allow-other-keys)
  "Write a tuple of CATEGORY to SPACE, replacing any with the same key.
The key is CATEGORY, SCOPE and IDENTITY, and IDENTITY is required.
KEYS are as for `rk3-space-out'.  Return the new tuple."
  (unless identity
    (error "rk3-space-put needs an :identity"))
  (rk3-space-with-transaction space
    (rk3-space-retract space (list category :scope scope :identity identity)
                       :actor (plist-get keys :actor))
    (apply #'rk3-space-out space category keys)))

(cl-defun rk3-space-retract (space pattern &key actor)
  "Remove every tuple in SPACE matching PATTERN, of any modality.
Return how many were removed.  ACTOR is recorded in the log."
  (rk3-space-with-transaction space
    (let ((count 0))
      (dolist (tuple (rk3-space--candidates space pattern))
        (when (rk3-space-match pattern tuple)
          (rk3-space--delete space tuple 'retract actor)
          (cl-incf count)))
      count)))

;;;; Reading

(defun rk3-space-scan (space pattern)
  "Return every tuple in SPACE matching PATTERN, oldest first."
  (cl-remove-if-not (lambda (tuple) (rk3-space-match pattern tuple))
                    (rk3-space--candidates space pattern)))

(defun rk3-space-rd (space pattern)
  "Return the oldest tuple in SPACE matching PATTERN, or nil."
  (cl-find-if (lambda (tuple) (rk3-space-match pattern tuple))
              (rk3-space--candidates space pattern)))

(cl-defun rk3-space-in (space pattern &key actor)
  "Take the oldest tuple matching PATTERN out of SPACE and return it.
Return nil if there is none.  Persistent tuples are never taken; use
`rk3-space-retract' for those.  ACTOR is recorded in the log."
  (rk3-space-with-transaction space
    (when-let* ((tuple (cl-find-if
                        (lambda (tuple)
                          (and (not (eq (plist-get tuple :modality) 'persistent))
                               (rk3-space-match pattern tuple)))
                        (rk3-space--candidates space pattern))))
      (rk3-space--delete space tuple 'in actor)
      tuple)))

;;;; Lifetime

(defun rk3-space--archive (space condition arguments reason)
  "Move the tuples in SPACE satisfying CONDITION to the archive.
CONDITION is SQL with ARGUMENTS for its parameters.  REASON, a symbol,
is recorded with each tuple and as the operation in the log.  Return
how many tuples moved."
  (let ((db (rk3-space-db space))
        (now (rk3-space--now))
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
             rk3-space--columns condition)
     (append (list now reason) arguments))
    (sqlite-execute db (format "DELETE FROM tuples WHERE %s" condition)
                    arguments)))

(defun rk3-space-sweep (space owner)
  "Archive every tuple in SPACE that OWNER holds.  Return how many."
  (let ((owner (rk3-space--field owner)))
    (unless owner
      (error "rk3-space-sweep needs an owner"))
    (rk3-space-with-transaction space
      (let ((count (rk3-space--archive space "owner = ?" (list owner) 'sweep)))
        (when (> count 0)
          (rk3-space--announce space 'sweep (list :owner owner :count count)))
        count))))

(defun rk3-space-expire (space)
  "Archive every tuple in SPACE whose time has passed.  Return how many."
  (rk3-space-with-transaction space
    (let ((count (rk3-space--archive space "expires IS NOT NULL AND expires <= ?"
                                     (list (rk3-space--now)) 'expire)))
      (when (> count 0)
        (rk3-space--announce space 'expire (list :count count)))
      count)))

;;;; Inspection

(defun rk3-space-archived (space &optional owner)
  "Return the archived tuples of SPACE, oldest first.
With OWNER, only those it held.  Each tuple also has `:archived', the
time it was archived, and `:reason', `sweep' or `expire'."
  (mapcar
   (lambda (row)
     (append (rk3-space--row-tuple (butlast row 2))
             (list :archived (nth 9 row) :reason (intern (nth 10 row)))))
   (sqlite-select
    (rk3-space-db space)
    (format "SELECT %s, archived, reason FROM archive %s ORDER BY id"
            rk3-space--columns (if owner "WHERE owner = ?" ""))
    (and owner (list (rk3-space--field owner))))))

(defun rk3-space-ops (space &optional limit)
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
            :payload (rk3-space--decode payload) :actor actor :at at))
    (sqlite-select
     (rk3-space-db space)
     (concat "SELECT op, tuple_id, category, scope, identity, payload, actor, at
              FROM ops ORDER BY id DESC"
             (and limit " LIMIT ?"))
     (and limit (list limit))))))

(provide 'rk3-space)
;;; rk3-space.el ends here
