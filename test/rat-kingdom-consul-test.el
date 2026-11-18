;;; rat-kingdom-consul-test.el --- Tests for consuls and rats' names -*- lexical-binding: t; -*-

;;; Commentary:

;; Batch tests for consuls: starting one, what it is told and may do,
;; status, dismissing it with and without commits and with uncommitted
;; changes, and taking it up again after a restart.  They use the
;; repository fixture of
;; rat-kingdom-story-test.el, with the backend that starts no agent; the
;; tests play the consul.

;;; Code:

(require 'ert)
(require 'rat-kingdom)
(require 'rat-kingdom-consul)
(require 'rat-kingdom-story-test)
(require 'rat-kingdom-king-test)
(require 'rat-kingdom-reload-test)

(defmacro rat-kingdom-consul-test-with-repo (vars &rest body)
  "Run BODY with VARS, (SPACE PATH), a repository \"demo\" and the king.
Stories follow the workflow story, which the king reviews."
  (declare (indent 1) (debug t))
  `(rat-kingdom-story-test-with-repo ,vars
     (let ((rat-kingdom-story-default-workflow "story"))
       (rat-kingdom-king-test--start ,(car vars))
       ,@body)))

(defun rat-kingdom-consul-test--start (space &rest arguments)
  "Start a consul in demo with `consul_start' and ARGUMENTS, in SPACE.
Return its run record."
  (let ((answer (apply #'rat-kingdom-king-test--ok "consul_start"
                       '(repo . "demo") arguments)))
    (should (string-match "Started the consul [A-Za-z]+-[0-9a-f]\\{4\\} \
(\\(C-[0-9a-f]\\{4\\}\\))" answer))
    (rat-kingdom-run-get space (match-string 1 answer))))

(defun rat-kingdom-consul-test--call (consul tool &rest arguments)
  "Call TOOL as the consul CONSUL, a run record, with ARGUMENTS.
Return (TEXT . FAILED)."
  (apply #'rat-kingdom-story-test--call (plist-get consul :id) tool arguments))

(defun rat-kingdom-consul-test--dismiss (consul &rest arguments)
  "Dismiss CONSUL, a run record, with `consul_dismiss' and ARGUMENTS.
Return (TEXT . FAILED)."
  (apply #'rat-kingdom-king-test--call "consul_dismiss"
         (cons 'consul (plist-get consul :id)) arguments))

;;;; Starting a consul

(ert-deftest rat-kingdom-consul-test-start ()
  (rat-kingdom-consul-test-with-repo (space path)
    (let* ((consul (rat-kingdom-consul-test--start space '(topic . "The cache")))
           (id (plist-get consul :id))
           (name (rat-kingdom-run-display-name consul))
           (worktree (plist-get consul :worktree))
           (branch (plist-get consul :branch))
           (prompt (rat-kingdom-story-test--prompt id)))
      ;; A run of its own, with a name and a worktree on a new branch.
      (should (string-match-p "\\`C-[0-9a-f]\\{4\\}\\'" id))
      (should (equal (plist-get consul :role) "consul"))
      (should (equal (plist-get consul :repo) "demo"))
      (should-not (plist-get consul :story))
      (should (equal (plist-get consul :name) "Pip"))
      (should (equal name (concat "Pip-" (substring id 2))))
      (should (equal (plist-get consul :topic) "The cache"))
      (should (equal (plist-get consul :agent) "claude"))
      (should (equal (plist-get consul :state) "working"))
      (should (equal (plist-get consul :target) "rk/integration"))
      (should (numberp (plist-get consul :started)))
      (should (equal branch (format "rats/consul-pip-%s" (substring id 2))))
      (should (equal worktree
                     (expand-file-name (format "worktrees/demo/%s" id)
                                       rat-kingdom-directory)))
      (should (equal (rat-kingdom-git worktree "rev-parse" "--abbrev-ref" "HEAD")
                     branch))
      (should (equal (rat-kingdom-git-rev path branch)
                     (rat-kingdom-git-rev path "rk/integration")))
      (should (rat-kingdom-git-push-guarded-p path branch))
      ;; The user's checkout is left alone.
      (should (equal (rat-kingdom-git path "rev-parse" "--abbrev-ref" "HEAD")
                     "main"))
      ;; What it is told.
      (should (string-search (format "You are %s, a consul for the repository \
demo" name)
                             prompt))
      (should (string-search "The user wants to talk about: The cache" prompt))
      (should (string-search (format "Your worktree is %s, on your own branch \
%s, cut from rk/integration." worktree branch)
                             prompt))
      (should (string-search "Never push" prompt))
      (should (string-search "Never start stories or epics" prompt))
      (should (string-search "they dismiss you" prompt))
      (should (string-search (rat-kingdom-king-tool-names 'consul) prompt))
      (should-not (string-search "{" prompt))
      ;; Its tools are few: no story's, no king's.
      (should (equal (sort (copy-sequence (rat-kingdom-mcp-tool-names 'consul))
                           #'string<)
                     '("note_fact" "read_doc" "write_doc")))
      (dolist (refused '("finish" "block" "story_start" "epic_start" "tell"
                         "status" "publish"))
        (let ((answer (rat-kingdom-consul-test--call consul refused)))
          (should (cdr answer))
          (should (string-search "unknown tool" (car answer))))))))

(ert-deftest rat-kingdom-consul-test-start-answer-and-choices ()
  (rat-kingdom-consul-test-with-repo (space _path)
    (let* ((answer (rat-kingdom-king-test--ok "consul_start" '(repo . "demo")))
           (id (and (string-match "(\\(C-[0-9a-f]\\{4\\}\\))" answer)
                    (match-string 1 answer)))
           (consul (rat-kingdom-run-get space id)))
      (should (string-search (format "in the buffer consul %s, shown to the \
user"
                                     (rat-kingdom-run-label consul))
                             answer))
      (should (string-search "consul_dismiss ends it" answer))
      (should-not (plist-get consul :topic))
      (should-not (string-search "talk about"
                                 (rat-kingdom-story-test--prompt id))))
    ;; The agent is the configured :agents :consul, by default the
    ;; user's; one can be named, and a model.
    (let* ((rat-kingdom-default-agent 'codex)
           (consul (rat-kingdom-consul-test--start space)))
      (should (equal (plist-get consul :agent) "codex")))
    (let ((consul (rat-kingdom-consul-test--start
                   space '(agent . "claude") '(model . "claude-opus-5-5"))))
      (should (equal (plist-get consul :agent) "claude"))
      (should (equal (plist-get consul :model) "claude-opus-5-5")))
    ;; Live consuls never share a name.
    (should (equal (length (cl-remove-duplicates
                            (mapcar (lambda (run) (plist-get run :name))
                                    (rat-kingdom-consul-list space))
                            :test #'equal))
                   3))
    ;; A repository that is not registered is refused.
    (let ((answer (rat-kingdom-king-test--call "consul_start"
                                               '(repo . "nowhere"))))
      (should (cdr answer))
      (should (string-search "No repository called nowhere" (car answer))))))

;;;; Status

(ert-deftest rat-kingdom-consul-test-status ()
  (rat-kingdom-consul-test-with-repo (space _path)
    (should-not (string-search "Consuls" (rat-kingdom-king-test--ok "status")))
    (let* ((consul (rat-kingdom-consul-test--start space '(topic . "Docs")))
           (line (format "- %s %s [demo] working, "
                         (plist-get consul :id)
                         (rat-kingdom-run-display-name consul))))
      (let ((status (rat-kingdom-king-test--ok "status")))
        (should (string-search "Consuls (each talks with the user in its own \
buffer" status))
        (should (string-search line status))
        (should (string-search (format ", claude; topic: Docs; branch %s, 0 \
commits ahead of rk/integration"
                                       (plist-get consul :branch))
                               status)))
      (rat-kingdom-story-test--commit (plist-get consul :worktree) "notes.md"
                                      "notes\n" "Add notes")
      (should (string-search "1 commit ahead of rk/integration"
                             (rat-kingdom-king-test--ok "status")))
      ;; Its age is shown.
      (let ((rat-kingdom-story-test--now
             (+ (plist-get consul :started) 600)))
        (should (string-search (concat line "10m, claude")
                               (rat-kingdom-king-test--ok "status")))))))

;;;; Docs and news

(ert-deftest rat-kingdom-consul-test-docs-and-no-news ()
  (rat-kingdom-consul-test-with-repo (space _path)
    (let* ((consul (rat-kingdom-consul-test--start space))
           (answer (rat-kingdom-consul-test--call
                    consul "write_doc" '(title . "The cache")
                    '(body . "It is LRU."))))
      (should-not (cdr answer))
      (should (string-match "Wrote doc \\(D-[0-9a-f]\\{4\\}\\)" (car answer)))
      (let ((doc (rat-kingdom-doc-get space (match-string 1 (car answer)))))
        ;; Written with the user, so approved at once; no story's.
        (should (equal (rat-kingdom-doc--field doc :status) "approved"))
        (should (equal (rat-kingdom-doc--field doc :run) (plist-get consul :id)))
        (should-not (rat-kingdom-doc--field doc :story))
        (should (equal (car (rat-kingdom-consul-test--call
                             consul "read_doc"
                             (cons 'id (plist-get doc :identity))))
                       (rat-kingdom-doc--describe doc))))
      (should-not (cdr (rat-kingdom-consul-test--call
                        consul "note_fact" '(fact . "Tests run with make."))))
      ;; Stories come and go; no news is addressed to it.
      (rat-kingdom-story-start space "demo" "Add a file" "Any file." "S-1")
      (rat-kingdom-reaction-run space)
      (rat-kingdom-story-test--call "S-1.1" "block" '(summary . "Unclear."))
      (rat-kingdom-reaction-run space)
      (should (rat-kingdom-king-test--news space))
      (should-not (rat-kingdom-space-scan
                   space (list 'message :to (plist-get consul :id))))
      ;; The king's tools for stories do not reach it.
      (let ((told (rat-kingdom-king-test--call
                   "tell" (cons 'story (plist-get consul :id))
                   '(text . "Hello."))))
        (should (cdr told))))))

;;;; Dismissing

(ert-deftest rat-kingdom-consul-test-dismiss-without-commits ()
  (rat-kingdom-consul-test-with-repo (space path)
    (let* ((consul (rat-kingdom-consul-test--start space))
           (id (plist-get consul :id))
           (doc (car (rat-kingdom-consul-test--call
                      consul "write_doc" '(title . "Design")
                      '(body . "We keep it.")))))
      (string-match "D-[0-9a-f]\\{4\\}" doc)
      (setq doc (match-string 0 doc))
      ;; Only harness files are in its worktree, which do not count.
      (make-directory (expand-file-name ".agent-shell"
                                        (plist-get consul :worktree)))
      (with-temp-file (expand-file-name ".agent-shell/transcript"
                                        (plist-get consul :worktree))
        (insert "x"))
      (let ((answer (rat-kingdom-consul-test--dismiss consul)))
        (should-not (cdr answer))
        (should (string-search (format "Dismissed the consul %s. It made no \
commits, so its worktree and its branch %s are removed."
                                       (rat-kingdom-run-label consul)
                                       (plist-get consul :branch))
                               (car answer)))
        (should (string-search (format "Its docs stay: %s." doc) (car answer))))
      ;; Its agent is stopped, its worktree and branch gone, its record
      ;; archived; its doc stays.
      (should (member id rat-kingdom-story-test--stopped))
      (should-not (rat-kingdom-run-live-p id))
      (should-not (file-directory-p (plist-get consul :worktree)))
      (should-not (rat-kingdom-git-ok-p path "rev-parse" "--verify" "--quiet"
                                        (concat "refs/heads/"
                                                (plist-get consul :branch))))
      (should-not (rat-kingdom-run-get space id))
      (should-not (rat-kingdom-consul-list space))
      (should (rat-kingdom-doc-get space doc))
      (should-not (rat-kingdom-story-list space))
      (should-not (string-search "Consuls" (rat-kingdom-king-test--ok "status")))
      ;; Its id is not given again.
      (should (rat-kingdom-consul--used-p space id))
      (let ((again (rat-kingdom-consul-test--dismiss consul)))
        (should (cdr again))
        (should (string-search "There is no consul" (car again)))))))

(ert-deftest rat-kingdom-consul-test-dismiss-with-commits-makes-a-story ()
  (rat-kingdom-consul-test-with-repo (space path)
    (let* ((consul (rat-kingdom-consul-test--start space '(topic . "Caching")))
           (worktree (plist-get consul :worktree))
           (branch (plist-get consul :branch)))
      (rat-kingdom-story-test--commit worktree "cache.txt" "lru\n" "Add a cache")
      (rat-kingdom-story-test--commit worktree "more.txt" "more\n" "Add more")
      (let* ((answer (rat-kingdom-consul-test--dismiss consul))
             (story (and (string-match "the story \\(S-[0-9a-f]\\{4\\}\\)"
                                       (car answer))
                         (match-string 1 (car answer)))))
        (should-not (cdr answer))
        (should (string-search (format "Its 2 commits on %s became the story \
%s (Caching), which starts at checking of the workflow story" branch story)
                               (car answer)))
        (should-not (rat-kingdom-consul-list space))
        ;; A normal story, from the consul's work, on its branch.
        (let ((payload (plist-get (rat-kingdom-story-get space story) :payload)))
          (should (equal (plist-get payload :branch) branch))
          (should (equal (plist-get payload :worktree) worktree))
          (should (equal (plist-get payload :title) "Caching"))
          (should (string-search "Add a cache" (plist-get payload :description)))
          (should-not (plist-get payload :run)))
        ;; It is checked, and waits for the king's review.
        (rat-kingdom-story-test--settle space story)
        (should (equal (rat-kingdom-story-test--get space story :awaiting)
                       "review"))
        (should (cl-some (lambda (text)
                           (string-search (format "%s (Caching) passed its \
check and waits for your review" story)
                                          text))
                         (rat-kingdom-king-test--news space)))
        (should (string-search "cache.txt"
                               (rat-kingdom-king-test--ok
                                "story_diff" (cons 'story story))))
        ;; A pass merges it, as any story's.
        (rat-kingdom-king-test--ok "verdict" (cons 'story story)
                                   '(value . "pass"))
        (rat-kingdom-reaction-run space)
        (should-not (rat-kingdom-story-get space story))
        (should (rat-kingdom-git-ok-p path "cat-file" "-e"
                                      "rk/integration:cache.txt"))
        (should-not (file-directory-p worktree))))))

(ert-deftest rat-kingdom-consul-test-dismiss-title-without-topic ()
  (rat-kingdom-consul-test-with-repo (space _path)
    (let ((consul (rat-kingdom-consul-test--start space)))
      (rat-kingdom-story-test--commit (plist-get consul :worktree) "a.txt" "a\n"
                                      "First change")
      (rat-kingdom-story-test--commit (plist-get consul :worktree) "b.txt" "b\n"
                                      "Second change")
      (should-not (cdr (rat-kingdom-consul-test--dismiss consul)))
      (should (equal (plist-get (plist-get (car (rat-kingdom-story-list space))
                                           :payload)
                                :title)
                     (format "Consul %s: First change"
                             (rat-kingdom-run-display-name consul)))))))

(ert-deftest rat-kingdom-consul-test-uncommitted-changes-refuse-or-force ()
  (rat-kingdom-consul-test-with-repo (space path)
    (let* ((consul (rat-kingdom-consul-test--start space))
           (id (plist-get consul :id))
           (worktree (plist-get consul :worktree)))
      (with-temp-file (expand-file-name "draft.md" worktree)
        (insert "half done\n"))
      ;; Refused, and nothing is lost or stopped.
      (let ((answer (rat-kingdom-consul-test--dismiss consul)))
        (should (cdr answer))
        (should (string-search "Not dismissed" (car answer)))
        (should (string-search "uncommitted changes" (car answer)))
        (should (string-search "draft.md" (car answer)))
        (should (string-search "force" (car answer))))
      (should (rat-kingdom-run-live-p id))
      (should (rat-kingdom-consul-get space id))
      (should (file-exists-p (expand-file-name "draft.md" worktree)))
      ;; Forced, the changes are committed first, and become a story.
      (let ((answer (rat-kingdom-consul-test--dismiss consul '(force . "true"))))
        (should-not (cdr answer))
        (should (string-search "Its uncommitted changes were committed first"
                               (car answer)))
        (should (string-search "Its 1 commit on" (car answer))))
      (should-not (rat-kingdom-run-live-p id))
      (should (string-prefix-p
               "WIP: uncommitted work of the consul"
               (rat-kingdom-git path "log" "-1" "--format=%s"
                                (plist-get consul :branch))))
      (should (rat-kingdom-git-ok-p path "cat-file" "-e"
                                    (concat (plist-get consul :branch)
                                            ":draft.md")))
      (should (eql (length (rat-kingdom-story-list space)) 1)))))

;;;; Restarts

(ert-deftest rat-kingdom-consul-test-taken-up-again-after-a-restart ()
  (rat-kingdom-consul-test-with-repo (space _path)
    (let* ((consul (rat-kingdom-consul-test--start space '(topic . "Kept")))
           (id (plist-get consul :id)))
      (rat-kingdom-run-update space id :session-id "consul-session")
      ;; Emacs stops: the consul's agent is gone, its run still working.
      (remhash id rat-kingdom-run--handles)
      ;; Status still lists it.
      (should (string-search (format "- %s %s [demo]" id
                                     (rat-kingdom-run-display-name consul))
                             (rat-kingdom-consul-status space)))
      (let ((found (rat-kingdom-reconcile)))
        (should (member id (plist-get found :runs)))
        (should (equal (plist-get found :consuls) (list id))))
      (rat-kingdom-reaction-run space)
      ;; Taken up again, in its session, with its name, topic and place.
      (let ((run (rat-kingdom-run-get space id))
            (started (car (cl-find id rat-kingdom-story-test--started
                                   :key (lambda (entry)
                                          (plist-get (car entry) :id))
                                   :test #'equal))))
        (should (rat-kingdom-run-live-p id))
        (should (equal (plist-get started :resume) "consul-session"))
        (dolist (key '(:name :topic :branch :worktree :target :started :agent))
          (should (equal (plist-get run key) (plist-get consul key))))
        (should (string-prefix-p (format "[rat-kingdom] Your session was \
restarted; you are still the consul %s for demo"
                                         (rat-kingdom-run-display-name consul))
                                 (rat-kingdom-story-test--prompt id))))
      ;; Reconciling again changes nothing.
      (should-not (plist-get (rat-kingdom-reconcile) :consuls))
      ;; One whose agent ended is started again when it is shown.
      (rat-kingdom-run-exited id)
      (should (string-search "exited, not running"
                             (rat-kingdom-consul-status space)))
      (rat-kingdom-consul-reopen space id)
      (should (rat-kingdom-run-live-p id))
      (should (equal (plist-get (car (car rat-kingdom-story-test--started))
                                :name)
                     (plist-get consul :name)))
      ;; And it can be dismissed as usual.
      (should-not (cdr (rat-kingdom-consul-test--dismiss consul))))))

;;;; Commands and its buffer

(ert-deftest rat-kingdom-consul-test-commands-and-buffer ()
  (rat-kingdom-consul-test-with-repo (space _path)
    (let* ((buffers nil)
           (rat-kingdom-mode t)
           (rat-kingdom-run-backend
            (list :start (lambda (run prompt)
                           (let ((token (rat-kingdom-mcp-grant
                                         (plist-get run :id)
                                         (intern (plist-get run :role))))
                                 (buffer (generate-new-buffer
                                          (rat-kingdom-agent-shell--buffer-name
                                           run))))
                             (push buffer buffers)
                             (push (list run prompt token)
                                   rat-kingdom-story-test--started)
                             buffer))
                  :stop (lambda (buffer) (kill-buffer buffer)))))
      (unwind-protect
          (let* ((id (save-window-excursion
                       (rat-kingdom-consul-start "demo" "Things")))
                 (consul (rat-kingdom-run-get space id))
                 (buffer (rat-kingdom-run-handle id)))
            ;; Its buffer is named for it, and marked.
            (should (equal (buffer-name buffer)
                           (format "consul %s" (rat-kingdom-run-label consul))))
            (with-current-buffer buffer
              (should rat-kingdom-consul-mode)
              (should (equal rat-kingdom-consul--buffer-id id))
              (should (eq (key-binding (kbd "C-c ~ d"))
                          #'rat-kingdom-consul-dismiss))
              ;; Asked there, it is the consul offered first.
              (cl-letf (((symbol-function 'completing-read)
                         (lambda (_prompt choices &rest args)
                           (should (assoc (nth 4 args) choices))
                           (nth 4 args))))
                (should (equal (rat-kingdom-consul--read "Dismiss consul")
                               id))))
            (should (string-search "Dismissed the consul"
                                   (rat-kingdom-consul-dismiss id)))
            (should-not (buffer-live-p buffer))
            (should-not (rat-kingdom-consul-list space)))
        (mapc (lambda (buffer)
                (when (buffer-live-p buffer) (kill-buffer buffer)))
              buffers)))))

;;;; Reloading

(ert-deftest rat-kingdom-consul-test-reload-keeps-one-of-each ()
  (rat-kingdom-reload-test--isolated
    (let ((rat-kingdom-king-status-functions
           (copy-sequence rat-kingdom-king-status-functions)))
      (rat-kingdom-reload)
      (rat-kingdom-reload)
      (should (member "rat-kingdom-consul" rat-kingdom--files))
      (should (eql (cl-count #'rat-kingdom-consul-status
                             rat-kingdom-king-status-functions)
                   1))
      (should (eql (cl-count #'rat-kingdom-consul--on-change
                             rat-kingdom-space-change-functions)
                   1))
      (dolist (role '(king consul))
        (should (rat-kingdom-reload-test--once-each
                 (rat-kingdom-mcp-tool-names role))))
      (dolist (name '("consul_start" "consul_dismiss"))
        (should (member name (rat-kingdom-mcp-tool-names 'king)))))))

(provide 'rat-kingdom-consul-test)
;;; rat-kingdom-consul-test.el ends here
