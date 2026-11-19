;;; rat-kingdom-board.el --- The story board surface -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Chaz Straney

;; Author: Chaz Straney <chaz.straney@gmail.com>
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;;; Commentary:

;; The story board (DESIGN.md, section 14.1): a Kanban board of the
;; stories in the pipeline, drawn by the engine in an a2ui surface, the
;; "Story board", and kept up to date as the stories move.  No model is
;; involved.  `rat-kingdom-board' opens it, and the king's `board_show'
;; opens it for the user.  It is shown in the main window: the selected
;; window of the selected frame takes it in place of its buffer, unless
;; that is a side window or a dedicated one, in which case a2ui's main
;; window does.  \\`q' buries it, and \\`g' draws it again from the space.
;;
;; The columns are phases of the pipeline, the same for every workflow:
;; Queued, Working, Checking, Review, Merging, Done and Stopped.
;; `rat-kingdom-board-phase' puts a story in one from its token and its
;; workflow, and `rat-kingdom-board-phases' says which column each kind
;; of step, or a place or step by name, belongs in.  Done holds the
;; stories that ended in the last `rat-kingdom-board-done-hours', and
;; Stopped those that are parked, or were cancelled in that time.  A
;; child story is not shown; its parent is.
;;
;; A card holds the story's id, the display name of its worker, its
;; repository, epic, title, agent and how long it has been where it is,
;; in a tone when it wants attention: waiting for review, stopped, stuck
;; or running long.  Its buttons open the worker's buffer, show the
;; story as `story_show' does, show its diff as `story_diff' does, and
;; cancel it, after asking.  Verdicts stay the king's: there is no
;; button for one.  A picker limits the board to one repository, and a
;; check box hides Done and Stopped.  `rat-kingdom-board' with a prefix
;; argument, and `board_show' with its `repo', open the board with the
;; picker set to one repository; `rat-kingdom-board-open' says how.
;; Opened without one, an open board keeps its repository, and a board
;; that is not open shows all of them.
;;
;; The board follows `rat-kingdom-space-change-functions'.  A change to
;; a story, its run or its stuck report marks the story; at most every
;; `rat-kingdom-board-interval' seconds the marked stories' cards are
;; made again, and only those that changed are sent, as updateDataModel
;; messages for their paths.  Ages are refreshed every
;; `rat-kingdom-board-tick' seconds the same way.  Nothing reads git.
;; Opening the board builds it from the space, so it is right after
;; Emacs restarts.
;;
;; The layout depends on the width of the window the board is shown
;; in, not the selected window, and it is laid out again when that
;; window changes its width.  The columns shown share the width, each
;; at most `rat-kingdom-board-column-width' characters wide.  When each
;; has at least `rat-kingdom-board-min-column-width', they stand side by
;; side, a Row of Columns, and every line of a card is cut to its
;; column; otherwise each phase is a Section, one above the other,
;; titled with its count.  With `rat-kingdom-board-hide-empty-columns',
;; a column with no cards is left out, which gives the others more
;; room, and a line under the filters names it with its count of 0.
;;
;; a2ui is optional, as for the epic plan (rat-kingdom-plan.el): it is
;; loaded when the board is first shown, and the board says plainly
;; when it cannot be.  Everything else here works without it.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'rat-kingdom-space)
(require 'rat-kingdom-workflow)
(require 'rat-kingdom-git)
(require 'rat-kingdom-run)
(require 'rat-kingdom-story)
(require 'rat-kingdom-king)
(require 'rat-kingdom-plan)

(declare-function a2ui-session-create "a2ui-core")
(declare-function a2ui-session-surface "a2ui-core" (session surface-id))
(declare-function a2ui-apply-message "a2ui-core" (session message))
(declare-function a2ui-vui-attach "a2ui-vui" (session))
(declare-function a2ui-show-surface "a2ui-vui" (session surface-id))
(declare-function a2ui-vui-display-in-main-window "a2ui-vui" (buffer alist))
(declare-function a2ui-surface-refresh "a2ui-vui" (&rest _))
(defvar a2ui-vui-display-action)
(defvar a2ui-vui-width)

(defconst rat-kingdom-board-surface-id "Story board"
  "The id of the story board's surface.")

(defconst rat-kingdom-board-columns
  '((queued . "Queued") (working . "Working") (checking . "Checking")
    (review . "Review") (merging . "Merging") (done . "Done")
    (stopped . "Stopped"))
  "The board's columns, in order, each with its title.")

(defconst rat-kingdom-board--ended '(done stopped)
  "The columns the check box \"Show Done and Stopped\" hides.")

(defconst rat-kingdom-board--buttons-width 34
  "Characters a card's buttons take on one line.
That is \"[Worker]  [Show]  [Diff]  [Cancel]\"; two to a line, they
take 16.")

(defcustom rat-kingdom-board-phases
  '((:spawn . working) (:check . checking) (:run . checking)
    (:review . review) (:gate . review) (:merge . merging)
    (:workflow . working))
  "Which column of the story board a story is in, by what it is doing.
Each entry maps a key to a column: `queued', `working', `checking',
`review', `merging', `done' or `stopped'.  A key is a kind of step, a
keyword such as `:spawn', or a string, the name of a place or of a
step, which comes before the kind.  A place is looked up first, then
the step, then the step's kind.

Whatever this says, a story waiting for a free worker is queued, one
at a spawn step whose worker has not started yet is queued unless its
place or step is named here, one at a final place or that ended is
done, and one parked, at its workflow's failure place, or cancelled is
stopped.  A step of a kind not listed is `working'.

The default puts the steps of the built-in workflows where their names
say: implement and research in Working, check in Checking, review in
Review and integrate in Merging.  A gate waits for a person or a time,
so it is in Review; a child workflow is the parent's work, so it is in
Working."
  :type '(alist :key-type (choice (const :tag "Spawn step" :spawn)
                                  (const :tag "Check step" :check)
                                  (const :tag "Run step" :run)
                                  (const :tag "Review step" :review)
                                  (const :tag "Gate step" :gate)
                                  (const :tag "Merge step" :merge)
                                  (const :tag "Child workflow step" :workflow)
                                  (string :tag "Place or step name"))
                :value-type (choice (const queued) (const working)
                                    (const checking) (const review)
                                    (const merging) (const done)
                                    (const stopped)))
  :group 'rat-kingdom)

(defcustom rat-kingdom-board-done-hours 24
  "How many hours a story that ended stays on the story board.
Those merged or finished are in Done, those cancelled in Stopped."
  :type 'number
  :group 'rat-kingdom)

(defcustom rat-kingdom-board-long-minutes 60
  "Minutes after which a queued, working, checking or merging story is long.
Its card then takes the warning tone."
  :type 'number
  :group 'rat-kingdom)

(defcustom rat-kingdom-board-interval 0.5
  "The fewest seconds between two updates of the story board."
  :type 'number
  :group 'rat-kingdom)

(defcustom rat-kingdom-board-tick 60
  "Seconds between refreshes of the ages on the story board."
  :type 'number
  :group 'rat-kingdom)

(defcustom rat-kingdom-board-column-width 32
  "Most characters a column of the story board has.
The columns shown share the width of the board's window, but none is
wider than this, so that a wide window does not stretch the cards."
  :type 'natnum
  :group 'rat-kingdom)

(defcustom rat-kingdom-board-min-column-width 18
  "Fewest characters a column of the story board needs to stand in a row.
The columns shown share the width of the board's window, and when
each has at least this, they stand side by side; when each has fewer,
each column is a section, one above the other.  Below 18 the
card buttons are wider than a column."
  :type 'natnum
  :group 'rat-kingdom)

(defcustom rat-kingdom-board-hide-empty-columns t
  "Non-nil means the story board leaves out the columns with no cards.
The other columns then have more room.  A line names the columns left
out, each with its count of 0, so that every phase is still seen."
  :type 'boolean
  :group 'rat-kingdom)

(defcustom rat-kingdom-board-title-width 60
  "Most characters of a story's title a card shows."
  :type 'natnum
  :group 'rat-kingdom)

(defvar rat-kingdom-board--session nil
  "The a2ui session that holds the story board, or nil.")

(defvar rat-kingdom-board--space nil
  "The space the story board shows, or nil while it is not shown.")

(defvar rat-kingdom-board--cards (make-hash-table :test #'equal)
  "The cards on the board, by story id.
Each is (COLUMN . CARD), as `rat-kingdom-board-card' returns it.")

(defvar rat-kingdom-board--filter (list :repo nil :ended t)
  "What the board shows, as a property list.
`:repo' is a repository's name, or nil for all, and `:ended' is
non-nil to show the columns Done and Stopped.")

(defvar rat-kingdom-board--layout 'stacked
  "How the board is laid out: `row' or `stacked'.")

(defvar rat-kingdom-board--column-width rat-kingdom-board-column-width
  "Characters each column of the board has in the layout `row'.")

(defvar rat-kingdom-board--shown nil
  "The columns the board shows, in order.")

(defvar rat-kingdom-board--width nil
  "The width of the window the board is laid out for, or nil.")

(defvar rat-kingdom-board--buffer nil
  "The buffer a2ui shows the board in, or nil.")

(defvar rat-kingdom-board--relayout-timer nil
  "The timer of the next layout of the board for its window, or nil.")

(defvar rat-kingdom-board--dirty nil
  "The ids of the stories whose cards are to be made again.")

(defvar rat-kingdom-board--timer nil
  "The timer of the next update of the board, or nil.")

(defvar rat-kingdom-board--last 0
  "When the board was last updated, as `float-time' gives it.")

(defvar rat-kingdom-board--tick-timer nil
  "The timer that refreshes the ages on the board, or nil.")

(defvar rat-kingdom-board--defer (lambda (function) (run-at-time 0 nil function))
  "How a button's handler is run: later, outside the button press.")

(defvar rat-kingdom-board--now #'float-time
  "Function returning the time, for the board's throttle.  Tests replace it.")

(defvar rat-kingdom-board-actions
  '(("open" . rat-kingdom-board-open-worker)
    ("show" . rat-kingdom-board-show-story)
    ("diff" . rat-kingdom-board-show-diff)
    ("cancel" . rat-kingdom-board-cancel))
  "The card buttons' actions, each with the function it calls.
Each function is called with the space and the story's id.")

;;;; Columns

(defun rat-kingdom-board--configured (key)
  "Return the column `rat-kingdom-board-phases' gives KEY, or nil."
  (and key (cdr (assoc key rat-kingdom-board-phases))))

(defun rat-kingdom-board-phase (workflow payload)
  "Return the column of a story whose token has PAYLOAD, in WORKFLOW.
WORKFLOW is normalized, or nil if the story's is not defined.  See
`rat-kingdom-board-phases'."
  (let ((phase (plist-get payload :phase))
        (at (plist-get payload :at)))
    (cond
     ((equal phase "done") 'done)
     ((member phase '("cancelled" "parked")) 'stopped)
     ((null workflow) 'stopped)
     ((rat-kingdom-workflow-final-p workflow at) 'done)
     ((equal at (plist-get workflow :failure)) 'stopped)
     (t
      (let ((step (if (equal phase "wait")
                      (rat-kingdom-workflow-step-named workflow
                                                       (plist-get payload :step))
                    (rat-kingdom-workflow-step workflow at))))
        (cond
         ((null step) 'stopped)
         ((equal (plist-get payload :awaiting) rat-kingdom-story-free-worker)
          'queued)
         ((rat-kingdom-board--configured at))
         ((rat-kingdom-board--configured (plist-get step :name)))
         ((and (eq (plist-get step :kind) :spawn) (not (equal phase "wait")))
          'queued)
         ((rat-kingdom-board--configured (plist-get step :kind)))
         (t 'working)))))))

(defun rat-kingdom-board--workflow (space story)
  "Return the workflow of the token STORY in SPACE, or nil."
  (or (ignore-errors (rat-kingdom-story--workflow space story))
      (rat-kingdom-workflow-get
       (plist-get (plist-get story :payload) :workflow))))

;;;; Cards

(defun rat-kingdom-board-rat-name (space run-id)
  "Return the name to show for the worker RUN-ID in SPACE, or nil.
A run with a `:name' is shown by `rat-kingdom-run-display-name', such
as Pip-3a9c; one without, by its id."
  (when (and run-id (not (equal run-id "")))
    (or (rat-kingdom-run-display-name
         (or (rat-kingdom-run-get space run-id) (list :id run-id)))
        run-id)))

(defun rat-kingdom-board-age-text (seconds)
  "Return SECONDS as a short age, such as 45s, 12m, 3h 5m or 2d."
  (let ((seconds (max 0 (truncate seconds))))
    (cond ((< seconds 60) (format "%ds" seconds))
          ((< seconds 3600) (format "%dm" (/ seconds 60)))
          ((< seconds 86400)
           (let ((minutes (% (/ seconds 60) 60)))
             (if (zerop minutes)
                 (format "%dh" (/ seconds 3600))
               (format "%dh %dm" (/ seconds 3600) minutes))))
          (t (format "%dd" (/ seconds 86400))))))

(defun rat-kingdom-board--text-width ()
  "Return the most characters a line of a card may have.
That is `rat-kingdom-board-title-width', and in the layout `row' no
more than a column has, less the two spaces between columns."
  (if (eq rat-kingdom-board--layout 'row)
      (min rat-kingdom-board-title-width
           (max 10 (- rat-kingdom-board--column-width 2)))
    rat-kingdom-board-title-width))

(defun rat-kingdom-board--truncate (text &optional width)
  "Return TEXT on one line, no longer than WIDTH.
WIDTH is by default `rat-kingdom-board-title-width'."
  (truncate-string-to-width
   (replace-regexp-in-string "[\n\t ]+" " " (string-trim (or text "")))
   (or width rat-kingdom-board-title-width) nil nil "…"))

(defun rat-kingdom-board--heading (id name epic &optional width)
  "Return the heading of the card of the story ID, in Markdown.
NAME is its worker's display name and EPIC its epic, either \"\" for
none.  What follows ID is cut so that the heading has no more than
WIDTH characters, by default `rat-kingdom-board-title-width'."
  (concat "**" id "**"
          (truncate-string-to-width
           (concat (if (string-empty-p name) "" (concat " · " name))
                   (if (string-empty-p epic) "" (format " · epic %s" epic)))
           (max 0 (- (or width rat-kingdom-board-title-width) (string-width id)))
           nil nil "…")))

(defun rat-kingdom-board--attention (column payload age stuck)
  "Return (TONE . NOTE) for a story in COLUMN with PAYLOAD.
AGE is how long it has been where it is, in seconds, and STUCK the
reason it was reported stuck, or nil."
  (let ((long (and (memq column '(queued working checking merging))
                   (> age (* 60 rat-kingdom-board-long-minutes)))))
    (cond
     ((eq column 'done)
      (cons "success" (if (plist-get payload :integrated) "Merged" "Finished")))
     ((eq column 'stopped)
      (cons "error" (if (equal (plist-get payload :phase) "cancelled")
                        "Cancelled"
                      (format "Stopped at %s: %s" (plist-get payload :at)
                              (or (plist-get payload :reason)
                                  "no reason given")))))
     (stuck (cons "error" (format "Stuck: %s" stuck)))
     ((eq column 'review)
      (cons "warning" (if (equal (plist-get payload :awaiting) "gate")
                          (format "Waits at the gate %s"
                                  (plist-get payload :step))
                        "Waits for review")))
     (long (cons "warning" "Running long"))
     (t (cons "" "")))))

(defun rat-kingdom-board-card (space story &optional archived)
  "Return the card of the token STORY in SPACE, as (COLUMN . CARD).
ARCHIVED, if given, is when the token was archived.  CARD is a
property list of what the card shows: `:id', `:name' (the worker's
display name, or \"\"), `:repo', `:epic' (or \"\"), `:title', `:agent',
`:age', `:tone', `:note', `:heading', `:detail', `:worker' (non-nil if
it has a worker to open) and `:live' (non-nil unless it ended)."
  (let* ((payload (plist-get story :payload))
         (id (plist-get story :identity))
         (repo (plist-get story :scope))
         (column (rat-kingdom-board-phase
                  (and (not archived) (rat-kingdom-board--workflow space story))
                  payload))
         (now (funcall rat-kingdom-space-now-function))
         (age (- now (or archived (plist-get payload :entered) now)))
         (run (plist-get payload :run))
         (name (or (rat-kingdom-board-rat-name space run) ""))
         (epic (or (plist-get payload :epic) ""))
         (agent (or (plist-get payload :agent) ""))
         (stuck (and (not archived)
                     (plist-get
                      (plist-get (rat-kingdom-space-rd
                                  space (list 'stuck :scope repo :identity id))
                                 :payload)
                      :reason)))
         (attention (rat-kingdom-board--attention
                     column payload age
                     (and stuck (format "%s" stuck))))
         (age-text (rat-kingdom-board-age-text age)))
    (cons column
          (list :id id :name name :repo repo :epic epic
                :title (rat-kingdom-board--truncate (plist-get payload :title))
                :agent agent :age age-text
                :tone (car attention) :note (cdr attention)
                :heading (rat-kingdom-board--heading id name epic)
                :detail (rat-kingdom-board--truncate
                         (string-join
                          (delete "" (list repo agent
                                           (format "%s at %s" age-text
                                                   (plist-get payload :at))))
                          " · "))
                :worker (and (not archived) run
                             (buffer-live-p (rat-kingdom-run-handle run))
                             t)
                :live (not archived)))))

(defun rat-kingdom-board--since ()
  "Return the time from which a story that ended is still shown."
  (- (funcall rat-kingdom-space-now-function)
     (* 3600 rat-kingdom-board-done-hours)))

(defun rat-kingdom-board--ended-p (story)
  "Return non-nil if the archived token STORY is one the board shows."
  (and (not (plist-get (plist-get story :payload) :parent))
       (member (plist-get (plist-get story :payload) :phase)
               '("done" "cancelled"))))

(defun rat-kingdom-board--shows-p (filter column story)
  "Return non-nil if FILTER lets the board show STORY, in COLUMN."
  (and (or (null (plist-get filter :repo))
           (equal (plist-get filter :repo) (plist-get story :scope)))
       (or (plist-get filter :ended)
           (not (memq column rat-kingdom-board--ended)))))

(defun rat-kingdom-board-card-for (space id &optional filter)
  "Return the card of the story ID in SPACE, as (COLUMN . CARD), or nil.
It is nil if the story is a child, ended before the board's window, or
is not one FILTER, a property list like `rat-kingdom-board--filter',
lets the board show."
  (let ((filter (or filter rat-kingdom-board--filter)))
    (if-let* ((story (rat-kingdom-story-get space id)))
        (unless (plist-get (plist-get story :payload) :parent)
          (let ((card (rat-kingdom-board-card space story)))
            (and (rat-kingdom-board--shows-p filter (car card) story) card)))
      (when-let* ((story (car (last (cl-remove-if-not
                                     #'rat-kingdom-board--ended-p
                                     (rat-kingdom-space-archived-in
                                      space 'story (rat-kingdom-board--since)
                                      id)))))
                  (card (rat-kingdom-board-card space story
                                                (plist-get story :archived))))
        (and (rat-kingdom-board--shows-p filter (car card) story) card)))))

(defun rat-kingdom-board-cards (space &optional filter)
  "Return the cards of the board of SPACE, as (ID COLUMN . CARD), oldest first.
FILTER is as for `rat-kingdom-board-card-for'."
  (let* ((filter (or filter rat-kingdom-board--filter))
         (live (rat-kingdom-story-list space))
         (ids (mapcar (lambda (story) (plist-get story :identity)) live))
         (ended (make-hash-table :test #'equal))
         entries)
    (dolist (story live)
      (unless (plist-get (plist-get story :payload) :parent)
        (push (list (plist-get (plist-get story :payload) :entered)
                    story nil)
              entries)))
    (dolist (story (rat-kingdom-space-archived-in space 'story
                                                  (rat-kingdom-board--since)))
      (when (and (rat-kingdom-board--ended-p story)
                 (not (member (plist-get story :identity) ids)))
        (puthash (plist-get story :identity) story ended)))
    (maphash (lambda (_id story)
               (push (list (plist-get story :archived) story
                           (plist-get story :archived))
                     entries))
             ended)
    (cl-loop for (_ story archived)
             in (cl-sort entries #'< :key (lambda (entry) (or (car entry) 0)))
             for card = (rat-kingdom-board-card space story archived)
             when (rat-kingdom-board--shows-p filter (car card) story)
             collect (cons (plist-get story :identity) card))))

;;;; The surface, as data

(defun rat-kingdom-board--card-object (card)
  "Return CARD, a property list, as the JSON object the data model holds.
Its lines are cut to `rat-kingdom-board--text-width'."
  (let ((width (rat-kingdom-board--text-width)))
    (rat-kingdom-plan--obj
     "id" (plist-get card :id) "name" (plist-get card :name)
     "repo" (plist-get card :repo) "epic" (plist-get card :epic)
     "title" (rat-kingdom-board--truncate (plist-get card :title) width)
     "agent" (plist-get card :agent)
     "age" (plist-get card :age) "tone" (plist-get card :tone)
     "note" (rat-kingdom-board--truncate (plist-get card :note) width)
     "hasNote" (rat-kingdom-plan--bool
                (not (string-empty-p (plist-get card :note))))
     "heading" (rat-kingdom-board--heading (plist-get card :id)
                                           (plist-get card :name)
                                           (plist-get card :epic)
                                           width)
     "detail" (rat-kingdom-board--truncate (plist-get card :detail) width)
     "worker" (rat-kingdom-plan--bool (plist-get card :worker))
     "live" (rat-kingdom-plan--bool (plist-get card :live)))))

(defun rat-kingdom-board--column-title (column count)
  "Return the title of COLUMN holding COUNT cards."
  (format "%s (%d)" (alist-get column rat-kingdom-board-columns) count))

(defun rat-kingdom-board--count (column)
  "Return how many cards the board holds in COLUMN."
  (let ((count 0))
    (maphash (lambda (_id entry) (when (eq (car entry) column) (cl-incf count)))
             rat-kingdom-board--cards)
    count))

(defun rat-kingdom-board-shown-columns (filter held)
  "Return the columns the board shows under FILTER, in order.
HELD is the columns that hold cards.  Done and Stopped are shown if
FILTER says so, and with `rat-kingdom-board-hide-empty-columns' only
the columns in HELD are."
  (cl-loop for (column . _) in rat-kingdom-board-columns
           when (and (or (plist-get filter :ended)
                         (not (memq column rat-kingdom-board--ended)))
                     (or (not rat-kingdom-board-hide-empty-columns)
                         (memq column held)))
           collect column))

(defun rat-kingdom-board--held ()
  "Return the columns that hold cards on the board."
  (let (held)
    (maphash (lambda (_id entry) (cl-pushnew (car entry) held))
             rat-kingdom-board--cards)
    held))

(defun rat-kingdom-board-layout (width count)
  "Return the layout for COUNT columns in a window WIDTH characters wide.
That is (LAYOUT . COLUMN-WIDTH): each column has the width shared
equally, but no more than `rat-kingdom-board-column-width', and LAYOUT
is `row' if that is at least `rat-kingdom-board-min-column-width', and
`stacked' otherwise."
  (let ((each (min rat-kingdom-board-column-width
                   (/ width (max 1 count)))))
    (cons (if (>= each rat-kingdom-board-min-column-width) 'row 'stacked)
          each)))

(defun rat-kingdom-board--arrange (held)
  "Lay the board out for the columns HELD that hold cards.
Set what it shows and how, from its filter and its window's width, and
return non-nil if that changed."
  (let* ((shown (rat-kingdom-board-shown-columns rat-kingdom-board--filter held))
         (layout (rat-kingdom-board-layout
                  (or rat-kingdom-board--width (rat-kingdom-board--guess-width))
                  (length shown)))
         (old (list rat-kingdom-board--shown rat-kingdom-board--layout
                    rat-kingdom-board--column-width)))
    (setq rat-kingdom-board--shown shown
          rat-kingdom-board--layout (car layout)
          rat-kingdom-board--column-width (cdr layout))
    (not (equal old (list shown (car layout) (cdr layout))))))

(defun rat-kingdom-board--legend (filter shown)
  "Return the line naming the columns FILTER allows but SHOWN leaves out.
Each is named with its count, 0, or the line is \"\" if there are none."
  (mapconcat (lambda (column)
               (format "%s 0" (alist-get column rat-kingdom-board-columns)))
             (cl-set-difference (rat-kingdom-board-shown-columns
                                 filter (mapcar #'car rat-kingdom-board-columns))
                                shown)
             " · "))

(defun rat-kingdom-board--button (id label action)
  "Return the components of the card button ID saying LABEL for ACTION."
  (list
   (rat-kingdom-plan--component
    id "Button" "child" (concat id "-label")
    "action" (rat-kingdom-plan--obj
              "event" (rat-kingdom-plan--obj
                       "name" action
                       "context" (rat-kingdom-plan--obj
                                  "story" (rat-kingdom-plan--path "id")))))
   (rat-kingdom-plan--component (concat id "-label") "Text" "text" label)))

(defun rat-kingdom-board--card-components (layout)
  "Return the components of a card, the template, for LAYOUT."
  (append
   (and (eq layout 'stacked)
        (list (rat-kingdom-plan--component "card" "Card" "child" "card-body")))
   (list
    (rat-kingdom-plan--component
     "card-body" "Column"
     "children" ["card-heading" "card-title" "card-detail" "card-note"
                 "card-buttons"])
    (rat-kingdom-plan--component "card-heading" "Text"
                                 "text" (rat-kingdom-plan--path "heading"))
    (rat-kingdom-plan--component "card-title" "Text"
                                 "text" (rat-kingdom-plan--path "title"))
    (rat-kingdom-plan--component "card-detail" "Text" "variant" "caption"
                                 "text" (rat-kingdom-plan--path "detail"))
    (rat-kingdom-plan--component "card-note" "Text"
                                 "text" (rat-kingdom-plan--path "note")
                                 "tone" (rat-kingdom-plan--path "tone")
                                 "visible" (rat-kingdom-plan--path "hasNote"))
    ;; A narrow column takes the buttons two to a line.
    (if (and (eq layout 'row)
             (< (rat-kingdom-board--text-width) rat-kingdom-board--buttons-width))
        (rat-kingdom-plan--component
         "card-buttons" "Column" "children" ["card-buttons-1" "card-buttons-2"])
      (rat-kingdom-plan--component
       "card-buttons" "Row"
       "children" ["card-open" "card-show" "card-diff" "card-cancel"]))
    (rat-kingdom-plan--component
     "card-buttons-1" "Row" "children" ["card-open" "card-show"])
    (rat-kingdom-plan--component
     "card-buttons-2" "Row" "children" ["card-diff" "card-cancel"]))
   (let ((open (rat-kingdom-board--button "card-open" "Worker" "open")))
     (puthash "visible" (rat-kingdom-plan--path "worker") (car open))
     open)
   (rat-kingdom-board--button "card-show" "Show" "show")
   (rat-kingdom-board--button "card-diff" "Diff" "diff")
   (let ((cancel (rat-kingdom-board--button "card-cancel" "Cancel" "cancel")))
     (puthash "visible" (rat-kingdom-plan--path "live") (car cancel))
     cancel)))

(defun rat-kingdom-board--column-components (column layout)
  "Return the components of COLUMN for LAYOUT, its container first."
  (let* ((name (symbol-name column))
         (id (concat "column-" name))
         (title (rat-kingdom-plan--path (format "/columns/%s/title" name)))
         (visible (rat-kingdom-plan--path (format "/columns/%s/visible" name)))
         (list (rat-kingdom-plan--component
                (concat id "-cards") "Column"
                "children" (rat-kingdom-plan--obj
                            "path" (format "/cards/%s" name)
                            "componentId" (if (eq layout 'row)
                                              "card-body"
                                            "card")))))
    (if (eq layout 'row)
        (list (rat-kingdom-plan--component
               id "Column" "children" (vector (concat id "-title")
                                              (concat id "-cards"))
               "visible" visible)
              (rat-kingdom-plan--component (concat id "-title") "Text"
                                           "variant" "h3" "text" title)
              list)
      (list (rat-kingdom-plan--component id "Section" "title" title
                                         "child" (concat id "-cards")
                                         "visible" visible)
            list))))

(defun rat-kingdom-board-components (layout &optional shown)
  "Return the components of the story board for LAYOUT, `row' or `stacked'.
SHOWN is the columns shown, by default all of them."
  (setq shown (or shown (mapcar #'car rat-kingdom-board-columns)))
  (append
   (list
    (rat-kingdom-plan--component
     "root" "Column"
     "children" ["heading" "filters" "result" "legend" "board"])
    (rat-kingdom-plan--component "heading" "Text" "variant" "h2"
                                 "text" "Story board")
    (rat-kingdom-plan--component
     "filters" "Row" "children" ["filter-repo" "filter-ended" "filter-apply"])
    (rat-kingdom-plan--component
     "filter-repo" "Picker" "label" "Repository"
     "options" (rat-kingdom-plan--path "/repos")
     "value" (rat-kingdom-plan--path "/filter/repo"))
    (rat-kingdom-plan--component
     "filter-ended" "CheckBox" "label" "Show Done and Stopped"
     "value" (rat-kingdom-plan--path "/filter/ended"))
    (rat-kingdom-plan--component
     "filter-apply" "Button" "child" "filter-apply-label"
     "action" (rat-kingdom-plan--obj
               "event" (rat-kingdom-plan--obj
                        "name" "filter"
                        "context" (rat-kingdom-plan--obj
                                   "repo" (rat-kingdom-plan--path "/filter/repo")
                                   "ended" (rat-kingdom-plan--path
                                            "/filter/ended")))))
    (rat-kingdom-plan--component "filter-apply-label" "Text" "text" "Apply")
    (rat-kingdom-plan--component "result" "Text"
                                 "text" (rat-kingdom-plan--path "/result")
                                 "tone" (rat-kingdom-plan--path "/resultTone"))
    (rat-kingdom-plan--component "legend" "Text" "variant" "caption"
                                 "text" (rat-kingdom-plan--path "/legend")
                                 "visible" (rat-kingdom-plan--path "/hasLegend"))
    (rat-kingdom-plan--component
     "board" (if (eq layout 'row) "Row" "Column")
     "children" (vconcat (mapcar (lambda (column) (format "column-%s" column))
                                 shown))))
   (mapcan (lambda (column)
             (rat-kingdom-board--column-components column layout))
           shown)
   (rat-kingdom-board--card-components layout)))

(defun rat-kingdom-board--repo-options (space)
  "Return the repository picker's options for SPACE, all first."
  (vconcat
   (list (rat-kingdom-plan--obj "label" "all repositories" "value" ""))
   (mapcar (lambda (repo)
             (let ((name (plist-get repo :name)))
               (rat-kingdom-plan--obj "label" name "value" name)))
           (rat-kingdom-repo-list space))))

(defun rat-kingdom-board-data (space entries filter)
  "Return the board's data model for SPACE, holding ENTRIES under FILTER.
ENTRIES are as `rat-kingdom-board-cards' returns them."
  (let* ((cards (rat-kingdom-plan--obj))
         (columns (rat-kingdom-plan--obj))
         (shown (rat-kingdom-board-shown-columns
                 filter (mapcar #'cadr entries)))
         (legend (rat-kingdom-board--legend filter shown)))
    (pcase-dolist (`(,column . ,_) rat-kingdom-board-columns)
      (let ((name (symbol-name column))
            (held (rat-kingdom-plan--obj)))
        (pcase-dolist (`(,id ,in . ,card) entries)
          (when (eq in column)
            (puthash id (rat-kingdom-board--card-object card) held)))
        (puthash name held cards)
        (puthash name
                 (rat-kingdom-plan--obj
                  "title" (rat-kingdom-board--column-title
                           column (hash-table-count held))
                  "visible" (rat-kingdom-plan--bool (memq column shown)))
                 columns)))
    (rat-kingdom-plan--obj
     "repos" (rat-kingdom-board--repo-options space)
     "legend" legend
     "hasLegend" (rat-kingdom-plan--bool (not (string-empty-p legend)))
     "filter" (rat-kingdom-plan--obj
               "repo" (or (plist-get filter :repo) "")
               "ended" (rat-kingdom-plan--bool (plist-get filter :ended)))
     "columns" columns
     "cards" cards
     "result" ""
     "resultTone" "muted")))

(defun rat-kingdom-board--message (type &rest pairs)
  "Return the A2UI message TYPE for the board, with the fields PAIRS."
  (rat-kingdom-plan--obj
   "version" "v0.9"
   type (apply #'rat-kingdom-plan--obj
               "surfaceId" rat-kingdom-board-surface-id pairs)))

(defun rat-kingdom-board-update (path &optional value)
  "Return the updateDataModel message setting PATH to VALUE.
With VALUE nil, the message removes PATH."
  (if value
      (rat-kingdom-board--message "updateDataModel" "path" path "value" value)
    (rat-kingdom-board--message "updateDataModel" "path" path)))

;;;; a2ui

(defun rat-kingdom-board--require-a2ui ()
  "Signal an error saying a2ui is missing, unless it can be loaded."
  (unless (rat-kingdom-plan-a2ui-p)
    (error "The story board needs a2ui (https://github.com/chazu/a2ui.el), \
which is not installed or cannot be loaded")))

(defun rat-kingdom-board--a2ui-session ()
  "Return the a2ui session of the story board, making it if needed."
  (or rat-kingdom-board--session
      (let ((session (a2ui-session-create
                      :name "rat-kingdom"
                      :catalogs '(basic emacs)
                      :send-action-fn (lambda (message _metadata)
                                        (rat-kingdom-board--receive message))
                      :on-change-fn (lambda (surface-id)
                                      (rat-kingdom-board--changed surface-id)))))
        (a2ui-vui-attach session)
        (setq rat-kingdom-board--session session))))

(defun rat-kingdom-board--live-p ()
  "Return non-nil if the story board is shown by a2ui."
  (and rat-kingdom-board--session
       (a2ui-session-surface rat-kingdom-board--session
                             rat-kingdom-board-surface-id)))

(defun rat-kingdom-board--send (message)
  "Apply MESSAGE, an A2UI message, to the story board's session."
  (a2ui-apply-message (rat-kingdom-board--a2ui-session) message))

(defun rat-kingdom-board--usable-window-p (window)
  "Return non-nil if WINDOW may be given the board in place of its buffer."
  (and (window-live-p window)
       (not (window-minibuffer-p window))
       (not (window-dedicated-p window))
       (not (window-parameter window 'window-side))))

(defun rat-kingdom-board--main-window ()
  "Return the window the board goes in: the main frame's selected window.
Return nil if that window is a side window, dedicated or the minibuffer."
  (let* ((frame (selected-frame))
         (frame (or (frame-parameter frame 'parent-frame) frame))
         (window (frame-selected-window frame)))
    (and (rat-kingdom-board--usable-window-p window) window)))

(defun rat-kingdom-board--display-in-main-window (buffer alist)
  "Show BUFFER in the main frame's selected window, as ALIST says.
Return the window, or nil if that window cannot take it."
  (when-let* ((window (rat-kingdom-board--main-window)))
    (window--display-buffer buffer window 'reuse alist)))

(defun rat-kingdom-board--display ()
  "Show the board's surface in the main window and return its window."
  (let* ((a2ui-vui-display-action
          '((rat-kingdom-board--display-in-main-window
             a2ui-vui-display-in-main-window)))
         (buffer (a2ui-show-surface (rat-kingdom-board--a2ui-session)
                                    rat-kingdom-board-surface-id)))
    (setq rat-kingdom-board--buffer buffer)
    (with-current-buffer buffer
      (rat-kingdom-board-mode 1)
      (add-hook 'window-size-change-functions #'rat-kingdom-board--resized
                nil t))
    (get-buffer-window buffer t)))

(defun rat-kingdom-board--window-width ()
  "Return the width of the window that shows the board, or nil if none does.
That is a window showing the board's buffer, on any frame, whichever
window is selected."
  (when-let* ((buffer rat-kingdom-board--buffer)
              ((buffer-live-p buffer))
              (window (get-buffer-window buffer t)))
    (window-width window)))

(defun rat-kingdom-board--guess-width ()
  "Return the width of the window the board goes in, before it is shown."
  (window-width (or (rat-kingdom-board--main-window) (selected-window))))

(defun rat-kingdom-board--fit ()
  "Make a2ui lay out the board's buffer for the board's layout, and draw it."
  (when (buffer-live-p rat-kingdom-board--buffer)
    (with-current-buffer rat-kingdom-board--buffer
      ;; a2ui lays a Row out in `a2ui-vui-width' characters, so the
      ;; columns stand side by side only if it is the window's width.
      (if (and (eq rat-kingdom-board--layout 'row) rat-kingdom-board--width)
          (setq-local a2ui-vui-width (max (default-value 'a2ui-vui-width)
                                          rat-kingdom-board--width))
        (kill-local-variable 'a2ui-vui-width))
      (a2ui-surface-refresh))))

(defun rat-kingdom-board-relayout ()
  "Lay the board out again for the width of the window that shows it.
Draw it again if that changes what it shows or how.  Do nothing if no
window shows it or its width did not change; otherwise return non-nil."
  (when (timerp rat-kingdom-board--relayout-timer)
    (cancel-timer rat-kingdom-board--relayout-timer))
  (setq rat-kingdom-board--relayout-timer nil)
  (when-let* ((space rat-kingdom-board--space)
              ((rat-kingdom-space-db space))
              (width (rat-kingdom-board--window-width))
              ((not (eql width rat-kingdom-board--width))))
    (setq rat-kingdom-board--width width)
    (when (rat-kingdom-board--arrange (rat-kingdom-board--held))
      (rat-kingdom-board-render space))
    (rat-kingdom-board--fit)
    t))

(defun rat-kingdom-board--resized (_window)
  "Lay the board out again soon: a window showing it changed its size.
This is on `window-size-change-functions' in the board's buffer.  The
layouts come at most every `rat-kingdom-board-interval' seconds."
  (unless rat-kingdom-board--relayout-timer
    (setq rat-kingdom-board--relayout-timer
          (run-at-time rat-kingdom-board-interval nil
                       #'rat-kingdom-board-relayout))))

;;;; Showing the board

(defun rat-kingdom-board-render (space)
  "Draw the whole story board of SPACE again, as the filter says.
Return the messages sent."
  (clrhash rat-kingdom-board--cards)
  (setq rat-kingdom-board--dirty nil)
  (let ((entries (rat-kingdom-board-cards space)))
    (pcase-dolist (`(,id . ,entry) entries)
      (puthash id entry rat-kingdom-board--cards))
    (rat-kingdom-board--arrange (mapcar #'cadr entries))
    (let ((messages
           (list (rat-kingdom-board--message
                  "createSurface" "catalogId" (rat-kingdom-plan--catalog)
                  "theme" (rat-kingdom-plan--obj
                           "agentDisplayName" "rat-kingdom"))
                 (rat-kingdom-board--message
                  "updateComponents"
                  "components" (vconcat (rat-kingdom-board-components
                                         rat-kingdom-board--layout
                                         rat-kingdom-board--shown)))
                 (rat-kingdom-board--message
                  "updateDataModel" "path" "/"
                  "value" (rat-kingdom-board-data
                           space entries rat-kingdom-board--filter)))))
      (dolist (message messages)
        (rat-kingdom-board--send message))
      (setq rat-kingdom-board--last (funcall rat-kingdom-board--now))
      messages)))

(defun rat-kingdom-board-show (&optional space select)
  "Show the story board of SPACE in the main window.
SPACE is by default the space rat-kingdom works in.  The board is
built from the space each time.  With SELECT, select its window.
Signal an error if a2ui cannot be loaded.  Return the board's window."
  (rat-kingdom-board--require-a2ui)
  (let ((space (or space (rat-kingdom-space-default))))
    ;; Until the board is shown, the width of its window is a guess;
    ;; once it is, it is laid out again if the guess was wrong.
    (setq rat-kingdom-board--space space
          rat-kingdom-board--width (or (rat-kingdom-board--window-width)
                                       (rat-kingdom-board--guess-width)))
    (rat-kingdom-board-render space)
    (rat-kingdom-board--start-ticking)
    (let ((window (rat-kingdom-board--display)))
      (unless (rat-kingdom-board-relayout)
        (rat-kingdom-board--fit))
      (when (and select (window-live-p window))
        (select-window window))
      window)))

(defun rat-kingdom-board--open-p (space)
  "Return non-nil if the story board of SPACE is open."
  (and space (eq rat-kingdom-board--space space) (rat-kingdom-board--live-p)))

(defun rat-kingdom-board-check-repo (space repo)
  "Signal an error unless REPO is the name of a repository registered in SPACE.
The error names the registered repositories."
  (unless (rat-kingdom-repo-get space repo)
    (let ((names (mapcar (lambda (record) (plist-get record :name))
                         (rat-kingdom-repo-list space))))
      (user-error "There is no repository named %s.  %s" repo
                  (if names
                      (format "The registered repositories are: %s"
                              (string-join (sort names #'string<) ", "))
                    "No repository is registered")))))

(defun rat-kingdom-board-scope (space scope)
  "Return the repository the board of SPACE is to show under SCOPE, or nil.
SCOPE is the name of a registered repository, `all' for all of them,
or nil.  With nil, an open board keeps its repository, and a board
that is not open shows all.  Signal an error if SCOPE names no
registered repository."
  (cond ((stringp scope) (rat-kingdom-board-check-repo space scope) scope)
        ((eq scope 'all) nil)
        ((rat-kingdom-board--open-p space)
         (plist-get rat-kingdom-board--filter :repo))))

(defun rat-kingdom-board-open (&optional space scope select)
  "Show the story board of SPACE, limited as SCOPE says, and return its window.
SPACE is by default the space rat-kingdom works in.  SCOPE is as for
`rat-kingdom-board-scope': a repository's name sets the board's
repository picker to it, `all' sets it to all repositories, and nil
keeps the picker of an open board, or shows all.  The check box that
hides Done and Stopped is kept.  With SELECT, select the board's
window.  Nothing is shown if SCOPE names no registered repository."
  (rat-kingdom-board--require-a2ui)
  (let* ((space (or space (rat-kingdom-space-default)))
         (repo (rat-kingdom-board-scope space scope)))
    (setq rat-kingdom-board--filter
          (plist-put (copy-sequence rat-kingdom-board--filter) :repo repo))
    (rat-kingdom-board-show space select)))

(defun rat-kingdom-board--read-repo (space)
  "Ask for a repository registered in SPACE, and return its name.
Return `all' if the answer is blank."
  (let* ((names (mapcar (lambda (record) (plist-get record :name))
                        (rat-kingdom-repo-list space)))
         (name (completing-read
                "Story board for the repository (blank for all): "
                names nil t)))
    (if (string-empty-p name) 'all name)))

;;;###autoload
(defun rat-kingdom-board (&optional repo)
  "Show the story board: the stories in the pipeline, as a Kanban board.
It takes the place of the buffer in the selected window, and keeps
itself up to date as the stories move.  \\`q' buries it.
With a prefix argument, ask for a repository, with completion over
those registered, and set the board's repository picker to it; a
blank answer shows all repositories.  Without one, an open board keeps
its repository, and a board that is not open shows all.

From Lisp, REPO is a repository's name, `all', or nil, as SCOPE is for
`rat-kingdom-board-open'."
  (interactive
   (list (and current-prefix-arg
              (rat-kingdom-board--read-repo (rat-kingdom-space-default)))))
  (rat-kingdom-board-open nil repo t))

(defun rat-kingdom-board-refresh ()
  "Draw the story board again from the space."
  (interactive)
  (if rat-kingdom-board--space
      (rat-kingdom-board-show rat-kingdom-board--space)
    (rat-kingdom-board)))

(defvar-keymap rat-kingdom-board-mode-map
  :doc "Keymap for `rat-kingdom-board-mode'."
  "q" #'quit-window
  "g" #'rat-kingdom-board-refresh)

(define-minor-mode rat-kingdom-board-mode
  "Minor mode for the buffer of the story board.
\\<rat-kingdom-board-mode-map>\\[quit-window] buries it and \
\\[rat-kingdom-board-refresh] draws it again from the space."
  :lighter " Board"
  :keymap rat-kingdom-board-mode-map)

;;;; Keeping it up to date

(defun rat-kingdom-board--story-of (op subject)
  "Return the id of the story whose card OP on SUBJECT may change, or nil.
OP and SUBJECT are as for `rat-kingdom-space-change-functions'."
  (if (memq op '(sweep expire))
      (plist-get subject :owner)
    (pcase (plist-get subject :category)
      ((or 'story 'stuck) (plist-get subject :identity))
      ('run (plist-get subject :owner)))))

(defun rat-kingdom-board--on-change (space op subject)
  "Mark the story OP on SUBJECT in SPACE changes, if the board shows SPACE."
  (when (and rat-kingdom-board--space (eq space rat-kingdom-board--space))
    (when-let* ((id (rat-kingdom-board--story-of op subject)))
      (rat-kingdom-board-mark id))))

(add-hook 'rat-kingdom-space-change-functions #'rat-kingdom-board--on-change)

(defun rat-kingdom-board-mark (id)
  "Mark the card of the story ID to be made again, and schedule an update.
Updates come at most every `rat-kingdom-board-interval' seconds."
  (unless (member id rat-kingdom-board--dirty)
    (push id rat-kingdom-board--dirty))
  (unless rat-kingdom-board--timer
    (setq rat-kingdom-board--timer
          (run-at-time (max 0 (- (+ rat-kingdom-board--last
                                    rat-kingdom-board-interval)
                                 (funcall rat-kingdom-board--now)))
                       nil #'rat-kingdom-board-flush))))

(defun rat-kingdom-board-changes (id old new)
  "Return the A2UI messages that turn the card OLD of the story ID into NEW.
OLD and NEW are (COLUMN . CARD), or nil for no card.  Return nil if
they are the same.  The counts of the columns are not included."
  (unless (equal old new)
    (append
     (when (and old (not (eq (car old) (car new))))
       (list (rat-kingdom-board-update (format "/cards/%s/%s" (car old) id))))
     (when new
       (list (rat-kingdom-board-update
              (format "/cards/%s/%s" (car new) id)
              (rat-kingdom-board--card-object (cdr new))))))))

(defun rat-kingdom-board-flush ()
  "Send the board the changes of the marked stories' cards.
Only the cards that changed are sent, and the titles of the columns
whose counts changed."
  (when (timerp rat-kingdom-board--timer)
    (cancel-timer rat-kingdom-board--timer))
  (setq rat-kingdom-board--timer nil)
  (let ((space rat-kingdom-board--space)
        (ids (reverse rat-kingdom-board--dirty))
        (columns nil)
        (messages nil))
    (setq rat-kingdom-board--dirty nil
          rat-kingdom-board--last (funcall rat-kingdom-board--now))
    (when (and space (rat-kingdom-space-db space) (rat-kingdom-board--live-p))
      (dolist (id ids)
        (let* ((old (gethash id rat-kingdom-board--cards))
               (new (rat-kingdom-board-card-for space id))
               (changes (rat-kingdom-board-changes id old new)))
          (when changes
            (setq messages (append messages changes))
            (unless (eq (car old) (car new))
              (when old (cl-pushnew (car old) columns))
              (when new (cl-pushnew (car new) columns)))
            (if new
                (puthash id new rat-kingdom-board--cards)
              (remhash id rat-kingdom-board--cards)))))
      (if (and columns (rat-kingdom-board--arrange (rat-kingdom-board--held)))
          ;; A column was emptied or filled, and is left out or brought
          ;; back: the columns shown, their widths and the cards' lines
          ;; change, so the board is drawn again.
          (prog1 (rat-kingdom-board-render space)
            (rat-kingdom-board--fit))
        (dolist (column (reverse columns))
          (setq messages
                (append messages
                        (list (rat-kingdom-board-update
                               (format "/columns/%s/title" column)
                               (rat-kingdom-board--column-title
                                column (rat-kingdom-board--count column)))))))
        (dolist (message messages)
          (rat-kingdom-board--send message))
        messages))))

(defun rat-kingdom-board--tick ()
  "Refresh the ages on the board, or stop if it is gone."
  (if (and rat-kingdom-board--space (rat-kingdom-board--live-p))
      (progn
        (maphash (lambda (id _entry) (rat-kingdom-board-mark id))
                 rat-kingdom-board--cards)
        ;; A story that ended may have moved into the window too.
        (when-let* ((space rat-kingdom-board--space)
                    ((rat-kingdom-space-db space)))
          (dolist (entry (rat-kingdom-board-cards space))
            (unless (gethash (car entry) rat-kingdom-board--cards)
              (rat-kingdom-board-mark (car entry))))))
    (rat-kingdom-board--stop)))

(defun rat-kingdom-board--start-ticking ()
  "Start refreshing the ages on the board, unless that is going on."
  (unless (timerp rat-kingdom-board--tick-timer)
    (setq rat-kingdom-board--tick-timer
          (run-at-time rat-kingdom-board-tick rat-kingdom-board-tick
                       #'rat-kingdom-board--tick))))

(defun rat-kingdom-board--stop ()
  "Stop following the space: the board is no longer shown."
  (dolist (timer (list rat-kingdom-board--timer rat-kingdom-board--tick-timer
                      rat-kingdom-board--relayout-timer))
    (when (timerp timer)
      (cancel-timer timer)))
  (setq rat-kingdom-board--timer nil
        rat-kingdom-board--tick-timer nil
        rat-kingdom-board--relayout-timer nil
        rat-kingdom-board--space nil
        rat-kingdom-board--dirty nil)
  (clrhash rat-kingdom-board--cards))

(defun rat-kingdom-board--changed (surface-id)
  "Note that the surface SURFACE-ID changed; stop if the board was deleted."
  (when (and (equal surface-id rat-kingdom-board-surface-id)
             rat-kingdom-board--space
             (not (rat-kingdom-board--live-p)))
    (rat-kingdom-board--stop)))

;;;; The buttons

(defun rat-kingdom-board--text-buffer (name text &optional mode)
  "Show TEXT in the buffer NAME, in MODE, by default `special-mode'."
  (let ((buffer (get-buffer-create name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert text)
        (goto-char (point-min)))
      (funcall (or mode #'special-mode)))
    (pop-to-buffer buffer)
    buffer))

(defun rat-kingdom-board-open-worker (space id)
  "Show the buffer of the worker of the story ID in SPACE."
  (let* ((run (plist-get (plist-get (rat-kingdom-story-get space id) :payload)
                         :run))
         (buffer (and run (rat-kingdom-run-handle run))))
    (unless (buffer-live-p buffer)
      (error "%s has no worker running in this Emacs" id))
    (pop-to-buffer buffer)))

(defun rat-kingdom-board-show-story (space id)
  "Show everything recorded about the story ID in SPACE, as `story_show' does."
  (rat-kingdom-board--text-buffer (format "*rat-kingdom story %s*" id)
                                  (rat-kingdom-king--show space id)))

(defun rat-kingdom-board-show-diff (space id)
  "Show the changes the story ID in SPACE makes, as `story_diff' does."
  (rat-kingdom-board--text-buffer (format "*rat-kingdom diff %s*" id)
                                  (rat-kingdom-king--diff space id)
                                  #'diff-mode))

(defun rat-kingdom-board-cancel (space id)
  "Cancel the story ID in SPACE, after asking.  Return what is left, or nil."
  (when (yes-or-no-p (format "Cancel the story %s for good? " id))
    (let ((text (rat-kingdom-story-cancel space id "user")))
      (rat-kingdom-board--result text "muted")
      text)))

(defun rat-kingdom-board--result (text tone)
  "Show TEXT on the board, in TONE."
  (when (rat-kingdom-board--live-p)
    (rat-kingdom-board--send (rat-kingdom-board-update "/result" text))
    (rat-kingdom-board--send (rat-kingdom-board-update "/resultTone" tone))))

(defun rat-kingdom-board-filter (context)
  "Show what the filter in CONTEXT asks for: `repo' and `ended'."
  (let* ((repo (rat-kingdom-plan--text (rat-kingdom-plan--get context "repo")))
         (ended (rat-kingdom-plan--true-p
                 (rat-kingdom-plan--get context "ended"))))
    (setq rat-kingdom-board--filter (list :repo repo :ended ended))
    (rat-kingdom-board-show rat-kingdom-board--space)))

(defun rat-kingdom-board-handle (name context)
  "Handle the button NAME pressed on the board, with CONTEXT."
  (if (equal name "filter")
      (rat-kingdom-board-filter context)
    (when-let* ((function (cdr (assoc name rat-kingdom-board-actions)))
                (id (rat-kingdom-plan--text
                     (rat-kingdom-plan--get context "story"))))
      (funcall function (or rat-kingdom-board--space
                            (rat-kingdom-space-default))
               id))))

(defun rat-kingdom-board--receive (message)
  "Act on MESSAGE, which the board sent."
  (cond
   ((gethash "action" message)
    (let* ((action (gethash "action" message))
           (name (gethash "name" action))
           (context (gethash "context" action)))
      (funcall rat-kingdom-board--defer
               (lambda ()
                 (condition-case err
                     (rat-kingdom-board-handle name context)
                   (error
                    (rat-kingdom-board--result
                     (format "**Error:** %s" (error-message-string err))
                     "error")
                    (message "rat-kingdom: the story board: %s"
                             (error-message-string err))))))))
   ((gethash "error" message)
    (let ((err (gethash "error" message)))
      (message "rat-kingdom: the story board reports %s: %s"
               (gethash "code" err) (gethash "message" err))))))

;;;; The king's tool

(rat-kingdom-king--deftool "board_show"
    "Show the user the story board in Emacs: a Kanban board of the stories \
in the pipeline (queued, working, checking, review, merging, done and \
stopped), which keeps itself up to date. It takes the place of the buffer \
in the user's main window. Use it when the user asks to see the board or \
how the stories stand. Give repo to show the stories of one repository: \
the board's repository picker is set to it, also when the board is open. \
Without repo, a board that is not open shows all repositories, and an open \
board keeps the repository its picker is set to; give all as true to show \
all repositories then. The answer says which repositories it shows."
    '((:name "repo" :type string :optional t
       :description "The name of a registered repository, to show only its \
stories. An unknown name is an error that lists the registered names, and \
nothing is shown. Leave it out to show all repositories, or to keep the \
repository of an open board.")
      (:name "all" :type boolean :optional t
       :description "true to show all repositories, also when the open \
board is set to one. Do not give it with repo. Default false."))
  (unless (rat-kingdom-plan-a2ui-p)
    (error "The story board is not available: a2ui is not installed or \
cannot be loaded in the user's Emacs.  Nothing was shown.  Tell the user \
how the stories stand with status instead"))
  (let ((repo (arg 'repo))
        (all (rat-kingdom-plan--true-p (arg 'all))))
    (when (and repo all)
      (error "Give repo or all, not both.  Nothing was shown"))
    (condition-case err
        (rat-kingdom-board-open space (cond (repo) (all 'all)))
      (user-error
       (error "%s.  Nothing was shown" (error-message-string err))))
    (let ((shown (plist-get rat-kingdom-board--filter :repo)))
      (format "Shown to the user: the story board for %s, with %d stories."
              (if shown (format "the repository %s" shown) "all repositories")
              (hash-table-count rat-kingdom-board--cards)))))

(provide 'rat-kingdom-board)
;;; rat-kingdom-board.el ends here
