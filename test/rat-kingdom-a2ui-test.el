;;; rat-kingdom-a2ui-test.el --- Tests for the a2ui guidance -*- lexical-binding: t; -*-

;;; Commentary:

;; Batch tests that the agents who talk with the user, the king and
;; consuls, are told to show concepts, implementation details and plans
;; visually with a2ui, and that workers, researchers and foremen are not.

;;; Code:

(require 'ert)
;; The whole package, so that its files load in their usual order.
(require 'rat-kingdom)

(ert-deftest rat-kingdom-a2ui-test-who-is-told ()
  (cl-flet ((flat (text) (replace-regexp-in-string "[ \n]+" " " text)))
    (dolist (text (list rat-kingdom-king-instructions
                        rat-kingdom-consul-instructions))
      (let ((text (flat text)))
        (should (string-search "When you explain a concept, walk through \
implementation details, or lay out a plan" text))
        (should (string-search "a plan with steps or dependencies" text))
        (should (string-search "with a2ui" text))
        (should (string-search "a2ui_catalog" text))
        (should (string-search "render_a2ui" text))
        (should (string-search "Keep the text answer complete" text))
        (should (string-search "if the a2ui tools are not available" text))))
    (dolist (text (list rat-kingdom-run-rat-instructions
                        rat-kingdom-run-researcher-instructions
                        rat-kingdom-foreman-instructions))
      (should-not (string-search "a2ui" text)))))

(provide 'rat-kingdom-a2ui-test)
;;; rat-kingdom-a2ui-test.el ends here
