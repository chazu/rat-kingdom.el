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
;;   :spawn ROLE   start an agent; `:to' when it finishes, `:blocked'
;;                 when it reports that it cannot
;;   :check t      merge in a candidate and run the repository's check;
;;                 `:pass' or `:fail'
;;   :review WHO   wait for a verdict from WHO; `:pass' or `:fix'
;;   :merge t      move the target branch; `:to', or `:stale' if the
;;                 target moved since the check
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

;;; Code:

(require 'cl-lib)
(require 'subr-x)

(defconst rat-kingdom-workflow-kinds
  '((:spawn :to :blocked)
    (:check :pass :fail)
    (:review :pass :fix)
    (:merge :to :stale))
  "Each kind of step, followed by its outcomes.
The first outcome must be given a place; the others default to the
workflow's failure place.")

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
Places and step names become strings, each step gets `:name' and
`:kind', and outcomes left out get the failure place."
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
                                  :attempts (plist-get plist :attempts))))
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
          :steps steps)))

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
              (when (and (plist-get step :timeout)
                         (not (and (numberp (plist-get step :timeout))
                                   (> (plist-get step :timeout) 0))))
                (problem "The timeout of step %s is not a number of seconds"
                         name))
              (when (and (plist-get step :attempts)
                         (not (and (integerp (plist-get step :attempts))
                                   (> (plist-get step :attempts) 0))))
                (problem "The attempts of step %s is not a count" name))))
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
\(by default `blocked'), `:steps' and `:doc'.  The commentary of this
file describes a step.  Signal an error if the workflow is not sound.
Return the workflow."
  (when-let* ((problems (rat-kingdom-workflow-validate spec)))
    (error "Workflow %s: %s" name (string-join problems "; ")))
  (let ((workflow (rat-kingdom-workflow--normalize name spec)))
    (setf (alist-get (plist-get workflow :name) rat-kingdom-workflow--table
                     nil nil #'equal)
          workflow)
    workflow))

(defun rat-kingdom-workflow-get (name)
  "Return the workflow called NAME, a symbol or string, or nil."
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

(defun rat-kingdom-workflow-describe (workflow)
  "Return a few lines of text describing WORKFLOW."
  (concat
   (format "%s: %s\n" (plist-get workflow :name)
           (or (plist-get workflow :doc) "no description"))
   (mapconcat
    (lambda (step)
      (format "  %s: at %s, %s%s; %s"
              (plist-get step :name) (plist-get step :from)
              (substring (symbol-name (plist-get step :kind)) 1)
              (if (eq (plist-get step :with) t)
                  ""
                (format " %s" (plist-get step :with)))
              (mapconcat (lambda (outcome)
                           (format "%s -> %s" (substring (symbol-name outcome) 1)
                                   (plist-get step outcome)))
                         (cdr (assq (plist-get step :kind)
                                    rat-kingdom-workflow-kinds))
                         ", ")))
    (plist-get workflow :steps) "\n")))

;;;; The workflows that come with rat-kingdom

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
