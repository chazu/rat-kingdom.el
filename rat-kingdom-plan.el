;;; rat-kingdom-plan.el --- The epic plan surface -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Chaz Straney

;; Author: Chaz Straney <chaz.straney@gmail.com>
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;;; Commentary:

;; The epic plan surface (DESIGN.md, section 14.1, surface 4): the king
;; proposes an epic with `epic_propose', and the user reviews it in an
;; a2ui surface, edits it, and approves it, sends it back with notes or
;; dismisses it.  The king is told what they decided.
;;
;; The surface shows the repository, the epic's title and description,
;; and its stories grouped into waves: wave 1 holds the stories that
;; depend on nothing, wave N those whose dependencies are all in earlier
;; waves.  Each story has an include box, its key, an editable title and
;; description, what it depends on, and pickers for its agent and its
;; workflow (which sets its review mode).  Below them are the options,
;; "start right away", "feature branch" and "max parallel", and the
;; buttons.
;;
;; Nothing is created until the user presses Approve.  Approve drops the
;; stories left out, refuses if a story kept depends on one left out,
;; checks the plan again with `rat-kingdom-epic-check', creates the epic
;; with `rat-kingdom-epic-create' and, if asked, starts it with
;; `rat-kingdom-epic-start', with a feature branch if that is ticked.  A
;; feature branch ticked without "start right away" is passed on to the
;; king, to use when it starts the epic.  Every button, and deleting the surface,
;; leaves the king a message saying what the user decided.
;;
;; a2ui is optional.  It is loaded only when a surface is shown, and
;; `epic_propose' says plainly when it cannot be.  Everything but
;; showing the surface and receiving its buttons works without it: the
;; surface is built here as A2UI JSON data, and a button's action
;; carries what the user entered as its context.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'rat-kingdom-space)
(require 'rat-kingdom-workflow)
(require 'rat-kingdom-task)
(require 'rat-kingdom-agent-shell)
(require 'rat-kingdom-story)
(require 'rat-kingdom-king)
(require 'rat-kingdom-epic)

(declare-function a2ui-session-create "a2ui-core")
(declare-function a2ui-session-surface "a2ui-core" (session surface-id))
(declare-function a2ui-apply-message "a2ui-core" (session message))
(declare-function a2ui-delete-surface "a2ui-core" (session surface-id))
(declare-function a2ui-vui-attach "a2ui-vui" (session))
(declare-function a2ui-show-surface "a2ui-vui" (session surface-id))
(defvar a2ui-vui-display-action)
(defvar a2ui-emacs-catalog-id)

(defconst rat-kingdom-plan--catalog-id
  "https://github.com/chazu/a2ui.el/catalogs/emacs/v0.1"
  "The id of a2ui's Emacs catalog, which the surface uses.")

(defvar rat-kingdom-plan--session nil
  "The a2ui session that holds the plan surfaces, or nil.")

(defvar rat-kingdom-plan--plans (make-hash-table :test #'equal)
  "The plans shown, by surface id.
Each is a property list: `:space', `:repo', `:title', `:description',
`:stories' (as `rat-kingdom-epic-check' returns them, in the order
given) and `:state', which is `open' until the user decides, and then
`approved', `sent-back', `dismissed', `failed' or `replaced'.")

(defvar rat-kingdom-plan--defer (lambda (function) (run-at-time 0 nil function))
  "How a button's handler is run: later, outside the button press.")

;;;; a2ui, loaded when needed

(defun rat-kingdom-plan-a2ui-p ()
  "Load a2ui if it can be, and return non-nil if it is loaded."
  (and (require 'a2ui nil t)
       (require 'a2ui-emacs nil t)
       (fboundp 'a2ui-show-surface)))

(defun rat-kingdom-plan--require-a2ui ()
  "Signal an error saying a2ui is missing, unless it can be loaded."
  (unless (rat-kingdom-plan-a2ui-p)
    (error "The epic plan surface needs a2ui (https://github.com/chazu/a2ui.el), \
which is not installed or cannot be loaded")))

(defun rat-kingdom-plan--catalog ()
  "Return the id of the catalog the surface uses."
  (if (boundp 'a2ui-emacs-catalog-id)
      a2ui-emacs-catalog-id
    rat-kingdom-plan--catalog-id))

(defun rat-kingdom-plan--a2ui-session ()
  "Return the a2ui session of the plan surfaces, making it if needed."
  (or rat-kingdom-plan--session
      (let ((session (a2ui-session-create
                      :name "rat-kingdom"
                      :catalogs '(basic emacs)
                      :send-action-fn (lambda (message _metadata)
                                        (rat-kingdom-plan--receive message))
                      :on-change-fn (lambda (surface-id)
                                      (rat-kingdom-plan--changed surface-id)))))
        (a2ui-vui-attach session)
        (setq rat-kingdom-plan--session session))))

(defun rat-kingdom-plan--live-p (surface-id)
  "Return non-nil if the surface SURFACE-ID is shown by a2ui."
  (and rat-kingdom-plan--session
       (a2ui-session-surface rat-kingdom-plan--session surface-id)))

(defun rat-kingdom-plan--send (message)
  "Apply MESSAGE, an A2UI message, to the plan surfaces' session."
  (a2ui-apply-message (rat-kingdom-plan--a2ui-session) message))

(defun rat-kingdom-plan--display-action ()
  "Return `a2ui-vui-display-action', kept off the selected window.
So the surface never takes the place of the buffer the user is in."
  (let ((action a2ui-vui-display-action))
    (cons (car action) (cons '(inhibit-same-window . t) (cdr action)))))

(defun rat-kingdom-plan--display (surface-id)
  "Show the surface SURFACE-ID the way a2ui shows surfaces.
It goes where `a2ui-vui-display-action' says, but never in the
selected window, and the selected window stays selected."
  (let ((a2ui-vui-display-action (rat-kingdom-plan--display-action)))
    (save-selected-window
      (a2ui-show-surface (rat-kingdom-plan--a2ui-session) surface-id))))

(defun rat-kingdom-plan--delete (surface-id)
  "Delete the surface SURFACE-ID, if it is shown."
  (when (rat-kingdom-plan--live-p surface-id)
    (a2ui-delete-surface rat-kingdom-plan--session surface-id)))

;;;; Building the surface, as data

(defun rat-kingdom-plan--obj (&rest pairs)
  "Return a JSON object, a hash table, of the alternating keys and values PAIRS."
  (let ((object (make-hash-table :test #'equal)))
    (while pairs
      (puthash (pop pairs) (pop pairs) object))
    object))

(defun rat-kingdom-plan--path (path)
  "Return a binding to the data model's PATH."
  (rat-kingdom-plan--obj "path" path))

(defun rat-kingdom-plan--component (id type &rest properties)
  "Return the component ID of TYPE with PROPERTIES, alternating names and values."
  (apply #'rat-kingdom-plan--obj "id" id "component" type properties))

(defun rat-kingdom-plan--bool (value)
  "Return VALUE as a JSON boolean."
  (if value t :false))

(defun rat-kingdom-plan--true-p (value)
  "Return non-nil if the JSON VALUE is true."
  (and value (not (eq value :false))
       (not (and (stringp value) (member value '("" "false"))))))

(defun rat-kingdom-plan-waves (stories)
  "Return STORIES grouped into waves, as a list of lists of stories.
STORIES are as `rat-kingdom-epic-check' returns them.  The first wave
holds the stories that depend on nothing, and each later one the
stories whose dependencies are all in earlier waves.  Within a wave the
stories keep the order they were given in."
  (let ((left (cl-sort (copy-sequence stories) #'<
                       :key (lambda (story) (plist-get story :index))))
        (placed nil)
        (waves nil))
    (while left
      (let ((wave (cl-remove-if-not
                   (lambda (story)
                     (cl-every (lambda (key) (member key placed))
                               (plist-get story :depends-on)))
                   left)))
        (unless wave
          (error "The stories' dependencies have a cycle"))
        (push wave waves)
        (setq placed (append placed (mapcar (lambda (story)
                                              (plist-get story :key))
                                            wave))
              left (cl-set-difference left wave))))
    (setq waves (nreverse waves))
    (mapcar (lambda (wave)
              (cl-sort wave #'< :key (lambda (story) (plist-get story :index))))
            waves)))

(defun rat-kingdom-plan--agent-options ()
  "Return the agent picker's options, the default first."
  (vconcat
   (list (rat-kingdom-plan--obj
          "label" (format "default (%s)" (rat-kingdom-agent-name nil))
          "value" ""))
   (mapcar (lambda (name) (rat-kingdom-plan--obj "label" name "value" name))
           (rat-kingdom-agent-names))))

(defun rat-kingdom-plan--workflow-options ()
  "Return the workflow picker's options, the repository's first."
  (vconcat
   (list (rat-kingdom-plan--obj "label" "the repository's" "value" ""))
   (mapcar (lambda (workflow)
             (let ((name (plist-get workflow :name)))
               (rat-kingdom-plan--obj "label" name "value" name)))
           (rat-kingdom-workflow-list))))

(defun rat-kingdom-plan--depends-text (story)
  "Return what STORY depends on, as text for the surface."
  (if-let* ((depends (plist-get story :depends-on)))
      (format "Depends on: %s" (string-join depends ", "))
    "Depends on nothing"))

(defun rat-kingdom-plan--header (repo title description)
  "Return the surface's header text, in Markdown, for REPO, TITLE and DESCRIPTION."
  (format "**Repository:** %s\n\n**Epic:** %s\n\n%s" repo title description))

(defun rat-kingdom-plan--story-components (index story)
  "Return the components for STORY, the INDEXth of the plan from 0.
The first is its card."
  (let* ((prefix (format "story-%d" index))
         (data (format "/stories/%d" index))
         (key (plist-get story :key)))
    (cl-flet ((id (name) (format "%s-%s" prefix name))
              (at (name) (rat-kingdom-plan--path (format "%s/%s" data name))))
      (list
       (rat-kingdom-plan--component (id "card") "Card" "child" (id "column"))
       (rat-kingdom-plan--component
        (id "column") "Column"
        "children" (vector (id "include") (id "title") (id "description")
                           (id "depends") (id "agent") (id "workflow")))
       (rat-kingdom-plan--component
        (id "include") "CheckBox"
        "label" (format "Include story %s" key) "value" (at "include"))
       (rat-kingdom-plan--component
        (id "title") "TextField" "label" (format "%s: title" key)
        "value" (at "title"))
       (rat-kingdom-plan--component
        (id "description") "TextField" "label" "Description"
        "variant" "longText" "value" (at "description"))
       (rat-kingdom-plan--component
        (id "depends") "Text" "text" (rat-kingdom-plan--depends-text story)
        "variant" "caption")
       (rat-kingdom-plan--component
        (id "agent") "Picker" "label" "Agent"
        "options" (rat-kingdom-plan--path "/agents") "value" (at "agent"))
       (rat-kingdom-plan--component
        (id "workflow") "Picker" "label" "Workflow"
        "options" (rat-kingdom-plan--path "/workflows")
        "value" (at "workflow"))))))

(defun rat-kingdom-plan--components (title stories)
  "Return the components of the surface for the epic TITLE and its STORIES.
STORIES are in the order of the data model's /stories."
  (let* ((waves (rat-kingdom-plan-waves stories))
         (index-of (lambda (story) (cl-position story stories :test #'eq)))
         (wave-ids (cl-loop for n from 1 to (length waves)
                            collect (format "wave-%d" n))))
    (append
     (list
      (rat-kingdom-plan--component
       "root" "Column"
       "children" (vconcat (list "heading" "header") wave-ids
                           (list "options" "buttons" "back" "result")))
      (rat-kingdom-plan--component "heading" "Text"
                                   "text" (format "Epic plan: %s" title)
                                   "variant" "h2")
      (rat-kingdom-plan--component "header" "Text"
                                   "text" (rat-kingdom-plan--path "/header")))
     (cl-loop
      for wave in waves
      for n from 1
      append
      (cons
       (rat-kingdom-plan--component
        (format "wave-%d" n) "Section"
        "title" (format "Wave %d: %s" n
                        (mapconcat (lambda (story) (plist-get story :key))
                                   wave ", "))
        "child" (format "wave-%d-stories" n))
       (cons
        (rat-kingdom-plan--component
         (format "wave-%d-stories" n) "Column"
         "children" (vconcat (mapcar (lambda (story)
                                       (format "story-%d-card"
                                               (funcall index-of story)))
                                     wave)))
        (mapcan (lambda (story)
                  (rat-kingdom-plan--story-components
                   (funcall index-of story) story))
                wave))))
     (list
      (rat-kingdom-plan--component "options" "Section" "title" "Options"
                                   "child" "options-column")
      (rat-kingdom-plan--component "options-column" "Column"
                                   "children" ["start" "feature-branch"
                                               "feature-branch-note"
                                               "max-parallel"])
      (rat-kingdom-plan--component
       "start" "CheckBox" "label" "Start right away"
       "value" (rat-kingdom-plan--path "/options/start"))
      (rat-kingdom-plan--component
       "feature-branch" "CheckBox"
       "label" "Feature branch: land the epic as one unit"
       "value" (rat-kingdom-plan--path "/options/featureBranch"))
      (rat-kingdom-plan--component
       "feature-branch-note" "Text" "variant" "caption"
       "text" "Applies when the epic is started: its stories merge into a \
branch of its own, which lands on the target after one check and the \
king's review of the whole. Without \"Start right away\", the king is \
told to use it when it starts the epic.")
      (rat-kingdom-plan--component
       "max-parallel" "TextField"
       "label" "Max parallel (empty for no limit)"
       "value" (rat-kingdom-plan--path "/options/maxParallel")
       "validationRegexp" "^ *[0-9]* *$")
      (rat-kingdom-plan--component
       "buttons" "Row" "children" ["approve" "cancel"]
       "visible" (rat-kingdom-plan--path "/open"))
      (rat-kingdom-plan--component
       "approve" "Button" "child" "approve-label" "variant" "primary"
       "action" (rat-kingdom-plan--obj
                 "event" (rat-kingdom-plan--obj
                          "name" "approve"
                          "context" (rat-kingdom-plan--obj
                                     "stories" (rat-kingdom-plan--path "/stories")
                                     "options" (rat-kingdom-plan--path "/options")))))
      (rat-kingdom-plan--component "approve-label" "Text"
                                   "text" "Approve and create")
      (rat-kingdom-plan--component
       "cancel" "Button" "child" "cancel-label"
       "action" (rat-kingdom-plan--obj
                 "event" (rat-kingdom-plan--obj "name" "cancel")))
      (rat-kingdom-plan--component "cancel-label" "Text" "text" "Cancel")
      (rat-kingdom-plan--component
       "back" "Section" "title" "Send back to the king" "child" "back-column"
       "visible" (rat-kingdom-plan--path "/open"))
      (rat-kingdom-plan--component "back-column" "Column"
                                   "children" ["notes" "send-back"])
      (rat-kingdom-plan--component
       "notes" "TextField" "label" "Notes" "variant" "longText"
       "value" (rat-kingdom-plan--path "/notes"))
      (rat-kingdom-plan--component
       "send-back" "Button" "child" "send-back-label"
       "checks" (vector
                 (rat-kingdom-plan--obj
                  "condition" (rat-kingdom-plan--obj
                               "call" "required"
                               "args" (rat-kingdom-plan--obj
                                       "value" (rat-kingdom-plan--path "/notes")))
                  "message" "Say what to change."))
       "action" (rat-kingdom-plan--obj
                 "event" (rat-kingdom-plan--obj
                          "name" "send_back"
                          "context" (rat-kingdom-plan--obj
                                     "notes" (rat-kingdom-plan--path "/notes")))))
      (rat-kingdom-plan--component "send-back-label" "Text"
                                   "text" "Send back with notes")
      (rat-kingdom-plan--component
       "result" "Text" "text" (rat-kingdom-plan--path "/result")
       "tone" (rat-kingdom-plan--path "/resultTone"))))))

(defun rat-kingdom-plan--data (repo title description stories)
  "Return the surface's data model for the epic TITLE of REPO.
DESCRIPTION is the epic's, and STORIES its checked stories."
  (rat-kingdom-plan--obj
   "header" (rat-kingdom-plan--header repo title description)
   "agents" (rat-kingdom-plan--agent-options)
   "workflows" (rat-kingdom-plan--workflow-options)
   "stories" (vconcat
              (mapcar (lambda (story)
                        (rat-kingdom-plan--obj
                         "key" (plist-get story :key)
                         "include" t
                         "title" (plist-get story :title)
                         "description" (plist-get story :description)
                         "agent" (or (plist-get story :agent) "")
                         "workflow" (or (plist-get story :workflow) "")))
                      stories))
   "options" (rat-kingdom-plan--obj "start" :false "featureBranch" :false
                                    "maxParallel" "")
   "notes" ""
   "open" t
   "result" ""
   "resultTone" "muted"))

(defun rat-kingdom-plan-surface (surface-id repo title description stories)
  "Return the A2UI messages that draw the surface SURFACE-ID.
It shows the epic TITLE of REPO, with DESCRIPTION, and its STORIES, as
`rat-kingdom-epic-check' returns them, in the order they were given.
The messages are hash tables, as a2ui takes them: createSurface,
updateComponents and updateDataModel."
  (cl-flet ((message (type &rest pairs)
              (rat-kingdom-plan--obj
               "version" "v0.9"
               type (apply #'rat-kingdom-plan--obj "surfaceId" surface-id
                           pairs))))
    (list
     (message "createSurface" "catalogId" (rat-kingdom-plan--catalog)
              "theme" (rat-kingdom-plan--obj "agentDisplayName" "rat-kingdom"))
     (message "updateComponents"
              "components" (vconcat (rat-kingdom-plan--components title
                                                                  stories)))
     (message "updateDataModel" "path" "/"
              "value" (rat-kingdom-plan--data repo title description
                                              stories)))))

(defun rat-kingdom-plan--set (surface-id path value)
  "Set PATH of the data of the surface SURFACE-ID to VALUE, if it is shown."
  (when (rat-kingdom-plan--live-p surface-id)
    (rat-kingdom-plan--send
     (rat-kingdom-plan--obj
      "version" "v0.9"
      "updateDataModel" (rat-kingdom-plan--obj "surfaceId" surface-id
                                               "path" path "value" value)))))

(defun rat-kingdom-plan--show-result (surface-id text tone &optional closed)
  "Show TEXT on the surface SURFACE-ID, in TONE.
If CLOSED, hide its buttons, since the plan is decided."
  (rat-kingdom-plan--set surface-id "/result" text)
  (rat-kingdom-plan--set surface-id "/resultTone" tone)
  (when closed
    (rat-kingdom-plan--set surface-id "/open" :false)))

;;;; Showing a plan

(defun rat-kingdom-plan--surface-id (title)
  "Return the id of the surface for the epic TITLE."
  (format "Epic plan: %s" (replace-regexp-in-string "[\n\t ]+" " "
                                                    (string-trim title))))

(defun rat-kingdom-plan-check (space repo title description stories)
  "Check the epic TITLE of REPO in SPACE, as `epic_create' would.
DESCRIPTION and STORIES are as `rat-kingdom-epic-create' takes them.
Return the checked stories, in the order they were given, or signal an
error saying what is wrong; nothing is created."
  (unless (rat-kingdom-repo-get space repo)
    (error "No repository called %s is registered" repo))
  (unless (rat-kingdom-task-adapter space repo)
    (error "The repository %s has no task tracker" repo))
  (when (rat-kingdom-epic--blank-p title)
    (error "Nothing was created: the epic's title is blank"))
  (when (rat-kingdom-epic--blank-p description)
    (error "Nothing was created: the epic's description is blank"))
  (cl-sort (copy-sequence (rat-kingdom-epic-check stories)) #'<
           :key (lambda (story) (plist-get story :index))))

(defun rat-kingdom-plan-show (space repo title description stories)
  "Show the user the epic TITLE of REPO in SPACE, for review, in a2ui.
DESCRIPTION and STORIES are as `rat-kingdom-epic-create' takes them.
The plan is checked first, and an error is signalled if it has a
problem or a2ui cannot be loaded.  Nothing is created until the user
approves it.  A surface for an epic of the same title is replaced.
Return the surface's id."
  (let ((checked (rat-kingdom-plan-check space repo title description
                                         stories)))
    (rat-kingdom-plan--require-a2ui)
    (let ((surface-id (rat-kingdom-plan--surface-id title)))
      (when-let* ((old (gethash surface-id rat-kingdom-plan--plans)))
        (plist-put old :state 'replaced))
      (rat-kingdom-plan--delete surface-id)
      (puthash surface-id
               (list :space space :repo repo :title title
                     :description description :stories checked :state 'open)
               rat-kingdom-plan--plans)
      (dolist (message (rat-kingdom-plan-surface surface-id repo title
                                                 description checked))
        (rat-kingdom-plan--send message))
      (rat-kingdom-plan--display surface-id)
      surface-id)))

;;;; What the user decides

(defun rat-kingdom-plan--tell (plan text)
  "Leave the king a message about PLAN saying TEXT."
  (rat-kingdom-space-out (plist-get plan :space) 'message
                         :scope (plist-get plan :repo)
                         :payload (list :to rat-kingdom-king-id :text text)
                         :actor "user"))

(defun rat-kingdom-plan--get (object name)
  "Return the field NAME of OBJECT, a JSON object as a hash table or alist."
  (cond ((hash-table-p object) (gethash name object))
        ((listp object) (alist-get (intern name) object))))

(defun rat-kingdom-plan--text (value)
  "Return VALUE, a field's value, as a trimmed string, or nil if blank."
  (let ((text (cond ((stringp value) value)
                    ((numberp value) (number-to-string value))
                    (t nil))))
    (and text (not (string-blank-p text)) (string-trim text))))

(defun rat-kingdom-plan--edited (plan entries)
  "Return PLAN's stories with the user's edits in ENTRIES applied.
ENTRIES are the surface's /stories, a vector or list of objects with
`key', `include', `title', `description', `agent' and `workflow'.
Return (KEPT . DROPPED): the stories kept, as alists that
`rat-kingdom-epic-check' takes, and the keys of those left out.  A
story the entries do not mention is kept as it was."
  (let (kept dropped)
    (dolist (story (plist-get plan :stories))
      (let* ((key (plist-get story :key))
             (entry (cl-find key (append entries nil)
                             :key (lambda (entry)
                                    (rat-kingdom-plan--get entry "key"))
                             :test #'equal)))
        (cl-flet ((edited (name property)
                    (if entry
                        (rat-kingdom-plan--text
                         (rat-kingdom-plan--get entry name))
                      (plist-get story property))))
          (if (and entry
                   (not (rat-kingdom-plan--true-p
                         (rat-kingdom-plan--get entry "include"))))
              (push key dropped)
            (push `((key . ,key)
                    (title . ,(edited "title" :title))
                    (description . ,(edited "description" :description))
                    (depends_on . ,(plist-get story :depends-on))
                    (agent . ,(edited "agent" :agent))
                    (workflow . ,(edited "workflow" :workflow))
                    (priority . ,(plist-get story :priority)))
                  kept)))))
    (cons (nreverse kept) (nreverse dropped))))

(defun rat-kingdom-plan--max-parallel (value)
  "Return VALUE, the max parallel field, as a number, or nil if blank.
Signal an error unless it is blank or a whole number of at least 1."
  (let ((text (rat-kingdom-plan--text value)))
    (cond ((null text) nil)
          ((and (integerp value) (> value 0)) value)
          ((and (floatp value) (> value 0) (= value (ftruncate value)))
           (truncate value))
          ((and (string-match-p "\\`[0-9]+\\'" text)
                (> (string-to-number text) 0))
           (string-to-number text))
          (t (error "Max parallel must be a whole number of at least 1, or \
empty for no limit, not %s" text)))))

(defun rat-kingdom-plan--approve-problems (kept dropped)
  "Return what stops the stories KEPT from being created without DROPPED.
KEPT are alists as `rat-kingdom-plan--edited' returns them, and DROPPED
the keys of the stories left out."
  (append
   (unless kept
     (list "every story is left out; include at least one, or press Cancel"))
   (cl-loop for story in kept
            for missing = (cl-intersection (alist-get 'depends_on story)
                                           dropped :test #'equal)
            when missing
            collect (format "story %s depends on %s, which %s left out; \
include %s or leave out %s too"
                            (alist-get 'key story)
                            (string-join missing ", ")
                            (if (cdr missing) "are" "is")
                            (if (cdr missing) "them" "it")
                            (alist-get 'key story)))))

(defun rat-kingdom-plan--refuse (surface-id problems)
  "Show PROBLEMS on the surface SURFACE-ID: nothing was created.
PROBLEMS is a list of them, or a message that says nothing was created."
  (rat-kingdom-plan--show-result
   surface-id
   (if (stringp problems)
       (concat problems "\n\nFix this and approve again.")
     (concat "Nothing was created. Fix this and approve again:\n\n- "
             (string-join problems "\n- ")))
   "error"))

(defun rat-kingdom-plan--created-text (result)
  "Return the stories RESULT of `rat-kingdom-epic-create' made, as text."
  (mapconcat (lambda (story)
               (format "%s (%s)" (plist-get story :id) (plist-get story :key)))
             (plist-get result :stories) ", "))

(defun rat-kingdom-plan-approve (surface-id context)
  "Do what Approve on the surface SURFACE-ID asks, with CONTEXT.
CONTEXT is the action's context: `stories', the surface's /stories,
and `options', its /options with `start', `featureBranch' and
`maxParallel'.  Apply the edits, check the plan, create the epic and,
if asked, start it, with a feature branch if that is ticked too.  A
feature branch ticked without start is only passed on to the king, to
use when it starts the epic.  If the plan has a problem, show it and
create nothing.  Return the epic's id, or nil if nothing was created."
  (let* ((plan (gethash surface-id rat-kingdom-plan--plans))
         (space (plist-get plan :space))
         (repo (plist-get plan :repo))
         (title (plist-get plan :title))
         (options (rat-kingdom-plan--get context "options"))
         (start (rat-kingdom-plan--true-p
                 (rat-kingdom-plan--get options "start")))
         (feature-branch (rat-kingdom-plan--true-p
                          (rat-kingdom-plan--get options "featureBranch")))
         (edited (rat-kingdom-plan--edited
                  plan (rat-kingdom-plan--get context "stories")))
         (kept (car edited))
         (problems (rat-kingdom-plan--approve-problems kept (cdr edited)))
         (max-parallel
          (condition-case err
              (rat-kingdom-plan--max-parallel
               (rat-kingdom-plan--get options "maxParallel"))
            (error (push (error-message-string err) problems) nil))))
    (unless problems
      (condition-case err
          (rat-kingdom-epic-check kept)
        (error (setq problems (error-message-string err)))))
    (if problems
        (progn (rat-kingdom-plan--refuse surface-id problems) nil)
      (let ((result
             (condition-case err
                 (rat-kingdom-epic-create space repo title
                                          (plist-get plan :description) kept)
               (error
                (let ((text (rat-kingdom-epic--message err)))
                  (if (string-prefix-p "Nothing was created" text)
                      (rat-kingdom-plan--refuse surface-id text)
                    ;; The tracker failed partway: what was made stays,
                    ;; so the plan cannot simply be approved again.
                    (plist-put plan :state 'failed)
                    (rat-kingdom-plan--show-result
                     surface-id (format "**Creating the epic failed.** %s"
                                        text)
                     "error" t)
                    (rat-kingdom-plan--tell
                     plan (format "The user approved the epic plan %s in the \
plan surface, but creating it failed: %s" title text))))
                nil))))
        (when result
          (let* ((epic (plist-get result :epic))
                 (count (length (plist-get result :stories)))
                 (branch (rat-kingdom-epic-branch-name epic))
                 (started nil)
                 (start-error nil))
            (plist-put plan :state 'approved)
            (when start
              (condition-case err
                  (progn
                    (setq started (rat-kingdom-epic-start
                                   space repo epic max-parallel
                                   feature-branch))
                    (rat-kingdom-epic--run-reactions space))
                (error (setq start-error (rat-kingdom-epic--message err)))))
            (rat-kingdom-plan--show-result
             surface-id
             (concat
              (format "**Created the epic %s** in %s with %d tasks: %s."
                      epic repo count (rat-kingdom-plan--created-text result))
              (cond (start-error
                     (format "\n\nStarting it failed: %s" start-error))
                    (start
                     (format "\n\nStarted%s%s; %s."
                             (if feature-branch
                                 (format " on its feature branch %s, which \
lands on the target after one check and the king's review" branch)
                               "")
                             (if max-parallel
                                 (format ", at most %d at once" max-parallel)
                               "")
                             (if started
                                 (concat "stories started now: "
                                         (mapconcat
                                          (lambda (entry)
                                            (format "%s for %s"
                                                    (cdr entry) (car entry)))
                                          started ", "))
                               "no story could start yet")))
                    (feature-branch "\n\nNot started: ask the king to run \
it when you want; it is told to give it a feature branch.")
                    (t "\n\nNot started: ask the king to run it when you \
want.")))
             (if start-error "warning" "success")
             t)
            (rat-kingdom-plan--tell
             plan
             (concat
              (format "The user approved the epic plan %s in the plan \
surface: created epic %s with %d tasks; started: %s."
                      title epic count
                      (if start-error
                          "no, it failed"
                        (if start "yes" "no")))
              "\nTasks: " (rat-kingdom-plan--created-text result) "."
              (if (cdr edited)
                  (format "\nLeft out by the user: %s."
                          (string-join (cdr edited) ", "))
                "")
              (cond
               (start-error
                (format "\nStarting it failed: %s\nAsk the user before you \
call epic_start.%s" start-error
                        (if feature-branch
                            "\nThe user asked for a feature branch: pass \
feature_branch to epic_start when you start it."
                          "")))
               (start
                (format "\nThe user started it from the plan surface%s, so \
do not ask again; the engine starts its stories as their tasks become \
ready.%s%s"
                        (if max-parallel
                            (format ", with at most %d stories at once"
                                    max-parallel)
                          "")
                        (if feature-branch
                            (format " It has a feature branch, %s: its \
stories merge into it, and it lands on the target after one check and \
your epic_verdict." branch)
                          " It has no feature branch: each story merges \
into the target as it passes.")
                        (if started
                            (format " Started now: %s."
                                    (mapconcat (lambda (entry)
                                                 (format "%s for %s"
                                                         (cdr entry)
                                                         (car entry)))
                                               started ", "))
                          "")))
               (feature-branch "\nIt has not been started. Ask the user \
before you call epic_start. The user wants a feature branch: pass \
feature_branch to epic_start when you start it.")
               (t "\nIt has not been started. Ask the user before you call \
epic_start."))))
            epic))))))

(defun rat-kingdom-plan-send-back (surface-id notes)
  "Send the plan of the surface SURFACE-ID back to the king with NOTES."
  (let ((plan (gethash surface-id rat-kingdom-plan--plans))
        (notes (rat-kingdom-plan--text notes)))
    (plist-put plan :state 'sent-back)
    (rat-kingdom-plan--show-result
     surface-id "Sent back to the king with your notes. Nothing was created."
     "muted" t)
    (rat-kingdom-plan--tell
     plan (format "The user sent the epic plan %s back with notes: %s\n\
Nothing was created. Revise the plan and propose it again with \
epic_propose."
                  (plist-get plan :title) (or notes "(none)")))))

(defun rat-kingdom-plan-dismiss (surface-id)
  "Dismiss the plan of the surface SURFACE-ID, close it and tell the king."
  (let ((plan (gethash surface-id rat-kingdom-plan--plans)))
    (plist-put plan :state 'dismissed)
    (rat-kingdom-plan--delete surface-id)
    (rat-kingdom-plan--tell
     plan (format "The user dismissed the epic plan %s in the plan surface. \
Nothing was created."
                  (plist-get plan :title)))))

(defun rat-kingdom-plan-handle (surface-id name context)
  "Handle the button NAME pressed on the surface SURFACE-ID, with CONTEXT.
A plan the user has already decided ignores it."
  (let ((plan (gethash surface-id rat-kingdom-plan--plans)))
    (when (eq (plist-get plan :state) 'open)
      (pcase name
        ("approve" (rat-kingdom-plan-approve surface-id context))
        ("send_back" (rat-kingdom-plan-send-back
                      surface-id (rat-kingdom-plan--get context "notes")))
        ("cancel" (rat-kingdom-plan-dismiss surface-id))))))

(defun rat-kingdom-plan--receive (message)
  "Act on MESSAGE, which a plan surface sent."
  (cond
   ((gethash "action" message)
    (let* ((action (gethash "action" message))
           (surface-id (gethash "surfaceId" action))
           (name (gethash "name" action))
           (context (gethash "context" action)))
      (funcall rat-kingdom-plan--defer
               (lambda ()
                 (condition-case err
                     (rat-kingdom-plan-handle surface-id name context)
                   (error
                    (rat-kingdom-plan--show-result
                     surface-id (format "**Error:** %s"
                                        (error-message-string err))
                     "error")
                    (message "rat-kingdom: the plan surface %s: %s"
                             surface-id (error-message-string err))))))))
   ((gethash "error" message)
    (let ((err (gethash "error" message)))
      (message "rat-kingdom: the plan surface %s reports %s: %s"
               (gethash "surfaceId" err) (gethash "code" err)
               (gethash "message" err))))))

(defun rat-kingdom-plan--changed (surface-id)
  "Note that the surface SURFACE-ID changed.
If the user deleted it before deciding, the plan is dismissed."
  (let ((plan (gethash surface-id rat-kingdom-plan--plans)))
    (when (and plan (eq (plist-get plan :state) 'open)
               (not (rat-kingdom-plan--live-p surface-id)))
      (rat-kingdom-plan-dismiss surface-id))))

;;;; The king's tool

(rat-kingdom-king--deftool "epic_propose"
    "Show the user a proposed epic in Emacs, in the epic plan surface, where \
they can edit each story's title, description, agent and workflow, leave \
stories out, and then approve it (which creates the epic, and starts it if \
they ask), send it back to you with notes, or dismiss it. You are told what \
they decided. Prefer it to epic_create for planning an epic. The plan is \
checked first, as epic_create checks it, and nothing is created until the \
user approves. Do not call epic_create for this plan yourself."
    '((:name "repo" :type string :description "The repository's name.")
      (:name "title" :type string :description "The epic's name, in one line.")
      (:name "description" :type string
       :description "The epic's goal, and how it will be judged as a whole.")
      (:name "stories" :type array
       :description "The stories, in order. Each becomes a task of the \
epic once the user approves."
       :items
       (:type object
        :properties
        ((:name "key" :type string
          :description "A name for the story, local to this call, such as \
a or parser, for depends_on to refer to.")
         (:name "title" :type string :description "What to do, in one line.")
         (:name "description" :type string
          :description "Everything a worker needs: what to change, where, \
constraints, and how the result will be judged. The worker knows nothing \
else.")
         (:name "depends_on" :type array :optional t
          :items (:type string)
          :description "Keys of stories in this list that must be merged \
before this one starts.")
         (:name "agent" :type string :optional t
          :description "claude or codex. Default the user's setting.")
         (:name "workflow" :type string :optional t
          :description "The workflow its story follows. Default the \
repository's.")
         (:name "priority" :type integer :optional t
          :description "0 (most urgent) to 4.")))))
  (let ((stories (rat-kingdom-plan-check space (arg 'repo) (arg 'title)
                                         (arg 'description) (arg 'stories))))
    (unless (rat-kingdom-plan-a2ui-p)
      (error "The epic plan surface is not available: a2ui is not installed \
or cannot be loaded in the user's Emacs.  Nothing was shown or created.  \
Agree the plan with the user in conversation instead, and create it with \
epic_create once they agree"))
    (let ((surface-id (rat-kingdom-plan-show space (arg 'repo) (arg 'title)
                                             (arg 'description)
                                             (arg 'stories))))
      (format "Shown to the user in the plan surface \"%s\", with %d stories \
in %d waves; you'll be told what they decide. Do not call epic_create for \
this plan yourself."
              surface-id (length stories)
              (length (rat-kingdom-plan-waves stories))))))

(provide 'rat-kingdom-plan)
;;; rat-kingdom-plan.el ends here
