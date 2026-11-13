;;; rat-kingdom-story-test.el --- Tests for runs and stories -*- lexical-binding: t; -*-

;;; Commentary:

;; Batch tests that take a story from start to merge in a disposable
;; repository, with real Git and a backend that starts no agent.  The
;; tests play the agent: they commit in its worktree and call its tools.

;;; Code:

(require 'ert)
(require 'url)
(require 'rat-kingdom-story)
(require 'rat-kingdom-king)

(defvar rat-kingdom-story-test--started nil
  "The runs the fake backend started, newest first, as (RUN PROMPT TOKEN).")

(defvar rat-kingdom-story-test--stopped nil
  "The handles the fake backend stopped.")

(defvar rat-kingdom-story-test--sent nil
  "The texts the fake backend was asked to send, newest first, as (HANDLE . TEXT).")

(defvar rat-kingdom-story-test--busy nil
  "Non-nil makes the fake backend refuse to send.")

(defvar rat-kingdom-story-test--events nil
  "The story events seen, newest first, as (EVENT . ID).")

(defvar rat-kingdom-story-test--now nil
  "If non-nil, the time the space is told it is.")

(defun rat-kingdom-story-test--git (directory &rest args)
  "Run Git with ARGS in DIRECTORY."
  (apply #'rat-kingdom-git directory args))

(defun rat-kingdom-story-test--commit (directory file text message)
  "Write TEXT to FILE in DIRECTORY and commit it with MESSAGE."
  (with-temp-file (expand-file-name file directory)
    (insert text))
  (rat-kingdom-story-test--git directory "add" "-A")
  (rat-kingdom-story-test--git directory "commit" "-m" message))

(defmacro rat-kingdom-story-test-with-repo (vars &rest body)
  "Run BODY with a fresh space and repository.
VARS is (SPACE PATH): the space and the repository's directory.  The
repository is registered as \"demo\" with no check.  Stories follow
the workflow story-lite unless they say otherwise."
  (declare (indent 1) (debug t))
  (let ((root (make-symbol "root")))
    `(let* ((,root (file-name-as-directory
                    (file-truename (make-temp-file "rat-kingdom-story" t))))
            (rat-kingdom-directory (expand-file-name "state/" ,root))
            (rat-kingdom-space-change-functions nil)
            (rat-kingdom-reaction--attachments nil)
            (rat-kingdom-run--handles (make-hash-table :test #'equal))
            (rat-kingdom-mcp--grants (make-hash-table :test #'equal))
            (rat-kingdom-story--checks (make-hash-table :test #'equal))
            (rat-kingdom-story-default-workflow "story-lite")
            (rat-kingdom-king--retry nil)
            (rat-kingdom-story-test--started nil)
            (rat-kingdom-story-test--stopped nil)
            (rat-kingdom-story-test--sent nil)
            (rat-kingdom-story-test--busy nil)
            (rat-kingdom-story-test--events nil)
            (rat-kingdom-story-test--now nil)
            (rat-kingdom-space-now-function
             (lambda () (or rat-kingdom-story-test--now (float-time))))
            (rat-kingdom-story-event-functions
             (list (lambda (_space event story)
                     (push (cons event (plist-get story :identity))
                           rat-kingdom-story-test--events))
                   #'rat-kingdom-king--news))
            (rat-kingdom-run-backend
             (list :start (lambda (run prompt)
                            (let ((token (rat-kingdom-mcp-grant
                                          (plist-get run :id)
                                          (intern (plist-get run :role)))))
                              (push (list run prompt token)
                                    rat-kingdom-story-test--started)
                              (plist-get run :id)))
                   :stop (lambda (handle)
                           (push handle rat-kingdom-story-test--stopped))
                   :send (lambda (handle text)
                           (unless rat-kingdom-story-test--busy
                             (push (cons handle text)
                                   rat-kingdom-story-test--sent)
                             t))))
            (inhibit-message t)
            (,(cadr vars) (expand-file-name "demo/" ,root))
            (,(car vars) (rat-kingdom-space-open
                          (expand-file-name "space.db" rat-kingdom-directory)))
            (rat-kingdom-space--default ,(car vars)))
       (unwind-protect
           (progn
             (make-directory ,(cadr vars))
             (rat-kingdom-story-test--git ,(cadr vars) "init" "-q" "-b" "main")
             (rat-kingdom-story-test--git ,(cadr vars) "config" "user.name" "Test")
             (rat-kingdom-story-test--git ,(cadr vars) "config" "user.email"
                                          "test@example.com")
             (rat-kingdom-story-test--commit ,(cadr vars) "README" "demo\n"
                                             "Initial commit")
             (rat-kingdom-repo-add ,(car vars) ,(cadr vars))
             ,@body)
         (when (timerp rat-kingdom-king--retry)
           (cancel-timer rat-kingdom-king--retry))
         (maphash (lambda (id _process) (rat-kingdom-story--abandon-check id))
                  (copy-hash-table rat-kingdom-story--checks))
         (rat-kingdom-space-close ,(car vars))
         (delete-directory ,root t)))))

(defun rat-kingdom-story-test--call (run-id tool &rest arguments)
  "Call TOOL as the agent of RUN-ID with ARGUMENTS, an alist, over JSON-RPC.
Return (TEXT . FAILED)."
  (let* ((token (nth 2 (cl-find run-id rat-kingdom-story-test--started
                                :key (lambda (entry) (plist-get (car entry) :id))
                                :test #'equal)))
         (reply (rat-kingdom-mcp--rpc
                 (gethash token rat-kingdom-mcp--grants)
                 `((jsonrpc . "2.0") (id . 1) (method . "tools/call")
                   (params . ((name . ,tool) (arguments . ,arguments))))))
         (result (plist-get reply :result)))
    (cons (plist-get (aref (plist-get result :content) 0) :text)
          (eq (plist-get result :isError) t))))

(defun rat-kingdom-story-test--place (space id)
  "Return where the story ID is in SPACE, or nil if it is gone."
  (plist-get (plist-get (rat-kingdom-story-get space id) :payload) :at))

(defun rat-kingdom-story-test--get (space id key)
  "Return what the token of the story ID in SPACE has under KEY."
  (plist-get (plist-get (rat-kingdom-story-get space id) :payload) key))

(defun rat-kingdom-story-test--prompt (run-id)
  "Return the prompt the run RUN-ID was started with."
  (nth 1 (cl-find run-id rat-kingdom-story-test--started
                  :key (lambda (entry) (plist-get (car entry) :id))
                  :test #'equal)))

(defun rat-kingdom-story-test--work (space id file)
  "Play the worker of the story ID in SPACE: commit FILE and call finish.
Return what finish answered."
  (let* ((story (plist-get (rat-kingdom-story-get space id) :payload))
         (worktree (plist-get story :worktree)))
    (rat-kingdom-story-test--commit worktree file "work\n" (concat "Add " file))
    (rat-kingdom-story-test--call (plist-get story :run) "finish"
                                  '(summary . "Added the file.")
                                  '(checks . "none run"))))

(defun rat-kingdom-story-test--settle (space id)
  "Run reactions in SPACE until the check of the story ID has come out."
  (rat-kingdom-reaction-run space)
  (let ((tries 0))
    (while (and (rat-kingdom-space-rd space (list 'story :identity id
                                                  :awaiting "check"))
                (not (rat-kingdom-space-rd space (list 'checked :identity id)))
                (< (cl-incf tries) 200))
      (accept-process-output nil 0.05)))
  (rat-kingdom-reaction-run space))

;;;; Repositories

(ert-deftest rat-kingdom-story-test-repo-add ()
  (rat-kingdom-story-test-with-repo (space path)
    (let ((repo (rat-kingdom-repo-get space "demo")))
      (should (equal (plist-get repo :path) (directory-file-name path)))
      (should (equal (plist-get repo :target) "rk/integration"))
      (should-not (plist-get repo :check))
      (should-not (plist-get repo :workflow)))
    (should (equal (rat-kingdom-git-rev path "rk/integration")
                   (rat-kingdom-git-rev path "main")))
    ;; Registering again replaces the record and keeps the branch.
    (rat-kingdom-story-test--commit path "more" "more\n" "More")
    (rat-kingdom-repo-add space path :check '("make" "check") :workflow 'story)
    (should (equal (plist-get (rat-kingdom-repo-get space "demo") :check)
                   '("make" "check")))
    (should (equal (plist-get (rat-kingdom-repo-get space "demo") :workflow)
                   "story"))
    (should-not (equal (rat-kingdom-git-rev path "rk/integration")
                       (rat-kingdom-git-rev path "main")))
    (should (eql (length (rat-kingdom-repo-list space)) 1))
    (should-error (rat-kingdom-repo-add space path :check "make check"))
    (should-error (rat-kingdom-repo-add space path :name "bad name"))
    (should-error (rat-kingdom-repo-add space temporary-file-directory))
    (let ((empty (expand-file-name "../empty/" path)))
      (make-directory empty)
      (rat-kingdom-story-test--git empty "init" "-q")
      (should-error (rat-kingdom-repo-add space empty)))
    (should-error (rat-kingdom-story-start space "nowhere" "Task"))
    ;; A story follows its own workflow, else the repository's.
    (should-error (rat-kingdom-story-start space "demo" "Task" nil "S-0"
                                           "no-such-workflow"))
    (rat-kingdom-story-start space "demo" "Task" nil "S-1")
    (rat-kingdom-story-start space "demo" "Task" nil "S-2" 'story-lite)
    (should (equal (rat-kingdom-story-test--get space "S-1" :workflow) "story"))
    (should (equal (rat-kingdom-story-test--get space "S-2" :workflow)
                   "story-lite"))))

(ert-deftest rat-kingdom-story-test-warnings-and-sync ()
  (rat-kingdom-story-test-with-repo (space path)
    (should-not (rat-kingdom-story-warnings space "demo"))
    (should (string-search "already" (rat-kingdom-story-sync space "demo")))
    ;; Uncommitted changes in the checkout.
    (with-temp-file (expand-file-name "scratch" path) (insert "x"))
    (let ((warnings (rat-kingdom-story-warnings space "demo")))
      (should (eql (length warnings) 1))
      (should (string-search "uncommitted changes" (car warnings))))
    ;; Commits the target lacks.
    (rat-kingdom-story-test--commit path "scratch" "x\n" "Scratch")
    (let ((warnings (rat-kingdom-story-warnings space "demo")))
      (should (eql (length warnings) 1))
      (should (string-search "has 1 commits that rk/integration lacks"
                             (car warnings)))
      (should (string-search "Syncing" (car warnings))))
    (should (string-search "Moved rk/integration forward"
                           (rat-kingdom-story-sync space "demo")))
    (should (equal (rat-kingdom-git-rev path "rk/integration")
                   (rat-kingdom-git-rev path "main")))
    (should-not (rat-kingdom-story-warnings space "demo"))
    ;; A target that is ahead is left alone; one that diverged is reported.
    (rat-kingdom-story-test--git path "checkout" "-q" "-b" "side")
    (rat-kingdom-story-test--commit path "side" "x\n" "Side")
    (rat-kingdom-story-test--git path "branch" "-f" "rk/integration" "side")
    (rat-kingdom-story-test--git path "checkout" "-q" "main")
    (should (string-search "1 commits ahead"
                           (rat-kingdom-story-sync space "demo")))
    (rat-kingdom-story-test--commit path "mine" "x\n" "Mine")
    (should (string-search "diverged" (rat-kingdom-story-sync space "demo")))
    (should (string-search "diverged"
                           (car (rat-kingdom-story-warnings space "demo"))))
    (should (equal (rat-kingdom-git-rev path "rk/integration")
                   (rat-kingdom-git-rev path "side")))))

;;;; The whole way

(ert-deftest rat-kingdom-story-test-start-to-merge ()
  (rat-kingdom-story-test-with-repo (space path)
    (let ((main (rat-kingdom-git-rev path "main")))
      (should (equal (rat-kingdom-story-start
                      space "demo" "Add the feature file"
                      "It must be called feature.txt." "S-1")
                     "S-1"))
      (should-error (rat-kingdom-story-start space "demo" "Again" nil "S-1"))
      (rat-kingdom-reaction-run space)
      ;; A worker was started in its own worktree and branch.
      (let* ((story (plist-get (rat-kingdom-story-get space "S-1") :payload))
             (worktree (plist-get story :worktree))
             (run (rat-kingdom-run-get space "S-1.1"))
             (started (car rat-kingdom-story-test--started)))
        (should (equal (plist-get story :at) "ready"))
        (should (equal (plist-get story :phase) "wait"))
        (should (equal (plist-get story :step) "implement"))
        (should (equal (plist-get story :awaiting) "worker"))
        (should (equal (plist-get story :run) "S-1.1"))
        (should (eql (plist-get story :attempt) 1))
        (should (equal (plist-get run :state) "working"))
        (should (equal (plist-get run :role) "rat"))
        (should (equal (plist-get run :story) "S-1"))
        (should (file-directory-p worktree))
        (should (equal (rat-kingdom-story-test--git worktree "rev-parse"
                                                    "--abbrev-ref" "HEAD")
                       "rats/S-1"))
        (should (eql (length rat-kingdom-story-test--started) 1))
        (should (string-search "Add the feature file" (nth 1 started)))
        (should (string-search "It must be called feature.txt." (nth 1 started)))
        (should (string-search worktree (nth 1 started)))
        (should-not (string-search "worked on before" (nth 1 started)))
        ;; The worker does the work and reports.
        (let ((answer (rat-kingdom-story-test--work space "S-1" "feature.txt")))
          (should-not (cdr answer))
          (should (string-search "Stop here" (car answer))))
        (should (equal (plist-get (rat-kingdom-run-get space "S-1.1") :state)
                       "ready"))
        (rat-kingdom-story-test--settle space "S-1")
        ;; Merged, cleaned up and archived.
        (should-not (rat-kingdom-story-get space "S-1"))
        (should-not (rat-kingdom-space-scan space '(_ :owner "S-1")))
        (should (equal (rat-kingdom-story-test--git
                        path "show" "rk/integration:feature.txt")
                       "work"))
        (should (string-search
                 "Merge S-1: Add the feature file"
                 (rat-kingdom-story-test--git path "log" "-1" "--format=%s"
                                              "rk/integration")))
        (should-not (file-exists-p worktree))
        (should-not (rat-kingdom-git-ok-p path "rev-parse" "--verify" "--quiet"
                                          "refs/heads/rats/S-1"))
        (should-not (file-exists-p
                     (expand-file-name "candidates/demo/S-1"
                                       rat-kingdom-directory)))
        (should (member "S-1.1" rat-kingdom-story-test--stopped))
        (should (equal rat-kingdom-story-test--events '((done . "S-1"))))
        ;; The archive has the story at done, with the worker's report.
        (let* ((archived (rat-kingdom-space-archived space "S-1"))
               (story (plist-get (cl-find 'story archived
                                          :key (lambda (tuple)
                                                 (plist-get tuple :category)))
                                 :payload)))
          (should (equal (plist-get story :at) "done"))
          (should (equal (plist-get story :summary) "Added the file."))
          (should (equal (plist-get story :integrated)
                         (rat-kingdom-git-rev path "rk/integration")))
          (should (cl-find 'result archived
                           :key (lambda (tuple) (plist-get tuple :category)))))
        ;; The user's checkout was not touched.
        (should (equal (rat-kingdom-git-rev path "main") main))
        (should (equal (rat-kingdom-story-test--git path "rev-parse"
                                                    "--abbrev-ref" "HEAD")
                       "main"))
        (should (string-empty-p
                 (rat-kingdom-story-test--git path "status" "--porcelain")))
        (should-not (file-exists-p (expand-file-name "feature.txt" path)))
        (should-not (rat-kingdom-reaction-failures space))))))

(ert-deftest rat-kingdom-story-test-failed-check-goes-back-to-a-worker ()
  (rat-kingdom-story-test-with-repo (space path)
    (rat-kingdom-repo-add space path
                          :check '("sh" "-c" "echo checking; test -f wanted.txt"))
    (let ((before (rat-kingdom-git-rev path "rk/integration")))
      (rat-kingdom-story-start space "demo" "Add the wanted file" nil "S-1")
      (rat-kingdom-reaction-run space)
      (rat-kingdom-story-test--work space "S-1" "other.txt")
      (rat-kingdom-story-test--settle space "S-1")
      ;; The check failed, so a second worker has the story, in the same
      ;; worktree, and is told why.
      (let ((story (plist-get (rat-kingdom-story-get space "S-1") :payload))
            (prompt (rat-kingdom-story-test--prompt "S-1.2")))
        (should (equal (plist-get story :at) "ready"))
        (should (equal (plist-get story :awaiting) "worker"))
        (should (equal (plist-get story :run) "S-1.2"))
        (should (eql (plist-get story :attempt) 2))
        (should (file-exists-p (expand-file-name "other.txt"
                                                 (plist-get story :worktree))))
        (should (string-search "worked on before" prompt))
        (should (string-search "check failed" prompt))
        (should (string-search "exited with 1" prompt))
        (should (string-search "checking" prompt)))
      (should (equal (plist-get (rat-kingdom-run-get space "S-1.1") :state)
                     "ready"))
      (should (member "S-1.1" rat-kingdom-story-test--stopped))
      (should (equal (rat-kingdom-git-rev path "rk/integration") before))
      ;; The first worker can no longer report.
      (should (cdr (rat-kingdom-story-test--call
                    "S-1.1" "finish" '(summary . "s") '(checks . "c"))))
      ;; The second puts it right, and the story is merged.
      (rat-kingdom-story-test--work space "S-1" "wanted.txt")
      (rat-kingdom-story-test--settle space "S-1")
      (should-not (rat-kingdom-story-get space "S-1"))
      (should (equal (rat-kingdom-story-test--git
                      path "show" "rk/integration:wanted.txt")
                     "work"))
      (should (equal (plist-get
                      (plist-get (cl-find 'checked
                                          (rat-kingdom-space-archived space "S-1")
                                          :key (lambda (tuple)
                                                 (plist-get tuple :category)))
                                 :payload)
                      :value)
                     "pass")))))

(ert-deftest rat-kingdom-story-test-gives-up-after-enough-workers ()
  (rat-kingdom-story-test-with-repo (space path)
    (rat-kingdom-repo-add space path :check '("false"))
    (let ((rat-kingdom-story-attempts 2)
          (before (rat-kingdom-git-rev path "rk/integration")))
      (rat-kingdom-story-start space "demo" "Add a file" nil "S-1")
      (rat-kingdom-reaction-run space)
      (rat-kingdom-story-test--work space "S-1" "one.txt")
      (rat-kingdom-story-test--settle space "S-1")
      (rat-kingdom-story-test--work space "S-1" "two.txt")
      (rat-kingdom-story-test--settle space "S-1")
      (let ((story (plist-get (rat-kingdom-story-get space "S-1") :payload)))
        (should (equal (plist-get story :at) "blocked"))
        (should (equal (plist-get story :phase) "parked"))
        (should (string-search "Gave up after 2 workers"
                               (plist-get story :reason)))
        (should (string-search "check failed" (plist-get story :reason)))
        (should (file-directory-p (plist-get story :worktree))))
      (should (eql (length rat-kingdom-story-test--started) 2))
      (should (equal (car rat-kingdom-story-test--events) '(parked . "S-1")))
      (should (equal (rat-kingdom-git-rev path "rk/integration") before))
      ;; Moved by hand, it gets a full count of workers again.
      (rat-kingdom-repo-add space path :check '("true"))
      (rat-kingdom-story-move space "S-1" "checking")
      (rat-kingdom-story-test--settle space "S-1")
      (should-not (rat-kingdom-story-get space "S-1"))
      (should (equal (rat-kingdom-story-test--git
                      path "show" "rk/integration:two.txt")
                     "work")))))

(ert-deftest rat-kingdom-story-test-merge-conflict-goes-back-to-a-worker ()
  (rat-kingdom-story-test-with-repo (space path)
    (rat-kingdom-story-start space "demo" "Edit the readme" nil "S-1")
    (rat-kingdom-reaction-run space)
    ;; The target gains a different version of the same file meanwhile.
    (rat-kingdom-story-test--commit path "README" "theirs\n" "Theirs")
    (rat-kingdom-story-test--git path "branch" "-f" "rk/integration" "main")
    (let ((target (rat-kingdom-git-rev path "rk/integration")))
      (rat-kingdom-story-test--work space "S-1" "README")
      (rat-kingdom-story-test--settle space "S-1")
      (let ((prompt (rat-kingdom-story-test--prompt "S-1.2"))
            (worktree (rat-kingdom-story-test--get space "S-1" :worktree)))
        (should (equal (rat-kingdom-story-test--get space "S-1" :run) "S-1.2"))
        (should (string-search "merge conflict" prompt))
        (should (string-search "README" prompt))
        (should (equal (rat-kingdom-git-rev path "rk/integration") target))
        ;; The second worker merges the target in and reports.
        (rat-kingdom-story-test--git worktree "merge" "-q" "-X" "ours"
                                     "rk/integration")
        (should-not (cdr (rat-kingdom-story-test--call
                          "S-1.2" "finish" '(summary . "Merged.")
                          '(checks . "none"))))
        (rat-kingdom-story-test--settle space "S-1")
        (should-not (rat-kingdom-story-get space "S-1"))
        (should (equal (rat-kingdom-story-test--git
                        path "show" "rk/integration:README")
                       "work"))))))

(ert-deftest rat-kingdom-story-test-target-that-moved-is-checked-again ()
  (rat-kingdom-story-test-with-repo (space path)
    (rat-kingdom-repo-add space path :check '("true"))
    (rat-kingdom-story-start space "demo" "Add a file" nil "S-1")
    (rat-kingdom-reaction-run space)
    (rat-kingdom-story-test--work space "S-1" "feature.txt")
    ;; Merge and start the check, then wait for it without reacting.
    (rat-kingdom-reaction-run space)
    (let ((tries 0))
      (while (and (not (rat-kingdom-space-rd space '(checked :identity "S-1")))
                  (< (cl-incf tries) 200))
        (accept-process-output nil 0.05)))
    (should (rat-kingdom-space-rd space '(checked :identity "S-1" :value pass)))
    ;; Someone else moves the target before the merge lands.
    (rat-kingdom-story-test--commit path "elsewhere" "x\n" "Elsewhere")
    (rat-kingdom-story-test--git path "branch" "-f" "rk/integration" "main")
    (let ((moved (rat-kingdom-git-rev path "rk/integration")))
      (rat-kingdom-story-test--settle space "S-1")
      ;; Nothing was overwritten: the work was merged onto what was there.
      (should-not (rat-kingdom-story-get space "S-1"))
      (should (rat-kingdom-git-ancestor-p path moved "rk/integration"))
      (should (equal (rat-kingdom-story-test--git
                      path "show" "rk/integration:feature.txt")
                     "work"))
      (should (equal (rat-kingdom-story-test--git
                      path "show" "rk/integration:elsewhere")
                     "x"))
      ;; No second worker was needed.
      (should (eql (length rat-kingdom-story-test--started) 1))
      (should-not (rat-kingdom-reaction-failures space)))))

(ert-deftest rat-kingdom-story-test-checked-out-target-stops-the-story ()
  (rat-kingdom-story-test-with-repo (space path)
    (rat-kingdom-story-start space "demo" "Add a file" nil "S-1")
    (rat-kingdom-reaction-run space)
    (rat-kingdom-story-test--git path "checkout" "-q" "rk/integration")
    (let ((before (rat-kingdom-git-rev path "rk/integration")))
      (rat-kingdom-story-test--work space "S-1" "feature.txt")
      (rat-kingdom-story-test--settle space "S-1")
      (should (equal (rat-kingdom-git-rev path "rk/integration") before))
      (should (equal (rat-kingdom-story-test--place space "S-1") "blocked"))
      (should (string-search "checked out"
                             (rat-kingdom-story-test--get space "S-1" :reason)))
      (should-not (rat-kingdom-reaction-failures space))
      ;; Once it is free, moving the story back lands the merge.
      (rat-kingdom-story-test--git path "checkout" "-q" "main")
      (rat-kingdom-story-move space "S-1" "integrating")
      (rat-kingdom-reaction-run space)
      (should-not (rat-kingdom-story-get space "S-1"))
      (should (equal (rat-kingdom-story-test--git
                      path "show" "rk/integration:feature.txt")
                     "work")))))

;;;; Review

(ert-deftest rat-kingdom-story-test-review-passes-or-sends-back ()
  (rat-kingdom-story-test-with-repo (space path)
    (rat-kingdom-story-start space "demo" "Add a file" nil "S-1" 'story)
    (rat-kingdom-reaction-run space)
    (should-error (rat-kingdom-story-verdict space "S-1" "pass"))
    (rat-kingdom-story-test--work space "S-1" "feature.txt")
    (rat-kingdom-story-test--settle space "S-1")
    ;; Checked, and now it waits for a verdict; nothing is merged.
    (should (equal (rat-kingdom-story-test--place space "S-1") "review"))
    (should (equal (rat-kingdom-story-test--get space "S-1" :awaiting) "review"))
    (should (equal (plist-get (plist-get (rat-kingdom-space-rd
                                          space '(review :identity "S-1"))
                                         :payload)
                              :by)
                   "king"))
    (should (equal (car rat-kingdom-story-test--events) '(review . "S-1")))
    (should (equal (rat-kingdom-git-rev path "rk/integration")
                   (rat-kingdom-git-rev path "main")))
    (should-error (rat-kingdom-story-verdict space "S-1" "maybe"))
    (should-error (rat-kingdom-story-verdict space "S-1" "fix"))
    ;; A fix goes back to a worker with the notes.
    (rat-kingdom-story-verdict space "S-1" "fix" "Call it wanted.txt instead.")
    (rat-kingdom-reaction-run space)
    (should (equal (rat-kingdom-story-test--get space "S-1" :run) "S-1.2"))
    (should (string-search "Call it wanted.txt instead."
                           (rat-kingdom-story-test--prompt "S-1.2")))
    (should-not (rat-kingdom-space-rd space '(review :identity "S-1")))
    (should-not (rat-kingdom-space-rd space '(verdict :identity "S-1")))
    (rat-kingdom-story-test--work space "S-1" "wanted.txt")
    (rat-kingdom-story-test--settle space "S-1")
    (should (equal (rat-kingdom-story-test--place space "S-1") "review"))
    ;; A pass lets it be merged.
    (rat-kingdom-story-verdict space "S-1" 'pass)
    (rat-kingdom-story-test--settle space "S-1")
    (should-not (rat-kingdom-story-get space "S-1"))
    (should (equal (rat-kingdom-story-test--git
                    path "show" "rk/integration:wanted.txt")
                   "work"))))

(ert-deftest rat-kingdom-story-test-reviewed-commit-is-not-reviewed-twice ()
  (rat-kingdom-story-test-with-repo (space path)
    (rat-kingdom-story-start space "demo" "Add a file" nil "S-1" 'story)
    (rat-kingdom-reaction-run space)
    (rat-kingdom-story-test--work space "S-1" "feature.txt")
    (rat-kingdom-story-test--settle space "S-1")
    ;; The target moves while the story waits for its review.
    (rat-kingdom-story-test--commit path "elsewhere" "x\n" "Elsewhere")
    (rat-kingdom-story-test--git path "branch" "-f" "rk/integration" "main")
    (rat-kingdom-story-verdict space "S-1" "pass")
    (rat-kingdom-story-test--settle space "S-1")
    ;; It was checked again on the new target and merged with no new review.
    (should-not (rat-kingdom-story-get space "S-1"))
    (should (eql (cl-count 'review rat-kingdom-story-test--events :key #'car)
                 1))
    (should (equal (rat-kingdom-story-test--git
                    path "show" "rk/integration:feature.txt")
                   "work"))
    (should (equal (rat-kingdom-story-test--git
                    path "show" "rk/integration:elsewhere")
                   "x"))))

;;;; The worker's tools

(ert-deftest rat-kingdom-story-test-finish-refuses-unfinished-work ()
  (rat-kingdom-story-test-with-repo (space _path)
    (rat-kingdom-story-start space "demo" "Add a file" nil "S-1")
    (rat-kingdom-reaction-run space)
    (let ((worktree (rat-kingdom-story-test--get space "S-1" :worktree)))
      (cl-flet ((finish ()
                  (rat-kingdom-story-test--call
                   "S-1.1" "finish" '(summary . "s") '(checks . "c"))))
        ;; Nothing committed.
        (let ((answer (finish)))
          (should (cdr answer))
          (should (string-search "no commits of its own" (car answer))))
        ;; Untracked file.
        (with-temp-file (expand-file-name "stray" worktree) (insert "x"))
        (should (string-search "uncommitted or untracked" (car (finish))))
        (delete-file (expand-file-name "stray" worktree))
        ;; On another branch.
        (rat-kingdom-story-test--git worktree "checkout" "-q" "-b" "elsewhere")
        (should (string-search "not on your branch rats/S-1" (car (finish))))
        (rat-kingdom-story-test--git worktree "checkout" "-q" "rats/S-1")
        ;; A missing argument.
        (let ((answer (rat-kingdom-story-test--call "S-1.1" "finish"
                                                    '(summary . "s"))))
          (should (cdr answer))
          (should (string-search "Missing argument: checks" (car answer))))
        (should-not (rat-kingdom-space-rd space '(result)))
        (should (equal (plist-get (rat-kingdom-run-get space "S-1.1") :state)
                       "working"))
        ;; Done properly, it is recorded.
        (rat-kingdom-story-test--commit worktree "f" "x\n" "Add f")
        (should-not (cdr (finish)))
        (let ((result (plist-get (rat-kingdom-space-rd
                                  space '(result :identity "S-1"))
                                 :payload)))
          (should (equal (plist-get result :commit)
                         (rat-kingdom-git-rev worktree "HEAD")))
          (should (equal (plist-get result :summary) "s"))
          (should (equal (plist-get result :checks) "c"))
          (should (equal (plist-get result :run) "S-1.1")))
        ;; Once the story is merged the run is over and its token is void.
        (rat-kingdom-reaction-run space)
        (should-not (rat-kingdom-story-get space "S-1"))
        (should (zerop (hash-table-count rat-kingdom-mcp--grants)))))))

(ert-deftest rat-kingdom-story-test-block-stops-the-story ()
  (rat-kingdom-story-test-with-repo (space path)
    (rat-kingdom-story-start space "demo" "Add a file" nil "S-1")
    (rat-kingdom-reaction-run space)
    (let ((answer (rat-kingdom-story-test--call
                   "S-1.1" "block"
                   '(summary . "Need to know the file's name."))))
      (should-not (cdr answer)))
    (should (equal (plist-get (rat-kingdom-run-get space "S-1.1") :state)
                   "blocked"))
    (rat-kingdom-reaction-run space)
    (let ((story (plist-get (rat-kingdom-story-get space "S-1") :payload)))
      (should (equal (plist-get story :at) "blocked"))
      (should (equal (plist-get story :phase) "parked"))
      (should (string-search "Need to know the file's name."
                             (plist-get story :reason)))
      (should (file-directory-p (plist-get story :worktree))))
    (should (equal (car rat-kingdom-story-test--events) '(parked . "S-1")))
    (should (equal (rat-kingdom-git-rev path "rk/integration")
                   (rat-kingdom-git-rev path "main")))
    (should (cdr (rat-kingdom-story-test--call "S-1.1" "block"
                                               '(summary . "Again"))))
    ;; Moved back with an answer, it gets a new worker who is told it.
    (should-error (rat-kingdom-story-move space "S-1" "nowhere"))
    (should-error (rat-kingdom-story-move space "S-9" "ready"))
    (rat-kingdom-story-move space "S-1" 'ready "Call it feature.txt.")
    (rat-kingdom-reaction-run space)
    (should (equal (rat-kingdom-story-test--get space "S-1" :run) "S-1.2"))
    (should (eql (rat-kingdom-story-test--get space "S-1" :attempt) 1))
    (should (string-search "Call it feature.txt."
                           (rat-kingdom-story-test--prompt "S-1.2")))
    (should (string-search "worked on before"
                           (rat-kingdom-story-test--prompt "S-1.2")))))

(ert-deftest rat-kingdom-story-test-tools-are-offered-by-role ()
  (rat-kingdom-story-test-with-repo (_space _path)
    (cl-flet ((names (role)
                (mapcar (lambda (tool) (plist-get tool :name))
                        (plist-get
                         (plist-get
                          (rat-kingdom-mcp--rpc
                           (list :run "x" :role role)
                           '((jsonrpc . "2.0") (id . 7) (method . "tools/list")))
                          :result)
                         :tools))))
      (should (equal (names 'rat) '("finish" "block")))
      (should (member "story_start" (names 'king)))
      (should-not (member "finish" (names 'king)))
      (should-not (names 'nobody)))
    ;; A tool outside the caller's role does not exist for it.
    (should (equal (rat-kingdom-mcp-call '(:run "x" :role king) "finish" nil)
                   '("Error: unknown tool finish" . t)))
    (should (equal (rat-kingdom-mcp-call '(:run "x" :role rat) "status" nil)
                   '("Error: unknown tool status" . t)))
    ;; A notification gets no reply; an unknown method gets an error.
    (should-not (rat-kingdom-mcp--rpc
                 '(:run "x" :role rat)
                 '((jsonrpc . "2.0") (method . "notifications/initialized"))))
    (should (plist-get (rat-kingdom-mcp--rpc
                        '(:run "x" :role rat)
                        '((jsonrpc . "2.0") (id . 1) (method . "nonsense")))
                       :error))))

(ert-deftest rat-kingdom-story-test-endpoint-answers-over-http ()
  (rat-kingdom-story-test-with-repo (_space _path)
    (unwind-protect
        (let* ((token (rat-kingdom-mcp-grant "S-9.1" 'rat))
               (url (rat-kingdom-mcp-url token)))
          (cl-flet ((post (url body)
                      (let ((url-request-method "POST")
                            (url-request-extra-headers
                             '(("Content-Type" . "application/json")))
                            (url-request-data body)
                            (url-show-status nil))
                        (with-current-buffer (url-retrieve-synchronously url t t 5)
                          (goto-char (point-min))
                          (let ((status (buffer-substring (point-min)
                                                          (line-end-position))))
                            (re-search-forward "\r?\n\r?\n" nil t)
                            (prog1 (cons status
                                         (buffer-substring (point) (point-max)))
                              (kill-buffer)))))))
            (let ((answer (post url "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}")))
              (should (string-search "200" (car answer)))
              (should (equal (mapcar (lambda (tool) (alist-get 'name tool))
                                     (alist-get
                                      'tools
                                      (alist-get
                                       'result
                                       (json-parse-string
                                        (cdr answer) :object-type 'alist
                                        :array-type 'list))))
                             '("finish" "block"))))
            (should (string-search
                     "404" (car (post (concat url "x") "{\"id\":1}"))))
            (should (string-search "400" (car (post url "not json"))))
            ;; A revoked token stops working.
            (rat-kingdom-mcp-revoke "S-9.1")
            (should (string-search
                     "404"
                     (car (post url "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"}"))))))
      (rat-kingdom-mcp-stop))))

;;;; Runs

(ert-deftest rat-kingdom-story-test-failed-start-stops-the-story ()
  (rat-kingdom-story-test-with-repo (space path)
    ;; The branch the story would use already exists.
    (rat-kingdom-story-test--git path "branch" "rats/S-1" "main")
    (rat-kingdom-story-start space "demo" "Add a file" nil "S-1")
    (rat-kingdom-reaction-run space)
    (should (equal (rat-kingdom-story-test--place space "S-1") "blocked"))
    (should (string-search "Step implement could not be begun"
                           (rat-kingdom-story-test--get space "S-1" :reason)))
    (should-not (rat-kingdom-run-list space))
    (should-not rat-kingdom-story-test--started)
    (should-not (rat-kingdom-reaction-failures space))
    (should-not (file-exists-p
                 (expand-file-name "worktrees/demo/S-1" rat-kingdom-directory)))
    ;; With the branch out of the way, moving it back starts the worker.
    (rat-kingdom-story-test--git path "branch" "-D" "rats/S-1")
    (rat-kingdom-story-move space "S-1" "ready")
    (rat-kingdom-reaction-run space)
    (should (equal (rat-kingdom-story-test--get space "S-1" :awaiting) "worker"))
    (should (eql (length rat-kingdom-story-test--started) 1))))

(ert-deftest rat-kingdom-story-test-agent-that-cannot-start-stops-the-story ()
  (rat-kingdom-story-test-with-repo (space _path)
    (let ((rat-kingdom-run-backend
           (list :start (lambda (_run _prompt) (error "No agent here"))
                 :stop #'ignore)))
      (rat-kingdom-story-start space "demo" "Add a file" nil "S-1")
      (rat-kingdom-reaction-run space)
      (should (equal (plist-get (rat-kingdom-run-get space "S-1.1") :state)
                     "exited"))
      (should (equal (rat-kingdom-story-test--place space "S-1") "blocked"))
      (should (string-search "No agent here"
                             (rat-kingdom-story-test--get space "S-1" :reason)))
      (should-not (rat-kingdom-reaction-failures space)))))

(ert-deftest rat-kingdom-story-test-run-that-exits-stops-the-story ()
  (rat-kingdom-story-test-with-repo (space _path)
    (rat-kingdom-story-start space "demo" "Add a file" nil "S-1")
    (rat-kingdom-reaction-run space)
    (rat-kingdom-run-exited "S-1.1")
    (should (equal (plist-get (rat-kingdom-run-get space "S-1.1") :state)
                   "exited"))
    ;; Its token no longer works, and the story is stopped with the reason.
    (should (zerop (hash-table-count rat-kingdom-mcp--grants)))
    (rat-kingdom-reaction-run space)
    (should (equal (rat-kingdom-story-test--place space "S-1") "blocked"))
    (should (string-search "ended before it reported"
                           (rat-kingdom-story-test--get space "S-1" :reason)))
    (should (file-directory-p (rat-kingdom-story-test--get space "S-1" :worktree)))
    ;; A run that had reported keeps what it reported.
    (rat-kingdom-run-update space "S-1.1" :state "ready")
    (rat-kingdom-run-exited "S-1.1")
    (should (equal (plist-get (rat-kingdom-run-get space "S-1.1") :state)
                   "ready"))
    ;; While Emacs is exiting, nothing is recorded.
    (rat-kingdom-run-update space "S-1.1" :state "working")
    (let ((rat-kingdom-run--dying t))
      (rat-kingdom-run-exited "S-1.1"))
    (should (equal (plist-get (rat-kingdom-run-get space "S-1.1") :state)
                   "working"))))

;;;; Cancelling, watching, recovering

(ert-deftest rat-kingdom-story-test-cancel-keeps-the-work ()
  (rat-kingdom-story-test-with-repo (space path)
    (rat-kingdom-story-start space "demo" "Add a file" nil "S-1")
    (rat-kingdom-reaction-run space)
    (let ((worktree (rat-kingdom-story-test--get space "S-1" :worktree)))
      (should (string-search worktree (rat-kingdom-story-cancel space "S-1")))
      (should-not (rat-kingdom-story-get space "S-1"))
      (should-not (rat-kingdom-space-scan space '(_ :owner "S-1")))
      (should (member "S-1.1" rat-kingdom-story-test--stopped))
      (should (file-directory-p worktree))
      (should (rat-kingdom-git-ok-p path "rev-parse" "--verify" "--quiet"
                                    "refs/heads/rats/S-1"))
      (should (equal (plist-get
                      (plist-get (cl-find 'story
                                          (rat-kingdom-space-archived space "S-1")
                                          :key (lambda (tuple)
                                                 (plist-get tuple :category)))
                                 :payload)
                      :phase)
                     "cancelled"))
      (should-error (rat-kingdom-story-cancel space "S-1"))
      (rat-kingdom-reaction-run space)
      (should (eql (length rat-kingdom-story-test--started) 1)))))

(ert-deftest rat-kingdom-story-test-watch-reports-stuck-stories ()
  (rat-kingdom-story-test-with-repo (space _path)
    (setq rat-kingdom-story-test--now 1000.0)
    (rat-kingdom-story-start space "demo" "Add a file" nil "S-1")
    ;; Nothing has picked it up yet.
    (should (zerop (rat-kingdom-story-watch space)))
    (setq rat-kingdom-story-test--now 1100.0)
    (should (eql (rat-kingdom-story-watch space) 1))
    (should (string-search "no step has begun"
                           (plist-get (plist-get (rat-kingdom-space-rd
                                                  space '(stuck :identity "S-1"))
                                                 :payload)
                                      :reason)))
    (should (equal (car rat-kingdom-story-test--events) '(stuck . "S-1")))
    ;; Reported once, and withdrawn when the story moves.
    (should (zerop (rat-kingdom-story-watch space)))
    (rat-kingdom-reaction-run space)
    (should-not (rat-kingdom-space-rd space '(stuck :identity "S-1")))
    ;; A worker that takes too long.
    (setq rat-kingdom-story-test--now (+ 1100.0 7000))
    (should (zerop (rat-kingdom-story-watch space)))
    (setq rat-kingdom-story-test--now (+ 1100.0 7300))
    (should (eql (rat-kingdom-story-watch space) 1))
    (should (string-search "Step implement has taken"
                           (plist-get (plist-get (rat-kingdom-space-rd
                                                  space '(stuck :identity "S-1"))
                                                 :payload)
                                      :reason)))
    ;; A stuck story still finishes if its worker reports.
    (rat-kingdom-story-test--work space "S-1" "feature.txt")
    (rat-kingdom-story-test--settle space "S-1")
    (should-not (rat-kingdom-story-get space "S-1"))
    (should-not (rat-kingdom-space-rd space '(stuck)))))

(ert-deftest rat-kingdom-story-test-recovers-an-interrupted-worker ()
  (rat-kingdom-story-test-with-repo (space path)
    (rat-kingdom-story-start space "demo" "Add a file" nil "S-1")
    (rat-kingdom-reaction-run space)
    (let ((worktree (rat-kingdom-story-test--get space "S-1" :worktree))
          (file (expand-file-name "space.db" rat-kingdom-directory)))
      ;; The worker leaves something uncommitted, and Emacs stops: the
      ;; space is closed, and nothing held in memory survives.
      (with-temp-file (expand-file-name "half" worktree) (insert "half\n"))
      (rat-kingdom-space-close space)
      (setq space (rat-kingdom-space-open file)
            rat-kingdom-space--default space)
      (clrhash rat-kingdom-run--handles)
      (clrhash rat-kingdom-mcp--grants)
      (should (equal (plist-get (rat-kingdom-run-get space "S-1.1") :state)
                     "working"))
      ;; Recovery finds the run, and the story gets a new worker in the
      ;; same worktree, told what happened.
      (should (equal (rat-kingdom-story-reconcile space)
                     '(:runs ("S-1.1") :checks nil :setups nil)))
      (should (equal (plist-get (rat-kingdom-run-get space "S-1.1") :state)
                     "interrupted"))
      (rat-kingdom-reaction-run space)
      (let ((story (plist-get (rat-kingdom-story-get space "S-1") :payload)))
        (should (equal (plist-get story :run) "S-1.2"))
        (should (equal (plist-get story :worktree) worktree))
        (should (eql (plist-get story :attempt) 2)))
      (should (equal (plist-get (rat-kingdom-run-get space "S-1.1") :state)
                     "stopped"))
      (should (file-exists-p (expand-file-name "half" worktree)))
      (should (string-search "was cut off when Emacs stopped"
                             (rat-kingdom-story-test--prompt "S-1.2")))
      (should (string-search "worked on before"
                             (rat-kingdom-story-test--prompt "S-1.2")))
      ;; Nothing more to recover; the new worker finishes the story.
      (should (equal (rat-kingdom-story-reconcile space)
                     '(:runs nil :checks nil :setups nil)))
      (delete-file (expand-file-name "half" worktree))
      (rat-kingdom-story-test--work space "S-1" "feature.txt")
      (rat-kingdom-story-test--settle space "S-1")
      (should-not (rat-kingdom-story-get space "S-1"))
      (should (equal (rat-kingdom-story-test--git
                      path "show" "rk/integration:feature.txt")
                     "work")))))

(ert-deftest rat-kingdom-story-test-recovers-an-interrupted-check ()
  (rat-kingdom-story-test-with-repo (space path)
    (rat-kingdom-repo-add space path :check '("sleep" "30"))
    (rat-kingdom-story-start space "demo" "Add a file" nil "S-1")
    (rat-kingdom-reaction-run space)
    (rat-kingdom-story-test--work space "S-1" "feature.txt")
    (rat-kingdom-reaction-run space)
    (should (equal (rat-kingdom-story-test--get space "S-1" :awaiting) "check"))
    (should (process-live-p (gethash "S-1" rat-kingdom-story--checks)))
    ;; A running check is not disturbed.
    (should (equal (rat-kingdom-story-reconcile space)
                   '(:runs nil :checks nil :setups nil)))
    ;; Emacs stops, taking the check with it.
    (rat-kingdom-story--abandon-check "S-1")
    (should-not (rat-kingdom-space-rd space '(checked :identity "S-1")))
    (should (eql (rat-kingdom-story-watch space) 0))
    (rat-kingdom-repo-add space path :check '("true"))
    (should (equal (rat-kingdom-story-reconcile space)
                   '(:runs nil :checks ("S-1") :setups nil)))
    (rat-kingdom-story-test--settle space "S-1")
    (should-not (rat-kingdom-story-get space "S-1"))
    (should (equal (rat-kingdom-story-test--git
                    path "show" "rk/integration:feature.txt")
                   "work"))
    (should (eql (length rat-kingdom-story-test--started) 1))))

;;;; The worker limit

(defun rat-kingdom-story-test--queued-p (space id)
  "Return non-nil if the story ID in SPACE is queued for a free worker."
  (rat-kingdom-space-rd space (list 'story :identity id :phase "wait"
                                    :awaiting "a free worker")))

(ert-deftest rat-kingdom-story-test-workers-are-capped ()
  (rat-kingdom-story-test-with-repo (space path)
    (let ((rat-kingdom-story-max-workers 1))
      (setq rat-kingdom-story-test--now 1000.0)
      (rat-kingdom-story-start space "demo" "First" nil "S-1")
      (rat-kingdom-story-start space "demo" "Second" nil "S-2")
      (rat-kingdom-reaction-run space)
      ;; One worker; the other story waits, with no worktree and no attempt.
      (should (eql (length rat-kingdom-story-test--started) 1))
      (should (equal (rat-kingdom-story-test--get space "S-1" :awaiting)
                     "worker"))
      (should (rat-kingdom-story-test--queued-p space "S-2"))
      (should (equal (rat-kingdom-story-test--get space "S-2" :step)
                     "implement"))
      (should (eql (rat-kingdom-story-test--get space "S-2" :attempt) 0))
      (should-not (rat-kingdom-story-test--get space "S-2" :run))
      (should-not (rat-kingdom-run-list space "S-2"))
      (should-not (file-exists-p (expand-file-name "worktrees/demo/S-2"
                                                   rat-kingdom-directory)))
      (should (string-search "(waiting for a free worker)"
                             (rat-kingdom-king--story-line
                              space (rat-kingdom-story-get space "S-2"))))
      ;; Queued time is not counted against the step: only the running
      ;; worker is reported stuck.
      (setq rat-kingdom-story-test--now (+ 1000.0 8000))
      (should (eql (rat-kingdom-story-watch space) 1))
      (should (rat-kingdom-space-rd space '(stuck :identity "S-1")))
      (should-not (rat-kingdom-space-rd space '(stuck :identity "S-2")))
      (should (rat-kingdom-story-test--queued-p space "S-2"))
      ;; When the first worker finishes, the second starts by itself, and
      ;; its step's time starts then.
      (setq rat-kingdom-story-test--now (+ 1000.0 9000))
      (rat-kingdom-story-test--work space "S-1" "one.txt")
      (rat-kingdom-reaction-run space)
      (should (eql (length rat-kingdom-story-test--started) 2))
      (should (equal (rat-kingdom-story-test--get space "S-2" :run) "S-2.1"))
      (should (eql (rat-kingdom-story-test--get space "S-2" :attempt) 1))
      (should (equal (rat-kingdom-story-test--get space "S-2" :entered)
                     (+ 1000.0 9000)))
      (should (zerop (rat-kingdom-story-watch space)))
      (rat-kingdom-story-test--settle space "S-1")
      (should-not (rat-kingdom-story-get space "S-1"))
      (rat-kingdom-story-test--work space "S-2" "two.txt")
      (rat-kingdom-story-test--settle space "S-2")
      (should-not (rat-kingdom-story-get space "S-2"))
      (should (equal (rat-kingdom-story-test--git
                      path "show" "rk/integration:two.txt")
                     "work"))
      (should-not (rat-kingdom-reaction-failures space)))))

(ert-deftest rat-kingdom-story-test-queue-is-served-in-order ()
  (rat-kingdom-story-test-with-repo (space _path)
    (let ((rat-kingdom-story-max-workers 1))
      (dolist (id '("S-1" "S-2" "S-3" "S-4"))
        (rat-kingdom-story-start space "demo" "Task" nil id))
      (rat-kingdom-reaction-run space)
      (should (eql (length rat-kingdom-story-test--started) 1))
      ;; Cancelling the running story frees its worker for the oldest.
      (rat-kingdom-story-cancel space "S-1")
      (rat-kingdom-reaction-run space)
      (should (equal (rat-kingdom-story-test--get space "S-2" :run) "S-2.1"))
      (should (rat-kingdom-story-test--queued-p space "S-3"))
      (should (rat-kingdom-story-test--queued-p space "S-4"))
      ;; A queued story moved by hand joins the back of the queue.
      (rat-kingdom-story-move space "S-3" 'ready "Again.")
      (rat-kingdom-reaction-run space)
      (should (rat-kingdom-story-test--queued-p space "S-3"))
      (should (equal (rat-kingdom-story-test--get space "S-3" :reason)
                     "Again."))
      ;; A worker that blocks frees its place; S-4 now waited longest.
      (rat-kingdom-story-test--call "S-2.1" "block" '(summary . "Stuck."))
      (rat-kingdom-reaction-run space)
      (should (equal (rat-kingdom-story-test--get space "S-2" :phase) "parked"))
      (should (equal (rat-kingdom-story-test--get space "S-4" :run) "S-4.1"))
      (should (rat-kingdom-story-test--queued-p space "S-3"))
      ;; A queued story can be cancelled like any other.
      (rat-kingdom-story-cancel space "S-3")
      (should-not (rat-kingdom-story-get space "S-3"))
      ;; Moving a running story to a final place frees its worker too.
      (rat-kingdom-story-start space "demo" "Task" nil "S-5")
      (rat-kingdom-reaction-run space)
      (should (rat-kingdom-story-test--queued-p space "S-5"))
      (rat-kingdom-story-move space "S-4" 'done)
      (rat-kingdom-reaction-run space)
      (should-not (rat-kingdom-story-get space "S-4"))
      (should (equal (rat-kingdom-story-test--get space "S-5" :run) "S-5.1"))
      (should (eql (length rat-kingdom-story-test--started) 4))
      (should-not (rat-kingdom-reaction-failures space)))))

(ert-deftest rat-kingdom-story-test-no-worker-limit ()
  (rat-kingdom-story-test-with-repo (space _path)
    (let ((rat-kingdom-story-max-workers nil))
      (dotimes (n 5)
        (rat-kingdom-story-start space "demo" "Task" nil (format "S-%d" n)))
      (rat-kingdom-reaction-run space)
      (should (eql (length rat-kingdom-story-test--started) 5))
      (should-not (rat-kingdom-space-rd space '(story :awaiting
                                                      "a free worker"))))))

(ert-deftest rat-kingdom-story-test-queue-survives-a-restart ()
  (rat-kingdom-story-test-with-repo (space _path)
    (let ((rat-kingdom-story-max-workers 1)
          (file (expand-file-name "space.db" rat-kingdom-directory)))
      (rat-kingdom-story-start space "demo" "First" nil "S-1")
      (rat-kingdom-story-start space "demo" "Second" nil "S-2")
      (rat-kingdom-reaction-run space)
      (should (rat-kingdom-story-test--queued-p space "S-2"))
      ;; Emacs stops.
      (rat-kingdom-space-close space)
      (setq space (rat-kingdom-space-open file)
            rat-kingdom-space--default space)
      (clrhash rat-kingdom-run--handles)
      (clrhash rat-kingdom-mcp--grants)
      ;; The interrupted worker is replaced first; the queue keeps its place.
      (should (equal (rat-kingdom-story-reconcile space)
                     '(:runs ("S-1.1") :checks nil :setups nil)))
      (rat-kingdom-reaction-run space)
      (should (equal (rat-kingdom-story-test--get space "S-1" :run) "S-1.2"))
      (should (rat-kingdom-story-test--queued-p space "S-2"))
      (should (eql (length rat-kingdom-story-test--started) 2))
      ;; With room for another worker, reconciling starts the queue.
      (let ((rat-kingdom-story-max-workers 2))
        (rat-kingdom-story-reconcile space)
        (rat-kingdom-reaction-run space)
        (should (equal (rat-kingdom-story-test--get space "S-2" :run) "S-2.1"))
        (should (eql (rat-kingdom-story-test--get space "S-2" :attempt) 1)))
      (should-not (rat-kingdom-reaction-failures space)))))

;;;; Setup

(defun rat-kingdom-story-test--set-up (space id)
  "Run reactions in SPACE until the setup of the story ID has come out."
  (rat-kingdom-reaction-run space)
  (let ((tries 0))
    (while (and (rat-kingdom-space-rd space (list 'story :identity id
                                                  :awaiting "setup"))
                (not (rat-kingdom-space-rd space (list 'setup :identity id)))
                (< (cl-incf tries) 200))
      (accept-process-output nil 0.05)))
  (rat-kingdom-reaction-run space))

(defun rat-kingdom-story-test--lines (file)
  "Return the lines of FILE, or nil if it does not exist."
  (and (file-exists-p file)
       (split-string (with-temp-buffer
                       (insert-file-contents file)
                       (buffer-string))
                     "\n" t)))

(ert-deftest rat-kingdom-story-test-setup-runs-before-the-worker ()
  (rat-kingdom-story-test-with-repo (space path)
    (let* ((log (expand-file-name "../setup.log" path))
           (worktree (expand-file-name "worktrees/demo/S-1"
                                       rat-kingdom-directory))
           (marker (expand-file-name "marker" worktree))
           (start (plist-get rat-kingdom-run-backend :start))
           marker-at-start
           (rat-kingdom-run-backend
            (plist-put (copy-sequence rat-kingdom-run-backend) :start
                       (lambda (run prompt)
                         (push (file-exists-p marker) marker-at-start)
                         (funcall start run prompt)))))
      (rat-kingdom-repo-add
       space path :check '("sh" "-c" "test -f wanted.txt")
       :setup (list "sh" "-c" (format "echo ok > marker; pwd >> %s"
                                      (shell-quote-argument log))))
      (rat-kingdom-story-start space "demo" "Add the wanted file" nil "S-1")
      (rat-kingdom-reaction-run space)
      ;; The worktree is made and set up; no worker yet, and no attempt.
      (should (equal (rat-kingdom-story-test--get space "S-1" :awaiting)
                     "setup"))
      (should (eql (rat-kingdom-story-test--get space "S-1" :attempt) 0))
      (should (string-search "(waiting for setup)"
                             (rat-kingdom-king--story-line
                              space (rat-kingdom-story-get space "S-1"))))
      (rat-kingdom-story-test--set-up space "S-1")
      (should (equal marker-at-start '(t)))
      (should (equal (rat-kingdom-story-test--get space "S-1" :awaiting)
                     "worker"))
      (should (equal (rat-kingdom-story-test--get space "S-1" :worktree)
                     worktree))
      (should (eql (rat-kingdom-story-test--get space "S-1" :attempt) 1))
      (should-not (string-search "worked on before"
                                 (rat-kingdom-story-test--prompt "S-1.1")))
      (should (equal (rat-kingdom-story-test--lines log) (list worktree)))
      ;; The check fails; the replacement worker in the same worktree is
      ;; not set up again, though setup runs in the candidate.
      (delete-file marker)
      (rat-kingdom-story-test--work space "S-1" "other.txt")
      (rat-kingdom-story-test--settle space "S-1")
      (should (equal (rat-kingdom-story-test--get space "S-1" :run) "S-1.2"))
      (should (equal marker-at-start '(nil t)))
      (should-not (file-exists-p marker))
      (should (equal (rat-kingdom-story-test--lines log)
                     (list worktree
                           (expand-file-name "candidates/demo/S-1"
                                             rat-kingdom-directory))))
      (should (string-search "check failed"
                             (rat-kingdom-story-test--prompt "S-1.2")))
      (should-not (rat-kingdom-reaction-failures space)))))

(ert-deftest rat-kingdom-story-test-failed-setup-stops-the-story ()
  (rat-kingdom-story-test-with-repo (space path)
    (rat-kingdom-repo-add space path
                          :setup '("sh" "-c" "echo no network; exit 3"))
    (rat-kingdom-story-start space "demo" "Add a file" nil "S-1")
    (rat-kingdom-story-test--set-up space "S-1")
    ;; Parked with the command, its exit and its output; no worker was
    ;; started and no attempt used.
    (let ((reason (rat-kingdom-story-test--get space "S-1" :reason)))
      (should (equal (rat-kingdom-story-test--place space "S-1") "blocked"))
      (should (equal (rat-kingdom-story-test--get space "S-1" :phase) "parked"))
      (should (string-search "setup failed" reason))
      (should (string-search "sh -c \"echo no network; exit 3\"" reason))
      (should (string-search "exited with 3" reason))
      (should (string-search "no network" reason)))
    (should (eql (rat-kingdom-story-test--get space "S-1" :attempt) 0))
    (should-not rat-kingdom-story-test--started)
    (should (equal (car rat-kingdom-story-test--events) '(parked . "S-1")))
    ;; Once setup is put right, moving the story back runs it again in
    ;; the worktree it failed in, and the worker starts.
    (rat-kingdom-repo-add space path :setup '("sh" "-c" "echo ok > marker"))
    (rat-kingdom-story-move space "S-1" 'ready)
    (rat-kingdom-story-test--set-up space "S-1")
    (should (equal (rat-kingdom-story-test--get space "S-1" :run) "S-1.1"))
    (should (file-exists-p (expand-file-name
                            "marker"
                            (rat-kingdom-story-test--get space "S-1" :worktree))))
    (should-not (rat-kingdom-reaction-failures space))))

(ert-deftest rat-kingdom-story-test-setup-runs-before-the-check ()
  (rat-kingdom-story-test-with-repo (space path)
    (let ((log (shell-quote-argument (expand-file-name "../setup.log" path))))
      (rat-kingdom-repo-add
       space path
       :setup (list "sh" "-c" (format "echo setup >> %s" log))
       :check (list "sh" "-c" (format "echo check >> %s" log)))
      (rat-kingdom-story-start space "demo" "Add a file" nil "S-1")
      (rat-kingdom-story-test--set-up space "S-1")
      (rat-kingdom-story-test--work space "S-1" "one.txt")
      (rat-kingdom-story-test--settle space "S-1")
      (should-not (rat-kingdom-story-get space "S-1"))
      (should (equal (rat-kingdom-story-test--lines
                      (expand-file-name "../setup.log" path))
                     '("setup" "setup" "check")))
      ;; A setup that fails in the candidate fails the check, which then
      ;; never runs, and the worker is told it was the setup.
      (rat-kingdom-repo-add
       space path
       :setup '("sh" "-c" "case $(pwd) in */candidates/*) echo no disk; \
exit 4;; esac")
       :check (list "sh" "-c" (format "echo check >> %s" log)))
      (rat-kingdom-story-start space "demo" "Add another file" nil "S-2")
      (rat-kingdom-story-test--set-up space "S-2")
      (rat-kingdom-story-test--work space "S-2" "two.txt")
      (rat-kingdom-story-test--settle space "S-2")
      (let ((checked (plist-get (rat-kingdom-space-rd
                                 space '(checked :identity "S-2"))
                                :payload))
            (prompt (rat-kingdom-story-test--prompt "S-2.2")))
        (should (equal (plist-get checked :value) "fail"))
        (should (equal (plist-get checked :reason) "setup failed"))
        (should (string-search "did not run because the repository's setup \
failed" prompt))
        (should (string-search "exited with 4" prompt))
        (should (string-search "no disk" prompt)))
      (should (equal (rat-kingdom-story-test--get space "S-2" :at) "ready"))
      (should (equal (rat-kingdom-story-test--lines
                      (expand-file-name "../setup.log" path))
                     '("setup" "setup" "check")))
      (should-not (rat-kingdom-reaction-failures space)))))

(ert-deftest rat-kingdom-story-test-setup-is-watched-and-recovered ()
  (rat-kingdom-story-test-with-repo (space path)
    (setq rat-kingdom-story-test--now 1000.0)
    (rat-kingdom-repo-add space path :setup '("sleep" "30"))
    (rat-kingdom-story-start space "demo" "Add a file" nil "S-1")
    (rat-kingdom-reaction-run space)
    (should (process-live-p (gethash "S-1" rat-kingdom-story--checks)))
    ;; A running setup is left alone, until it runs past a check's time.
    (should (equal (rat-kingdom-story-reconcile space)
                   '(:runs nil :checks nil :setups nil)))
    (setq rat-kingdom-story-test--now (+ 1000.0 1700))
    (should (zerop (rat-kingdom-story-watch space)))
    (setq rat-kingdom-story-test--now (+ 1000.0 1900))
    (should (eql (rat-kingdom-story-watch space) 1))
    (should (string-search "Its setup has taken 31 minutes"
                           (plist-get (plist-get (rat-kingdom-space-rd
                                                  space '(stuck :identity "S-1"))
                                                 :payload)
                                      :reason)))
    ;; Moving the story kills its setup, which runs again from the start.
    (let ((process (gethash "S-1" rat-kingdom-story--checks)))
      (rat-kingdom-story-move space "S-1" 'ready)
      (should-not (process-live-p process)))
    (rat-kingdom-reaction-run space)
    (should (equal (rat-kingdom-story-test--get space "S-1" :awaiting) "setup"))
    ;; Emacs stops, taking the setup with it: the watchdog sees it.
    (rat-kingdom-story--abandon-check "S-1")
    (setq rat-kingdom-story-test--now (+ 1000.0 2000))
    (should (eql (rat-kingdom-story-watch space) 1))
    (should (equal (plist-get (plist-get (rat-kingdom-space-rd
                                          space '(stuck :identity "S-1"))
                                         :payload)
                              :reason)
                   "Its setup is not running."))
    ;; Recovery runs it again.
    (rat-kingdom-repo-add space path :setup '("sh" "-c" "echo ok > marker"))
    (should (equal (rat-kingdom-story-reconcile space)
                   '(:runs nil :checks nil :setups ("S-1"))))
    (rat-kingdom-story-test--set-up space "S-1")
    (should (equal (rat-kingdom-story-test--get space "S-1" :run) "S-1.1"))
    (should (file-exists-p (expand-file-name
                            "marker"
                            (rat-kingdom-story-test--get space "S-1" :worktree))))
    ;; Cancelling a story kills its setup too.
    (rat-kingdom-repo-add space path :setup '("sleep" "30"))
    (rat-kingdom-story-start space "demo" "Another" nil "S-2")
    (rat-kingdom-reaction-run space)
    (let ((process (gethash "S-2" rat-kingdom-story--checks)))
      (should (process-live-p process))
      (rat-kingdom-story-cancel space "S-2")
      (should-not (process-live-p process)))
    (should-not (rat-kingdom-reaction-failures space))))

(ert-deftest rat-kingdom-story-test-setup-holds-a-worker-place ()
  (rat-kingdom-story-test-with-repo (space path)
    (let ((rat-kingdom-story-max-workers 1)
          (go (expand-file-name "../go" path)))
      (rat-kingdom-repo-add
       space path
       :setup (list "sh" "-c" (format "while [ ! -f %s ]; do sleep 0.05; done"
                                      (shell-quote-argument go))))
      (rat-kingdom-story-start space "demo" "First" nil "S-1")
      (rat-kingdom-story-start space "demo" "Second" nil "S-2")
      (rat-kingdom-reaction-run space)
      ;; The first is being set up and holds the one place.
      (should (equal (rat-kingdom-story-test--get space "S-1" :awaiting)
                     "setup"))
      (should (rat-kingdom-story-test--queued-p space "S-2"))
      (should-not (rat-kingdom-story-dequeue space))
      (with-temp-file go)
      (rat-kingdom-story-test--set-up space "S-1")
      (should (equal (rat-kingdom-story-test--get space "S-1" :run) "S-1.1"))
      (should (rat-kingdom-story-test--queued-p space "S-2"))
      (should (eql (length rat-kingdom-story-test--started) 1))
      ;; When it finishes, the second is set up and then started.
      (rat-kingdom-story-test--work space "S-1" "one.txt")
      (rat-kingdom-reaction-run space)
      (should (equal (rat-kingdom-story-test--get space "S-2" :awaiting)
                     "setup"))
      (rat-kingdom-story-test--set-up space "S-2")
      (should (equal (rat-kingdom-story-test--get space "S-2" :run) "S-2.1"))
      (should (eql (length rat-kingdom-story-test--started) 2))
      (should-not (rat-kingdom-reaction-failures space)))))

(provide 'rat-kingdom-story-test)
;;; rat-kingdom-story-test.el ends here
