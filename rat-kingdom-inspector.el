;;; rat-kingdom-inspector.el --- Look inside a tuplespace -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Chaz Straney

;; Author: Chaz Straney <chaz.straney@gmail.com>
;; SPDX-License-Identifier: GPL-3.0-or-later

;; This file is not part of GNU Emacs.

;;; Commentary:

;; M-x rat-kingdom-inspect lists what is in a space.  Three views:
;;
;;   t  the live tuples, oldest first
;;   l  the operations log, newest first
;;   A  the archive, newest first
;;
;; In the tuple view, / narrows to a pattern such as
;; (result :scope "myrepo" :commit $c); an empty answer shows everything
;; again.  RET shows the row at point in full.  d retracts the tuple at
;; point and + writes one, both after asking.  g re-reads the space.
;;
;; The list re-reads itself after each change this Emacs makes to the
;; space.  Tuples written by another process appear on the next g, or
;; when a poll for reactions notices them.
;;
;; The mode line counts the live tuples in each category.

;;; Code:

(require 'cl-lib)
(require 'subr-x)
(require 'tabulated-list)
(require 'rat-kingdom-space)

(defgroup rat-kingdom-inspector nil
  "Look inside a tuplespace."
  :group 'rat-kingdom
  :prefix "rat-kingdom-inspector-")

(defcustom rat-kingdom-inspector-log-limit 500
  "Most entries the log and archive views show."
  :type 'integer)

(defvar-local rat-kingdom-inspector--space nil
  "The space this buffer shows.")

(defvar-local rat-kingdom-inspector--view 'tuples
  "What this buffer lists: `tuples', `log' or `archive'.")

(defvar-local rat-kingdom-inspector--pattern nil
  "The pattern the tuple view is narrowed to, or nil.")

(defvar-local rat-kingdom-inspector--rows nil
  "Hash table from row id to the tuple or log entry shown there.")

;;;; Rows

(defun rat-kingdom-inspector--age (then now)
  "Return how long ago THEN was at NOW, as short text."
  (let ((seconds (max 0 (- now then))))
    (cond ((< seconds 60) (format "%ds" seconds))
          ((< seconds 3600) (format "%dm" (/ seconds 60)))
          ((< seconds 86400) (format "%dh" (/ seconds 3600)))
          (t (format "%dd" (/ seconds 86400))))))

(defun rat-kingdom-inspector--payload (payload)
  "Return PAYLOAD as one line of text."
  (if payload (prin1-to-string payload) ""))

(defconst rat-kingdom-inspector--formats
  `((tuples . [("Id" 6 rat-kingdom-inspector--by-id :right-align t)
               ("Category" 10 t) ("Scope" 12 t) ("Identity" 16 t)
               ("Mod" 4 t) ("Owner" 10 t) ("Age" 5 nil :right-align t)
               ("Payload" 0 nil)])
    (log . [("Op" 6 rat-kingdom-inspector--by-id :right-align t)
            ("What" 8 t) ("Tuple" 6 nil :right-align t)
            ("Category" 10 t) ("Scope" 12 t) ("Identity" 16 t)
            ("Actor" 14 t) ("Age" 5 nil :right-align t)
            ("Payload" 0 nil)])
    (archive . [("Id" 6 rat-kingdom-inspector--by-id :right-align t)
                ("Why" 7 t) ("Category" 10 t) ("Scope" 12 t)
                ("Identity" 16 t) ("Owner" 10 t)
                ("Gone" 5 nil :right-align t) ("Payload" 0 nil)]))
  "The columns of each view.")

(defun rat-kingdom-inspector--by-id (a b)
  "Return non-nil if row A has a smaller id than row B."
  (< (car a) (car b)))

(defun rat-kingdom-inspector--tuple-row (tuple now)
  "Return the row for TUPLE at time NOW."
  (list (plist-get tuple :id)
        (vector (number-to-string (plist-get tuple :id))
                (symbol-name (plist-get tuple :category))
                (plist-get tuple :scope)
                (or (plist-get tuple :identity) "")
                (substring (symbol-name (plist-get tuple :modality)) 0 3)
                (or (plist-get tuple :owner) "")
                (rat-kingdom-inspector--age (plist-get tuple :created) now)
                (rat-kingdom-inspector--payload (plist-get tuple :payload)))))

(defun rat-kingdom-inspector--log-row (id entry now)
  "Return the row numbered ID for log ENTRY at time NOW."
  (list id
        (vector (number-to-string id)
                (symbol-name (plist-get entry :op))
                (number-to-string (plist-get entry :tuple-id))
                (symbol-name (plist-get entry :category))
                (plist-get entry :scope)
                (or (plist-get entry :identity) "")
                (or (plist-get entry :actor) "")
                (rat-kingdom-inspector--age (plist-get entry :at) now)
                (rat-kingdom-inspector--payload (plist-get entry :payload)))))

(defun rat-kingdom-inspector--archive-row (tuple now)
  "Return the row for archived TUPLE at time NOW."
  (list (plist-get tuple :id)
        (vector (number-to-string (plist-get tuple :id))
                (symbol-name (plist-get tuple :reason))
                (symbol-name (plist-get tuple :category))
                (plist-get tuple :scope)
                (or (plist-get tuple :identity) "")
                (or (plist-get tuple :owner) "")
                (rat-kingdom-inspector--age (plist-get tuple :archived) now)
                (rat-kingdom-inspector--payload (plist-get tuple :payload)))))

(defun rat-kingdom-inspector--entries ()
  "Return the rows of this buffer's view, and remember what each shows."
  (let ((space rat-kingdom-inspector--space)
        (now (funcall rat-kingdom-space-now-function))
        (rows (make-hash-table))
        entries)
    (pcase rat-kingdom-inspector--view
      ('tuples
       (dolist (tuple (rat-kingdom-space-scan
                       space (or rat-kingdom-inspector--pattern '(_))))
         (puthash (plist-get tuple :id) tuple rows)
         (push (rat-kingdom-inspector--tuple-row tuple now) entries))
       (setq entries (nreverse entries)))
      ('log
       ;; The log has no ids of its own to show; number from the newest.
       (let* ((log (rat-kingdom-space-ops
                    space rat-kingdom-inspector-log-limit))
              (id (length log)))
         (dolist (entry (reverse log))
           (puthash id entry rows)
           (push (rat-kingdom-inspector--log-row id entry now) entries)
           (cl-decf id))
         (setq entries (nreverse entries))))
      ('archive
       (dolist (tuple (last (rat-kingdom-space-archived space)
                            rat-kingdom-inspector-log-limit))
         (puthash (plist-get tuple :id) tuple rows)
         (push (rat-kingdom-inspector--archive-row tuple now) entries))))
    (setq rat-kingdom-inspector--rows rows)
    entries))

(defun rat-kingdom-inspector--summary ()
  "Return the mode-line text: the view, the counts and the pattern."
  (let ((counts (rat-kingdom-space-counts rat-kingdom-inspector--space)))
    (concat
     (format " [%s] " rat-kingdom-inspector--view)
     (if counts
         (mapconcat (lambda (count) (format "%s:%d" (car count) (cdr count)))
                    counts " ")
       "empty")
     (and rat-kingdom-inspector--pattern
          (eq rat-kingdom-inspector--view 'tuples)
          (format "  / %S" rat-kingdom-inspector--pattern)))))

(defun rat-kingdom-inspector--refresh ()
  "Re-read the space into this buffer."
  (setq tabulated-list-format
        (alist-get rat-kingdom-inspector--view rat-kingdom-inspector--formats)
        tabulated-list-entries (rat-kingdom-inspector--entries)
        mode-line-process (rat-kingdom-inspector--summary))
  (tabulated-list-init-header))

;;;; Commands

(defun rat-kingdom-inspector--row-at-point ()
  "Return what the row at point shows, or signal an error."
  (or (and rat-kingdom-inspector--rows
           (gethash (tabulated-list-get-id) rat-kingdom-inspector--rows))
      (user-error "No row here")))

(defun rat-kingdom-inspector-show ()
  "Show the row at point in full."
  (interactive nil rat-kingdom-inspector-mode)
  (let ((row (rat-kingdom-inspector--row-at-point)))
    (with-help-window "*rat-kingdom tuple*"
      (with-current-buffer standard-output
        (let ((rest row))
          (while rest
            (insert (format "%-10s " (pop rest)))
            (let ((value (pop rest)))
              (if (and (consp value) (keywordp (car value)))
                  (insert "\n" (string-trim-right (pp-to-string value)) "\n")
                (insert (format "%S\n" value))))))))))

(defun rat-kingdom-inspector--set-view (view)
  "Switch this buffer to VIEW and re-read."
  (setq rat-kingdom-inspector--view view)
  (rat-kingdom-inspector--refresh)
  (tabulated-list-print))

(defun rat-kingdom-inspector-tuples ()
  "List the live tuples."
  (interactive nil rat-kingdom-inspector-mode)
  (rat-kingdom-inspector--set-view 'tuples))

(defun rat-kingdom-inspector-log ()
  "List the operations log, newest first."
  (interactive nil rat-kingdom-inspector-mode)
  (rat-kingdom-inspector--set-view 'log))

(defun rat-kingdom-inspector-archive ()
  "List the archived tuples, newest first."
  (interactive nil rat-kingdom-inspector-mode)
  (rat-kingdom-inspector--set-view 'archive))

(defun rat-kingdom-inspector-narrow (pattern)
  "Show only the tuples matching PATTERN; nil shows them all."
  (interactive
   (list (let ((text (read-string
                      "Pattern (empty for all): "
                      (and rat-kingdom-inspector--pattern
                           (prin1-to-string rat-kingdom-inspector--pattern)))))
           (and (not (string-blank-p text)) (read text))))
   rat-kingdom-inspector-mode)
  (when pattern
    (rat-kingdom-space--check-pattern pattern))
  (setq rat-kingdom-inspector--pattern pattern)
  (rat-kingdom-inspector--set-view 'tuples))

(defun rat-kingdom-inspector-retract ()
  "Remove the tuple at point from the space, after asking."
  (interactive nil rat-kingdom-inspector-mode)
  (unless (eq rat-kingdom-inspector--view 'tuples)
    (user-error "Only a live tuple can be retracted"))
  (let ((tuple (rat-kingdom-inspector--row-at-point)))
    (when (y-or-n-p (format "Retract %s %s? "
                            (plist-get tuple :category)
                            (or (plist-get tuple :identity)
                                (plist-get tuple :id))))
      (rat-kingdom-space-retract rat-kingdom-inspector--space
                                 (list '_ :id (plist-get tuple :id))
                                 :actor "inspector")
      (revert-buffer))))

(defun rat-kingdom-inspector--out-arguments (form)
  "Return arguments for `rat-kingdom-space-out' from FORM.
FORM is written like a pattern: a category, then `:scope',
`:identity', `:owner', `:modality' and `:ttl' for the tuple's fields,
and any other keyword for the payload."
  (rat-kingdom-space--check-pattern form)
  (let ((rest (cdr form))
        fields payload)
    (while rest
      (let ((key (pop rest))
            (value (pop rest)))
        (when (rat-kingdom-space--open-p value)
          (error "A tuple cannot hold the variable %s" value))
        (if (memq key '(:scope :identity :owner :modality :ttl))
            (setq fields (plist-put fields key value))
          (setq payload (append payload (list key value))))))
    (append (list (car form)) fields (list :payload payload))))

(defun rat-kingdom-inspector-out (form)
  "Write the tuple FORM describes to the space.
FORM is written like a pattern, for example
\(fact :scope \"myrepo\" :identity \"ci\" :slow t)."
  (interactive (list (read (read-string "Tuple: " "(fact :scope \"\" )")))
               rat-kingdom-inspector-mode)
  (apply #'rat-kingdom-space-out rat-kingdom-inspector--space
         (append (rat-kingdom-inspector--out-arguments form)
                 (list :actor "inspector")))
  (revert-buffer))

;;;; Mode

(defvar-keymap rat-kingdom-inspector-mode-map
  :doc "Keymap for `rat-kingdom-inspector-mode'."
  :parent tabulated-list-mode-map
  "RET" #'rat-kingdom-inspector-show
  "t" #'rat-kingdom-inspector-tuples
  "l" #'rat-kingdom-inspector-log
  "A" #'rat-kingdom-inspector-archive
  "/" #'rat-kingdom-inspector-narrow
  "d" #'rat-kingdom-inspector-retract
  "+" #'rat-kingdom-inspector-out)

(define-derived-mode rat-kingdom-inspector-mode tabulated-list-mode
  "Space"
  "List what is in a rat-kingdom tuplespace.
\\<rat-kingdom-inspector-mode-map>
\\[rat-kingdom-inspector-tuples] lists the live tuples, \
\\[rat-kingdom-inspector-log] the operations log and \
\\[rat-kingdom-inspector-archive] the archive.
\\[rat-kingdom-inspector-narrow] narrows the tuples to a pattern.
\\[rat-kingdom-inspector-show] shows the row at point in full.
\\[rat-kingdom-inspector-retract] retracts the tuple at point and \
\\[rat-kingdom-inspector-out] writes one.
\\[revert-buffer] re-reads the space."
  :interactive nil
  (setq tabulated-list-padding 1)
  (add-hook 'tabulated-list-revert-hook #'rat-kingdom-inspector--refresh nil t)
  (add-hook 'rat-kingdom-space-change-functions
            #'rat-kingdom-inspector--on-change))

(defvar rat-kingdom-inspector--timer nil
  "The timer for a pending re-read of the inspector buffers, if any.")

(defun rat-kingdom-inspector--buffers (&optional space)
  "Return the live inspector buffers, or only those showing SPACE."
  (cl-remove-if-not
   (lambda (buffer)
     (and (eq (buffer-local-value 'major-mode buffer)
              'rat-kingdom-inspector-mode)
          (or (null space)
              (eq (buffer-local-value 'rat-kingdom-inspector--space buffer)
                  space))))
   (buffer-list)))

(defun rat-kingdom-inspector--reread ()
  "Re-read every inspector buffer whose space is still open."
  (setq rat-kingdom-inspector--timer nil)
  (dolist (buffer (rat-kingdom-inspector--buffers))
    (with-current-buffer buffer
      (when (rat-kingdom-space-db rat-kingdom-inspector--space)
        (revert-buffer)))))

(defun rat-kingdom-inspector--on-change (space _op _subject)
  "Re-read the inspector buffers showing SPACE, once Emacs is idle."
  (if (null (rat-kingdom-inspector--buffers))
      (remove-hook 'rat-kingdom-space-change-functions
                   #'rat-kingdom-inspector--on-change)
    (when (and (rat-kingdom-inspector--buffers space)
               (not rat-kingdom-inspector--timer))
      (setq rat-kingdom-inspector--timer
            (run-with-idle-timer 0.2 nil #'rat-kingdom-inspector--reread)))))

;;;###autoload
(defun rat-kingdom-inspect (&optional space)
  "List what is in SPACE, by default the space rat-kingdom works in."
  (interactive)
  (let* ((space (or space (rat-kingdom-space-default)))
         (buffer (or (car (rat-kingdom-inspector--buffers space))
                     (generate-new-buffer "*rat-kingdom space*"))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'rat-kingdom-inspector-mode)
        (rat-kingdom-inspector-mode)
        (setq rat-kingdom-inspector--space space))
      (rat-kingdom-inspector--refresh)
      (tabulated-list-print t))
    (pop-to-buffer buffer)))

(provide 'rat-kingdom-inspector)
;;; rat-kingdom-inspector.el ends here
