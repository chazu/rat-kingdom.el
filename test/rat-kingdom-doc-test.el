;;; rat-kingdom-doc-test.el --- Tests for research and docs -*- lexical-binding: t; -*-

;;; Commentary:

;; Batch tests for the research workflow, the researcher's tools, docs
;; in the brief, and the king's doc tools.  They use the fixture of
;; rat-kingdom-story-test.el: real Git, a backend that starts no agent
;; and records prompts, and tools called over JSON-RPC.

;;; Code:

(require 'ert)
(require 'rat-kingdom-test-helper)
(require 'rat-kingdom)
(require 'rat-kingdom-doc)
(require 'rat-kingdom-story-test)
(require 'rat-kingdom-king-test)
(require 'rat-kingdom-task-test)
(require 'rat-kingdom-fact-test)

(defmacro rat-kingdom-doc-test-with-repo (vars &rest body)
  "Run BODY as `rat-kingdom-story-test-with-repo' does, with doc events.
VARS is (SPACE PATH).  Story events also reach rat-kingdom-doc.el's
clean-up, ahead of the king's news, as they do outside tests."
  (declare (indent 1) (debug t))
  `(rat-kingdom-story-test-with-repo ,vars
     (let ((rat-kingdom-story-event-functions
            (cons #'rat-kingdom-doc--story-event
                  rat-kingdom-story-event-functions)))
       ,@body)))

(defun rat-kingdom-doc-test--start (space id &optional task)
  "Start the research story ID in demo in SPACE, and its researcher.
With TASK, the story works on that task."
  (rat-kingdom-story-start space "demo" (format "Research %s" id)
                           (and (not task) "Find out how it works.")
                           id "research" task)
  (rat-kingdom-reaction-run space))

(defun rat-kingdom-doc-test--write (run &rest arguments)
  "Call write_doc as RUN with ARGUMENTS.  Return (TEXT . FAILED)."
  (apply #'rat-kingdom-story-test--call run "write_doc" arguments))

(defun rat-kingdom-doc-test--write-ok (run title body &rest more)
  "Write the doc TITLE with BODY as RUN, and MORE arguments; return its id."
  (let ((answer (apply #'rat-kingdom-doc-test--write run
                       (cons 'title title) (cons 'body body) more)))
    (should-not (cdr answer))
    (should (string-match "doc \\(D-[0-9a-f]\\{4\\}\\)" (car answer)))
    (match-string 1 (car answer))))

(defun rat-kingdom-doc-test--finish (run)
  "Call finish as RUN.  Return (TEXT . FAILED)."
  (rat-kingdom-story-test--call run "finish" '(summary . "Wrote it up.")
                                '(checks . "none run")))

(defun rat-kingdom-doc-test--field (space id key)
  "Return the payload field KEY of the live doc ID in SPACE."
  (plist-get (plist-get (rat-kingdom-doc-get space id) :payload) key))

(defun rat-kingdom-doc-test--king (tool &rest arguments)
  "Call the king's TOOL with ARGUMENTS without starting the king.
Return (TEXT . FAILED)."
  (rat-kingdom-mcp-call '(:run "king" :role king) tool arguments))

(defun rat-kingdom-doc-test--put (space repo title status &optional topic story)
  "Write a doc of REPO in SPACE directly, with TITLE, STATUS and TOPIC.
STORY is the story that wrote it.  Return its id."
  (let ((id (rat-kingdom-doc--new-id space)))
    (rat-kingdom-space-put space 'doc :scope repo :identity id
                           :payload (list :title title :body "Text."
                                          :topic topic :status status
                                          :story (or story "S-9") :run "S-9.1"
                                          :updated 0)
                           :actor "S-9.1")
    id))

;;;; The workflow

(ert-deftest rat-kingdom-doc-test-research-workflow-validates ()
  (let ((workflow (rat-kingdom-workflow-get 'research)))
    (should workflow)
    (should (equal (plist-get workflow :start) "ready"))
    (should (equal (plist-get workflow :final) '("done")))
    (should-not (rat-kingdom-story-merges-p workflow))
    (let ((research (rat-kingdom-workflow-step-named workflow "research"))
          (review (rat-kingdom-workflow-step-named workflow "review")))
      (should (eq (plist-get research :kind) :spawn))
      (should (eq (plist-get research :with) 'researcher))
      (should (equal (plist-get research :to) "review"))
      (should (equal (plist-get review :pass) "done"))
      (should (equal (plist-get review :fix) "ready"))))
  (should-not (rat-kingdom-workflow-validate
               '(:places (ready review done blocked) :start ready :final (done)
                 :steps ((research :from ready :spawn researcher :to review)
                         (review :from review :review king :pass done
                                 :fix ready)))))
  (should (rat-kingdom-story-merges-p (rat-kingdom-workflow-get 'story))))

;;;; The researcher

(ert-deftest rat-kingdom-doc-test-researcher-writes-and-finishes ()
  (rat-kingdom-doc-test-with-repo (space _path)
    (rat-kingdom-doc-test--start space "S-1")
    (let ((run (rat-kingdom-run-get space "S-1.1"))
          (prompt (rat-kingdom-story-test--prompt "S-1.1")))
      ;; The researcher works in a worktree like a rat, with its own
      ;; instructions and tools.
      (should (equal (plist-get run :role) "researcher"))
      (should (file-directory-p (plist-get run :worktree)))
      (should (string-prefix-p rat-kingdom-run-researcher-instructions prompt))
      (should-not (string-search rat-kingdom-run-rat-instructions prompt))
      (should (string-search "Task S-1: Research S-1" prompt))
      (should (equal (sort (rat-kingdom-mcp-tool-names 'researcher) #'string<)
                     '("block" "finish" "inbox" "note_fact" "read_doc"
                       "write_doc")))
      (should (equal (rat-kingdom-agent-shell--buffer-name run)
                     (format "researcher %s-1 (S-1.1)"
                             (plist-get run :name)))))
    (let* ((id (rat-kingdom-doc-test--write-ok
                "S-1.1" "  How the cache\nworks " "# Cache\n\nIt is LRU."
                '(topic . "cache")))
           (doc (rat-kingdom-doc-get space id))
           (payload (plist-get doc :payload)))
      (should (equal (plist-get doc :scope) "demo"))
      (should-not (plist-get doc :owner))
      (should (eq (plist-get doc :modality) 'persistent))
      (should (equal (plist-get payload :title) "How the cache works"))
      (should (equal (plist-get payload :body) "# Cache\n\nIt is LRU."))
      (should (equal (plist-get payload :topic) "cache"))
      (should (equal (plist-get payload :status) "draft"))
      (should (equal (plist-get payload :story) "S-1"))
      (should (equal (plist-get payload :run) "S-1.1"))
      (should (numberp (plist-get payload :updated)))
      (should (equal (rat-kingdom-fact--actor space (plist-get doc :id))
                     "S-1.1"))
      ;; A researcher may record facts too.
      (should-not (cdr (rat-kingdom-story-test--call
                        "S-1.1" "note_fact" '(fact . "The cache is LRU."))))
      ;; It finishes without a commit, and the story waits for review.
      (let ((answer (rat-kingdom-doc-test--finish "S-1.1")))
        (should-not (cdr answer))
        (should (string-search id (car answer))))
      (let ((result (plist-get (rat-kingdom-space-rd
                                space '(result :identity "S-1"))
                               :payload)))
        (should-not (plist-get result :commit))
        (should (equal (plist-get result :docs) (list id)))
        (should (equal (plist-get result :summary) "Wrote it up.")))
      (should (equal (plist-get (rat-kingdom-run-get space "S-1.1") :state)
                     "ready"))
      (rat-kingdom-reaction-run space)
      (should (equal (rat-kingdom-story-test--place space "S-1") "review"))
      (should (equal (rat-kingdom-story-test--get space "S-1" :awaiting)
                     "review"))
      (should-not (rat-kingdom-story-test--get space "S-1" :commit))
      ;; Once reported, it can write no more.
      (should (cdr (rat-kingdom-doc-test--write
                    "S-1.1" '(title . "Late") '(body . "Too late.")))))))

(ert-deftest rat-kingdom-doc-test-finish-needs-a-doc ()
  (rat-kingdom-doc-test-with-repo (space _path)
    (rat-kingdom-doc-test--start space "S-1")
    (let ((answer (rat-kingdom-doc-test--finish "S-1.1")))
      (should (cdr answer))
      (should (string-search "no doc" (car answer))))
    (should-not (rat-kingdom-space-rd space '(result :identity "S-1")))
    (should (equal (plist-get (rat-kingdom-run-get space "S-1.1") :state)
                   "working"))
    ;; A doc of another story does not count.
    (rat-kingdom-doc-test--put space "demo" "Someone else's" "draft" nil "S-9")
    (should (cdr (rat-kingdom-doc-test--finish "S-1.1")))
    (rat-kingdom-reaction-run space)
    (should (equal (rat-kingdom-story-test--place space "S-1") "ready"))
    ;; A rat's finish is unchanged: it still needs a commit.
    (rat-kingdom-story-start space "demo" "Code" "Write code." "S-2")
    (rat-kingdom-reaction-run space)
    (let ((answer (rat-kingdom-story-test--call "S-2.1" "finish"
                                                '(summary . "x")
                                                '(checks . "none"))))
      (should (cdr answer))
      (should (string-search "no commits" (car answer))))))

(ert-deftest rat-kingdom-doc-test-write-doc-refusals ()
  (rat-kingdom-doc-test-with-repo (space _path)
    (rat-kingdom-doc-test--start space "S-1")
    (cl-flet ((refused (needle &rest arguments)
                (let ((answer (apply #'rat-kingdom-doc-test--write "S-1.1"
                                     arguments)))
                  (should (cdr answer))
                  (should (string-search needle (car answer))))))
      (refused "title" '(title . "  ") '(body . "Text."))
      (refused "body" '(title . "Title") '(body . "\n"))
      (let ((rat-kingdom-doc-max-length 10))
        (refused "at most 10" '(title . "Title") '(body . "Eleven chars")))
      (refused "no doc D-0000" '(title . "T") '(body . "B") '(id . "D-0000"))
      (let ((other (rat-kingdom-doc-test--put space "other" "Theirs" "approved")))
        (refused (format "no doc %s in demo" other)
                 '(title . "T") '(body . "B") (cons 'id other))))
    (should-not (rat-kingdom-doc-list space :repo "demo"))
    ;; A rat cannot write docs.
    (rat-kingdom-story-start space "demo" "Code" "Write code." "S-2")
    (rat-kingdom-reaction-run space)
    (let ((answer (rat-kingdom-doc-test--write "S-2.1" '(title . "T")
                                               '(body . "B"))))
      (should (cdr answer))
      (should (string-search "unknown tool" (car answer))))))

;;;; Review

(ert-deftest rat-kingdom-doc-test-pass-approves ()
  (rat-kingdom-doc-test-with-repo (space path)
    (rat-kingdom-king-test--start space)
    (rat-kingdom-doc-test--start space "S-1")
    (let* ((worktree (rat-kingdom-story-test--get space "S-1" :worktree))
           (one (rat-kingdom-doc-test--write-ok "S-1.1" "One" "First doc."))
           (two (rat-kingdom-doc-test--write-ok "S-1.1" "Two" "Second doc."
                                                '(topic . "misc")))
           (other (rat-kingdom-doc-test--put space "demo" "Older" "draft"
                                             nil "S-9")))
      (should-not (cdr (rat-kingdom-doc-test--finish "S-1.1")))
      (rat-kingdom-reaction-run space)
      ;; The king is asked to review, and told of the docs.
      (let ((news (car (last (rat-kingdom-king-test--news space)))))
        (should (string-search "S-1 (Research S-1) is done and waits for your \
review" news))
        (should (string-search one news))
        (should (string-search two news)))
      ;; story_show lists the docs; story_diff gives them in full, with no
      ;; Git diff since the branch has no commits.
      (let ((show (rat-kingdom-king-test--ok "story_show" '(story . "S-1"))))
        (should (string-search (format "  %s: One, draft, 10 characters" one)
                               show))
        (should (string-search (format "  %s: Two (misc), draft, 11 characters"
                                       two)
                               show))
        (should-not (string-search other show)))
      (let ((diff (rat-kingdom-king-test--ok "story_diff" '(story . "S-1"))))
        (should (string-search (format "=== Doc %s: One\nTopic: none\nStatus: \
draft\n\nFirst doc." one)
                               diff))
        (should (string-search "Second doc." diff))
        (should-not (string-search "no commits" diff)))
      (should (string-search
               "its workflow merges nothing"
               (rat-kingdom-king-test--ok "verdict" '(story . "S-1")
                                          '(value . "pass"))))
      (rat-kingdom-reaction-run space)
      ;; The story is done and archived, its drafts approved; the other
      ;; story's draft is not touched.
      (should-not (rat-kingdom-story-get space "S-1"))
      (should (equal (rat-kingdom-doc-test--field space one :status) "approved"))
      (should (equal (rat-kingdom-doc-test--field space two :status) "approved"))
      (should (equal (rat-kingdom-doc-test--field space other :status) "draft"))
      (should (equal (rat-kingdom-doc-test--field space one :body) "First doc."))
      (should (member '(done . "S-1") rat-kingdom-story-test--events))
      ;; Nothing was merged, and the worktree and branch, which had no
      ;; commits of their own, are gone.
      (should-not (rat-kingdom-git-ok-p path "rev-parse" "--verify" "--quiet"
                                        "refs/heads/rats/S-1"))
      (should-not (file-directory-p worktree))
      (let ((news (car (last (rat-kingdom-king-test--news space)))))
        (should (string-search "S-1 (Research S-1) is over." news))
        (should (string-search (format "%s: One, approved" one) news))
        (should (string-search "Its worktree and branch are removed." news)))
      ;; story_show still lists the docs of the archived story.
      (should (string-search
               (format "%s: One, approved" one)
               (rat-kingdom-king-test--ok "story_show" '(story . "S-1"))))
      (should-not (rat-kingdom-reaction-failures space)))))

(ert-deftest rat-kingdom-doc-test-branch-with-commits-is-kept ()
  (rat-kingdom-doc-test-with-repo (space path)
    (rat-kingdom-king-test--start space)
    (rat-kingdom-doc-test--start space "S-1")
    (let ((worktree (rat-kingdom-story-test--get space "S-1" :worktree))
          (id (rat-kingdom-doc-test--write-ok "S-1.1" "One" "First doc.")))
      (rat-kingdom-story-test--commit worktree "notes.txt" "notes\n" "Notes")
      (should-not (cdr (rat-kingdom-doc-test--finish "S-1.1")))
      (rat-kingdom-reaction-run space)
      ;; The diff follows the docs.
      (let ((diff (rat-kingdom-king-test--ok "story_diff" '(story . "S-1"))))
        (should (string-search (format "=== Doc %s" id) diff))
        (should (string-search "notes.txt" diff))
        (should (< (string-search "=== Doc" diff) (string-search "notes.txt" diff))))
      (rat-kingdom-king-test--ok "verdict" '(story . "S-1") '(value . "pass"))
      (rat-kingdom-reaction-run space)
      (should-not (rat-kingdom-story-get space "S-1"))
      (should (file-directory-p worktree))
      (should (rat-kingdom-git-ok-p path "rev-parse" "--verify" "--quiet"
                                    "refs/heads/rats/S-1"))
      ;; Nothing was merged.
      (should-not (rat-kingdom-git-ok-p path "cat-file" "-e"
                                        "rk/integration:notes.txt"))
      (should (string-search
               (format "Its worktree %s and branch rats/S-1 are kept: the \
branch has commits of its own" worktree)
               (car (last (rat-kingdom-king-test--news space))))))))

(ert-deftest rat-kingdom-doc-test-fix-then-revise ()
  (rat-kingdom-doc-test-with-repo (space _path)
    (rat-kingdom-doc-test--start space "S-1")
    (let ((id (rat-kingdom-doc-test--write-ok "S-1.1" "Draft" "Rough."
                                              '(topic . "plan"))))
      (should-not (cdr (rat-kingdom-doc-test--finish "S-1.1")))
      (rat-kingdom-reaction-run space)
      (should (string-search
               "goes back to a worker"
               (car (rat-kingdom-doc-test--king "verdict" '(story . "S-1")
                                                '(value . "fix")
                                                '(notes . "Say more about X.")))))
      (rat-kingdom-reaction-run space)
      ;; The doc stays a draft, and a new researcher is told to revise it.
      (should (equal (rat-kingdom-doc-test--field space id :status) "draft"))
      (should (equal (rat-kingdom-story-test--get space "S-1" :run) "S-1.2"))
      (let ((prompt (rat-kingdom-story-test--prompt "S-1.2")))
        (should (string-prefix-p rat-kingdom-run-researcher-instructions prompt))
        (should (string-search "Say more about X." prompt))
        (should (string-search (format "Your drafts, to revise with \
write_doc:\n%s: Draft (plan)\n" id)
                               prompt))
        (should-not (string-search "Approved docs" prompt)))
      ;; The old researcher can no longer write.
      (should (cdr (rat-kingdom-doc-test--write
                    "S-1.1" '(title . "Old") '(body . "Old.") (cons 'id id))))
      ;; The new one revises the doc by its id; it is replaced whole.
      (should (equal (rat-kingdom-doc-test--write-ok
                      "S-1.2" "Better" "Much more about X." (cons 'id id))
                     id))
      (should (eql (length (rat-kingdom-doc-list space :repo "demo")) 1))
      (should (equal (rat-kingdom-doc-test--field space id :title) "Better"))
      (should (equal (rat-kingdom-doc-test--field space id :body)
                     "Much more about X."))
      (should-not (rat-kingdom-doc-test--field space id :topic))
      (should (equal (rat-kingdom-doc-test--field space id :run) "S-1.2"))
      (should (equal (rat-kingdom-doc-test--field space id :status) "draft"))
      (should-not (cdr (rat-kingdom-doc-test--finish "S-1.2")))
      (rat-kingdom-reaction-run space)
      ;; A story with no commit is reviewed again, not let through.
      (should (equal (rat-kingdom-story-test--get space "S-1" :awaiting)
                     "review"))
      (rat-kingdom-doc-test--king "verdict" '(story . "S-1") '(value . "pass"))
      (rat-kingdom-reaction-run space)
      (should-not (rat-kingdom-story-get space "S-1"))
      (should (equal (rat-kingdom-doc-test--field space id :status)
                     "approved")))))

(ert-deftest rat-kingdom-doc-test-revising-an-approved-doc ()
  (rat-kingdom-doc-test-with-repo (space _path)
    (let ((old (rat-kingdom-doc-test--put space "demo" "Old" "approved")))
      (rat-kingdom-doc-test--start space "S-1")
      (rat-kingdom-doc-test--write-ok "S-1.1" "New" "Newer." (cons 'id old))
      ;; It is a draft of this story now, so finish counts it.
      (should (equal (rat-kingdom-doc-test--field space old :status) "draft"))
      (should (equal (rat-kingdom-doc-test--field space old :story) "S-1"))
      (should-not (cdr (rat-kingdom-doc-test--finish "S-1.1"))))))

(ert-deftest rat-kingdom-doc-test-cancel-leaves-drafts ()
  (rat-kingdom-doc-test-with-repo (space _path)
    (rat-kingdom-doc-test--start space "S-1")
    (let ((id (rat-kingdom-doc-test--write-ok "S-1.1" "Draft" "Rough.")))
      (rat-kingdom-story-cancel space "S-1")
      (should (equal (rat-kingdom-doc-test--field space id :status) "draft"))
      (should (string-search (format "%s [draft] Draft" id)
                             (car (rat-kingdom-doc-test--king
                                   "doc_list" '(repo . "demo"))))))))

(ert-deftest rat-kingdom-doc-test-done-closes-the-task ()
  (rat-kingdom-task-test-with-tracker (space fake)
    (let ((rat-kingdom-story-event-functions
           (cons #'rat-kingdom-doc--story-event
                 rat-kingdom-story-event-functions)))
      (rat-kingdom-task-project space "demo")
      (rat-kingdom-doc-test--start space "S-1" "T-1")
      (should (equal (rat-kingdom-story-test--get space "S-1" :task) "T-1"))
      (rat-kingdom-doc-test--write-ok "S-1.1" "Findings" "What I found.")
      (should-not (cdr (rat-kingdom-doc-test--finish "S-1.1")))
      (rat-kingdom-reaction-run space)
      (rat-kingdom-story-verdict space "S-1" "pass")
      (rat-kingdom-reaction-run space)
      (should-not (rat-kingdom-story-get space "S-1"))
      (rat-kingdom-task-test--drain fake 'close)
      (should (equal (assq 'close (rat-kingdom-task-test-fake-calls fake))
                     '(close "T-1" "Done: the story S-1 reached done in the \
workflow research, which merges nothing")))
      (should-not (assq 'release (rat-kingdom-task-test-fake-calls fake)))
      (should (equal (rat-kingdom-task-test--available space) '("T-2"))))))

(ert-deftest rat-kingdom-doc-test-moved-to-done-by-hand-is-not-complete ()
  (rat-kingdom-task-test-with-tracker (space fake)
    ;; A story whose workflow merges, moved to done by hand, was not
    ;; merged: its task is released, as before.
    (rat-kingdom-task-project space "demo")
    (rat-kingdom-story-start space "demo" "First" nil "S-1" nil "T-1")
    (rat-kingdom-reaction-run space)
    (rat-kingdom-story-move space "S-1" "done")
    (rat-kingdom-reaction-run space)
    (should-not (rat-kingdom-story-get space "S-1"))
    (rat-kingdom-task-test--drain fake 'release)
    (should (member '(release "T-1") (rat-kingdom-task-test-fake-calls fake)))
    (should-not (assq 'close (rat-kingdom-task-test-fake-calls fake)))))

;;;; The brief

(ert-deftest rat-kingdom-doc-test-brief-lists-approved-docs ()
  (rat-kingdom-doc-test-with-repo (space path)
    (rat-kingdom-fact-test--other-repo space path)
    (should (equal rat-kingdom-story-brief-functions
                   '(rat-kingdom-fact-brief rat-kingdom-doc-brief
                     rat-kingdom-message-brief)))
    ;; With no approved docs there is no section.
    (rat-kingdom-doc-test--put space "demo" "A draft" "draft")
    (rat-kingdom-fact-test--start space "S-1")
    (let ((prompt (rat-kingdom-story-test--prompt "S-1.1")))
      (should-not (string-search "Approved docs" prompt))
      (should-not (string-search "Your drafts" prompt)))
    (let ((first (rat-kingdom-doc-test--put space "demo" "First" "approved"
                                            "setup"))
          (second (rat-kingdom-doc-test--put space "demo" "Second" "approved"))
          (_theirs (rat-kingdom-doc-test--put space "other" "Theirs"
                                              "approved")))
      (rat-kingdom-space-out space 'fact :scope "demo"
                             :payload '(:text "A fact.") :actor "S-9.1")
      (rat-kingdom-fact-test--start space "S-2")
      (let ((prompt (rat-kingdom-story-test--prompt "S-2.1"))
            (section (format "Approved docs for this repository (read one \
with read_doc):\n%s: Second\n%s: First (setup)\n" second first)))
        (should (string-search section prompt))
        (should-not (string-search "Theirs" prompt))
        (should-not (string-search "A draft" prompt))
        ;; After the facts.
        (should (< (string-search "A fact." prompt)
                   (string-search "Approved docs" prompt))))
      ;; The caps: by count, and by characters, saying what is left out.
      (let ((rat-kingdom-doc-brief-max-count 1))
        (let ((brief (rat-kingdom-doc-brief
                      space (rat-kingdom-story-get space "S-2") "S-2.1")))
          (should (string-search (format "%s: Second\n" second) brief))
          (should-not (string-search "First" brief))
          (should (string-search "(1 older doc is left out.)" brief))))
      (let ((rat-kingdom-doc-brief-max-chars 5))
        (should (string-search
                 "(2 older docs are left out.)"
                 (rat-kingdom-doc-brief
                  space (rat-kingdom-story-get space "S-2") "S-2.1"))))
      ;; A rat may read an approved doc of its repository, and no other.
      (let ((answer (rat-kingdom-story-test--call "S-2.1" "read_doc"
                                                  (cons 'id first))))
        (should-not (cdr answer))
        (should (equal (car answer)
                       (format "%s: First\nTopic: setup\nStatus: approved\n\n\
Text." first))))
      (let ((theirs (plist-get (car (rat-kingdom-doc-list space :repo "other"))
                               :identity)))
        (let ((answer (rat-kingdom-story-test--call "S-2.1" "read_doc"
                                                    (cons 'id theirs))))
          (should (cdr answer))
          (should (string-search (format "no doc %s in demo" theirs)
                                 (car answer)))))
      (should (cdr (rat-kingdom-story-test--call "S-2.1" "read_doc"
                                                 '(id . "D-0000")))))))

;;;; The king's tools

(ert-deftest rat-kingdom-doc-test-king-doc-tools ()
  (rat-kingdom-doc-test-with-repo (space _path)
    (let ((names (rat-kingdom-mcp-tool-names 'king)))
      (dolist (name '("doc_list" "doc_show" "doc_forget"))
        (should (member name names))
        (should (string-search name (rat-kingdom-king-instructions)))))
    (should (string-search "research" (rat-kingdom-king-instructions)))
    (let ((draft (rat-kingdom-doc-test--put space "demo" "Draft one" "draft"
                                            "notes" "S-3"))
          (approved (rat-kingdom-doc-test--put space "demo" "Approved one"
                                               "approved")))
      ;; doc_list, newest first, optionally by status.
      (let ((all (car (rat-kingdom-doc-test--king "doc_list"
                                                  '(repo . "demo")))))
        (should (string-prefix-p "2 docs in demo, newest first:\n" all))
        (should (string-search (format "%s [draft] Draft one (notes); by S-3, "
                                       draft)
                               all))
        (should (< (string-search approved all) (string-search draft all))))
      (let ((some (car (rat-kingdom-doc-test--king "doc_list" '(repo . "demo")
                                                   '(status . "approved")))))
        (should (string-search approved some))
        (should-not (string-search draft some)))
      (should (cdr (rat-kingdom-doc-test--king "doc_list" '(repo . "demo")
                                               '(status . "final"))))
      (should (cdr (rat-kingdom-doc-test--king "doc_list" '(repo . "nowhere"))))
      ;; doc_show, in full.
      (let ((shown (car (rat-kingdom-doc-test--king "doc_show"
                                                    (cons 'id draft)))))
        (should (string-prefix-p (format "%s in demo: Draft one\nStatus: draft\n\
Topic: notes\nStory: S-3\nRun: S-9.1\n" draft)
                                 shown))
        (should (string-search "Recorded by: S-9.1" shown))
        (should (string-suffix-p "\n\nText." shown)))
      (should (cdr (rat-kingdom-doc-test--king "doc_show" '(id . "D-0000"))))
      ;; doc_forget archives it, and refuses anything else.
      (let ((answer (rat-kingdom-doc-test--king "doc_forget"
                                                (cons 'id approved))))
        (should-not (cdr answer))
        (should (equal (car answer)
                       (format "Forgot doc %s of demo: Approved one" approved))))
      (should-not (rat-kingdom-doc-get space approved))
      (should (cl-find approved (rat-kingdom-space-archived space)
                       :key (lambda (tuple) (plist-get tuple :identity))
                       :test #'equal))
      (should (rat-kingdom-doc--used-p space approved))
      (should (string-search approved
                             (car (rat-kingdom-doc-test--king
                                   "query" '(category . "doc")
                                   '(archived . "true")))))
      (should (cdr (rat-kingdom-doc-test--king "doc_forget"
                                               (cons 'id approved))))
      (rat-kingdom-story-start space "demo" "Code" "Write code." "S-1")
      (let ((answer (rat-kingdom-doc-test--king "doc_forget" '(id . "S-1"))))
        (should (cdr answer))
        (should (string-search "not a doc" (car answer))))
      (should (rat-kingdom-story-get space "S-1"))
      (should (string-search "1 doc in demo"
                             (car (rat-kingdom-doc-test--king
                                   "doc_list" '(repo . "demo"))))))
    (should (equal (car (rat-kingdom-doc-test--king "doc_list" '(repo . "demo")
                                                    '(status . "approved")))
                   "demo has no approved docs."))))

(ert-deftest rat-kingdom-doc-test-story-start-takes-research ()
  (rat-kingdom-doc-test-with-repo (space _path)
    (let ((answer (rat-kingdom-doc-test--king
                   "story_start" '(repo . "demo") '(title . "Look into it")
                   '(description . "Find out.") '(workflow . "research"))))
      (should-not (cdr answer))
      (should (string-search "with the workflow research" (car answer))))
    (let ((story (car (rat-kingdom-story-list space "demo"))))
      (should (equal (plist-get (plist-get story :payload) :workflow)
                     "research")))))

(provide 'rat-kingdom-doc-test)
;;; rat-kingdom-doc-test.el ends here
