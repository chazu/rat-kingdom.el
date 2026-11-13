;;; rat-kingdom-space-test.el --- Tests for rat-kingdom-space -*- lexical-binding: t; -*-

;;; Commentary:

;; Batch tests for the tuplespace.  Each test gets its own database file.

;;; Code:

(require 'ert)
(require 'rat-kingdom-space)

(defvar rat-kingdom-space-test--now 1000.0
  "The time the space sees during a test.")

(defmacro rat-kingdom-space-test-with-space (var &rest body)
  "Run BODY with VAR bound to a fresh space at a fixed time."
  (declare (indent 1) (debug t))
  (let ((file (make-symbol "file")))
    `(let* ((,file (make-temp-file "rat-kingdom-space-test" nil ".db"))
            (rat-kingdom-space-test--now 1000.0)
            (rat-kingdom-space-now-function (lambda () rat-kingdom-space-test--now))
            (rat-kingdom-space-change-functions nil)
            (,var (rat-kingdom-space-open ,file)))
       (unwind-protect
           (progn ,@body)
         (rat-kingdom-space-close ,var)
         (dolist (suffix '("" "-wal" "-shm"))
           (ignore-errors (delete-file (concat ,file suffix))))))))

;;;; out and rd

(ert-deftest rat-kingdom-space-test-out-returns-what-rd-reads ()
  (rat-kingdom-space-test-with-space space
				     (let ((written (rat-kingdom-space-out space 'result :scope "repo" :identity "S-1"
									   :payload '(:commit "abc" :checks ("lint" "test")
											      :stats (:files 3))
									   :owner "S-1")))
				       (should (integerp (plist-get written :id)))
				       (should (equal written (rat-kingdom-space-rd space '(result :identity "S-1"))))
				       (should (equal (plist-get written :payload)
						      '(:commit "abc" :checks ("lint" "test") :stats (:files 3))))
				       (should (eq (plist-get written :modality) 'persistent))
				       (should (equal (plist-get written :created) 1000.0)))))

(ert-deftest rat-kingdom-space-test-symbols-are-stored-as-names ()
  (rat-kingdom-space-test-with-space space
				     (rat-kingdom-space-out space 'story :scope 'repo :identity 'S-1
							    :payload '(:at ready))
				     (let ((tuple (rat-kingdom-space-rd space '(story :at ready))))
				       (should (equal (plist-get tuple :scope) "repo"))
				       (should (equal (plist-get tuple :identity) "S-1"))
				       (should (equal (plist-get tuple :payload) '(:at "ready"))))
				     (should (rat-kingdom-space-rd space '(story :at "ready")))
				     (should-not (rat-kingdom-space-rd space '(story :at done)))))

(ert-deftest rat-kingdom-space-test-false-and-null-survive ()
  (rat-kingdom-space-test-with-space space
				     (rat-kingdom-space-out space 'fact :identity "f"
							    :payload '(:yes t :no :false :nothing nil))
				     (should (equal (plist-get (rat-kingdom-space-rd space '(fact)) :payload)
						    '(:yes t :no :false :nothing nil)))))

(ert-deftest rat-kingdom-space-test-out-rejects-bad-tuples ()
  (rat-kingdom-space-test-with-space space
				     (should-error (rat-kingdom-space-out space 'nonsense))
				     (should-error (rat-kingdom-space-out space 'fact :payload '(:scope "x")))
				     (should-error (rat-kingdom-space-out space 'fact :payload '("key" 1)))
				     (should-error (rat-kingdom-space-out space 'fact :payload '(:dangling)))
				     (should-error (rat-kingdom-space-out space 'fact :payload '(:kind :keyword)))
				     (should-error (rat-kingdom-space-out space 'fact :modality 'eternal))
				     (should-error (rat-kingdom-space-out space 'event))
				     (should-error (rat-kingdom-space-out space 'event :ttl 0))
				     (should-not (rat-kingdom-space-scan space '(_)))
				     (should-not (rat-kingdom-space-ops space))))

(ert-deftest rat-kingdom-space-test-define-category ()
  (rat-kingdom-space-test-with-space space
				     (let ((rat-kingdom-space-categories (copy-alist rat-kingdom-space-categories)))
				       (rat-kingdom-space-define-category 'tick 'affine)
				       (should-error (rat-kingdom-space-out space 'tick))
				       (should (rat-kingdom-space-out space 'tick :ttl 5))
				       (should-error (rat-kingdom-space-define-category 'tock 'eternal)))))

;;;; Patterns

(ert-deftest rat-kingdom-space-test-match-binds-variables ()
  (let ((tuple '(:id 4 :category result :scope "repo" :identity "S-1"
                     :payload (:commit "abc") :modality persistent :owner nil)))
    (should (equal (rat-kingdom-space-match '(result) tuple) rat-kingdom-space-no-bindings))
    (let ((bindings (rat-kingdom-space-match
                     '($c :scope $repo :identity $story :commit $commit :id $id)
                     tuple)))
      (should (eq (alist-get '$c bindings) 'result))
      (should (equal (alist-get '$repo bindings) "repo"))
      (should (equal (alist-get '$story bindings) "S-1"))
      (should (equal (alist-get '$commit bindings) "abc"))
      (should (eql (alist-get '$id bindings) 4)))
    (should (rat-kingdom-space-match '(result :modality persistent) tuple))
    (should-not (rat-kingdom-space-match '(result :modality linear) tuple))
    (should-not (rat-kingdom-space-match '(review) tuple))
    (should-not (rat-kingdom-space-match '(result :commit "other") tuple))))

(ert-deftest rat-kingdom-space-test-match-repeated-variable-must-agree ()
  (let ((same '(:category fact :scope "a" :identity "a" :payload nil
			  :modality persistent))
        (differ '(:category fact :scope "a" :identity "b" :payload nil
			    :modality persistent)))
    (should (rat-kingdom-space-match '(fact :scope $x :identity $x) same))
    (should-not (rat-kingdom-space-match '(fact :scope $x :identity $x) differ))))

(ert-deftest rat-kingdom-space-test-match-starts-from-given-bindings ()
  (let ((tuple '(:category checked :scope "repo" :identity "S-1"
			   :payload (:value "pass") :modality persistent)))
    (should (rat-kingdom-space-match '(checked :identity $story) tuple
				     '(($story . "S-1") (t . t))))
    (should-not (rat-kingdom-space-match '(checked :identity $story) tuple
					 '(($story . "S-2") (t . t))))))

(ert-deftest rat-kingdom-space-test-match-absent-fields ()
  (let ((tuple '(:category fact :scope "repo" :identity nil
			   :payload (:nothing nil) :modality persistent :owner nil)))
    ;; A variable needs something to bind.
    (should-not (rat-kingdom-space-match '(fact :missing $v) tuple))
    (should-not (rat-kingdom-space-match '(fact :identity $i) tuple))
    ;; A key that is present with a null value does bind.
    (should (rat-kingdom-space-match '(fact :nothing $v) tuple))
    ;; The wildcard and a literal nil accept absence.
    (should (rat-kingdom-space-match '(fact :missing _ :identity _) tuple))
    (should (rat-kingdom-space-match '(fact :missing nil :owner nil) tuple))))

(ert-deftest rat-kingdom-space-test-malformed-patterns-are-errors ()
  (rat-kingdom-space-test-with-space space
				     (should-error (rat-kingdom-space-scan space '(:scope "x")))
				     (should-error (rat-kingdom-space-scan space '(fact :scope)))
				     (should-error (rat-kingdom-space-scan space '(fact "scope" "x")))
				     (should-error (rat-kingdom-space-scan space nil))))

;;;; scan, in, modalities

(ert-deftest rat-kingdom-space-test-scan-filters-and-keeps-order ()
  (rat-kingdom-space-test-with-space space
				     (rat-kingdom-space-out space 'fact :scope "a" :identity "1" :payload '(:n 1))
				     (rat-kingdom-space-out space 'fact :scope "b" :identity "2" :payload '(:n 2))
				     (rat-kingdom-space-out space 'fact :scope "a" :identity "3" :payload '(:n 3))
				     (rat-kingdom-space-out space 'doc :scope "a" :identity "4")
				     (cl-flet ((ids (pattern)
						 (mapcar (lambda (tuple) (plist-get tuple :identity))
							 (rat-kingdom-space-scan space pattern))))
				       (should (equal (ids '(fact)) '("1" "2" "3")))
				       (should (equal (ids '(fact :scope "a")) '("1" "3")))
				       (should (equal (ids '(_ :scope "a")) '("1" "3" "4")))
				       (should (equal (ids '(fact :n 2)) '("2")))
				       (should (equal (ids '(fact :scope $s :n 3)) '("3")))
				       (should (equal (ids '(fact :scope "nowhere")) nil)))))

(ert-deftest rat-kingdom-space-test-in-takes-each-tuple-once ()
  (rat-kingdom-space-test-with-space space
				     (rat-kingdom-space-out space 'available :scope "repo" :identity "T-1")
				     (rat-kingdom-space-out space 'available :scope "repo" :identity "T-2")
				     (should (equal (plist-get (rat-kingdom-space-in space '(available :scope "repo"))
							       :identity)
						    "T-1"))
				     (should (equal (plist-get (rat-kingdom-space-in space '(available :scope "repo"))
							       :identity)
						    "T-2"))
				     (should-not (rat-kingdom-space-in space '(available :scope "repo")))
				     (should-not (rat-kingdom-space-scan space '(available)))))

(ert-deftest rat-kingdom-space-test-in-leaves-persistent-tuples ()
  (rat-kingdom-space-test-with-space space
				     (rat-kingdom-space-out space 'fact :identity "f")
				     (rat-kingdom-space-out space 'fact :identity "g" :modality 'linear)
				     (should (equal (plist-get (rat-kingdom-space-in space '(fact)) :identity) "g"))
				     (should-not (rat-kingdom-space-in space '(fact)))
				     (should (rat-kingdom-space-rd space '(fact :identity "f")))))

(ert-deftest rat-kingdom-space-test-put-replaces-by-key ()
  (rat-kingdom-space-test-with-space space
				     (rat-kingdom-space-put space 'run :scope "repo" :identity "R-1"
							    :payload '(:state starting))
				     (rat-kingdom-space-put space 'run :scope "repo" :identity "R-2"
							    :payload '(:state starting))
				     (rat-kingdom-space-put space 'run :scope "repo" :identity "R-1"
							    :payload '(:state working))
				     (should (equal (mapcar (lambda (tuple)
							      (cons (plist-get tuple :identity)
								    (plist-get (plist-get tuple :payload) :state)))
							    (rat-kingdom-space-scan space '(run)))
						    '(("R-2" . "starting") ("R-1" . "working"))))
				     (should-error (rat-kingdom-space-put space 'run :scope "repo"))))

(ert-deftest rat-kingdom-space-test-retract-removes-every-match ()
  (rat-kingdom-space-test-with-space space
				     (rat-kingdom-space-out space 'fact :scope "a" :identity "1")
				     (rat-kingdom-space-out space 'fact :scope "a" :identity "2")
				     (rat-kingdom-space-out space 'fact :scope "b" :identity "3")
				     (should (eql (rat-kingdom-space-retract space '(fact :scope "a")) 2))
				     (should (eql (rat-kingdom-space-retract space '(fact :scope "a")) 0))
				     (should (equal (length (rat-kingdom-space-scan space '(fact))) 1))))

;;;; Lifetime

(ert-deftest rat-kingdom-space-test-expired-tuples-cannot-be-read ()
  (rat-kingdom-space-test-with-space space
				     (rat-kingdom-space-out space 'event :identity "tick" :ttl 60)
				     (rat-kingdom-space-out space 'fact :identity "kept")
				     (setq rat-kingdom-space-test--now 1059.0)
				     (should (rat-kingdom-space-rd space '(event)))
				     (setq rat-kingdom-space-test--now 1060.0)
				     (should-not (rat-kingdom-space-rd space '(event)))
				     (should-not (rat-kingdom-space-in space '(event)))
				     (should-not (rat-kingdom-space-scan space '(event)))
				     (should (eql (rat-kingdom-space-expire space) 1))
				     (should (eql (rat-kingdom-space-expire space) 0))
				     (should (rat-kingdom-space-rd space '(fact :identity "kept")))
				     (let ((archived (rat-kingdom-space-archived space)))
				       (should (equal (length archived) 1))
				       (should (eq (plist-get (car archived) :reason) 'expire))
				       (should (equal (plist-get (car archived) :archived) 1060.0)))))

(ert-deftest rat-kingdom-space-test-sweep-archives-one-owner ()
  (rat-kingdom-space-test-with-space space
				     (rat-kingdom-space-out space 'story :identity "S-1" :owner "S-1"
							    :payload '(:at done))
				     (rat-kingdom-space-out space 'result :identity "S-1" :owner "S-1"
							    :payload '(:commit "abc"))
				     (rat-kingdom-space-out space 'result :identity "S-2" :owner "S-2")
				     (rat-kingdom-space-out space 'fact :scope "repo" :identity "learned")
				     (should (eql (rat-kingdom-space-sweep space "S-1") 2))
				     (should (eql (rat-kingdom-space-sweep space "S-1") 0))
				     (should (equal (mapcar (lambda (tuple) (plist-get tuple :identity))
							    (rat-kingdom-space-scan space '(_)))
						    '("S-2" "learned")))
				     (let ((archived (rat-kingdom-space-archived space "S-1")))
				       (should (equal (mapcar (lambda (tuple) (plist-get tuple :category))
							      archived)
						      '(story result)))
				       (should (equal (plist-get (cadr archived) :payload) '(:commit "abc")))
				       (should (eq (plist-get (car archived) :reason) 'sweep)))
				     (should-not (rat-kingdom-space-archived space "S-2"))
				     (should-error (rat-kingdom-space-sweep space nil))))

;;;; Transactions, hooks and the log

(ert-deftest rat-kingdom-space-test-failed-transaction-keeps-nothing ()
  (rat-kingdom-space-test-with-space space
				     (let (seen)
				       (add-hook 'rat-kingdom-space-change-functions
						 (lambda (_space op _subject) (push op seen)))
				       (rat-kingdom-space-out space 'available :identity "T-1")
				       (setq seen nil)
				       (should-error
					(rat-kingdom-space-with-transaction space
					  (rat-kingdom-space-out space 'fact :identity "f")
					  (rat-kingdom-space-in space '(available))
					  (error "Boom")))
				       (should-not seen)
				       (should-not (rat-kingdom-space-rd space '(fact)))
				       (should (rat-kingdom-space-rd space '(available :identity "T-1")))
				       (should (equal (mapcar (lambda (op) (plist-get op :op))
							      (rat-kingdom-space-ops space))
						      '(out)))
				       ;; The space still works afterwards.
				       (should (rat-kingdom-space-out space 'fact :identity "after"))
				       (should (equal seen '(out))))))

(ert-deftest rat-kingdom-space-test-changes-are-announced-after-commit ()
  (rat-kingdom-space-test-with-space space
				     (let (seen visible)
				       (add-hook 'rat-kingdom-space-change-functions
						 (lambda (space op subject)
						   (push (cons op (or (plist-get subject :identity)
								      (plist-get subject :count)))
							 seen)
						   ;; By now the whole transaction is readable.
						   (push (length (rat-kingdom-space-scan space '(_))) visible)))
				       (rat-kingdom-space-with-transaction space
					 (rat-kingdom-space-out space 'available :identity "T-1" :owner "E")
					 (rat-kingdom-space-out space 'available :identity "T-2" :owner "E")
					 (rat-kingdom-space-in space '(available))
					 (should-not seen))
				       (should (equal (reverse seen)
						      '((out . "T-1") (out . "T-2") (in . "T-1"))))
				       (should (equal visible '(1 1 1)))
				       (setq seen nil)
				       (rat-kingdom-space-sweep space "E")
				       (should (equal seen '((sweep . 1)))))))

(ert-deftest rat-kingdom-space-test-a-failing-change-function-stops-nothing ()
  (rat-kingdom-space-test-with-space space
				     (let (seen (debug-on-error nil) (inhibit-message t))
				       (add-hook 'rat-kingdom-space-change-functions
						 (lambda (&rest _) (push 'second seen)) t)
				       (add-hook 'rat-kingdom-space-change-functions
						 (lambda (&rest _) (error "Broken")))
				       (should (rat-kingdom-space-out space 'fact :identity "f"))
				       (should (equal seen '(second))))))

(ert-deftest rat-kingdom-space-test-ops-log-records-each-write ()
  (rat-kingdom-space-test-with-space space
				     (rat-kingdom-space-out space 'available :scope "repo" :identity "T-1"
							    :payload '(:priority 2) :actor "adapter")
				     (rat-kingdom-space-in space '(available) :actor "engine")
				     (rat-kingdom-space-out space 'fact :identity "f")
				     (rat-kingdom-space-retract space '(fact) :actor 'king)
				     (let ((ops (rat-kingdom-space-ops space)))
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
							    (rat-kingdom-space-ops space 2))
						    '(out retract)))))

;;;; Files and other writers

(ert-deftest rat-kingdom-space-test-tuples-survive-reopening ()
  (let ((file (make-temp-file "rat-kingdom-space-test" nil ".db")))
    (unwind-protect
        (progn
          (let ((space (rat-kingdom-space-open file)))
            (rat-kingdom-space-out space 'fact :identity "kept" :payload '(:n 1))
            (rat-kingdom-space-close space))
          (let ((space (rat-kingdom-space-open file)))
            (should (equal (plist-get (rat-kingdom-space-rd space '(fact :identity "kept"))
                                      :payload)
                           '(:n 1)))
            (rat-kingdom-space-close space)))
      (dolist (suffix '("" "-wal" "-shm"))
        (ignore-errors (delete-file (concat file suffix)))))))

(ert-deftest rat-kingdom-space-test-open-refuses-a-newer-schema ()
  (let ((file (make-temp-file "rat-kingdom-space-test" nil ".db")))
    (unwind-protect
        (progn
          (let ((db (sqlite-open file)))
            (sqlite-execute db "PRAGMA user_version = 99")
            (sqlite-close db))
          (should-error (rat-kingdom-space-open file)))
      (dolist (suffix '("" "-wal" "-shm"))
        (ignore-errors (delete-file (concat file suffix)))))))

(ert-deftest rat-kingdom-space-test-another-writer-is-noticed ()
  (rat-kingdom-space-test-with-space space
				     (rat-kingdom-space-out space 'fact :identity "ours")
				     (let ((before (rat-kingdom-space-data-version space))
					   (other (sqlite-open (rat-kingdom-space-file space))))
				       (should (eql before (rat-kingdom-space-data-version space)))
				       (unwind-protect
					   (sqlite-execute
					    other
					    "INSERT INTO tuples (category, scope, identity, payload, modality,
                                created, expires)
            VALUES ('event', 'system', 'webhook', '{\"kind\":\"push\"}',
                    'affine', 1000.0, 1300.0)")
					 (sqlite-close other))
				       (should-not (eql before (rat-kingdom-space-data-version space)))
				       (let ((event (rat-kingdom-space-in space '(event :kind $kind))))
					 (should (equal (plist-get event :identity) "webhook"))
					 (should (equal (plist-get event :payload) '(:kind "push")))))))

(provide 'rat-kingdom-space-test)
;;; rat-kingdom-space-test.el ends here
