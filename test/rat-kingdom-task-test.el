;;; rat-kingdom-task-test.el --- Tests for the task adapter -*- lexical-binding: t; -*-

;;; Commentary:

;; Batch tests for the Rust Beads adapter.  A fake br, a shell script,
;; records the directory it ran in and its arguments, prints canned JSON
;; shaped like the real br's and exits as told.  One test uses the real
;; br, if it is installed, in a disposable workspace.

;;; Code:

(require 'ert)
(require 'rat-kingdom-task)

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

(provide 'rat-kingdom-task-test)
;;; rat-kingdom-task-test.el ends here
