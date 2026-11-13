;;; rat-kingdom-reaction-test.el --- Tests for reactions -*- lexical-binding: t; -*-

;;; Commentary:

;; Batch tests for reactions.  Each test gets its own database file and
;; an empty registry.

;;; Code:

(require 'ert)
(require 'rat-kingdom-reaction)

(defvar rat-kingdom-reaction-test--now 1000.0
  "The time the space sees during a test.")

(defmacro rat-kingdom-reaction-test-with-space (var &rest body)
  "Run BODY with VAR bound to a fresh space and no reactions defined."
  (declare (indent 1) (debug t))
  (let ((file (make-symbol "file")))
    `(let* ((,file (make-temp-file "rat-kingdom-reaction-test" nil ".db"))
            (rat-kingdom-reaction-test--now 1000.0)
            (rat-kingdom-space-now-function
             (lambda () rat-kingdom-reaction-test--now))
            (rat-kingdom-space-change-functions nil)
            (rat-kingdom-reaction--registry nil)
            (rat-kingdom-reaction--attachments nil)
            (inhibit-message t)
            (,var (rat-kingdom-space-open ,file)))
       (unwind-protect
           (progn ,@body)
         (rat-kingdom-reaction-detach ,var)
         (rat-kingdom-space-close ,var)
         (dolist (suffix '("" "-wal" "-shm"))
           (ignore-errors (delete-file (concat ,file suffix))))))))

(defun rat-kingdom-reaction-test--identities (space pattern)
  "Return the identities of the tuples in SPACE matching PATTERN."
  (mapcar (lambda (tuple) (plist-get tuple :identity))
          (rat-kingdom-space-scan space pattern)))

;;;; Defining

(ert-deftest rat-kingdom-reaction-test-define-and-replace ()
  (rat-kingdom-reaction-test-with-space _space
    (rat-kingdom-defreaction first "The first." :take (available) nil)
    (rat-kingdom-defreaction second :read ((doc) (fact)) nil)
    (rat-kingdom-defreaction first "Replaced." :take (review) nil)
    (should (equal (mapcar #'rat-kingdom-reaction-name
                           (rat-kingdom-reaction-list))
                   '(first second)))
    (let ((first (rat-kingdom-reaction-get 'first))
          (second (rat-kingdom-reaction-get 'second)))
      (should (equal (rat-kingdom-reaction-doc first) "Replaced."))
      (should (equal (rat-kingdom-reaction-take first) '((review))))
      (should (equal (rat-kingdom-reaction-read second) '((doc) (fact))))
      (should-not (rat-kingdom-reaction-take second)))
    (rat-kingdom-reaction-remove 'first)
    (should-not (rat-kingdom-reaction-get 'first))
    (should-error (rat-kingdom-reaction-define 'empty :function #'ignore))
    (should-error (rat-kingdom-reaction-define 'bad :take '(:scope "x")
                                               :function #'ignore))))

;;;; Taking

(ert-deftest rat-kingdom-reaction-test-take-fires-once-per-tuple ()
  (rat-kingdom-reaction-test-with-space space
    (let (seen)
      (rat-kingdom-defreaction start-story
        :take (available :scope $repo :identity $task)
        (push (list $repo $task
                    (plist-get (car rat-kingdom-reaction-tuples) :category))
              seen)
        (rat-kingdom-space-out rat-kingdom-reaction-space 'story
                               :scope $repo :identity $task
                               :payload '(:at ready)))
      (rat-kingdom-space-out space 'available :scope "repo" :identity "T-1")
      (rat-kingdom-space-out space 'available :scope "repo" :identity "T-2")
      (should (eql (rat-kingdom-reaction-run space) 2))
      (should (equal (reverse seen)
                     '(("repo" "T-1" available) ("repo" "T-2" available))))
      (should-not (rat-kingdom-space-scan space '(available)))
      (should (equal (rat-kingdom-reaction-test--identities space '(story))
                     '("T-1" "T-2")))
      (should (eql (rat-kingdom-reaction-run space) 0))
      (let ((reaction (rat-kingdom-reaction-get 'start-story)))
        (should (eql (rat-kingdom-reaction-fired reaction) 2))
        (should (equal (rat-kingdom-reaction-last-fired reaction) 1000.0))
        (should-not (rat-kingdom-reaction-last-error reaction)))
      ;; The take is logged under the reaction's name.
      (should (member '(in "start-story")
                      (mapcar (lambda (op)
                                (list (plist-get op :op) (plist-get op :actor)))
                              (rat-kingdom-space-ops space)))))))

(ert-deftest rat-kingdom-reaction-test-take-never-matches-persistent ()
  (rat-kingdom-reaction-test-with-space space
    (let ((count 0))
      (rat-kingdom-defreaction eat-facts :take (fact) (cl-incf count))
      (rat-kingdom-space-out space 'fact :identity "kept")
      (rat-kingdom-space-out space 'fact :identity "eaten" :modality 'linear)
      (rat-kingdom-reaction-run space)
      (should (eql count 1))
      (should (equal (rat-kingdom-reaction-test--identities space '(fact))
                     '("kept"))))))

;;;; Reading

(ert-deftest rat-kingdom-reaction-test-read-fires-once-per-tuple ()
  (rat-kingdom-reaction-test-with-space space
    (let (seen)
      (rat-kingdom-defreaction show-draft
        :read (doc :identity $path :status draft)
        (push $path seen))
      (rat-kingdom-space-put space 'doc :identity "a.md"
                             :payload '(:status draft))
      (rat-kingdom-space-put space 'doc :identity "b.md"
                             :payload '(:status approved))
      (should (eql (rat-kingdom-reaction-run space) 1))
      (should (eql (rat-kingdom-reaction-run space) 0))
      (should (equal seen '("a.md")))
      (should (rat-kingdom-space-rd space '(doc :identity "a.md")))
      ;; A replaced tuple is a new tuple, so it fires again.
      (rat-kingdom-space-put space 'doc :identity "a.md"
                             :payload '(:status draft :revision 2))
      (rat-kingdom-space-put space 'doc :identity "b.md"
                             :payload '(:status draft))
      (should (eql (rat-kingdom-reaction-run space) 2))
      (should (equal seen '("b.md" "a.md" "a.md"))))))

(ert-deftest rat-kingdom-reaction-test-what-fired-survives-reopening ()
  (let ((file (make-temp-file "rat-kingdom-reaction-test" nil ".db"))
        (rat-kingdom-reaction--registry nil)
        (rat-kingdom-space-change-functions nil)
        (count 0))
    (unwind-protect
        (progn
          (rat-kingdom-defreaction note :read (fact) (cl-incf count))
          (let ((space (rat-kingdom-space-open file)))
            (rat-kingdom-space-out space 'fact :identity "one")
            (rat-kingdom-reaction-run space)
            (rat-kingdom-space-close space))
          (let ((space (rat-kingdom-space-open file)))
            (rat-kingdom-space-out space 'fact :identity "two")
            (rat-kingdom-reaction-run space)
            (rat-kingdom-space-close space))
          (should (eql count 2)))
      (dolist (suffix '("" "-wal" "-shm"))
        (ignore-errors (delete-file (concat file suffix)))))))

;;;; Joins

(ert-deftest rat-kingdom-reaction-test-join-waits-for-every-pattern ()
  (rat-kingdom-reaction-test-with-space space
    (let (seen)
      (rat-kingdom-defreaction integrate-on-pass
        :take (verdict :scope $repo :identity $story :value pass)
        :read (story :identity $story :at review)
        (push (list $repo $story) seen)
        (rat-kingdom-space-put rat-kingdom-reaction-space 'story
                               :scope $repo :identity $story
                               :modality 'persistent
                               :payload '(:at integrating)))
      (rat-kingdom-space-put space 'story :scope "repo" :identity "S-1"
                             :modality 'persistent :payload '(:at review))
      (rat-kingdom-space-put space 'story :scope "repo" :identity "S-2"
                             :modality 'persistent :payload '(:at implementing))
      (should (eql (rat-kingdom-reaction-run space) 0))
      ;; A verdict for a story that is not in review waits.
      (rat-kingdom-space-out space 'verdict :scope "repo" :identity "S-2"
                             :payload '(:value pass))
      (rat-kingdom-space-out space 'verdict :scope "repo" :identity "S-1"
                             :payload '(:value fix))
      (should (eql (rat-kingdom-reaction-run space) 0))
      (rat-kingdom-space-out space 'verdict :scope "repo" :identity "S-1"
                             :payload '(:value pass))
      (should (eql (rat-kingdom-reaction-run space) 1))
      (should (equal seen '(("repo" "S-1"))))
      (should (equal (plist-get (plist-get (rat-kingdom-space-rd
                                            space '(story :identity "S-1"))
                                           :payload)
                                :at)
                     "integrating"))
      (should (eql (length (rat-kingdom-space-scan space '(verdict))) 2)))))

(ert-deftest rat-kingdom-reaction-test-join-uses-each-tuple-once ()
  (rat-kingdom-reaction-test-with-space space
    (let (pairs)
      (rat-kingdom-defreaction pair
        :take ((available :identity $a) (available :identity $b))
        (push (list $a $b) pairs))
      (rat-kingdom-space-out space 'available :identity "1")
      (should (eql (rat-kingdom-reaction-run space) 0))
      (rat-kingdom-space-out space 'available :identity "2")
      (rat-kingdom-space-out space 'available :identity "3")
      (should (eql (rat-kingdom-reaction-run space) 1))
      (should (equal pairs '(("1" "2"))))
      (should (equal (rat-kingdom-reaction-test--identities space '(available))
                     '("3"))))))

;;;; Failure

(ert-deftest rat-kingdom-reaction-test-failure-rolls-back-and-waits ()
  (rat-kingdom-reaction-test-with-space space
    (let ((broken t) (calls 0))
      (rat-kingdom-defreaction fragile
        :take (available :identity $task)
        (cl-incf calls)
        (rat-kingdom-space-out rat-kingdom-reaction-space 'fact
                               :identity $task)
        (when broken (error "No worktree for %s" $task)))
      (rat-kingdom-space-out space 'available :identity "T-1")
      (should (eql (rat-kingdom-reaction-run space) 0))
      ;; Nothing the firing did was kept.
      (should (rat-kingdom-space-rd space '(available :identity "T-1")))
      (should-not (rat-kingdom-space-scan space '(fact)))
      (should (equal (rat-kingdom-reaction-last-error
                      (rat-kingdom-reaction-get 'fragile))
                     "No worktree for T-1"))
      (let ((failures (rat-kingdom-reaction-failures space)))
        (should (eql (length failures) 1))
        (should (eq (plist-get (car failures) :reaction) 'fragile))
        (should (equal (plist-get (car failures) :error) "No worktree for T-1"))
        (should (equal (plist-get (car failures) :tuples)
                       (list (plist-get (rat-kingdom-space-rd space '(available))
                                        :id)))))
      ;; It is not tried again on its own, but other tuples still fire.
      (rat-kingdom-reaction-run space)
      (should (eql calls 1))
      (setq broken nil)
      (rat-kingdom-space-out space 'available :identity "T-2")
      (should (eql (rat-kingdom-reaction-run space) 1))
      (should (eql calls 2))
      (should (eql (rat-kingdom-reaction-retry space 'other) 0))
      (should (eql calls 2))
      (should (eql (rat-kingdom-reaction-retry space 'fragile) 1))
      (should (eql calls 3))
      (should-not (rat-kingdom-space-scan space '(available)))
      (should-not (rat-kingdom-reaction-failures space))
      (should (equal (rat-kingdom-reaction-test--identities space '(fact))
                     '("T-2" "T-1"))))))

(ert-deftest rat-kingdom-reaction-test-failed-read-is-not-marked-done ()
  (rat-kingdom-reaction-test-with-space space
    (let ((broken t) (calls 0))
      (rat-kingdom-defreaction note
        :read (fact)
        (cl-incf calls)
        (when broken (error "Broken")))
      (rat-kingdom-space-out space 'fact :identity "f")
      (rat-kingdom-reaction-run space)
      (rat-kingdom-reaction-run space)
      (should (eql calls 1))
      (setq broken nil)
      (should (eql (rat-kingdom-reaction-retry space) 1))
      (should (eql calls 2))
      (rat-kingdom-reaction-run space)
      (should (eql calls 2)))))

;;;; Runs

(ert-deftest rat-kingdom-reaction-test-one-run-follows-the-chain ()
  (rat-kingdom-reaction-test-with-space space
    (rat-kingdom-defreaction check
      :take (review :identity $story)
      (rat-kingdom-space-out rat-kingdom-reaction-space 'verdict
                             :identity $story :payload '(:value pass)))
    (rat-kingdom-defreaction start
      :take (available :identity $story)
      (rat-kingdom-space-out rat-kingdom-reaction-space 'review
                             :identity $story))
    (rat-kingdom-space-out space 'available :identity "S-1")
    (should (eql (rat-kingdom-reaction-run space) 2))
    (should (equal (rat-kingdom-reaction-test--identities space '(_))
                   '("S-1")))
    (should (rat-kingdom-space-rd space '(verdict :identity "S-1")))))

(ert-deftest rat-kingdom-reaction-test-runaway-is-stopped ()
  (rat-kingdom-reaction-test-with-space space
    (let ((rat-kingdom-reaction-max-firings 25)
          (warning-minimum-log-level :emergency)
          (count 0))
      (rat-kingdom-defreaction forever
        :take (available :identity $task)
        (cl-incf count)
        (rat-kingdom-space-out rat-kingdom-reaction-space 'available
                               :identity $task))
      (rat-kingdom-space-out space 'available :identity "T-1")
      (should (eql (rat-kingdom-reaction-run space) 25))
      (should (eql count 25))
      (should (rat-kingdom-space-rd space '(available :identity "T-1"))))))

(ert-deftest rat-kingdom-reaction-test-disabled-reaction-waits ()
  (rat-kingdom-reaction-test-with-space space
    (let ((count 0))
      (rat-kingdom-defreaction eat :take (available) (cl-incf count))
      (setf (rat-kingdom-reaction-enabled (rat-kingdom-reaction-get 'eat)) nil)
      (rat-kingdom-space-out space 'available :identity "T-1")
      (should (eql (rat-kingdom-reaction-run space) 0))
      (setf (rat-kingdom-reaction-enabled (rat-kingdom-reaction-get 'eat)) t)
      (should (eql (rat-kingdom-reaction-run space) 1))
      (should (eql count 1)))))

(ert-deftest rat-kingdom-reaction-test-run-refuses-a-transaction ()
  (rat-kingdom-reaction-test-with-space space
    (rat-kingdom-defreaction eat :take (available) nil)
    (should-error
     (rat-kingdom-space-with-transaction space
       (rat-kingdom-reaction-run space)))))

(ert-deftest rat-kingdom-reaction-test-forget-gone ()
  (rat-kingdom-reaction-test-with-space space
    (rat-kingdom-defreaction note :read (fact) nil)
    (rat-kingdom-space-out space 'fact :identity "stays")
    (rat-kingdom-space-out space 'fact :identity "goes" :owner "S-1")
    (rat-kingdom-reaction-run space)
    (should (eql (rat-kingdom-reaction-forget-gone space) 0))
    (rat-kingdom-space-sweep space "S-1")
    (should (eql (rat-kingdom-reaction-forget-gone space) 1))
    (should (eql (rat-kingdom-reaction-forget-gone space) 0))
    (should (eql (rat-kingdom-reaction-run space) 0))))

;;;; Attached spaces

(ert-deftest rat-kingdom-reaction-test-attach-catches-up-then-follows ()
  (rat-kingdom-reaction-test-with-space space
    (let (seen)
      (rat-kingdom-defreaction eat
        :take (available :identity $task)
        (push $task seen))
      ;; Written while nothing was attached.
      (rat-kingdom-space-out space 'available :identity "before")
      (rat-kingdom-reaction-attach space)
      (should (equal seen '("before")))
      ;; A write only schedules a run; the writer is not held up.
      (rat-kingdom-space-out space 'available :identity "after")
      (rat-kingdom-space-out space 'available :identity "again")
      (should (equal seen '("before")))
      (accept-process-output nil 0.05)
      (should (equal seen '("again" "after" "before")))
      (rat-kingdom-reaction-detach space)
      (rat-kingdom-space-out space 'available :identity "detached")
      (accept-process-output nil 0.05)
      (should (equal seen '("again" "after" "before"))))))

(ert-deftest rat-kingdom-reaction-test-poll-sees-another-writer ()
  (rat-kingdom-reaction-test-with-space space
    (let ((rat-kingdom-reaction-poll-interval 3600)
          seen)
      (rat-kingdom-defreaction on-push
        :take (event :identity $source :kind push)
        (push $source seen))
      (rat-kingdom-reaction-attach space)
      (rat-kingdom-reaction-poll space)
      (should-not seen)
      (let ((other (sqlite-open (rat-kingdom-space-file space))))
        (unwind-protect
            (sqlite-execute
             other
             "INSERT INTO tuples (category, scope, identity, payload, modality,
                                  created, expires)
              VALUES ('event', 'system', 'webhook', '{\"kind\":\"push\"}',
                      'affine', 1000.0, 1300.0)")
          (sqlite-close other)))
      (rat-kingdom-reaction-poll space)
      (should (equal seen '("webhook")))
      (should-not (rat-kingdom-space-scan space '(event))))))

(ert-deftest rat-kingdom-reaction-test-poll-archives-expired-tuples ()
  (rat-kingdom-reaction-test-with-space space
    (let ((rat-kingdom-reaction-poll-interval 3600))
      (rat-kingdom-defreaction note :read (event) nil)
      (rat-kingdom-reaction-attach space)
      (rat-kingdom-space-out space 'event :identity "tick" :ttl 60)
      (rat-kingdom-reaction-run space)
      (setq rat-kingdom-reaction-test--now 2000.0)
      (rat-kingdom-reaction-poll space)
      (should (eql (length (rat-kingdom-space-archived space)) 1))
      ;; Its firing record went with it.
      (should (eql (rat-kingdom-reaction-forget-gone space) 0))
      (should-not (sqlite-select (rat-kingdom-space-db space)
                                 "SELECT * FROM firings")))))

(provide 'rat-kingdom-reaction-test)
;;; rat-kingdom-reaction-test.el ends here
