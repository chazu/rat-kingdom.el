;;; rat-kingdom-config.el --- Configuration layers, read and merged -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Chaz Straney

;; Author: Chaz Straney <chaz.straney@gmail.com>
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;;; Commentary:

;; Configuration (DESIGN.md, section 7.3): which workflow a story runs,
;; the target branch, the commands for setup and check, which agent
;; runs each role, time limits, attempts, the worker limit and whether
;; rat-kingdom's directories are kept in Git.
;;
;; A configuration is a property list of the keys in
;; `rat-kingdom-config-schema'.  It comes in layers, least specific
;; first (`rat-kingdom-config-layer-names'):
;;
;;   defaults      the existing user options, `rat-kingdom-config-defaults'
;;   global        config.eld in `rat-kingdom-directory'
;;   registration  :workflow :target :check :setup on the `repo' tuple
;;   repo          .rk/config.eld in the repository's checkout (its :path)
;;   epic          the epic's `policy' tuple
;;   task          the task's `policy' tuple
;;
;; The most specific layer wins, key by key; for :commands, :agents,
;; :timeouts and :track, sub-key by sub-key.  Code reads one key with
;; `rat-kingdom-config-get', and `rat-kingdom-config-explain' says which
;; layer every value came from.
;;
;; Files are read with `read', never evaluated, and cached by file,
;; modification time and size, so a changed file is read again.  A file
;; that does not read as one property list, or that fails
;; `rat-kingdom-config-validate', contributes nothing; the error is kept
;; for `rat-kingdom-config-errors' and shown once in *Messages*.  A
;; missing file contributes nothing and is no error.
;;
;; What one layer cannot show (an undefined command name, an unknown
;; workflow or agent, a target that is not a branch) is found by
;; `rat-kingdom-config-validate-merged'.
;;
;; Policy tuples.  The epic and task layers are persistent `policy'
;; tuples:
;;
;;   scope     the repository's name
;;   identity  "epic:ID" or "task:ID", so an epic and a task with the
;;             same id cannot replace each other's
;;   owner     ID, the epic or task, so the policy goes when it is swept
;;   payload   (:layer "epic" :of ID :config TEXT)
;;
;; TEXT is the configuration property list printed with `prin1' and
;; read back with `read'.  It is kept as text because the space stores
;; payloads as JSON, which turns symbols into strings: :check (lint
;; test), command names, would read back as ("lint" "test"), an
;; argument list.  A policy is replaced whole by
;; `rat-kingdom-config-policy-set'; an empty one is removed.
;;
;; :track.  `rat-kingdom-config-track-apply' makes a repository's
;; info/exclude, in its common Git directory, have /.rk/ and /.beads/
;; when :track says to keep them out, and not when it says to track
;; them, touching no other line; `rat-kingdom-config-track-apply-all'
;; does every repository.  Registering a repository and turning on
;; `rat-kingdom-mode' apply it.  Nothing is ever committed or removed
;; from the index; Git tracking files in a directory kept out is a
;; warning.  `rat-kingdom-config-repo-directory' makes .rk, applying
;; :track first.
;;
;; The engine reads its settings through `rat-kingdom-config-get' and,
;; for :setup and :check, `rat-kingdom-story-commands'.
;;
;; Workflow files.  A workflow can be a file holding the property list
;; `rat-kingdom-workflow-define' takes, with :name: workflows/*.eld in
;; `rat-kingdom-directory' for every repository, .rk/workflows/*.eld in
;; a repository's checkout for that one.  They are read, cached and
;; reported as configuration files are.  `rat-kingdom-config-workflows'
;; gives a repository's view (its files, then the global ones, then the
;; built-in workflows), and `rat-kingdom-config-workflow' resolves one
;; name in it.  The engine looks a story's workflow up there each time
;; it moves the token, so a changed file applies from the next move.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'rat-kingdom-space)
(require 'rat-kingdom-git)
(require 'rat-kingdom-workflow)
(require 'rat-kingdom-agent-shell)
(require 'rat-kingdom-task)

;; In rat-kingdom-story.el, which is loaded when the defaults are read.
(defvar rat-kingdom-story-default-workflow)
(defvar rat-kingdom-story-timeouts)
(defvar rat-kingdom-story-attempts)
(defvar rat-kingdom-story-max-workers)

(define-error 'rat-kingdom-config-error "Configuration error")

;;;; The schema

(defconst rat-kingdom-config-layer-names
  '(defaults global registration repo epic task)
  "The configuration layers, least specific first.")

(defconst rat-kingdom-config-schema
  '((:workflow
     :layers (defaults global registration repo epic task)
     :validate rat-kingdom-config--workflow-problem)
    (:target
     :layers (defaults global registration repo)
     :validate rat-kingdom-config--branch-problem)
    (:commands
     :layers (global repo)
     :sub-keys t
     :validate rat-kingdom-config--argv-problem)
    (:setup
     :layers (global registration repo)
     :validate rat-kingdom-config--run-problem)
    (:check
     :layers (global registration repo epic task)
     :validate rat-kingdom-config--run-problem)
    (:agents
     :layers (defaults global repo epic task)
     :sub-keys (:worker :foreman)
     :validate rat-kingdom-config--agent-problem)
    (:timeouts
     :layers (defaults global repo epic task)
     :sub-keys (:worker :check)
     :validate rat-kingdom-config--seconds-problem)
    (:attempts
     :layers (defaults global repo epic task)
     :validate rat-kingdom-config--count-problem)
    (:max-workers
     :layers (defaults global)
     :validate rat-kingdom-config--count-problem)
    (:track
     :layers (defaults global repo)
     :sub-keys (:rk :beads)
     :validate rat-kingdom-config--boolean-problem))
  "The configuration keys, each with what may set it and how it is checked.
Each entry is (KEY . PROPERTIES):

  `:layers'    the layers that may set KEY
  `:validate'  a function of a value returning nil if it is sound, or
               a phrase saying what is wrong with it
  `:sub-keys'  for a key whose value is a property list, the sub-keys
               it may have, or t for any keyword; then `:validate'
               checks each sub-key's value, and layers are merged
               sub-key by sub-key")

(defun rat-kingdom-config--entry (key)
  "Return the schema entry of KEY, or signal an error if it is unknown."
  (or (assq key rat-kingdom-config-schema)
      (signal 'rat-kingdom-config-error
              (list (format "%S is not a configuration key; the keys are %s"
                            key (rat-kingdom-config--key-names))))))

(defun rat-kingdom-config--key-names ()
  "Return the configuration keys, as text."
  (mapconcat (lambda (entry) (symbol-name (car entry)))
             rat-kingdom-config-schema " "))

(defun rat-kingdom-config-plist-key-p (key)
  "Return non-nil if KEY's value is a property list merged sub-key by sub-key."
  (plist-get (cdr (assq key rat-kingdom-config-schema)) :sub-keys))

;;;; Validating values

(defun rat-kingdom-config--name-symbol-p (value)
  "Return non-nil if VALUE is a symbol that can be a name."
  (and (symbolp value) value (not (eq value t)) (not (keywordp value))))

(defun rat-kingdom-config--workflow-problem (value)
  "Return what is wrong with VALUE as a workflow name, or nil."
  (unless (or (rat-kingdom-config--name-symbol-p value)
              (and (stringp value) (not (string-blank-p value))))
    (format "is a workflow name, a symbol or string, not %S" value)))

(defun rat-kingdom-config--branch-problem (value)
  "Return what is wrong with VALUE as a branch name, or nil."
  (unless (and (stringp value) (not (string-blank-p value)))
    (format "is a branch name, a string, not %S" value)))

(defun rat-kingdom-config--argv-problem (value)
  "Return what is wrong with VALUE as an argument list, or nil."
  (unless (and value (proper-list-p value) (cl-every #'stringp value))
    (format "is an argument list, strings such as (\"make\" \"test\"), \
not %S" value)))

(defun rat-kingdom-config--run-problem (value)
  "Return what is wrong with VALUE as a setup or check, or nil.
It is an argument list or a list of command names."
  (unless (and value (proper-list-p value)
               (or (cl-every #'stringp value)
                   (cl-every #'rat-kingdom-config--name-symbol-p value)))
    (format "is an argument list (\"make\" \"test\") or a list of command \
names (lint test), not both and not %S" value)))

(defun rat-kingdom-config--agent-problem (value)
  "Return what is wrong with VALUE as an agent kind, or nil."
  (unless (or (rat-kingdom-config--name-symbol-p value)
              (and (stringp value) (not (string-blank-p value))))
    (format "is an agent kind such as claude or codex, not %S" value)))

(defun rat-kingdom-config--seconds-problem (value)
  "Return what is wrong with VALUE as a number of seconds, or nil."
  (unless (and (numberp value) (> value 0))
    (format "is a positive number of seconds, not %S" value)))

(defun rat-kingdom-config--count-problem (value)
  "Return what is wrong with VALUE as a count, or nil."
  (unless (and (natnump value) (> value 0))
    (format "is a positive integer, not %S" value)))

(defun rat-kingdom-config--boolean-problem (value)
  "Return what is wrong with VALUE as t or nil, or nil."
  (unless (memq value '(t nil))
    (format "is t or nil, not %S" value)))

(defun rat-kingdom-config--plist-p (value)
  "Return non-nil if VALUE is a proper list of even length."
  (and (proper-list-p value) (cl-evenp (length value))))

(defun rat-kingdom-config--value-problem (entry value)
  "Return what is wrong with VALUE as the value of the schema ENTRY, or nil."
  (let ((sub-keys (plist-get (cdr entry) :sub-keys))
        (validate (plist-get (cdr entry) :validate)))
    (cond
     ((not sub-keys) (funcall validate value))
     ((not (rat-kingdom-config--plist-p value))
      (format "is a property list, not %S" value))
     (t
      (let (seen)
        (cl-loop for (sub sub-value) on value by #'cddr
                 for problem
                 = (cond
                    ((not (keywordp sub))
                     (format "has %S, which is not a keyword" sub))
                    ((memq sub seen) (format "has %s twice" sub))
                    ((and (listp sub-keys) (not (memq sub sub-keys)))
                     (format "has %s, which is not one of %s" sub
                             (mapconcat #'symbol-name sub-keys " ")))
                    (t (when-let* ((problem (funcall validate sub-value)))
                         (format "%s %s" sub problem))))
                 do (push sub seen)
                 when problem return problem))))))

(defun rat-kingdom-config-validate (plist layer)
  "Return what is wrong with PLIST as the configuration of LAYER, as strings.
LAYER is one of `rat-kingdom-config-layer-names'.  Return nil if PLIST
is sound: a property list of known keys, each allowed at LAYER, with a
value of the right shape.  A key whose value is nil is as if left out.
Whether command names are defined, and whether the workflow, agents
and target exist, is checked on the merged result, by
`rat-kingdom-config-validate-merged'."
  (unless (memq layer rat-kingdom-config-layer-names)
    (error "There is no configuration layer %S; the layers are %s"
           layer rat-kingdom-config-layer-names))
  (if (not (rat-kingdom-config--plist-p plist))
      (list (format "A configuration is a property list such as \
(:check (\"make\" \"test\")), not %S" plist))
    (let (problems seen)
      (cl-loop
       for (key value) on plist by #'cddr
       for entry = (assq key rat-kingdom-config-schema)
       for problem
       = (cond
          ((not (keywordp key))
           (format "%S is not a key; keys are keywords such as :check" key))
          ((memq key seen) (format "%s is given twice" key))
          ((null entry)
           (format "%s is not a configuration key; the keys are %s"
                   key (rat-kingdom-config--key-names)))
          ((not (memq layer (plist-get (cdr entry) :layers)))
           (format "%s cannot be set at the %s layer, only at: %s" key layer
                   (mapconcat #'symbol-name (plist-get (cdr entry) :layers)
                              ", ")))
          ((null value) nil)
          (t (when-let* ((problem (rat-kingdom-config--value-problem
                                   entry value)))
               (format "%s %s" key problem))))
       do (push key seen)
       when problem do (push problem problems))
      (nreverse problems))))

(defun rat-kingdom-config--normalize (plist)
  "Return the sound configuration PLIST in the form lookups return.
Keys whose value is nil are left out, the workflow is a string and
agent kinds are symbols."
  (let (result)
    (cl-loop
     for (key value) on plist by #'cddr
     when value
     do (push key result)
     (push (pcase key
             (:workflow (format "%s" value))
             (:agents (cl-loop for (sub kind) on value by #'cddr
                               append (list sub (if (stringp kind)
                                                    (intern kind)
                                                  kind))))
             (_ value))
           result))
    (nreverse result)))

;;;; Errors

(defvar rat-kingdom-config--errors (make-hash-table :test #'equal)
  "Configuration that is being ignored, and why.
A table from a source, a file name or a policy's description, to
\(REPO . MESSAGE), where REPO is the repository it affects, or nil for
every repository.")

(defun rat-kingdom-config--record-error (source repo message)
  "Record that SOURCE, which affects REPO, is ignored because of MESSAGE.
The error is shown in *Messages* unless it was already recorded."
  (unless (equal (cdr (gethash source rat-kingdom-config--errors)) message)
    (message "rat-kingdom: ignoring the configuration in %s: %s"
             source message))
  (puthash source (cons repo message) rat-kingdom-config--errors))

(defun rat-kingdom-config--clear-error (source)
  "Forget any error recorded for SOURCE."
  (remhash source rat-kingdom-config--errors))

(defun rat-kingdom-config-errors (&optional repo)
  "Return the configuration being ignored, as a list of (SOURCE MESSAGE).
SOURCE is a file name or a policy's description.  With REPO, a
repository's name, only the errors that affect it: those of the global
file and its own.  Sorted by source.  Only what has been read is
known; a lookup reads what it needs."
  (let (errors)
    (maphash (lambda (source entry)
               (when (or (null repo) (null (car entry))
                         (equal (car entry) repo))
                 (push (list source (cdr entry)) errors)))
             rat-kingdom-config--errors)
    (sort errors (lambda (a b) (string< (car a) (car b))))))

;;;; Files

(defvar rat-kingdom-config--files (make-hash-table :test #'equal)
  "Configuration files read, as a table from file name to (STAMP . PLIST).
STAMP is the file's modification time and size when it was read, PLIST
what it contributes: nil if it was invalid.")

(defun rat-kingdom-config-global-file ()
  "Return the name of the global configuration file."
  (expand-file-name "config.eld" rat-kingdom-directory))

(defun rat-kingdom-config-repo-file (repo)
  "Return the name of the configuration file of REPO, a repository record."
  (expand-file-name ".rk/config.eld" (plist-get repo :path)))

(defun rat-kingdom-config--parse (file)
  "Return the one form in FILE, or signal `rat-kingdom-config-error'."
  (with-temp-buffer
    (insert-file-contents file)
    (set-syntax-table emacs-lisp-mode-syntax-table)
    (goto-char (point-min))
    (let ((form (condition-case err
                    (let ((read-circle nil))
                      (read (current-buffer)))
                  (end-of-file
                   (signal 'rat-kingdom-config-error
                           (list (if (progn (goto-char (point-min))
                                            (forward-comment (buffer-size))
                                            (eobp))
                                     "it holds no property list"
                                   "a list is not closed"))))
                  (error
                   (signal 'rat-kingdom-config-error
                           (list (format "it does not read: %s"
                                         (error-message-string err))))))))
      (forward-comment (buffer-size))
      (unless (eobp)
        (signal 'rat-kingdom-config-error
                (list (format "there is more after the property list, \
at line %d" (line-number-at-pos)))))
      form)))

(defun rat-kingdom-config--read-cached (file repo convert)
  "Return what CONVERT makes of the one form in FILE, read when it changed.
REPO is the name of the repository FILE affects, or nil for every one.
CONVERT is a function of the form that returns what FILE contributes,
or signals `rat-kingdom-config-error' saying why it is invalid.  FILE
is read with `read', never evaluated, and only again when its
modification time or size changes.  Return nil if FILE is missing,
which is no error, or if it is invalid: then the reason is recorded
for `rat-kingdom-config-errors'."
  (let* ((file (expand-file-name file))
         (attributes (file-attributes file))
         (stamp (and attributes
                     (list (file-attribute-modification-time attributes)
                           (file-attribute-size attributes))))
         (cached (gethash file rat-kingdom-config--files)))
    (cond
     ((null attributes)
      (remhash file rat-kingdom-config--files)
      (rat-kingdom-config--clear-error file)
      nil)
     ((and cached (equal (car cached) stamp))
      (cdr cached))
     (t
      (let ((value
             (condition-case err
                 (prog1 (funcall convert (rat-kingdom-config--parse file))
                   (rat-kingdom-config--clear-error file))
               (rat-kingdom-config-error
                (rat-kingdom-config--record-error file repo (cadr err))
                nil)
               (error
                (rat-kingdom-config--record-error
                 file repo (error-message-string err))
                nil))))
        (puthash file (cons stamp value) rat-kingdom-config--files)
        value)))))

(defun rat-kingdom-config-read-file (file layer &optional repo)
  "Return the configuration in FILE, for LAYER, as a property list.
REPO is the name of the repository it affects, or nil for every one.
FILE is read with `read', never evaluated, and only again when its
modification time or size changes.  Return nil if FILE is missing,
which is no error, or if it is invalid: then the reason is recorded
for `rat-kingdom-config-errors'."
  (rat-kingdom-config--read-cached
   file repo
   (lambda (form)
     (when-let* ((problems (rat-kingdom-config-validate form layer)))
       (signal 'rat-kingdom-config-error (list (string-join problems "; "))))
     (rat-kingdom-config--normalize form))))

;;;; Workflow files

(defconst rat-kingdom-config-workflow-keys
  '(:name :doc :places :start :final :failure :steps)
  "The keys a workflow file may have.
They are `:name' and the keys `rat-kingdom-workflow-define' takes.")

(defun rat-kingdom-config-workflow-directory ()
  "Return the directory of the workflow files for every repository."
  (file-name-as-directory (expand-file-name "workflows" rat-kingdom-directory)))

(defun rat-kingdom-config-repo-workflow-directory (repo)
  "Return the directory of the workflow files of REPO, a repository record."
  (file-name-as-directory
   (expand-file-name ".rk/workflows" (plist-get repo :path))))

(defun rat-kingdom-config-workflow-problems (form)
  "Return what is wrong with FORM as the contents of a workflow file.
Return a list of strings, or nil if FORM is sound: a property list of
`rat-kingdom-config-workflow-keys' with a `:name', a symbol or string,
whose other keys `rat-kingdom-workflow-validate' finds sound, as
`rat-kingdom-workflow-define' would."
  (if (not (rat-kingdom-config--plist-p form))
      (list (format "A workflow file holds a property list such as \
\(:name quick :places (ready done blocked) ...), not %S" form))
    (let (problems seen)
      (cl-loop for (key) on form by #'cddr
               do (cond
                   ((not (memq key rat-kingdom-config-workflow-keys))
                    (push (format "%S is not a workflow key; the keys are %s"
                                  key (mapconcat #'symbol-name
                                                 rat-kingdom-config-workflow-keys
                                                 " "))
                          problems))
                   ((memq key seen)
                    (push (format "%s is given twice" key) problems)))
               (push key seen))
      (if (null (plist-get form :name))
          (push "It has no :name" problems)
        (when-let* ((problem (rat-kingdom-config--workflow-problem
                              (plist-get form :name))))
          (push (concat ":name " problem) problems)))
      (when (and (plist-get form :doc) (not (stringp (plist-get form :doc))))
        (push (format ":doc is a string, not %S" (plist-get form :doc))
              problems))
      (unless problems
        (let ((spec (cl-loop for (key value) on form by #'cddr
                             unless (eq key :name) append (list key value))))
          (setq problems
                (reverse
                 (condition-case err
                     (rat-kingdom-workflow-validate spec)
                   (error (list (format "It is not a workflow: %s"
                                        (error-message-string err)))))))))
      (nreverse problems))))

(defun rat-kingdom-config--read-workflow-file (file repo)
  "Return the workflow in FILE, normalized, or nil if FILE is invalid.
REPO is the name of the repository FILE is for, or nil for every one.
FILE is read as `rat-kingdom-config-read-file' reads, and an invalid
one is recorded for `rat-kingdom-config-errors' in the same way."
  (rat-kingdom-config--read-cached
   file repo
   (lambda (form)
     (when-let* ((problems (rat-kingdom-config-workflow-problems form)))
       (signal 'rat-kingdom-config-error (list (string-join problems "; "))))
     (let ((name (plist-get form :name)))
       (rat-kingdom-workflow--normalize
        (if (stringp name) name (symbol-name name))
        (cl-loop for (key value) on form by #'cddr
                 unless (eq key :name) append (list key value)))))))

(defun rat-kingdom-config--workflow-files (directory repo)
  "Return the workflows defined by the files in DIRECTORY.
REPO is the name of the repository DIRECTORY is for, or nil for every
one.  The files are the *.eld files in DIRECTORY, not hidden ones.
Return an alist from workflow name to (WORKFLOW FILE), in the order of
the files' names.  An invalid file is left out, and so are two or more
files that define the same name; each is recorded for
`rat-kingdom-config-errors'.  Errors recorded before for files that
are gone are forgotten."
  (let* ((directory (file-name-as-directory (expand-file-name directory)))
         (files (and (file-directory-p directory)
                     (cl-remove-if-not
                      #'file-regular-p
                      (directory-files directory t "\\`[^.].*\\.eld\\'"))))
         read)
    (maphash (lambda (source _entry)
               (when (and (equal (file-name-directory source) directory)
                          (not (member source files)))
                 (rat-kingdom-config--clear-error source)
                 (remhash source rat-kingdom-config--files)))
             (copy-hash-table rat-kingdom-config--errors))
    (dolist (file files)
      (when-let* ((workflow (rat-kingdom-config--read-workflow-file file repo)))
        (push (list (plist-get workflow :name) workflow file) read)))
    (setq read (nreverse read))
    (cl-loop
     for entry in read
     for others = (cl-remove-if-not
                   (lambda (other) (and (not (eq other entry))
                                        (equal (car other) (car entry))))
                   read)
     if others
     do (rat-kingdom-config--record-error
         (nth 2 entry) repo
         (format "The workflow %s is also defined in %s; all are ignored"
                 (car entry)
                 (mapconcat (lambda (other) (nth 2 other)) others ", ")))
     else
     do (rat-kingdom-config--clear-error (nth 2 entry))
     and collect entry)))

(defun rat-kingdom-config-workflows (space &optional repo)
  "Return the workflows a story in REPO can follow, in SPACE.
REPO is a repository's name or record; without it, or if it is not
registered, the workflows every repository has.  A workflow comes from
REPO's .rk/workflows/*.eld, else from the global workflow files in
`rat-kingdom-config-workflow-directory', else it is one defined with
`rat-kingdom-workflow-define', such as the built-in story and
story-lite: a repo file shadows a global or built-in workflow of the
same name, for REPO only, and a global file replaces a built-in one.
Files are read again when they change.

Return a list of (WORKFLOW ORIGIN FILE), sorted by name, where ORIGIN
is `repo', `global' or `built-in' and FILE the file it was read from,
nil for a built-in one."
  (let* ((record (and repo (rat-kingdom-config--repo space repo)))
         (table (mapcar (lambda (workflow)
                          (list (plist-get workflow :name) workflow
                                'built-in nil))
                        (rat-kingdom-workflow-list))))
    (cl-flet ((add (entries origin)
                (pcase-dolist (`(,name ,workflow ,file) entries)
                  (setf (alist-get name table nil nil #'equal)
                        (list workflow origin file)))))
      (add (rat-kingdom-config--workflow-files
            (rat-kingdom-config-workflow-directory) nil)
           'global)
      (when (plist-get record :path)
        (add (rat-kingdom-config--workflow-files
              (rat-kingdom-config-repo-workflow-directory record)
              (plist-get record :name))
             'repo)))
    (mapcar #'cdr
            (sort table (lambda (a b) (string< (car a) (car b)))))))

(defun rat-kingdom-config-workflow (space name &optional repo)
  "Return the workflow called NAME, a symbol or string, for REPO in SPACE.
REPO is a repository's name or record, or nil for the workflows every
repository has.  The workflow is resolved as
`rat-kingdom-config-workflows' says.  Return nil if there is none."
  (when (and name (not (equal name "")))
    (let ((name (rat-kingdom-workflow--name name)))
      (car (cl-find name (rat-kingdom-config-workflows space repo)
                    :key (lambda (entry) (plist-get (car entry) :name))
                    :test #'equal)))))

(defun rat-kingdom-config-workflow-names (space &optional repo)
  "Return the names of the workflows of REPO in SPACE, as text."
  (mapconcat (lambda (entry) (plist-get (car entry) :name))
             (rat-kingdom-config-workflows space repo) ", "))

;;;; Policies

(defconst rat-kingdom-config-policy-kinds '(epic task)
  "The layers kept in `policy' tuples.")

(defun rat-kingdom-config--policy-kind (kind)
  "Return KIND, a symbol or string, as one of the policy kinds, or signal."
  (let ((kind (if (stringp kind) (intern kind) kind)))
    (unless (memq kind rat-kingdom-config-policy-kinds)
      (error "A policy belongs to an epic or a task, not %S" kind))
    kind))

(defun rat-kingdom-config-policy-identity (kind id)
  "Return the identity of the `policy' tuple of the KIND, epic or task, ID."
  (format "%s:%s" (rat-kingdom-config--policy-kind kind) id))

(defun rat-kingdom-config-policy-tuple (space repo kind id)
  "Return the `policy' tuple of the KIND, epic or task, ID in REPO, or nil.
SPACE holds it.  REPO is the repository's name."
  (rat-kingdom-space-rd
   space (list 'policy :scope repo
               :identity (rat-kingdom-config-policy-identity kind id))))

(defun rat-kingdom-config--policy-source (repo kind id)
  "Return how the policy of the KIND ID in REPO is named in errors."
  (format "the policy of %s %s in %s" kind id repo))

(defun rat-kingdom-config-policy (space repo kind id)
  "Return the configuration of the KIND, epic or task, ID in REPO.
SPACE holds it as a `policy' tuple.  Return nil if there is none, or
if it is invalid: then the reason is recorded for
`rat-kingdom-config-errors'."
  (let* ((kind (rat-kingdom-config--policy-kind kind))
         (source (rat-kingdom-config--policy-source repo kind id))
         (tuple (rat-kingdom-config-policy-tuple space repo kind id)))
    (if (null tuple)
        (progn (rat-kingdom-config--clear-error source) nil)
      (condition-case err
          (let* ((text (plist-get (plist-get tuple :payload) :config))
                 (form (if (stringp text)
                           (car (read-from-string text))
                         (signal 'rat-kingdom-config-error
                                 (list "it has no :config text"))))
                 (problems (rat-kingdom-config-validate form kind)))
            (when problems
              (signal 'rat-kingdom-config-error
                      (list (string-join problems "; "))))
            (rat-kingdom-config--clear-error source)
            (rat-kingdom-config--normalize form))
        (rat-kingdom-config-error
         (rat-kingdom-config--record-error source repo (cadr err))
         nil)
        (error
         (rat-kingdom-config--record-error source repo
                                           (error-message-string err))
         nil)))))

(cl-defun rat-kingdom-config-policy-set (space repo kind id plist &key actor)
  "Make PLIST the configuration of the KIND, epic or task, ID in REPO.
SPACE keeps it as a `policy' tuple, replaced whole, scoped to REPO and
owned by ID.  Keys whose value is nil are left out, and if none is
left the policy is removed.  Signal `rat-kingdom-config-error' if
PLIST is not sound at KIND's layer; nothing is written then.  ACTOR,
by default \"king\", is recorded in the log.  Return the tuple, or nil
if the policy was removed."
  (let* ((kind (rat-kingdom-config--policy-kind kind))
         (problems (rat-kingdom-config-validate plist kind))
         (actor (or actor "king"))
         (identity (rat-kingdom-config-policy-identity kind id)))
    (when problems
      (signal 'rat-kingdom-config-error
              (list (format "The policy of %s %s: %s" kind id
                            (string-join problems "; ")))))
    (let ((plist (rat-kingdom-config--normalize plist)))
      (rat-kingdom-config--clear-error
       (rat-kingdom-config--policy-source repo kind id))
      (if (null plist)
          (progn
            (rat-kingdom-space-retract space (list 'policy :scope repo
                                                   :identity identity)
                                       :actor actor)
            nil)
        (rat-kingdom-space-put
         space 'policy :scope repo :identity identity :owner id
         :payload (list :layer (symbol-name kind) :of (format "%s" id)
                        :config (let ((print-length nil) (print-level nil))
                                  (prin1-to-string plist)))
         :actor actor)))))

;;;; Layers

(defun rat-kingdom-config-defaults ()
  "Return the defaults layer, from the existing user options."
  (require 'rat-kingdom-story)
  (let ((worker (alist-get :spawn rat-kingdom-story-timeouts))
        (check (alist-get :check rat-kingdom-story-timeouts)))
    (rat-kingdom-config--normalize
     (list :workflow rat-kingdom-story-default-workflow
           :target rat-kingdom-git-default-target
           :agents (list :worker rat-kingdom-default-agent :foreman 'claude)
           :timeouts (append (and worker (list :worker worker))
                             (and check (list :check check)))
           :attempts rat-kingdom-story-attempts
           :max-workers rat-kingdom-story-max-workers
           :track (list :rk nil :beads (not rat-kingdom-task-br-untracked))))))

(defun rat-kingdom-config-registration (repo)
  "Return the registration layer of REPO, a repository record."
  (rat-kingdom-config--normalize
   (list :workflow (plist-get repo :workflow)
         :target (plist-get repo :target)
         :setup (plist-get repo :setup)
         :check (plist-get repo :check))))

(defun rat-kingdom-config--repo (space repo)
  "Return REPO, a repository's name or record, as a record, or nil.
SPACE holds the registration."
  (cond ((null repo) nil)
        ((consp repo) repo)
        (t (rat-kingdom-repo-get space (format "%s" repo)))))

(cl-defun rat-kingdom-config-layers (space &key repo epic task layer plist)
  "Return the configuration layers of REPO, EPIC and TASK in SPACE.
REPO is a repository's name or record; EPIC and TASK are ids, and are
read only with REPO.  Return an alist from layer to property list,
least specific first, leaving out the layers that contribute nothing.
With LAYER, PLIST takes the place of what LAYER holds, as long as it is
sound there; this is how a change is tried before it is made."
  (let* ((record (rat-kingdom-config--repo space repo))
         (name (plist-get record :name))
         (layers
          (list
           (cons 'defaults (rat-kingdom-config-defaults))
           (cons 'global (rat-kingdom-config-read-file
                          (rat-kingdom-config-global-file) 'global))
           (cons 'registration (and record (rat-kingdom-config-registration
                                            record)))
           (cons 'repo (and record (plist-get record :path)
                            (rat-kingdom-config-read-file
                             (rat-kingdom-config-repo-file record) 'repo name)))
           (cons 'epic (and name epic
                            (rat-kingdom-config-policy space name 'epic epic)))
           (cons 'task (and name task
                            (rat-kingdom-config-policy space name 'task
                                                       task))))))
    (when layer
      (unless (rat-kingdom-config-validate plist layer)
        (setf (alist-get layer layers) (rat-kingdom-config--normalize plist))))
    (cl-remove-if-not #'cdr layers)))

;;;; Merging

(defun rat-kingdom-config--merge (layers)
  "Return the effective configuration of LAYERS.
LAYERS is an alist as `rat-kingdom-config-layers' returns.  Return a
list of (KEY VALUE ORIGIN),
one for every key of the schema in its order.  ORIGIN is the layer
VALUE came from, or for a property-list key a property list from each
sub-key to its layer.  A key no layer sets has VALUE and ORIGIN nil."
  (mapcar
   (lambda (entry)
     (let ((key (car entry)))
       (if (plist-get (cdr entry) :sub-keys)
           (let (values origins)
             (dolist (layer layers)
               (cl-loop for (sub value) on (plist-get (cdr layer) key)
                        by #'cddr
                        do (setf (alist-get sub values) value
                                 (alist-get sub origins) (car layer))))
             (cl-flet ((plist (alist)
                         (cl-loop for (sub . value) in (reverse alist)
                                  append (list sub value))))
               (list key (plist values) (plist origins))))
         (let ((found (cl-find-if (lambda (layer)
                                    (plist-get (cdr layer) key))
                                  (reverse layers))))
           (list key (plist-get (cdr found) key) (car found))))))
   rat-kingdom-config-schema))

(cl-defun rat-kingdom-config-explain (space &key repo epic task)
  "Return the effective configuration of REPO, EPIC and TASK in SPACE.
Return a list of (KEY VALUE ORIGIN), one for every configuration key:
VALUE is what `rat-kingdom-config-get' returns for KEY, and ORIGIN the
layer it came from, or for :commands, :agents, :timeouts and :track a
property list from each sub-key to the layer it came from.  A key that
no layer sets has VALUE and ORIGIN nil.  See `rat-kingdom-config-layers'
for the arguments."
  (rat-kingdom-config--merge
   (rat-kingdom-config-layers space :repo repo :epic epic :task task)))

(cl-defun rat-kingdom-config-merged (space &key repo epic task)
  "Return the effective configuration of REPO, EPIC and TASK in SPACE.
It is one property list of every key some layer sets."
  (cl-loop for (key value) in (rat-kingdom-config-explain
                               space :repo repo :epic epic :task task)
           when value append (list key value)))

(cl-defun rat-kingdom-config-get (space key &key repo epic task)
  "Return the effective value of the configuration KEY in SPACE.
REPO is a repository's name, EPIC and TASK the ids of the epic and
task, if any; each makes its layers count.  The most specific layer
that sets KEY wins; for :commands, :agents, :timeouts and :track the
layers are merged sub-key by sub-key.  Return nil if no layer sets
KEY.  Signal `rat-kingdom-config-error' if KEY is unknown."
  (rat-kingdom-config--entry key)
  (nth 1 (assq key (rat-kingdom-config-explain
                    space :repo repo :epic epic :task task))))

;;;; Commands

(defun rat-kingdom-config--command-key (name)
  "Return the :commands key of the command NAME, a symbol."
  (intern (concat ":" (symbol-name name))))

(defun rat-kingdom-config--command-names (commands)
  "Return text naming the commands COMMANDS, a :commands value, defines."
  (if commands
      (concat "which defines "
              (mapconcat (lambda (key) (substring (symbol-name key) 1))
                         (cl-loop for (key) on commands by #'cddr
                                  collect key)
                         ", "))
    "which defines none"))

(defun rat-kingdom-config-resolve-commands (value commands)
  "Return the setup or check VALUE as a list of argument lists.
VALUE is an argument list, which is returned as the only element, or a
list of command names, each replaced by its argument list in COMMANDS,
the merged :commands.  Return nil if VALUE is nil.  Signal
`rat-kingdom-config-error' if a name is not defined in COMMANDS or
VALUE is neither form."
  (cond
   ((null value) nil)
   ((rat-kingdom-config--run-problem value)
    (signal 'rat-kingdom-config-error
            (list (format "A setup or check %s"
                          (rat-kingdom-config--run-problem value)))))
   ((stringp (car value)) (list value))
   (t
    (mapcar (lambda (name)
              (let ((key (rat-kingdom-config--command-key name)))
                (if (plist-member commands key)
                    (plist-get commands key)
                  (signal 'rat-kingdom-config-error
                          (list (format "The command %s is not defined in \
:commands, %s" name (rat-kingdom-config--command-names commands)))))))
            value))))

(cl-defun rat-kingdom-config-commands (space key &key repo epic task)
  "Return the effective KEY, :setup or :check, as a list of argument lists.
Command names are resolved against the merged :commands.  SPACE, REPO,
EPIC and TASK are as for `rat-kingdom-config-get'.  Signal
`rat-kingdom-config-error' on an undefined command name."
  (unless (memq key '(:setup :check))
    (error "Only :setup and :check are commands, not %S" key))
  (let ((merged (rat-kingdom-config-merged space :repo repo :epic epic
                                           :task task)))
    (rat-kingdom-config-resolve-commands (plist-get merged key)
                                         (plist-get merged :commands))))

;;;; The merged result

(cl-defun rat-kingdom-config-validate-merged (space repo &key epic task
                                                    layer plist)
  "Return what is wrong with the effective configuration of REPO, as strings.
SPACE, REPO, EPIC and TASK are as for `rat-kingdom-config-get'.  With
LAYER, PLIST takes the place of what that layer holds, so a change can
be checked before it is made, and what is wrong with PLIST itself is
reported too.  Checked here is what no single layer can show: that the
workflow and the agents exist, that every command name in :setup and
:check is defined in :commands, and that the target is a local branch
of the repository.  Return nil if all is well."
  (let* ((record (rat-kingdom-config--repo space repo))
         (problems (and layer
                        (mapcar (lambda (problem)
                                  (format "At the %s layer: %s" layer problem))
                                (rat-kingdom-config-validate plist layer))))
         (merged (cl-loop for (key value) in
                          (rat-kingdom-config--merge
                           (rat-kingdom-config-layers
                            space :repo (or record repo) :epic epic :task task
                            :layer layer :plist plist))
                          when value append (list key value))))
    (cl-flet ((problem (format-string &rest args)
                (push (apply #'format format-string args) problems)))
      (when-let* ((workflow (plist-get merged :workflow)))
        (unless (rat-kingdom-config-workflow space workflow (or record repo))
          (problem "There is no workflow called %s; there are: %s" workflow
                   (rat-kingdom-config-workflow-names space
                                                      (or record repo)))))
      (cl-loop for (role kind) on (plist-get merged :agents) by #'cddr
               unless (member (format "%s" kind) (rat-kingdom-agent-names))
               do (problem ":agents %s: there is no agent called %s; there \
are: %s" role kind (string-join (rat-kingdom-agent-names) ", ")))
      (dolist (key '(:setup :check))
        (condition-case err
            (rat-kingdom-config-resolve-commands (plist-get merged key)
                                                 (plist-get merged :commands))
          (rat-kingdom-config-error (problem "%s: %s" key (cadr err)))))
      (let ((target (plist-get merged :target))
            (path (plist-get record :path)))
        (when (and target path)
          (unless (and (file-directory-p path)
                       (rat-kingdom-git-ok-p path "rev-parse" "--verify"
                                             "--quiet"
                                             (concat "refs/heads/" target)))
            (problem "The target %s is not a local branch of %s" target
                     (plist-get record :name))))))
    (nreverse problems)))

;;;; :track

(defconst rat-kingdom-config-track-directories
  `((:rk ".rk" "/.rk/")
    (:beads ".beads" ,rat-kingdom-task-br-exclude-line))
  "The directories :track keeps in or out of Git.
Each entry is (SUB-KEY DIRECTORY LINE): the :track sub-key, the
directory at the top of the checkout, and the line in info/exclude
that keeps it out.")

(defvar rat-kingdom-config--track-warnings (make-hash-table :test #'equal)
  "The warnings applying :track last gave, by repository name.")

(defun rat-kingdom-config-track-warnings (repo)
  "Return the warnings applying :track to the repository REPO last gave.
REPO is its name.  Each is a string: Git tracks files in a directory
that :track keeps out."
  (gethash repo rat-kingdom-config--track-warnings))

(defun rat-kingdom-config--track-tracked-warning (name directory files key)
  "Return the warning that Git tracks FILES in DIRECTORY of NAME.
KEY is DIRECTORY's :track sub-key."
  (let ((count (length files)))
    (format "Git already tracks %d file%s in %s of %s (%s%s), but :track %s \
is nil, so it is meant to be kept out of Git.  Excluding it does not \
affect tracked files, and rat-kingdom does not remove them from the index: \
run git rm -r --cached %s and commit to stop tracking them, or set :track \
\(%s t) to keep them."
            count (if (= count 1) "" "s") directory (or name "the repository")
            (car files) (if (> count 1) ", ..." "")
            key directory key)))

(defun rat-kingdom-config-track-apply (space repo)
  "Make REPO's info/exclude say what its :track says.
SPACE holds the configuration.  REPO is a repository's name or record.
:track is read with `rat-kingdom-config-get'.  For each directory in
`rat-kingdom-config-track-directories', a nil sub-key adds its line,
/.rk/ or /.beads/, to the info/exclude in the repository's common Git
directory, which linked worktrees share, if it is missing; t removes
that line if it is there.  No other line, and no other byte of the
file, changes.  Nothing is committed, and nothing is removed from the
index: if Git already tracks files in a directory to be kept out, a
warning says so, with `display-warning' the first time, and the line
is added anyway.  The warnings are kept for
`rat-kingdom-config-track-warnings'.

Return a property list: `:added' and `:removed', the lines added and
removed, and `:warnings', the warnings."
  (let* ((record (or (rat-kingdom-config--repo space repo)
                     (error "There is no repository called %s" repo)))
         (name (plist-get record :name))
         (top (rat-kingdom-git (or (plist-get record :path)
                                   (error "The repository %s has no path" name))
                               "rev-parse" "--show-toplevel"))
         (file (rat-kingdom-git-exclude-file top))
         (track (rat-kingdom-config-get space :track :repo record))
         added removed warnings)
    (pcase-dolist (`(,key ,directory ,line) rat-kingdom-config-track-directories)
      (if (plist-get track key)
          (when (rat-kingdom-git-unexclude file line)
            (push line removed))
        (when (rat-kingdom-git-exclude file line)
          (push line added))
        (when-let* ((files (split-string
                            (rat-kingdom-git top "ls-files" "--" directory)
                            "\n" t)))
          (push (rat-kingdom-config--track-tracked-warning
                 name directory files key)
                warnings))))
    (setq warnings (nreverse warnings))
    (let ((known (and name (gethash name rat-kingdom-config--track-warnings))))
      (dolist (warning warnings)
        (unless (member warning known)
          (display-warning 'rat-kingdom warning :warning))))
    (when name
      (if warnings
          (puthash name warnings rat-kingdom-config--track-warnings)
        (remhash name rat-kingdom-config--track-warnings)))
    (list :added (nreverse added) :removed (nreverse removed)
          :warnings warnings)))

(defun rat-kingdom-config-track-apply-all (space)
  "Apply :track, by `rat-kingdom-config-track-apply', to every repository.
SPACE holds them.  A repository whose checkout is not there is
skipped; one that fails otherwise is reported with a warning, and the
others are still done.  Return an alist from the name of each
repository done to what `rat-kingdom-config-track-apply' returned."
  (let (results)
    (dolist (repo (rat-kingdom-repo-list space))
      (let ((name (plist-get repo :name))
            (path (plist-get repo :path)))
        (when (and path (file-directory-p path))
          (condition-case err
              (push (cons name (rat-kingdom-config-track-apply space repo))
                    results)
            (error
             (display-warning
              'rat-kingdom
              (format "Could not apply :track to the repository %s: %s"
                      name (error-message-string err))
              :warning))))))
    (nreverse results)))

(defun rat-kingdom-config-repo-directory (space repo)
  "Return REPO's .rk directory, making it if it is not there.
SPACE holds the registration; REPO is a repository's name or record.
Before the directory is made, :track is applied to REPO, so that a .rk
kept out of Git never shows in `git status'.  This is for writing the
repo layer; applying :track alone never makes the directory."
  (let* ((record (or (rat-kingdom-config--repo space repo)
                     (error "There is no repository called %s" repo)))
         (directory (file-name-directory
                     (rat-kingdom-config-repo-file record))))
    (unless (file-directory-p directory)
      (rat-kingdom-config-track-apply space record)
      (make-directory directory t))
    directory))

(provide 'rat-kingdom-config)
;;; rat-kingdom-config.el ends here
