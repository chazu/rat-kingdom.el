;;; rat-kingdom-story-test.el --- Tests for runs and stories -*- lexical-binding: t; -*-

;;; Commentary:

;; Batch tests that take a story from start to merge in a disposable
;; repository, with real Git and a backend that starts no agent.  The
;; tests play the agent: they commit in its worktree and call its tools.

;;; Code:

(require 'ert)
(require 'url)
(require 'rat-kingdom-story)

(defvar rat-kingdom-story-test--started nil
  "The runs the fake backend started, newest first, as (RUN PROMPT TOKEN).")

(defvar rat-kingdom-story-test--stopped nil
  "The handles the fake backend stopped.")

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
repository is registered as \"demo\" with no check."
  (declare (indent 1) (debug t))
  (let ((root (make-symbol "root")))
    `(let* ((,root (file-name-as-directory
                    (file-truename (make-temp-file "rat-kingdom-story" t))))
            (rat-kingdom-directory (expand-file-name "state/" ,root))
            (rat-kingdom-space-change-functions nil)
            (rat-kingdom-reaction--attachments nil)
            (rat-kingdom-run--handles (make-hash-table :test #'equal))
            (rat-kingdom-mcp--grants (make-hash-table :test #'equal))
            (rat-kingdom-story-test--started nil)
            (rat-kingdom-story-test--stopped nil)
            (rat-kingdom-run-backend
             (list :start (lambda (run prompt)
                            (let ((token (rat-kingdom-mcp-grant
                                          (plist-get run :id) 'rat)))
                              (push (list run prompt token)
                                    rat-kingdom-story-test--started)
                              (plist-get run :id)))
                   :stop (lambda (handle)
                           (push handle rat-kingdom-story-test--stopped))))
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
    (while (and (equal (rat-kingdom-story-test--place space id) "checking")
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
      (should-not (plist-get repo :check)))
    (should (equal (rat-kingdom-git-rev path "rk/integration")
                   (rat-kingdom-git-rev path "main")))
    ;; Registering again replaces the record and keeps the branch.
    (rat-kingdom-story-test--commit path "more" "more\n" "More")
    (rat-kingdom-repo-add space path :check '("make" "check"))
    (should (equal (plist-get (rat-kingdom-repo-get space "demo") :check)
                   '("make" "check")))
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
    (should-error (rat-kingdom-story-start space "nowhere" "Task"))))

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
        (should (equal (plist-get story :at) "implementing"))
        (should (equal (plist-get story :run) "S-1.1"))
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
        (should-not (directory-files
                     (expand-file-name "candidates/demo" rat-kingdom-directory)
                     nil "S-1"))
        (should (equal rat-kingdom-story-test--stopped '("S-1.1")))
        ;; The archive has the story at done and its result.
        (let ((archived (rat-kingdom-space-archived space "S-1")))
          (should (equal (plist-get
                          (plist-get (cl-find 'story archived
                                              :key (lambda (tuple)
                                                     (plist-get tuple :category)))
                                     :payload)
                          :at)
                         "done"))
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

(ert-deftest rat-kingdom-story-test-check-must-pass ()
  (rat-kingdom-story-test-with-repo (space path)
    (rat-kingdom-repo-add space path
                          :check '("sh" "-c" "echo checking; test -f wanted.txt"))
    (let ((before (rat-kingdom-git-rev path "rk/integration")))
      ;; A story whose merge fails the check stops, with everything kept.
      (rat-kingdom-story-start space "demo" "Wrong file" nil "S-1")
      (rat-kingdom-reaction-run space)
      (rat-kingdom-story-test--work space "S-1" "other.txt")
      (rat-kingdom-story-test--settle space "S-1")
      (let ((story (plist-get (rat-kingdom-story-get space "S-1") :payload))
            (checked (plist-get (rat-kingdom-space-rd
                                 space '(checked :identity "S-1"))
                                :payload)))
        (should (equal (plist-get story :at) "blocked"))
        (should (equal (plist-get story :reason) "check failed"))
        (should (equal (plist-get checked :value) "fail"))
        (should (eql (plist-get checked :exit) 1))
        (should (equal (plist-get checked :output) "checking\n"))
        (should (equal (plist-get checked :check)
                       '("sh" "-c" "echo checking; test -f wanted.txt")))
        (should (file-directory-p (plist-get story :worktree)))
        (should (file-exists-p (expand-file-name "other.txt"
                                                 (plist-get story :candidate))))
        (should (equal (rat-kingdom-git-rev path "rk/integration") before))
        (should-not rat-kingdom-story-test--stopped))
      ;; One that passes is merged.
      (rat-kingdom-story-start space "demo" "Right file" nil "S-2")
      (rat-kingdom-reaction-run space)
      (rat-kingdom-story-test--work space "S-2" "wanted.txt")
      (rat-kingdom-story-test--settle space "S-2")
      (should-not (rat-kingdom-story-get space "S-2"))
      (should (equal (rat-kingdom-story-test--git
                      path "show" "rk/integration:wanted.txt")
                     "work"))
      (should (equal (plist-get
                      (plist-get (cl-find 'checked
                                          (rat-kingdom-space-archived space "S-2")
                                          :key (lambda (tuple)
                                                 (plist-get tuple :category)))
                                 :payload)
                      :value)
                     "pass")))))

(ert-deftest rat-kingdom-story-test-merge-conflict-blocks ()
  (rat-kingdom-story-test-with-repo (space path)
    (rat-kingdom-story-start space "demo" "Edit the readme" nil "S-1")
    (rat-kingdom-reaction-run space)
    ;; The target gains a different version of the same file meanwhile.
    (rat-kingdom-story-test--commit path "README" "theirs\n" "Theirs")
    (rat-kingdom-story-test--git path "branch" "-f" "rk/integration" "main")
    (let ((target (rat-kingdom-git-rev path "rk/integration")))
      (rat-kingdom-story-test--work space "S-1" "README")
      (rat-kingdom-story-test--settle space "S-1")
      (let ((story (plist-get (rat-kingdom-story-get space "S-1") :payload)))
        (should (equal (plist-get story :at) "blocked"))
        (should (equal (plist-get story :reason) "merge conflict"))
        (should (file-directory-p (plist-get story :candidate)))
        (should (file-directory-p (plist-get story :worktree))))
      (should (equal (rat-kingdom-git-rev path "rk/integration") target)))))

(ert-deftest rat-kingdom-story-test-target-that-moved-is-not-overwritten ()
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
      (rat-kingdom-reaction-run space)
      (should (equal (rat-kingdom-git-rev path "rk/integration") moved))
      (should (equal (rat-kingdom-story-test--place space "S-1") "checking"))
      (let ((failures (rat-kingdom-reaction-failures space)))
        (should (eql (length failures) 1))
        (should (eq (plist-get (car failures) :reaction)
                    'rat-kingdom-story-integrate)))
      (should (file-directory-p
               (plist-get (plist-get (rat-kingdom-story-get space "S-1")
                                     :payload)
                          :worktree))))))

(ert-deftest rat-kingdom-story-test-checked-out-target-is-refused ()
  (rat-kingdom-story-test-with-repo (space path)
    (rat-kingdom-story-start space "demo" "Add a file" nil "S-1")
    (rat-kingdom-reaction-run space)
    (rat-kingdom-story-test--git path "checkout" "-q" "rk/integration")
    (let ((before (rat-kingdom-git-rev path "rk/integration")))
      (rat-kingdom-story-test--work space "S-1" "feature.txt")
      (rat-kingdom-story-test--settle space "S-1")
      (should (equal (rat-kingdom-git-rev path "rk/integration") before))
      (should (equal (rat-kingdom-story-test--place space "S-1") "checking"))
      (should (string-search
               "checked out"
               (plist-get (car (rat-kingdom-reaction-failures space)) :error)))
      ;; Once it is free, a retry lands the merge.
      (rat-kingdom-story-test--git path "checkout" "-q" "main")
      (rat-kingdom-reaction-retry space)
      (should-not (rat-kingdom-story-get space "S-1"))
      (should (equal (rat-kingdom-story-test--git
                      path "show" "rk/integration:feature.txt")
                     "work")))))

;;;; The worker's tools

(ert-deftest rat-kingdom-story-test-finish-refuses-unfinished-work ()
  (rat-kingdom-story-test-with-repo (space _path)
    (rat-kingdom-story-start space "demo" "Add a file" nil "S-1")
    (rat-kingdom-reaction-run space)
    (let ((worktree (plist-get (plist-get (rat-kingdom-story-get space "S-1")
                                          :payload)
                               :worktree)))
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
        ;; Done properly, it is recorded; done twice, it is refused.
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
      (should (equal (plist-get story :reason) "Need to know the file's name."))
      (should (file-directory-p (plist-get story :worktree))))
    (should (equal (rat-kingdom-git-rev path "rk/integration")
                   (rat-kingdom-git-rev path "main")))
    (should (cdr (rat-kingdom-story-test--call "S-1.1" "block"
                                               '(summary . "Again"))))))

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
      (should-not (names 'king)))
    ;; A tool outside the caller's role does not exist for it.
    (should (equal (rat-kingdom-mcp-call '(:run "x" :role king) "finish" nil)
                   '("Error: unknown tool finish" . t)))
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

(ert-deftest rat-kingdom-story-test-failed-start-leaves-no-worktree ()
  (rat-kingdom-story-test-with-repo (space path)
    ;; The branch the story would use already exists.
    (rat-kingdom-story-test--git path "branch" "rats/S-1" "main")
    (rat-kingdom-story-start space "demo" "Add a file" nil "S-1")
    (rat-kingdom-reaction-run space)
    (should (equal (rat-kingdom-story-test--place space "S-1") "ready"))
    (should-not (rat-kingdom-run-list space))
    (should-not rat-kingdom-story-test--started)
    (should (eq (plist-get (car (rat-kingdom-reaction-failures space)) :reaction)
                'rat-kingdom-story-implement))
    (should-not (file-exists-p
                 (expand-file-name "worktrees/demo/S-1" rat-kingdom-directory)))
    ;; With the branch out of the way, a retry starts the worker.
    (rat-kingdom-story-test--git path "branch" "-D" "rats/S-1")
    (rat-kingdom-reaction-retry space)
    (should (equal (rat-kingdom-story-test--place space "S-1") "implementing"))
    (should (eql (length rat-kingdom-story-test--started) 1))))

(ert-deftest rat-kingdom-story-test-run-that-exits-is-marked ()
  (rat-kingdom-story-test-with-repo (space _path)
    (rat-kingdom-story-start space "demo" "Add a file" nil "S-1")
    (rat-kingdom-reaction-run space)
    (rat-kingdom-run-exited "S-1.1")
    (should (equal (plist-get (rat-kingdom-run-get space "S-1.1") :state)
                   "exited"))
    ;; Its token no longer works, and the story waits where it was.
    (should (zerop (hash-table-count rat-kingdom-mcp--grants)))
    (should (equal (rat-kingdom-story-test--place space "S-1") "implementing"))
    ;; A run that had reported keeps what it reported.
    (rat-kingdom-run-update space "S-1.1" :state "ready")
    (rat-kingdom-run-exited "S-1.1")
    (should (equal (plist-get (rat-kingdom-run-get space "S-1.1") :state)
                   "ready"))))

(provide 'rat-kingdom-story-test)
;;; rat-kingdom-story-test.el ends here
