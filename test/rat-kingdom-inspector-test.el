;;; rat-kingdom-inspector-test.el --- Tests for the inspector -*- lexical-binding: t; -*-

;;; Commentary:

;; Batch tests for the space inspector.

;;; Code:

(require 'ert)
(require 'rat-kingdom-inspector)

(defvar rat-kingdom-inspector-test--now 1000.0
  "The time the space sees during a test.")

(defmacro rat-kingdom-inspector-test-with-space (var &rest body)
  "Run BODY with VAR bound to a fresh space and its inspector current."
  (declare (indent 1) (debug t))
  (let ((file (make-symbol "file")))
    `(let* ((,file (make-temp-file "rat-kingdom-inspector-test" nil ".db"))
            (rat-kingdom-inspector-test--now 1000.0)
            (rat-kingdom-space-now-function
             (lambda () rat-kingdom-inspector-test--now))
            (rat-kingdom-space-change-functions nil)
            (,var (rat-kingdom-space-open ,file)))
       (unwind-protect
           (save-window-excursion
             (rat-kingdom-inspect ,var)
             (unwind-protect
                 (progn ,@body)
               (kill-buffer (current-buffer))))
         (rat-kingdom-space-close ,var)
         (dolist (suffix '("" "-wal" "-shm"))
           (ignore-errors (delete-file (concat ,file suffix))))))))

(defun rat-kingdom-inspector-test--rows ()
  "Return the rows the current inspector buffer shows, as lists."
  (mapcar (lambda (entry) (append (cadr entry) nil)) tabulated-list-entries))

(defun rat-kingdom-inspector-test--goto (id)
  "Move point to the row with ID."
  (goto-char (point-min))
  (while (and (not (eobp)) (not (eql (tabulated-list-get-id) id)))
    (forward-line 1))
  (should (eql (tabulated-list-get-id) id)))

(ert-deftest rat-kingdom-inspector-test-age ()
  (should (equal (rat-kingdom-inspector--age 100 100) "0s"))
  (should (equal (rat-kingdom-inspector--age 100 159.9) "59s"))
  (should (equal (rat-kingdom-inspector--age 100 160) "1m"))
  (should (equal (rat-kingdom-inspector--age 0 7200) "2h"))
  (should (equal (rat-kingdom-inspector--age 0 (* 3 86400)) "3d"))
  (should (equal (rat-kingdom-inspector--age 100 50) "0s")))

(ert-deftest rat-kingdom-inspector-test-lists-tuples ()
  (rat-kingdom-inspector-test-with-space space
    (should (derived-mode-p 'rat-kingdom-inspector-mode))
    (should-not tabulated-list-entries)
    (should (string-search "empty" mode-line-process))
    (rat-kingdom-space-out space 'story :scope "repo" :identity "S-1"
                           :owner "S-1" :payload '(:at ready))
    (setq rat-kingdom-inspector-test--now 1090.0)
    (rat-kingdom-space-out space 'fact :scope "repo" :identity "ci")
    (revert-buffer)
    (should (equal (rat-kingdom-inspector-test--rows)
                   '(("1" "story" "repo" "S-1" "lin" "S-1" "1m"
                      "(:at \"ready\")")
                     ("2" "fact" "repo" "ci" "per" "" "0s" ""))))
    (should (string-search "fact:1 story:1" mode-line-process))
    (should (string-search "S-1" (buffer-string)))))

(ert-deftest rat-kingdom-inspector-test-narrows-to-a-pattern ()
  (rat-kingdom-inspector-test-with-space space
    (rat-kingdom-space-out space 'fact :scope "a" :identity "1")
    (rat-kingdom-space-out space 'fact :scope "b" :identity "2")
    (rat-kingdom-space-out space 'doc :scope "a" :identity "3")
    (rat-kingdom-inspector-narrow '(_ :scope "a"))
    (should (equal (mapcar #'car tabulated-list-entries) '(1 3)))
    (should (string-search "/ (_ :scope \"a\")" mode-line-process))
    ;; The counts are of the whole space, not of what is shown.
    (should (string-search "doc:1 fact:2" mode-line-process))
    (should-error (rat-kingdom-inspector-narrow '(:scope "a")))
    (rat-kingdom-inspector-narrow nil)
    (should (equal (mapcar #'car tabulated-list-entries) '(1 2 3)))))

(ert-deftest rat-kingdom-inspector-test-log-and-archive-views ()
  (rat-kingdom-inspector-test-with-space space
    (rat-kingdom-space-out space 'available :scope "repo" :identity "T-1"
                           :owner "E" :actor "adapter")
    (rat-kingdom-space-out space 'available :scope "repo" :identity "T-2"
                           :owner "E")
    (rat-kingdom-space-in space '(available) :actor "engine")
    (rat-kingdom-inspector-log)
    (should (equal (mapcar (lambda (row) (list (nth 0 row) (nth 1 row)
                                               (nth 5 row) (nth 6 row)))
                           (rat-kingdom-inspector-test--rows))
                   '(("3" "in" "T-1" "engine")
                     ("2" "out" "T-2" "")
                     ("1" "out" "T-1" "adapter"))))
    (rat-kingdom-space-sweep space "E")
    (rat-kingdom-inspector-archive)
    (should (equal (mapcar (lambda (row) (list (nth 1 row) (nth 4 row)))
                           (rat-kingdom-inspector-test--rows))
                   '(("sweep" "T-2"))))
    (should-error (rat-kingdom-inspector-retract))
    (rat-kingdom-inspector-tuples)
    (should-not tabulated-list-entries)))

(ert-deftest rat-kingdom-inspector-test-retract-asks-first ()
  (rat-kingdom-inspector-test-with-space space
    (rat-kingdom-space-out space 'fact :identity "keep")
    (rat-kingdom-space-out space 'fact :identity "drop")
    (revert-buffer)
    (rat-kingdom-inspector-test--goto 2)
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) nil)))
      (rat-kingdom-inspector-retract))
    (should (eql (length (rat-kingdom-space-scan space '(fact))) 2))
    (rat-kingdom-inspector-test--goto 2)
    (cl-letf (((symbol-function 'y-or-n-p) (lambda (&rest _) t)))
      (rat-kingdom-inspector-retract))
    (should (equal (mapcar #'car tabulated-list-entries) '(1)))
    (should (equal (plist-get (car (last (rat-kingdom-space-ops space))) :actor)
                   "inspector"))
    (goto-char (point-max))
    (should-error (rat-kingdom-inspector-retract))))

(ert-deftest rat-kingdom-inspector-test-out-form ()
  (should (equal (rat-kingdom-inspector--out-arguments
                  '(event :scope "repo" :identity "push" :ttl 60
                          :kind push :branch "main"))
                 '(event :scope "repo" :identity "push" :ttl 60
                         :payload (:kind push :branch "main"))))
  (should (equal (rat-kingdom-inspector--out-arguments '(fact))
                 '(fact :payload nil)))
  (should-error (rat-kingdom-inspector--out-arguments '(fact :scope $repo)))
  (should-error (rat-kingdom-inspector--out-arguments '(fact :scope)))
  (rat-kingdom-inspector-test-with-space space
    (rat-kingdom-inspector-out '(fact :scope "repo" :identity "ci" :slow t))
    (should (equal (rat-kingdom-inspector-test--rows)
                   '(("1" "fact" "repo" "ci" "per" "" "0s" "(:slow t)"))))
    (should-error (rat-kingdom-inspector-out '(nonsense :identity "x")))))

(ert-deftest rat-kingdom-inspector-test-show-row-in-full ()
  (rat-kingdom-inspector-test-with-space space
    (rat-kingdom-space-out space 'result :scope "repo" :identity "S-1"
                           :payload '(:commit "abc123" :summary "Done"))
    (revert-buffer)
    (rat-kingdom-inspector-test--goto 1)
    (rat-kingdom-inspector-show)
    (with-current-buffer "*rat-kingdom tuple*"
      (should (string-search ":category  result" (buffer-string)))
      (should (string-search ":commit \"abc123\"" (buffer-string))))
    (kill-buffer "*rat-kingdom tuple*")))

(ert-deftest rat-kingdom-inspector-test-follows-changes ()
  (rat-kingdom-inspector-test-with-space space
    (let ((buffer (current-buffer)))
      ;; Opening a second time reuses the buffer.
      (should (eq (rat-kingdom-inspect space) buffer))
      (rat-kingdom-space-out space 'fact :identity "new")
      (should rat-kingdom-inspector--timer)
      (should-not tabulated-list-entries)
      (rat-kingdom-inspector--reread)
      (should (equal (mapcar #'car tabulated-list-entries) '(1)))
      (should-not rat-kingdom-inspector--timer))))

(provide 'rat-kingdom-inspector-test)
;;; rat-kingdom-inspector-test.el ends here
