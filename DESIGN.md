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
with the repo as owner.

Each `out` and `in` is also appended to an operations log table. That log
is the audit trail and can be replayed.

### 5.4 Vocabulary (first cut)

| Category | Modality | Written by | Meaning |
|---|---|---|---|
| `story` | linear | engine | the token: `(story S :at PLACE :workflow W :task T)` |
| `available` | linear | task adapter | a ready task with no story yet |
| `run` | persistent | engine | a live or stopped agent run and its state |
| `result` | persistent | worker `finish` | commit, summary, reported checks |
| `blocked` | persistent | worker `block` | why the worker stopped |
| `checked` | persistent | engine | what the engine itself verified |
| `review` | linear | engine | a request for the king or user to judge |
| `verdict` | linear | king or user | `pass` or `fix` with notes |
| `message` | linear | anyone | text for one run, delivered at a turn boundary |
| `doc` | persistent | research worker | a design or research document and its status |
| `fact` | persistent | workers | something learned about the repo |
| `policy` | persistent | king | an epic or task override of configuration |
| `event` | affine | ingress, engine | something happened outside or inside |
| `stuck` | persistent | watchdog | a token that cannot move |
| `repo` | persistent | user | a registered repository: path, target branch, check |

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
The step kinds are `:spawn`, `:check`, `:review` and `:merge`, each with
named outcomes that lead to places; an outcome left out leads to the
workflow's failure place. And there are no mixins or aspects yet. The two
workflows that exist are `story` and `story-lite`.

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

The sketch this grew from, kept for the parts not yet built:

```elisp
(workflow story
  :places (ready implementing checking review integrating done blocked)
  :steps ((implement :from ready       :spawn rat          :to checking)
          (check     :from checking    :run (lint test)    :pass review :fail implementing)
          (review    :from review      :by king            :pass integrating :fix implementing)
          (integrate :from integrating :merge :into target :to done))
  :mixins (git-feature-branch)
  :aspects ((:around check :timeout "15m")
            (:after implement :run (format))))
```

Step kinds, first cut: `:spawn` a role, `:run` named commands, `:by` a
judge (king or user), `:merge`, `:gate` (wait for a tuple or a timer),
`:workflow` (run a child workflow).

- **Mixins** are named fragments merged into a workflow: `no-review`,
  `tdd`, `git-feature-branch`.
- **Aspects** add steps before, after or around every step matching a
  pattern.
- **Named commands** such as `lint` and `test` resolve to argument arrays
  in configuration. They run without a shell.

Starting workflows: `story`, `story-lite` (no review), `research` (writes a
doc, no code), `epic` (dispatches child stories in dependency order).

### 7.2 Not getting stuck

- State is one token, never derived from several tuples.
- A step that cannot be begun sends the token to the failure place with
  the reason. An error never leaves a token half moved or waiting on a
  failed reaction.
- Steps have timeouts: by default two hours for a worker and thirty
  minutes for a check, and none for a review.
- At most `rat-kingdom-story-max-workers` workers (three by default) run
  at once. A story whose worker would go over waits in its step for "a
  free worker", with no worktree, run or attempt, and its step's time
  starts only when the worker does. The queue is served oldest first by a
  reaction on every change to a run, when a story is archived, by the
  watchdog and by reconciling, so it cannot wait while a worker is free.
- A watchdog, once a minute, writes `stuck` for a token whose step has run
  past its time, whose check is not running, whose worker's record is
  gone, or which no reaction has picked up. The king is told.
- The user or king can move any token to any place by hand. Its worker is
  stopped, a running check is abandoned, and no file is touched. Each move
  is logged with who made it.
- A story can be cancelled: it is archived, and its worktree and branch
  are kept.

All of this is built.

### 7.3 Configuration layers

Most specific wins: global → repo → epic → task.

| Layer | Where | Who edits |
|---|---|---|
| global | `~/.emacs.d/rat-kingdom/config.eld`, `~/.emacs.d/rat-kingdom/workflows/` | user, or king through a tool |
| repo | `<repo>/.rk/config.eld`, `<repo>/.rk/workflows/` | same; versioned with the code |
| epic, task | `policy` tuples owned by the epic or task | king |

Configuration covers: the default workflow, command arrays (`lint`,
`test`, `format`, `check`), git discipline (branch naming, target branch,
merge or rebase, feature branch per epic), review mode (`king`, `user`,
`none`), worker limit, and the agent command per role.

The king changes configuration through a tool that validates the merged
result and refuses a change that leaves a workflow invalid: an unknown
place, a step with no exit, an undefined command. The king never writes
elisp.

## 8. Runs

### 8.1 What a run is

A run is one agent session doing one job: an agent-shell buffer over ACP, a
worktree, a branch, and a `run` tuple. A worker does one task per lifetime.

Run states, kept distinct as in rk2: `starting`, `working`, `ready`,
`blocked`, `stopped`, `exited` (its session ended before it reported) and
`interrupted` (Emacs stopped while it worked). A run that cannot be
started is `exited` with the error.

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

**Built for the king only.** Messages waiting for the king are given to it
together, as one prompt, when it is between turns and the user has nothing
typed but unsent in its buffer. Otherwise another try is made twenty
seconds later and at the end of its next turn. A message is removed after
it is sent, so a crash between the two repeats it and never loses it.
Messages to workers are not built; a worker hears from the king only
through the reason a story carries to its next worker.

### 8.3 The brief

When a run starts, the engine builds its prompt from: the role's
instructions, the task, and a query of the space for facts, docs and
policy in that task's repo and epic. This is how a research worker's
findings reach a worker started days later.

### 8.4 Recovery

**Built** (`rat-kingdom-story-reconcile`, run when `rat-kingdom-mode` is
turned on and by `M-x rat-kingdom-reconcile`), and tested by closing the
space and discarding everything held in memory, not yet by killing a real
Emacs. A run recorded as `working` with no agent in this Emacs becomes
`interrupted`, and a reaction gives its story a new worker in the same
worktree, with a fresh session and a prompt that says what happened. That
worker takes its old place ahead of the queue for a free worker, which is
kept and served once the replaced workers have started. A
check that was running is run again. The king takes up its earlier
session by its id. Sessions that end while Emacs is exiting are not
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
| king | long-lived, global, no worktree | built: `status` (with the tracker tasks available), `repo_add`, `repo_sync`, `workflow_list`, `story_start` (optionally from a `task`), `story_show`, `story_diff`, `story_move`, `story_cancel`, `verdict`. Planned: `task_create`, `epic_create`, `tell`, `query`, `config_set`, `publish` |
| rat (worker) | one task | `finish`, `block`, `note_fact`, `inbox` |
| researcher | one task | `finish_doc`, `note_fact`, `block` |
| foreman | one epic, optional | `story_start`, `tell`, `verdict`, `query`, limited to its epic |
| ambient | one event | set by the reaction that starts it |

The king's chores from imp and rk2 (run the check, merge, close the task,
clean the worktree, notice a finished worker) are reactions. Review
requests reach the king as messages at a turn boundary and never interrupt
a conversation with the user.

## 10. Tasks

Tasks sit behind an adapter:

```
ready(repo) → tasks      show(id)      create(...)      close(id, reason)
claim(id, run)           release(id)   comment(id, text)
```

The first adapter is Rust Beads (`br`), one canonical workspace per repo,
as in rk2. A tuplespace-native adapter can follow.

The adapter projects ready tasks into the space as `available` tuples.
When integration closes a task, its dependents become ready and are
projected in turn. That is how an epic's waves advance without a foreman.

## 11. Integration and publication

Integration follows rk2:

1. Merge the reported commit into a detached candidate worktree.
2. Run the configured check there.
3. Advance the target branch with a compare-and-swap. A target checked out
   elsewhere is refused.
4. Close the task. Write `checked` with what integration itself ran,
   separate from the worker's reported checks.

A failed merge or check keeps the worker's work and the candidate. The
user's checkout, index, stash and hooks are never touched.

Publication is a king tool that pushes one named branch to one named
remote, only on the user's explicit request, and writes a receipt.

## 12. Guards

- Role-scoped tools replace rk2's role checks.
- A session-only pre-push hook refuses pushes from managed sessions, as in
  rk2.
- ACP permission requests pass through Emacs, so a policy function can
  refuse a tool call before it runs. This applies only when the session
  mode asks for permission.

**Open:** whether workers run in Claude's auto mode. In auto mode fewer
permission requests reach Emacs, so the pre-push hook is the only push
guard.

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

**To verify:** the elisp entry points for driving a surface and receiving
its actions without an agent. `examples/k8s-rollout.el` in a2ui.el does
this with a scripted agent.

| # | Surface | Shows | Actions | Kind |
|---|---|---|---|---|
| 1 | Factory floor | one table per epic: each story's place, worker, time in place (warning tone near its timeout), check result; a progress bar per epic | open the shell, tell, move, show diff | engine |
| 2 | Attention queue | everything waiting on a person: review requests, stuck tokens, blocked runs, failed checks, oldest first | verdict, resume, move to a picked place, discard | engine |
| 3 | Review card | one `review`: the worker's summary, what integration verified beside what the worker reported, the diff | pass, or fix with notes; writes a `verdict` tuple | engine |
| 4 | Epic plan | the king's proposed stories with dependencies, grouped into waves; per story a checkbox, workflow and review mode | edit, approve and dispatch, send back with notes | king |
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
   adapter, tested with a fake `br`. Ready tasks are projected as
   `available` when `rat-kingdom-mode` starts and on
   `rat-kingdom-tasks-refresh`; a story started from a task takes its
   tuple and claims it, and merging closes it and projects its
   dependents, tested with an in-memory adapter. The king's `status`
   projects and lists the available tasks, and its `story_start` takes a
   `task`, filling in the title and description from it. Still to come: epic
   waves and the epic plan surface (4).
7. **Configuration**: layers, mixins, aspects, validated `config_set`.
8. **Dashboard** additions with the factory floor, attention queue and
   review card (surfaces 1 to 3), then the **research** workflow, docs and
   the remaining surfaces.
9. **Ingress** sidecar and ambient agents.

Tests use scripted fake agents and disposable repositories, as rk2's
acceptance suite does. No test calls a model or pushes.

## 16. Open questions

1. Do workers run in auto mode, and if so is the pre-push hook enough?
2. Does a passing check on a `story-lite` story integrate with no review
   at all, or does the user confirm the first few per repo?
3. When is a foreman worth starting, given that waves advance on their
   own? Proposal: only when the epic's policy asks for one.
4. Where do design docs live: in the repo, or in the project's org-roam
   hub?
5. Does the king see every `fact`, or only those a reaction promotes?
6. The package layout.
