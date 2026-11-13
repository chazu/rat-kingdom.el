;;; rk3-space-test.el --- Tests for rk3-space -*- lexical-binding: t; -*-

;;; Commentary:

;; Batch tests for the tuplespace.  Each test gets its own database file.

;;; Code:

(require 'ert)
(require 'rk3-space)

(defvar rk3-space-test--now 1000.0
  "The time the space sees during a test.")

(defmacro rk3-space-test-with-space (var &rest body)
  "Run BODY with VAR bound to a fresh space at a fixed time."
  (declare (indent 1) (debug t))
  (let ((file (make-symbol "file")))
    `(let* ((,file (make-temp-file "rk3-space-test" nil ".db"))
            (rk3-space-test--now 1000.0)
            (rk3-space-now-function (lambda () rk3-space-test--now))
            (rk3-space-change-functions nil)
            (,var (rk3-space-open ,file)))
       (unwind-protect
           (progn ,@body)
         (rk3-space-close ,var)
         (dolist (suffix '("" "-wal" "-shm"))
           (ignore-errors (delete-file (concat ,file suffix))))))))

;;;; out and rd

(ert-deftest rk3-space-test-out-returns-what-rd-reads ()
  (rk3-space-test-with-space space
    (let ((written (rk3-space-out space 'result :scope "repo" :identity "S-1"
                                  :payload '(:commit "abc" :checks ("lint" "test")
                                             :stats (:files 3))
                                  :owner "S-1")))
      (should (integerp (plist-get written :id)))
      (should (equal written (rk3-space-rd space '(result :identity "S-1"))))
      (should (equal (plist-get written :payload)
                     '(:commit "abc" :checks ("lint" "test") :stats (:files 3))))
      (should (eq (plist-get written :modality) 'persistent))
      (should (equal (plist-get written :created) 1000.0)))))

(ert-deftest rk3-space-test-symbols-are-stored-as-names ()
  (rk3-space-test-with-space space
    (rk3-space-out space 'story :scope 'repo :identity 'S-1
                   :payload '(:at ready))
    (let ((tuple (rk3-space-rd space '(story :at ready))))
      (should (equal (plist-get tuple :scope) "repo"))
      (should (equal (plist-get tuple :identity) "S-1"))
      (should (equal (plist-get tuple :payload) '(:at "ready"))))
    (should (rk3-space-rd space '(story :at "ready")))
    (should-not (rk3-space-rd space '(story :at done)))))

(ert-deftest rk3-space-test-false-and-null-survive ()
  (rk3-space-test-with-space space
    (rk3-space-out space 'fact :identity "f"
                   :payload '(:yes t :no :false :nothing nil))
    (should (equal (plist-get (rk3-space-rd space '(fact)) :payload)
                   '(:yes t :no :false :nothing nil)))))

(ert-deftest rk3-space-test-out-rejects-bad-tuples ()
  (rk3-space-test-with-space space
    (should-error (rk3-space-out space 'nonsense))
    (should-error (rk3-space-out space 'fact :payload '(:scope "x")))
    (should-error (rk3-space-out space 'fact :payload '("key" 1)))
    (should-error (rk3-space-out space 'fact :payload '(:dangling)))
    (should-error (rk3-space-out space 'fact :payload '(:kind :keyword)))
    (should-error (rk3-space-out space 'fact :modality 'eternal))
    (should-error (rk3-space-out space 'event))
    (should-error (rk3-space-out space 'event :ttl 0))
    (should-not (rk3-space-scan space '(_)))
    (should-not (rk3-space-ops space))))

(ert-deftest rk3-space-test-define-category ()
  (rk3-space-test-with-space space
    (let ((rk3-space-categories (copy-alist rk3-space-categories)))
      (rk3-space-define-category 'tick 'affine)
      (should-error (rk3-space-out space 'tick))
      (should (rk3-space-out space 'tick :ttl 5))
      (should-error (rk3-space-define-category 'tock 'eternal)))))

;;;; Patterns

(ert-deftest rk3-space-test-match-binds-variables ()
  (let ((tuple '(:id 4 :category result :scope "repo" :identity "S-1"
                 :payload (:commit "abc") :modality persistent :owner nil)))
    (should (equal (rk3-space-match '(result) tuple) rk3-space-no-bindings))
    (let ((bindings (rk3-space-match
                     '($c :scope $repo :identity $story :commit $commit :id $id)
                     tuple)))
      (should (eq (alist-get '$c bindings) 'result))
      (should (equal (alist-get '$repo bindings) "repo"))
      (should (equal (alist-get '$story bindings) "S-1"))
      (should (equal (alist-get '$commit bindings) "abc"))
      (should (eql (alist-get '$id bindings) 4)))
    (should (rk3-space-match '(result :modality persistent) tuple))
    (should-not (rk3-space-match '(result :modality linear) tuple))
    (should-not (rk3-space-match '(review) tuple))
    (should-not (rk3-space-match '(result :commit "other") tuple))))

(ert-deftest rk3-space-test-match-repeated-variable-must-agree ()
  (let ((same '(:category fact :scope "a" :identity "a" :payload nil
                :modality persistent))
        (differ '(:category fact :scope "a" :identity "b" :payload nil
                  :modality persistent)))
    (should (rk3-space-match '(fact :scope $x :identity $x) same))
    (should-not (rk3-space-match '(fact :scope $x :identity $x) differ))))

(ert-deftest rk3-space-test-match-starts-from-given-bindings ()
  (let ((tuple '(:category checked :scope "repo" :identity "S-1"
                 :payload (:value "pass") :modality persistent)))
    (should (rk3-space-match '(checked :identity $story) tuple
                             '(($story . "S-1") (t . t))))
    (should-not (rk3-space-match '(checked :identity $story) tuple
                                 '(($story . "S-2") (t . t))))))

(ert-deftest rk3-space-test-match-absent-fields ()
  (let ((tuple '(:category fact :scope "repo" :identity nil
                 :payload (:nothing nil) :modality persistent :owner nil)))
    ;; A variable needs something to bind.
    (should-not (rk3-space-match '(fact :missing $v) tuple))
    (should-not (rk3-space-match '(fact :identity $i) tuple))
    ;; A key that is present with a null value does bind.
    (should (rk3-space-match '(fact :nothing $v) tuple))
    ;; The wildcard and a literal nil accept absence.
    (should (rk3-space-match '(fact :missing _ :identity _) tuple))
    (should (rk3-space-match '(fact :missing nil :owner nil) tuple))))

(ert-deftest rk3-space-test-malformed-patterns-are-errors ()
  (rk3-space-test-with-space space
    (should-error (rk3-space-scan space '(:scope "x")))
    (should-error (rk3-space-scan space '(fact :scope)))
    (should-error (rk3-space-scan space '(fact "scope" "x")))
    (should-error (rk3-space-scan space nil))))

;;;; scan, in, modalities

(ert-deftest rk3-space-test-scan-filters-and-keeps-order ()
  (rk3-space-test-with-space space
    (rk3-space-out space 'fact :scope "a" :identity "1" :payload '(:n 1))
    (rk3-space-out space 'fact :scope "b" :identity "2" :payload '(:n 2))
    (rk3-space-out space 'fact :scope "a" :identity "3" :payload '(:n 3))
    (rk3-space-out space 'doc :scope "a" :identity "4")
    (cl-flet ((ids (pattern)
                (mapcar (lambda (tuple) (plist-get tuple :identity))
                        (rk3-space-scan space pattern))))
      (should (equal (ids '(fact)) '("1" "2" "3")))
      (should (equal (ids '(fact :scope "a")) '("1" "3")))
      (should (equal (ids '(_ :scope "a")) '("1" "3" "4")))
      (should (equal (ids '(fact :n 2)) '("2")))
      (should (equal (ids '(fact :scope $s :n 3)) '("3")))
      (should (equal (ids '(fact :scope "nowhere")) nil)))))

(ert-deftest rk3-space-test-in-takes-each-tuple-once ()
  (rk3-space-test-with-space space
    (rk3-space-out space 'available :scope "repo" :identity "T-1")
    (rk3-space-out space 'available :scope "repo" :identity "T-2")
    (should (equal (plist-get (rk3-space-in space '(available :scope "repo"))
                              :identity)
                   "T-1"))
    (should (equal (plist-get (rk3-space-in space '(available :scope "repo"))
                              :identity)
                   "T-2"))
    (should-not (rk3-space-in space '(available :scope "repo")))
    (should-not (rk3-space-scan space '(available)))))

(ert-deftest rk3-space-test-in-leaves-persistent-tuples ()
  (rk3-space-test-with-space space
    (rk3-space-out space 'fact :identity "f")
    (rk3-space-out space 'fact :identity "g" :modality 'linear)
    (should (equal (plist-get (rk3-space-in space '(fact)) :identity) "g"))
    (should-not (rk3-space-in space '(fact)))
    (should (rk3-space-rd space '(fact :identity "f")))))

(ert-deftest rk3-space-test-put-replaces-by-key ()
  (rk3-space-test-with-space space
    (rk3-space-put space 'run :scope "repo" :identity "R-1"
                   :payload '(:state starting))
    (rk3-space-put space 'run :scope "repo" :identity "R-2"
                   :payload '(:state starting))
    (rk3-space-put space 'run :scope "repo" :identity "R-1"
                   :payload '(:state working))
    (should (equal (mapcar (lambda (tuple)
                             (cons (plist-get tuple :identity)
                                   (plist-get (plist-get tuple :payload) :state)))
                           (rk3-space-scan space '(run)))
                   '(("R-2" . "starting") ("R-1" . "working"))))
    (should-error (rk3-space-put space 'run :scope "repo"))))

(ert-deftest rk3-space-test-retract-removes-every-match ()
  (rk3-space-test-with-space space
    (rk3-space-out space 'fact :scope "a" :identity "1")
    (rk3-space-out space 'fact :scope "a" :identity "2")
    (rk3-space-out space 'fact :scope "b" :identity "3")
    (should (eql (rk3-space-retract space '(fact :scope "a")) 2))
    (should (eql (rk3-space-retract space '(fact :scope "a")) 0))
    (should (equal (length (rk3-space-scan space '(fact))) 1))))

;;;; Lifetime

(ert-deftest rk3-space-test-expired-tuples-cannot-be-read ()
  (rk3-space-test-with-space space
    (rk3-space-out space 'event :identity "tick" :ttl 60)
    (rk3-space-out space 'fact :identity "kept")
    (setq rk3-space-test--now 1059.0)
    (should (rk3-space-rd space '(event)))
    (setq rk3-space-test--now 1060.0)
    (should-not (rk3-space-rd space '(event)))
    (should-not (rk3-space-in space '(event)))
    (should-not (rk3-space-scan space '(event)))
    (should (eql (rk3-space-expire space) 1))
    (should (eql (rk3-space-expire space) 0))
    (should (rk3-space-rd space '(fact :identity "kept")))
    (let ((archived (rk3-space-archived space)))
      (should (equal (length archived) 1))
      (should (eq (plist-get (car archived) :reason) 'expire))
      (should (equal (plist-get (car archived) :archived) 1060.0)))))

(ert-deftest rk3-space-test-sweep-archives-one-owner ()
  (rk3-space-test-with-space space
    (rk3-space-out space 'story :identity "S-1" :owner "S-1"
                   :payload '(:at done))
    (rk3-space-out space 'result :identity "S-1" :owner "S-1"
                   :payload '(:commit "abc"))
    (rk3-space-out space 'result :identity "S-2" :owner "S-2")
    (rk3-space-out space 'fact :scope "repo" :identity "learned")
    (should (eql (rk3-space-sweep space "S-1") 2))
    (should (eql (rk3-space-sweep space "S-1") 0))
    (should (equal (mapcar (lambda (tuple) (plist-get tuple :identity))
                           (rk3-space-scan space '(_)))
                   '("S-2" "learned")))
    (let ((archived (rk3-space-archived space "S-1")))
      (should (equal (mapcar (lambda (tuple) (plist-get tuple :category))
                             archived)
                     '(story result)))
      (should (equal (plist-get (cadr archived) :payload) '(:commit "abc")))
      (should (eq (plist-get (car archived) :reason) 'sweep)))
    (should-not (rk3-space-archived space "S-2"))
    (should-error (rk3-space-sweep space nil))))

;;;; Transactions, hooks and the log

(ert-deftest rk3-space-test-failed-transaction-keeps-nothing ()
  (rk3-space-test-with-space space
    (let (seen)
      (add-hook 'rk3-space-change-functions
                (lambda (_space op _subject) (push op seen)))
      (rk3-space-out space 'available :identity "T-1")
      (setq seen nil)
      (should-error
       (rk3-space-with-transaction space
         (rk3-space-out space 'fact :identity "f")
         (rk3-space-in space '(available))
         (error "Boom")))
      (should-not seen)
      (should-not (rk3-space-rd space '(fact)))
      (should (rk3-space-rd space '(available :identity "T-1")))
      (should (equal (mapcar (lambda (op) (plist-get op :op))
                             (rk3-space-ops space))
                     '(out)))
      ;; The space still works afterwards.
      (should (rk3-space-out space 'fact :identity "after"))
      (should (equal seen '(out))))))

(ert-deftest rk3-space-test-changes-are-announced-after-commit ()
  (rk3-space-test-with-space space
    (let (seen visible)
      (add-hook 'rk3-space-change-functions
                (lambda (space op subject)
                  (push (cons op (or (plist-get subject :identity)
                                     (plist-get subject :count)))
                        seen)
                  ;; By now the whole transaction is readable.
                  (push (length (rk3-space-scan space '(_))) visible)))
      (rk3-space-with-transaction space
        (rk3-space-out space 'available :identity "T-1" :owner "E")
        (rk3-space-out space 'available :identity "T-2" :owner "E")
        (rk3-space-in space '(available))
        (should-not seen))
      (should (equal (reverse seen)
                     '((out . "T-1") (out . "T-2") (in . "T-1"))))
      (should (equal visible '(1 1 1)))
      (setq seen nil)
      (rk3-space-sweep space "E")
      (should (equal seen '((sweep . 1)))))))

(ert-deftest rk3-space-test-a-failing-change-function-stops-nothing ()
  (rk3-space-test-with-space space
    (let (seen (debug-on-error nil) (inhibit-message t))
      (add-hook 'rk3-space-change-functions
                (lambda (&rest _) (push 'second seen)) t)
      (add-hook 'rk3-space-change-functions
                (lambda (&rest _) (error "Broken")))
      (should (rk3-space-out space 'fact :identity "f"))
      (should (equal seen '(second))))))

(ert-deftest rk3-space-test-ops-log-records-each-write ()
  (rk3-space-test-with-space space
    (rk3-space-out space 'available :scope "repo" :identity "T-1"
                   :payload '(:priority 2) :actor "adapter")
    (rk3-space-in space '(available) :actor "engine")
    (rk3-space-out space 'fact :identity "f")
    (rk3-space-retract space '(fact) :actor 'king)
    (let ((ops (rk3-space-ops space)))
      (should (equal (mapcar (lambda (op)
                               (list (plist-get op :op) (plist-get op :category)
                                     (plist-get op :actor)))
                             ops)
                     '((out available "adapter") (in available "engine")
                       (out fact nil) (retract fact "king"))))
      (should (equal (plist-get (car ops) :payload) '(:priority 2)))
      (should (equal (plist-get (car ops) :identity) "T-1"))
      (should (eql (plist-get (car ops) :tuple-id)
                   (plist-get (cadr ops) :tuple-id))))
    (should (equal (mapcar (lambda (op) (plist-get op :op))
                           (rk3-space-ops space 2))
                   '(out retract)))))

;;;; Files and other writers

(ert-deftest rk3-space-test-tuples-survive-reopening ()
  (let ((file (make-temp-file "rk3-space-test" nil ".db")))
    (unwind-protect
        (progn
          (let ((space (rk3-space-open file)))
            (rk3-space-out space 'fact :identity "kept" :payload '(:n 1))
            (rk3-space-close space))
          (let ((space (rk3-space-open file)))
            (should (equal (plist-get (rk3-space-rd space '(fact :identity "kept"))
                                      :payload)
                           '(:n 1)))
            (rk3-space-close space)))
      (dolist (suffix '("" "-wal" "-shm"))
        (ignore-errors (delete-file (concat file suffix)))))))

(ert-deftest rk3-space-test-open-refuses-a-newer-schema ()
  (let ((file (make-temp-file "rk3-space-test" nil ".db")))
    (unwind-protect
        (progn
          (let ((db (sqlite-open file)))
            (sqlite-execute db "PRAGMA user_version = 99")
            (sqlite-close db))
          (should-error (rk3-space-open file)))
      (dolist (suffix '("" "-wal" "-shm"))
        (ignore-errors (delete-file (concat file suffix)))))))

(ert-deftest rk3-space-test-another-writer-is-noticed ()
  (rk3-space-test-with-space space
    (rk3-space-out space 'fact :identity "ours")
    (let ((before (rk3-space-data-version space))
          (other (sqlite-open (rk3-space-file space))))
      (should (eql before (rk3-space-data-version space)))
      (unwind-protect
          (sqlite-execute
           other
           "INSERT INTO tuples (category, scope, identity, payload, modality,
                                created, expires)
            VALUES ('event', 'system', 'webhook', '{\"kind\":\"push\"}',
                    'affine', 1000.0, 1300.0)")
        (sqlite-close other))
      (should-not (eql before (rk3-space-data-version space)))
      (let ((event (rk3-space-in space '(event :kind $kind))))
        (should (equal (plist-get event :identity) "webhook"))
        (should (equal (plist-get event :payload) '(:kind "push")))))))

(provide 'rk3-space-test)
;;; rk3-space-test.el ends here
