# rat-kingdom design

Status: draft, 2026-11-12. Section 15 says what is built.

rat-kingdom is an Emacs-native swarm orchestrator. It descends from imp
(`~/.imp`), rk2 (`~/dev/go/rk2`) and procyon-park, and runs on the
existing Emacs agent tooling: agent-shell, deathless, a2ui and the in-Emacs
MCP endpoint.

## 1. Goals

- Keep the loop that made imp work: a research agent writes a design doc,
  the user and the king revise it, the king turns it into an epic, and
  waves of well-scoped stories go to workers.
- Keep the king free to talk. The king is a long-lived agent with context.
  It does judgment; it does no chores.
- Use a tuplespace for generative communication, with pattern matching
  doing real work, not as a mailbox.
- Workflows are customizable per repo and per epic, with mixins and
  aspects, and the king can configure them.
- Work continues while the user is away, and survives a restart or crash of
  Emacs by resuming interrupted runs.
- Ambient agents start from events: timers, webhooks, stream messages.

## 2. Non-goals

- No LLM agent for deterministic work. There is no steward.
- No multi-machine sync of the space.
- No supervisor outside Emacs in the first version. It is added only if
  Emacs performance suffers (section 14).
- No sandbox. Guards are operational, as in rk2.
- Nothing pushes unless the user asks for a specific push.

## 3. Lessons carried over

| Source | Keep | Drop |
|---|---|---|
| imp | research → doc → epic → waves; long-lived king; foreman where an epic needs judgment; mixins and aspects in workflows | steward; agents scanning the space; prompts that teach claiming; tmux scraping; analytics tiers, hub, sync |
| rk2 | distinct states (working, ready, blocked, integrated, exited); integration in a candidate worktree with a check and compare-and-swap; integration's result reported apart from the worker's claim; preserve work on every failure; durable message delivery; explicit publish | file locks and claim races (one writer now); shell-command parsing as the main guard |
| procyon-park | Petri-net workflows over tuples; linear, persistent and affine tuples | derived story state (stories got stuck); no archiving (the UI filled up) |

## 4. Architecture

```
            user
             │
   ┌─────────┴──────────────────────────── Emacs ───────────────────────┐
   │  king (agent-shell)      dashboard (deathless + rat-kingdom views)         │
   │        │ tools                    ▲                                │
   │        ▼                          │ change hooks                   │
   │  ┌───────────┐   match    ┌───────┴──────┐   spawn   ┌───────────┐ │
   │  │ MCP tools │──out/in──▶ │  tuplespace  │◀─────────▶│ reactions │ │
   │  │ per role  │            │  (SQLite)    │           │ workflows │ │
   │  └───────────┘            └───────▲──────┘           └─────┬─────┘ │
   │        ▲                          │                        │       │
   │  workers (agent-shell, one worktree each)◀──────────────────┘       │
   └───────────────────────────────────┼────────────────────────────────┘
                                       │ same SQLite file
                         ingress sidecar (ganso: cron, streams, webhooks)
```

Emacs is the orchestrator and the only process that runs reactions. All
durable state is in one SQLite file, so nothing that matters lives only in
Emacs memory. Git operations and checks run as asynchronous subprocesses;
no reaction blocks the UI.

## 5. The tuplespace

### 5.1 Shape

A tuple keeps imp's four parts plus bookkeeping:

| Field | Meaning |
|---|---|
| `category` | the kind of tuple, from a fixed vocabulary (5.4) |
| `scope` | repo name, or `system` |
| `identity` | the thing it is about: a story, task, run or path |
| `payload` | a property list, stored as JSON |
| `modality` | `linear`, `persistent` or `affine` |
| `owner` | the story or epic whose lifetime it shares, or none |
| `expires` | for affine tuples |

### 5.2 Operations

- `out` writes a tuple.
- `in` removes and returns one match. Only one taker succeeds.
- `rd` returns one match without removing it.
- `scan` returns all matches.

A pattern fixes some fields and binds others: `(result :scope $repo
:identity $story :commit $c)`. Matching on category, scope and identity
uses indexes; payload fields are matched after. Variables start with `$`
because the Emacs reader takes `?x` for a character.

Blocking reads are not offered to agents. Inside Emacs a blocked read is a
reaction (section 6).

### 5.3 Modalities and lifetime

- **Linear**: consumed exactly once. Story tokens, claims, review requests.
- **Persistent**: stays until its owner ends. Facts, policy, docs, results.
- **Affine**: consumed at most once, else expires. Events, ticks, notices.

Every tuple written during a story is owned by that story, and by its epic
if it has one. When a story's token reaches a terminal place, its owned
tuples move to an archive table in the same transaction. The live space
holds only work in flight. Facts worth keeping past a story are written
with no owner, scoped to the repo, so no sweep takes them; the king
removes a wrong one with `fact_forget`, which retracts it. Docs are kept
the same way, and removed with `doc_forget` (section 9).

Each `out` and `in` is also appended to an operations log table. That log
is the audit trail and can be replayed.

### 5.4 Vocabulary (first cut)

| Category | Modality | Written by | Meaning |
|---|---|---|---|
| `story` | linear | engine | the token: `(story S :at PLACE :workflow W :task T)`, with `:target` if it has a target of its own; a child story (7.1) has `:parent` instead of `:task` and `:epic` |
| `available` | linear | task adapter | a ready task with no story yet |
| `run` | persistent | engine | a live or stopped agent run and its state |
| `result` | persistent | worker `finish` | commit, summary, reported checks |
| `blocked` | persistent | worker `block` | why the worker stopped |
| `checked` | persistent | engine | what the engine itself verified, for a story, or for an epic's landing (named by the epic) |
| `setup` | persistent | engine | how a new worktree's setup command came out |
| `review` | linear | engine | a request for the king or user to judge |
| `verdict` | linear | king or user | `pass` or `fix` with notes |
| `message` | linear | engine, king `tell` | text for the king, or for a story's working run, delivered at a turn boundary |
| `doc` | persistent | researcher `write_doc` | a design or research document, scoped to the repo, named `D-` and four hex digits, with no owner: `:title :body :topic :status :story :run`, `:status` `draft` or `approved` (7.1) |
| `signal` | linear | king `story_signal` | opens a story's `:gate (:signal NAME)`: scoped to the story's repo, named and owned by the story, `:name NAME`; taken when the gate opens (7.1) |
| `ran` | persistent | engine | how a `:run` step's commands came out, named by the story (7.1) |
| `fact` | persistent | workers | something learned about the repo |
| `policy` | persistent | king `config_set` | an epic or task override of configuration (7.3), scoped to the repo, named and owned by the epic or task, its payload the keys that layer allows; replaced whole |
| `event` | affine | ingress, engine | something happened outside or inside |
| `stuck` | persistent | watchdog | a token that cannot move |
| `repo` | persistent | user | a registered repository: path, target branch, check, setup |
| `published` | persistent | king `publish`, user | a push receipt: repo (scope), branch, remote and URL, old and new remote commit, actor, time |
| `epic` | persistent | king's epic tools, engine | a running epic, scoped to its repo and named by its br id: `:state` (`running`, `paused`, `landing`, `done`, `cancelled`), `:title`, `:max-parallel`, `:held` (tasks not to be restarted by themselves, with reasons), `:merged`, `:started`, `:finished`; with a feature branch also `:branch`, `:target`, `:landing` (`check`, `review` or `fix`), `:fix-task`, `:candidate`, the checked `:commit`, `:base` and `:head`, `:reviewed` and `:landed`; always replaced whole, in one transaction |

### 5.5 The rule: agents write, rules read

Agents emit a few typed tuples through tools. They do not scan the space
and are not taught how to claim. Reactions do the matching. What an agent
needs to know is assembled for it by query when it starts (section 8.3).
The king is the exception: it has a `query` tool.

## 6. Reactions

A reaction is a standing set of patterns with an elisp body. When tuples
matching all of its patterns are in the space, the body runs with the
patterns' variables bound.

```elisp
(rat-kingdom-defreaction integrate-on-pass
  "Move a story on once its review passes."
  :take (verdict :scope $repo :identity $story :value pass)
  :read (story :identity $story :at review)
  (rat-kingdom-story-move $story 'integrating))
```

- `:take` patterns consume what they match; `:read` patterns only require
  it. Each takes one pattern or several. A variable shared between
  patterns joins them, as the inputs of a Petri-net transition are joined.
- **A firing is one transaction.** The tuples are taken, the body runs, and
  what the body writes commits with the take. Nobody sees a half-done
  transition.
- **A failed body changes nothing.** The transaction rolls back, the tuples
  stay, and the failure is recorded. Those tuples do not fire that
  reaction again until someone retries it. Failures are listed for the
  dashboard.
- **Reactions fire on what is in the space, not on the act of writing.**
  The space records which tuples each read-only reaction has fired on, so
  each fires once per match. After a crash, a reaction fires on exactly
  the tuples it had not handled.
- A replaced tuple is a new tuple. Updating a run's state with `put` lets
  reactions on that state fire again.
- Reactions are elisp, written by the user, global or per repo.
- A body must not block. Long work is a subprocess whose exit writes a
  tuple.
- A write schedules a run for when Emacs is next idle; the writer is not
  held up. One run follows the whole chain of consequences, and stops
  with a warning after 1000 firings.
- Tuples written by another process are noticed by polling SQLite's data
  version every two seconds. The same poll archives expired tuples.

A new role is a new pattern. Adding one changes no existing prompt.

## 7. Workflows

### 7.1 Model

A workflow is data. A fixed engine reads it each time it moves a token, so
a changed workflow applies from the next move. Each story has exactly one
token, and the token's place is the story's state.

**Built** (`rat-kingdom-workflow.el`, `rat-kingdom-story.el`), in a first
form that differs from the sketch below in three ways. The engine is a
fixed set of reactions that interpret the workflow, not reactions compiled
from it: one begins the step of a token that has arrived at a place, and
the others each join a waiting token with the tuple that ends its step.
The step kinds are `:spawn`, `:check`, `:review`, `:merge`, `:run`,
`:gate` and `:workflow`, each with named outcomes that lead to places;
an outcome left out leads to the workflow's failure place. The built-in
workflows are `story`, `story-lite` and `research`.

```elisp
(rat-kingdom-workflow-define 'story
  :places '(ready checking review integrating done blocked)
  :start 'ready
  :final '(done)
  :steps '((implement :from ready :spawn rat :to checking)
           (check :from checking :check t :pass review :fail ready)
           (review :from review :review king :pass integrating :fix ready)
           (integrate :from integrating :merge t :to done :stale checking)))
```

A failed check, a merge conflict and a review that asks for changes all
lead back to `ready`, where a new worker is started in the same worktree
with the reason. A story is given at most five workers before it is
parked. A target branch that moved after the check leads back to
`checking`; a commit that was already reviewed is not reviewed again.
Workers are capped; the rest queue (section 7.2).

**Built: workflow composition**, step 8 of the build order (section 15),
all of it as the rest of this section describes. The step kinds `:run`,
`:gate` and `:workflow` (child stories, below), `:check (NAME ...)` and
`:brief` on a spawn step, with the shape of every kind's value validated,
are in `rat-kingdom-workflow.el` and `rat-kingdom-story.el`. Mixins and
aspects, with `:entry`, the built-in mixins `no-review` and `tdd`, mixin
files, the `:mixins` key (7.3) and the expansions `workflow_list` shows
are in `rat-kingdom-workflow.el` and `rat-kingdom-config.el`. The
`research` workflow, the `researcher` role, docs, docs in every worker's
brief (8.3) and the doc tools (9) are in `rat-kingdom-doc.el`. The
king's `story_signal`, and `repo_add`'s `mixins` and `git` arguments,
are in `rat-kingdom-king.el`. The paragraphs marked **Built** below give
the details of each part.

The starting workflows are `story`, `story-lite` (no review) and
`research` (writes docs, no code; below). **Epics are not a workflow.**
An epic is a collection of stories, dispatched by reactions on the `epic`
tuple (section 10). Each of its stories runs whatever workflow it is
given.

A workflow file that uses most of what follows:

```elisp
(:name careful
 :doc "As story, test first, with the code formatted before the check."
 :places (ready checking review integrating done blocked)
 :start ready
 :final (done)
 :steps ((implement :from ready :spawn rat :to checking)
         (check :from checking :check (lint test) :pass review :fail ready)
         (review :from review :review king :pass integrating :fix ready)
         (integrate :from integrating :merge t :to done :stale checking))
 :mixins (tdd)
 :aspects ((:around check :timeout 900)
           (:after implement :run (format))))
```

**Step kinds.** A step has exactly one kind, a name, `:from`, and
optionally `:timeout` and `:attempts`. The first outcome of each kind must
be given a place; the others lead to the failure place unless given one.
`rat-kingdom-workflow-kinds` has a row for each kind.

| Kind | Value | Outcomes | What it does |
|---|---|---|---|
| `:spawn` | a role, `rat` or `researcher` | `:to`, `:blocked` | starts a worker, as built; may have `:brief` |
| `:check` | `t`, or a list of command names | `:pass`, `:fail` | merges in a candidate and runs a check, as built |
| `:review` | `king` or `user` | `:pass`, `:fix` | waits for a verdict, as built |
| `:merge` | `t` | `:to`, `:stale` | moves the target, as built; how it integrates is `:git :integrate` (7.3) |
| `:run` | a list of command names | `:pass`, `:fail` | runs commands in the story's worktree and commits what they change |
| `:gate` | `(:after SECONDS)` or `(:signal NAME)` | `:to` | waits, with no process |
| `:workflow` | a workflow name | `:to`, `:fail` | runs a child story |

The normalized step keeps the kind's value as `:with`, as now, and
`:brief` when it has one. `rat-kingdom-workflow-validate` checks each
value's shape as below; a value of the wrong shape makes the workflow
invalid.

- **`:spawn ROLE`** takes an optional `:brief STRING`: extra instructions
  for this step's worker. They go in its prompt after the task's
  description, under the line "For this step (STEP):". This is how a step
  such as `tests` says "write failing tests first". `:brief` on a step of
  another kind, or a ROLE other than `rat` or `researcher`, makes the
  workflow invalid.
- **`:check t`** keeps today's meaning: the configured setup, then the
  configured check (7.3). **`:check (NAME ...)`**, a non-empty list of
  symbols, runs those commands from the merged `:commands` for the
  story's repository, epic and task, in that order, in place of the
  configured `:check`. The configured setup still runs first. A name that
  `:commands` does not define makes the step fail to begin, with the
  reason (7.2): "Step check could not be begun: lint is not a command;
  the commands are …". The `checked` tuple records `:names` and the
  failing command, as now.
- **`:run (NAME ...)`**, a non-empty list of symbols, outcomes `:pass`
  (required) and `:fail`. The names are resolved as for `:check (NAME
  ...)`, and an unknown one fails the step's beginning in the same way.
  1. The worktree must be clean (`git status --porcelain` shows nothing)
     and its `HEAD` must be the token's `:commit`. Otherwise the step fails
     to begin, naming the files or the two commits. The setup is not run
     again.
  2. The commands run in the story's own worktree, not in a candidate, one
     after another, as processes without a shell, stopping at the first
     that fails. They are the story's process, as a check is: one at a
     time, killed when the story is moved or cancelled, and run again by
     reconciling (8.4) if Emacs stopped while they ran. The story waits
     for "run". Its limit is the step's `:timeout`, else the
     configuration's `:timeouts :check`.
  3. If a command fails, the outcome is `:fail`, with the reason "run
     failed: the command NAME (ARGV) exited with N. The end of its
     output: …". That is what the next worker is told if `:fail` leads
     back to one.
  4. If all succeed and the worktree is changed, the engine commits every
     change on the story's branch (`git add -A`, then `git commit
     --no-verify -m "rat-kingdom: run NAMES"`, NAMES the names joined by
     spaces) and records the new commit as the token's `:commit`. The
     outcome is `:pass`. If nothing changed, it is `:pass` with `:commit`
     as it was. A commit that fails is `:fail`, with Git's message.
  5. The outcome is a persistent `ran` tuple named by the story (5.4):
     `:value` (`pass` or `fail`), `:names`, `:command` and `:argv` (the
     command that failed, or the last that ran), `:exit`, `:output` and
     `:commit`. A reaction joins it with the waiting token, as the
     `checked` one does. The story's earlier `ran` tuple is retracted when
     the step begins, so an old outcome never ends a new run.

  This is the step an aspect such as `(:after implement :run (format))`
  inserts.
- **`:gate SPEC`**, outcome `:to` (required). It waits without any
  process and holds no worker. The story waits for "gate". SPEC is one
  of:
  - `(:after SECONDS)`, SECONDS a positive number. When the step begins,
    the time it opens (now, as `rat-kingdom-space-now-function` gives it,
    plus SECONDS) is stored on the token as `:until`, so it survives a
    restart. `rat-kingdom-story-open-gates` moves on by `:to`, each in its
    own transaction, every token that waits for "gate" and whose `:until`
    has passed. A timer set when the step begins calls it, and so do the
    watchdog, once a minute, and reconciling. A gate entered again after
    a loop gets a new `:until`.
  - `(:signal NAME)`, NAME a symbol or string, kept on the token as a
    string under `:signal`. The gate opens when a `signal` tuple (5.4)
    with the story's scope and identity and `:name NAME` is in the space:
    a reaction takes both the token and the signal and moves the token on
    by `:to`. So a signal written before the gate began opens it as soon
    as it begins. The king's `story_signal` (section 9) writes signals.

  A gate has no default timeout, like a review. A step `:timeout` makes
  the watchdog report it stuck once that has passed.
- **`:workflow NAME`**, outcomes `:to` (required) and `:fail`. NAME is a
  symbol or string. It starts a child story (below) and waits for it.
  Whether a workflow of that name exists is checked when the step begins.

**Child stories.** A `:workflow` step starts a child story that runs
workflow NAME in the parent's worktree, on its branch, from its commit.

- The child's id is PARENT/STEP, for example `S-1a2b/lint`. If that id
  was used before, because the step runs again after a loop, it is
  `S-1a2b/lint-2`, then `-3`. Where an id names a file, `/` is written
  `+`: the child's candidate is `candidates/REPO/S-1a2b+lint`, never a
  directory inside its parent's candidate.
- Its token is a story token in the parent's repository, owned by itself,
  at its workflow's start, with `:attempt 0`, the parent's `:agent`, the
  title "TITLE (STEP)" and the parent's description. It takes from the
  parent `:worktree`, `:branch`, `:commit`, `:head` and `:base`, and the
  parent's target (`rat-kingdom-story-target`) as its `:target`. It has
  `:parent`, the parent's id, and `:depth`, one more than the parent's (a
  story with no parent has depth 0).
- The parent's epic and task are on the child as `:config-epic` and
  `:config-task`, not as `:epic` and `:task`. `rat-kingdom-story-config`
  reads them for a token that has them, so the child's configuration,
  and with it its `:commands`, `:check` and `:mixins`, is the parent's.
  Because the child has no `:task` or `:epic`, it never claims, closes or
  releases the parent's task, and its epic neither counts it nor records
  it. News of a child is routed by its `:config-epic` as its parent's
  is by `:epic` (8.2), so an epic's foreman hears of it.
- Its spawn steps find the worktree and branch already there, so no setup
  runs, and each worker is told of the earlier work. It has its own count
  of workers.
- A NAME that is not a workflow, or whose expansion fails, makes the
  parent's step fail to begin. A child's workflow may have a `:merge`
  step: it moves the target as any story's does, but leaves the shared
  worktree and branch, and the parent takes its `:integrated`. A parent
  that ends with `:integrated` taken from a child has its worktree and
  branch removed then, as its own merge would have.
- A child is never complete (`rat-kingdom-story-complete-p`): its end
  closes no task, and a child whose workflow merges nothing does not
  remove the worktree as a research story's end does.
- **Limits.** Before the child starts, the engine follows the `:workflow`
  steps of NAME's expansion, and of theirs in turn, for the story's
  configuration. The step fails to begin if that would make a story
  deeper than 4, or would reach NAME again, or the workflow of the story
  or of any of its ancestors: "the workflow lint would contain itself".
- The parent waits in its step for "child", with the child's id as
  `:child`. It holds no worker.
- When the child reaches a final place, it is archived as any story is,
  and in the same transaction the parent takes the child's `:commit`,
  `:head`, `:base`, `:summary`, `:integrated`, `:integrate` and
  `:reviewed` (each one the child has; one it lacks stays as the parent
  had it) and leaves by `:to`. Either way the parent takes the child's
  `:worktree` and `:branch` if it had none, as when the child's spawn step
  made the worktree, where the parent's own would be. The child's
  candidate is removed.
- When the child reaches its failure place, or is parked anywhere else,
  it is archived, and in the same transaction the parent leaves by `:fail`
  with the child's reason: "The child S-1a2b/lint stopped at blocked:
  REASON". The worktree is left as it is.
- Moving or cancelling the parent cancels the child first, as
  `story_cancel` would; the worktree and branch are the parent's and are
  kept. Cancelling the child alone sends the parent on by `:fail`, with
  "The child S-1a2b/lint was cancelled". The child can be moved, told and
  signalled by its own id, as any story.
- `status` shows the child on its own line, indented under its parent's,
  and `story_show` of either names the other.
- The watchdog reports as stuck a parent that waits for "child" when the
  child's token is gone, and reconciling (8.4) sends such a parent on by
  `:fail`: "The child S-1a2b/lint is gone".

**Built** (`rat-kingdom-story.el`, `rat-kingdom-king.el`): child stories
as above. A child that is parked is not news: its parent's step says
why. `rat-kingdom-story-children` gives a story's children in progress,
and the parent's token keeps `:children`, the ids of every child it
started, which `story_show` lists.

**Mixins and aspects.**

- **Where they appear.** A workflow, built in or in a file, may have
  `:mixins (NAME ...)` and `:aspects (ASPECT ...)`.
  `rat-kingdom-workflow-define` takes both keys, and so does a workflow
  file (`rat-kingdom-config-workflow-keys`).
- **Order of application.** The workflow's own mixins are applied in
  order, then the mixins of the configuration's `:mixins` for the story
  (7.3), in order, then the workflow's own aspects, in order. A mixin
  named twice is applied once, where it first appears. Expansion works on
  the workflow with every step's outcomes written out, defaults included.
  The result is validated as a whole by `rat-kingdom-workflow-validate`,
  then normalized.
- **When expansion happens.** At lookup, so a change to a workflow, a
  mixin or `:mixins` applies from a token's next move, as for workflows
  today. `rat-kingdom-config-workflow` takes the story's epic and task as
  well as its repository, to read `:mixins`, and `rat-kingdom-story--workflow`
  passes the token's. A token whose step is no longer in the expansion
  gets the existing error, "Its workflow no longer has the step STEP".
- **An expansion that fails**, because a mixin is not defined, an aspect
  has the wrong shape, or the validator refuses the result, is to the
  engine a workflow that is not defined (7.3), except that the reason the
  token and the watchdog give says what is wrong: "The workflow story
  cannot be built: there is no mixin called tdd2". A workflow file whose
  own mixins and aspects do not expand, with the mixins its own directory
  can see, is ignored with the error shown, as any invalid file is.

**What a mixin is.** A named property list, applied in the order of its
keys here:

| Key | Value |
|---|---|
| `:doc` | a string |
| `:remove` | a list of step names, `(STEP ...)` |
| `:places` | a list of extra places |
| `:steps` | a list of extra steps, written as in a workflow |
| `:aspects` | a list of aspects |

Its removals come first, then its places and steps are added after the
workflow's, then its aspects are applied. A place or step it adds whose
name is taken makes the expansion fail.

**Removing a step.** The engine drops the step and its place, and sends
every outcome that led to that place to where the removed step's first
outcome led. If the place was the start, that place becomes the start.
Removing `review` from `story` gives exactly `story-lite`'s routing:
`check :pass` then leads to `integrating`. A step the workflow does not
have is skipped, so a mixin such as `no-review` can apply to any
workflow. A first outcome that led back to the removed place makes the
expansion fail.

**Aspect forms.** STEP-BODY is a step's property list without `:from` or
a name: `(:run (format))`, `(:spawn rat :brief "…")`. It has exactly one
kind. It may name its other outcomes, but not its first, which the aspect
places. A `:before` body may also have `:entry` (below).

- **`(:before MATCH STEP-BODY)`** adds a place and a step, both named
  `before-STEP`, STEP the matched step's name. Its STEP-BODY may include
  `:entry ENTRY`, which says which ways into the matched place the new
  step catches. ENTRY is `all` or `start`, and `all` is the default.
  - With `:entry all`, every outcome that led to the matched step's place
    now reaches the new place, and so does the start if it was the
    matched place.
  - With `:entry start`, only the workflow's start is redirected to the
    new place, and only when the matched place is the start. Every
    outcome that led to the matched place still leads there directly. If
    the matched place is not the start, the aspect adds nothing for that
    match and is skipped, as a MATCH that matches nothing is.

  In both cases the new step's first outcome leads to the matched place.
  `:entry` is removed from the body before the step is made. It is
  invalid on `:after`, on `:around`, and with any value other than `all`
  or `start`; an aspect with an invalid `:entry` has the wrong shape, so
  the expansion fails, or the mixin file is invalid.
- **`(:after MATCH STEP-BODY)`** adds a place and a step named `after-STEP`
  on the matched step's first outcome: that outcome now leads to the new
  place, and the new step's first outcome leads to where it used to go.
- In both cases the new step's other outcomes go to the failure place
  unless the body names them.
- **`(:around MATCH PROPS)`** sets `:timeout`, `:attempts` or `:brief`, the
  keys PROPS may have, on each matched step, replacing what it had.
  `:brief` is set only on matched `:spawn` steps and skipped on the rest.
- **MATCH** is a step name (a symbol), a kind keyword such as `:check`
  (every step of that kind), or `t` (every step). It is matched against
  the workflow as it is when the aspect is applied. A MATCH that matches
  nothing is skipped.
- Steps that an aspect adds are never matched by another aspect.
- **Names.** If `before-STEP` or `after-STEP` is already the name of a
  place or a step, it gets a suffix, `-2`, `-3` and so on, the first that
  is free. So when a step is matched more than once, by two aspects, the
  second step is `after-check-2`.

By default every way into a matched place passes through a `:before`
step. `tdd` uses `:entry start` so that its tests worker runs once, at
the beginning: a failed check or a review that asks for changes leads
straight back to `implement`, not through `before-implement`.

**Built-in mixins**, defined with `rat-kingdom-workflow-define-mixin`,
which validates a mixin's shape as a mixin file is validated:

```elisp
(rat-kingdom-workflow-define-mixin 'no-review
  :doc "No review: work whose check passes is merged."
  :remove '(review))

(rat-kingdom-workflow-define-mixin 'tdd
  :doc "A worker writes failing tests before another implements the task."
  :aspects '((:before implement :entry start :spawn rat
              :brief "Write failing tests for the task and commit them; \
do not implement it.")))
```

`tdd`'s step is `before-implement`, and its place becomes the start
when `implement`'s place is the start, as in `story`. Its first outcome,
`:to`, leads to `implement`'s place, and its `:blocked` to the failure
place. Every other way into `implement`'s place is unchanged. In a
workflow whose start is not `implement`'s place, `tdd` adds nothing.

**Mixin files.** Mixins can also be files:
`~/.emacs.d/rat-kingdom/mixins/NAME.eld` (`mixins` in
`rat-kingdom-directory`) for every repository, and
`<repo>/.rk/mixins/NAME.eld` for one. The file's name, less `.eld`, is the
mixin's name. It holds one property list of the keys above, read with
`read` and never evaluated, and checked for shape when it is read: each
key's value as above, each aspect one of the forms, each MATCH and
STEP-BODY as described. They are looked up as workflow files are: the
repository's file, then the global file, then the built-in mixin. They
are read again when they change, and an invalid file is ignored with its
error shown in `status`. `rat-kingdom-config-mixins` returns a
repository's view, each mixin with its origin and file, and
`rat-kingdom-config-mixin` resolves one name for a repository.

**Showing expansions.** `workflow_list` shows each workflow expanded,
with a line saying what it was built from: its own mixins, the mixins
`:mixins` adds for the view (the repository's, or the global layer's
without one) and the layer they come from, and its aspects as written.
The mixins of the view follow the workflows, each with its origin. A
story's workflow can differ from that view by an epic's or task's
`:mixins`; `story_show` names the mixins its workflow was expanded with.
`config_show` shows `:mixins` with its layer, as any key.

**Built** (`rat-kingdom-workflow.el`, `rat-kingdom-config.el`): mixins
and aspects as above. `rat-kingdom-workflow-expand` is the expansion, a
pure function of the workflow as written, the configured mixins and a
function that resolves a mixin's name; the expanded workflow keeps
`:mixins` and `:aspects` as written and adds `:extra-mixins`, the
configured ones. `rat-kingdom-config-build-workflow` resolves and
expands a workflow for a repository, epic and task, signalling why it
cannot be built; `rat-kingdom-config-workflow` returns nil instead, and
`rat-kingdom-config-workflow-problem` gives the reason, which a story's
token and the watchdog show. `rat-kingdom-config-workflows` still
returns the workflows as written. `repo_add` takes `mixins`.

**Research and docs.** Docs live in the space (open question 4, section
16).

**Built** (`rat-kingdom-doc.el`), as below, with these details. A pass
approves the story's drafts through `rat-kingdom-story-verdict-functions`,
called by the engine inside the transaction that moves the story on.
`story_show` and `story_diff` show docs through
`rat-kingdom-king-show-functions`, for archived stories too. A story is
complete (`rat-kingdom-story-complete-p`) when it was merged or reached a
final place of a workflow with no `:merge` step; the task of a complete
story is closed and an epic counts it as merged. `doc_forget` moves the
doc to the archive (`rat-kingdom-space-archive`, reason `forget`) rather
than retracting it, so `query` with `archived` still finds it and its id
is never reused.

- **The `research` workflow** is built in:

  ```elisp
  (rat-kingdom-workflow-define 'research
    :doc "A researcher writes docs and the king reviews them. No code is merged."
    :places '(ready review done blocked)
    :start 'ready
    :final '(done)
    :steps '((research :from ready :spawn researcher :to review)
             (review :from review :review king :pass done :fix ready)))
  ```

  It has no check and no merge.
- **The `researcher` role** works in a story worktree like a rat: the
  same worktree, branch, setup and worker limit. Its job is to write
  documents, not to commit code. Its instructions are
  `rat-kingdom-run-researcher-instructions`, and its tools are listed in
  section 9: `write_doc`, `read_doc`, `note_fact`, `inbox`, `block` and
  `finish`.
- **A doc** is a persistent `doc` tuple (5.4) scoped to the repo, with no
  owner, so it outlives the story. Its identity is `D-` and four hex
  digits, unused in the live space and the archive. Its payload is
  `:title :body :topic :status :story :run`; `:status` is `draft` or
  `approved`, and `:story` and `:run` are the story and run that last
  wrote it.
- **`finish` for a researcher** takes a summary, and optionally the
  checks it ran. It needs at least one doc whose `:story` is this story,
  and refuses otherwise. It needs no commit and does not look at the
  worktree. Its `result` has `:commit` nil and `:docs`, the ids of the
  story's docs.
- **What the king sees.** For a story with docs, `story_show` lists them
  (id, title, topic, status, length), and `story_diff` gives each one's
  text in full, followed by the Git diff if the branch has commits of its
  own.
- **Verdicts.** A pass, on any story, sets `:status approved` on every
  draft whose `:story` is the story, replacing each doc in the
  transaction that moves the story on. A fix sends the story back to a new
  researcher with the notes, and the docs stay drafts for it to revise:
  its brief lists them (8.3). A story with no commit is never let through
  a review as already reviewed.
- **When a research story ends.** At a final place, a story whose workflow
  has no `:merge` step has its worktree removed and its branch deleted,
  unless the branch has commits of its own; then both are kept and the
  king's news says so. A cancelled research story leaves its drafts as
  they are, for the king to `doc_forget`.

### 7.2 Not getting stuck

- State is one token, never derived from several tuples.
- A step that cannot be begun sends the token to the failure place with
  the reason. An error never leaves a token half moved or waiting on a
  failed reaction.
- Steps have timeouts: by default two hours for a worker and thirty
  minutes for a check, and none for a review. A repository's setup in a
  new worker worktree has the check's limit; in a candidate it is part of
  the check and shares its time.
- A setup runs as a process, like a check, and never blocks Emacs. While
  it runs its story waits for "setup" and holds a worker place, so the
  worker that follows cannot go over the limit. A setup that fails parks
  the story at the failure place with the command, its exit and the end
  of its output; that uses none of the story's workers. Moving or
  cancelling the story kills it.
- At most `rat-kingdom-story-max-workers` workers (three by default) run
  at once. A story whose worker would go over waits in its step for "a
  free worker", with no worktree, run or attempt, and its step's time
  starts only when the worker does. The queue is served oldest first by a
  reaction on every change to a run, when a story is archived, by the
  watchdog and by reconciling, so it cannot wait while a worker is free.
- A watchdog, once a minute, writes `stuck` for a token whose step has run
  past its time, whose check or setup is not running, whose worker's
  record is gone, or which no reaction has picked up. The king is told.
- The user or king can move any token to any place by hand. Its worker is
  stopped, a running check is abandoned, and no file is touched. Each move
  is logged with who made it.
- A story can be cancelled: it is archived, and its worktree and branch
  are kept.

All of this is built.

**Built** (7.1): a story waiting in a `:run` step has a process, as a
check does, and the watchdog reports it stuck if that is not running or
has run past the check's limit. A story waiting at a gate, or a parent
waiting for its child, has no process and holds no worker; it is stuck
only past its step's own `:timeout`, or, for a parent, when its child is
gone.

### 7.3 Configuration layers

Configuration says, per repository and, where it matters, per epic and
task: which workflow a story runs, the target branch, the commands for
setup and check, which agent runs each role, the time limits and
attempts, the worker limit, and whether rat-kingdom's directories are
kept in Git. This section is the spec for step 7 of the build order
(section 15), which is built. The keys `:mixins` and `:git` (below) are
step 8, and both are built.

**Format.** A configuration file is one Emacs Lisp property list, read
with `read` and never evaluated. Its extension is `.eld`. Anything after
the list, other than whitespace and comments, makes the file invalid.

```elisp
(:workflow story
 :target "rk/integration"
 :commands (:install ("npm" "ci") :lint ("npx" "eslint" ".") :test ("npm" "test"))
 :setup (install)
 :check (lint test)
 :agents (:worker codex :foreman claude)
 :timeouts (:worker 7200 :check 1800)
 :attempts 5
 :max-workers 3
 :track (:rk t :beads nil))
```

**Keys**, and the layers that may set each (the layers are below):

| Key | Value | Layers |
|---|---|---|
| `:workflow` | a workflow name, symbol or string | all |
| `:target` | a branch name, string | global, repo |
| `:commands` | a property list from a command name (`:lint`) to an argument list of strings, run without a shell | global, repo |
| `:setup` | an argument list of strings, or a list of command names | global, repo |
| `:check` | as `:setup` | all |
| `:agents` | a property list: `:worker`, `:foreman`, `:consul`, each an agent kind, `claude` or `codex` | all |
| `:timeouts` | a property list: `:worker`, `:check`, each a number of seconds | all |
| `:attempts` | how many workers a story is given before it is parked, a positive integer | all |
| `:max-workers` | how many workers run at once, across all repositories, a positive integer | global |
| `:track` | a property list: `:rk`, `:beads`, `:a2ui`, each `t` to track that directory in Git or `nil` to keep it out | global, repo |
| `:mixins` | a list of mixin names, symbols, applied to whatever workflow a story runs (7.1) | global, registration, repo, epic, task |
| `:git` | a property list: `:branch`, a format for story branch names; `:integrate`, `merge`, `rebase` or `squash` | all |

- `:setup` and `:check` are either one argument list (`("make" "test")`,
  every element a string) or a list of command names (`(lint test)`,
  every element a symbol). A list that mixes the two is invalid. Names
  run in order, each as its argument list from the merged `:commands`;
  all must succeed, and the first that fails ends the setup or check
  with its name, exit and output. A name that `:commands` does not
  define is invalid. A command name in `:commands` is a keyword (`:lint`)
  and the same name in `:setup` or `:check` is a plain symbol (`lint`).
- Names are resolved against the merged configuration of the repository
  (and the epic and task, for `:check`), so a global `:check (lint test)`
  may use commands each repository defines for itself. `:commands` is
  set only at the global and repo layers, so an epic's or task's `:check`
  names commands defined there.
- A key whose value is `nil` in a file is the same as a key left out.
  There is no way yet to turn off at one layer a check or setup set at a
  less specific one.
- The king's own agent is not configured here; it stays as it is started.
  `:agents :foreman` is the agent `foreman_start` and `epic_start` with
  `foreman` use when not given one.
- An explicit argument still wins over configuration: `story_start` with
  an `agent` or `workflow`, a task's `rk-agent:` and `rk-workflow:`
  labels, `foreman_start` with an agent. Configuration gives the default
  they replace.
- Review mode is chosen by the workflow, `story` (the king reviews) or
  `story-lite` (no review), or by the mixin `no-review` in `:mixins`. There is no `:review` key.
- An unknown key is invalid, and so is a key set at a layer the table
  does not allow.

**Layers**, least to most specific:

| Layer | Where | Who edits |
|---|---|---|
| defaults | the existing user options, below | user, with Customize |
| global | `~/.emacs.d/rat-kingdom/config.eld`, that is `config.eld` in `rat-kingdom-directory` | user, or king with `config_set` |
| registration | the `:workflow`, `:target`, `:check`, `:setup`, `:mixins` and `:git`, stored on the `repo` tuple by `repo_add` or `rat-kingdom-add-repo` | user, when registering |
| repo | `<repo>/.rk/config.eld` in the user's checkout | user, or king with `config_set` |
| epic | the epic's `policy` tuple | king with `config_set` |
| task | the task's `policy` tuple | king with `config_set` |

- The defaults are the existing user options, so a customization made
  before this keeps working: `:workflow` from
  `rat-kingdom-story-default-workflow`, `:target` from
  `rat-kingdom-git-default-target`, `:agents :worker` from
  `rat-kingdom-default-agent`, `:agents :foreman` is `claude` (as the
  foreman runs today), `:agents :consul` from `rat-kingdom-default-agent`,
  `:timeouts` from `rat-kingdom-story-timeouts` (its
  `:spawn` entry is `:worker`), `:attempts` from
  `rat-kingdom-story-attempts`, `:max-workers` from
  `rat-kingdom-story-max-workers`, `:track :beads` from
  `rat-kingdom-task-br-untracked` (non-nil there is `nil` here), and
  `:track :rk` and `:track :a2ui` are `nil`. There is no default
  `:commands`, `:setup` or `:check`. `:git` is
  `(:branch "rats/%i" :integrate merge)`, the behaviour from before
  `:git` existed, and there is no default `:mixins`.
- Registration stays a layer of its own, between global and repo, so a
  repository registered before configuration existed needs nothing
  migrated. Its values are written only by registering.
- The repo file is read from the user's checkout, the repository's
  `:path`, never from a worker's worktree or a branch. A worker that
  changes `.rk/config.eld` changes nothing until that commit reaches the
  user's checkout.
- A `policy` tuple is persistent, scoped to the repository, named by the
  epic's or task's id and owned by it, and is replaced whole. Its payload
  is a property list of the keys its layer allows, in the same form as a
  file. A story with no epic or task has no layer there.
- **Most specific wins, key by key.** For `:commands`, `:agents`,
  `:timeouts`, `:track` and `:git` the merge goes sub-key by sub-key: a
  repo file with `:commands (:test ("make" "test"))` keeps the global
  `:lint`. `:mixins` is a list, and a more specific layer replaces it; it
  is not merged.
- Every lookup can report the layer each value came from, and for the
  property-list keys, each sub-key's layer. Code reads configuration
  through one function that takes the repository and optionally the epic
  and task, so the engine never reads a user option or a `repo` field
  directly for these keys again.

**Errors.** A file that does not read as one property list, or that fails
validation (an unknown key, a key not allowed at its layer, a value of
the wrong shape), is ignored as a whole: its layer contributes nothing.
The error is shown in the king's `status`, for every repository it
affects, and once in `*Messages*`. It never stops the engine or a
reaction. A file is read again when its modification time changes, so
fixing it is enough. A file that is missing contributes nothing and is no
error.

What a single file cannot show (a command name defined in no layer, a
workflow that does not exist) is checked on the merged result. It is
shown in `status` for that repository, and a step that needs the missing
thing cannot begin, so its story goes to the failure place with the
reason (7.2). `config_set` refuses such a change before it is made; only
a hand-edited file can cause it.

**`:track`.** The engine never commits anything. `:track` only adds or
removes the line `/.rk/`, `/.beads/` or `/.a2ui/` in the repository's
`info/exclude`, in the directory `git rev-parse --git-common-dir` names,
which worktrees share. It never writes `.gitignore`.

- `nil` adds the line if it is missing; `t` removes it if it is there.
  The line is rat-kingdom's to manage: change it with `:track`, not by
  hand.
- It is applied when a repository is registered, when `rat-kingdom-mode`
  starts, and when `config_set` changes `:track` (at the global layer,
  for every repository).
- The `.rk` directory is created only when something is first written at
  the repo layer, by `config_set`. Applying `:track` never creates it.
- If a directory is to be kept out of Git but Git already tracks files in
  it (`git ls-files -- .rk`), rat-kingdom warns, in `status` and in
  `*Messages*`, and adds the line anyway, which does not affect tracked
  files. It does not run `git rm --cached`; that is the user's call.
- `:track :beads` replaces `rat-kingdom-task-br-untracked`, which becomes
  its default. A br workspace that already existed before rat-kingdom is
  still never touched by `br init` (section 10), but its exclude line
  follows `:track` like any other: kept out by default, with the warning
  above if Git already tracks it. A user who keeps `.beads` in Git sets
  `:track (:beads t)`.
- `:track :a2ui` is for `.a2ui`, where a2ui (`a2ui-library-directory`)
  saves UIs in the user's checkout. It is kept out by default, so a saved
  UI is not committed and pushed by accident. A user who keeps saved UIs
  in Git sets `:track (:a2ui t)`.
- Built: `rat-kingdom-config-track-apply` (one repository, returning the
  lines added and removed and any warnings, which `status` and
  `repo_add` also show), `rat-kingdom-config-track-apply-all` (mode
  start) and `rat-kingdom-config-repo-directory` (makes `.rk`, applying
  `:track` first), for `config_set` to call.
- An untracked `.rk` keeps `git status` in the user's checkout quiet, so
  `story_start` does not warn of uncommitted changes. A user who wants
  the configuration versioned with the code sets `:track (:rk t)` and
  commits `.rk` themselves.

**Workflow files.** Workflows can also be defined in
`~/.emacs.d/rat-kingdom/workflows/*.eld` (in `rat-kingdom-directory`, for
all repositories) and `<repo>/.rk/workflows/*.eld` (that repository
only). Each file holds one workflow as a property list with the keys
`rat-kingdom-workflow-define` takes (`:places`, `:start`, `:final`,
`:failure`, `:steps`, `:doc`) and `:name`, read with `read` and never
evaluated.

- It is validated as `rat-kingdom-workflow-define` validates, by
  `rat-kingdom-workflow-validate`. An invalid file, and two files in one
  directory with the same `:name`, are ignored with the error shown as
  for a configuration file. Files are read again when their modification
  time changes, and a changed workflow applies from a token's next move
  (7.1).
- A global file replaces a built-in workflow of the same name. A repo
  file shadows a global or built-in one of the same name for that
  repository only. Looking a workflow up therefore takes the repository,
  and `workflow_list` and the check of `:workflow` use the repository's
  view.
- A token whose workflow has gone, because its file was removed and
  nothing of that name is left, cannot move; the watchdog reports it as
  stuck (7.2).
- Built (`rat-kingdom-config.el`): `rat-kingdom-config-workflows`
  returns a repository's view, each workflow with its origin (`repo`,
  `global` or `built-in`) and file; `rat-kingdom-config-workflow`
  resolves one name for a repository. The engine looks a story's
  workflow up by name, for its repository, each time it moves the token,
  as it always did for built-in workflows; nothing is pinned when a story
  starts, so an edited file applies from the next move. A file may have
  no key but `:name` and those `rat-kingdom-workflow-define` takes.
  `workflow_list` takes an optional `repo`: without it, the workflows of
  every repository and then what each registered one has, with its own
  files' workflows described; with it, that repository's view. Each
  workflow says where it comes from and what it shadows, and ignored
  workflow files follow. `story_start`, `repo_add`, `epic_create`,
  `task_create`, the plan surface and the check of `:workflow` all use
  the repository's view.

**King tools.**

- `config_show` takes a repository and optionally an epic or a task. It
  returns the effective configuration, one line per key or sub-key, each
  with its value and the layer it came from, followed by any file that
  is being ignored and why, and any name the merged result cannot
  resolve.
- `config_set` takes a layer (`global`, `repo`, `epic` or `task`), the
  repository, epic or task it applies to (none for `global`), a key and a
  value. The value is Emacs Lisp text, read with `read` and never
  evaluated: `("npm" "test")`, `(lint test)`, `7200`. A value for a
  property-list key replaces that key's whole value at that layer;
  sub-keys it leaves out fall back to less specific layers. The value
  `nil` removes the key from that layer.
- Before writing anything it validates the merged result for every
  repository the change affects (every registered one for `global`): an
  unknown workflow, an undefined command name, a key not allowed at that
  layer, a value of the wrong shape, a `:target` that is not an existing
  local branch. If any fails it refuses with the reason and writes
  nothing.
- Otherwise it writes the file, pretty-printed and replaced whole, or
  replaces the policy tuple. Comments in a file are not preserved; the
  tool's description says so, and so does its answer when the file had
  any. A change to `:track` is applied at once.
- The king never writes elisp. The registration layer is not written by
  `config_set`.
- Built: `rat-kingdom-config-show` and `rat-kingdom-config-set`, offered
  to the king alone, not to a worker or the foreman. A problem the merged
  configuration already had (from a hand-edited file, say) does not
  refuse a change that leaves it as it was; only a problem the change
  would add does, so a broken configuration can be fixed one key at a
  time. For `global` and `repo` the check covers each affected
  repository and every epic and task with a policy in it. A file is
  written under a two-line comment saying rat-kingdom wrote it and that
  comments are not kept; a `repo` file's `.rk` is made by
  `rat-kingdom-config-repo-directory`. Setting a key to the value it has
  writes nothing.

**Built: `:mixins`** (step 8). A list of mixin names, symbols, each a
built-in mixin or a mixin file the repository can see (7.1). It applies
those mixins after the workflow's own mixins, to whatever workflow a
story runs; the story's repository, epic and task decide its value.
`repo_add` and `rat-kingdom-add-repo` take an optional `mixins`, Emacs Lisp
text read as `config_set` reads a value, for the registration layer. As
for `:check`, a less specific layer's `:mixins` cannot be turned off at a
more specific one except by replacing it with another list. A name that
is not a mixin, or a merged `:mixins` with which the merged `:workflow`
does not expand, is a problem of the merged result: `status` shows it,
`config_set` refuses to make it, and a story whose workflow does not
expand cannot move (7.1).

**Built: `:git`** (step 8). A property list with two sub-keys, merged sub-key
by sub-key. `repo_add` and `rat-kingdom-add-repo` take an optional `git`
for the registration layer, as for `mixins`.

- **`:branch`** is a format for a story's branch name, by default
  `"rats/%i"`. Its specifiers are:
  - `%i`, the story id;
  - `%s`, a slug of the title: lowercased, every run of characters other
    than `a`–`z` and `0`–`9` made one `-`, dashes trimmed from both ends,
    cut to at most 40 characters and trimmed again, `story` if nothing is
    left;
  - `%r`, the repo;
  - `%e`, the epic id, or `none`;
  - `%%`, a literal `%`.

  The result must pass `git check-ref-format --branch`. The format is
  validated where it is set (a file read, or `config_set`): a `%`
  followed by anything else is invalid, and so is a format that, filled
  with `S-0000`, `title`, `repo` and `none`, breaks the rules of
  `git check-ref-format` (checked in Lisp: no `..`, `@{`, `//`, space,
  control character or any of `~^:?*[\`; no component starting with `.`
  or ending with `.lock`; not ending with `/` or `.`; not `@`).
  The name is made when a story starts, from the story's configuration,
  checked with `git check-ref-format --branch` (a failure is an error
  that starts nothing), and kept on the token as `:branch-name`. When the
  story's worktree is first made, a name that is taken by a local branch
  gets `-2`, `-3` and so on, the first that is free, and the branch made
  is recorded as `:branch`, as now. Only new stories use the format: a
  token with no `:branch-name` gets `rats/ID`, as today. A child story
  uses its parent's branch, and an epic's feature branch stays
  `rk/epic/ID`.
- **`:integrate`** is `merge` (the default, today's behaviour), `rebase` or
  `squash`: how a story's work goes into its target. Section 11 says what
  each does. It is read for the story's repository, epic and task when
  its check begins, kept on the `checked` tuple as `:integrate` and
  copied to the token with `:head` and `:base`, so the merge step and the
  clean-up use the mode that was checked. When an epic's feature branch
  lands, it is read for the epic's repository and epic.

**Built: a feature branch per epic**, chosen per epic rather than through
configuration: `epic_start` with `feature_branch` (section 10). The epic's
branch is `rk/epic/ID`, cut from the repository's target. Its stories
carry it as their own target, so each is cut from it and merged into it,
and the repository's target moves once, when the epic lands. A story's
target is read in one place, `rat-kingdom-story-target`: the token's
`:target`, else the repository's. `story_start` takes a `target` too,
rarely needed; it must be an existing local branch that is not checked
out. With configuration, "the repository's" target is the merged
`:target`, and an epic's or story's own target still wins over it.

## 8. Runs

### 8.1 What a run is

A run is one agent session doing one job: an agent-shell buffer over ACP, a
worktree, a branch, and a `run` tuple. A worker does one task per lifetime.

Run states, kept distinct as in rk2: `starting`, `working`, `ready`,
`blocked`, `stopped`, `exited` (its session ended before it reported) and
`interrupted` (Emacs stopped while it worked). A run that cannot be
started is `exited` with the error.

**Built: names.** Every rat, that is every run but the king's (workers,
researchers, foremen, consuls), has a name, `:name` in its run record,
taken in turn from `rat-kingdom-rat-names` (Pip, Nibbles, Whiskers and
some sixty more, each one word). The place in the list is kept in the
file `rat-names` in `rat-kingdom-directory`, so it carries on after a
restart, and a name a live rat holds is skipped: one whose run is
`starting`, `working` or `interrupted`, or whose agent runs in this
Emacs, or a consul not yet dismissed. If every name is held, the next is
numbered, as Pip2. A name is shown with the run's suffix, the four hex
digits of its story or consul, or the epic's id for a foreman: Pip-3a9c
for S-3a9c's first worker, Nibbles-3a9c for its second, Bean-T-1 for the
foreman F-T-1. People see it with the id beside it, "Pip-3a9c
(S-3a9c.1)", in agent-shell buffer names ("rat Pip-3a9c (S-3a9c.1)"),
status lines, `story_show`'s worker line, `tell`'s answers and the
engine's news, and a worker is told its own in its prompt. Ids stay the
references every tool takes. A foreman or consul taken up again after a
restart keeps its name.

A story's run counts against the worker limit (section 7.2) while it is
`starting` or `working`. Once it reports, its agent sits idle until its
story moves on; the king's run never counts. Stories beyond the limit
queue and start in order as workers end.

The process state comes from agent-shell's events (session ready, turn
ended with its stop reason, tool call, permission request, error, process
gone), the way deathless's store already reads them. The outcome comes only
from the worker's `finish` or `block` tool. A turn ending says nothing
about whether the task is done.

### 8.2 Messages

A `message` tuple is delivered as the run's next prompt when its turn ends.
If the run is idle it is delivered at once.

**Built for the king** (`rat-kingdom-king.el`). Messages waiting for the
king are given to it together, as one prompt, when it is between turns and
the user has nothing typed but unsent in its buffer. Otherwise another try
is made twenty seconds later and at the end of its next turn. A message is
removed after it is sent, so a crash between the two repeats it and never
loses it.

**Built for foremen** (`rat-kingdom-foreman.el`). An epic's foreman (9) is
given its news the same way, by the same code: `rat-kingdom-king-deliver-to`
gives any run the `message` tuples addressed to it with `:to`, as one
prompt headed "[rat-kingdom] News from the engine:", retracting them only
after the send, and retries on a timer of its own;
`rat-kingdom-king-deliver` is that for the king. A message written with a
`:to` is tried soon after (a space change hook), and a run's messages
whenever it ends a turn. Which run is told of an epic's work is chosen by
`rat-kingdom-king-route`, through `rat-kingdom-king-route-functions`: while
a live epic's foreman is running (or starting), news of the epic's stories
(review requests, stopped and stuck stories, held tasks, merges, a task
dispatch could not start) is addressed to it instead of the king. News of
the epic as a whole (done, ready to land, landing that failed) has no
epic to route by and stays the king's, as do the foreman's own `report`s.
Without a running foreman everything goes to the king as before; if the
foreman died rather than being stopped, each piece of news the king gets
instead says so. Messages that waited for a foreman when it stops, by
`foreman_stop`, with its epic, by dying, or at a reconcile that cannot take
it up again, are readdressed to the king in one transaction, each prefixed
with what happened, so none is lost.

**Built for workers** (`rat-kingdom-message.el`). The king's `tell`
writes a linear `message` tuple scoped to the story's repo, owned by the
story so that it is archived with it, with the payload `:to-story STORY
:from FROM :text TEXT`. FROM is `king`; `rat-kingdom-message-tell` takes
another, and the foreman passes its run id, which workers see as
"Message from foreman F-…". Telling an unknown or finished story,
or with blank text, is an error. A message is addressed to the story, not
to a run, and is given only to the story's current run while that run is
`working`: never to one that has reported with `finish` or `block`, and
never to the king's. It is tried at once, when it is written (from a
space change hook, soon after), and whenever the run ends a turn
(`rat-kingdom-run-idle-functions`). All the story's waiting messages go
in one prompt, oldest first, each headed `[rat-kingdom] Message from the
king:` (or from FROM). `rat-kingdom-run-send` refuses while the agent is
in a turn; a run that is between turns but refuses is tried again after
`rat-kingdom-message-retry-interval` (20) seconds. Each message is
retracted only after the send succeeded. A worker can also take its
messages in the middle of a turn with `inbox`, which returns them oldest
first with their senders and retracts them, or says `No messages.`; it
refuses a run that is not its story's working run. `tell` answers which
of these happened: delivered now, waiting for the run's turn to end (or
its first turn, while it starts), or no worker right now, saying where
the story is. A message sent while the story is at its check or review
is read only if the story goes back to a worker.

A story with no working run keeps its messages for its next worker: they
are a section of its brief (8.3), under "Messages for this task from the
king (oldest first):". They are retracted only when that run becomes
`working`, that is when its backend has started the agent with the
prompt, and only if the run's recorded prompt holds that section. A run
that fails to start leaves them for the next. Which messages went into
which brief is kept in memory, so if Emacs stops between the brief and
the start, they stay in the space and are given again as a prompt once
the restarted run is working: repeated, not lost. Since messages are
tuples, a restart keeps them, and the worker that replaces one cut off
by a restart (8.4) gets them in its brief. `status` shows "N messages
waiting" on a story's line and `story_show` lists each one's sender and
first line, through `rat-kingdom-king-story-note-functions`.

### 8.3 The brief

When a run starts, the engine builds its prompt from: the role's
instructions, the task, and a query of the space for facts, docs and
policy in that task's repo and epic. This is how a research worker's
findings reach a worker started days later.

**Built for facts** (`rat-kingdom-fact.el`). A worker records a fact with
`note_fact`: the text, at most `rat-kingdom-fact-max-length` (1500)
characters, and optionally a topic and the files it concerns. It is
written as a persistent `fact` tuple scoped to the run's repo, with no
owner, the payload `:text :topic :files :story :run`, and the run as the
actor, so it outlives the story, merged or cancelled. A worker's prompt
ends with the sections returned by the functions on
`rat-kingdom-story-brief-functions`, each called with the space, the
story's token and the run's id. rat-kingdom-fact.el puts one there: the
repo's facts, newest first, with topic and files, capped at
`rat-kingdom-fact-brief-max-count` (40) facts and
`rat-kingdom-fact-brief-max-chars` (8000) characters, saying how many
older ones are left out. A repo with no facts adds no section. rat-kingdom-message.el adds
another after it: the story's waiting messages (8.2). Policy is not in
the brief yet.

**Built: docs in the brief** (`rat-kingdom-doc.el`). Every
worker's brief lists the repo's approved docs, through
`rat-kingdom-story-brief-functions`, in a section after the facts and
before the messages: "Approved docs for this repository (read one with
read_doc):", then one line per doc, `D-1a2b: TITLE (topic)`, newest
first. It is capped like facts, at `rat-kingdom-doc-brief-max-count` (40)
docs and `rat-kingdom-doc-brief-max-chars` (4000) characters, saying how
many older ones are left out. A repo with no approved docs adds no
section. The bodies are not in the brief; a worker reads one with
`read_doc` (id), which returns its title, topic, status and text, for a
doc of its own repo only. A story that has drafts of its own, as a
research story does after a fix, gets another section, "Your drafts, to
revise with write_doc:", listing each draft's id, title and topic.

### 8.4 Recovery

**Built** (`rat-kingdom-story-reconcile`, run when `rat-kingdom-mode` is
turned on and by `M-x rat-kingdom-reconcile`), and tested by closing the
space and discarding everything held in memory, not yet by killing a real
Emacs. A run recorded as `working` with no agent in this Emacs becomes
`interrupted`, and a reaction gives its story a new worker in the same
worktree, with a fresh session and a prompt that says what happened. That
worker takes its old place ahead of the queue for a free worker, which is
kept and served once the replaced workers have started. A
check that was running is run again, and so is a setup that was running
in a new worker worktree, which keeps its worker place. The king takes up its earlier
session by its id. So does an epic's foreman, on reconcile: a foreman run
left `interrupted` whose epic is live is recorded again with the same agent
and `:resume` set to its session (`rat-kingdom-foreman-reconcile`), and the
reaction that starts runs takes the session up; one whose epic ended is
marked `stopped` and its waiting news given to the king. An epic that was `landing` stays so; if its landing
check was running, `rat-kingdom-epic-reconcile` runs it again in a fresh
candidate (from `rat-kingdom-reconcile`, as interrupted story checks are),
and a landing that waited for a review still waits. Running epics are
dispatched again once the tasks are projected (section 10). Sessions that end while Emacs is exiting are not
recorded as ended, so they are found interrupted on the next start.

The plan this came from:

On Emacs startup, and on demand, reconcile:

- For each `run` not in a final state with no live process: mark it
  `exited`, keep its worktree and branch, and resume it if its workflow
  step says to.
- Resuming starts a new attempt in the same worktree. It reloads the ACP
  session when the agent supports it, and otherwise starts a fresh session
  with a brief that says what exists in the worktree.
- Stopping never commits, merges, pushes or deletes.

**Checked, 2026-11-12** (agent-shell `6ae364b`, claude-agent-acp 0.101.0,
by reading both; not yet exercised by a test):

- `agent-shell--start` starts a shell from code. It takes an agent config,
  `:no-focus` for the background, and `:session-strategy 'new` to skip the
  session picker. It returns the buffer.
- Passing `:session-id` restores that session with `session/resume` or
  `session/load`, whichever the agent advertises, and starts a new session
  if it advertises neither. Claude's adapter advertises `loadSession` and
  implements resume. The session ID is in the shell's state once the
  session is up, and is stored on the `run` tuple.
- `agent-shell-insert` with `:submit t` sends a prompt to a shell.
  `agent-shell-subscribe-to` delivers its events.
- `agent-shell--start` and the shell's state are internal to agent-shell.
  deathless and meta-agent-shell already depend on both. rat-kingdom keeps
  every such call in one file.

### 8.5 Agents

**Built.** A run's agent is one of a small set of agent kinds. Each kind
is a function that returns an agent-shell config:

| Kind | Config | Loads |
|---|---|---|
| `claude` | `agent-shell-anthropic-make-claude-code-config` | agent-shell-anthropic |
| `codex` | `agent-shell-openai-make-codex-config`, put in full-access mode | agent-shell-openai |

A kind's library is loaded only when a run of that kind starts. The
built-in kinds are in the defconst `rat-kingdom-agent-shell-builtin-agents`.
`rat-kingdom-agent-shell-define-agent` adds a kind, or replaces one of the
same name. Those additions are kept in a defvar, so a reload keeps them,
takes the built-in defaults afresh and lists no kind twice.

The agent is chosen per story. `story_start` takes `agent`, `claude` or
`codex`, and so does `rat-kingdom-story-start`. When it is left out, the
story gets `rat-kingdom-default-agent` (default `claude`). The name is
checked when the story starts: an unknown one is an error that names the
known kinds. The result is recorded on the story token as `:agent`, so a
later change to the default does not affect stories already started.
Each worker the story is given gets the story's agent as `:agent` on its
run. That holds for the first worker and for every replacement: after a
failed check, a merge conflict, a review that asks for changes, and after
recovery. The backend builds the run's config from that `:agent`. A run
with no `:agent` is Claude Code: the king, and runs recorded before agents
could be chosen. The king is always started that way. A run that takes up
a session (`:resume`) is given the agent of the run that started the
session. Today only the king resumes sessions. `status` lists the agent
kinds and the default, and shows each story's agent, as does `story_show`.

The Claude model is chosen apart from the king's. `story_start` takes an
optional `model`, a Claude model id, and so does `rat-kingdom-story-start`.
When given, it is recorded on the story token as `:model` and on each of
its workers' runs (and on a child story's token), like `:agent`. When a
run's config is made, a run that is not the king's and whose agent kind is
`claude` is given `:default-model-id`, a function that returns the run's
`:model`, else `rat-kingdom-worker-model` (default nil). With neither, the
config keeps agent-shell's own `:default-model-id`. The king's config and
Codex configs are never changed. `story_show` shows the model when one was
given.

**Codex runs in full access**, the equivalent of `codex --yolo`. codex-acp
has four session modes: `read-only`, `workspace-write`, `agent` (its
default, auto review) and `agent-full-access` (approval policy `never`,
sandbox `dangerFullAccess`). rat-kingdom sets `agent-full-access` in two
ways. The config's `:default-session-mode-id` returns it, so agent-shell
sets the mode once the session is up. The client's environment also has
`INITIAL_AGENT_MODE=agent-full-access`, which codex-acp reads when it
makes, loads or resumes a session. The user's
`agent-shell-openai-default-session-mode-id` is not changed.

**Checked, 2026-11-13**, by reading the installed
`@agentclientprotocol/codex-acp` 2.2.2 and trying codex-cli 0.166.0. No
Codex worker has been run end to end yet.

- codex-acp advertises `mcpCapabilities.http: true` (not `sse`, not
  `acp`). It honours HTTP servers given in `session/new`, `session/load`
  and `session/resume`. It turns each into an `mcp_servers` entry of the
  Codex config, with `url` and `http_headers`, so a Codex worker reaches
  rat-kingdom's endpoint as a Claude one does, through the run's own
  token URL from `rat-kingdom-agent-shell--servers`. One catch: if the
  user's Codex config already defines a server named `rat-kingdom`,
  codex-acp skips the requested one in its favour. Setting
  `DISABLE_MCP_CONFIG_FILTERING=true` turns that off.
- codex-acp starts `codex app-server` with its own environment, which is
  the ACP client's. So the push guard's variables reach Codex.

## 9. Roles and tools

Tools are served by an MCP endpoint inside Emacs, scoped by role. A
worker's session does not contain the coordinator tools at all.

**Checked, 2026-11-12:** an agent config carries its own `:mcp-servers`,
and agent-shell sends those with the session request in place of the
global list. So each run gets a server entry whose URL holds a token for
that run. The endpoint looks the token up, knows the run and its role, and
lists only that role's tools. The global list is replaced, not merged, so
rat-kingdom adds the user's other servers to each run's list itself.

The `emacs` endpoint in the user's configuration has one token and one
tool registry, so it cannot tell runs apart. rat-kingdom ships its own
endpoint, built the same way.

An agent config also carries `:session-meta`, sent as `_meta` with the
session request. Claude's adapter reads a system prompt and lists of
allowed and disallowed tools from it. That is where a role's instructions
go, and it lets a role be denied built-in tools as well.

| Role | Lifetime | Tools |
|---|---|---|
| king | long-lived, global, no worktree | built: `status` (with the tracker tasks available, each with its epic and agent), `repo_add`, `repo_sync`, `workflow_list`, `story_start` (optionally from a `task`, with an `agent` and a `model`; a task's `rk-agent:` and `rk-workflow:` labels are the defaults), `story_show`, `story_diff`, `story_move`, `story_cancel`, `verdict`, `publish`, `query`, `fact_forget`, `task_create`, `epic_create`, `epic_propose` (the epic plan surface, 14.1), `epic_start` (optionally with a `feature_branch`, and a `foreman`), `epic_pause`, `epic_resume`, `epic_cancel`, `epic_retry`, `epic_show`, `epic_diff`, `epic_verdict` (section 10), `tell`, `foreman_start`, `foreman_stop`, `consul_start`, `consul_dismiss`, `config_show` and `config_set` (7.3), `doc_list`, `doc_show` and `doc_forget` (7.1), `story_signal` (7.1), `compact_self` (below); `story_start` also takes a rarely needed `target`; built (step 8): `mixins` and `git` on `repo_add` |
| rat (worker) | one task | built: `finish`, `block`, `note_fact`, `inbox`, `read_doc` |
| researcher | one task | built: `write_doc`, `read_doc`, `note_fact`, `inbox`, `block`, `finish` |
| consul | one repository, until the user dismisses it | built: `write_doc` (its docs are approved at once), `read_doc`, `note_fact` |
| foreman | one epic, optional | built: `status` (its epic: the `epic_show` view and its stories' lines), `story_show`, `story_diff`, `verdict`, `tell`, `query`, `task_create` (its epic is the parent), `epic_retry`, `story_start` (for a task of its epic), `report` (to the king); every one but `query` limited to its epic |
| ambient | one event | set by the reaction that starts it |

The king's instructions list its tools by name, generated from the tools
defined for the role `king` (`{tools}` in `rat-kingdom-king-instructions`),
so a tool added later is listed without editing them. A changed list
changes the king's fingerprint, and a reload restarts it in place.
The king's and the consul's instructions, not other roles', say to also
show an explained concept, implementation detail or plan visually with
a2ui (`a2ui_catalog`, then `render_a2ui`), keeping the text answer
complete.

A tool is defined per role: a definition replaces only the tools of its
name that share a role with it, so the foreman's `status` or `tell` is
its own and the king's is unchanged, and no role is offered two tools of
one name.

Other Emacs packages can ask which run an agent-shell buffer holds:
`(rat-kingdom-buffer-run &optional BUFFER)` returns its role, id, name,
story, title (the story's, the foreman's epic's, or the consul's topic),
repo and state, or nil. The agent-shell backend sets the buffer-local
`rat-kingdom-run-buffer-id` when it makes the buffer, for every role, so
the lookup does not parse buffer names; the rest is read from the space
at each call. The variable is permanent-local, a reload keeps it, and a
restart's new buffers are marked as they are made.

**Built: the foreman** (`rat-kingdom-foreman.el`). An optional long-lived
agent that runs one epic on the king's behalf, so that a big epic does not
flood the king with reviews. It is a run like the king's, with the id
`F-` and the epic's id, the role `foreman`, `:epic` and `:repo`, in the
repository's checkout, which its instructions
(`rat-kingdom-foreman-instructions`, with `{epic}`, `{title}`, `{repo}`,
`{goal}` and a generated `{tools}`) say never to edit. It runs Claude Code
unless started with another agent; `rat-kingdom-default-agent` is not
applied. Its first prompt has the epic's `epic_show` view and the stories
waiting for review. The king's `foreman_start` (an epic, optionally an
agent) starts one for a running or paused epic and records `:foreman` on
the epic's record, refusing if one is running; `epic_start` with
`foreman` starts one right after. `foreman_stop` stops it and hands its
reviews back to the king. It stops by itself when its epic is done or
cancelled (`rat-kingdom-epic-ended-functions`), and the king is told.

The foreman's tools share the king's code: `rat-kingdom-king-story-start`,
`rat-kingdom-king-verdict`, `rat-kingdom-king--show`,
`rat-kingdom-king--diff`, `rat-kingdom-message-tell-answer` take an
optional scope check, which the foreman's tools pass and the king's do
not. It refuses a story whose `:epic` is not the foreman's epic, live or
archived, and a task whose parent is not the epic; it is applied before
anything is written. `task_create` forces the parent to the epic and
refuses dependencies outside it (`rat-kingdom-epic-task-create-answer`);
`epic_retry` is always its own epic's
(`rat-kingdom-epic-retry-answer`); `report` writes a message to the king,
"[rat-kingdom] Report from the foreman of epic E: …". `query` is the
king's, offered to both roles. The foreman has no `publish`, `repo_add`,
`repo_sync`, `epic_create`, `epic_start`, `epic_cancel`, `epic_verdict`,
`story_move`, `story_cancel` or `foreman_*`. `status` and `epic_show`
show "foreman F-… (agent, working)", idle, starting or stopped.

**Built: the consul** (`rat-kingdom-consul.el`). A rat the user asks
the king for in one registered repository, whose only job is to talk
with the user about that project, directly, in its own agent-shell
buffer, while the king is busy. The king does not drive it, review its
turns or relay messages to it. It is a run like the foreman's, with the
id `C-` and four hex digits (unique as story ids are, against live and
archived runs), the role `consul`, and `:repo`, `:name`, `:topic` (an
optional line), `:branch`, `:worktree`, `:target` and `:started` in its
record. It works in a worktree of its own under
`rat-kingdom-directory`, cut from the repository's target on a new
branch made by `:git :branch` with the id `consul-NAME-XXXX`
(`rats/consul-pip-3a9c` by default), push-guarded as any `rats/*`
branch; it never touches the user's checkout. It runs the agent it is
given, else `:agents :consul` for its repository (7.3), and the model
it is given, else `rat-kingdom-worker-model`. Its instructions
(`rat-kingdom-consul-instructions`, with `{name}`, `{repo}`, `{topic}`,
`{worktree}`, `{branch}`, `{target}`, `{checkout}` and `{tools}`) say:
explore and explain the code, answer questions, propose designs; write
docs when asked or when a discussion reaches a decision worth keeping;
change code and commit in its worktree when the user asks; never push;
never start stories or epics; wait until the user dismisses it.

Lifecycle:

- **Start.** The king's `consul_start` (`repo`, optionally `topic`,
  `agent`, `model`) makes the worktree and branch, records the run and
  starts its agent; its buffer is shown to the user. It answers with the
  consul's name, id and buffer. `M-x rat-kingdom-consul-start` asks for
  a repository and a topic and pops to the buffer, which is in
  `rat-kingdom-consul-mode`.
- **While it runs.** No engine news goes to it: it has no story and no
  epic, so nothing routes to it, and the king's story tools (`tell`,
  `story_*`, `verdict`) never reach it. `status` lists the consuls in a
  section of their own: id, name, repository, state, age, agent, topic,
  branch and how many commits it is ahead of the target.
- **Dismissal.** `consul_dismiss` (`consul`, its id or name, and
  optionally `force`), or `M-x rat-kingdom-consul-dismiss`, bound to
  `C-c ~ d` in the consul's buffer, stops its agent. Uncommitted changes
  in its worktree refuse the dismissal, with the paths, unless `force`
  is given; then they are committed first as a WIP commit. If its
  branch then has commits its target lacks, they become a story in the
  repository's workflow (`rat-kingdom-story-start-from-branch`), titled
  by the topic or "Consul NAME: <first commit's subject>", on the
  consul's branch and worktree, at the place a worker's finished work
  goes (`rat-kingdom-story-work-place`, where the spawn steps from the
  start lead: `checking` in `story`), so the check runs and the king
  reviews and merges it as usual. Otherwise its worktree and branch are
  removed. Its docs stay either way. The answer says which happened.
  Its run record is then archived.
- **Restarts.** A consul lasts until it is dismissed. One that Emacs cut
  off is taken up again in its session, with its name, on reconcile
  (`rat-kingdom-consul-reconcile`); `M-x rat-kingdom-consul-show` shows
  its buffer, starting it again if its agent ended.

**Built:** `query` (`rat-kingdom-fact.el`) is the king's read-only look
into the space (5.5). It takes a `category`, which must be a known one,
and optionally `scope`, `identity`, `owner`, `contains` (a substring of
the printed payload, ignoring case), `archived` (true to search the
archive too) and `limit` (default 20, at most 200). It answers one block
per tuple, newest first: id, category, scope, identity, owner, the actor
from the operations log, time, and the payload, cut to
`rat-kingdom-fact-query-payload-limit` characters; it says how many
matched and whether the list was cut off. It never writes.
`fact_forget` retracts one `fact` by id and refuses any other tuple.

**Built: tools for docs and signals** (step 8; 7.1, 8.3). The doc tools
are in `rat-kingdom-doc.el`; `story_signal`, and `repo_add`'s `mixins`
and `git` arguments (7.3), are in `rat-kingdom-king.el`.

- `write_doc` (researcher): `title`, `body` (Markdown), optionally `topic`
  and `id`, the id of a doc to revise. It writes a `doc` tuple scoped to
  the run's repo, with no owner, the payload `:title :body :topic :status
  draft :story :run`, and the run as the actor. Without `id` it makes a
  new doc; with one it replaces that doc whole, keeping its id, as a
  draft of this story, even if it was approved. It refuses a blank title
  or body, a body over `rat-kingdom-doc-max-length` (100000) characters,
  an `id` that is not a doc of this repo, and a run that is not its
  story's working run. It answers with the doc's id.
- `write_doc` (consul): as the researcher's, but the doc is `approved`
  when written, since the user asked for it, and belongs to no story;
  `:run` is the consul's id.
- `read_doc` (rat, researcher, consul): `id`. It returns the doc's title, topic,
  status and body, and refuses a doc of another repo.
- `finish` (researcher): `summary` and `checks`, as a rat's. It needs at
  least one doc whose `:story` is this story, and no commit (7.1).
- `note_fact`, `inbox` and `block` (researcher) are the rat's.
- `doc_list` (king): `repo`, optionally `status` (`draft` or `approved`).
  One line per doc, newest first: id, status, title, topic, the story
  that last wrote it, and when.
- `doc_show` (king): `id`. The doc in full, with its payload's fields and
  who wrote it, from the operations log.
- `doc_forget` (king): `id`. It retracts one `doc`, as `fact_forget`
  retracts a fact, and refuses any other tuple.
- `story_signal` (king): `story` and `name`. It writes a linear `signal`
  tuple scoped to the story's repo, named and owned by the story, with
  `:name NAME` (5.4). It refuses an unknown or finished story and a blank
  name. It answers whether the story waits at a gate for that name now,
  so it opens, or not, in which case the signal is kept until a gate
  waits for it or the story ends. The engine consumes it when the gate
  opens.
- `repo_add` (king) takes optional `mixins` and `git`, Emacs Lisp text read
  as `config_set` reads a value, for the registration layer (7.3).

**Built: the king compacts its own context** (`rat-kingdom-king.el`).
**Checked, 2026-11-18:** a `/compact` sent as an ordinary prompt through
agent-shell runs Claude Code's compact command. claude-agent-acp 0.93.0
hands the prompt text to the SDK as it is. `compact` is not in its
`UNSUPPORTED_COMMANDS`, so it is in the `available_commands_update` it
sends; agent-shell keeps that list in its state and uses it only to
complete and show commands. The adapter knows `/compact`: it hides the
command when it replays a session, and it settles the compaction's turn,
which echoes no user message, so the prompt request ends and agent-shell
emits `turn-complete`. Text after the command, `/compact <focus>`, is
Claude Code's instructions for the summary. So no restart with a handoff
is needed.

The king's tool `compact_self`, with an optional `focus`, only schedules
the compaction, because the king calls it in the middle of its own turn.
When the king's turn ends (`turn-complete`, then
`rat-kingdom-run-idle-functions`), the engine sends `/compact <focus>`, the
focus put on one line, and tries again after
`rat-kingdom-king-retry-interval` if the king cannot take a prompt. News
for the king waits in the space while the compaction is scheduled or runs.
When the compaction's own turn ends, the king is given one prompt: a line
saying that it was compacted and that it should call `status`, then the
news that waited. A new session of the king forgets a compaction under
way; its first prompt says how things stand anyway. `M-x
rat-kingdom-king-compact` does the same for the user, at once if the king
is between turns. The state is kept in Emacs, not in the space: a
compaction asked just before Emacs exits is not done.

The king's chores from imp and rk2 (run the check, merge, close the task,
clean the worktree, notice a finished worker, start an epic's next
stories) are reactions. Review
requests reach the king as messages at a turn boundary and never interrupt
a conversation with the user.

## 10. Tasks

Tasks sit behind an adapter:

```
ready(repo) → tasks      show(id)      create(..., labels)   close(id, reason)
claim(id, run)           release(id)   comment(id, text)
depend(id, depends-on)   children(epic) → tasks
```

`depend` is `br dep add ID DEPENDS-ON`: the task that waits comes first,
and it is not ready until DEPENDS-ON is closed. `children` reads an epic's
tasks from `br show EPIC` (its dependents of type parent-child) and one
more `br show` of them, with their status, labels and the tasks each
depends on. `ready` reads the ready tasks with one `br show` too, since
`br ready` does not give a task's parent.

The adapter is Rust Beads (`br`), and br is required: every registered
repository has one canonical workspace, the `.beads` directory of the
user's main checkout, as in rk2. br runs there and never in a worker's
worktree. `rat-kingdom-task-adapter-function` stays as the extension point,
so tests can use an in-memory adapter and a tuplespace-native adapter can
follow.

A repository with no workspace gets one when it is registered, and, for
those registered earlier, when `rat-kingdom-mode` starts or the tasks are
refreshed (`rat-kingdom-task-br-ensure`):

- br must be installed; if it is not, registration fails, saying so.
- A `.beads` that already exists is left alone: br is not run in it.
  Only its exclude line follows `:track` (7.3).
- Otherwise `br init --prefix PREFIX` runs in the checkout, and `br config
  get issue_prefix` must then answer PREFIX, since a user-level br
  configuration once overrode it. PREFIX is the repository's
  `:task-prefix`, set through `repo_add` or `rat-kingdom-add-repo`, or else
  its name. A prefix br rejects is reported with br's message; no other is
  tried.
- The new workspace is untracked: `/.beads/` is added, once, to
  `info/exclude` in the repository's common Git directory, never to
  `.gitignore`, and `git status --porcelain` must then show nothing under
  `.beads`, unless `:track :beads` (7.3), whose default comes from
  `rat-kingdom-task-br-untracked`, says to track it instead.
- If any step fails, the `.beads` it made and the exclude line it added
  are removed, and registration fails with the reason: no `repo` tuple is
  written and no target branch created. On mode start a failure is a
  warning and a note in the king's `status` for that repository; the
  others are still ensured and the engine starts.

The adapter projects ready tasks into the space as `available` tuples,
with the task's epic (`:parent`) and labels when it has them. An epic is
never projected: it is not work for one story. When integration closes a
task, its dependents become ready and are projected in turn. That is how
an epic's waves advance without a foreman.

**Built: planning an epic** (`rat-kingdom-epic.el`). The king creates tasks
with two tools; neither starts anything.

- `task_create` makes one task: title, description, and optionally
  priority (0 to 4), type (task, bug, feature, chore), `parent` (an epic),
  `depends_on` (ids, separated by commas or spaces), `agent` and
  `workflow`. The agent and workflow must be known, and the parent and the
  tasks depended on must exist, before anything is written.
- `epic_create` makes an epic and its stories. It takes the repository,
  the epic's title, a description (its goal and how it is judged as a
  whole) and `stories`, a JSON array of objects: `key` (local to the
  call), `title`, `description`, and optionally `depends_on` (keys),
  `agent`, `workflow` and `priority`. The tool's input schema describes the
  array and its objects (`items`), so the king's client sends real JSON; a
  JSON text is accepted as well.
- The plan is checked in full first: unique keys, non-blank titles and
  descriptions, dependencies on keys of the plan only, no cycle (found in
  Lisp, and named as `a depends on b depends on a`), known agents and
  workflows, priorities from 0 to 4. Any problem creates nothing, and every
  problem is listed.
- Then the epic is created (`--type epic`), each story as a task of it
  (`--parent EPIC`, with its labels) in an order where every task comes
  after those it depends on, keeping the given order otherwise, and then
  the dependencies.
- If br fails partway, the error names the step, br's message, every id
  created and every dependency recorded. Nothing is rolled back: `br
  delete` only leaves tombstones.
- The repository's tasks are projected again, and the king gets the epic's
  id, a table of key, task, title, dependencies, agent and workflow, and
  which tasks are ready now.

A task carries its story's agent and workflow as the labels
`rk-agent:NAME` and `rk-workflow:NAME`. `story_start` with a `task` uses
them unless it is given `agent` or `workflow`. The king's instructions
tell it to propose an epic's stories and dependencies to the user and call
`epic_create` only once they agree.

**Built: running an epic** (`rat-kingdom-epic.el`). An epic runs once the
king calls `epic_start`; its instructions say to ask the user first, and
that the stories of a running epic are started by the engine, not by the
king, which reviews them as usual.

- **The record.** An epic's state is one persistent `epic` tuple (5.4),
  scoped to the repository and named by the br epic's id, so it survives
  a restart. It is only ever replaced whole, in one transaction:
  `running`, `paused`, `done` or `cancelled`, the title, an optional
  `:max-parallel`, the held tasks with their reasons, the tasks merged
  by its stories, and when it started and ended.
- **Starting a story for a task** is one function,
  `rat-kingdom-story-start-for-task`, used by `story_start` and by
  dispatch: the title and the task's text from the `available` tuple or
  the tracker, the agent and workflow from its labels, the `available`
  tuple taken and the task claimed. A story started for an epic, or by
  `story_start` for a task of an epic that has a record, carries
  `:epic`, and, while the epic has not ended and has a feature branch,
  that branch as its `:target`. `rat-kingdom-story-start` refuses a task that already has a
  story in progress, in the same transaction that takes the `available`
  tuple and writes the token.
- **Dispatch** (`rat-kingdom-epic-dispatch`) starts, for each running
  epic, a story for each `available` task whose `:parent` is the epic,
  that is not held and has no story, while the epic has fewer stories in
  progress (parked ones included) than its `:max-parallel`. Each start
  checks all of that again in the transaction that takes the tuple, so
  dispatching twice, or from two triggers, never gives a task two
  stories. The worker cap and its queue apply as to any story. Dispatch
  runs from a reaction joining an `available` tuple with the running
  `epic` tuple of its parent, which fires as dependents are projected
  after a merge and again whenever the epic tuple is replaced; from
  `epic_start`, `epic_resume` and `epic_retry`; after the task of an
  ended story of the epic is settled
  (`rat-kingdom-task-settled-functions`, from the timer that closes or
  releases it, outside any transaction); and when `rat-kingdom-mode`
  starts, after reconciling and projecting.
- **Ends.** On each story event (`rat-kingdom-story-event-functions`,
  inside the transaction, before the task is settled) for a story with
  `:epic`: a merged story's task is recorded as merged. A story that
  ends without a merge, moved to a final place by hand or cancelled
  (`story_cancel` now raises a `cancelled` event), has its task added to
  `:held` with the reason before the release can project it, so it is
  not started again until `epic_retry` clears it. So has a task whose
  story could not be started. A story that parks adds to the king's one
  message about it (through `rat-kingdom-king-news-functions`) its task
  and the tasks of the epic waiting on it, directly or through others,
  from the tasks' `:depends-on`. When every task of the epic is closed,
  the epic is `done`, the br epic is closed with "All N tasks merged",
  and the king is told "Epic E (title) is done: N stories merged." An
  epic with a feature branch lands instead (below).
- **Pause, resume, cancel.** `epic_pause` stops dispatch; stories in
  progress carry on. `epic_resume` dispatches again, or lands an epic whose tasks are all
  closed. `epic_cancel` marks
  the epic cancelled first, so that nothing is held or started, then
  cancels each story of it in progress as `story_cancel` does, which
  releases its task, and abandons a landing check. The br epic and its
  tasks are left open, a feature branch is kept and the answer says so,
  and a cancelled epic can be started again.
- **The view.** `status` has an Epics section
  (`rat-kingdom-king-status-functions`) for each running or paused epic:
  its state, merged/total, its stories in progress and where each is,
  the tasks held up behind a stopped story, the held tasks, and how many
  tasks wait on others. Each story's line names its epic, and
  `story_show` gives its task and epic. `epic_show` gives the full table:
  each task's id, title, status, story, agent and what it waits on. For
  an epic with a feature branch, both give the branch, the target it
  lands on, and what the landing waits for: the check, the king's
  review, or the task that puts it right.

**Built: a feature branch per epic** (`rat-kingdom-epic.el`). `epic_start`
with `feature_branch` creates `rk/epic/ID` from the head of the
repository's target, or uses an existing branch of that name if the
target's head is in it (or moves it forward if it is behind with nothing
of its own), and refuses one that has diverged. The record keeps
`:branch` and `:target`, and every story of the epic is started with the
branch as its target (7.3), so the stories merge there after their own
check and review, and the target does not move.

- **Landing.** When every task of such an epic is closed, it becomes
  `landing` instead of `done`. The engine merges the branch into the
  target in a fresh candidate worktree and runs the setup and check
  there, with the code the stories use
  (`rat-kingdom-story-check-candidate`). The outcome is a `checked` tuple
  named by the epic, which a reaction joins with the landing epic.
- **Review.** A check that passes asks the king, through the news: "Epic
  E (title) is ready to land on TARGET: N stories, review with epic_diff
  and give epic_verdict." `epic_diff` gives the branch's commits and its
  combined diff against the target.
- **Pass** moves the target to the checked merge with the same
  compare-and-swap as a story's merge. If the target or the branch moved
  after the check, the epic is checked again, and lands without another
  review if the branch is the one reviewed. Then the epic is `done`, the
  br epic is closed with "Landed on TARGET at SHORTSHA", the king is
  told, and the branch is kept for the user to delete.
- **Fix**, with notes, creates a task in the epic (`--parent`) whose
  description is the notes. The epic goes back to `running`, its landing
  waiting for that task; dispatch starts its story on the branch, and
  once it is merged the epic lands again.
- **A failed check, or a merge that conflicts** because the target moved,
  creates the task "Merge TARGET into the epic branch and fix what
  breaks", with the check's output or the files in conflict, and the epic
  runs again. The task's worker is cut from the epic's branch, merges the
  target in, and its story merges into the branch; then landing retries.
  So neither is a dead end. If the tracker cannot create the task, or the
  candidate cannot be made, the epic is paused and the king told;
  `epic_resume` lands it again.
- **Restarts.** The `landing` state is in the persistent record; an
  interrupted landing check is run again on reconcile (8.4).

Without a feature branch nothing changes: the epic is done when its tasks
are closed.

An epic's foreman (section 9), when it has one, is told of its stories
instead of the king (8.2).

## 11. Integration and publication

Integration follows rk2:

1. Merge the reported commit into a detached candidate worktree.
2. Run the configured check there, after the repository's setup command
   if it has one. A setup that fails fails the check, and says so.
3. Advance the target branch with a compare-and-swap. A target checked out
   elsewhere is refused.
4. Close the task. Write `checked` with what integration itself ran,
   separate from the worker's reported checks.

A failed merge or check keeps the worker's work and the candidate. The
user's checkout, index, stash and hooks are never touched.

Each worktree starts empty of whatever the repository does not commit,
such as installed dependencies. A repository may therefore have a setup
command, run without a shell like the check: in a worker's worktree when
it is made, before the worker starts, and in each candidate before the
check. A worker that replaces another in the same worktree is not set up
again. After a restart, a setup that was running is run again (8.4).

A story's target is its repository's, or its own `:target` (7.3): the
stories of an epic with a feature branch are merged into the epic's
branch this way. That epic then lands on the repository's target as one,
by the same steps: its branch merged into a candidate, the setup and
check run there, and, after the king's `epic_verdict`, the target moved by
compare-and-swap. A conflict or a failed check there becomes a task of
the epic, done on its branch (section 10).

**Built: how work goes into the target** (step 8), `:git :integrate`
(7.3). Steps 1 and 3 above depend on it; the check, the setup and step 4
do not.

- **`merge`**, the default, is today's behaviour: the candidate is
  detached at the target's head and the story's commit is merged with
  `--no-ff` and the message `Merge ID: TITLE` (an epic's: `Merge the epic
  ID: TITLE`).
- **`rebase`** replays the story's commits onto the target in the
  candidate: the candidate is detached at the story's commit and `git
  rebase BASE` runs there, BASE the target's head. Git drops merge
  commits, and commits already in BASE, as it does by default. The
  rebased head is `:head`, a descendant of BASE, so the merge step moves
  the target by fast-forward. A conflict takes the files in conflict
  (`git diff --name-only --diff-filter=U`), runs `git rebase --abort`, and
  fails the check with the reason "rebase conflict" and the files as its
  output. The worker is told: "rebase conflict: your branch no longer
  rebases cleanly onto the target branch. Rebase your branch onto TARGET,
  resolve the conflicts, commit, and finish again. Files in conflict: …".
- **`squash`** makes one commit on the target: the candidate is detached
  at the target's head, `git merge --squash` takes the story's commit,
  and the commit's message is `ID: TITLE`, a blank line, then the
  worker's summary (the token's `:summary`). A conflict fails as for
  `merge`, "merge conflict". A story that changes nothing against the
  target fails the check with the reason "nothing to integrate". For an
  epic, the message is `ID: TITLE` followed by the ids of the tasks it
  merged, one per line.
- **Cleaning up.** After `merge`, the story branch is deleted when it is
  an ancestor of the target's new head, as now. After `rebase` or
  `squash` it is not, so the branch is deleted when its tip is still the
  commit that was checked, the token's `:commit`. Otherwise it is kept,
  since someone has added to it.
- **Staleness** is unchanged: the target must still be at `:base`, or the
  story goes back to its check.
- `rat-kingdom-story-check-candidate` takes the mode, and the squash
  message, besides what it takes now. The same setting applies when an
  epic's feature branch lands, read for the epic's context; the branch
  is kept after landing, as now.
- **Branch names** come from `:git :branch` (7.3).

Publication is a king tool that pushes one named branch to one named
remote, only on the user's explicit request, and writes a receipt.

**Built:** `publish` (repo, branch, remote defaulting to `origin`) runs
`git push REMOTE COMMIT:refs/heads/BRANCH` in Emacs itself, from the
repository's path, with the user's own configuration and credentials. It
never forces; a rejected push returns Git's error. The receipt is a
persistent `published` tuple scoped to the repository, with no owner, so
it outlives every story. The king's instructions and the tool's
description say it may be called only when the user has asked for that
push in the conversation, and that approval does not carry over to the
next push. `M-x rat-kingdom-publish` is the user's own way in.

## 12. Guards

- Role-scoped tools replace rk2's role checks.
- No managed session can push. Built in three layers, for workers and the
  king alike, all in rat-kingdom-agent-shell.el. Claude sessions get all
  three. Codex sessions get only the first, which
  `rat-kingdom-agent-shell--guard` applies to every agent kind in the
  same way (section 8.5):
  1. **Environment.** The agent's client is started with Git
     configuration in its environment: `GIT_CONFIG_COUNT` and
     `GIT_CONFIG_KEY_n`/`GIT_CONFIG_VALUE_n` pairs (Git 2.31 or later),
     numbered after any the environment already has, setting
     `url.rat-kingdom-refuses-to-push::<prefix>.pushInsteadOf` for every
     prefix, the empty one included. Every push URL becomes one for a
     remote helper that does not exist, so the push fails with that name,
     `--no-verify` or not, while fetches still work. It is set through
     the ACP client's own environment variables, so it applies whenever
     the client's process starts. It works in every permission mode,
     auto and bypass included, and in Codex's full-access mode. Nothing is written to `.git/config`, hooks
     or the user's global configuration, so the user's own pushes are
     unaffected. `GH_PROMPT_DISABLED=1` and `RAT_KINGDOM_RUN=<run id>` are
     set too. Git does not rewrite a remote with an explicit `pushurl`,
     and an agent that sets out to unset the variables can; the next two
     layers stand in those cases.
  2. **Claude's deny rules.** The session meta carries
     `claudeCode.options.disallowedTools` with `Bash(git push:*)`,
     `Bash(git -C * push:*)` and `Bash(gh:*)`. Claude's ACP adapter passes
     them to Claude Code, which applies deny rules in every mode.
  3. **Emacs.** rat-kingdom's permission responder refuses any request to
     run a command that pushes (`git … push` or `send-pack`, after `&&`,
     in a pipe, `$(…)` or `sh -c`) or runs `gh`, before the user's own
     responder sees it. This applies only when the mode asks for
     permission.

  rk2's session-only pre-push hook is not used: `--no-verify` skips it.

  **For Codex the environment is the only layer.** The session meta is
  the same for every kind, so a Codex session carries the Claude deny
  rules too. codex-acp ignores `_meta.claudeCode`, and keeping one guard
  for all kinds is simpler than leaving them out. In full-access mode,
  with approval `never`, Codex sends no permission requests, so layer 3
  never fires. This leaves Codex workers uncovered in three cases:
  - a remote with an explicit `pushurl`, which Git does not rewrite;
  - `gh`, which only has `GH_PROMPT_DISABLED`;
  - an agent that unsets the variables on purpose.

  Codex passes its environment to the commands it runs according to
  `shell_environment_policy` in the user's Codex config. With codex-cli
  0.166.0 and no such setting, every variable is passed, the
  `GIT_CONFIG_*` ones included. This was checked with `codex sandbox --
  env`, which applies the policy. Two settings change that:
  - `inherit = "core"` or `"none"` drops `GIT_CONFIG_COUNT`, and with it
    the block.
  - `ignore_default_excludes = false` drops only the `GIT_CONFIG_KEY_n`
    variables, whose names contain KEY. Git then refuses to run at all
    ("missing config key"), so the block fails closed.

  rat-kingdom does not check the user's Codex config.
- **The user's own pushes of rat-kingdom's branches** are guarded by a
  fourth layer, in rat-kingdom-git.el, so that the user does not push
  them by accident from their checkout with `git push` or magit. They go
  out only through `publish`, when the user asks.
  4. **pushRemote.** For each branch rat-kingdom makes, it sets
     `branch.<name>.pushRemote` to `rat-kingdom-refuses-to-push::<name>`
     in the repository's own Git configuration, in the common Git
     directory (`rat-kingdom-git-push-guard`). The branches are the
     target, at `repo_add` (also when the target was already there) and
     each `repo_sync`, every worker branch a story cuts, and an epic's
     feature branch. Candidate worktrees are detached and need none. A
     `git push` that names no remote on such a branch goes to that URL,
     whatever `push.default` says, and fails with an error that names
     rat-kingdom. A push that names its remote, such as `git push origin
     rk/integration`, is unaffected; `publish` pushes that way, so it
     still works. Nothing is committed and no hook is installed. When
     Git deletes a branch, it deletes the branch's configuration too.

  The configuration sub-key `:git :push-guard`, default t, may be set at
  the global and repo layers only. With nil, rat-kingdom sets no guard
  and takes the guard off every branch that has it; with t, it guards
  the target, every `rats/*` branch and the branch of every story and
  epic (`rat-kingdom-config-push-guard-apply`). It is applied to every
  repository when `rat-kingdom-mode` turns on, and at `config_set`, as
  `:track` is. A `pushRemote` that is not the guard is never changed,
  and the user's other branches are never touched.
- ACP permission requests pass through Emacs, so a policy function can
  refuse a tool call before it runs. This applies only when the session
  mode asks for permission.

Whether workers run in Claude's auto mode, or Codex in full access, is no
longer a question for pushing: the environment block holds in any mode. It remains one for
other tool calls, which in auto mode do not reach Emacs.

## 13. Ingress and ambient agents

Everything from outside becomes an `event` tuple.

| Source | How |
|---|---|
| timers | Emacs timers while it is running |
| cron, streams | a small Go sidecar using ganso writes rows into the same SQLite file |
| webhooks | the sidecar's HTTP listener; Bento can post to it |

An ambient agent is a reaction on an `event` pattern whose body starts a
run with the event's bindings in its brief. Events that arrive while Emacs
is down wait as tuples and are handled at startup. Affine expiry stops a
backlog of stale ticks from firing all at once.

## 14. UI

- **Dashboard**: deathless cards gain the story, its place and the run
  state. New sections list stuck tokens, review requests and blocked runs,
  each with its actions as buttons.
- **Review**: magit for the diff, a2ui for a verdict form.
- **Docs**: a new draft opens in the main pane.
- **Commands**: a transient menu for start, tell, move, integrate,
  reconcile, and stop everything.

If Emacs becomes slow with many sessions, runs move behind a supervisor
process that holds the ACP connections, and Emacs attaches to it. The
space, reactions and workflows do not change.

### 14.1 a2ui surfaces

deathless stays the per-session view. a2ui surfaces show the factory: the
stories, the space and the rules. They come in two kinds.

- **Engine-drawn**: rat-kingdom renders the surface from elisp and binds its data
  model to queries of the space. A change hook updates only the data paths
  that changed. No model is involved and no tokens are spent. A button
  press writes a tuple or calls an rat-kingdom command directly.
- **King-drawn**: the king draws a surface when it wants a decision from
  the user, with the a2ui tools it already has.

Because a surface is data, the king can also recall and adapt an
engine-drawn one, and both kinds can be saved in the repo's `.a2ui`
folder.

a2ui has tables with row actions, bars and sparklines, diffs with accept
and reject, folds, tabs, pickers, progress bars and status tones. It has
no graph component, so a workflow is shown as rows in places, not as a
drawn net.

**Checked, 2026-11-13:** a surface is driven from elisp with no agent
behind it, as `examples/k8s-rollout.el` in a2ui.el does: a session from
`a2ui-session-create` whose `:send-action-fn` receives each button press
as an A2UI action message, `a2ui-vui-attach` to render it,
`a2ui-apply-message` for createSurface, updateComponents and
updateDataModel, and `a2ui-show-surface` to display it through
`a2ui-vui-display-action`. A button's action carries in its context the
data paths it names, so the handler gets what the user entered without
reading the surface. a2ui stays an optional dependency: it is loaded
when a surface is first shown.

**Built: the epic plan (4)**, in `rat-kingdom-plan.el`. The king calls
`epic_propose` with the arguments `epic_create` takes. The plan is
checked as `epic_create` checks it and shown in the surface "Epic plan:
TITLE", replacing one of that title; the tool returns at once, and says
that a2ui is missing if it is. The surface has the repository, title
and description as Markdown; a Section per wave (wave 1 the stories
with no dependencies, wave N those whose dependencies are all in
earlier waves), with a Card per story holding an include CheckBox, its
key, its title and description as TextFields, what it depends on, and
Pickers for its agent and workflow (the workflow sets the review mode),
the proposed values selected and blank meaning the default; the
options "start right away" (off), "feature branch: land the epic as one
unit" (off, with a note that it applies when the epic is started) and
"max parallel" (empty for no limit); and Approve, Cancel, and Send back with a notes field. Nothing
is written until Approve: it drops the stories left out, refuses with
the reason shown on the surface if a kept story depends on one left out
or the edited plan fails `rat-kingdom-epic-check`, then calls
`rat-kingdom-epic-create` and, if asked, `rat-kingdom-epic-start`,
passing it the feature branch option, and shows the epic's id and
tasks. A feature branch ticked without "start right away" starts
nothing; the king is told the user wants one, to pass `feature_branch`
to `epic_start` when it starts the epic. Every outcome (approved with what was
created, whether it started and whether with a feature branch, sent back with the notes, dismissed by
Cancel or by deleting the surface, or the tracker failing partway) is a
`message` to the king, delivered between its turns. A plan the user
started from the surface counts as their approval to run it. The
surface is shown off the selected window, so it never takes the place
of the buffer the user is typing in. Not yet: keeping an open plan
across an Emacs restart.

**Built: the story board**, in `rat-kingdom-board.el`, a first form of
the factory floor (1). `rat-kingdom-board`, or the king's `board_show`,
shows the surface "Story board" in the main window: the selected window
of the selected frame takes it in place of its buffer, unless that is a
side or dedicated window, when a2ui's main window does; `q` buries it.
Its columns are phases shared by every workflow: Queued, Working,
Checking, Review, Merging, Done and Stopped. A story's column comes from
its token and its workflow: waiting for a free worker, or at a spawn
step whose worker has not started, is Queued; a final place, or a story
that ended, is Done; parked, at the failure place, or cancelled is
Stopped; otherwise the place, the step's name or the step's kind is
looked up in `rat-kingdom-board-phases` (by default spawn and child
workflow steps Working, check and run Checking, review and gate Review,
merge Merging). Done and Stopped keep stories that ended in the last
`rat-kingdom-board-done-hours`, read from the archive, and a child
story is not shown. A card has the id, the worker's display name (its
run's `:name` as Name-hex, else the run id), repository, epic, title,
agent and time at its place, in a tone when it waits for review, is
stopped, stuck or running long, and buttons that open the worker's
buffer, show `story_show` and `story_diff` text, and cancel after
asking; no verdict. A picker limits it to one repository and a check
box hides Done and Stopped. Cards live at `/cards/COLUMN/ID`.
`rat-kingdom-space-change-functions` marks the stories a change to a
`story`, `run` or `stuck` tuple, or a sweep, touches; at most every
half second the marked cards are made again and only those that
changed are sent, a removal from the old column, the card in the new
one and the column's count. A timer refreshes ages each minute; nothing
reads git. Opening it builds it from the space, so it is right after a
restart. a2ui lays a Row out in `a2ui-vui-width` characters and has no
fixed-width columns, so a window with `rat-kingdom-board-column-width`
characters for every column shown gets a Row of Columns, with that
width made local to the board's buffer, and a narrower one, the usual
case, a Section per column titled with its count.

| # | Surface | Shows | Actions | Kind |
|---|---|---|---|---|
| 1 | Factory floor (first form built: the story board) | one table per epic: each story's place, worker, time in place (warning tone near its timeout), check result; a progress bar per epic | open the shell, tell, move, show diff | engine |
| 2 | Attention queue | everything waiting on a person: review requests, stuck tokens, blocked runs, failed checks, oldest first | verdict, resume, move to a picked place, discard | engine |
| 3 | Review card | one `review`: the worker's summary, what integration verified beside what the worker reported, the diff | pass, or fix with notes; writes a `verdict` tuple | engine |
| 4 | Epic plan (built) | the repository, title and description; the king's proposed stories grouped into waves, each with an include checkbox, its key, editable title and description, what it depends on, and pickers for its agent and its workflow (which sets the review mode); options to start right away, to give the epic a feature branch (it lands as one unit, after one check and `epic_verdict`) and to limit stories in parallel | approve (create, and start if asked, with a feature branch if ticked), send back with notes, cancel | engine, opened by the king's `epic_propose` |
| 5 | Design doc review | the doc, its status, the facts it cites, a notes field | revise (a message to its author), approve and ask the king for an epic | engine |
| 6 | Story timeline | one story's history from the operations log: place changes, attempts, messages, checks, verdicts | open any attempt's transcript, move the token | engine |
| 7 | Policy editor | the effective configuration for a repo or epic, with the layer each value came from | change review mode, workflow, worker limit, commands; validated before it is saved | engine or king |
| 8 | Space inspector | live tuple counts by category with a sparkline of writes and takes; tuples matching a typed pattern; the tail of the operations log | archive a tuple, write a tuple by hand | engine |
| 9 | Reactions | each reaction: its pattern, times fired, last fired, last error; each workflow's steps and the tokens waiting at each | enable, disable, fire once against a picked tuple | engine |
| 10 | Ingress | event sources, last event, waiting events, the ambient runs each started | enable, disable, fire a test event | engine |
| 11 | Throughput | per epic: stories finished per day, time spent in each place as bars, fix loops per story, tokens and cost per story | none; read-only | engine |

Surfaces 1 to 3 are the working set and are built with the dashboard. The
attention queue and the review card matter most: they let the user clear
reviews and stuck work without spending a king turn. Surface 4 is the
centre of the research → epic → waves loop and arrives with the king.
Surfaces 8 and 9 are the debugging tools for the generative layer and are
worth building early, in a plain form, alongside the space itself.
Surface 11 answers where the factory is slow, most often whether stories
wait longer for review than for implementation.

## 15. Build order

1. **Space** (built: `rat-kingdom-space.el`, `rat-kingdom-inspector.el`):
   SQLite schema, `out`/`in`/`rd`/`scan`, patterns, modalities, owner
   sweep to archive, operations log. Tested without agents. The inspector
   is surface 8 in a plain form: a tabulated list, not yet a2ui.
2. **Reactions** (built: `rat-kingdom-reaction.el`): definition, joins,
   one transaction per firing, recorded failures, once-per-match memory,
   scheduling after commit, external-write polling.
3. **One story, by hand** (built, and run once with a real agent:
   `rat-kingdom-git.el`, `rat-kingdom-mcp.el`, `rat-kingdom-run.el`,
   `rat-kingdom-agent-shell.el`, `rat-kingdom-story.el`): repositories as
   `repo` tuples, a worktree per story, one rat through agent-shell with
   `finish` and `block`, the tool endpoint with a token per run, and
   integration with a check. Tested with real Git and a backend that
   starts no agent. Its hand-written reactions were replaced in step 4.
4. **Workflow engine** (built: `rat-kingdom-workflow.el`,
   `rat-kingdom-story.el`): workflows as validated data, `story` and
   `story-lite`, one token per story, review as a step, loops back to a
   worker, timeouts, a watchdog, moving and cancelling by hand.
5. **Recovery** (built, tested without killing a real Emacs): reconcile on
   startup; an interrupted worker is replaced in the same worktree, an
   interrupted check is run again, the king's session is taken up again.
6. **King and tasks** (the king is built, not yet run with a real agent:
   `rat-kingdom-king.el`; the task adapter interface, its `br` adapter
   and the `available` projection are built: `rat-kingdom-task.el`):
   king role and tools, news delivered between turns, tasks behind an
   adapter, tested with a fake `br`. br is required: registration and mode
   start create a missing workspace, kept out of Git through
   `info/exclude`. Ready tasks are projected as
   `available` when `rat-kingdom-mode` starts and on
   `rat-kingdom-tasks-refresh`; a story started from a task takes its
   tuple and claims it, and merging closes it and projects its
   dependents, tested with an in-memory adapter. The king's `status`
   projects and lists the available tasks, with each one's epic and agent,
   and its `story_start` takes a `task`, filling in the title and
   description from it, and the agent and workflow from its labels. The
   king plans work with `task_create` and `epic_create`
   (`rat-kingdom-epic.el`): an epic and its tasks with dependencies, checked
   in full before anything is written, started by nothing. Its instructions
   list its tools from those defined. Running an epic is built: an `epic`
   tuple per epic, `epic_start`, `epic_pause`, `epic_resume`,
   `epic_cancel`, `epic_retry` and `epic_show`, dispatch of ready tasks
   by the engine as their dependencies merge, held tasks, holdups told to
   the king, the Epics section of `status`, and dispatch resumed after a
   restart, tested with the in-memory adapter. The epic plan surface (4)
   is built (`rat-kingdom-plan.el`): the king's `epic_propose` shows the
   plan in a2ui, where the user edits it and approves it, sends it back
   or dismisses it, and the king is told; nothing is created before
   Approve. Tested with a2ui stubbed, and with the real a2ui where it can
   be loaded. A feature branch per epic is built: `epic_start` with
   `feature_branch`, stories with a target of their own, landing through
   one check and the king's `epic_verdict` after `epic_diff`, conflicts
   and failed checks returned as tasks on the epic's branch, and an
   interrupted landing check run again on reconcile, tested with real
   Git. The foreman is built (`rat-kingdom-foreman.el`): `foreman_start`
   and `foreman_stop`, news of an epic's stories routed to it through the
   king's delivery, its tools limited to its epic, `report`, its end with
   the epic's, and its session taken up again on reconcile, tested with
   the backend that starts no agent. The consul is built
   (`rat-kingdom-consul.el`): `consul_start` and `consul_dismiss`, its own
   worktree and branch, its work made a story on dismissal, and its
   session taken up again on reconcile. Every rat has a name from
   `rat-kingdom-rat-names`, shown with its id.

   **Facts** (built: `rat-kingdom-fact.el`): the worker's `note_fact`,
   facts in every worker's brief through
   `rat-kingdom-story-brief-functions`, and the king's `query` and
   `fact_forget`.
7. **Configuration** (7.3): `.eld` files read and never evaluated, the
   layers (defaults from the existing user options, global file,
   registration, repo file, epic and task `policy` tuples) merged key by
   key with the layer of each value, ignored files reported in `status`,
   `:track` kept in `info/exclude`, workflow files global and per repo,
   and the king's `config_show` and validated `config_set`. Mixins and
   aspects are step 8.
8. **Workflow composition** (7.1, 7.3, 8.3, 9 and 11). Built, all of it:
   - step kinds: `:spawn` with `:brief`, `:check` with named commands,
     `:run`, `:gate` and `:workflow` with child stories
     (`rat-kingdom-workflow.el`, `rat-kingdom-story.el`);
   - mixins and aspects, with `:entry`, expanded at lookup, the built-in
     `no-review` and `tdd`, mixin files global and per repo, the
     `:mixins` key, and the expansions in `workflow_list`
     (`rat-kingdom-workflow.el`, `rat-kingdom-config.el`);
   - the `research` workflow, the `researcher` role, `doc` tuples, docs in
     every worker's brief, `write_doc` and `read_doc`, and the king's
     `doc_list`, `doc_show` and `doc_forget` (`rat-kingdom-doc.el`), and
     `story_signal` (`rat-kingdom-king.el`);
   - git options: the `:git` key with `:branch` and `:integrate` (`merge`,
     `rebase`, `squash`), for stories and for an epic's landing
     (`rat-kingdom-config.el`, `rat-kingdom-story.el`,
     `rat-kingdom-epic.el`);
   - `repo_add`'s and `rat-kingdom-add-repo`'s `mixins` and `git`
     arguments for the registration layer.
9. **Dashboard** additions with the factory floor, attention queue and
   review card (surfaces 1 to 3), then the remaining surfaces.
10. **Ingress** sidecar and ambient agents.

Tests use scripted fake agents and disposable repositories, as rk2's
acceptance suite does. No test calls a model, and no test pushes anywhere
but a disposable bare repository.

## 16. Open questions

1. Do workers run in auto mode? For pushing this is settled (section 12):
   the environment block and the deny rules hold in any mode.
2. Does a passing check on a `story-lite` story integrate with no review
   at all, or does the user confirm the first few per repo?
3. When is a foreman worth starting, given that waves advance on their
   own? Answered for now: the king starts one when the user asks, or when
   an epic is big, with `foreman_start` or `foreman` on `epic_start`. There
   is no automatic policy yet; an epic's policy could ask for one once
   configuration (step 7) exists.
4. Where do design docs live: in the repo, or in the project's org-roam
   hub? Answered: in the space, as `doc` tuples scoped to the repo with
   no owner, written by the researcher's `write_doc` and approved by a
   review (7.1). A doc is not a file in the repo; a story that should
   commit one does so as code.
5. Does the king see every `fact`, or only those a reaction promotes?
   Today it can `query` every one, and is told none unasked.
6. The package layout.
7. Should a `:before` step catch every way into its place? Answered by
   `:entry` (7.1): by default it does, and with `:entry start` it catches
   only the start. `tdd` uses `:entry start`, so its tests worker runs
   once and fixes loop straight back to `implement`.
