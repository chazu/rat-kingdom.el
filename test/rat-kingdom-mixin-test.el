;;; rat-kingdom-mixin-test.el --- Mixins and aspects -*- lexical-binding: t; -*-

;;; Commentary:

;; Batch tests of workflow composition (DESIGN.md, section 7.1):
;; `rat-kingdom-workflow-expand' applies a workflow's mixins, the
;; configuration's :mixins and its aspects; the built-in mixins
;; no-review and tdd; mixin files, global and per repository; the
;; :mixins configuration key at each layer; workflow_list; and a story
;; run end to end under a policy's :mixins.

;;; Code:

(require 'ert)
(require 'rat-kingdom-test-helper)
(require 'rat-kingdom)
(require 'rat-kingdom-config)
(require 'rat-kingdom-story-test)
(require 'rat-kingdom-king-test)
(require 'rat-kingdom-config-engine-test)
(require 'rat-kingdom-workflow-files-test)
(require 'rat-kingdom-fact-test)

;;;; Helpers

(defun rat-kingdom-mixin-test--story (&rest changes)
  "Return the built-in story workflow with CHANGES to its keys."
  (let ((workflow (copy-sequence (rat-kingdom-workflow-get 'story))))
    (cl-loop for (key value) on changes by #'cddr
             do (setq workflow (plist-put workflow key value)))
    workflow))

(defun rat-kingdom-mixin-test--routes (workflow)
  "Return WORKFLOW's routing: its start, places and each step's outcomes."
  (list (plist-get workflow :start)
        (plist-get workflow :places)
        (mapcar (lambda (step)
                  (cons (plist-get step :name)
                        (cl-loop for outcome
                                 in (cdr (assq (plist-get step :kind)
                                               rat-kingdom-workflow-kinds))
                                 collect (cons outcome
                                               (plist-get step outcome)))))
                (plist-get workflow :steps))))

(defun rat-kingdom-mixin-test--step (workflow name key)
  "Return KEY of the step NAME of WORKFLOW."
  (plist-get (rat-kingdom-workflow-step-named workflow name) key))

(defun rat-kingdom-mixin-test--names (workflow)
  "Return the names of WORKFLOW's steps, in order."
  (mapcar (lambda (step) (plist-get step :name)) (plist-get workflow :steps)))

(defun rat-kingdom-mixin-test--fails (text workflow &optional mixins lookup)
  "Check that WORKFLOW does not expand with MIXINS, for a reason with TEXT."
  (let ((err (should-error (rat-kingdom-workflow-expand workflow mixins lookup)
                           :type 'rat-kingdom-workflow-expansion-error)))
    (should (string-search text (cadr err)))))

(defun rat-kingdom-mixin-test--global (name contents)
  "Make CONTENTS the global mixin file NAME.eld."
  (let ((file (expand-file-name (concat name ".eld")
                                (rat-kingdom-config-mixin-directory))))
    (rat-kingdom-config-engine-test--write file contents)
    file))

(defun rat-kingdom-mixin-test--repo (path name contents)
  "Make CONTENTS the mixin file NAME.eld of the repository at PATH."
  (let ((file (expand-file-name (concat ".rk/mixins/" name ".eld") path)))
    (rat-kingdom-config-engine-test--write file contents)
    file))

(defun rat-kingdom-mixin-test--origins (space &optional repo)
  "Return the names and origins of the mixins of REPO in SPACE."
  (mapcar (lambda (entry) (cons (plist-get (car entry) :name) (nth 1 entry)))
          (rat-kingdom-config-mixins space repo)))

;;;; The built-in mixins

(ert-deftest rat-kingdom-mixin-test-no-review-is-story-lite ()
  (let ((expanded (rat-kingdom-workflow-expand
                   (rat-kingdom-workflow-get 'story) '(no-review))))
    (should (equal (rat-kingdom-mixin-test--routes expanded)
                   (rat-kingdom-mixin-test--routes
                    (rat-kingdom-workflow-get 'story-lite))))
    (should (equal (plist-get expanded :final) '("done")))
    (should (equal (plist-get expanded :failure) "blocked"))
    (should (equal (plist-get expanded :extra-mixins) '(no-review))))
  ;; A workflow without the step is left as it was.
  (should (equal (rat-kingdom-mixin-test--routes
                  (rat-kingdom-workflow-expand
                   (rat-kingdom-workflow-get 'story-lite) '(no-review)))
                 (rat-kingdom-mixin-test--routes
                  (rat-kingdom-workflow-get 'story-lite)))))

(ert-deftest rat-kingdom-mixin-test-tdd ()
  (let ((expanded (rat-kingdom-workflow-expand
                   (rat-kingdom-workflow-get 'story) '(tdd))))
    (should (equal (plist-get expanded :start) "before-implement"))
    (should (equal (rat-kingdom-mixin-test--names expanded)
                   '("before-implement" "implement" "check" "review"
                     "integrate")))
    (should (eq (rat-kingdom-mixin-test--step expanded "before-implement" :kind)
                :spawn))
    (should (eq (rat-kingdom-mixin-test--step expanded "before-implement" :with)
                'rat))
    (should (string-prefix-p "Write failing tests"
                             (rat-kingdom-mixin-test--step
                              expanded "before-implement" :brief)))
    (should (equal (rat-kingdom-mixin-test--step expanded "before-implement" :to)
                   "ready"))
    (should (equal (rat-kingdom-mixin-test--step expanded "before-implement"
                                                 :blocked)
                   "blocked"))
    ;; Every other way into implement's place is unchanged.
    (should (equal (rat-kingdom-mixin-test--step expanded "check" :fail) "ready"))
    (should (equal (rat-kingdom-mixin-test--step expanded "review" :fix) "ready")))
  ;; Where implement's place is not the start, tdd adds nothing.
  (let ((late (rat-kingdom-workflow--normalize
               'late
               '(:places (todo ready checking done blocked)
                 :start todo
                 :final (done)
                 :steps ((warmup :from todo :gate (:after 1) :to ready)
                         (implement :from ready :spawn rat :to checking)
                         (check :from checking :check t :pass done
                                :fail ready))))))
    (should (equal (rat-kingdom-mixin-test--routes
                    (rat-kingdom-workflow-expand late '(tdd)))
                   (rat-kingdom-mixin-test--routes late)))))

;;;; Aspects

(ert-deftest rat-kingdom-mixin-test-before ()
  (let ((expanded (rat-kingdom-workflow-expand
                   (rat-kingdom-mixin-test--story
                    :aspects '((:before check :run (format)))))))
    (should (equal (rat-kingdom-mixin-test--names expanded)
                   '("implement" "before-check" "check" "review" "integrate")))
    ;; Every way into check's place passes through the new step.
    (should (equal (rat-kingdom-mixin-test--step expanded "implement" :to)
                   "before-check"))
    (should (equal (rat-kingdom-mixin-test--step expanded "integrate" :stale)
                   "before-check"))
    (should (equal (rat-kingdom-mixin-test--step expanded "before-check" :from)
                   "before-check"))
    (should (equal (rat-kingdom-mixin-test--step expanded "before-check" :pass)
                   "checking"))
    (should (equal (rat-kingdom-mixin-test--step expanded "before-check" :fail)
                   "blocked"))
    (should (member "before-check" (plist-get expanded :places))))
  ;; Before the start, with :entry all, the new place is the start and
  ;; every way back in passes through it too.
  (let ((expanded (rat-kingdom-workflow-expand
                   (rat-kingdom-mixin-test--story
                    :aspects '((:before implement :gate (:after 60)))))))
    (should (equal (plist-get expanded :start) "before-implement"))
    (should (equal (rat-kingdom-mixin-test--step expanded "check" :fail)
                   "before-implement"))
    (should (equal (rat-kingdom-mixin-test--step expanded "before-implement" :to)
                   "ready")))
  ;; :entry start redirects only the start.
  (let ((expanded (rat-kingdom-workflow-expand
                   (rat-kingdom-mixin-test--story
                    :aspects '((:before check :entry start :run (format)))))))
    (should (equal (rat-kingdom-mixin-test--routes expanded)
                   (rat-kingdom-mixin-test--routes
                    (rat-kingdom-workflow-get 'story))))))

(ert-deftest rat-kingdom-mixin-test-after ()
  (let ((expanded (rat-kingdom-workflow-expand
                   (rat-kingdom-mixin-test--story
                    :aspects '((:after implement :run (format)
                                       :fail ready))))))
    (should (equal (rat-kingdom-mixin-test--names expanded)
                   '("implement" "after-implement" "check" "review"
                     "integrate")))
    (should (equal (rat-kingdom-mixin-test--step expanded "implement" :to)
                   "after-implement"))
    (should (equal (rat-kingdom-mixin-test--step expanded "after-implement" :pass)
                   "checking"))
    ;; The body may name its other outcomes.
    (should (equal (rat-kingdom-mixin-test--step expanded "after-implement" :fail)
                   "ready"))
    (should (equal (rat-kingdom-mixin-test--step expanded "after-implement" :with)
                   '(format)))
    ;; Only the first outcome is moved.
    (should (equal (rat-kingdom-mixin-test--step expanded "implement" :blocked)
                   "blocked"))))

(ert-deftest rat-kingdom-mixin-test-around ()
  (let ((expanded (rat-kingdom-workflow-expand
                   (rat-kingdom-mixin-test--story
                    :aspects '((:around check :timeout 900)
                               (:around t :attempts 2 :brief "Be careful."))))))
    (should (eql (rat-kingdom-mixin-test--step expanded "check" :timeout) 900))
    (should-not (rat-kingdom-mixin-test--step expanded "review" :timeout))
    (dolist (name '("implement" "check" "review" "integrate"))
      (should (eql (rat-kingdom-mixin-test--step expanded name :attempts) 2)))
    ;; A brief is set on spawn steps only.
    (should (equal (rat-kingdom-mixin-test--step expanded "implement" :brief)
                   "Be careful."))
    (should-not (rat-kingdom-mixin-test--step expanded "check" :brief))
    (should (equal (rat-kingdom-mixin-test--routes expanded)
                   (rat-kingdom-mixin-test--routes
                    (rat-kingdom-workflow-get 'story))))))

(ert-deftest rat-kingdom-mixin-test-multiple-matches ()
  ;; A kind matches every step of it; the same step matched twice gets a
  ;; suffix; steps an aspect added are never matched again.
  (let ((expanded (rat-kingdom-workflow-expand
                   (rat-kingdom-mixin-test--story
                    :aspects '((:after check :run (format))
                               (:after :check :run (lint))
                               (:before t :gate (:after 5))
                               (:around :run :timeout 30))))))
    (should (equal (rat-kingdom-mixin-test--names expanded)
                   '("before-implement" "implement" "before-check" "check"
                     "after-check-2" "after-check" "before-review" "review"
                     "before-integrate" "integrate")))
    (should (equal (rat-kingdom-mixin-test--step expanded "check" :pass)
                   "after-check-2"))
    (should (equal (rat-kingdom-mixin-test--step expanded "after-check-2" :pass)
                   "after-check"))
    (should (equal (rat-kingdom-mixin-test--step expanded "after-check" :pass)
                   "before-review"))
    ;; The added run steps were not matched by (:around :run ...) nor
    ;; given a before- step by (:before t ...).
    (should-not (rat-kingdom-mixin-test--step expanded "after-check" :timeout))
    (should-not (rat-kingdom-workflow-step-named expanded "before-after-check"))
    ;; A match that matches nothing is skipped.
    (should (equal (rat-kingdom-mixin-test--routes
                    (rat-kingdom-workflow-expand
                     (rat-kingdom-mixin-test--story
                      :aspects '((:after nothing :run (format))
                                 (:around :gate :timeout 9)))))
                   (rat-kingdom-mixin-test--routes
                    (rat-kingdom-workflow-get 'story))))))

(ert-deftest rat-kingdom-mixin-test-name-taken-by-a-place ()
  (let* ((workflow (rat-kingdom-workflow--normalize
                    'odd
                    '(:places (ready after-implement done blocked)
                      :start ready
                      :final (done)
                      :steps ((implement :from ready :spawn rat
                                         :to after-implement)
                              (check :from after-implement :check t
                                     :pass done :fail ready)))))
         (expanded (rat-kingdom-workflow-expand
                    (plist-put (copy-sequence workflow)
                               :aspects '((:after implement :run (format)))))))
    (should (equal (rat-kingdom-mixin-test--step expanded "implement" :to)
                   "after-implement-2"))
    (should (equal (rat-kingdom-mixin-test--step expanded "after-implement-2"
                                                 :pass)
                   "after-implement"))))

;;;; Removing steps and mixins with places and steps

(ert-deftest rat-kingdom-mixin-test-remove ()
  (let* ((mixins
          `(("no-check" :name "no-check" :remove (check nothing))
            ("loop" :name "loop" :remove (spin))
            ("no-implement" :name "no-implement" :remove (implement))))
         (lookup (lambda (name) (cdr (assoc name mixins)))))
    ;; Outcomes that led to the place go where its first outcome led; a
    ;; step the workflow does not have is skipped.
    (let ((expanded (rat-kingdom-workflow-expand
                     (rat-kingdom-workflow-get 'story) '(no-check) lookup)))
      (should-not (member "checking" (plist-get expanded :places)))
      (should (equal (rat-kingdom-mixin-test--step expanded "implement" :to)
                     "review"))
      (should (equal (rat-kingdom-mixin-test--step expanded "integrate" :stale)
                     "review")))
    ;; The start moves on when its step is removed.
    (let ((expanded (rat-kingdom-workflow-expand
                     (rat-kingdom-workflow-get 'story) '(no-implement) lookup)))
      (should (equal (plist-get expanded :start) "checking"))
      (should (equal (rat-kingdom-mixin-test--step expanded "check" :fail)
                     "checking")))
    ;; A first outcome that leads back to its own place cannot be removed.
    (rat-kingdom-mixin-test--fails
     "leads back to its own place"
     (rat-kingdom-workflow--normalize
      'spinning '(:places (ready done blocked) :start ready :final (done)
                  :steps ((spin :from ready :gate (:after 1) :to ready))))
     '(loop) lookup)))

(ert-deftest rat-kingdom-mixin-test-mixin-places-and-steps ()
  (let* ((mixins
          `(("with-review" :name "with-review"
             :places (review)
             :steps ((review :from review :review king :pass integrating
                             :fix ready))
             :aspects ((:after check :entry all :run (x))))
            ("readd" :name "readd" :places (review) :steps ())
            ("restep" :name "restep" :places (extra)
             :steps ((check :from extra :check t :pass done)))))
         (lookup (lambda (name) (cdr (assoc name mixins))))
         (lite (rat-kingdom-workflow-get 'story-lite)))
    ;; An aspect with a wrong shape makes it fail.
    (rat-kingdom-mixin-test--fails "only a :before aspect may have :entry"
                                   lite '(with-review) lookup)
    (setf (alist-get "with-review" mixins nil nil #'equal)
          '(:name "with-review"
            :places (polish)
            :steps ((polish :from polish :spawn rat :to checking))
            :aspects ((:after check :run (lint) :fail polish))))
    ;; Its places and steps go after the workflow's, then its aspects
    ;; apply: here one that leads to its new place.
    (let ((expanded (rat-kingdom-workflow-expand lite '(with-review) lookup)))
      (should (equal (car (last (rat-kingdom-mixin-test--names expanded)))
                     "polish"))
      (should (equal (car (last (plist-get expanded :places))) "polish"))
      (should (equal (rat-kingdom-mixin-test--step expanded "polish" :to)
                     "checking"))
      (should (equal (rat-kingdom-mixin-test--step expanded "polish" :blocked)
                     "blocked"))
      (should (equal (rat-kingdom-mixin-test--step expanded "after-check" :fail)
                     "polish")))
    ;; Unreachable, its place makes the result unsound.
    (setf (alist-get "with-review" mixins nil nil #'equal)
          '(:name "with-review" :places (polish)
            :steps ((polish :from polish :spawn rat :to checking))))
    (rat-kingdom-mixin-test--fails "The place polish cannot be reached"
                                   lite '(with-review) lookup)
    ;; Names that are taken make it fail.
    (rat-kingdom-mixin-test--fails "adds the place review"
                                   (rat-kingdom-workflow-get 'story) '(readd)
                                   lookup)
    (rat-kingdom-mixin-test--fails "adds the step check" lite '(restep)
                                   lookup)))

;;;; Order, failure, purity

(ert-deftest rat-kingdom-mixin-test-order ()
  (let* ((log nil)
         (mixins `(("a" :name "a" :aspects ((:after implement :run (a))))
                   ("b" :name "b" :aspects ((:after implement :run (b))))))
         (lookup (lambda (name) (push name log) (cdr (assoc name mixins))))
         (expanded (rat-kingdom-workflow-expand
                    (rat-kingdom-mixin-test--story
                     :mixins '(a b)
                     :aspects '((:after implement :run (own))))
                    '(b a) lookup)))
    ;; Own mixins, then configured ones, each once where it first
    ;; appears, then own aspects: each :after goes in front of the last.
    (should (equal (nreverse log) '("a" "b")))
    (should (equal (rat-kingdom-mixin-test--step expanded "implement" :to)
                   "after-implement-3"))
    (should (equal (rat-kingdom-mixin-test--step expanded "after-implement-3"
                                                 :with)
                   '(own)))
    (should (equal (rat-kingdom-mixin-test--step expanded "after-implement-2"
                                                 :with)
                   '(b)))
    (should (equal (rat-kingdom-mixin-test--step expanded "after-implement" :with)
                   '(a)))
    (should (equal (plist-get expanded :mixins) '(a b)))
    (should (equal (plist-get expanded :extra-mixins) '(b a)))
    (should (string-search "its mixins a b; the mixins b a of :mixins"
                           (rat-kingdom-workflow-composition expanded)))))

(ert-deftest rat-kingdom-mixin-test-failures ()
  (let ((story (rat-kingdom-workflow-get 'story)))
    (rat-kingdom-mixin-test--fails "there is no mixin called tdd2" story
                                   '(tdd2))
    (rat-kingdom-mixin-test--fails
     "there is no mixin called nope"
     (rat-kingdom-mixin-test--story :mixins '(nope)))
    ;; A result the validator refuses.
    (rat-kingdom-mixin-test--fails
     "the result is not sound: Step after-implement leads to mars"
     (rat-kingdom-mixin-test--story
      :aspects '((:after implement :run (format) :fail mars))))
    (rat-kingdom-mixin-test--fails
     "the result is not sound: Step s is taken from nowhere"
     (rat-kingdom-mixin-test--story :mixins '(stray))
     nil (lambda (_) '(:name "stray"
                       :steps ((s :from nowhere :gate (:after 1) :to done)))))
    ;; A place a mixin adds twice.
    (rat-kingdom-mixin-test--fails
     "adds the place x"
     (rat-kingdom-mixin-test--story :mixins '(dup))
     nil (lambda (_) '(:name "dup" :places ("x" x) :steps ())))
    (rat-kingdom-mixin-test--fails
     "is wrong: the brief of its step is not a string"
     (rat-kingdom-mixin-test--story
      :aspects '((:after implement :spawn rat :brief 7))))
    ;; An aspect of the wrong shape.
    (rat-kingdom-mixin-test--fails
     "is wrong"
     (rat-kingdom-mixin-test--story :aspects '((:after check :entry start
                                                       :run (x)))))))

(ert-deftest rat-kingdom-mixin-test-pure-and-deterministic ()
  (let* ((workflow (rat-kingdom-mixin-test--story
                    :mixins '(tdd)
                    :aspects '((:after :check :run (format))
                               (:around t :timeout 10))))
         (copy (copy-tree workflow))
         (first (rat-kingdom-workflow-expand workflow '(no-review)))
         (second (rat-kingdom-workflow-expand workflow '(no-review))))
    (should (equal first second))
    (should (equal workflow copy))
    (should (equal (rat-kingdom-workflow-get 'story)
                   (rat-kingdom-workflow-expand
                    (rat-kingdom-workflow-get 'story))))
    ;; The built-in story is untouched.
    (should-not (rat-kingdom-mixin-test--step (rat-kingdom-workflow-get 'story)
                                              "check" :timeout))))

;;;; Shapes

(ert-deftest rat-kingdom-mixin-test-shapes ()
  (cl-flet ((bad (text aspect)
              (let ((problem (rat-kingdom-workflow-aspect-problem aspect)))
                (should problem)
                (should (string-search text problem)))))
    (should-not (rat-kingdom-workflow-aspect-problem
                 '(:before implement :entry start :spawn rat :brief "x")))
    (should-not (rat-kingdom-workflow-aspect-problem '(:around t :timeout 9)))
    (bad "is not (:before" '(:during check :run (x)))
    (bad "not a step name" '(:after "check" :run (x)))
    (bad "exactly one of" '(:after check :timeout 9))
    (bad "has :from" '(:after check :from ready :run (x)))
    (bad "names its first outcome :pass" '(:after check :run (x) :pass done))
    (bad ":entry is all or start" '(:before check :entry some :run (x)))
    (bad "only a :before aspect" '(:after check :entry all :run (x)))
    (bad "only a spawn step" '(:after check :run (x) :brief "y"))
    (bad "it sets nothing" '(:around check))
    (bad "it has :to" '(:around check :to done))
    (bad "not a number of seconds" '(:around check :timeout -1))
    (bad "is a list of command names" '(:after check :run "make")))
  ;; Mixins.
  (should-not (rat-kingdom-workflow-mixin-problems
               '(:doc "d" :remove (review) :places (x)
                 :steps ((s :from x :gate (:after 1) :to done))
                 :aspects ((:around t :timeout 1)))))
  (cl-flet ((bad (text spec)
              (should (cl-some (lambda (problem) (string-search text problem))
                               (rat-kingdom-workflow-mixin-problems spec)))))
    (bad "A mixin has :name" '(:name x))
    (bad ":remove is a list of names" '(:remove review))
    (bad ":doc is a string" '(:doc 7))
    (bad "needs exactly one of" '(:steps ((s :from x :to y))))
    (bad "has no :from" '(:steps ((s :gate (:after 1) :to y))))
    (bad "The aspect" '(:aspects ((:after))))
    (bad "A mixin has :doc twice" '(:doc "a" :doc "b")))
  (should-error (rat-kingdom-workflow-define-mixin 'bad :remove 'review))
  ;; A workflow's own mixins and aspects are checked when it is defined.
  (should (string-search
           "no mixin called nope"
           (error-message-string
            (should-error (rat-kingdom-workflow-define
                           'composed-test
                           :places '(ready done blocked) :start 'ready
                           :final '(done)
                           :steps '((implement :from ready :spawn rat :to done))
                           :mixins '(nope))))))
  (should (cl-some (lambda (problem) (string-search ":mixins is a list" problem))
                   (rat-kingdom-workflow-validate
                    '(:places (ready done blocked) :start ready :final (done)
                      :steps ((implement :from ready :spawn rat :to done))
                      :mixins tdd)))))

;;;; Mixin files

(ert-deftest rat-kingdom-mixin-test-files ()
  (rat-kingdom-config-engine-test-with-repo (space path)
    (rat-kingdom-fact-test--other-repo space path)
    (should (equal (rat-kingdom-mixin-test--origins space "demo")
                   '(("no-review" . built-in) ("tdd" . built-in))))
    ;; A global file is every repository's; a repo file is its own and
    ;; shadows the global and built-in ones.
    (let ((slow (rat-kingdom-mixin-test--global
                 "slow" '(:doc "Slow checks." :aspects ((:around check
                                                                 :timeout 5000)))))
          (tdd (rat-kingdom-mixin-test--global
                "tdd" '(:aspects ((:around check :timeout 7)))))
          (mine (rat-kingdom-mixin-test--repo
                 path "slow" '(:aspects ((:around check :timeout 6000))))))
      (should (equal (rat-kingdom-mixin-test--origins space "demo")
                     '(("no-review" . built-in) ("slow" . repo)
                       ("tdd" . global))))
      (should (equal (rat-kingdom-mixin-test--origins space "other")
                     '(("no-review" . built-in) ("slow" . global)
                       ("tdd" . global))))
      (should (equal (plist-get (rat-kingdom-config-mixin space 'slow "other")
                                :doc)
                     "Slow checks."))
      (should (eql (rat-kingdom-mixin-test--step
                    (rat-kingdom-workflow-expand
                     (rat-kingdom-workflow-get 'story) '(slow)
                     (rat-kingdom-config--mixin-lookup space "demo"))
                    "check" :timeout)
                   6000))
      (should (eql (rat-kingdom-mixin-test--step
                    (rat-kingdom-workflow-expand
                     (rat-kingdom-workflow-get 'story) '(slow)
                     (rat-kingdom-config--mixin-lookup space "other"))
                    "check" :timeout)
                   5000))
      (should (file-exists-p slow))
      (should (file-exists-p tdd))
      (should (file-exists-p mine))
      ;; A file is read again when it changes.
      (rat-kingdom-mixin-test--repo path "slow"
                                    '(:aspects ((:around check :timeout 6500))))
      (should (eql (rat-kingdom-mixin-test--step
                    (rat-kingdom-workflow-expand
                     (rat-kingdom-workflow-get 'story) '(slow)
                     (rat-kingdom-config--mixin-lookup space "demo"))
                    "check" :timeout)
                   6500))
      ;; An invalid file is ignored, its error is shown, and the mixin
      ;; falls back to the next one of its name.
      (let ((broken (rat-kingdom-mixin-test--repo
                     path "slow" '(:aspects ((:around check :timeout -3))))))
        (should (equal (cdr (assoc "slow" (rat-kingdom-mixin-test--origins
                                           space "demo")))
                       'global))
        (should (string-search "not a number of seconds"
                               (rat-kingdom-workflow-files-test--error broken)))
        (should (string-search broken (rat-kingdom-king-status space)))
        (should (string-search broken (rat-kingdom-king-workflow-list space)))
        ;; Fixed, it counts again and the error goes.
        (rat-kingdom-mixin-test--repo path "slow" '(:remove (review)))
        (should (equal (cdr (assoc "slow" (rat-kingdom-mixin-test--origins
                                           space "demo")))
                       'repo))
        (should-not (rat-kingdom-workflow-files-test--error broken))
        ;; One that does not read.
        (rat-kingdom-mixin-test--global "bad" "(:remove (review)")
        (should-not (assoc "bad" (rat-kingdom-mixin-test--origins space)))
        (should (string-search "bad.eld" (rat-kingdom-king-status space)))
        ;; A file that is gone is forgotten.
        (delete-file (expand-file-name "bad.eld"
                                       (rat-kingdom-config-mixin-directory)))
        (rat-kingdom-config-mixins space)
        (should-not (cl-find-if (lambda (error)
                                  (string-search "bad.eld" (car error)))
                                (rat-kingdom-config-errors)))))))

(ert-deftest rat-kingdom-mixin-test-workflow-file-with-mixins ()
  (rat-kingdom-config-engine-test-with-repo (space path)
    (rat-kingdom-fact-test--other-repo space path)
    ;; A workflow file may have its own mixins and aspects.
    (rat-kingdom-workflow-files-test--global
     "careful.eld"
     (rat-kingdom-workflow-files-test--spec
      'careful :mixins '(tdd) :aspects '((:around check :timeout 900))))
    (let ((careful (rat-kingdom-config-workflow space 'careful "demo")))
      (should (equal (plist-get careful :start) "before-implement"))
      (should (eql (rat-kingdom-mixin-test--step careful "check" :timeout) 900)))
    ;; One whose mixins its directory cannot see is ignored: a global
    ;; file cannot use a repository's mixin.
    (rat-kingdom-mixin-test--repo path "local" '(:remove (check)))
    (let ((global (rat-kingdom-workflow-files-test--global
                   "uses-local.eld"
                   (rat-kingdom-workflow-files-test--spec 'uses-local
                                                          :mixins '(local))))
          (own (rat-kingdom-workflow-files-test--repo
                path "own.eld"
                (rat-kingdom-workflow-files-test--spec 'own :mixins '(local)))))
      (should-not (rat-kingdom-config-workflow space 'uses-local "demo"))
      (should (string-search "The workflow uses-local cannot be built: there \
is no mixin called local"
                             (rat-kingdom-workflow-files-test--error global)))
      ;; A repository's own file can use it.
      (should (rat-kingdom-config-workflow space 'own "demo"))
      (should-not (rat-kingdom-workflow-files-test--error own))
      (should-not (rat-kingdom-workflow-step-named
                   (rat-kingdom-config-workflow space 'own "demo") "check")))))

;;;; :mixins in the configuration

(ert-deftest rat-kingdom-mixin-test-config-layers ()
  (rat-kingdom-config-engine-test-with-repo (space path)
    (should-not (rat-kingdom-config-get space :mixins :repo "demo"))
    ;; Global.
    (rat-kingdom-config-engine-test--write (rat-kingdom-config-global-file)
                                           '(:mixins (tdd)))
    (should (equal (rat-kingdom-config-get space :mixins :repo "demo") '(tdd)))
    ;; Registration.
    (rat-kingdom-repo-add space path :mixins '(no-review))
    (should (equal (rat-kingdom-config-get space :mixins :repo "demo")
                   '(no-review)))
    (should (equal (plist-get (rat-kingdom-config-registration
                               (rat-kingdom-repo-get space "demo"))
                              :mixins)
                   '(no-review)))
    ;; Repo, replacing, not merging.
    (rat-kingdom-config-engine-test--repo path '(:mixins (tdd no-review)))
    (should (equal (rat-kingdom-config-get space :mixins :repo "demo")
                   '(tdd no-review)))
    ;; Epic and task.
    (rat-kingdom-config-policy-set space "demo" 'epic "E-1" '(:mixins (tdd)))
    (rat-kingdom-config-policy-set space "demo" 'task "T-1"
                                   '(:mixins (no-review)))
    (should (equal (rat-kingdom-config-get space :mixins :repo "demo"
                                           :epic "E-1")
                   '(tdd)))
    (should (equal (rat-kingdom-config-get space :mixins :repo "demo"
                                           :epic "E-1" :task "T-1")
                   '(no-review)))
    ;; config_show names the layer.
    (should (string-search "- :mixins (tdd) (epic)"
                           (rat-kingdom-config-show space "demo" :epic "E-1")))
    (should (string-search "- :mixins (tdd no-review) (repo)"
                           (rat-kingdom-config-show space "demo")))
    ;; The workflow is expanded with them, after its own.
    (let ((workflow (rat-kingdom-config-workflow space 'story "demo" "E-1")))
      (should (equal (plist-get workflow :start) "before-implement"))
      (should (rat-kingdom-workflow-step-named workflow "review")))
    (let ((workflow (rat-kingdom-config-workflow space 'story "demo" nil
                                                 "T-1")))
      (should (equal (plist-get workflow :start) "ready"))
      (should-not (rat-kingdom-workflow-step-named workflow "review")))
    ;; A shape that is wrong is invalid at the layer.
    (should (rat-kingdom-config-validate '(:mixins no-review) 'repo))
    (should (rat-kingdom-config-validate '(:mixins ("no-review")) 'repo))
    (should-not (rat-kingdom-config-validate '(:mixins (no-review)) 'task))
    ;; Not at the defaults layer.
    (should (rat-kingdom-config-validate '(:mixins (tdd)) 'defaults))))

(ert-deftest rat-kingdom-mixin-test-config-unknown-mixin ()
  (rat-kingdom-config-engine-test-with-repo (space path)
    (rat-kingdom-config-engine-test--repo path '(:mixins (tdd2)))
    (let ((problems (rat-kingdom-config-validate-merged space "demo")))
      (should (cl-some (lambda (problem)
                         (string-search "there is no mixin called tdd2" problem))
                       problems)))
    (should (string-search "there is no mixin called tdd2"
                           (rat-kingdom-king-status space)))
    (should (string-search "The workflow story-lite cannot be built: there is \
no mixin called tdd2"
                           (rat-kingdom-config-workflow-problem
                            space 'story-lite "demo")))
    (should-not (rat-kingdom-config-workflow space 'story-lite "demo"))
    ;; A story whose workflow does not expand cannot be started.
    (should (string-search "cannot be built"
                           (error-message-string
                            (should-error (rat-kingdom-story-start
                                           space "demo" "One" nil "S-1")))))
    ;; config_set refuses to add an unknown mixin.
    (rat-kingdom-config-engine-test--repo path nil)
    (should (string-search "there is no mixin called nope"
                           (error-message-string
                            (should-error (rat-kingdom-config-set
                                           space 'epic :mixins '(nope)
                                           :repo "demo" :epic "E-1")))))
    (should-not (rat-kingdom-config-policy-tuple space "demo" 'epic "E-1"))
    ;; And a merged :mixins with which the workflow does not expand.
    (rat-kingdom-mixin-test--repo path "bad-review"
                                  '(:places (review) :steps ()))
    (should (string-search "cannot be built"
                           (error-message-string
                            (should-error (rat-kingdom-config-set
                                           space 'repo :mixins '(bad-review)
                                           :repo "demo")))))
    (should (string-search "Set :mixins"
                           (rat-kingdom-config-set space 'epic :mixins
                                                   '(no-review)
                                                   :repo "demo"
                                                   :epic "E-1")))))

(ert-deftest rat-kingdom-mixin-test-story-stops-when-its-workflow-breaks ()
  (rat-kingdom-config-engine-test-with-repo (space path)
    (rat-kingdom-story-start space "demo" "Waiting" nil "S-2")
    (rat-kingdom-reaction-run space)
    (should (equal (rat-kingdom-story-test--get space "S-2" :phase) "wait"))
    (rat-kingdom-story-start space "demo" "One" nil "S-1")
    ;; The configuration changes under them to a mixin that is not there.
    (rat-kingdom-config-engine-test--repo path '(:mixins (tdd2)))
    (rat-kingdom-reaction-run space)
    ;; The one that arrives at a place goes to its failure place.
    (should (equal (rat-kingdom-story-test--get space "S-1" :phase) "parked"))
    (should (string-search "The workflow story-lite cannot be built: there is \
no mixin called tdd2"
                           (rat-kingdom-story-test--get space "S-1" :reason)))
    ;; The one that waits is reported stuck, with the reason.
    (should (>= (rat-kingdom-story-watch space) 1))
    (should (string-search
             "The workflow story-lite cannot be built: there is no mixin \
called tdd2, so it cannot move"
             (plist-get (plist-get (rat-kingdom-space-rd
                                    space '(stuck :identity "S-2"))
                                   :payload)
                        :reason)))))

;;;; workflow_list

(ert-deftest rat-kingdom-mixin-test-workflow-list ()
  (rat-kingdom-config-engine-test-with-repo (space path)
    (rat-kingdom-fact-test--other-repo space path)
    (rat-kingdom-workflow-files-test--global
     "careful.eld"
     (rat-kingdom-workflow-files-test--spec
      'careful :mixins '(tdd) :aspects '((:around check :timeout 900))))
    (let ((local (rat-kingdom-mixin-test--repo
                  path "local" '(:doc "Local only." :remove (review)))))
      (rat-kingdom-config-engine-test--repo path '(:mixins (local)))
      (let ((text (rat-kingdom-king-workflow-list space)))
        (should (string-search "careful: The workflow careful.\n  (global, from"
                               text))
        (should (string-search "Built from its mixins tdd; its aspects \
\(:around check :timeout 900)." text))
        (should (string-search "before-implement: at before-implement" text))
        (should (string-search "Mixins of every repository:\n- no-review: No \
review: work whose check passes is merged. (built-in)" text))
        (should (string-search "Its :mixins is local" text))
        (should (string-search (format "- local: Local only. (this \
repository's own, from %s)" local)
                               text)))
      (let ((text (rat-kingdom-king-workflow-list space "demo")))
        (should (string-search "Built from the mixins local of :mixins (from \
the repo layer)." text))
        ;; story is shown expanded: no review.
        (should (string-search "check: at checking, check; pass -> \
integrating" text))
        (should-not (string-search "review: at review" text))
        (should (string-search "Mixins demo can use:" text)))
      (let ((text (rat-kingdom-king-workflow-list space "other")))
        (should (string-search "review: at review" text))
        (should-not (string-search "local" text))))
    ;; A workflow that cannot be built is shown with the reason.
    (rat-kingdom-config-engine-test--repo path '(:mixins (gone)))
    (should (string-search "cannot be built: there is no mixin called gone, so \
no story can follow it here"
                           (rat-kingdom-king-workflow-list space "demo")))))

;;;; A story run under a policy's :mixins

(ert-deftest rat-kingdom-mixin-test-story-under-policy-no-review ()
  (rat-kingdom-config-engine-test-with-repo (space path)
    (rat-kingdom-config-engine-test--repo path '(:workflow story))
    (rat-kingdom-config-policy-set space "demo" 'epic "E-1"
                                   '(:mixins (no-review)))
    ;; A story of the epic follows story without its review.
    (rat-kingdom-story-start space "demo" "Of the epic" nil "S-1" nil nil nil
                             "E-1")
    (should (equal (rat-kingdom-story-test--get space "S-1" :workflow) "story"))
    (rat-kingdom-reaction-run space)
    (should (equal (rat-kingdom-story-test--get space "S-1" :step) "implement"))
    (should (string-search "Its workflow is built from the mixins no-review of \
:mixins." (rat-kingdom-king--show space "S-1")))
    (rat-kingdom-story-test--work space "S-1" "epic.txt")
    (rat-kingdom-story-test--settle space "S-1")
    (should-not (rat-kingdom-story-get space "S-1"))
    (should (equal (rat-kingdom-story-test--git path "show"
                                                "rk/integration:epic.txt")
                   "work"))
    ;; A story outside the epic waits for a review.
    (rat-kingdom-story-start space "demo" "Plain" nil "S-2")
    (rat-kingdom-reaction-run space)
    (rat-kingdom-story-test--work space "S-2" "plain.txt")
    (rat-kingdom-story-test--settle space "S-2")
    (should (equal (rat-kingdom-story-test--get space "S-2" :at) "review"))
    (should (equal (rat-kingdom-story-test--get space "S-2" :step) "review"))))

(provide 'rat-kingdom-mixin-test)
;;; rat-kingdom-mixin-test.el ends here
