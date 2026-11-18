;;; rat-kingdom-name-test.el --- Tests for rats' names -*- lexical-binding: t; -*-

;;; Commentary:

;; Batch tests for rats' names: how they are given, in turn and never
;; to two live rats, across a restart too, and where they are shown.
;; They use the repository fixture of rat-kingdom-story-test.el, with
;; the backend that starts no agent.

;;; Code:

(require 'ert)
(require 'rat-kingdom)
(require 'rat-kingdom-story-test)
(require 'rat-kingdom-king-test)

(defmacro rat-kingdom-name-test-with-repo (vars &rest body)
  "Run BODY with VARS, (SPACE PATH), a repository \"demo\" and the king.
Stories follow the workflow story."
  (declare (indent 1) (debug t))
  `(rat-kingdom-story-test-with-repo ,vars
     (let ((rat-kingdom-story-default-workflow "story"))
       (rat-kingdom-king-test--start ,(car vars))
       ,@body)))

(ert-deftest rat-kingdom-name-test-suffixes-and-buffer-names ()
  (should (equal (rat-kingdom-run-suffix "S-3a9c.2") "3a9c"))
  (should (equal (rat-kingdom-run-suffix "S-3a9c") "3a9c"))
  (should (equal (rat-kingdom-run-suffix "C-3a9c") "3a9c"))
  (should (equal (rat-kingdom-run-suffix "S-3a9c/tests.1") "3a9c"))
  (should (equal (rat-kingdom-run-suffix "F-T-1") "T-1"))
  (should (equal (rat-kingdom-run-suffix "S-1.1") "1"))
  (let ((rat (list :id "S-3a9c.1" :role "rat" :name "Pip"))
        (consul (list :id "C-3a9c" :role "consul" :name "Mochi"))
        (foreman (list :id "F-T-1" :role "foreman" :name "Bean")))
    (should (equal (rat-kingdom-run-display-name rat) "Pip-3a9c"))
    (should (equal (rat-kingdom-run-label rat) "Pip-3a9c (S-3a9c.1)"))
    (should (equal (rat-kingdom-agent-shell--buffer-name rat)
                   "rat Pip-3a9c (S-3a9c.1)"))
    (should (equal (rat-kingdom-agent-shell--buffer-name consul)
                   "consul Mochi-3a9c (C-3a9c)"))
    (should (equal (rat-kingdom-agent-shell--buffer-name foreman)
                   "foreman Bean-T-1 (F-T-1)")))
  ;; The king, and a run recorded before names, has none.
  (should-not (rat-kingdom-run-display-name '(:id "king" :role "king")))
  (should (equal (rat-kingdom-run-label '(:id "S-1.1" :role "rat")) "S-1.1"))
  (should (equal (rat-kingdom-agent-shell--buffer-name
                  '(:id "king" :role "king"))
                 "king"))
  ;; Every name is one word, and there are at least sixty.
  (should (>= (length rat-kingdom-rat-names) 60))
  (should (eql (length (cl-remove-duplicates rat-kingdom-rat-names
                                             :test #'equal))
               (length rat-kingdom-rat-names)))
  (dolist (name rat-kingdom-rat-names)
    (should (string-match-p "\\`[A-Z][a-z]+\\'" name))))

(ert-deftest rat-kingdom-name-test-cycle-and-skip-live-rats ()
  (rat-kingdom-story-test-with-repo (space _path)
    (let ((rat-kingdom-rat-names '("Pip" "Nibbles" "Whiskers")))
      (cl-flet ((rat (id)
                  (plist-get (rat-kingdom-run-create
                              space :id id :role 'rat :repo "demo"
                              :worktree "/tmp/")
                             :name)))
        ;; In turn, and kept in the state directory.
        (should (equal (rat "S-0001.1") "Pip"))
        (should (equal (rat "S-0002.1") "Nibbles"))
        (should (file-exists-p (expand-file-name "rat-names"
                                                 rat-kingdom-directory)))
        ;; The king has none.
        (rat-kingdom-run-create space :id "king" :role 'king :worktree "/tmp/")
        (should-not (plist-get (rat-kingdom-run-get space "king") :name))
        ;; Emacs restarts: the runs are interrupted, and still hold
        ;; their names; the place in the list carries on.
        (rat-kingdom-run-update space "S-0001.1" :state "working")
        (rat-kingdom-run-update space "S-0002.1" :state "working")
        (clrhash rat-kingdom-run--handles)
        (should (equal (rat-kingdom-run-reconcile space)
                       '("S-0001.1" "S-0002.1")))
        (should (equal (plist-get (rat-kingdom-run-get space "S-0001.1") :name)
                       "Pip"))
        (should (equal (rat "S-0003.1") "Whiskers"))
        ;; The list wraps; every name is held, so the next is numbered.
        (should (equal (rat "S-0004.1") "Pip2"))
        ;; Once a rat is gone, its name is free again, but only in turn:
        ;; Nibbles is still held, so the next free one is Pip.
        (rat-kingdom-run-stop space "S-0001.1")
        (should (equal (rat "S-0005.1") "Pip"))
        (rat-kingdom-run-stop space "S-0002.1")
        (rat-kingdom-run-stop space "S-0003.1")
        (should (equal (rat "S-0006.1") "Nibbles"))
        (should (equal (rat "S-0007.1") "Whiskers"))))))

(ert-deftest rat-kingdom-name-test-workers-are-named ()
  (rat-kingdom-name-test-with-repo (space _path)
    (rat-kingdom-story-start space "demo" "Add a file" "Any file." "S-3a9c")
    (rat-kingdom-reaction-run space)
    (let* ((run (rat-kingdom-run-get space "S-3a9c.1"))
           (name (rat-kingdom-run-display-name run)))
      (should (equal name "Pip-3a9c"))
      ;; The worker is told its name, and people see it.
      (should (string-search "You are S-3a9c.1, called Pip-3a9c."
                             (rat-kingdom-story-test--prompt "S-3a9c.1")))
      (should (string-search "(waiting for worker Pip-3a9c (S-3a9c.1), \
working)"
                             (rat-kingdom-king-test--ok "status")))
      (should (string-search "Worker Pip-3a9c (S-3a9c.1): working"
                             (rat-kingdom-king-test--ok
                              "story_show" '(story . "S-3a9c")))))
    ;; A second worker of the story keeps its suffix and takes the next
    ;; name.
    (rat-kingdom-king-test--ok "story_move" '(story . "S-3a9c")
                               '(place . "ready") '(note . "Again."))
    (rat-kingdom-reaction-run space)
    (should (equal (rat-kingdom-run-display-name
                    (rat-kingdom-run-get space "S-3a9c.2"))
                   "Nibbles-3a9c"))
    (should (string-search "Worker Nibbles-3a9c (S-3a9c.2): working"
                           (rat-kingdom-king-test--ok
                            "story_show" '(story . "S-3a9c"))))
    ;; The engine's news names it too.
    (rat-kingdom-story-test--call "S-3a9c.2" "block"
                                  '(summary . "Which file?"))
    (rat-kingdom-reaction-run space)
    (should (cl-some (lambda (text)
                       (string-search "The worker Nibbles-3a9c (S-3a9c.2) is \
blocked: Which file?"
                                      text))
                     (rat-kingdom-king-test--news space)))))

(provide 'rat-kingdom-name-test)
;;; rat-kingdom-name-test.el ends here
