;;; rat-kingdom-workflow-files-test.el --- Workflows from .eld files -*- lexical-binding: t; -*-

;;; Commentary:

;; Batch tests of workflow files (DESIGN.md, section 7.3): workflows in
;; workflows/*.eld under `rat-kingdom-directory' are every repository's,
;; and those in a repository's .rk/workflows/*.eld are its own.  A repo
;; file shadows a global or built-in workflow of its name for that
;; repository only, and a global file replaces a built-in one.  An
;; invalid file is ignored and shown, as a configuration file is.  Each
;; test has its own `rat-kingdom-directory' and repositories, in a
;; temporary directory.

;;; Code:

(require 'ert)
(require 'rat-kingdom)
(require 'rat-kingdom-config)
(require 'rat-kingdom-story-test)
(require 'rat-kingdom-king-test)
(require 'rat-kingdom-config-engine-test)
(require 'rat-kingdom-fact-test)

(defun rat-kingdom-workflow-files-test--spec (name &rest changes)
  "Return the contents of a workflow file for NAME, with CHANGES.
It is story-lite with its places renamed: it starts at todo.  CHANGES
is a property list whose keys replace those of the workflow."
  (let ((spec (list :name name :doc (format "The workflow %s." name)
                    :places '(todo checking integrating done blocked)
                    :start 'todo
                    :final '(done)
                    :steps '((implement :from todo :spawn rat :to checking)
                             (check :from checking :check t
                                    :pass integrating :fail todo)
                             (integrate :from integrating :merge t :to done
                                        :stale checking)))))
    (cl-loop for (key value) on changes by #'cddr
             do (setq spec (plist-put spec key value)))
    spec))

(defun rat-kingdom-workflow-files-test--global (file contents)
  "Make CONTENTS the global workflow file FILE, a name in workflows/."
  (let ((file (expand-file-name file (rat-kingdom-config-workflow-directory))))
    (rat-kingdom-config-engine-test--write file contents)
    file))

(defun rat-kingdom-workflow-files-test--repo (path file contents)
  "Make CONTENTS the workflow file FILE of the repository at PATH."
  (let ((file (expand-file-name (concat ".rk/workflows/" file) path)))
    (rat-kingdom-config-engine-test--write file contents)
    file))

(defun rat-kingdom-workflow-files-test--names (space &optional repo)
  "Return the names and origins of the workflows of REPO in SPACE."
  (mapcar (lambda (entry) (cons (plist-get (car entry) :name) (nth 1 entry)))
          (rat-kingdom-config-workflows space repo)))

(defun rat-kingdom-workflow-files-test--error (file)
  "Return the error recorded for FILE, or nil."
  (cadr (assoc file (rat-kingdom-config-errors))))

;;;; No files

(ert-deftest rat-kingdom-workflow-files-test-built-in-only ()
  (rat-kingdom-config-engine-test-with-repo (space _path)
    (should (equal (rat-kingdom-workflow-files-test--names space "demo")
                   '(("story" . built-in) ("story-lite" . built-in))))
    (should (equal (rat-kingdom-config-workflow space 'story "demo")
                   (rat-kingdom-workflow-get 'story)))
    (should-not (rat-kingdom-config-workflow space "nothing" "demo"))
    (should-not (rat-kingdom-config-errors))))

;;;; Global and repo files

(ert-deftest rat-kingdom-workflow-files-test-global-file-for-every-repo ()
  (rat-kingdom-config-engine-test-with-repo (space path)
    (rat-kingdom-fact-test--other-repo space path)
    (rat-kingdom-workflow-files-test--global
     "quick.eld" (rat-kingdom-workflow-files-test--spec 'quick))
    (dolist (repo '("demo" "other"))
      (should (equal (cdr (assoc "quick" (rat-kingdom-workflow-files-test--names
                                          space repo)))
                     'global)))
    (rat-kingdom-story-start space "demo" "One" nil "S-1" 'quick)
    (rat-kingdom-story-start space "other" "Two" nil "S-2" "quick")
    (should (equal (rat-kingdom-story-test--get space "S-1" :at) "todo"))
    (should (equal (rat-kingdom-story-test--get space "S-2" :at) "todo"))
    ;; The configuration may name it.
    (rat-kingdom-config-engine-test--repo path '(:workflow quick))
    (should-not (rat-kingdom-config-validate-merged space "demo"))
    (rat-kingdom-story-start space "demo" "Three" nil "S-3")
    (should (equal (rat-kingdom-story-test--get space "S-3" :workflow)
                   "quick"))
    ;; A plan may name it.
    (should (rat-kingdom-epic-check
             '(((key . "a") (title . "A") (description . "Do A.")
                (workflow . "quick")))
             space "other"))
    ;; The built-in workflows are still there.
    (rat-kingdom-story-start space "other" "Four" nil "S-4" 'story)
    (should (equal (rat-kingdom-story-test--get space "S-4" :at) "ready"))))

(ert-deftest rat-kingdom-workflow-files-test-repo-file-for-its-repo-only ()
  (rat-kingdom-config-engine-test-with-repo (space path)
    (let ((other (rat-kingdom-fact-test--other-repo space path)))
      (rat-kingdom-workflow-files-test--repo
       path "mine.eld" (rat-kingdom-workflow-files-test--spec 'mine))
      (should (equal (cdr (assoc "mine" (rat-kingdom-workflow-files-test--names
                                         space "demo")))
                     'repo))
      (should-not (assoc "mine" (rat-kingdom-workflow-files-test--names
                                 space "other")))
      (should-not (assoc "mine" (rat-kingdom-workflow-files-test--names space)))
      (rat-kingdom-story-start space "demo" "One" nil "S-1" 'mine)
      (should (equal (rat-kingdom-story-test--get space "S-1" :at) "todo"))
      (should (string-search
               "There is no workflow called mine"
               (error-message-string
                (should-error (rat-kingdom-story-start space "other" "Two"
                                                       nil "S-2" 'mine)))))
      ;; Configuration naming it is sound for demo only.
      (rat-kingdom-config-engine-test--repo path '(:workflow mine))
      (rat-kingdom-config-engine-test--repo other '(:workflow mine))
      (should-not (rat-kingdom-config-validate-merged space "demo"))
      (should (string-search "There is no workflow called mine"
                             (car (rat-kingdom-config-validate-merged
                                   space "other"))))
      ;; And so is a plan.
      (let ((plan '(((key . "a") (title . "A") (description . "Do A.")
                     (workflow . "mine")))))
        (should (rat-kingdom-epic-check plan space "demo"))
        (should-error (rat-kingdom-epic-check plan space "other"))))))

(ert-deftest rat-kingdom-workflow-files-test-shadowing ()
  (rat-kingdom-config-engine-test-with-repo (space path)
    (rat-kingdom-fact-test--other-repo space path)
    (let ((built-in (rat-kingdom-workflow-get 'story-lite)))
      ;; A global file replaces the built-in workflow, for every repository.
      (rat-kingdom-workflow-files-test--global
       "lite.eld" (rat-kingdom-workflow-files-test--spec
                   'story-lite :doc "Global lite."))
      (should (equal (plist-get (rat-kingdom-config-workflow space 'story-lite)
                                :doc)
                     "Global lite."))
      ;; A repo file shadows both, for its repository only.
      (rat-kingdom-workflow-files-test--repo
       path "lite.eld" (rat-kingdom-workflow-files-test--spec
                        "story-lite" :doc "Demo's lite."
                        :places '(start checking integrating done blocked)
                        :start 'start
                        :steps '((implement :from start :spawn rat
                                            :to checking)
                                 (check :from checking :check t
                                        :pass integrating :fail start)
                                 (integrate :from integrating :merge t
                                            :to done :stale checking))))
      (should (equal (plist-get (rat-kingdom-config-workflow
                                 space 'story-lite "demo")
                                :doc)
                     "Demo's lite."))
      (should (equal (plist-get (rat-kingdom-config-workflow
                                 space 'story-lite "other")
                                :doc)
                     "Global lite."))
      (should (equal (cdr (assoc "story-lite"
                                 (rat-kingdom-workflow-files-test--names
                                  space "demo")))
                     'repo))
      ;; The built-in definition itself is untouched.
      (should (equal (rat-kingdom-workflow-get 'story-lite) built-in))
      ;; The engine follows each repository's view.  These tests' default
      ;; workflow is story-lite.
      (rat-kingdom-story-start space "demo" "One" nil "S-1")
      (rat-kingdom-story-start space "other" "Two" nil "S-2")
      (should (equal (rat-kingdom-story-test--get space "S-1" :at) "start"))
      (should (equal (rat-kingdom-story-test--get space "S-2" :at) "todo"))
      ;; With the files gone, the built-in workflow is back.
      (delete-file (expand-file-name ".rk/workflows/lite.eld" path))
      (delete-file (expand-file-name "lite.eld"
                                     (rat-kingdom-config-workflow-directory)))
      (should (equal (rat-kingdom-config-workflow space 'story-lite "demo")
                     built-in)))))

(ert-deftest rat-kingdom-workflow-files-test-reread-when-changed ()
  (rat-kingdom-config-engine-test-with-repo (space path)
    (let ((file (rat-kingdom-workflow-files-test--repo
                 path "mine.eld" (rat-kingdom-workflow-files-test--spec
                                  'mine))))
      (rat-kingdom-story-start space "demo" "One" nil "S-1" 'mine)
      (should-error (rat-kingdom-story-move space "S-1" "parking"))
      ;; The file changes without the cache being cleared: its new
      ;; modification time is enough.
      (with-temp-file file
        (let ((print-length nil) (print-level nil))
          (prin1 (rat-kingdom-workflow-files-test--spec
                  'mine :places '(todo checking integrating done blocked
                                       parking)
                  :steps '((implement :from todo :spawn rat :to checking)
                           (check :from checking :check t
                                  :pass integrating :fail parking)
                           (park :from parking :spawn rat :to todo)
                           (integrate :from integrating :merge t :to done
                                      :stale checking)))
                 (current-buffer))))
      (set-file-times file (time-add (current-time) 10))
      ;; A changed workflow applies from the token's next move.
      (rat-kingdom-story-move space "S-1" "parking")
      (should (equal (rat-kingdom-story-test--get space "S-1" :at)
                     "parking")))))

;;;; Invalid files

(ert-deftest rat-kingdom-workflow-files-test-invalid-file-is-ignored ()
  (rat-kingdom-config-engine-test-with-repo (space path)
    (let ((unsound (rat-kingdom-workflow-files-test--global
                    "unsound.eld" '(:name unsound :places (a) :start b
                                          :final (a))))
          (unread (rat-kingdom-workflow-files-test--global
                   "unread.eld" "(:name unread :places"))
          (unknown (rat-kingdom-workflow-files-test--repo
                    path "unknown.eld"
                    (rat-kingdom-workflow-files-test--spec 'unknown
                                                           :review t)))
          (nameless (rat-kingdom-workflow-files-test--repo
                     path "nameless.eld"
                     (cddr (rat-kingdom-workflow-files-test--spec 'x))))
          (good (rat-kingdom-workflow-files-test--global
                 "good.eld" (rat-kingdom-workflow-files-test--spec 'good))))
      (should (equal (rat-kingdom-workflow-files-test--names space "demo")
                     '(("good" . global) ("story" . built-in)
                       ("story-lite" . built-in))))
      (should (string-search "The start b is not a place"
                             (rat-kingdom-workflow-files-test--error unsound)))
      (should (string-search "a list is not closed"
                             (rat-kingdom-workflow-files-test--error unread)))
      (should (string-search ":review is not a workflow key"
                             (rat-kingdom-workflow-files-test--error unknown)))
      (should (string-search "It has no :name"
                             (rat-kingdom-workflow-files-test--error nameless)))
      (should-not (rat-kingdom-workflow-files-test--error good))
      ;; A repo file's error is its repository's; a global one, every one's.
      (should (assoc unknown (rat-kingdom-config-errors "demo")))
      (should (assoc unsound (rat-kingdom-config-errors "demo")))
      (should-not (assoc unknown (rat-kingdom-config-errors "elsewhere")))
      ;; Starting a story with one says there is none.
      (should-error (rat-kingdom-story-start space "demo" "One" nil "S-1"
                                             'unsound))
      ;; Status shows them.
      (let ((status (rat-kingdom-king-status space)))
        (should (string-search "Configuration ignored" status))
        (dolist (file (list unsound unread unknown nameless))
          (should (string-search file status))))
      ;; Fixing a file is enough, and so is removing it.
      (rat-kingdom-workflow-files-test--global
       "unsound.eld" (rat-kingdom-workflow-files-test--spec 'unsound))
      (delete-file unread)
      (delete-file unknown)
      (delete-file nameless)
      (should (assoc "unsound" (rat-kingdom-workflow-files-test--names
                                space "demo")))
      (should-not (rat-kingdom-config-errors))
      (should-not (string-search "Configuration ignored"
                                 (rat-kingdom-king-status space))))))

(ert-deftest rat-kingdom-workflow-files-test-same-name-twice ()
  (rat-kingdom-config-engine-test-with-repo (space _path)
    (let ((one (rat-kingdom-workflow-files-test--global
                "one.eld" (rat-kingdom-workflow-files-test--spec 'twice)))
          (two (rat-kingdom-workflow-files-test--global
                "two.eld" (rat-kingdom-workflow-files-test--spec 'twice))))
      (should-not (rat-kingdom-config-workflow space 'twice "demo"))
      (should (string-search "also defined in"
                             (rat-kingdom-workflow-files-test--error one)))
      (should (string-search one (rat-kingdom-workflow-files-test--error two)))
      (delete-file two)
      (should (rat-kingdom-config-workflow space 'twice "demo"))
      (should-not (rat-kingdom-config-errors)))))

;;;; A workflow that is gone

(ert-deftest rat-kingdom-workflow-files-test-gone-workflow-is-stuck ()
  (rat-kingdom-config-engine-test-with-repo (space path)
    (let ((file (rat-kingdom-workflow-files-test--repo
                 path "mine.eld" (rat-kingdom-workflow-files-test--spec
                                  'mine))))
      (rat-kingdom-story-start space "demo" "One" nil "S-1" 'mine)
      (rat-kingdom-reaction-run space)
      (should (equal (rat-kingdom-story-test--get space "S-1" :awaiting)
                     "worker"))
      (should (zerop (rat-kingdom-story-watch space)))
      (delete-file file)
      (should (= (rat-kingdom-story-watch space) 1))
      (should (string-search
               "Its workflow mine is not defined"
               (plist-get (plist-get (rat-kingdom-space-rd
                                      space '(stuck :identity "S-1"))
                                     :payload)
                          :reason))))))

;;;; workflow_list

(ert-deftest rat-kingdom-workflow-files-test-workflow-list ()
  (rat-kingdom-config-engine-test-with-repo (space path)
    (rat-kingdom-fact-test--other-repo space path)
    (let ((quick (rat-kingdom-workflow-files-test--global
                  "quick.eld" (rat-kingdom-workflow-files-test--spec 'quick)))
          (mine (rat-kingdom-workflow-files-test--repo
                 path "mine.eld" (rat-kingdom-workflow-files-test--spec 'mine)))
          (lite (rat-kingdom-workflow-files-test--repo
                 path "lite.eld" (rat-kingdom-workflow-files-test--spec
                                  'story-lite)))
          (broken (rat-kingdom-workflow-files-test--repo
                   path "broken.eld" "(:name broken")))
      (let ((text (rat-kingdom-king-workflow-list space)))
        (should (string-search "Workflows of every repository:" text))
        (should (string-search "\n  (built-in)\n  implement:" text))
        (should (string-search (format "quick: The workflow quick.\n  (global, \
from %s)\n" quick) text))
        (should (string-search "Repository demo has: mine (its own), quick \
\(global), story (built-in), story-lite (its own)." text))
        (should (string-search "Repository other has: quick (global), story \
\(built-in), story-lite (built-in)." text))
        (should (string-search (format "mine: The workflow mine.\n  (this \
repository's own, from %s)\n" mine) text))
        (should (string-search (format "story-lite: The workflow story-lite.\n\
  (this repository's own, from %s; it shadows the built-in one)\n" lite)
                               text))
        (should (string-search "Workflow files ignored" text))
        (should (string-search broken text)))
      ;; For one repository.
      (let ((text (rat-kingdom-king-workflow-list space "other")))
        (should (string-search "Workflows of other:" text))
        (should (string-search "story-lite: As story, with no review: work whose \
check passes is merged.\n  (built-in)\n" text))
        (should-not (string-search "mine" text))
        (should-not (string-search broken text)))
      ;; Through the tool.
      (rat-kingdom-king-test--start space)
      (should (string-search
               "Workflows of demo:"
               (rat-kingdom-king-test--ok "workflow_list" '(repo . "demo"))))
      (should-error (rat-kingdom-king-workflow-list space "nowhere")))))

(provide 'rat-kingdom-workflow-files-test)
;;; rat-kingdom-workflow-files-test.el ends here
