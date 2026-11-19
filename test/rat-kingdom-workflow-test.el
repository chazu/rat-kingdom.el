;;; rat-kingdom-workflow-test.el --- Tests for workflows -*- lexical-binding: t; -*-

;;; Commentary:

;; Batch tests for workflow definitions and their validation.

;;; Code:

(require 'ert)
(require 'rat-kingdom-test-helper)
(require 'rat-kingdom-workflow)

(defconst rat-kingdom-workflow-test--sound
  '(:places (ready checking done blocked)
    :start ready
    :final (done)
    :steps ((implement :from ready :spawn rat :to checking)
            (check :from checking :check t :pass done :fail ready)))
  "A small sound workflow.")

(defun rat-kingdom-workflow-test--problems (&rest changes)
  "Return the problems of the sound workflow with CHANGES applied."
  (let ((spec (copy-sequence rat-kingdom-workflow-test--sound)))
    (while changes
      (setq spec (plist-put spec (pop changes) (pop changes))))
    (rat-kingdom-workflow-validate spec)))

(ert-deftest rat-kingdom-workflow-test-built-in-workflows ()
  (let ((story (rat-kingdom-workflow-get 'story))
        (lite (rat-kingdom-workflow-get "story-lite")))
    (should (equal (plist-get story :start) "ready"))
    (should (equal (plist-get story :failure) "blocked"))
    (should (equal (mapcar (lambda (step) (plist-get step :name))
                           (plist-get story :steps))
                   '("implement" "check" "review" "integrate")))
    (should-not (rat-kingdom-workflow-step-named lite "review"))
    (let ((check (rat-kingdom-workflow-step story "checking")))
      (should (eq (plist-get check :kind) :check))
      (should (equal (plist-get check :pass) "review"))
      (should (equal (plist-get check :fail) "ready")))
    ;; An outcome left out leads to the failure place.
    (should (equal (plist-get (rat-kingdom-workflow-step story "ready") :blocked)
                   "blocked"))
    (should (eq (plist-get (rat-kingdom-workflow-step story "review") :with)
                'king))
    (should (rat-kingdom-workflow-final-p story "done"))
    (should-not (rat-kingdom-workflow-final-p story "blocked"))
    (should-not (rat-kingdom-workflow-step story "blocked"))
    (should (member story (rat-kingdom-workflow-list)))
    (should (string-search "check: at checking, check; pass -> review"
                           (rat-kingdom-workflow-describe story)))))

(ert-deftest rat-kingdom-workflow-test-validation ()
  (should-not (rat-kingdom-workflow-test--problems))
  (cl-flet ((bad (text &rest changes)
              (let ((problems (apply #'rat-kingdom-workflow-test--problems
                                     changes)))
                (should (cl-some (lambda (problem)
                                   (string-search text problem))
                                 problems)))))
    (bad "start nowhere is not a place" :start 'nowhere)
    (bad "no final place" :final nil)
    (bad "final place gone is not a place" :final '(gone))
    (bad "failure place lost is not a place" :failure 'lost)
    (bad "cannot be final" :final '(done blocked))
    (bad "listed twice" :places '(ready ready checking done blocked))
    (bad "needs exactly one of"
         :steps '((implement :from ready :to checking)))
    (bad "needs exactly one of"
         :steps '((implement :from ready :spawn rat :check t :to checking)))
    (bad "a name followed by a property list"
         :steps '((implement :from ready :spawn)))
    (bad "does not say where :to leads"
         :steps '((implement :from ready :spawn rat)
                  (check :from checking :check t :pass done)))
    (bad "leads to mars, which is not a place"
         :steps '((implement :from ready :spawn rat :to mars)))
    (bad "taken from mars, which is not a place"
         :steps '((implement :from mars :spawn rat :to done)))
    (bad "More than one step is taken from ready"
         :steps '((implement :from ready :spawn rat :to checking)
                  (again :from ready :spawn rat :to checking)
                  (check :from checking :check t :pass done)))
    (bad "taken from the final place done"
         :steps '((implement :from ready :spawn rat :to checking)
                  (check :from checking :check t :pass done)
                  (more :from done :merge t :to ready)))
    (bad "No final place can be reached"
         :steps '((implement :from ready :spawn rat :to checking)
                  (check :from checking :check t :pass ready)))
    (bad "No step is taken from checking"
         :steps '((implement :from ready :spawn rat :to checking)))
    (bad "The place limbo cannot be reached"
         :places '(ready checking done blocked limbo))
    (bad "timeout of step implement"
         :steps '((implement :from ready :spawn rat :to checking :timeout soon)
                  (check :from checking :check t :pass done)))
    (bad "attempts of step implement"
         :steps '((implement :from ready :spawn rat :to checking :attempts 0)
                  (check :from checking :check t :pass done))))
  ;; Defining an unsound workflow is refused and defines nothing.
  (let ((rat-kingdom-workflow--table nil))
    (should-error (rat-kingdom-workflow-define 'broken :places '(a) :start 'b))
    (should-not (rat-kingdom-workflow-get 'broken))
    (should (apply #'rat-kingdom-workflow-define 'small
                   rat-kingdom-workflow-test--sound))
    (should (rat-kingdom-workflow-get 'small))))

;;;; The kinds of step in workflow composition (DESIGN.md, section 7.1)

(defun rat-kingdom-workflow-test--with-step (step)
  "Return the problems of a workflow whose only step, from ready, is STEP.
STEP is a step's property list without its name and `:from'.  Every
outcome of it may lead to done, ready or blocked."
  (rat-kingdom-workflow-validate
   (list :places '(ready done blocked)
         :start 'ready
         :final '(done)
         :steps (list (append '(only :from ready) step)))))

(ert-deftest rat-kingdom-workflow-test-new-kinds ()
  (should (equal (assq :run rat-kingdom-workflow-kinds) '(:run :pass :fail)))
  (should (equal (assq :gate rat-kingdom-workflow-kinds) '(:gate :to)))
  (should (equal (assq :workflow rat-kingdom-workflow-kinds)
                 '(:workflow :to :fail)))
  ;; Sound values.
  (dolist (step '((:spawn rat :to done)
                  (:spawn researcher :to done)
                  (:spawn rat :to done :brief "Write failing tests first.")
                  (:check t :pass done)
                  (:check (lint) :pass done)
                  (:check (lint test) :pass done :fail ready)
                  (:run (format) :pass done)
                  (:run (format lint) :pass done :fail ready)
                  (:gate (:after 600) :to done)
                  (:gate (:after 0.5) :to done)
                  (:gate (:signal approve) :to done)
                  (:gate (:signal "approve") :to done)
                  (:workflow lint-only :to done)
                  (:workflow "lint-only" :to done :fail ready)))
    (should-not (rat-kingdom-workflow-test--with-step step)))
  ;; Unsound ones, each with what is said about it.
  (dolist (case '(((:spawn king :to done) "spawns king, which is not a role")
                  ((:check nil :pass done) "a check is t or a list")
                  ((:check () :pass done) "a check is t or a list")
                  ((:check lint :pass done) "a check is t or a list")
                  ((:check ("make" "lint") :pass done) "a check is t or a list")
                  ((:check (lint t) :pass done) "a check is t or a list")
                  ((:run nil :pass done) "a run is a list of command names")
                  ((:run t :pass done) "a run is a list of command names")
                  ((:run format :pass done) "a run is a list of command names")
                  ((:run (format :lint) :pass done)
                   "a run is a list of command names")
                  ((:run ("gofmt" "-w") :pass done)
                   "a run is a list of command names")
                  ((:gate 600 :to done) "a gate is (:after SECONDS)")
                  ((:gate (:after 0) :to done) "a gate is (:after SECONDS)")
                  ((:gate (:after -5) :to done) "a gate is (:after SECONDS)")
                  ((:gate (:after soon) :to done) "a gate is (:after SECONDS)")
                  ((:gate (:after 60 :signal go) :to done)
                   "a gate is (:after SECONDS)")
                  ((:gate (:signal nil) :to done) "a gate is (:after SECONDS)")
                  ((:gate (:signal "") :to done) "a gate is (:after SECONDS)")
                  ((:gate (:signal 7) :to done) "a gate is (:after SECONDS)")
                  ((:gate (:until 60) :to done) "a gate is (:after SECONDS)")
                  ((:workflow nil :to done) "a workflow name is a symbol")
                  ((:workflow t :to done) "a workflow name is a symbol")
                  ((:workflow "  " :to done) "a workflow name is a symbol")
                  ((:workflow (lint) :to done) "a workflow name is a symbol")
                  ((:run (format)) "does not say where :pass leads")
                  ((:gate (:after 60)) "does not say where :to leads")
                  ((:workflow lint-only :fail ready)
                   "does not say where :to leads")
                  ((:gate (:after 60) :to mars) "leads to mars")
                  ((:workflow lint-only :to done :fail mars) "leads to mars")
                  ((:check t :pass done :brief "Be careful.")
                   "only a spawn step may have")
                  ((:run (format) :pass done :brief "x")
                   "only a spawn step may have")
                  ((:spawn rat :to done :brief write-tests)
                   "brief of step only is not a string")
                  ((:spawn rat :to done :brief nil)
                   "brief of step only is not a string")
                  ((:run (format) :gate (:after 60) :pass done)
                   "needs exactly one of")))
    (let ((problems (rat-kingdom-workflow-test--with-step (car case))))
      (unless (cl-some (lambda (problem) (string-search (cadr case) problem))
                       problems)
        (ert-fail (list (car case) :expected (cadr case) :got problems))))))

(ert-deftest rat-kingdom-workflow-test-new-kinds-normalized ()
  (let ((workflow
         (rat-kingdom-workflow--normalize
          'composed
          '(:places (ready formatting waiting linting done blocked)
            :start ready
            :final (done)
            :steps ((implement :from ready :spawn rat :to formatting
                               :brief "Write the tests first.")
                    (format :from formatting :run (format) :pass waiting)
                    (wait :from waiting :gate (:signal approve) :to linting)
                    (lint :from linting :workflow lint-only :to done
                          :fail ready))))))
    (let ((implement (rat-kingdom-workflow-step-named workflow "implement"))
          (format (rat-kingdom-workflow-step-named workflow "format"))
          (wait (rat-kingdom-workflow-step-named workflow "wait"))
          (lint (rat-kingdom-workflow-step-named workflow "lint")))
      (should (equal (plist-get implement :brief) "Write the tests first."))
      (should (plist-member format :brief))
      (should-not (plist-get format :brief))
      (should (eq (plist-get format :kind) :run))
      (should (equal (plist-get format :with) '(format)))
      ;; An outcome left out leads to the failure place.
      (should (equal (plist-get format :fail) "blocked"))
      (should (equal (plist-get wait :with) '(:signal approve)))
      (should (equal (plist-get wait :to) "linting"))
      (should (eq (plist-get lint :with) 'lint-only))
      (should (equal (plist-get lint :fail) "ready"))))
  ;; Built-in steps carry :brief, as nil.
  (dolist (step (plist-get (rat-kingdom-workflow-get 'story) :steps))
    (should (plist-member step :brief))
    (should-not (plist-get step :brief))))

(ert-deftest rat-kingdom-workflow-test-new-kinds-reachability ()
  ;; Places are reached through the outcomes of the new kinds.
  (should-not
   (rat-kingdom-workflow-validate
    '(:places (ready formatting waiting linting done blocked)
      :start ready
      :final (done)
      :steps ((implement :from ready :spawn rat :to formatting)
              (format :from formatting :run (format) :pass waiting
                      :fail ready)
              (wait :from waiting :gate (:after 60) :to linting)
              (lint :from linting :workflow lint-only :to done :fail ready)))))
  ;; A place only a missing outcome would lead to cannot be reached.
  (should (member
           "The place linting cannot be reached"
           (rat-kingdom-workflow-validate
            '(:places (ready waiting linting done blocked)
              :start ready
              :final (done)
              :steps ((wait :from ready :gate (:after 60) :to done)
                      (lint :from linting :workflow lint-only :to done))))))
  ;; A :run's :fail and a :workflow's :fail reach their places.
  (should-not
   (rat-kingdom-workflow-validate
    '(:places (ready fixing done blocked)
      :start ready
      :final (done)
      :steps ((lint :from ready :workflow lint-only :to done :fail fixing)
              (fix :from fixing :run (format) :pass ready)))))
  ;; A gate's only outcome must reach a final place somehow.
  (should (member
           "No final place can be reached from the start"
           (rat-kingdom-workflow-validate
            '(:places (ready waiting done blocked)
              :start ready
              :final (done)
              :steps ((wait :from ready :gate (:after 60) :to waiting)
                      (again :from waiting :gate (:signal go) :to ready)))))))

(ert-deftest rat-kingdom-workflow-test-describe-new-kinds ()
  (let ((text (rat-kingdom-workflow-describe
               (rat-kingdom-workflow--normalize
                'composed
                '(:doc "Composed."
                  :places (ready checking formatting waiting signalled
                                 linting done blocked)
                  :start ready
                  :final (done)
                  :steps ((implement :from ready :spawn rat :to checking
                                     :brief "Write failing tests for the \
task and commit them; do not implement it.")
                          (check :from checking :check (lint test)
                                 :pass formatting :fail ready)
                          (format :from formatting :run (format)
                                  :pass waiting)
                          (wait :from waiting :gate (:after 600)
                                :to signalled)
                          (approval :from signalled :gate (:signal approve)
                                    :to linting)
                          (lint :from linting :workflow lint-only :to done
                                :fail ready)))))))
    (dolist (line '("implement: at ready, spawn rat (brief: Write failing \
tests for the task and ...); to -> checking, blocked -> blocked"
                    "check: at checking, check (lint test); pass -> \
formatting, fail -> ready"
                    "format: at formatting, run (format); pass -> waiting, \
fail -> blocked"
                    "wait: at waiting, gate after 600s; to -> signalled"
                    "approval: at signalled, gate signal approve; to -> linting"
                    "lint: at linting, workflow lint-only; to -> done, \
fail -> ready"))
      (unless (string-search line text)
        (ert-fail (list :missing line :in text)))))
  ;; The built-in workflows read as before.
  (let ((text (rat-kingdom-workflow-describe (rat-kingdom-workflow-get 'story))))
    (should (string-search "implement: at ready, spawn rat; to -> checking"
                           text))
    (should (string-search "check: at checking, check; pass -> review" text))
    (should (string-search "review: at review, review king; pass -> integrating"
                           text))
    (should (string-search "integrate: at integrating, merge; to -> done"
                           text))))

(provide 'rat-kingdom-workflow-test)
;;; rat-kingdom-workflow-test.el ends here
