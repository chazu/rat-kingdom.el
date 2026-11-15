;;; rat-kingdom-git-options-test.el --- Tests for the :git configuration -*- lexical-binding: t; -*-

;;; Commentary:

;; Tests for :git (DESIGN.md 7.3 and 11): the format of story branch
;; names, with its specifiers, validation and collision suffixes, and
;; the ways a story's work goes into its target, merge, rebase and
;; squash, with their conflicts, the squashed message, the clean-up of
;; the story branch, staleness, and an epic's feature branch landing
;; squashed.  They use real Git in disposable repositories and the
;; backend that starts no agent; the tests play the workers.

;;; Code:

(require 'ert)
(require 'rat-kingdom)
(require 'rat-kingdom-config)
(require 'rat-kingdom-story-test)
(require 'rat-kingdom-epic-branch-test)

(defun rat-kingdom-git-options-test--set (space value &optional layer id)
  "Set :git to VALUE in SPACE at LAYER, by default demo's repo layer.
ID is the epic's or task's id for those layers."
  (let ((layer (or layer 'repo)))
    (rat-kingdom-config-set space layer :git value :repo "demo"
                            :epic (and (eq layer 'epic) id)
                            :task (and (eq layer 'task) id))))

(defun rat-kingdom-git-options-test--king (tool &rest arguments)
  "Call TOOL as the king with ARGUMENTS, an alist.  Return (TEXT . FAILED)."
  (rat-kingdom-mcp-call '(:run "king" :role king) tool arguments))

(defun rat-kingdom-git-options-test--archived (space id key)
  "Return what the archived token of the story ID in SPACE has under KEY."
  (plist-get (plist-get (cl-find 'story (rat-kingdom-space-archived space id)
                                 :key (lambda (tuple)
                                        (plist-get tuple :category)))
                        :payload)
             key))

(defun rat-kingdom-git-options-test--branch-p (path branch)
  "Return non-nil if the repository at PATH has the local BRANCH."
  (rat-kingdom-git-ok-p path "rev-parse" "--verify" "--quiet"
                        (concat "refs/heads/" branch)))

(defun rat-kingdom-git-options-test--move-target (path file text)
  "Commit FILE with TEXT on main at PATH and move rk/integration there."
  (rat-kingdom-story-test--commit path file text (concat "Target: " file))
  (rat-kingdom-git path "branch" "-f" "rk/integration" "main")
  (rat-kingdom-git-rev path "rk/integration"))

(defun rat-kingdom-git-options-test--wait-checked (space id)
  "Run reactions in SPACE and wait, without moving on, for ID's check."
  (rat-kingdom-reaction-run space)
  (let ((tries 0))
    (while (and (not (rat-kingdom-space-rd space (list 'checked :identity id)))
                (< (cl-incf tries) 200))
      (accept-process-output nil 0.05))))

(defun rat-kingdom-git-options-test--merges (path from to)
  "Return how many merge commits are in FROM..TO at PATH."
  (length (split-string (rat-kingdom-git path "rev-list" "--merges"
                                         (concat from ".." to))
                        "\n" t)))

;;;; The key

(ert-deftest rat-kingdom-git-options-test-branch-specifiers ()
  (dolist (case '(("rats/%i" "rats/S-1")
                  ("%s" "fix-the-login-page")
                  ("%r/%i" "demo/S-1")
                  ("%e/%i" "E-7/S-1")
                  ("w/100%%/%i" "w/100%/S-1")
                  ("%r/%e/%s-%i" "demo/E-7/fix-the-login-page-S-1")))
    (should (equal (rat-kingdom-config-branch-name
                    (car case) "S-1" "  Fix the LOGIN page!! " "demo" "E-7")
                   (cadr case))))
  ;; No epic is none.
  (should (equal (rat-kingdom-config-branch-name "%e/%i" "S-1" "t" "demo" nil)
                 "none/S-1"))
  ;; The slug: lowercased, runs of anything else made one dash, trimmed,
  ;; cut to 40 and trimmed again, story if empty.
  (should (equal (rat-kingdom-config-branch-slug "Über-cool: v2.0 (beta)")
                 "ber-cool-v2-0-beta"))
  (should (equal (rat-kingdom-config-branch-slug (make-string 60 ?a))
                 (make-string 40 ?a)))
  (should (equal (rat-kingdom-config-branch-slug
                  (concat (make-string 39 ?a) " b"))
                 (make-string 39 ?a)))
  (should (equal (rat-kingdom-config-branch-slug "!!! ???") "story"))
  (should (equal (rat-kingdom-config-branch-slug nil) "story"))
  (should-error (rat-kingdom-config-branch-name "x/%q" "S-1" "t" "demo" nil)))

(ert-deftest rat-kingdom-git-options-test-validation ()
  ;; Sound values, at every layer that may set :git.
  (dolist (layer '(defaults global registration repo epic task))
    (should-not (rat-kingdom-config-validate
                 '(:git (:branch "rk/%r/%s-%i" :integrate rebase)) layer)))
  (should-not (rat-kingdom-config-validate '(:git (:integrate "squash"))
                                           'registration))
  ;; Unsound ones.
  (dolist (case '(((:branch "x/%q") "%q, which is not a specifier")
                  ((:branch "x/%i%") "a % at its end")
                  ((:branch "bad name/%i") "has a space")
                  ((:branch "rats/.%i") "starts with .")
                  ((:branch "%i.lock") "ends with .lock")
                  ((:branch "rats//%i") "has //")
                  ((:branch "rats/%i/") "ends with /")
                  ((:branch "-%i") "starts with -")
                  ((:branch "a..b/%i") "has ..")
                  ((:branch "x@{%i") "has @{")
                  ((:branch "") "is a format for branch names")
                  ((:branch rats) "is a format for branch names")
                  ((:integrate fold) "is merge, rebase, squash, not fold")
                  ((:other t) "not one of :branch :integrate")
                  ((:branch) "is a property list")))
    (let ((problems (rat-kingdom-config-validate (list :git (car case)) 'repo)))
      (should (eql (length problems) 1))
      (should (string-search (cadr case) (car problems)))))
  ;; The default is today's behaviour.
  (should (equal (plist-get (rat-kingdom-config-defaults) :git)
                 '(:branch "rats/%i" :integrate merge))))

(ert-deftest rat-kingdom-git-options-test-layers-and-config-set ()
  (rat-kingdom-story-test-with-repo (space path)
    (let ((rat-kingdom-config--errors (make-hash-table :test #'equal)))
      (should (equal (rat-kingdom-config-get space :git :repo "demo")
                     '(:branch "rats/%i" :integrate merge)))
      ;; config_set refuses a bad format or mode, writing nothing.
      (dolist (value '((:branch "x/%q") (:branch "bad name %i")
                       (:integrate fold)))
        (should-error (rat-kingdom-git-options-test--set space value)))
      (should-not (file-exists-p (expand-file-name ".rk/config.eld" path)))
      (let ((answer (rat-kingdom-git-options-test--king
                     "config_set" '(layer . "repo") '(repo . "demo")
                     '(key . ":git") '(value . "(:branch \"a b/%i\")"))))
        (should (cdr answer))
        (should (string-search "Refused, nothing was written" (car answer)))
        (should (string-search "does not make a valid branch name"
                               (car answer))))
      ;; Sub-key by sub-key: the repo's :integrate, the task's :branch.
      (rat-kingdom-git-options-test--set space '(:integrate rebase))
      (rat-kingdom-git-options-test--set space '(:branch "t/%i") 'task "T-9")
      (should (equal (rat-kingdom-config-get space :git :repo "demo"
                                             :task "T-9")
                     '(:branch "t/%i" :integrate rebase)))
      (let ((show (rat-kingdom-config-show space "demo" :task "T-9")))
        (should (string-search "- :git :branch \"t/%i\" (task)" show))
        (should (string-search "- :git :integrate rebase (repo)" show)))
      ;; A hand-edited file with a bad format is ignored as a whole.
      (with-temp-file (expand-file-name ".rk/config.eld" path)
        (insert "(:git (:branch \"x/%z\" :integrate squash))\n"))
      (clrhash rat-kingdom-config--files)
      (should (equal (rat-kingdom-config-get space :git :repo "demo")
                     '(:branch "rats/%i" :integrate merge)))
      (should (string-search "%z, which is not a specifier"
                             (cadr (assoc (expand-file-name ".rk/config.eld"
                                                            path)
                                          (rat-kingdom-config-errors
                                           "demo"))))))))

(ert-deftest rat-kingdom-git-options-test-registration ()
  (rat-kingdom-story-test-with-repo (space path)
    (should-error (rat-kingdom-repo-add space path :git '(:integrate fold)))
    (should-error (rat-kingdom-repo-add space path :git '(:branch "%i/")))
    ;; Stored on the repo tuple, read back as the registration layer.
    (rat-kingdom-repo-add space path :git '(:branch "r/%i" :integrate squash))
    (should (equal (assq :git (rat-kingdom-config-explain space :repo "demo"))
                   '(:git (:branch "r/%i" :integrate squash)
                          (:branch registration :integrate registration))))
    ;; repo_add takes it as Emacs Lisp text.
    (let ((answer (rat-kingdom-git-options-test--king
                   "repo_add" (cons 'path path)
                   '(git . "(:integrate rebase)"))))
      (should-not (cdr answer)))
    (should (equal (rat-kingdom-config-get space :git :repo "demo")
                   '(:branch "rats/%i" :integrate rebase)))
    ;; Without it the registration is as before.
    (rat-kingdom-repo-add space path)
    (should-not (plist-member (rat-kingdom-repo-get space "demo") :git))))

;;;; Branch names

(ert-deftest rat-kingdom-git-options-test-story-branch-from-the-format ()
  (rat-kingdom-story-test-with-repo (space path)
    ;; The default is rats/ID.
    (rat-kingdom-story-start space "demo" "Plain" nil "S-1")
    (should (equal (rat-kingdom-story-test--get space "S-1" :branch-name)
                   "rats/S-1"))
    (rat-kingdom-git-options-test--set space '(:branch "%r/%e/%s-%i"))
    (rat-kingdom-story-start space "demo" "Add the Feature!" nil "S-2" nil nil
                             nil "E-1")
    (rat-kingdom-story-start space "demo" "No epic" nil "S-3")
    (should (equal (rat-kingdom-story-test--get space "S-2" :branch-name)
                   "demo/E-1/add-the-feature-S-2"))
    (should (equal (rat-kingdom-story-test--get space "S-3" :branch-name)
                   "demo/none/no-epic-S-3"))
    ;; A story keeps the name it started with.
    (should (equal (rat-kingdom-story-test--get space "S-1" :branch-name)
                   "rats/S-1"))
    (rat-kingdom-reaction-run space)
    (dolist (case '(("S-1" "rats/S-1")
                    ("S-2" "demo/E-1/add-the-feature-S-2")
                    ("S-3" "demo/none/no-epic-S-3")))
      (let ((worktree (rat-kingdom-story-test--get space (car case) :worktree)))
        (should (equal (rat-kingdom-story-test--get space (car case) :branch)
                       (cadr case)))
        (should (equal (rat-kingdom-git worktree "symbolic-ref" "--short"
                                        "HEAD")
                       (cadr case)))
        (should (string-search (cadr case)
                               (rat-kingdom-story-test--prompt
                                (concat (car case) ".1"))))))
    ;; A name Git refuses starts nothing.
    (rat-kingdom-git-options-test--set space '(:branch "rats/%i"))
    (should-error (rat-kingdom-story-start space "demo" "Bad" nil "S-4..x"))
    (should-not (rat-kingdom-story-get space "S-4..x"))
    ;; The story's work is merged and its branch removed as before.
    (rat-kingdom-story-test--work space "S-2" "feature.txt")
    (rat-kingdom-story-test--settle space "S-2")
    (should-not (rat-kingdom-story-get space "S-2"))
    (should-not (rat-kingdom-git-options-test--branch-p
                 path "demo/E-1/add-the-feature-S-2"))
    (should (equal (rat-kingdom-git path "show" "rk/integration:feature.txt")
                   "work"))))

(ert-deftest rat-kingdom-git-options-test-collision-suffixes ()
  (rat-kingdom-story-test-with-repo (space path)
    (rat-kingdom-git-options-test--set space '(:branch "work/%s"))
    (rat-kingdom-git path "branch" "work/same" "main")
    (rat-kingdom-git path "branch" "work/same-2" "main")
    (rat-kingdom-story-start space "demo" "Same" nil "S-1")
    (rat-kingdom-story-start space "demo" "Same" nil "S-2")
    (rat-kingdom-reaction-run space)
    (should (equal (rat-kingdom-story-test--get space "S-1" :branch)
                   "work/same-3"))
    (should (equal (rat-kingdom-story-test--get space "S-2" :branch)
                   "work/same-4"))
    (should (equal (rat-kingdom-story-test--get space "S-1" :branch-name)
                   "work/same"))
    ;; The branches already there are left alone.
    (should (equal (rat-kingdom-git-rev path "work/same")
                   (rat-kingdom-git-rev path "main")))
    ;; A later worker in the same worktree keeps the recorded branch.
    (rat-kingdom-story-move space "S-1" "ready")
    (rat-kingdom-reaction-run space)
    (should (equal (rat-kingdom-story-test--get space "S-1" :run) "S-1.2"))
    (should (equal (rat-kingdom-story-test--get space "S-1" :branch)
                   "work/same-3"))))

(ert-deftest rat-kingdom-git-options-test-suffixed-branch-with-setup ()
  (rat-kingdom-story-test-with-repo (space path)
    ;; The worktree is made before its setup runs, and the branch is
    ;; recorded only when the worker starts; it is the one made.
    (rat-kingdom-repo-add space path :setup '("true"))
    (rat-kingdom-git path "branch" "rats/S-1" "main")
    (rat-kingdom-story-start space "demo" "Add a file" nil "S-1")
    (rat-kingdom-reaction-run space)
    (let ((tries 0))
      (while (and (not (rat-kingdom-story-test--get space "S-1" :run))
                  (< (cl-incf tries) 200))
        (accept-process-output nil 0.05)
        (rat-kingdom-reaction-run space)))
    (should (equal (rat-kingdom-story-test--get space "S-1" :branch)
                   "rats/S-1-2"))
    (should (string-search "rats/S-1-2" (rat-kingdom-story-test--prompt
                                         "S-1.1")))))

;;;; Integration

(ert-deftest rat-kingdom-git-options-test-merge-is-unchanged ()
  (rat-kingdom-story-test-with-repo (space path)
    (rat-kingdom-story-start space "demo" "Add a file" nil "S-1")
    (rat-kingdom-reaction-run space)
    (let ((before (rat-kingdom-git-rev path "rk/integration")))
      (rat-kingdom-story-test--work space "S-1" "feature.txt")
      (rat-kingdom-story-test--settle space "S-1")
      (should-not (rat-kingdom-story-get space "S-1"))
      (should (equal (rat-kingdom-git-options-test--archived space "S-1"
                                                             :integrate)
                     "merge"))
      (should (equal (rat-kingdom-git path "log" "-1" "--format=%s"
                                      "rk/integration")
                     "Merge S-1: Add a file"))
      (should (equal (rat-kingdom-git path "rev-parse" "rk/integration^1")
                     before))
      (should-not (rat-kingdom-git-options-test--branch-p path "rats/S-1")))))

(ert-deftest rat-kingdom-git-options-test-rebase ()
  (rat-kingdom-story-test-with-repo (space path)
    (rat-kingdom-git-options-test--set space '(:integrate rebase))
    (rat-kingdom-story-start space "demo" "Add a file" nil "S-1")
    (rat-kingdom-reaction-run space)
    ;; The target moves on while the worker works.
    (let* ((moved (rat-kingdom-git-options-test--move-target path "other" "x\n"))
           (worktree (rat-kingdom-story-test--get space "S-1" :worktree)))
      (rat-kingdom-story-test--commit worktree "one.txt" "1\n" "One")
      (rat-kingdom-story-test--work space "S-1" "two.txt")
      (let ((commit (rat-kingdom-git-rev path "rats/S-1")))
        (rat-kingdom-story-test--settle space "S-1")
        (should-not (rat-kingdom-story-get space "S-1"))
        ;; The worker's two commits, replayed on the target: no merge.
        (should (equal (rat-kingdom-git path "log" "--format=%s"
                                        (concat moved "..rk/integration"))
                       "Add two.txt\nOne"))
        (should (equal (rat-kingdom-git path "rev-parse" "rk/integration~2")
                       moved))
        (should (eql (rat-kingdom-git-options-test--merges
                      path moved "rk/integration")
                     0))
        (should (equal (rat-kingdom-git path "show" "rk/integration:two.txt")
                       "work"))
        ;; Not an ancestor of the target, but still the commit checked: gone.
        (should-not (rat-kingdom-git-ancestor-p path commit "rk/integration"))
        (should-not (rat-kingdom-git-options-test--branch-p path "rats/S-1"))
        (should-not (rat-kingdom-reaction-failures space))))))

(ert-deftest rat-kingdom-git-options-test-rebase-conflict ()
  (rat-kingdom-story-test-with-repo (space path)
    (rat-kingdom-git-options-test--set space '(:integrate rebase))
    (rat-kingdom-story-start space "demo" "Edit the readme" nil "S-1")
    (rat-kingdom-reaction-run space)
    (let ((target (rat-kingdom-git-options-test--move-target
                   path "README" "theirs\n")))
      (rat-kingdom-story-test--work space "S-1" "README")
      (rat-kingdom-story-test--settle space "S-1")
      (let ((prompt (rat-kingdom-story-test--prompt "S-1.2"))
            (candidate (expand-file-name "candidates/demo/S-1"
                                         rat-kingdom-directory))
            (worktree (rat-kingdom-story-test--get space "S-1" :worktree)))
        (should (string-search "rebase conflict: your branch no longer \
rebases cleanly onto the target branch. Rebase your branch onto \
rk/integration, resolve the conflicts, commit, and finish again. Files in \
conflict:\nREADME" prompt))
        (should (equal (rat-kingdom-git-rev path "rk/integration") target))
        ;; The rebase was aborted.
        (should-not (rat-kingdom-git-ok-p candidate "rev-parse" "--verify"
                                          "--quiet" "REBASE_HEAD"))
        (should-not (string-search "rebase" (rat-kingdom-git candidate
                                                             "status")))
        ;; The second worker rebases, keeping its version, and reports.
        (rat-kingdom-git worktree "rebase" "-X" "theirs" "rk/integration")
        (should-not (cdr (rat-kingdom-story-test--call
                          "S-1.2" "finish" '(summary . "Rebased.")
                          '(checks . "none"))))
        (rat-kingdom-story-test--settle space "S-1")
        (should-not (rat-kingdom-story-get space "S-1"))
        (should (equal (rat-kingdom-git path "show" "rk/integration:README")
                       "work"))
        (should (equal (rat-kingdom-git path "rev-parse" "rk/integration^")
                       target))))))

(ert-deftest rat-kingdom-git-options-test-squash ()
  (rat-kingdom-story-test-with-repo (space path)
    (rat-kingdom-git-options-test--set space '(:integrate squash))
    (rat-kingdom-story-start space "demo" "Add two files" nil "S-1")
    (rat-kingdom-reaction-run space)
    (let ((before (rat-kingdom-git-rev path "rk/integration"))
          (worktree (rat-kingdom-story-test--get space "S-1" :worktree)))
      (rat-kingdom-story-test--commit worktree "one.txt" "1\n" "One")
      (rat-kingdom-story-test--work space "S-1" "two.txt")
      (rat-kingdom-story-test--settle space "S-1")
      (should-not (rat-kingdom-story-get space "S-1"))
      ;; One commit on the target, with the id, title and summary.
      (should (equal (rat-kingdom-git path "rev-parse" "rk/integration^")
                     before))
      (should (equal (rat-kingdom-git path "log" "-1" "--format=%B"
                                      "rk/integration")
                     "S-1: Add two files\n\nAdded the file."))
      (should (equal (rat-kingdom-git path "log" "-1" "--format=%P"
                                      "rk/integration")
                     before))
      (should (equal (rat-kingdom-git path "show" "rk/integration:one.txt")
                     "1"))
      (should (equal (rat-kingdom-git path "show" "rk/integration:two.txt")
                     "work"))
      (should-not (rat-kingdom-git-options-test--branch-p path "rats/S-1"))
      (should-not (rat-kingdom-reaction-failures space)))))

(ert-deftest rat-kingdom-git-options-test-squash-conflict-and-nothing ()
  (rat-kingdom-story-test-with-repo (space path)
    (rat-kingdom-git-options-test--set space '(:integrate squash))
    (rat-kingdom-story-start space "demo" "Edit the readme" nil "S-1")
    (rat-kingdom-reaction-run space)
    (let ((target (rat-kingdom-git-options-test--move-target
                   path "README" "theirs\n"))
          (worktree (rat-kingdom-story-test--get space "S-1" :worktree)))
      (rat-kingdom-story-test--work space "S-1" "README")
      (rat-kingdom-story-test--settle space "S-1")
      (let ((prompt (rat-kingdom-story-test--prompt "S-1.2")))
        (should (string-search "merge conflict" prompt))
        (should (string-search "README" prompt)))
      (should (equal (rat-kingdom-git-rev path "rk/integration") target))
      ;; The second worker gives up its change: there is nothing to squash.
      (rat-kingdom-git worktree "merge" "-q" "-X" "theirs" "rk/integration")
      (should-not (cdr (rat-kingdom-story-test--call
                        "S-1.2" "finish" '(summary . "Nothing.")
                        '(checks . "none"))))
      (rat-kingdom-story-test--settle space "S-1")
      (let ((prompt (rat-kingdom-story-test--prompt "S-1.3")))
        (should (string-search "nothing to integrate: your branch makes no \
change against rk/integration" prompt)))
      (should (equal (rat-kingdom-git-rev path "rk/integration") target)))))

(ert-deftest rat-kingdom-git-options-test-branch-kept-when-added-to ()
  (rat-kingdom-story-test-with-repo (space path)
    (rat-kingdom-repo-add space path :check '("true"))
    (rat-kingdom-git-options-test--set space '(:integrate squash))
    (rat-kingdom-story-start space "demo" "Add a file" nil "S-1")
    (rat-kingdom-reaction-run space)
    (rat-kingdom-story-test--work space "S-1" "feature.txt")
    (rat-kingdom-git-options-test--wait-checked space "S-1")
    ;; Someone adds to the branch after the check.
    (let ((worktree (rat-kingdom-story-test--get space "S-1" :worktree)))
      (rat-kingdom-story-test--commit worktree "later.txt" "x\n" "Later"))
    (let ((tip (rat-kingdom-git-rev path "rats/S-1")))
      (rat-kingdom-story-test--settle space "S-1")
      (should-not (rat-kingdom-story-get space "S-1"))
      (should (equal (rat-kingdom-git path "show" "rk/integration:feature.txt")
                     "work"))
      (should-not (rat-kingdom-git-ok-p path "show" "rk/integration:later.txt"))
      (should (equal (rat-kingdom-git-rev path "rats/S-1") tip)))))

(ert-deftest rat-kingdom-git-options-test-mode-read-when-the-check-begins ()
  (rat-kingdom-story-test-with-repo (space path)
    (rat-kingdom-repo-add space path :check '("true"))
    (rat-kingdom-git-options-test--set space '(:integrate squash))
    (rat-kingdom-story-start space "demo" "Add a file" nil "S-1")
    (rat-kingdom-reaction-run space)
    (rat-kingdom-story-test--work space "S-1" "feature.txt")
    (rat-kingdom-git-options-test--wait-checked space "S-1")
    ;; A change after the check does not change how the work goes in.
    (rat-kingdom-git-options-test--set space '(:integrate merge))
    (rat-kingdom-story-test--settle space "S-1")
    (should-not (rat-kingdom-story-get space "S-1"))
    (should (equal (rat-kingdom-git path "log" "-1" "--format=%s"
                                    "rk/integration")
                   "S-1: Add a file"))
    (should-not (rat-kingdom-git-options-test--branch-p path "rats/S-1"))))

(ert-deftest rat-kingdom-git-options-test-stale-after-rebase ()
  (rat-kingdom-story-test-with-repo (space path)
    (rat-kingdom-git-options-test--set space '(:integrate rebase))
    (rat-kingdom-story-start space "demo" "Add a file" nil "S-1" 'story)
    (rat-kingdom-reaction-run space)
    (rat-kingdom-git-options-test--move-target path "first" "1\n")
    (rat-kingdom-story-test--work space "S-1" "feature.txt")
    (rat-kingdom-story-test--settle space "S-1")
    (should (equal (rat-kingdom-story-test--place space "S-1") "review"))
    (let ((commit (rat-kingdom-story-test--get space "S-1" :commit))
          (first-head (rat-kingdom-story-test--get space "S-1" :head)))
      (should (equal (rat-kingdom-story-test--get space "S-1" :integrate)
                     "rebase"))
      ;; The rebased head is not the worker's commit, which is what the
      ;; review is of.
      (should-not (equal first-head commit))
      (should (equal (plist-get (plist-get (rat-kingdom-space-rd
                                            space '(review :identity "S-1"))
                                           :payload)
                                :commit)
                     commit))
      ;; The target moves while it waits for its review.
      (let ((moved (rat-kingdom-git-options-test--move-target
                    path "elsewhere" "x\n")))
        (rat-kingdom-story-verdict space "S-1" "pass")
        (rat-kingdom-story-test--settle space "S-1")
        ;; Stale, so checked again: rebased onto the new target, merged
        ;; with no second review and no second worker.
        (should-not (rat-kingdom-story-get space "S-1"))
        (should (equal (rat-kingdom-git-options-test--archived space "S-1"
                                                               :reviewed)
                       commit))
        (should-not (equal (rat-kingdom-git-options-test--archived
                            space "S-1" :head)
                           first-head))
        (should (eql (cl-count 'review rat-kingdom-story-test--events
                               :key #'car)
                     1))
        (should (eql (length rat-kingdom-story-test--started) 1))
        (should (equal (rat-kingdom-git path "rev-parse" "rk/integration^")
                       moved))
        (should (equal (rat-kingdom-git path "log" "-1" "--format=%s"
                                        "rk/integration")
                       "Add feature.txt"))
        (should-not (equal (rat-kingdom-git-rev path "rk/integration") commit))
        (should (equal (rat-kingdom-git path "show" "rk/integration:elsewhere")
                       "x"))
        (should-not (rat-kingdom-git-options-test--branch-p path "rats/S-1"))
        (should-not (rat-kingdom-reaction-failures space))))))

;;;; An epic's landing

(ert-deftest rat-kingdom-git-options-test-epic-lands-squashed ()
  (rat-kingdom-epic-branch-test-with-pair (space fake path)
    (let ((rat-kingdom-config--errors (make-hash-table :test #'equal))
          (integration (rat-kingdom-epic-branch-test--rev path "rk/integration")))
      (rat-kingdom-git-options-test--set space '(:integrate squash) 'epic "T-1")
      (rat-kingdom-epic-branch-test--start)
      (rat-kingdom-reaction-run space)
      (rat-kingdom-epic-dispatch-test--merge space fake "T-2")
      (rat-kingdom-epic-dispatch-test--merge space fake "T-3")
      ;; The stories of the epic were squashed into its branch too.
      (should (eql (rat-kingdom-git-options-test--merges
                    path integration "rk/epic/T-1")
                   0))
      (rat-kingdom-epic-branch-test--landing space "review")
      (should (equal (rat-kingdom-epic-branch-test--rev path "rk/integration")
                     integration))
      (rat-kingdom-king-test--ok "epic_verdict" '(epic . "T-1")
                                 '(value . "pass"))
      (let ((landed (rat-kingdom-epic-branch-test--rev path "rk/integration")))
        ;; One commit on the target, naming the tasks it merged.
        (should (equal (rat-kingdom-git path "log" "-1" "--format=%P" landed)
                       integration))
        (should (equal (rat-kingdom-git path "log" "-1" "--format=%B" landed)
                       "T-1: Plan\n\nT-2\nT-3"))
        (dolist (file '("T-2.txt" "T-3.txt"))
          (should (equal (rat-kingdom-epic-branch-test--show
                          path "rk/integration" file)
                         "work"))))
      (should (equal (rat-kingdom-epic-dispatch-test--state space) "done"))
      ;; The epic's branch is kept after landing, as always.
      (should (rat-kingdom-epic-branch-test--rev path "rk/epic/T-1"))
      (should-not (rat-kingdom-reaction-failures space)))))

(provide 'rat-kingdom-git-options-test)
;;; rat-kingdom-git-options-test.el ends here
