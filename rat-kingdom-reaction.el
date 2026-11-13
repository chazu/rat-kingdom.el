;;; rat-kingdom-reaction.el --- Rules that fire on tuples -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Chaz Straney

;; Author: Chaz Straney <chaz.straney@gmail.com>
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A reaction is a standing set of patterns with a body (DESIGN.md,
;; section 6).  When tuples matching all of its patterns are in a space,
;; the reaction fires: the body runs with the patterns' variables bound.
;;
;;   (rat-kingdom-defreaction integrate-on-pass
;;     "Move a story on once its review passes."
;;     :take (verdict :scope $repo :identity $story :value pass)
;;     :read (story :identity $story :at review)
;;     (rat-kingdom-space-put rat-kingdom-reaction-space 'story
;;                            :scope $repo :identity $story
;;                            :payload '(:at integrating)))
;;
;; `:take' patterns consume the tuples they match; `:read' patterns only
;; require them.  Each takes one pattern or a list of patterns.  A
;; variable used in several patterns must have the same value in all of
;; them, which is how patterns are joined.
;;
;; A firing is one transaction: the tuples are taken, the body runs, and
;; whatever the body writes commits with the take.  If the body signals
;; an error the transaction is rolled back, so the tuples stay, and the
;; failure is recorded so the same tuples do not fire that reaction
;; again until `rat-kingdom-reaction-retry'.
;;
;; Reactions fire on what is in the space, not on the act of writing.  A
;; reaction with no `:take' would then fire for ever on the same tuples,
;; so the space remembers which tuples each such reaction has fired on.
;; Both records live in the space's file, so after a restart a reaction
;; fires on exactly the tuples it had not handled.
;;
;; A body must not block.  Start a process and let its exit write a tuple.
;;
;; `rat-kingdom-reaction-attach' makes a space run reactions: after each
;; commit, and when a poll finds that another process wrote to the file.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'rat-kingdom-space)

(defgroup rat-kingdom-reaction nil
  "Rules that fire on tuples."
  :group 'rat-kingdom
  :prefix "rat-kingdom-reaction-")

(defcustom rat-kingdom-reaction-poll-interval 2
  "Seconds between checks for tuples written by other processes.
The same check archives tuples whose time has passed."
  :type 'number)

(defcustom rat-kingdom-reaction-max-firings 1000
  "Most firings in one run before the run is stopped as a runaway.
A run is everything that follows from one change to the space."
  :type 'integer)

;;;; Reactions

(cl-defstruct (rat-kingdom-reaction (:constructor rat-kingdom-reaction--create)
                                    (:copier nil))
  "A standing rule."
  (name nil :documentation "A symbol.")
  (doc nil :documentation "What the reaction is for.")
  (take nil :documentation "Patterns whose matches are consumed.")
  (read nil :documentation "Patterns whose matches are only required.")
  (function nil :documentation "Called with the bindings alist.")
  (enabled t :documentation "Nil to keep the reaction from firing.")
  (fired 0 :documentation "How many times it has fired in this session.")
  (last-fired nil :documentation "When it last fired.")
  (last-error nil :documentation "The last error its body signalled."))

(defvar rat-kingdom-reaction--registry nil
  "Every defined reaction, in the order they were first defined.")

(defvar rat-kingdom-reaction-space nil
  "The space a reaction's body is firing in.")

(defvar rat-kingdom-reaction-tuples nil
  "The tuples a reaction's body is firing on, taken ones first.")

(defun rat-kingdom-reaction--patterns (spec)
  "Return SPEC, one pattern or a list of patterns, as a list of patterns."
  (cond ((null spec) nil)
        ((consp (car spec)) spec)
        (t (list spec))))

(cl-defun rat-kingdom-reaction-define (name &key doc take read function)
  "Define the reaction NAME, replacing any reaction of that name.
TAKE and READ are each a pattern or a list of patterns.  FUNCTION is
called with the alist of variable bindings.  DOC says what it is for.
Return the reaction.  `rat-kingdom-defreaction' is the usual way in.
A replaced reaction keeps its state in this session: whether it is
enabled and how often it has fired."
  (let ((take (rat-kingdom-reaction--patterns take))
        (read (rat-kingdom-reaction--patterns read)))
    (unless (or take read)
      (error "Reaction %s has no patterns" name))
    (mapc #'rat-kingdom-space--check-pattern (append take read))
    (let ((reaction (rat-kingdom-reaction--create
                     :name name :doc doc :take take :read read
                     :function function))
          (cell (cl-member name rat-kingdom-reaction--registry
                           :key #'rat-kingdom-reaction-name)))
      (if cell
          (let ((old (car cell)))
            ;; Redefining, as reloading does, keeps what this session
            ;; knows about the reaction.
            (setf (rat-kingdom-reaction-enabled reaction)
                  (rat-kingdom-reaction-enabled old)
                  (rat-kingdom-reaction-fired reaction)
                  (rat-kingdom-reaction-fired old)
                  (rat-kingdom-reaction-last-fired reaction)
                  (rat-kingdom-reaction-last-fired old)
                  (rat-kingdom-reaction-last-error reaction)
                  (rat-kingdom-reaction-last-error old))
            (setcar cell reaction))
        (setq rat-kingdom-reaction--registry
              (append rat-kingdom-reaction--registry (list reaction))))
      reaction)))

(defun rat-kingdom-reaction--variables (form)
  "Return the pattern variables that occur in FORM."
  (cond ((rat-kingdom-space-variable-p form) (list form))
        ((consp form)
         (cl-union (rat-kingdom-reaction--variables (car form))
                   (rat-kingdom-reaction--variables (cdr form))))))

(defmacro rat-kingdom-defreaction (name &rest args)
  "Define the reaction NAME.
ARGS are an optional docstring, then `:take' and `:read' each followed
by a pattern or a list of patterns, then the body.  The body runs with
every pattern variable bound to its value, `rat-kingdom-reaction-space'
bound to the space and `rat-kingdom-reaction-tuples' to the matched
tuples.

\(fn NAME [DOCSTRING] [:take PATTERNS] [:read PATTERNS] BODY...)"
  (declare (indent defun) (doc-string 2))
  (let ((doc (and (stringp (car args)) (pop args)))
        take read)
    (while (memq (car args) '(:take :read))
      (pcase (pop args)
        (:take (setq take (pop args)))
        (:read (setq read (pop args)))))
    (let ((variables (rat-kingdom-reaction--variables (list take read)))
          (bindings (make-symbol "bindings")))
      `(rat-kingdom-reaction-define
        ',name :doc ,doc :take ',take :read ',read
        :function
        (lambda (,bindings)
          (let ,(mapcar (lambda (variable)
                          `(,variable (alist-get ',variable ,bindings)))
                        variables)
            (ignore ,bindings ,@variables)
            ,@args))))))

(defun rat-kingdom-reaction-get (name)
  "Return the reaction called NAME, or nil."
  (cl-find name rat-kingdom-reaction--registry
           :key #'rat-kingdom-reaction-name))

(defun rat-kingdom-reaction-remove (name)
  "Forget the reaction called NAME."
  (setq rat-kingdom-reaction--registry
        (cl-remove name rat-kingdom-reaction--registry
                   :key #'rat-kingdom-reaction-name)))

(defun rat-kingdom-reaction-list ()
  "Return every defined reaction, in definition order."
  (copy-sequence rat-kingdom-reaction--registry))

;;;; What has fired

(defun rat-kingdom-reaction--ensure-table (space)
  "Create the table of firings in SPACE unless it is there."
  (sqlite-execute
   (rat-kingdom-space-db space)
   "CREATE TABLE IF NOT EXISTS firings (
      reaction TEXT NOT NULL,
      tuples TEXT NOT NULL,
      status TEXT NOT NULL,
      error TEXT,
      at REAL NOT NULL,
      PRIMARY KEY (reaction, tuples))"))

(defun rat-kingdom-reaction--key (tuples)
  "Return the text that identifies the join TUPLES."
  (mapconcat (lambda (tuple) (number-to-string (plist-get tuple :id)))
             tuples ","))

(defun rat-kingdom-reaction--handled (space reaction)
  "Return the keys of the joins REACTION has already fired on in SPACE."
  (mapcar #'car
          (sqlite-select
           (rat-kingdom-space-db space)
           "SELECT tuples FROM firings WHERE reaction = ?"
           (list (symbol-name (rat-kingdom-reaction-name reaction))))))

(defun rat-kingdom-reaction--record (space reaction key status &optional error)
  "Record that REACTION fired on the join KEY in SPACE with STATUS.
STATUS is `done' or `failed'; ERROR is the failure's text."
  (sqlite-execute
   (rat-kingdom-space-db space)
   "INSERT OR REPLACE INTO firings (reaction, tuples, status, error, at)
    VALUES (?, ?, ?, ?, ?)"
   (list (symbol-name (rat-kingdom-reaction-name reaction)) key
         (symbol-name status) error (funcall rat-kingdom-space-now-function))))

(defun rat-kingdom-reaction-failures (space)
  "Return the failed firings recorded in SPACE, oldest first.
Each is a property list: `:reaction', `:tuples' (a list of tuple ids),
`:error' and `:at'."
  (rat-kingdom-reaction--ensure-table space)
  (mapcar
   (pcase-lambda (`(,reaction ,tuples ,error ,at))
     (list :reaction (intern reaction)
           :tuples (mapcar #'string-to-number (split-string tuples ","))
           :error error :at at))
   (sqlite-select
    (rat-kingdom-space-db space)
    "SELECT reaction, tuples, error, at FROM firings
     WHERE status = 'failed' ORDER BY at, rowid")))

(defun rat-kingdom-reaction-retry (space &optional name)
  "Let failed firings in SPACE fire again, then run reactions.
With NAME, only that reaction's failures.  Return how many were cleared."
  (prog1 (sqlite-execute
          (rat-kingdom-space-db space)
          (concat "DELETE FROM firings WHERE status = 'failed'"
                  (and name " AND reaction = ?"))
          (and name (list (symbol-name name))))
    (rat-kingdom-reaction-run space)))

(defun rat-kingdom-reaction-forget-gone (space)
  "Drop the firing records in SPACE whose tuples no longer exist.
Return how many were dropped."
  (let ((db (rat-kingdom-space-db space))
        (live (make-hash-table :test #'equal))
        (count 0))
    (dolist (row (sqlite-select db "SELECT id FROM tuples"))
      (puthash (number-to-string (car row)) t live))
    (pcase-dolist (`(,reaction ,tuples)
                   (sqlite-select db "SELECT reaction, tuples FROM firings"))
      (unless (cl-every (lambda (id) (gethash id live))
                        (split-string tuples ","))
        (sqlite-execute
         db "DELETE FROM firings WHERE reaction = ? AND tuples = ?"
         (list reaction tuples))
        (cl-incf count)))
    count))

;;;; Firing

(defun rat-kingdom-reaction--joins (space reaction)
  "Return the joins in SPACE that satisfy every pattern of REACTION.
Each is (TUPLES . BINDINGS) with the taken tuples first.  No tuple
appears twice in a join, and no persistent tuple is matched by a
`:take' pattern."
  (let ((patterns (append (rat-kingdom-reaction-take reaction)
                          (rat-kingdom-reaction-read reaction)))
        (takes (length (rat-kingdom-reaction-take reaction)))
        joins)
    (cl-labels
        ((walk (patterns index tuples bindings)
           (if (null patterns)
               (push (cons (reverse tuples) bindings) joins)
             (pcase-dolist (`(,tuple . ,extended)
                            (rat-kingdom-space-matches
                             space (car patterns) bindings))
               (unless (or (cl-member (plist-get tuple :id) tuples
                                      :key (lambda (other)
                                             (plist-get other :id)))
                           (and (< index takes)
                                (eq (plist-get tuple :modality) 'persistent)))
                 (walk (cdr patterns) (1+ index)
                       (cons tuple tuples) extended))))))
      (walk patterns 0 nil rat-kingdom-space-no-bindings))
    (nreverse joins)))

(defun rat-kingdom-reaction--fire (space reaction join)
  "Fire REACTION in SPACE on JOIN, which is (TUPLES . BINDINGS).
Return `fired', `failed', or `gone' if the tuples had changed."
  (let* ((tuples (car join))
         (key (rat-kingdom-reaction--key tuples))
         (name (rat-kingdom-reaction-name reaction))
         (takes (length (rat-kingdom-reaction-take reaction)))
         (outcome
          (condition-case err
              (catch 'gone
                (rat-kingdom-space-with-transaction space
                  (cl-loop
                   for tuple in tuples
                   for index from 0
                   for pattern = (list '_ :id (plist-get tuple :id))
                   unless (if (< index takes)
                              (rat-kingdom-space-in space pattern :actor name)
                            (rat-kingdom-space-rd space pattern))
                   do (throw 'gone 'gone))
                  (when (zerop takes)
                    (rat-kingdom-reaction--record space reaction key 'done))
                  (let ((rat-kingdom-reaction-space space)
                        (rat-kingdom-reaction-tuples tuples))
                    (funcall (rat-kingdom-reaction-function reaction)
                             (cdr join)))
                  'fired))
            (error
             (let ((text (error-message-string err)))
               (setf (rat-kingdom-reaction-last-error reaction) text)
               (rat-kingdom-reaction--record space reaction key 'failed text)
               (message "rat-kingdom: reaction %s failed: %s" name text))
             'failed))))
    (when (eq outcome 'fired)
      (cl-incf (rat-kingdom-reaction-fired reaction))
      (setf (rat-kingdom-reaction-last-fired reaction)
            (funcall rat-kingdom-space-now-function)))
    outcome))

(defvar rat-kingdom-reaction--running nil
  "The spaces whose reactions are running now.")

(defun rat-kingdom-reaction-run (space)
  "Fire reactions in SPACE until none has anything left to fire on.
Return how many firings there were.  Calling this while SPACE is
already running does nothing, since the run in progress will see the
change."
  (when (> (rat-kingdom-space-depth space) 0)
    (error "Reactions cannot run inside a transaction"))
  (rat-kingdom-reaction--ensure-table space)
  (if (memq space rat-kingdom-reaction--running)
      0
    (let ((rat-kingdom-reaction--running
           (cons space rat-kingdom-reaction--running))
          (firings 0)
          (progress t))
      (catch 'runaway
        (while progress
          (setq progress nil)
          (dolist (reaction rat-kingdom-reaction--registry)
            (when (rat-kingdom-reaction-enabled reaction)
              (let ((handled (rat-kingdom-reaction--handled space reaction)))
                (dolist (join (rat-kingdom-reaction--joins space reaction))
                  (unless (member (rat-kingdom-reaction--key (car join))
                                  handled)
                    (when (eq (rat-kingdom-reaction--fire space reaction join)
                              'fired)
                      (setq progress t)
                      (when (>= (cl-incf firings)
                                rat-kingdom-reaction-max-firings)
                        (display-warning
                         'rat-kingdom
                         (format "Stopped reactions after %d firings; last was %s"
                                 firings (rat-kingdom-reaction-name reaction)))
                        (throw 'runaway nil))))))))))
      firings)))

;;;; Attaching to a space

(cl-defstruct (rat-kingdom-reaction--attachment (:copier nil))
  "What ties a space to the reactions."
  space
  (version nil :documentation "The data version last seen.")
  (poll nil :documentation "The repeating poll timer.")
  (pending nil :documentation "The timer for a scheduled run, if any."))

(defvar rat-kingdom-reaction--attachments nil
  "One attachment per attached space.")

(defun rat-kingdom-reaction--attachment (space)
  "Return SPACE's attachment, or nil."
  (cl-find space rat-kingdom-reaction--attachments
           :key #'rat-kingdom-reaction--attachment-space))

(defun rat-kingdom-reaction-schedule (space)
  "Run SPACE's reactions as soon as Emacs is next idle.
Asking again before that run has started does nothing more."
  (when-let* ((attachment (rat-kingdom-reaction--attachment space)))
    (unless (rat-kingdom-reaction--attachment-pending attachment)
      (setf (rat-kingdom-reaction--attachment-pending attachment)
            (run-at-time
             0 nil
             (lambda ()
               (setf (rat-kingdom-reaction--attachment-pending attachment) nil)
               (when (rat-kingdom-space-db space)
                 (rat-kingdom-reaction-run space))))))))

(defun rat-kingdom-reaction--on-change (space op _subject)
  "Schedule a run after OP changed SPACE, if SPACE is attached."
  (when (rat-kingdom-reaction--attachment space)
    (when (memq op '(sweep expire))
      (rat-kingdom-reaction-forget-gone space))
    (unless (memq space rat-kingdom-reaction--running)
      (rat-kingdom-reaction-schedule space))))

(defun rat-kingdom-reaction-poll (space)
  "Archive expired tuples in SPACE and run if another process wrote to it.
The poll timer calls this; it is safe to call by hand."
  (when-let* ((attachment (rat-kingdom-reaction--attachment space))
              ((rat-kingdom-space-db space)))
    (rat-kingdom-space-expire space)
    (let ((version (rat-kingdom-space-data-version space)))
      (unless (eql version (rat-kingdom-reaction--attachment-version attachment))
        (setf (rat-kingdom-reaction--attachment-version attachment) version)
        (rat-kingdom-reaction-run space)))))

(defun rat-kingdom-reaction-attach (space)
  "Make SPACE run reactions from now on, and run them once now.
The first run fires on whatever was written while nothing was
attached."
  (unless (rat-kingdom-reaction--attachment space)
    (rat-kingdom-reaction--ensure-table space)
    (let ((attachment (make-rat-kingdom-reaction--attachment
                       :space space
                       :version (rat-kingdom-space-data-version space))))
      (setf (rat-kingdom-reaction--attachment-poll attachment)
            (run-at-time rat-kingdom-reaction-poll-interval
                         rat-kingdom-reaction-poll-interval
                         #'rat-kingdom-reaction-poll space))
      (push attachment rat-kingdom-reaction--attachments))
    (add-hook 'rat-kingdom-space-change-functions
              #'rat-kingdom-reaction--on-change)
    (rat-kingdom-reaction-forget-gone space)
    (rat-kingdom-reaction-run space))
  space)

(defun rat-kingdom-reaction-detach (space)
  "Stop SPACE from running reactions."
  (when-let* ((attachment (rat-kingdom-reaction--attachment space)))
    (dolist (timer (list (rat-kingdom-reaction--attachment-poll attachment)
                         (rat-kingdom-reaction--attachment-pending attachment)))
      (when timer (cancel-timer timer)))
    (setq rat-kingdom-reaction--attachments
          (delq attachment rat-kingdom-reaction--attachments))
    (unless rat-kingdom-reaction--attachments
      (remove-hook 'rat-kingdom-space-change-functions
                   #'rat-kingdom-reaction--on-change))))

(provide 'rat-kingdom-reaction)
;;; rat-kingdom-reaction.el ends here
