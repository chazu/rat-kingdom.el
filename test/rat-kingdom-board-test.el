;;; rat-kingdom-board-test.el --- Tests for the story board -*- lexical-binding: t; -*-

;;; Commentary:

;; Batch tests for the story board.  Most run without a2ui: the board
;; is built as data, the calls into a2ui are stubbed, and the tests
;; press the buttons by handing the handler the message a2ui would
;; send.  The last test draws the board with the real a2ui, where it
;; can be loaded; see rat-kingdom-plan-test.el for RAT_KINGDOM_TEST_A2UI.

;;; Code:

(require 'ert)
(require 'rat-kingdom)
(require 'rat-kingdom-board)
(require 'rat-kingdom-story-test)
(require 'rat-kingdom-king-test)
(require 'rat-kingdom-reload-test)
(require 'rat-kingdom-plan-test)

(defvar rat-kingdom-board-test--sent nil
  "The A2UI messages sent to the stubbed a2ui, newest first.")

(defvar rat-kingdom-board-test--width 80
  "The width of the window that shows the board, under the stubbed a2ui.")

(defmacro rat-kingdom-board-test-with-stubs (vars &rest body)
  "Run BODY with VARS, (SPACE PATH), a fresh repository and a stubbed a2ui.
The board's state is fresh, it follows the space, and what it sends to
a2ui is recorded in `rat-kingdom-board-test--sent'.  It counts as shown
from when it is first shown."
  (declare (indent 1) (debug t))
  `(rat-kingdom-story-test-with-repo ,vars
     (let ((rat-kingdom-space-change-functions
            (list #'rat-kingdom-board--on-change))
           (rat-kingdom-board--cards (make-hash-table :test #'equal))
           (rat-kingdom-board--space nil)
           (rat-kingdom-board--session nil)
           (rat-kingdom-board--filter (list :repo nil :ended t))
           (rat-kingdom-board--layout 'stacked)
           (rat-kingdom-board--column-width rat-kingdom-board-column-width)
           (rat-kingdom-board--shown nil)
           (rat-kingdom-board--width nil)
           (rat-kingdom-board--buffer nil)
           (rat-kingdom-board--relayout-timer nil)
           (rat-kingdom-board--dirty nil)
           (rat-kingdom-board--timer nil)
           (rat-kingdom-board--tick-timer nil)
           (rat-kingdom-board--last 0)
           (rat-kingdom-board--defer #'funcall)
           (rat-kingdom-board-test--sent nil)
           (rat-kingdom-board-test--width 80))
       (cl-letf (((symbol-function 'rat-kingdom-plan-a2ui-p) (lambda () t))
                 ((symbol-function 'rat-kingdom-board--send)
                  (lambda (message)
                    (push message rat-kingdom-board-test--sent)))
                 ((symbol-function 'rat-kingdom-board--live-p)
                  (lambda () (and rat-kingdom-board--space t)))
                 ((symbol-function 'rat-kingdom-board--display) #'ignore)
                 ((symbol-function 'rat-kingdom-board--window-width)
                  (lambda () rat-kingdom-board-test--width))
                 ((symbol-function 'rat-kingdom-board--guess-width)
                  (lambda () rat-kingdom-board-test--width))
                 ((symbol-function 'rat-kingdom-board--start-ticking) #'ignore))
         (unwind-protect
             (progn ,@body)
           (dolist (timer (list rat-kingdom-board--timer
                                rat-kingdom-board--relayout-timer))
             (when (timerp timer)
               (cancel-timer timer))))))))

(defun rat-kingdom-board-test--updates ()
  "Return the updateDataModel messages sent, oldest first, as (PATH . VALUE).
VALUE is `absent' for a message that removes PATH."
  (cl-loop for message in (reverse rat-kingdom-board-test--sent)
           for (type . body) = (rat-kingdom-plan-test--body message)
           when (equal type "updateDataModel")
           collect (cons (gethash "path" body)
                         (gethash "value" body 'absent))))

(defun rat-kingdom-board-test--data ()
  "Return the data model last sent whole."
  (cdr (cl-find "/" (reverse (rat-kingdom-board-test--updates))
                :key #'car :test #'equal)))

(defun rat-kingdom-board-test--components ()
  "Return the components last sent, by id."
  (let ((message (cl-find-if (lambda (message)
                               (equal (car (rat-kingdom-plan-test--body message))
                                      "updateComponents"))
                             rat-kingdom-board-test--sent))
        (components (make-hash-table :test #'equal)))
    (seq-doseq (component (gethash "components"
                                   (cdr (rat-kingdom-plan-test--body message))))
      (puthash (gethash "id" component) component components))
    components))

(defun rat-kingdom-board-test--board ()
  "Return the board's container last sent, as (COMPONENT . CHILDREN)."
  (let ((board (gethash "board" (rat-kingdom-board-test--components))))
    (cons (gethash "component" board)
          (append (gethash "children" board) nil))))

(defun rat-kingdom-board-test--column (data column)
  "Return the ids of the cards DATA holds in COLUMN, sorted."
  (sort (hash-table-keys (gethash column (gethash "cards" data))) #'string<))

(defun rat-kingdom-board-test--press (name story)
  "Press the button NAME of the card of STORY, as a2ui sends it."
  (rat-kingdom-board--receive
   (rat-kingdom-plan--obj
    "version" "v0.9"
    "action" (rat-kingdom-plan--obj
              "name" name "surfaceId" rat-kingdom-board-surface-id
              "context" (rat-kingdom-plan--obj "story" story)))))

;;;; Columns

(defun rat-kingdom-board-test--phase (workflow &rest payload)
  "Return the column of a story of WORKFLOW, a name, whose token has PAYLOAD."
  (rat-kingdom-board-phase (rat-kingdom-workflow-get workflow) payload))

(ert-deftest rat-kingdom-board-test-phases-of-story ()
  (cl-flet ((phase (&rest payload)
              (apply #'rat-kingdom-board-test--phase "story" payload)))
    (should (eq (phase :at "ready" :phase "enter") 'queued))
    (should (eq (phase :at "ready" :phase "wait" :step "implement"
                       :awaiting rat-kingdom-story-free-worker)
                'queued))
    (should (eq (phase :at "ready" :phase "wait" :step "implement"
                       :awaiting "setup")
                'working))
    (should (eq (phase :at "ready" :phase "wait" :step "implement"
                       :awaiting "worker")
                'working))
    (should (eq (phase :at "checking" :phase "enter") 'checking))
    (should (eq (phase :at "checking" :phase "wait" :step "check"
                       :awaiting "check")
                'checking))
    (should (eq (phase :at "review" :phase "wait" :step "review"
                       :awaiting "review")
                'review))
    (should (eq (phase :at "integrating" :phase "enter") 'merging))
    (should (eq (phase :at "done" :phase "enter") 'done))
    (should (eq (phase :at "done" :phase "done") 'done))
    (should (eq (phase :at "blocked" :phase "parked") 'stopped))
    (should (eq (phase :at "blocked" :phase "enter") 'stopped))
    (should (eq (phase :at "review" :phase "cancelled") 'stopped))
    ;; Moved by hand to a place no step is taken from.
    (should (eq (phase :at "checking" :phase "parked") 'stopped))))

(ert-deftest rat-kingdom-board-test-phases-of-story-lite ()
  (cl-flet ((phase (&rest payload)
              (apply #'rat-kingdom-board-test--phase "story-lite" payload)))
    (should (eq (phase :at "ready" :phase "enter") 'queued))
    (should (eq (phase :at "ready" :phase "wait" :step "implement"
                       :awaiting "worker")
                'working))
    (should (eq (phase :at "checking" :phase "wait" :step "check"
                       :awaiting "check")
                'checking))
    (should (eq (phase :at "integrating" :phase "enter") 'merging))
    (should (eq (phase :at "done" :phase "done") 'done))
    (should (eq (phase :at "blocked" :phase "parked") 'stopped))))

(ert-deftest rat-kingdom-board-test-phases-of-research ()
  (cl-flet ((phase (&rest payload)
              (apply #'rat-kingdom-board-test--phase "research" payload)))
    (should (eq (phase :at "ready" :phase "enter") 'queued))
    (should (eq (phase :at "ready" :phase "wait" :step "research"
                       :awaiting "worker")
                'working))
    (should (eq (phase :at "review" :phase "wait" :step "review"
                       :awaiting "review")
                'review))
    (should (eq (phase :at "done" :phase "done") 'done))
    (should (eq (phase :at "blocked" :phase "parked") 'stopped))))

(ert-deftest rat-kingdom-board-test-phases-every-place ()
  ;; Every place of every built-in workflow has a column.
  (dolist (workflow (rat-kingdom-workflow-list))
    (dolist (place (plist-get workflow :places))
      (should (assq (rat-kingdom-board-phase
                     workflow (list :at place :phase "enter"))
                    rat-kingdom-board-columns)))))

(ert-deftest rat-kingdom-board-test-phases-customized ()
  (cl-flet ((phase (&rest payload)
              (apply #'rat-kingdom-board-test--phase "story" payload)))
    ;; A place by name comes first, then a step, then the kind.
    (let ((rat-kingdom-board-phases '(("review" . working) (:review . merging))))
      (should (eq (phase :at "review" :phase "wait" :step "review"
                         :awaiting "review")
                  'working)))
    (let ((rat-kingdom-board-phases '(("implement" . checking))))
      (should (eq (phase :at "ready" :phase "wait" :step "implement"
                         :awaiting "worker")
                  'checking))
      ;; Waiting for a free worker is queued whatever the table says.
      (should (eq (phase :at "ready" :phase "wait" :step "implement"
                         :awaiting rat-kingdom-story-free-worker)
                  'queued)))
    (let ((rat-kingdom-board-phases '((:review . merging))))
      (should (eq (phase :at "review" :phase "wait" :step "review"
                         :awaiting "review")
                  'merging))
      ;; A kind not listed is working.
      (should (eq (phase :at "checking" :phase "wait" :step "check"
                         :awaiting "check")
                  'working)))))

(ert-deftest rat-kingdom-board-test-layout ()
  (let ((rat-kingdom-board-column-width 32)
        (rat-kingdom-board-min-column-width 18))
    ;; The columns share the width, each no wider than the most.
    (should (equal (rat-kingdom-board-layout 185 7) '(row . 26)))
    (should (equal (rat-kingdom-board-layout 300 7) '(row . 32)))
    (should (equal (rat-kingdom-board-layout 185 2) '(row . 32)))
    ;; Side by side down to the fewest characters a column needs.
    (should (equal (rat-kingdom-board-layout 126 7) '(row . 18)))
    (should (equal (rat-kingdom-board-layout 125 7) '(stacked . 17)))
    (should (equal (rat-kingdom-board-layout 124 5) '(row . 24)))
    (should (eq (car (rat-kingdom-board-layout 80 7)) 'stacked))
    ;; No column at all is a row of nothing.
    (should (eq (car (rat-kingdom-board-layout 80 0)) 'row))))

(ert-deftest rat-kingdom-board-test-shown-columns ()
  (let ((held '(working review)))
    (let ((rat-kingdom-board-hide-empty-columns nil))
      (should (equal (rat-kingdom-board-shown-columns '(:ended t) held)
                     (mapcar #'car rat-kingdom-board-columns)))
      (should (equal (rat-kingdom-board-shown-columns '(:ended nil) held)
                     '(queued working checking review merging)))
      (should (equal (rat-kingdom-board--legend
                      '(:ended t) (mapcar #'car rat-kingdom-board-columns))
                     "")))
    (let ((rat-kingdom-board-hide-empty-columns t))
      (should (equal (rat-kingdom-board-shown-columns '(:ended t) held)
                     '(working review)))
      (should (equal (rat-kingdom-board-shown-columns '(:ended nil)
                                                      '(working done))
                     '(working)))
      ;; Every column left out is named, with its count.
      (should (equal (rat-kingdom-board--legend '(:ended nil) '(working review))
                     "Queued 0 · Checking 0 · Merging 0")))))

(ert-deftest rat-kingdom-board-test-age-text ()
  (should (equal (rat-kingdom-board-age-text 45) "45s"))
  (should (equal (rat-kingdom-board-age-text 750) "12m"))
  (should (equal (rat-kingdom-board-age-text 7200) "2h"))
  (should (equal (rat-kingdom-board-age-text 11100) "3h 5m"))
  (should (equal (rat-kingdom-board-age-text 200000) "2d")))

;;;; Cards

(ert-deftest rat-kingdom-board-test-card-without-and-with-a-name ()
  (rat-kingdom-board-test-with-stubs (space path)
    (setq rat-kingdom-story-test--now 1000.0)
    (rat-kingdom-story-start space "demo" "Add a parser" nil "S-3a9c")
    (rat-kingdom-reaction-run space)
    (setq rat-kingdom-story-test--now 1750.0)
    (let ((card (rat-kingdom-board-card-for space "S-3a9c")))
      (should (eq (car card) 'working))
      (should (equal (plist-get (cdr card) :id) "S-3a9c"))
      ;; Every worker gets a name: the first in a fresh space is Pip.
      (should (equal (plist-get (cdr card) :name) "Pip-3a9c"))
      (should (equal (plist-get (cdr card) :heading) "**S-3a9c** · Pip-3a9c"))
      (should (equal (plist-get (cdr card) :repo) "demo"))
      (should (equal (plist-get (cdr card) :title) "Add a parser"))
      (should (equal (plist-get (cdr card) :agent) "claude"))
      (should (equal (plist-get (cdr card) :age) "12m"))
      (should (equal (plist-get (cdr card) :epic) ""))
      (should (equal (plist-get (cdr card) :tone) ""))
      (should (plist-get (cdr card) :live)))
    ;; A run with no :name, as before rats had names, shows its id.
    (rat-kingdom-run-update space "S-3a9c.1" :name nil)
    (let ((card (rat-kingdom-board-card-for space "S-3a9c")))
      (should (equal (plist-get (cdr card) :name) "S-3a9c.1"))
      (should (equal (plist-get (cdr card) :heading) "**S-3a9c** · S-3a9c.1")))))

(ert-deftest rat-kingdom-board-test-card-attention ()
  (rat-kingdom-board-test-with-stubs (space path)
    (setq rat-kingdom-story-test--now 1000.0)
    (rat-kingdom-story-start space "demo" (make-string 100 ?x) nil "S-1"
                             nil nil nil "T-7")
    (rat-kingdom-reaction-run space)
    (let ((card (cdr (rat-kingdom-board-card-for space "S-1"))))
      ;; An epic's story names its epic; a long title is cut short.
      (should (equal (plist-get card :epic) "T-7"))
      (should (string-search "epic T-7" (plist-get card :heading)))
      (should (= (length (plist-get card :title))
                 rat-kingdom-board-title-width)))
    ;; Long-running.
    (setq rat-kingdom-story-test--now (+ 1000.0 (* 61 60)))
    (let ((card (cdr (rat-kingdom-board-card-for space "S-1"))))
      (should (equal (plist-get card :tone) "warning"))
      (should (equal (plist-get card :note) "Running long")))
    ;; Stuck.
    (rat-kingdom-story--stuck space (rat-kingdom-story-get space "S-1")
                              "Its worker is gone.")
    (let ((card (cdr (rat-kingdom-board-card-for space "S-1"))))
      (should (equal (plist-get card :tone) "error"))
      (should (equal (plist-get card :note) "Stuck: Its worker is gone.")))
    ;; Stopped.
    (rat-kingdom-story-move space "S-1" "blocked" "Wrong approach")
    (rat-kingdom-reaction-run space)
    (let ((card (rat-kingdom-board-card-for space "S-1")))
      (should (eq (car card) 'stopped))
      (should (equal (plist-get (cdr card) :tone) "error"))
      (should (string-search "Stopped at blocked" (plist-get (cdr card) :note))))))

(ert-deftest rat-kingdom-board-test-review-card ()
  (rat-kingdom-board-test-with-stubs (space path)
    (rat-kingdom-story-start space "demo" "Reviewed" nil "S-1" "story")
    (rat-kingdom-reaction-run space)
    (rat-kingdom-story-test--work space "S-1" "feature.txt")
    (rat-kingdom-story-test--settle space "S-1")
    (should (equal (rat-kingdom-story-test--place space "S-1") "review"))
    (let ((card (rat-kingdom-board-card-for space "S-1")))
      (should (eq (car card) 'review))
      (should (equal (plist-get (cdr card) :tone) "warning"))
      (should (equal (plist-get (cdr card) :note) "Waits for review")))))

(ert-deftest rat-kingdom-board-test-built-from-the-space ()
  ;; What a restarted Emacs sees: live stories, stories that ended in
  ;; the window, and none of those that ended before it.
  (rat-kingdom-board-test-with-stubs (space path)
    (setq rat-kingdom-story-test--now 1000.0)
    (rat-kingdom-story-start space "demo" "Old" nil "S-1")
    (rat-kingdom-story-cancel space "S-1")
    (setq rat-kingdom-story-test--now (+ 1000.0 (* 25 3600)))
    (rat-kingdom-story-start space "demo" "Cancelled" nil "S-2")
    (rat-kingdom-story-cancel space "S-2")
    (rat-kingdom-story-start space "demo" "Merged" nil "S-3")
    (rat-kingdom-reaction-run space)
    (rat-kingdom-story-test--work space "S-3" "feature.txt")
    (rat-kingdom-story-test--settle space "S-3")
    (should-not (rat-kingdom-story-get space "S-3"))
    (rat-kingdom-story-start space "demo" "Live" nil "S-4")
    (rat-kingdom-board-show space)
    (let ((data (rat-kingdom-board-test--data)))
      (should (equal (rat-kingdom-board-test--column data "done") '("S-3")))
      (should (equal (rat-kingdom-board-test--column data "stopped") '("S-2")))
      (should (equal (rat-kingdom-board-test--column data "queued") '("S-4")))
      (should (equal (gethash "title" (gethash "done" (gethash "columns" data)))
                     "Done (1)"))
      (let ((card (gethash "S-3" (gethash "done" (gethash "cards" data)))))
        (should (equal (gethash "note" card) "Merged"))
        (should (eq (gethash "live" card) :false))))
    ;; Hiding Done and Stopped, and keeping to one repository.
    (setq rat-kingdom-board-test--sent nil)
    (rat-kingdom-board-filter (rat-kingdom-plan--obj "repo" "" "ended" :false))
    (let ((data (rat-kingdom-board-test--data)))
      (should-not (rat-kingdom-board-test--column data "done"))
      (should (eq (gethash "visible" (gethash "done" (gethash "columns" data)))
                  :false))
      (should (equal (rat-kingdom-board-test--column data "queued") '("S-4"))))
    (rat-kingdom-board-filter (rat-kingdom-plan--obj "repo" "other" "ended" t))
    (should-not (rat-kingdom-board-test--column (rat-kingdom-board-test--data)
                                                "queued"))))

;;;; Keeping it up to date

(ert-deftest rat-kingdom-board-test-updates-only-changed-stories ()
  ;; Every column is shown, so none is left out or brought back.
  (let ((rat-kingdom-board-hide-empty-columns nil))
    (rat-kingdom-board-test-with-stubs (space path)
      (rat-kingdom-story-start space "demo" "One" nil "S-1")
      (rat-kingdom-story-start space "demo" "Two" nil "S-2")
      (rat-kingdom-board-show space)
      (should (equal (rat-kingdom-board-test--column
                      (rat-kingdom-board-test--data) "queued")
                     '("S-1" "S-2")))
      (setq rat-kingdom-board-test--sent nil)
      ;; The change hook marks only the story that changed.
      (rat-kingdom-reaction-run space)
      (should (equal (sort (copy-sequence rat-kingdom-board--dirty) #'string<)
                     '("S-1" "S-2")))
      (rat-kingdom-board-flush)
      (should (equal (mapcar #'car (rat-kingdom-board-test--updates))
                     '("/cards/queued/S-1" "/cards/working/S-1"
                       "/cards/queued/S-2" "/cards/working/S-2"
                       "/columns/queued/title" "/columns/working/title")))
      (should (eq (cdr (car (rat-kingdom-board-test--updates))) 'absent))
      (should (equal (cdr (car (last (rat-kingdom-board-test--updates))))
                     "Working (2)"))
      ;; One story moves: only its paths are sent.
      (setq rat-kingdom-board-test--sent nil)
      (rat-kingdom-story-move space "S-2" "blocked" "Not now")
      (rat-kingdom-reaction-run space)
      (should (equal rat-kingdom-board--dirty '("S-2")))
      (rat-kingdom-board-flush)
      (should (equal (mapcar #'car (rat-kingdom-board-test--updates))
                     '("/cards/working/S-2" "/cards/stopped/S-2"
                       "/columns/working/title" "/columns/stopped/title")))
      ;; A story marked that did not change sends nothing.
      (setq rat-kingdom-board-test--sent nil)
      (rat-kingdom-board-mark "S-1")
      (should-not (rat-kingdom-board-flush))
      (should-not rat-kingdom-board-test--sent)
      ;; A change of the run, such as a name, changes the card in place.
      (rat-kingdom-run-update space "S-1.1" :name "Whiskers")
      (should (equal rat-kingdom-board--dirty '("S-1")))
      (rat-kingdom-board-flush)
      (should (equal (mapcar #'car (rat-kingdom-board-test--updates))
                     '("/cards/working/S-1")))
      (should (equal (gethash "name" (cdr (car (rat-kingdom-board-test--updates))))
                     "Whiskers-1"))
      ;; A cancelled story moves to Stopped.
      (setq rat-kingdom-board-test--sent nil)
      (rat-kingdom-story-cancel space "S-1")
      (rat-kingdom-board-flush)
      (should (equal (mapcar #'car (rat-kingdom-board-test--updates))
                     '("/cards/working/S-1" "/cards/stopped/S-1"
                       "/columns/working/title" "/columns/stopped/title"))))))

(ert-deftest rat-kingdom-board-test-not-shown-not-followed ()
  (rat-kingdom-board-test-with-stubs (space path)
    (rat-kingdom-story-start space "demo" "One" nil "S-1")
    (should-not rat-kingdom-board--dirty)
    (should-not rat-kingdom-board--timer)))

(ert-deftest rat-kingdom-board-test-throttle ()
  (rat-kingdom-board-test-with-stubs (space path)
    (let* ((now 100.0)
           (scheduled nil)
           (rat-kingdom-board-interval 0.5)
           (rat-kingdom-board--now (lambda () now)))
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (delay _repeat function &rest _)
                   (push (cons delay function) scheduled)
                   'timer)))
        (setq rat-kingdom-board--space space
              rat-kingdom-board--last 99.8)
        ;; The first change waits out the rest of the interval.
        (rat-kingdom-board-mark "S-1")
        (should (equal (length scheduled) 1))
        (should (< (abs (- (car (car scheduled)) 0.3)) 1e-6))
        (should (eq (cdr (car scheduled)) #'rat-kingdom-board-flush))
        ;; More changes before it ends join the same update.
        (rat-kingdom-board-mark "S-2")
        (rat-kingdom-board-mark "S-1")
        (should (equal (length scheduled) 1))
        (should (equal rat-kingdom-board--dirty '("S-2" "S-1")))
        (setq now 100.3)
        (rat-kingdom-board-flush)
        (should-not rat-kingdom-board--dirty)
        (should (= rat-kingdom-board--last 100.3))
        ;; A change just after an update waits a whole interval.
        (setq now 100.4)
        (rat-kingdom-board-mark "S-1")
        (should (equal (length scheduled) 2))
        (should (< (abs (- (car (car scheduled)) 0.4)) 1e-6))
        ;; One long after goes at once.
        (setq rat-kingdom-board--timer nil
              now 200.0)
        (rat-kingdom-board-mark "S-1")
        (should (equal (car (car scheduled)) 0))
        (setq rat-kingdom-board--timer nil)))))

;;;; Fitting the window

(ert-deftest rat-kingdom-board-test-width-of-the-window-showing-it ()
  ;; The board is measured in the window that shows it, not in the
  ;; selected one, such as the king's shell when it calls board_show.
  (let ((buffer (generate-new-buffer " *board*"))
        (rat-kingdom-board--buffer nil))
    (unwind-protect
        (save-window-excursion
          (delete-other-windows)
          (let* ((selected (selected-window))
                 (board (split-window-right 30)))
            (should-not (rat-kingdom-board--window-width))
            (set-window-buffer board buffer)
            (setq rat-kingdom-board--buffer buffer)
            (should (eq (selected-window) selected))
            (should (/= (window-width selected) (window-width board)))
            (should (= (rat-kingdom-board--window-width) (window-width board)))
            ;; Not shown, it has no width.
            (set-window-buffer board (get-buffer-create "*scratch*"))
            (should-not (rat-kingdom-board--window-width))))
      (kill-buffer buffer))))

(ert-deftest rat-kingdom-board-test-hides-empty-columns ()
  (rat-kingdom-board-test-with-stubs (space path)
    (rat-kingdom-story-start space "demo" "One" nil "S-1")
    ;; Only Queued holds a card: it alone is shown, and has the room.
    (let ((rat-kingdom-board-hide-empty-columns t))
      (rat-kingdom-board-show space)
      (should (equal (rat-kingdom-board-test--board) '("Row" "column-queued")))
      (should (eq rat-kingdom-board--layout 'row))
      (let ((data (rat-kingdom-board-test--data)))
        (should (equal (gethash "legend" data)
                       "Working 0 · Checking 0 · Review 0 · Merging 0 · \
Done 0 · Stopped 0"))
        (should (eq (gethash "hasLegend" data) t))
        (should (eq (gethash "visible" (gethash "working" (gethash "columns" data)))
                    :false))))
    ;; Off, every column is shown, and in 80 characters they are stacked.
    (let ((rat-kingdom-board-hide-empty-columns nil))
      (setq rat-kingdom-board-test--sent nil)
      (rat-kingdom-board-show space)
      (should (equal (rat-kingdom-board-test--board)
                     (cons "Column"
                           (mapcar (lambda (column) (format "column-%s" (car column)))
                                   rat-kingdom-board-columns))))
      (should (eq rat-kingdom-board--layout 'stacked))
      (let ((data (rat-kingdom-board-test--data)))
        (should (equal (gethash "legend" data) ""))
        (should (eq (gethash "hasLegend" data) :false))))))

(ert-deftest rat-kingdom-board-test-column-emptied-draws-again ()
  (rat-kingdom-board-test-with-stubs (space path)
    (let ((rat-kingdom-board-hide-empty-columns t))
      (rat-kingdom-story-start space "demo" "One" nil "S-1")
      (rat-kingdom-board-show space)
      (should (equal (rat-kingdom-board-test--board) '("Row" "column-queued")))
      (setq rat-kingdom-board-test--sent nil)
      ;; Queued is emptied and Working filled: the board is drawn again.
      (rat-kingdom-reaction-run space)
      (rat-kingdom-board-flush)
      (should (equal (rat-kingdom-board-test--board) '("Row" "column-working")))
      (should (equal (rat-kingdom-board-test--column
                      (rat-kingdom-board-test--data) "working")
                     '("S-1")))
      (should (string-search "Queued 0"
                             (gethash "legend" (rat-kingdom-board-test--data))))
      ;; A change that keeps the columns is sent alone.
      (setq rat-kingdom-board-test--sent nil)
      (rat-kingdom-run-update space "S-1.1" :name "Whiskers")
      (rat-kingdom-board-flush)
      (should (equal (mapcar #'car (rat-kingdom-board-test--updates))
                     '("/cards/working/S-1"))))))

(ert-deftest rat-kingdom-board-test-relayout-on-resize ()
  (rat-kingdom-board-test-with-stubs (space path)
    (let ((rat-kingdom-board-hide-empty-columns nil)
          (rat-kingdom-board-column-width 32)
          (rat-kingdom-board-min-column-width 18)
          (scheduled nil))
      (rat-kingdom-story-start space "demo" "One" nil "S-1")
      (rat-kingdom-board-show space)
      (should (eq rat-kingdom-board--layout 'stacked))
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (_delay _repeat function &rest _)
                   (push function scheduled)
                   'timer)))
        ;; The window grows: one layout is scheduled, however often
        ;; the hook runs before it.
        (setq rat-kingdom-board-test--width 185
              rat-kingdom-board-test--sent nil)
        (rat-kingdom-board--resized (selected-window))
        (rat-kingdom-board--resized (selected-window))
        (should (equal scheduled '(rat-kingdom-board-relayout)))
        (should-not rat-kingdom-board-test--sent)
        (should (rat-kingdom-board-relayout))
        (should-not rat-kingdom-board--relayout-timer)
        (should (eq rat-kingdom-board--layout 'row))
        (should (= rat-kingdom-board--column-width 26))
        (should (equal (car (rat-kingdom-board-test--board)) "Row"))
        ;; The same width again changes nothing.
        (setq rat-kingdom-board-test--sent nil)
        (should-not (rat-kingdom-board-relayout))
        (should-not rat-kingdom-board-test--sent)
        ;; It shrinks below seven columns of 18: stacked again.
        (setq rat-kingdom-board-test--width 125)
        (rat-kingdom-board--resized (selected-window))
        (should (= (length scheduled) 2))
        (should (rat-kingdom-board-relayout))
        (should (eq rat-kingdom-board--layout 'stacked))
        (should (equal (car (rat-kingdom-board-test--board)) "Column"))
        ;; Not shown, it is left as it is.
        (setq rat-kingdom-board-test--width nil
              rat-kingdom-board-test--sent nil)
        (should-not (rat-kingdom-board-relayout))
        (should-not rat-kingdom-board-test--sent)))))

(ert-deftest rat-kingdom-board-test-card-fits-its-column ()
  (rat-kingdom-board-test-with-stubs (space path)
    (let ((rat-kingdom-board-hide-empty-columns nil)
          (rat-kingdom-board-column-width 32)
          (rat-kingdom-board-min-column-width 18))
      (rat-kingdom-story-start space "demo" (make-string 100 ?x) nil "S-1"
                               nil nil nil "T-7")
      (cl-flet ((card ()
                  (gethash "S-1" (gethash "queued" (gethash "cards"
                                                            (rat-kingdom-board-test--data)))))
                (buttons ()
                  (gethash "component"
                           (gethash "card-buttons"
                                    (rat-kingdom-board-test--components)))))
        ;; Seven columns of 18: every line of a card has 16 characters.
        (setq rat-kingdom-board-test--width 126)
        (rat-kingdom-board-show space)
        (should (eq rat-kingdom-board--layout 'row))
        (dolist (key '("title" "detail"))
          (should (= (string-width (gethash key (card))) 16)))
        (should (equal (gethash "heading" (card)) "**S-1** · epic T-7"))
        (should (equal (rat-kingdom-board--heading "S-3a9c" "Pip-3a9c" "T-7" 16)
                       "**S-3a9c** · Pip-3a…"))
        ;; The buttons go two to a line.
        (should (equal (buttons) "Column"))
        ;; Stacked, a card has the whole title width, buttons on one line.
        (setq rat-kingdom-board-test--width 80
              rat-kingdom-board-test--sent nil)
        (rat-kingdom-board-show space)
        (should (eq rat-kingdom-board--layout 'stacked))
        (should (= (string-width (gethash "title" (card)))
                   rat-kingdom-board-title-width))
        (should (equal (gethash "heading" (card)) "**S-1** · epic T-7"))
        (should (equal (buttons) "Row"))))))

;;;; The buttons

(ert-deftest rat-kingdom-board-test-actions-dispatch ()
  (rat-kingdom-board-test-with-stubs (space path)
    (rat-kingdom-story-start space "demo" "One" nil "S-1")
    (rat-kingdom-board-show space)
    (let (calls)
      (cl-letf (((symbol-function 'rat-kingdom-board-open-worker)
                 (lambda (space id) (push (list 'open space id) calls)))
                ((symbol-function 'rat-kingdom-board-show-story)
                 (lambda (space id) (push (list 'show space id) calls)))
                ((symbol-function 'rat-kingdom-board-show-diff)
                 (lambda (space id) (push (list 'diff space id) calls)))
                ((symbol-function 'rat-kingdom-board-cancel)
                 (lambda (space id) (push (list 'cancel space id) calls))))
        (dolist (name '("open" "show" "diff" "cancel"))
          (rat-kingdom-board-test--press name "S-1"))
        ;; There is no verdict button.
        (rat-kingdom-board-test--press "verdict" "S-1")
        (should (equal (reverse calls)
                       (list (list 'open space "S-1") (list 'show space "S-1")
                             (list 'diff space "S-1")
                             (list 'cancel space "S-1"))))))))

(ert-deftest rat-kingdom-board-test-cancel-asks ()
  (rat-kingdom-board-test-with-stubs (space path)
    (rat-kingdom-story-start space "demo" "One" nil "S-1")
    (rat-kingdom-board-show space)
    (let (cancelled)
      (cl-letf (((symbol-function 'rat-kingdom-story-cancel)
                 (lambda (_space id &rest _)
                   (push id cancelled)
                   (format "Cancelled %s." id))))
        (cl-letf (((symbol-function 'yes-or-no-p) #'ignore))
          (rat-kingdom-board-test--press "cancel" "S-1"))
        (should-not cancelled)
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (_prompt) t)))
          (rat-kingdom-board-test--press "cancel" "S-1"))
        (should (equal cancelled '("S-1")))
        (should (member '("/result" . "Cancelled S-1.")
                        (rat-kingdom-board-test--updates)))))))

(ert-deftest rat-kingdom-board-test-show-story-and-diff ()
  (rat-kingdom-board-test-with-stubs (space path)
    (rat-kingdom-story-start space "demo" "One" nil "S-1")
    (rat-kingdom-reaction-run space)
    (save-window-excursion
      (rat-kingdom-board-test--press "show" "S-1")
      (with-current-buffer "*rat-kingdom story S-1*"
        (should (string-search "S-1" (buffer-string)))
        (should (derived-mode-p 'special-mode)))
      (rat-kingdom-board-test--press "diff" "S-1")
      (with-current-buffer "*rat-kingdom diff S-1*"
        (should (derived-mode-p 'diff-mode)))
      ;; The worker's buffer is the run's handle.
      (let ((buffer (generate-new-buffer "rat S-1.1")))
        (puthash "S-1.1" buffer rat-kingdom-run--handles)
        (rat-kingdom-board-test--press "open" "S-1")
        (should (eq (window-buffer (selected-window)) buffer))
        (kill-buffer buffer)))
    (kill-buffer "*rat-kingdom story S-1*")
    (kill-buffer "*rat-kingdom diff S-1*")))

(ert-deftest rat-kingdom-board-test-error-is-shown ()
  (rat-kingdom-board-test-with-stubs (space path)
    (rat-kingdom-story-start space "demo" "One" nil "S-1")
    (rat-kingdom-board-show space)
    (rat-kingdom-board-test--press "open" "S-1")
    (should (equal (assoc "/resultTone" (rat-kingdom-board-test--updates))
                   '("/resultTone" . "error")))
    (should (string-search "has no worker running"
                           (cdr (assoc "/result"
                                       (rat-kingdom-board-test--updates)))))))

;;;; Without a2ui, and the king's tool

(ert-deftest rat-kingdom-board-test-board-show-tool ()
  (rat-kingdom-board-test-with-stubs (space path)
    (rat-kingdom-king-test--start space)
    (rat-kingdom-story-start space "demo" "One" nil "S-1")
    (should (string-search
             "the story board for all repositories, with 1 stories"
             (rat-kingdom-king-test--ok "board_show")))
    (should (eq rat-kingdom-board--space space))
    (cl-letf (((symbol-function 'rat-kingdom-plan-a2ui-p) #'ignore))
      (let ((answer (rat-kingdom-king-test--call "board_show")))
        (should (cdr answer))
        (should (string-search "a2ui is not installed" (car answer))))
      (should-error (rat-kingdom-board) :type 'error))))

(defun rat-kingdom-board-test--add-repo (space path name)
  "Register a second repository NAME in SPACE, beside the one at PATH."
  (let ((other (expand-file-name (format "../%s/" name) path)))
    (make-directory other)
    (rat-kingdom-story-test--git other "init" "-q" "-b" "main")
    (rat-kingdom-story-test--git other "config" "user.name" "Test")
    (rat-kingdom-story-test--git other "config" "user.email" "test@example.com")
    (rat-kingdom-story-test--commit other "README" "other\n" "Initial commit")
    (rat-kingdom-repo-add space other)))

(defun rat-kingdom-board-test--picker ()
  "Return the value of the repository picker in the data model last sent."
  (gethash "repo" (gethash "filter" (rat-kingdom-board-test--data))))

(defun rat-kingdom-board-test--shown-ids ()
  "Return the ids of every card in the data model last sent, sorted."
  (let ((data (rat-kingdom-board-test--data)))
    (sort (cl-loop for (column . _) in rat-kingdom-board-columns
                   append (rat-kingdom-board-test--column
                           data (symbol-name column)))
          #'string<)))

(ert-deftest rat-kingdom-board-test-board-show-repo ()
  (rat-kingdom-board-test-with-stubs (space path)
    (rat-kingdom-board-test--add-repo space path "other")
    (rat-kingdom-king-test--start space)
    (rat-kingdom-story-start space "demo" "One" nil "S-1")
    (rat-kingdom-story-start space "other" "Two" nil "S-2")
    ;; With a repository, the picker is set to it and only its stories show.
    (should (string-search
             "the story board for the repository demo, with 1 stories"
             (rat-kingdom-king-test--ok "board_show" '(repo . "demo"))))
    (should (equal (rat-kingdom-board-test--picker) "demo"))
    (should (equal (rat-kingdom-board-test--shown-ids) '("S-1")))
    ;; The board is open: without a repository, it keeps its own.
    (setq rat-kingdom-board-test--sent nil)
    (should (string-search "for the repository demo"
                           (rat-kingdom-king-test--ok "board_show")))
    (should (equal (rat-kingdom-board-test--picker) "demo"))
    ;; Opened again with another repository, the picker follows.
    (should (string-search
             "for the repository other"
             (rat-kingdom-king-test--ok "board_show" '(repo . "other"))))
    (should (equal (rat-kingdom-board-test--picker) "other"))
    (should (equal (rat-kingdom-board-test--shown-ids) '("S-2")))
    ;; all shows every repository, and the picker is blank.
    (should (string-search
             "the story board for all repositories, with 2 stories"
             (rat-kingdom-king-test--ok "board_show" '(all . t))))
    (should (equal (rat-kingdom-board-test--picker) ""))
    (should (equal (rat-kingdom-board-test--shown-ids) '("S-1" "S-2")))
    ;; The check box is not changed.
    (rat-kingdom-board-filter (rat-kingdom-plan--obj "repo" "" "ended" :false))
    (rat-kingdom-king-test--ok "board_show" '(repo . "demo"))
    (should (equal rat-kingdom-board--filter '(:repo "demo" :ended nil)))
    ;; A board that is not open shows all repositories.
    (rat-kingdom-board--stop)
    (should (string-search "for all repositories"
                           (rat-kingdom-king-test--ok "board_show")))
    (should (equal (rat-kingdom-board-test--picker) ""))))

(ert-deftest rat-kingdom-board-test-board-show-unknown-repo ()
  (rat-kingdom-board-test-with-stubs (space path)
    (rat-kingdom-board-test--add-repo space path "other")
    (rat-kingdom-king-test--start space)
    (let ((answer (rat-kingdom-king-test--call "board_show" '(repo . "nope"))))
      (should (cdr answer))
      (should (string-search "There is no repository named nope" (car answer)))
      (should (string-search "The registered repositories are: demo, other"
                             (car answer)))
      (should (string-search "Nothing was shown" (car answer))))
    (let ((answer (rat-kingdom-king-test--call "board_show" '(repo . "demo")
                                               '(all . t))))
      (should (cdr answer))
      (should (string-search "not both" (car answer))))
    ;; Nothing was shown.
    (should-not rat-kingdom-board-test--sent)
    (should-not rat-kingdom-board--space)
    (should (equal rat-kingdom-board--filter '(:repo nil :ended t)))
    ;; The same from Lisp, and an open board keeps its repository.
    (rat-kingdom-board-open space "demo")
    (setq rat-kingdom-board-test--sent nil)
    (should-error (rat-kingdom-board-open space "nope") :type 'user-error)
    (should-not rat-kingdom-board-test--sent)
    (should (equal (plist-get rat-kingdom-board--filter :repo) "demo"))))

(ert-deftest rat-kingdom-board-test-command-asks-for-a-repo ()
  (rat-kingdom-board-test-with-stubs (space path)
    (rat-kingdom-board-test--add-repo space path "other")
    (rat-kingdom-story-start space "demo" "One" nil "S-1")
    (rat-kingdom-story-start space "other" "Two" nil "S-2")
    (let* ((answer "other")
           collection
           (current-prefix-arg '(4)))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt names &rest _)
                   (setq collection names)
                   answer)))
        (call-interactively #'rat-kingdom-board)
        (should (equal (sort (copy-sequence collection) #'string<)
                       '("demo" "other")))
        (should (equal (rat-kingdom-board-test--picker) "other"))
        (should (equal (rat-kingdom-board-test--shown-ids) '("S-2")))
        ;; Without a prefix argument, the open board keeps its repository.
        (let ((current-prefix-arg nil))
          (setq collection 'not-asked)
          (call-interactively #'rat-kingdom-board)
          (should (eq collection 'not-asked))
          (should (equal (rat-kingdom-board-test--picker) "other")))
        ;; A blank answer shows all repositories.
        (setq answer "")
        (call-interactively #'rat-kingdom-board)
        (should (equal (rat-kingdom-board-test--picker) ""))
        (should (equal (rat-kingdom-board-test--shown-ids) '("S-1" "S-2")))))))

(ert-deftest rat-kingdom-board-test-loading-does-not-need-a2ui ()
  (let* ((directory (rat-kingdom--directory))
         (output
          (with-temp-buffer
            (call-process
             (expand-file-name invocation-name invocation-directory) nil t nil
             "-Q" "--batch" "-L" directory
             "--eval"
             "(progn (setq load-path (seq-remove (lambda (dir) \
(string-search \"a2ui\" dir)) load-path)) (require 'rat-kingdom) \
(princ (format \"loaded:%s a2ui:%s \" (featurep 'rat-kingdom-board) \
(featurep 'a2ui))) \
(princ (condition-case err (rat-kingdom-board) \
(error (error-message-string err)))))")
            (buffer-string))))
    (should (string-search "loaded:t a2ui:nil" output))
    (should (string-search "The story board needs a2ui" output))))

(ert-deftest rat-kingdom-board-test-reload ()
  (rat-kingdom-reload-test--isolated
    (let ((a2ui (featurep 'a2ui)))
      (rat-kingdom-reload)
      (rat-kingdom-reload)
      (should (member "rat-kingdom-board" rat-kingdom--files))
      (should (eql (cl-count "board_show" rat-kingdom-mcp--tools
                             :key (lambda (tool) (plist-get tool :name))
                             :test #'equal)
                   1))
      (should (eql (cl-count #'rat-kingdom-board--on-change
                             (default-value 'rat-kingdom-space-change-functions))
                   1))
      (should (eq (featurep 'a2ui) a2ui)))))

;;;; With the real a2ui

(declare-function a2ui-surface-refresh "a2ui-vui" (&rest _))

(defun rat-kingdom-board-test--text ()
  "Return the text of the board's buffer, once a2ui has drawn it."
  (with-current-buffer "*a2ui: Story board*"
    (a2ui-surface-refresh)
    ;; a2ui draws on a timer.
    (accept-process-output nil 0.1)
    (buffer-string)))

(ert-deftest rat-kingdom-board-test-a2ui ()
  (skip-unless (rat-kingdom-plan-a2ui-p))
  (rat-kingdom-story-test-with-repo (space path)
    (let ((rat-kingdom-space-change-functions
           (list #'rat-kingdom-board--on-change))
          (rat-kingdom-board--cards (make-hash-table :test #'equal))
          (rat-kingdom-board--space nil)
          (rat-kingdom-board--session nil)
          (rat-kingdom-board--filter (list :repo nil :ended t))
          (rat-kingdom-board--layout 'stacked)
          (rat-kingdom-board--column-width rat-kingdom-board-column-width)
          (rat-kingdom-board--shown nil)
          (rat-kingdom-board--width nil)
          (rat-kingdom-board--buffer nil)
          (rat-kingdom-board--relayout-timer nil)
          (rat-kingdom-board--dirty nil)
          (rat-kingdom-board--timer nil)
          (rat-kingdom-board--tick-timer nil)
          (rat-kingdom-board--last 0)
          (rat-kingdom-board-hide-empty-columns t))
      (unwind-protect
          (save-window-excursion
            (rat-kingdom-story-start space "demo" "One" nil "S-1")
            (let ((before (selected-window)))
              (rat-kingdom-board)
              ;; It took the place of the selected window's buffer.
              (should (eq (selected-window) before))
              (should (equal (buffer-name (window-buffer before))
                             "*a2ui: Story board*")))
            (with-current-buffer "*a2ui: Story board*"
              (should rat-kingdom-board-mode)
              (should (eq (key-binding "q") #'quit-window)))
            (should (string-search "Queued (1)" (rat-kingdom-board-test--text)))
            (rat-kingdom-reaction-run space)
            (rat-kingdom-board-flush)
            (let ((text (rat-kingdom-board-test--text)))
              (should (string-search "Working (1)" text))
              ;; Queued, now empty, is left out and named below the filters.
              (should-not (string-search "Queued (" text))
              (should (string-search "Queued 0 · Checking 0" text))
              (should (string-search "S-1 · Pip-1" text))))
        (rat-kingdom-board--stop)
        (when (get-buffer "*a2ui: Story board*")
          (kill-buffer "*a2ui: Story board*"))))))

(provide 'rat-kingdom-board-test)
;;; rat-kingdom-board-test.el ends here
