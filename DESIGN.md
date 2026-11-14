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
removes a wrong one with `fact_forget`, which retracts it.

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
| `setup` | persistent | engine | how a new worktree's setup command came out |
| `review` | linear | engine | a request for the king or user to judge |
| `verdict` | linear | king or user | `pass` or `fix` with notes |
| `message` | linear | engine, king `tell` | text for the king, or for a story's working run, delivered at a turn boundary |
| `doc` | persistent | research worker | a design or research document and its status |
| `fact` | persistent | workers | something learned about the repo |
| `policy` | persistent | king | an epic or task override of configuration |
| `event` | affine | ingress, engine | something happened outside or inside |
| `stuck` | persistent | watchdog | a token that cannot move |
| `repo` | persistent | user | a registered repository: path, target branch, check, setup |
| `published` | persistent | king `publish`, user | a push receipt: repo (scope), branch, remote and URL, old and new remote commit, actor, time |
| `epic` | persistent | king's epic tools, engine | a running epic, scoped to its repo and named by its br id: `:state` (`running`, `paused`, `done`, `cancelled`), `:title`, `:max-parallel`, `:held` (tasks not to be restarted by themselves, with reasons), `:merged`, `:started`, `:finished`; always replaced whole, in one transaction |

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
doc, no code), `epic` (dispatches child stories in dependency order;
built instead as dispatch by reactions on an `epic` tuple, section 10).

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

**Built for the king** (`rat-kingdom-king.el`). Messages waiting for the
king are given to it together, as one prompt, when it is between turns and
the user has nothing typed but unsent in its buffer. Otherwise another try
is made twenty seconds later and at the end of its next turn. A message is
removed after it is sent, so a crash between the two repeats it and never
loses it.

**Built for workers** (`rat-kingdom-message.el`). The king's `tell`
writes a linear `message` tuple scoped to the story's repo, owned by the
story so that it is archived with it, with the payload `:to-story STORY
:from FROM :text TEXT`. FROM is `king`; `rat-kingdom-message-tell` takes
another, for the foreman to come. Telling an unknown or finished story,
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
another after it: the story's waiting messages (8.2). Docs and
policy are not in the brief yet.

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
session by its id. Running epics are dispatched again once the tasks are
projected (section 10). Sessions that end while Emacs is exiting are not
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
| king | long-lived, global, no worktree | built: `status` (with the tracker tasks available, each with its epic and agent), `repo_add`, `repo_sync`, `workflow_list`, `story_start` (optionally from a `task`, with an `agent`; a task's `rk-agent:` and `rk-workflow:` labels are the defaults), `story_show`, `story_diff`, `story_move`, `story_cancel`, `verdict`, `publish`, `query`, `fact_forget`, `task_create`, `epic_create`, `epic_start`, `epic_pause`, `epic_resume`, `epic_cancel`, `epic_retry`, `epic_show` (section 10), `tell`. Planned: `config_set` |
| rat (worker) | one task | built: `finish`, `block`, `note_fact`, `inbox` |
| researcher | one task | `finish_doc`, `note_fact`, `block` |
| foreman | one epic, optional | `story_start`, `tell`, `verdict`, `query`, limited to its epic |
| ambient | one event | set by the reaction that starts it |

The king's instructions list its tools by name, generated from the tools
defined for the role `king` (`{tools}` in `rat-kingdom-king-instructions`),
so a tool added later is listed without editing them. A changed list
changes the king's fingerprint, and a reload restarts it in place.

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
- A `.beads` that already exists is left alone, tracked, ignored or
  neither.
- Otherwise `br init --prefix PREFIX` runs in the checkout, and `br config
  get issue_prefix` must then answer PREFIX, since a user-level br
  configuration once overrode it. PREFIX is the repository's
  `:task-prefix`, set through `repo_add` or `rat-kingdom-add-repo`, or else
  its name. A prefix br rejects is reported with br's message; no other is
  tried.
- The new workspace is untracked: `/.beads/` is added, once, to
  `info/exclude` in the repository's common Git directory, never to
  `.gitignore`, and `git status --porcelain` must then show nothing under
  `.beads`. `rat-kingdom-task-br-untracked` set to nil leaves it to be
  tracked instead.
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
  `:epic`. `rat-kingdom-story-start` refuses a task that already has a
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
  and the king is told "Epic E (title) is done: N stories merged."
- **Pause, resume, cancel.** `epic_pause` stops dispatch; stories in
  progress carry on. `epic_resume` dispatches again. `epic_cancel` marks
  the epic cancelled first, so that nothing is held or started, then
  cancels each story of it in progress as `story_cancel` does, which
  releases its task. The br epic and its tasks are left open, and a
  cancelled epic can be started again.
- **The view.** `status` has an Epics section
  (`rat-kingdom-king-status-functions`) for each running or paused epic:
  its state, merged/total, its stories in progress and where each is,
  the tasks held up behind a stopped story, the held tasks, and how many
  tasks wait on others. Each story's line names its epic, and
  `story_show` gives its task and epic. `epic_show` gives the full table:
  each task's id, title, status, story, agent and what it waits on.

Not built yet: a feature branch per epic, a foreman, the epic plan
surface.

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
   restart, tested with the in-memory adapter. Still to come: feature
   branches per epic, the foreman, and the epic plan surface (4).

   **Facts** (built: `rat-kingdom-fact.el`): the worker's `note_fact`,
   facts in every worker's brief through
   `rat-kingdom-story-brief-functions`, and the king's `query` and
   `fact_forget`.
7. **Configuration**: layers, mixins, aspects, validated `config_set`.
8. **Dashboard** additions with the factory floor, attention queue and
   review card (surfaces 1 to 3), then the **research** workflow, docs and
   the remaining surfaces.
9. **Ingress** sidecar and ambient agents.

Tests use scripted fake agents and disposable repositories, as rk2's
acceptance suite does. No test calls a model, and no test pushes anywhere
but a disposable bare repository.

## 16. Open questions

1. Do workers run in auto mode? For pushing this is settled (section 12):
   the environment block and the deny rules hold in any mode.
2. Does a passing check on a `story-lite` story integrate with no review
   at all, or does the user confirm the first few per repo?
3. When is a foreman worth starting, given that waves advance on their
   own? Proposal: only when the epic's policy asks for one.
4. Where do design docs live: in the repo, or in the project's org-roam
   hub?
5. Does the king see every `fact`, or only those a reaction promotes?
   Today it can `query` every one, and is told none unasked.
6. The package layout.
