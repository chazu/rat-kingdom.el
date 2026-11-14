;;; rat-kingdom-fact-test.el --- Tests for facts and the king's query -*- lexical-binding: t; -*-

;;; Commentary:

;; Batch tests for `note_fact', the facts in a worker's brief, and the
;; king's `query' and `fact_forget'.  They use the fixture of
;; rat-kingdom-story-test.el: real Git, a backend that starts no agent
;; and records prompts, and tools called over JSON-RPC.

;;; Code:

(require 'ert)
(require 'rat-kingdom)
(require 'rat-kingdom-fact)
(require 'rat-kingdom-story-test)
(require 'rat-kingdom-king-test)
(require 'rat-kingdom-reload-test)

(defun rat-kingdom-fact-test--other-repo (space path)
  "Make and register a second repository, \"other\", beside PATH in SPACE."
  (let ((other (expand-file-name "../other/" path)))
    (make-directory other)
    (rat-kingdom-story-test--git other "init" "-q" "-b" "main")
    (rat-kingdom-story-test--git other "config" "user.name" "Test")
    (rat-kingdom-story-test--git other "config" "user.email" "test@example.com")
    (rat-kingdom-story-test--commit other "README" "other\n" "Initial commit")
    (rat-kingdom-repo-add space other)
    other))

(defun rat-kingdom-fact-test--start (space id &optional repo)
  "Start the story ID in REPO, by default demo, in SPACE and its worker."
  (rat-kingdom-story-start space (or repo "demo") (format "Task %s" id)
                           "Do it." id)
  (rat-kingdom-reaction-run space))

(defun rat-kingdom-fact-test--note (run &rest arguments)
  "Call note_fact as RUN with ARGUMENTS.  Return (TEXT . FAILED)."
  (apply #'rat-kingdom-story-test--call run "note_fact" arguments))

(defun rat-kingdom-fact-test--facts (space)
  "Return the live facts in SPACE, oldest first."
  (rat-kingdom-space-scan space '(fact)))

(defun rat-kingdom-fact-test--run (repo)
  "Return a run record in REPO, for writing facts directly."
  (list :id "S-9.1" :repo repo :story "S-9"))

;;;; Recording

(ert-deftest rat-kingdom-fact-test-note-fact-outlives-its-story ()
  (rat-kingdom-story-test-with-repo (space _path)
    (rat-kingdom-fact-test--start space "S-1")
    (let* ((answer (rat-kingdom-fact-test--note
                    "S-1.1" '(fact . "  Run the tests with make check.  ")
                    '(topic . "testing") '(files . "Makefile, test/a.el,")))
           (fact (car (rat-kingdom-fact-test--facts space)))
           (payload (plist-get fact :payload)))
      (should-not (cdr answer))
      (should (string-prefix-p (format "Recorded fact %d." (plist-get fact :id))
                               (car answer)))
      (should (eql (length (rat-kingdom-fact-test--facts space)) 1))
      (should-not (cdr (rat-kingdom-fact-test--note
                        "S-1.1" '(fact . "Another."))))
      (should (equal (plist-get fact :scope) "demo"))
      (should-not (plist-get fact :owner))
      (should (eq (plist-get fact :modality) 'persistent))
      (should (equal (plist-get payload :text) "Run the tests with make check."))
      (should (equal (plist-get payload :topic) "testing"))
      (should (equal (plist-get payload :files) '("Makefile" "test/a.el")))
      (should (equal (plist-get payload :story) "S-1"))
      (should (equal (plist-get payload :run) "S-1.1"))
      (should (equal (rat-kingdom-fact--actor space (plist-get fact :id))
                     "S-1.1")))
    ;; The story is merged and archived; the facts stay.
    (should-not (cdr (rat-kingdom-story-test--work space "S-1" "feature.txt")))
    (rat-kingdom-story-test--settle space "S-1")
    (should-not (rat-kingdom-story-get space "S-1"))
    (should (rat-kingdom-space-archived space "S-1"))
    (should (eql (length (rat-kingdom-fact-test--facts space)) 2))
    ;; So they do when a story is cancelled.
    (rat-kingdom-fact-test--start space "S-2")
    (rat-kingdom-fact-test--note "S-2.1" '(fact . "A third."))
    (rat-kingdom-story-cancel space "S-2")
    (should-not (rat-kingdom-story-get space "S-2"))
    (should (eql (length (rat-kingdom-fact-test--facts space)) 3))
    (should-not (cl-find 'fact (rat-kingdom-space-archived space)
                         :key (lambda (tuple) (plist-get tuple :category))))))

(ert-deftest rat-kingdom-fact-test-note-fact-validates ()
  (rat-kingdom-story-test-with-repo (space _path)
    (rat-kingdom-fact-test--start space "S-1")
    (let ((answer (rat-kingdom-fact-test--note "S-1.1" '(fact . "   \n "))))
      (should (cdr answer))
      (should (string-search "needs some text" (car answer))))
    (should (cdr (rat-kingdom-fact-test--note "S-1.1" '(topic . "x"))))
    (let* ((rat-kingdom-fact-max-length 10)
           (answer (rat-kingdom-fact-test--note
                    "S-1.1" '(fact . "Eleven char"))))
      (should (cdr answer))
      (should (string-search "at most 10 characters" (car answer)))
      (should-not (cdr (rat-kingdom-fact-test--note
                        "S-1.1" '(fact . "Ten chars!")))))
    (should (eql (length (rat-kingdom-fact-test--facts space)) 1))))

;;;; The brief

(ert-deftest rat-kingdom-fact-test-brief-has-the-repos-facts ()
  (rat-kingdom-story-test-with-repo (space path)
    (rat-kingdom-fact-test--other-repo space path)
    (rat-kingdom-fact-test--start space "S-1")
    (should-not (string-search "Facts recorded"
                               (rat-kingdom-story-test--prompt "S-1.1")))
    (rat-kingdom-fact-test--note "S-1.1" '(fact . "Old fact.\nTwo lines."))
    (rat-kingdom-fact-test--note "S-1.1" '(fact . "Configs live in etc/.")
                                 '(topic . "layout")
                                 '(files . "etc/a.conf, etc/b.conf"))
    (rat-kingdom-fact-test--start space "S-2")
    (let ((prompt (rat-kingdom-story-test--prompt "S-2.1")))
      (should (string-search "Facts recorded by earlier workers in this \
repository (newest first):" prompt))
      (should (string-search "- [layout] Configs live in etc/.\n  Files: \
etc/a.conf, etc/b.conf\n" prompt))
      (should (string-search "- Old fact.\n  Two lines.\n" prompt))
      (should (< (string-search "Configs live" prompt)
                 (string-search "Old fact" prompt)))
      ;; The facts come after the task.
      (should (< (string-search "Task S-2" prompt)
                 (string-search "Facts recorded" prompt))))
    ;; A story in another repository is not told them.
    (rat-kingdom-fact-test--start space "S-3" "other")
    (let ((prompt (rat-kingdom-story-test--prompt "S-3.1")))
      (should (string-search "Task S-3" prompt))
      (should-not (string-search "Facts recorded" prompt))
      (should-not (string-search "Configs live" prompt)))))

(ert-deftest rat-kingdom-fact-test-brief-is-capped ()
  (rat-kingdom-story-test-with-repo (space _path)
    (dotimes (i 5)
      (rat-kingdom-fact-note space (rat-kingdom-fact-test--run "demo")
                             (format "Fact number %d." (1+ i))))
    (let ((story (list :scope "demo")))
      (should-not (rat-kingdom-fact-brief space (list :scope "nowhere") "x"))
      (let ((brief (rat-kingdom-fact-brief space story "x")))
        (dotimes (i 5)
          (should (string-search (format "Fact number %d." (1+ i)) brief)))
        (should-not (string-search "left out" brief)))
      ;; By count.
      (let* ((rat-kingdom-fact-brief-max-count 3)
             (brief (rat-kingdom-fact-brief space story "x")))
        (should (string-search "Fact number 5." brief))
        (should (string-search "Fact number 3." brief))
        (should-not (string-search "Fact number 2." brief))
        (should (string-search "(2 older facts are left out.)" brief)))
      ;; By characters: each entry is "- Fact number N.\n", 17 of them.
      (let* ((rat-kingdom-fact-brief-max-chars 40)
             (brief (rat-kingdom-fact-brief space story "x")))
        (should (string-search "Fact number 5." brief))
        (should (string-search "Fact number 4." brief))
        (should-not (string-search "Fact number 3." brief))
        (should (string-search "(3 older facts are left out.)" brief)))
      (let* ((rat-kingdom-fact-brief-max-chars 5)
             (brief (rat-kingdom-fact-brief space story "x")))
        (should-not (string-search "Fact number" brief))
        (should (string-search "(5 older facts are left out.)" brief))))))

(ert-deftest rat-kingdom-fact-test-a-failing-brief-function-is-left-out ()
  (rat-kingdom-story-test-with-repo (space _path)
    (let ((rat-kingdom-story-brief-functions
           (list (lambda (&rest _) (error "Broken"))
                 (lambda (_space story run)
                   (format "Section for %s and %s."
                           (plist-get story :identity) run))
                 #'ignore)))
      (rat-kingdom-fact-test--start space "S-1")
      (let ((prompt (rat-kingdom-story-test--prompt "S-1.1")))
        (should (string-search "\nSection for S-1 and S-1.1.\n" prompt))
        (should-not (string-search "Broken" prompt))))))

;;;; The king's tools

(ert-deftest rat-kingdom-fact-test-query ()
  (rat-kingdom-story-test-with-repo (space path)
    (rat-kingdom-fact-test--other-repo space path)
    (rat-kingdom-king-test--start space)
    (rat-kingdom-fact-note space (rat-kingdom-fact-test--run "demo")
                           "Use MAKE CHECK." :topic "testing")
    (rat-kingdom-fact-note space (rat-kingdom-fact-test--run "demo")
                           "The docs are in doc/.")
    (rat-kingdom-fact-note space (rat-kingdom-fact-test--run "other")
                           "Other repo's fact.")
    (let ((ops (length (rat-kingdom-space-ops space)))
          (counts (rat-kingdom-space-counts space)))
      (let ((text (rat-kingdom-king-test--ok "query" '(category . "fact"))))
        (should (string-prefix-p "3 tuples match, newest first.\n" text))
        (should-not (string-search "cut off" text))
        (should (< (string-search "Other repo's fact." text)
                   (string-search "Use MAKE CHECK." text)))
        (should (string-search "category: fact" text))
        (should (string-search "scope: demo" text))
        (should (string-search "owner: -" text))
        (should (string-search "actor: S-9.1" text))
        (should (string-search "  :topic testing" text))
        (should (string-match-p "time: [0-9]\\{4\\}-" text)))
      (let ((text (rat-kingdom-king-test--ok "query" '(category . "fact")
                                             '(scope . "demo"))))
        (should (string-prefix-p "2 tuples match" text))
        (should-not (string-search "Other repo" text)))
      (let ((text (rat-kingdom-king-test--ok "query" '(category . "fact")
                                             '(contains . "make check"))))
        (should (string-prefix-p "1 tuple matches" text))
        (should (string-search "Use MAKE CHECK." text)))
      (let ((text (rat-kingdom-king-test--ok "query" '(category . "fact")
                                             '(limit . "1"))))
        (should (string-prefix-p "3 tuples match" text))
        (should (string-search "cut off: showing the newest 1" text))
        (should (string-search "Other repo's fact." text))
        (should-not (string-search "Use MAKE CHECK." text)))
      (should (string-search "No fact tuples match"
                             (rat-kingdom-king-test--ok
                              "query" '(category . "fact")
                              '(contains . "nothing like this"))))
      (let ((answer (rat-kingdom-king-test--call "query"
                                                 '(category . "facts"))))
        (should (cdr answer))
        (should (string-search "There is no category facts" (car answer)))
        (should (string-search "fact, message" (car answer))))
      (should (cdr (rat-kingdom-king-test--call "query" '(category . "fact")
                                                '(limit . "many"))))
      (should (cdr (rat-kingdom-king-test--call "query" '(category . "fact")
                                                '(archived . "maybe"))))
      ;; Nothing was written.
      (should (eql (length (rat-kingdom-space-ops space)) ops))
      (should (equal (rat-kingdom-space-counts space) counts)))
    ;; Archived tuples only when asked for.
    (rat-kingdom-fact-test--start space "S-1")
    (rat-kingdom-story-cancel space "S-1")
    (should (string-search "No story tuples match"
                           (rat-kingdom-king-test--ok
                            "query" '(category . "story")
                            '(identity . "S-1"))))
    (let ((text (rat-kingdom-king-test--ok "query" '(category . "story")
                                           '(identity . "S-1")
                                           '(archived . "true"))))
      (should (string-prefix-p "1 tuple matches" text))
      (should (string-search "archived: " text))
      (should (string-search "(sweep)" text))
      (should (string-search "owner: S-1" text)))
    ;; A long payload is cut.
    (let ((rat-kingdom-fact-query-payload-limit 10))
      (should (string-search "more characters)"
                             (rat-kingdom-king-test--ok
                              "query" '(category . "fact")))))))

(ert-deftest rat-kingdom-fact-test-forget ()
  (rat-kingdom-story-test-with-repo (space _path)
    (rat-kingdom-king-test--start space)
    (let* ((fact (rat-kingdom-fact-note space (rat-kingdom-fact-test--run "demo")
                                        "Wrong fact."))
           (other (rat-kingdom-fact-note space (rat-kingdom-fact-test--run "demo")
                                         "Right fact."))
           (repo (rat-kingdom-space-rd space '(repo :identity "demo"))))
      (let ((answer (rat-kingdom-king-test--call
                     "fact_forget" (cons 'id (number-to-string
                                              (plist-get repo :id))))))
        (should (cdr answer))
        (should (string-search "is a repo, not a fact" (car answer))))
      (should (cdr (rat-kingdom-king-test--call "fact_forget" '(id . "99999"))))
      (should (cdr (rat-kingdom-king-test--call "fact_forget" '(id . "one"))))
      (should (rat-kingdom-space-rd space '(repo :identity "demo")))
      (should (string-search "Forgot fact"
                             (rat-kingdom-king-test--ok
                              "fact_forget"
                              (cons 'id (number-to-string
                                         (plist-get fact :id))))))
      (should (equal (mapcar (lambda (tuple) (plist-get tuple :id))
                             (rat-kingdom-fact-test--facts space))
                     (list (plist-get other :id))))
      (should (eq (plist-get (car (rat-kingdom-space-ops space 1)) :op)
                  'retract))
      ;; A forgotten fact is not forgotten twice.
      (should (cdr (rat-kingdom-king-test--call
                    "fact_forget" (cons 'id (number-to-string
                                             (plist-get fact :id)))))))))

(ert-deftest rat-kingdom-fact-test-tools-by-role ()
  (let ((names (lambda (role)
                 (mapcar (lambda (tool) (plist-get tool :name))
                         (rat-kingdom-mcp-tool-list role)))))
    (should (member "note_fact" (funcall names 'rat)))
    (should-not (member "query" (funcall names 'rat)))
    (should-not (member "fact_forget" (funcall names 'rat)))
    (should (member "query" (funcall names 'king)))
    (should (member "fact_forget" (funcall names 'king)))
    (should-not (member "note_fact" (funcall names 'king))))
  (rat-kingdom-story-test-with-repo (space _path)
    (rat-kingdom-king-test--start space)
    (rat-kingdom-fact-test--start space "S-1")
    (let ((answer (rat-kingdom-story-test--call "S-1.1" "query"
                                                '(category . "fact"))))
      (should (cdr answer))
      (should (string-search "unknown tool" (car answer))))
    (should (cdr (rat-kingdom-king-test--call "note_fact" '(fact . "No."))))
    (should-not (rat-kingdom-fact-test--facts space))))

(ert-deftest rat-kingdom-fact-test-reload-keeps-one-brief-function ()
  (rat-kingdom-reload-test--isolated
    (let ((rat-kingdom-story-brief-functions
           (copy-sequence rat-kingdom-story-brief-functions)))
      (should (equal rat-kingdom-story-brief-functions
                     '(rat-kingdom-fact-brief)))
      (rat-kingdom-reload)
      (rat-kingdom-reload)
      (should (equal rat-kingdom-story-brief-functions
                     '(rat-kingdom-fact-brief))))))

(provide 'rat-kingdom-fact-test)
;;; rat-kingdom-fact-test.el ends here
