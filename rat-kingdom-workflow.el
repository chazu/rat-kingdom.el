;;; rat-kingdom-workflow.el --- Workflows as data -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Chaz Straney

;; Author: Chaz Straney <chaz.straney@gmail.com>
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;;; Commentary:

;; A workflow says which places a story's token can be at and which step
;; is taken from each place (DESIGN.md, section 7).  It is data: nothing
;; here runs anything.  rat-kingdom-story.el reads a workflow each time
;; it moves a token, so a changed workflow applies from the next move.
;;
;;   (rat-kingdom-workflow-define 'story-lite
;;     :places '(ready checking integrating done blocked)
;;     :start 'ready
;;     :final '(done)
;;     :failure 'blocked
;;     :steps '((implement :from ready :spawn rat :to checking)
;;              (check :from checking :check t :pass integrating :fail ready)
;;              (integrate :from integrating :merge t :to done
;;                         :stale checking)))
;;
;; A step has a name, the place it is taken `:from', exactly one kind,
;; and the places its outcomes lead to:
;;
;;   :spawn ROLE   start an agent, ROLE `rat' or `researcher'; `:to'
;;                 when it finishes, `:blocked' when it reports that it
;;                 cannot.  `:brief STRING' adds instructions for this
;;                 step's worker; only a spawn step may have it.
;;   :check t      merge in a candidate and run the repository's check;
;;                 `:pass' or `:fail'.  `:check (NAME ...)' runs those
;;                 commands in place of the configured check.
;;   :review WHO   wait for a verdict from WHO; `:pass' or `:fix'
;;   :merge t      move the target branch; `:to', or `:stale' if the
;;                 target moved since the check
;;   :run (NAME ...)
;;                 run commands in the story's worktree and commit what
;;                 they change; `:pass' or `:fail'
;;   :gate (:after SECONDS) or :gate (:signal NAME)
;;                 wait, with no process, for a time or a signal; `:to'
;;   :workflow NAME
;;                 run a child story with the workflow NAME; `:to', or
;;                 `:fail' if it stops short of a final place
;;
;; An outcome with no place leads to the workflow's `:failure' place.  A
;; token at a place no step is taken from stays there until it is moved
;; by hand; at a `:final' place the story is over and is archived.
;;
;; `:timeout' on a step is how many seconds it may take before the story
;; is reported stuck.  `:attempts' on a spawn step is how many workers
;; one story may be given there.
;;
;; Names are stored as strings, because that is how a token read back
;; from the space names its place.
;;
;; The workflows defined here are the built-in ones.  Workflows can also
;; be files, for every repository or for one (DESIGN.md, section 7.3);
;; rat-kingdom-config.el reads them, and `rat-kingdom-config-workflow'
;; resolves a name for a repository.  The engine looks workflows up
;; there, not with `rat-kingdom-workflow-get'.

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defconst rat-kingdom-workflow-kinds
  '((:spawn :to :blocked)
    (:check :pass :fail)
    (:review :pass :fix)
    (:merge :to :stale)
    (:run :pass :fail)
    (:gate :to)
    (:workflow :to :fail))
  "Each kind of step, followed by its outcomes.
The first outcome must be given a place; the others default to the
workflow's failure place.")

(defconst rat-kingdom-workflow-roles '(rat researcher)
  "The roles a `:spawn' step can start.")

(defvar rat-kingdom-workflow--table nil
  "Alist from workflow name to its normalized property list.")

(defun rat-kingdom-workflow--name (value)
  "Return VALUE, a symbol or string, as a string."
  (if (symbolp value) (symbol-name value) value))

(defun rat-kingdom-workflow--step-kind (step)
  "Return the kind keyword of the raw STEP, or nil unless it has exactly one."
  (let ((kinds (cl-remove-if-not (lambda (kind) (plist-member (cdr step) kind))
                                 (mapcar #'car rat-kingdom-workflow-kinds))))
    (and (null (cdr kinds)) (car kinds))))

(defun rat-kingdom-workflow--normalize (name spec)
  "Return the workflow NAME described by the property list SPEC, normalized.
Places and step names become strings, each step gets `:name',
`:kind', `:with' (the kind's value) and `:brief', and outcomes left out
get the failure place."
  (let* ((failure (rat-kingdom-workflow--name
                   (or (plist-get spec :failure) "blocked")))
         (steps
          (mapcar
           (lambda (step)
             (let* ((kind (rat-kingdom-workflow--step-kind step))
                    (plist (cdr step))
                    (normal (list :name (rat-kingdom-workflow--name (car step))
                                  :kind kind
                                  :from (rat-kingdom-workflow--name
                                         (plist-get plist :from))
                                  :with (and kind (plist-get plist kind))
                                  :timeout (plist-get plist :timeout)
                                  :attempts (plist-get plist :attempts)
                                  :brief (plist-get plist :brief))))
               (dolist (outcome (cdr (assq kind rat-kingdom-workflow-kinds)))
                 (setq normal
                       (plist-put normal outcome
                                  (rat-kingdom-workflow--name
                                   (or (plist-get plist outcome) failure)))))
               normal))
           (plist-get spec :steps))))
    (list :name (rat-kingdom-workflow--name name)
          :doc (plist-get spec :doc)
          :places (mapcar #'rat-kingdom-workflow--name (plist-get spec :places))
          :start (rat-kingdom-workflow--name (plist-get spec :start))
          :final (mapcar #'rat-kingdom-workflow--name (plist-get spec :final))
          :failure failure
          :steps steps
          :mixins (plist-get spec :mixins)
          :aspects (plist-get spec :aspects))))

(defun rat-kingdom-workflow--name-symbol-p (value)
  "Return non-nil if VALUE is a symbol that can be a name.
That is any symbol but nil, t and keywords."
  (and value (symbolp value) (not (eq value t)) (not (keywordp value))))

(defun rat-kingdom-workflow--name-p (value)
  "Return non-nil if VALUE is a name: such a symbol, or a non-blank string."
  (or (rat-kingdom-workflow--name-symbol-p value)
      (and (stringp value) (not (string-blank-p value)))))

(defun rat-kingdom-workflow--command-names-p (value)
  "Return non-nil if VALUE is a non-empty list of command names."
  (and value (proper-list-p value)
       (cl-every #'rat-kingdom-workflow--name-symbol-p value)))

(defun rat-kingdom-workflow--value-problem (step)
  "Return what is wrong with the value of the normalized STEP's kind, or nil."
  (let ((name (plist-get step :name))
        (value (plist-get step :with)))
    (pcase (plist-get step :kind)
      (:spawn
       (unless (memq value rat-kingdom-workflow-roles)
         (format "Step %s spawns %S, which is not a role; the roles are %s"
                 name value
                 (mapconcat #'symbol-name rat-kingdom-workflow-roles ", "))))
      (:check
       (unless (or (eq value t) (rat-kingdom-workflow--command-names-p value))
         (format "Step %s checks %S; a check is t or a list of command \
names such as (lint test)" name value)))
      (:run
       (unless (rat-kingdom-workflow--command-names-p value)
         (format "Step %s runs %S; a run is a list of command names such \
as (format)" name value)))
      (:gate
       (unless (pcase value
                 (`(:after ,seconds) (and (numberp seconds) (> seconds 0)))
                 (`(:signal ,signal) (rat-kingdom-workflow--name-p signal)))
         (format "Step %s waits for %S; a gate is (:after SECONDS), SECONDS \
a positive number, or (:signal NAME), NAME a symbol or string" name value)))
      (:workflow
       (unless (rat-kingdom-workflow--name-p value)
         (format "Step %s runs the workflow %S; a workflow name is a symbol \
or string" name value))))))

(defun rat-kingdom-workflow-validate (spec)
  "Return what is wrong with the workflow described by SPEC, as strings.
SPEC is the property list `rat-kingdom-workflow-define' takes.  Return
nil if the workflow is sound."
  (let (problems)
    (cl-flet ((problem (format-string &rest args)
                (push (apply #'format format-string args) problems)))
      (dolist (step (plist-get spec :steps))
        (cond
         ((not (and (consp step) (car step) (symbolp (car step))
                    (proper-list-p step) (cl-evenp (length (cdr step)))))
          (problem "A step is a name followed by a property list: %S" step))
         ((not (rat-kingdom-workflow--step-kind step))
          (problem "Step %s needs exactly one of %s" (car step)
                   (mapconcat (lambda (kind) (symbol-name (car kind)))
                              rat-kingdom-workflow-kinds ", ")))))
      (unless problems
        (let* ((workflow (rat-kingdom-workflow--normalize "?" spec))
               (places (plist-get workflow :places))
               (final (plist-get workflow :final))
               (steps (plist-get workflow :steps))
               (reached (list (plist-get workflow :start))))
          (unless places
            (problem "The workflow has no places"))
          (unless (equal places (cl-remove-duplicates places :test #'equal))
            (problem "A place is listed twice"))
          (unless (member (plist-get workflow :start) places)
            (problem "The start %s is not a place" (plist-get workflow :start)))
          (unless final
            (problem "The workflow has no final place"))
          (dolist (place final)
            (unless (member place places)
              (problem "The final place %s is not a place" place)))
          (unless (member (plist-get workflow :failure) places)
            (problem "The failure place %s is not a place"
                     (plist-get workflow :failure)))
          (when (member (plist-get workflow :failure) final)
            (problem "The failure place %s cannot be final"
                     (plist-get workflow :failure)))
          (dolist (step steps)
            (let ((name (plist-get step :name))
                  (kind (plist-get step :kind)))
              (unless (member (plist-get step :from) places)
                (problem "Step %s is taken from %s, which is not a place"
                         name (plist-get step :from)))
              (when (member (plist-get step :from) final)
                (problem "Step %s is taken from the final place %s"
                         name (plist-get step :from)))
              (when (> (cl-count (plist-get step :from) steps
                                 :key (lambda (other) (plist-get other :from))
                                 :test #'equal)
                       1)
                (problem "More than one step is taken from %s"
                         (plist-get step :from)))
              (when (> (cl-count name steps
                                 :key (lambda (other) (plist-get other :name))
                                 :test #'equal)
                       1)
                (problem "More than one step is called %s" name))
              (pcase-let ((`(,first . ,_) (cdr (assq kind
                                                    rat-kingdom-workflow-kinds))))
                (unless (plist-get (cdr (assq (intern name)
                                              (plist-get spec :steps)))
                                   first)
                  (problem "Step %s does not say where %s leads" name first)))
              (dolist (outcome (cdr (assq kind rat-kingdom-workflow-kinds)))
                (unless (member (plist-get step outcome) places)
                  (problem "Step %s leads to %s, which is not a place"
                           name (plist-get step outcome))))
              (when-let* ((problem (rat-kingdom-workflow--value-problem step)))
                (problem "%s" problem))
              (when (plist-member (cdr (assq (intern name)
                                             (plist-get spec :steps)))
                                  :brief)
                (cond
                 ((not (eq kind :spawn))
                  (problem "Step %s has a :brief, which only a spawn step \
may have" name))
                 ((not (stringp (plist-get step :brief)))
                  (problem "The brief of step %s is not a string" name))))
              (when (and (plist-get step :timeout)
                         (not (and (numberp (plist-get step :timeout))
                                   (> (plist-get step :timeout) 0))))
                (problem "The timeout of step %s is not a number of seconds"
                         name))
              (when (and (plist-get step :attempts)
                         (not (and (integerp (plist-get step :attempts))
                                   (> (plist-get step :attempts) 0))))
                (problem "The attempts of step %s is not a count" name))))
          (dolist (composition (rat-kingdom-workflow--composition-problems spec))
            (problem "%s" composition))
          ;; Every place can be reached, and a final place among them.
          (let ((grew t))
            (while grew
              (setq grew nil)
              (dolist (step steps)
                (when (member (plist-get step :from) reached)
                  (dolist (outcome (cdr (assq (plist-get step :kind)
                                              rat-kingdom-workflow-kinds)))
                    (unless (member (plist-get step outcome) reached)
                      (push (plist-get step outcome) reached)
                      (setq grew t)))))))
          (unless (cl-intersection final reached :test #'equal)
            (problem "No final place can be reached from the start"))
          (dolist (place places)
            (unless (or (member place reached)
                        (equal place (plist-get workflow :failure)))
              (problem "The place %s cannot be reached" place)))
          (dolist (place reached)
            (unless (or (member place final)
                        (equal place (plist-get workflow :failure))
                        (cl-find place steps
                                 :key (lambda (step) (plist-get step :from))
                                 :test #'equal))
              (problem "No step is taken from %s, and it is not final"
                       place))))))
    (nreverse problems)))

(defun rat-kingdom-workflow-define (name &rest spec)
  "Define the workflow NAME, replacing any workflow of that name.
SPEC is a property list: `:places', `:start', `:final', `:failure'
\(by default `blocked'), `:steps', `:doc', `:mixins' and `:aspects'.
The commentary of this file describes a step.  The workflow is stored
as it is written; its mixins and aspects are applied when it is looked
up (`rat-kingdom-workflow-expand').  Signal an error if the workflow
is not sound, or does not expand with the built-in mixins.  Return the
workflow."
  (when-let* ((problems (rat-kingdom-workflow-validate spec)))
    (error "Workflow %s: %s" name (string-join problems "; ")))
  (let ((workflow (rat-kingdom-workflow--normalize name spec)))
    (condition-case err
        (rat-kingdom-workflow-expand workflow)
      (rat-kingdom-workflow-expansion-error
       (error "Workflow %s cannot be built: %s" name (cadr err))))
    (setf (alist-get (plist-get workflow :name) rat-kingdom-workflow--table
                     nil nil #'equal)
          workflow)
    workflow))

(defun rat-kingdom-workflow-get (name)
  "Return the workflow called NAME, a symbol or string, or nil.
Only workflows defined with `rat-kingdom-workflow-define' are known
here; `rat-kingdom-config-workflow' also knows workflow files."
  (alist-get (rat-kingdom-workflow--name name) rat-kingdom-workflow--table
             nil nil #'equal))

(defun rat-kingdom-workflow-list ()
  "Return every defined workflow, sorted by name."
  (sort (mapcar #'cdr rat-kingdom-workflow--table)
        (lambda (a b) (string< (plist-get a :name) (plist-get b :name)))))

(defun rat-kingdom-workflow-step (workflow place)
  "Return the step of WORKFLOW taken from PLACE, or nil."
  (cl-find place (plist-get workflow :steps)
           :key (lambda (step) (plist-get step :from)) :test #'equal))

(defun rat-kingdom-workflow-step-named (workflow name)
  "Return the step of WORKFLOW called NAME, or nil."
  (cl-find name (plist-get workflow :steps)
           :key (lambda (step) (plist-get step :name)) :test #'equal))

(defun rat-kingdom-workflow-final-p (workflow place)
  "Return non-nil if PLACE is a final place of WORKFLOW."
  (member place (plist-get workflow :final)))

(defun rat-kingdom-workflow--describe-kind (step)
  "Return text saying what the normalized STEP does, such as \"run (format)\".
A brief is shown, shortened, after the kind."
  (let ((kind (substring (symbol-name (plist-get step :kind)) 1))
        (value (plist-get step :with))
        (brief (plist-get step :brief)))
    (concat
     (pcase value
       ('t kind)
       (`(:after ,seconds) (format "%s after %ss" kind seconds))
       (`(:signal ,signal) (format "%s signal %s" kind signal))
       (_ (format "%s %s" kind value)))
     (if (stringp brief)
         (format " (brief: %s)"
                 (truncate-string-to-width
                  (string-trim (replace-regexp-in-string "[ \t\n]+" " " brief))
                  40 nil nil "..."))
       ""))))

(defun rat-kingdom-workflow-describe (workflow &optional origin layer)
  "Return a few lines of text describing WORKFLOW.
ORIGIN, if given, is text saying where it comes from, on its own line
after the first.  If WORKFLOW was built from mixins or aspects, a line
says so (`rat-kingdom-workflow-composition'); LAYER is the layer its
configured mixins come from."
  (concat
   (format "%s: %s\n" (plist-get workflow :name)
           (or (plist-get workflow :doc) "no description"))
   (if origin (format "  (%s)\n" origin) "")
   (if-let* ((composition (rat-kingdom-workflow-composition workflow layer)))
       (format "  Built from %s.\n" composition)
     "")
   (mapconcat
    (lambda (step)
      (format "  %s: at %s, %s; %s"
              (plist-get step :name) (plist-get step :from)
              (rat-kingdom-workflow--describe-kind step)
              (mapconcat (lambda (outcome)
                           (format "%s -> %s" (substring (symbol-name outcome) 1)
                                   (plist-get step outcome)))
                         (cdr (assq (plist-get step :kind)
                                    rat-kingdom-workflow-kinds))
                         ", ")))
    (plist-get workflow :steps) "\n")))

;;;; Mixins and aspects

;; A workflow may have `:mixins (NAME ...)' and `:aspects (ASPECT ...)'
;; (DESIGN.md, section 7.1).  They are not applied when it is defined:
;; `rat-kingdom-workflow-expand' applies them when the workflow is
;; looked up, with the mixins configuration adds, so a change to either
;; applies from a token's next move.
;;
;; A mixin is a property list of `rat-kingdom-workflow-mixin-keys',
;; applied in that order: `:remove' drops steps, `:places' and `:steps'
;; add to the workflow's, and `:aspects' are applied.  An aspect is
;;
;;   (:before MATCH STEP-BODY)  a step on the way into each matched step
;;   (:after MATCH STEP-BODY)   a step on each matched step's first outcome
;;   (:around MATCH PROPS)      set :timeout, :attempts or :brief on them
;;
;; MATCH is a step name, a kind keyword such as :check, or t for every
;; step.  STEP-BODY is a step without a name or :from, whose first
;; outcome the aspect places; a :before body may have :entry, `all'
;; (the default) or `start'.

(define-error 'rat-kingdom-workflow-expansion-error
  "The workflow cannot be built")

(defconst rat-kingdom-workflow-mixin-keys
  '(:doc :remove :places :steps :aspects)
  "The keys a mixin may have, in the order they are applied.")

(defconst rat-kingdom-workflow-around-keys '(:timeout :attempts :brief)
  "The keys an `:around' aspect may set.")

(defvar rat-kingdom-workflow--mixins nil
  "Alist from mixin name to the mixin, defined with
`rat-kingdom-workflow-define-mixin'.")

(defun rat-kingdom-workflow--outcomes (kind)
  "Return the outcomes of steps of KIND, the first first."
  (cdr (assq kind rat-kingdom-workflow-kinds)))

(defun rat-kingdom-workflow--plist-keys-problem (plist allowed what)
  "Return what is wrong with the keys of PLIST, or nil.
ALLOWED is the keys it may have, WHAT how to name it in the message."
  (if (not (and (proper-list-p plist) (cl-evenp (length plist))))
      (format "%s is not a property list" what)
    (let (seen)
      (cl-loop for (key) on plist by #'cddr
               for problem = (cond
                              ((memq key seen)
                               (format "%s has %S twice" what key))
                              ((not (memq key allowed))
                               (format "%s has %S; it may have %s" what key
                                       (mapconcat #'symbol-name allowed " "))))
               do (push key seen)
               when problem return problem))))

(defun rat-kingdom-workflow--props-problem (plist what)
  "Return what is wrong with :timeout, :attempts or :brief in PLIST, or nil.
WHAT names what PLIST belongs to."
  (cond
   ((and (plist-member plist :timeout)
         (not (and (numberp (plist-get plist :timeout))
                   (> (plist-get plist :timeout) 0))))
    (format "the timeout of %s is not a number of seconds" what))
   ((and (plist-member plist :attempts)
         (not (and (integerp (plist-get plist :attempts))
                   (> (plist-get plist :attempts) 0))))
    (format "the attempts of %s is not a count" what))
   ((and (plist-member plist :brief)
         (not (stringp (plist-get plist :brief))))
    (format "the brief of %s is not a string" what))))

(defun rat-kingdom-workflow--body-problem (form body)
  "Return what is wrong with BODY as the STEP-BODY of a FORM aspect, or nil.
FORM is :before or :after."
  (let ((kind (rat-kingdom-workflow--step-kind (cons nil body))))
    (cond
     ((not (and (proper-list-p body) (cl-evenp (length body))))
      "its step is not a property list")
     ((plist-member body :from)
      "its step has :from; the aspect says where it is taken from")
     ((null kind)
      (format "its step needs exactly one of %s"
              (mapconcat (lambda (kind) (symbol-name (car kind)))
                         rat-kingdom-workflow-kinds ", ")))
     ((plist-member body (car (rat-kingdom-workflow--outcomes kind)))
      (format "its step names its first outcome %s, which the aspect places"
              (car (rat-kingdom-workflow--outcomes kind))))
     ((and (plist-member body :entry) (not (eq form :before)))
      (format "only a :before aspect may have :entry, not %s" form))
     ((and (plist-member body :entry)
           (not (memq (plist-get body :entry) '(all start))))
      (format ":entry is all or start, not %S" (plist-get body :entry)))
     ((rat-kingdom-workflow--plist-keys-problem
       body
       (append (list kind :timeout :attempts :brief)
               (cdr (rat-kingdom-workflow--outcomes kind))
               (and (eq form :before) '(:entry)))
       "its step"))
     ((cl-loop for outcome in (cdr (rat-kingdom-workflow--outcomes kind))
               when (and (plist-member body outcome)
                         (not (rat-kingdom-workflow--name-p
                               (plist-get body outcome))))
               return (format "its outcome %s does not lead to a place name"
                              outcome)))
     ((rat-kingdom-workflow--value-problem
       (list :name "added by the aspect" :kind kind :with (plist-get body kind))))
     ((and (plist-member body :brief) (not (eq kind :spawn)))
      "its step has a :brief, which only a spawn step may have")
     ((rat-kingdom-workflow--props-problem body "its step")))))

(defun rat-kingdom-workflow-aspect-problem (aspect)
  "Return what is wrong with ASPECT, as a sentence, or nil if it is sound."
  (let ((problem
         (pcase aspect
           ((and `(,form ,match . ,body)
                 (guard (memq form '(:before :after :around))))
            (cond
             ((not (or (eq match t) (assq match rat-kingdom-workflow-kinds)
                       (rat-kingdom-workflow--name-symbol-p match)))
              (format "it matches %S, which is not a step name, a kind such \
as :check, or t" match))
             ((not (eq form :around))
              (rat-kingdom-workflow--body-problem form body))
             ((null body) "it sets nothing")
             ((rat-kingdom-workflow--plist-keys-problem
               body rat-kingdom-workflow-around-keys "it"))
             ((rat-kingdom-workflow--props-problem body "it"))))
           (_ "it is not (:before MATCH STEP-BODY), (:after MATCH STEP-BODY) \
or (:around MATCH PROPS)"))))
    (when problem
      (let ((print-length nil) (print-level nil))
        (format "The aspect %S is wrong: %s" aspect problem)))))

(defun rat-kingdom-workflow--names-problem (value what)
  "Return what is wrong with VALUE as a list of names, or nil.
WHAT names the value in the message."
  (unless (and (proper-list-p value)
               (cl-every #'rat-kingdom-workflow--name-symbol-p value))
    (format "%s is a list of names such as (no-review), not %S" what value)))

(defun rat-kingdom-workflow--composition-problems (spec)
  "Return what is wrong with the `:mixins' and `:aspects' of SPEC, as strings."
  (let ((aspects (plist-get spec :aspects)))
    (delq nil
          (cons (rat-kingdom-workflow--names-problem
                 (plist-get spec :mixins) ":mixins")
                (if (proper-list-p aspects)
                    (mapcar #'rat-kingdom-workflow-aspect-problem aspects)
                  (list (format ":aspects is a list of aspects, not %S"
                                aspects)))))))

(defun rat-kingdom-workflow-mixin-problems (spec)
  "Return what is wrong with SPEC as a mixin, as strings, or nil.
SPEC is a property list of `rat-kingdom-workflow-mixin-keys', as
`rat-kingdom-workflow-define-mixin' takes it and a mixin file holds it."
  (if-let* ((problem (rat-kingdom-workflow--plist-keys-problem
                      spec rat-kingdom-workflow-mixin-keys "A mixin")))
      (list problem)
    (let ((places (plist-get spec :places))
          (steps (plist-get spec :steps))
          (aspects (plist-get spec :aspects))
          problems)
      (cl-flet ((problem (problem) (when problem (push problem problems))))
        (when (and (plist-get spec :doc) (not (stringp (plist-get spec :doc))))
          (problem (format ":doc is a string, not %S" (plist-get spec :doc))))
        (problem (rat-kingdom-workflow--names-problem (plist-get spec :remove)
                                                      ":remove"))
        (unless (and (proper-list-p places)
                     (cl-every #'rat-kingdom-workflow--name-p places))
          (problem (format ":places is a list of place names, not %S" places)))
        (if (not (proper-list-p steps))
            (problem (format ":steps is a list of steps, not %S" steps))
          (dolist (step steps)
            (cond
             ((not (and (consp step)
                        (rat-kingdom-workflow--name-symbol-p (car step))
                        (proper-list-p step) (cl-evenp (length (cdr step)))))
              (problem (format "A step is a name followed by a property list: \
%S" step)))
             ((not (rat-kingdom-workflow--step-kind step))
              (problem (format "Step %s needs exactly one of %s" (car step)
                               (mapconcat (lambda (kind) (symbol-name (car kind)))
                                          rat-kingdom-workflow-kinds ", "))))
             ((not (rat-kingdom-workflow--name-p (plist-get (cdr step) :from)))
              (problem (format "Step %s has no :from" (car step)))))))
        (if (not (proper-list-p aspects))
            (problem (format ":aspects is a list of aspects, not %S" aspects))
          (mapc (lambda (aspect)
                  (problem (rat-kingdom-workflow-aspect-problem aspect)))
                aspects)))
      (nreverse problems))))

(defun rat-kingdom-workflow--normalize-mixin (name spec)
  "Return the mixin NAME described by the sound property list SPEC."
  (list :name (rat-kingdom-workflow--name name)
        :doc (plist-get spec :doc)
        :remove (plist-get spec :remove)
        :places (plist-get spec :places)
        :steps (plist-get spec :steps)
        :aspects (plist-get spec :aspects)))

(defun rat-kingdom-workflow-define-mixin (name &rest spec)
  "Define the mixin NAME, replacing any mixin of that name.
SPEC is a property list of `rat-kingdom-workflow-mixin-keys'.  Signal
an error if it is not sound, as `rat-kingdom-workflow-mixin-problems'
says.  Return the mixin."
  (when-let* ((problems (rat-kingdom-workflow-mixin-problems spec)))
    (error "Mixin %s: %s" name (string-join problems "; ")))
  (let ((mixin (rat-kingdom-workflow--normalize-mixin name spec)))
    (setf (alist-get (plist-get mixin :name) rat-kingdom-workflow--mixins
                     nil nil #'equal)
          mixin)
    mixin))

(defun rat-kingdom-workflow-mixin-get (name)
  "Return the built-in mixin called NAME, a symbol or string, or nil.
Mixin files are known to `rat-kingdom-config-mixin', not here."
  (alist-get (rat-kingdom-workflow--name name) rat-kingdom-workflow--mixins
             nil nil #'equal))

(defun rat-kingdom-workflow-mixin-list ()
  "Return every built-in mixin, sorted by name."
  (sort (mapcar #'cdr rat-kingdom-workflow--mixins)
        (lambda (a b) (string< (plist-get a :name) (plist-get b :name)))))

(defun rat-kingdom-workflow--raw (workflow)
  "Return the normalized WORKFLOW as the property list it could be defined by.
Every outcome is written out."
  (list :doc (plist-get workflow :doc)
        :places (mapcar #'intern (plist-get workflow :places))
        :start (intern (plist-get workflow :start))
        :final (mapcar #'intern (plist-get workflow :final))
        :failure (intern (plist-get workflow :failure))
        :steps
        (mapcar
         (lambda (step)
           (let ((kind (plist-get step :kind)))
             (append
              (list (intern (plist-get step :name))
                    :from (intern (plist-get step :from))
                    kind (plist-get step :with))
              (mapcan (lambda (outcome)
                        (list outcome (intern (plist-get step outcome))))
                      (rat-kingdom-workflow--outcomes kind))
              (mapcan (lambda (key)
                        (and (plist-get step key)
                             (list key (plist-get step key))))
                      '(:timeout :attempts :brief)))))
         (plist-get workflow :steps))
        :mixins (plist-get workflow :mixins)
        :aspects (plist-get workflow :aspects)))

(defun rat-kingdom-workflow-expand (workflow &optional mixins lookup)
  "Return WORKFLOW, normalized, with its mixins and aspects applied.
MIXINS is a list of further mixin names, from the configuration.
LOOKUP is a function from a mixin's name, a string, to the mixin or
nil; by default `rat-kingdom-workflow-mixin-get', the built-in ones.

The workflow's own mixins are applied in order, then MIXINS, then its
own aspects; a mixin named twice is applied where it first appears.
The result is validated by `rat-kingdom-workflow-validate'.  It has the
workflow's `:mixins' and `:aspects' as written, and `:extra-mixins',
MIXINS, when there are any.  A workflow with nothing to apply is
returned as it is.  WORKFLOW is not changed, and the same arguments
always give the same result.

Signal `rat-kingdom-workflow-expansion-error', with a phrase saying
what is wrong, if a mixin is not defined, a mixin or an aspect cannot
be applied, or the result is not sound."
  (let ((own (plist-get workflow :mixins))
        (aspects (plist-get workflow :aspects))
        (lookup (or lookup #'rat-kingdom-workflow-mixin-get)))
    (if (not (or own mixins aspects))
        workflow
      (let* ((places (copy-sequence (plist-get workflow :places)))
             (start (plist-get workflow :start))
             (failure (plist-get workflow :failure))
             (steps (mapcar #'copy-sequence (plist-get workflow :steps)))
             (added nil)
             (names nil))
        (dolist (name (append own mixins))
          (cl-pushnew (rat-kingdom-workflow--name name) names :test #'equal))
        (cl-labels
            ((fail (format-string &rest args)
               (signal 'rat-kingdom-workflow-expansion-error
                       (list (apply #'format format-string args))))
             (first-outcome (step)
               (car (rat-kingdom-workflow--outcomes (plist-get step :kind))))
             (set-outcome (step outcome place)
               (setcar (cdr (plist-member step outcome)) place))
             (redirect (from to)
               ;; Every outcome that leads to FROM leads to TO.
               (dolist (step steps)
                 (dolist (outcome (rat-kingdom-workflow--outcomes
                                   (plist-get step :kind)))
                   (when (equal (plist-get step outcome) from)
                     (set-outcome step outcome to)))))
             (step-names ()
               (mapcar (lambda (step) (plist-get step :name)) steps))
             (fresh (base)
               (let ((name base) (n 1))
                 (while (or (member name places) (member name (step-names)))
                   (setq n (1+ n)
                         name (format "%s-%d" base n)))
                 name))
             (insert-at (list index element)
               (append (cl-subseq list 0 index) (list element)
                       (nthcdr index list)))
             (make-step (name from body first)
               (let* ((kind (rat-kingdom-workflow--step-kind (cons nil body)))
                      (step (list :name name :kind kind :from from
                                  :with (plist-get body kind)
                                  :timeout (plist-get body :timeout)
                                  :attempts (plist-get body :attempts)
                                  :brief (plist-get body :brief))))
                 (cl-loop for outcome in (rat-kingdom-workflow--outcomes kind)
                          for index from 0
                          do (setq step
                                   (append step
                                           (list outcome
                                                 (if (zerop index)
                                                     first
                                                   (rat-kingdom-workflow--name
                                                    (or (plist-get body outcome)
                                                        failure)))))))
                 step))
             (remove-step (name)
               (when-let* ((step (cl-find name steps
                                          :key (lambda (step)
                                                 (plist-get step :name))
                                          :test #'equal)))
                 (let ((place (plist-get step :from))
                       (next (plist-get step (first-outcome step))))
                   (when (equal next place)
                     (fail "the step %s cannot be removed: its first outcome \
leads back to its own place %s" name place))
                   (setq steps (delq step steps)
                         places (remove place places))
                   (redirect place next)
                   (when (equal start place)
                     (setq start next)))))
             (matches (match)
               (cl-remove-if-not
                (lambda (step)
                  (and (not (member (plist-get step :name) added))
                       (cond ((eq match t) t)
                             ((keywordp match) (eq (plist-get step :kind) match))
                             (t (equal (plist-get step :name)
                                       (rat-kingdom-workflow--name match))))))
                steps))
             (before (step body)
               (let ((place (plist-get step :from))
                     (entry (or (plist-get body :entry) 'all)))
                 (when (or (eq entry 'all) (equal start place))
                   (let ((name (fresh (concat "before-" (plist-get step :name)))))
                     (if (eq entry 'all)
                         (progn (redirect place name)
                                (when (equal start place) (setq start name)))
                       (setq start name))
                     (setq places (insert-at places
                                             (cl-position place places
                                                          :test #'equal)
                                             name)
                           steps (insert-at steps (cl-position step steps)
                                            (make-step name name
                                                       (rat-kingdom-workflow--without
                                                        body :entry)
                                                       place)))
                     (push name added)))))
             (after (step body)
               (let* ((outcome (first-outcome step))
                      (next (plist-get step outcome))
                      (name (fresh (concat "after-" (plist-get step :name)))))
                 (set-outcome step outcome name)
                 (setq places (insert-at places
                                         (1+ (cl-position (plist-get step :from)
                                                          places :test #'equal))
                                         name)
                       steps (insert-at steps (1+ (cl-position step steps))
                                        (make-step name name body next)))
                 (push name added)))
             (around (step props)
               (cl-loop for (key value) on props by #'cddr
                        unless (and (eq key :brief)
                                    (not (eq (plist-get step :kind) :spawn)))
                        do (setcar (cdr (plist-member step key)) value)))
             (apply-aspect (aspect)
               (when-let* ((problem (rat-kingdom-workflow-aspect-problem aspect)))
                 (fail "t%s" (substring problem 1)))
               (pcase-let ((`(,form ,match . ,body) aspect))
                 (dolist (step (matches match))
                   (pcase form
                     (:before (before step body))
                     (:after (after step body))
                     (:around (around step body))))))
             (apply-mixin (name)
               (let ((mixin (or (funcall lookup name)
                                (fail "there is no mixin called %s" name))))
                 (mapc (lambda (step) (remove-step (rat-kingdom-workflow--name step)))
                       (plist-get mixin :remove))
                 (dolist (place (plist-get mixin :places))
                   (let ((place (rat-kingdom-workflow--name place)))
                     (when (member place places)
                       (fail "the mixin %s adds the place %s, which the \
workflow already has" name place))
                     (setq places (append places (list place)))))
                 (dolist (step (plist-get (rat-kingdom-workflow--normalize
                                           "?" (list :failure failure
                                                     :steps (plist-get mixin
                                                                       :steps)))
                                          :steps))
                   (when (member (plist-get step :name) (step-names))
                     (fail "the mixin %s adds the step %s, which the workflow \
already has" name (plist-get step :name)))
                   (setq steps (append steps (list step))))
                 (mapc #'apply-aspect (plist-get mixin :aspects)))))
          (mapc #'apply-mixin (reverse names))
          (mapc #'apply-aspect aspects))
        (let* ((spec (rat-kingdom-workflow--raw
                      (list :doc (plist-get workflow :doc) :places places
                            :start start :final (plist-get workflow :final)
                            :failure failure :steps steps
                            :mixins own :aspects aspects)))
               (problems (rat-kingdom-workflow-validate spec)))
          (when problems
            (signal 'rat-kingdom-workflow-expansion-error
                    (list (format "the result is not sound: %s"
                                  (string-join problems "; ")))))
          (append (rat-kingdom-workflow--normalize (plist-get workflow :name)
                                                   spec)
                  (and mixins (list :extra-mixins mixins))))))))

(defun rat-kingdom-workflow--without (plist key)
  "Return PLIST without KEY."
  (cl-loop for (k v) on plist by #'cddr
           unless (eq k key) append (list k v)))

(defun rat-kingdom-workflow-composition (workflow &optional layer)
  "Return text saying what WORKFLOW was built from, or nil if nothing.
That is its own mixins, the mixins configuration added and its aspects,
as written.  LAYER, if given, is the configuration layer the added
mixins come from."
  (let ((print-length nil) (print-level nil)
        (own (plist-get workflow :mixins))
        (extra (plist-get workflow :extra-mixins))
        (aspects (plist-get workflow :aspects)))
    (when (or own extra aspects)
      (string-join
       (delq nil
             (list (and own (format "its mixins %s"
                                    (mapconcat #'symbol-name own " ")))
                   (and extra (format "the mixins %s of :mixins%s"
                                      (mapconcat (lambda (name) (format "%s" name))
                                                 extra " ")
                                      (if layer
                                          (format " (from the %s layer)" layer)
                                        "")))
                   (and aspects (format "its aspects %s"
                                        (mapconcat #'prin1-to-string aspects
                                                   " ")))))
       "; "))))

(defun rat-kingdom-workflow-describe-mixin (mixin &optional origin)
  "Return a line describing MIXIN; ORIGIN says where it comes from."
  (format "%s: %s%s" (plist-get mixin :name)
          (or (plist-get mixin :doc) "no description")
          (if origin (format " (%s)" origin) "")))

;;;; The workflows that come with rat-kingdom

(rat-kingdom-workflow-define-mixin
 'no-review
 :doc "No review: work whose check passes is merged."
 :remove '(review))

(rat-kingdom-workflow-define-mixin
 'tdd
 :doc "A worker writes failing tests before another implements the task."
 :aspects '((:before implement :entry start :spawn rat
             :brief "Write failing tests for the task and commit them; \
do not implement it.")))

(rat-kingdom-workflow-define
 'story
 :doc "A worker implements, the check runs, the king reviews, then it is \
merged.  A failed check or a review that asks for changes goes back to a \
worker."
 :places '(ready checking review integrating done blocked)
 :start 'ready
 :final '(done)
 :steps '((implement :from ready :spawn rat :to checking)
          (check :from checking :check t :pass review :fail ready)
          (review :from review :review king :pass integrating :fix ready)
          (integrate :from integrating :merge t :to done :stale checking)))

(rat-kingdom-workflow-define
 'story-lite
 :doc "As story, with no review: work whose check passes is merged."
 :places '(ready checking integrating done blocked)
 :start 'ready
 :final '(done)
 :steps '((implement :from ready :spawn rat :to checking)
          (check :from checking :check t :pass integrating :fail ready)
          (integrate :from integrating :merge t :to done :stale checking)))

(provide 'rat-kingdom-workflow)
;;; rat-kingdom-workflow.el ends here
