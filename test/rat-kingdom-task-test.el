;;; rat-kingdom-task-test.el --- Tests for the task adapter -*- lexical-binding: t; -*-

;;; Commentary:

;; Batch tests for the Rust Beads adapter.  A fake br, a shell script,
;; records the directory it ran in and its arguments, prints canned JSON
;; shaped like the real br's and exits as told.  One test uses the real
;; br, if it is installed, in a disposable workspace.
;;
;; The projection of ready tasks into the space and the stories that
;; work on them are tested with an in-memory adapter and no subprocess
;; but Git, in the disposable repositories of rat-kingdom-story-test.el.

;;; Code:

(require 'ert)
(require 'rat-kingdom-task)
(require 'rat-kingdom-story-test)

(defvar rat-kingdom-task-test--fake nil
  "The directory of the fake br in use.")

(defmacro rat-kingdom-task-test-with-fake (var &rest body)
  "Run BODY with a fake br and VAR bound to an adapter for it.
The adapter's workspace is a fresh directory.  Use
`rat-kingdom-task-test--answer' to say what the fake prints and
`rat-kingdom-task-test--args' to see what it was given."
  (declare (indent 1) (debug t))
  (let ((root (make-symbol "root")))
    `(let* ((,root (file-name-as-directory
                    (file-truename (make-temp-file "rat-kingdom-task" t))))
            (rat-kingdom-task-test--fake ,root)
            (rat-kingdom-task-br-program (expand-file-name "br" ,root))
            (,var (rat-kingdom-task-br
                   (list :name "demo" :path (expand-file-name "repo/" ,root)))))
       (make-directory (rat-kingdom-task-br-directory ,var))
       (with-temp-file rat-kingdom-task-br-program
         (insert "#!/bin/sh\n"
                 "dir=" (shell-quote-argument ,root) "\n"
                 "pwd > \"$dir/cwd\"\n"
                 "for a in \"$@\"; do printf '%s\\n' \"$a\"; done > \"$dir/args\"\n"
                 "cat \"$dir/stdout\"\n"
                 "cat \"$dir/stderr\" >&2\n"
                 "exit $(cat \"$dir/exit\")\n"))
       (set-file-modes rat-kingdom-task-br-program #o755)
       (rat-kingdom-task-test--answer "")
       (unwind-protect
           (progn ,@body)
         (delete-directory ,root t)))))

(defun rat-kingdom-task-test--answer (stdout &optional exit stderr)
  "Make the fake br print STDOUT and STDERR and exit with EXIT."
  (dolist (file `(("stdout" . ,stdout)
                  ("stderr" . ,(or stderr ""))
                  ("exit" . ,(format "%d" (or exit 0)))))
    (with-temp-file (expand-file-name (car file) rat-kingdom-task-test--fake)
      (insert (cdr file)))))

(defun rat-kingdom-task-test--args ()
  "Return the arguments the fake br was last given."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "args" rat-kingdom-task-test--fake))
    (split-string (buffer-string) "\n" t)))

(defun rat-kingdom-task-test--cwd ()
  "Return the directory the fake br last ran in."
  (with-temp-buffer
    (insert-file-contents (expand-file-name "cwd" rat-kingdom-task-test--fake))
    (file-name-as-directory (file-truename (string-trim (buffer-string))))))

(ert-deftest rat-kingdom-task-test-adapter-defaults-to-repo-path ()
  (should (equal (rat-kingdom-task-br-directory
                  (rat-kingdom-task-br '(:name "demo" :path "/src/demo")))
                 "/src/demo"))
  (should (equal (rat-kingdom-task-br-directory
                  (rat-kingdom-task-br '(:name "demo" :path "/src/demo")
                                       "/src/beads"))
                 "/src/beads")))

(ert-deftest rat-kingdom-task-test-ready ()
  (rat-kingdom-task-test-with-fake adapter
    (rat-kingdom-task-test--answer
     (concat "[{\"created_at\":\"2026-11-13T13:09:26Z\",\"created_by\":\"chazu\","
             "\"description\":\"Do it\",\"id\":\"bd-duw\",\"issue_type\":\"task\","
             "\"labels\":[\"ui\"],\"priority\":1,\"status\":\"open\","
             "\"title\":\"First task\",\"updated_at\":\"2026-11-13T13:09:26Z\"},"
             "{\"created_at\":\"2026-11-13T13:09:26Z\",\"created_by\":\"chazu\","
             "\"id\":\"bd-s9g\",\"issue_type\":\"bug\",\"labels\":[],"
             "\"priority\":2,\"status\":\"open\",\"title\":\"Second\","
             "\"assignee\":null,\"updated_at\":\"2026-11-13T13:09:26Z\"}]"))
    (let ((tasks (rat-kingdom-task-ready adapter)))
      (should (equal (rat-kingdom-task-test--args) '("ready" "--json")))
      (should (equal (rat-kingdom-task-test--cwd)
                     (file-truename (rat-kingdom-task-br-directory adapter))))
      (should (= (length tasks) 2))
      (should (equal (car tasks)
                     '(:id "bd-duw" :title "First task" :description "Do it"
                       :status "open" :priority 1 :type "task" :assignee nil
                       :labels ("ui"))))
      (should (equal (plist-get (cadr tasks) :id) "bd-s9g"))
      (should (null (plist-get (cadr tasks) :description)))
      (should (null (plist-get (cadr tasks) :assignee)))
      (should (equal (plist-get (cadr tasks) :type) "bug")))))

(ert-deftest rat-kingdom-task-test-ready-empty ()
  (rat-kingdom-task-test-with-fake adapter
    (rat-kingdom-task-test--answer "[]")
    (should (null (rat-kingdom-task-ready adapter)))))

(ert-deftest rat-kingdom-task-test-show ()
  (rat-kingdom-task-test-with-fake adapter
    (rat-kingdom-task-test--answer
     (concat "[{\"id\":\"bd-s9g\",\"title\":\"Second\",\"description\":\"More\","
             "\"status\":\"in_progress\",\"priority\":2,\"issue_type\":\"task\","
             "\"assignee\":\"run-1\",\"created_at\":\"2026-11-13T13:09:26Z\","
             "\"source_repo\":\"demo\",\"compaction_level\":0}]"))
    (let ((task (rat-kingdom-task-show adapter "bd-s9g")))
      (should (equal (rat-kingdom-task-test--args) '("show" "bd-s9g" "--json")))
      (should (equal (plist-get task :id) "bd-s9g"))
      (should (equal (plist-get task :title) "Second"))
      (should (equal (plist-get task :description) "More"))
      (should (equal (plist-get task :status) "in_progress"))
      (should (equal (plist-get task :priority) 2))
      (should (equal (plist-get task :assignee) "run-1")))
    (rat-kingdom-task-test--answer "[]")
    (should-error (rat-kingdom-task-show adapter "bd-none")
                  :type 'rat-kingdom-task-error)))

(ert-deftest rat-kingdom-task-test-create ()
  (rat-kingdom-task-test-with-fake adapter
    (rat-kingdom-task-test--answer
     (concat "{\"id\":\"bd-new\",\"title\":\"A task\",\"description\":\"-x\","
             "\"status\":\"open\",\"priority\":1,\"issue_type\":\"bug\"}"))
    (should (equal (rat-kingdom-task-create adapter "A task" :description "-x"
                                            :priority 1 :type "bug"
                                            :parent "bd-epic")
                   "bd-new"))
    (should (equal (rat-kingdom-task-test--args)
                   '("create" "--title=A task" "--description=-x"
                     "--priority" "1" "--type" "bug" "--parent" "bd-epic"
                     "--json")))
    (rat-kingdom-task-create adapter "Bare")
    (should (equal (rat-kingdom-task-test--args)
                   '("create" "--title=Bare" "--json")))))

(ert-deftest rat-kingdom-task-test-close-claim-release-comment ()
  (rat-kingdom-task-test-with-fake adapter
    (rat-kingdom-task-test--answer
     "[{\"id\":\"bd-s9g\",\"title\":\"Second\",\"status\":\"closed\"}]")
    (rat-kingdom-task-close adapter "bd-s9g" "Merged")
    (should (equal (rat-kingdom-task-test--args)
                   '("close" "bd-s9g" "--reason=Merged" "--json")))
    (rat-kingdom-task-test--answer
     "[{\"id\":\"bd-s9g\",\"status\":\"in_progress\",\"assignee\":\"run-7\"}]")
    (rat-kingdom-task-claim adapter "bd-s9g" "run-7")
    (should (equal (rat-kingdom-task-test--args)
                   '("update" "bd-s9g" "--claim" "--actor=run-7" "--json")))
    (rat-kingdom-task-test--answer
     "[{\"id\":\"bd-s9g\",\"status\":\"open\",\"assignee\":null}]")
    (rat-kingdom-task-release adapter "bd-s9g")
    (should (equal (rat-kingdom-task-test--args)
                   '("update" "bd-s9g" "--status" "open" "--assignee=" "--json")))
    (rat-kingdom-task-test--answer
     "{\"id\":1,\"issue_id\":\"bd-s9g\",\"author\":\"chazu\",\"text\":\"hi\"}")
    (rat-kingdom-task-comment adapter "bd-s9g" "-- looks done")
    (should (equal (rat-kingdom-task-test--args)
                   '("comments" "add" "bd-s9g" "--message=-- looks done"
                     "--json")))))

(ert-deftest rat-kingdom-task-test-failure ()
  (rat-kingdom-task-test-with-fake adapter
    (rat-kingdom-task-test--answer
     "" 3 "{\"error\":{\"code\":\"ISSUE_NOT_FOUND\",\"message\":\"Issue not found: nope\"}}")
    (let ((err (should-error (rat-kingdom-task-show adapter "nope")
                             :type 'rat-kingdom-task-error)))
      (should (string-match-p "br show nope --json" (cadr err)))
      (should (string-match-p "Issue not found: nope" (cadr err))))))

(ert-deftest rat-kingdom-task-test-real-br ()
  (skip-unless (executable-find "br"))
  (let* ((root (file-name-as-directory
                (file-truename (make-temp-file "rat-kingdom-task-br" t))))
         (rat-kingdom-task-br-program (executable-find "br"))
         (adapter (rat-kingdom-task-br (list :name "demo" :path root))))
    (unwind-protect
        (progn
          (let ((default-directory root))
            (should (eql (call-process rat-kingdom-task-br-program nil nil nil
                                       "init")
                         0)))
          (let ((id (rat-kingdom-task-create adapter "-A task" :description "Body"
                                             :priority 1)))
            (should (stringp id))
            (should (equal (mapcar (lambda (task) (plist-get task :id))
                                   (rat-kingdom-task-ready adapter))
                           (list id)))
            (let ((task (rat-kingdom-task-show adapter id)))
              (should (equal (plist-get task :title) "-A task"))
              (should (equal (plist-get task :description) "Body"))
              (should (equal (plist-get task :priority) 1))
              (should (equal (plist-get task :status) "open")))
            (rat-kingdom-task-claim adapter id "run-1")
            (should (equal (plist-get (rat-kingdom-task-show adapter id) :assignee)
                           "run-1"))
            (should (equal (plist-get (rat-kingdom-task-show adapter id) :status)
                           "in_progress"))
            (rat-kingdom-task-release adapter id)
            (should (null (plist-get (rat-kingdom-task-show adapter id) :assignee)))
            (should (equal (plist-get (rat-kingdom-task-show adapter id) :status)
                           "open"))
            (rat-kingdom-task-comment adapter id "Noted")
            (rat-kingdom-task-close adapter id "Done")
            (should (equal (plist-get (rat-kingdom-task-show adapter id) :status)
                           "closed"))
            (should (null (rat-kingdom-task-ready adapter)))
            (should-error (rat-kingdom-task-show adapter "nope-000")
                          :type 'rat-kingdom-task-error)))
      (delete-directory root t))))

;;;; Tasks in the space

(cl-defstruct (rat-kingdom-task-test-fake
               (:constructor rat-kingdom-task-test-fake--create)
               (:copier nil))
  "An in-memory tracker."
  (tasks nil :documentation "The tasks; each may have `:after', a task id.")
  (calls nil :documentation "The calls made, newest first.")
  (fail nil :documentation "Non-nil makes every call fail."))

(defvar rat-kingdom-task-test--tracker nil
  "The fake tracker in use.")

(defun rat-kingdom-task-test--call (fake &rest call)
  "Record CALL on FAKE, or fail if FAKE is told to."
  (push call (rat-kingdom-task-test-fake-calls fake))
  (when (rat-kingdom-task-test-fake-fail fake)
    (signal 'rat-kingdom-task-error (list "the tracker is down"))))

(defun rat-kingdom-task-test--task (fake id)
  "Return the task ID of FAKE."
  (cl-find id (rat-kingdom-task-test-fake-tasks fake)
           :key (lambda (task) (plist-get task :id)) :test #'equal))

(defun rat-kingdom-task-test--set (fake id status)
  "Give the task ID of FAKE the STATUS."
  (plist-put (rat-kingdom-task-test--task fake id) :status status))

(cl-defmethod rat-kingdom-task-ready ((fake rat-kingdom-task-test-fake))
  "Return FAKE's open tasks whose predecessor, if any, is closed."
  (rat-kingdom-task-test--call fake 'ready)
  (cl-remove-if-not
   (lambda (task)
     (and (equal (plist-get task :status) "open")
          (let ((after (plist-get task :after)))
            (or (null after)
                (equal (plist-get (rat-kingdom-task-test--task fake after)
                                  :status)
                       "closed")))))
   (rat-kingdom-task-test-fake-tasks fake)))

(cl-defmethod rat-kingdom-task-close ((fake rat-kingdom-task-test-fake) id reason)
  "Close the task ID of FAKE, saying REASON."
  (rat-kingdom-task-test--call fake 'close id reason)
  (rat-kingdom-task-test--set fake id "closed"))

(cl-defmethod rat-kingdom-task-claim ((fake rat-kingdom-task-test-fake) id run)
  "Claim the task ID of FAKE for RUN."
  (rat-kingdom-task-test--call fake 'claim id run)
  (rat-kingdom-task-test--set fake id "in_progress"))

(cl-defmethod rat-kingdom-task-release ((fake rat-kingdom-task-test-fake) id)
  "Release the task ID of FAKE."
  (rat-kingdom-task-test--call fake 'release id)
  (rat-kingdom-task-test--set fake id "open"))

(defmacro rat-kingdom-task-test-with-tracker (vars &rest body)
  "Run BODY with a fresh space, repository and fake tracker.
VARS is (SPACE FAKE).  The repository \"demo\" has FAKE as its adapter
and two open tasks: T-1, and T-2, which waits for T-1.  Story events
reach the task tracker."
  (declare (indent 1) (debug t))
  (let ((path (make-symbol "path")))
    `(rat-kingdom-story-test-with-repo (,(car vars) ,path)
       (ignore ,path)
       (let* ((,(cadr vars)
               (rat-kingdom-task-test-fake--create
                :tasks (list (list :id "T-1" :title "First" :description "Do it"
                                   :status "open" :priority 1 :type "task")
                             (list :id "T-2" :title "Second" :status "open"
                                   :priority 2 :type "bug" :after "T-1"))))
              (rat-kingdom-task-test--tracker ,(cadr vars))
              (rat-kingdom-task-adapter-function
               (lambda (repo)
                 (and (equal (plist-get repo :name) "demo")
                      rat-kingdom-task-test--tracker)))
              (rat-kingdom-story-event-functions
               (cons #'rat-kingdom-task-story-event
                     rat-kingdom-story-event-functions)))
         ,@body))))

(defun rat-kingdom-task-test--available (space)
  "Return the ids of the tasks available in SPACE for demo."
  (mapcar (lambda (tuple) (plist-get tuple :identity))
          (rat-kingdom-space-scan space '(available :scope "demo"))))

(defun rat-kingdom-task-test--drain (fake call)
  "Run timers until FAKE has been given a call whose head is CALL."
  (let ((tries 0))
    (while (and (not (assq call (rat-kingdom-task-test-fake-calls fake)))
                (< (cl-incf tries) 100))
      (accept-process-output nil 0.01))
    ;; The projection follows the call in the same timer.
    (accept-process-output nil 0.01)))

(ert-deftest rat-kingdom-task-test-default-adapter ()
  (let ((root (file-name-as-directory (make-temp-file "rat-kingdom-task" t))))
    (unwind-protect
        (let ((repo (list :name "demo" :path root)))
          (should-not (rat-kingdom-task-default-adapter repo))
          (make-directory (expand-file-name ".beads" root))
          (should (equal (rat-kingdom-task-br-directory
                          (rat-kingdom-task-default-adapter repo))
                         root)))
      (delete-directory root t))))

(ert-deftest rat-kingdom-task-test-project ()
  (rat-kingdom-task-test-with-tracker (space fake)
    (should (eql (rat-kingdom-task-project space "demo") 1))
    (should (equal (rat-kingdom-task-test--available space) '("T-1")))
    (let ((tuple (rat-kingdom-space-rd space '(available :identity "T-1"))))
      (should (eq (plist-get tuple :modality) 'linear))
      (should (equal (plist-get tuple :payload)
                     '(:title "First" :description "Do it" :priority 1
                       :type "task"))))
    ;; Projecting again changes nothing.
    (should (eql (rat-kingdom-task-project space "demo") 1))
    (should (eql (length (rat-kingdom-space-scan space '(available))) 1))
    ;; A task that is no longer ready is withdrawn; one that is, appears.
    (rat-kingdom-task-test--set fake "T-1" "closed")
    (should (eql (rat-kingdom-task-project-all space) 1))
    (should (equal (rat-kingdom-task-test--available space) '("T-2")))
    ;; A task a story already has is not made available.
    (rat-kingdom-story-start space "demo" "Second" nil "S-1" nil "T-2")
    (rat-kingdom-task-test--set fake "T-2" "open")
    (should (eql (rat-kingdom-task-project space "demo") 0))
    (should-not (rat-kingdom-task-test--available space))))

(ert-deftest rat-kingdom-task-test-project-without-adapter ()
  (rat-kingdom-task-test-with-tracker (space fake)
    (let ((rat-kingdom-task-adapter-function #'ignore))
      (should-not (rat-kingdom-task-project space "demo"))
      (should (eql (rat-kingdom-task-project-all space) 0))
      (rat-kingdom-story-start space "demo" "Plain" nil "S-1" nil "T-1")
      (rat-kingdom-story-cancel space "S-1")
      (accept-process-output nil 0.02))
    (should-not (rat-kingdom-space-scan space '(available)))
    (should-not (rat-kingdom-task-test-fake-calls fake))
    (should-not (rat-kingdom-task-project space "nowhere"))))

(ert-deftest rat-kingdom-task-test-project-failure-leaves-space-alone ()
  (rat-kingdom-task-test-with-tracker (space fake)
    (rat-kingdom-task-project space "demo")
    (let ((before (rat-kingdom-space-scan space '(available))))
      (rat-kingdom-task-test--set fake "T-1" "closed")
      (setf (rat-kingdom-task-test-fake-fail fake) t)
      (should-not (rat-kingdom-task-project space "demo"))
      (should (equal (rat-kingdom-space-scan space '(available)) before)))))

(ert-deftest rat-kingdom-task-test-story-takes-and-claims ()
  (rat-kingdom-task-test-with-tracker (space fake)
    (rat-kingdom-task-project space "demo")
    (should (equal (rat-kingdom-story-start space "demo" "First" "Do it" "S-1"
                                            nil "T-1")
                   "S-1"))
    (should (equal (rat-kingdom-story-test--get space "S-1" :task) "T-1"))
    (should-not (rat-kingdom-task-test--available space))
    (should (equal (car (rat-kingdom-task-test-fake-calls fake))
                   '(claim "T-1" "S-1")))
    ;; With no `available' tuple, and a tracker that fails, a story
    ;; still starts.
    (setf (rat-kingdom-task-test-fake-fail fake) t)
    (rat-kingdom-story-start space "demo" "Second" nil "S-2" nil "T-2")
    (should (equal (rat-kingdom-story-test--get space "S-2" :task) "T-2"))
    (should (equal (car (rat-kingdom-task-test-fake-calls fake))
                   '(claim "T-2" "S-2")))
    ;; A story without a task has none.
    (rat-kingdom-story-start space "demo" "Third" nil "S-3")
    (should-not (plist-member (plist-get (rat-kingdom-story-get space "S-3")
                                         :payload)
                              :task))))

(ert-deftest rat-kingdom-task-test-merge-closes-and-projects ()
  (rat-kingdom-task-test-with-tracker (space fake)
    (rat-kingdom-task-project space "demo")
    (rat-kingdom-story-start space "demo" "First" nil "S-1" nil "T-1")
    (rat-kingdom-reaction-run space)
    (rat-kingdom-story-test--work space "S-1" "first.txt")
    (rat-kingdom-story-test--settle space "S-1")
    (should-not (rat-kingdom-story-get space "S-1"))
    (rat-kingdom-task-test--drain fake 'close)
    (let ((head (rat-kingdom-git-rev (plist-get (rat-kingdom-repo-get space "demo")
                                                :path)
                                     "rk/integration")))
      (should (equal (assq 'close (rat-kingdom-task-test-fake-calls fake))
                     (list 'close "T-1"
                           (format "Merged into rk/integration at %s"
                                   (substring head 0 7))))))
    (should (equal (rat-kingdom-task-test--available space) '("T-2")))))

(ert-deftest rat-kingdom-task-test-cancel-releases ()
  (rat-kingdom-task-test-with-tracker (space fake)
    (rat-kingdom-task-project space "demo")
    (rat-kingdom-story-start space "demo" "First" nil "S-1" nil "T-1")
    (rat-kingdom-reaction-run space)
    (rat-kingdom-story-cancel space "S-1")
    (rat-kingdom-task-test--drain fake 'release)
    (should (member '(release "T-1") (rat-kingdom-task-test-fake-calls fake)))
    (should-not (assq 'close (rat-kingdom-task-test-fake-calls fake)))
    (should (equal (rat-kingdom-task-test--available space) '("T-1")))))

(ert-deftest rat-kingdom-task-test-tracker-failure-after-merge-is-demoted ()
  (rat-kingdom-task-test-with-tracker (space fake)
    (rat-kingdom-story-start space "demo" "First" nil "S-1" nil "T-1")
    (setf (rat-kingdom-task-test-fake-fail fake) t)
    (rat-kingdom-reaction-run space)
    (rat-kingdom-story-test--work space "S-1" "first.txt")
    (rat-kingdom-story-test--settle space "S-1")
    ;; The story was merged and archived all the same.
    (should-not (rat-kingdom-story-get space "S-1"))
    (should (equal rat-kingdom-story-test--events '((done . "S-1"))))
    (should (equal (rat-kingdom-story-test--git
                    (plist-get (rat-kingdom-repo-get space "demo") :path)
                    "show" "rk/integration:first.txt")
                   "work"))
    (rat-kingdom-task-test--drain fake 'close)
    (should (assq 'close (rat-kingdom-task-test-fake-calls fake)))
    (should-not (rat-kingdom-space-scan space '(available)))
    (should-not (rat-kingdom-reaction-failures space))))

(provide 'rat-kingdom-task-test)
;;; rat-kingdom-task-test.el ends here
