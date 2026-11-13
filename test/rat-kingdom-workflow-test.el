;;; rat-kingdom-workflow-test.el --- Tests for workflows -*- lexical-binding: t; -*-

;;; Commentary:

;; Batch tests for workflow definitions and their validation.

;;; Code:

(require 'ert)
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

(provide 'rat-kingdom-workflow-test)
;;; rat-kingdom-workflow-test.el ends here
