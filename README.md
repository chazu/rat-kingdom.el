# rat-kingdom

Swarm orchestration for coding agents, inside Emacs. A king you talk to,
workers in their own Git worktrees, and a tuplespace they coordinate
through. See [DESIGN.md](DESIGN.md).

**Status:** early, and usable for one story at a time or a few in
parallel. You talk to a king; it starts stories; each story follows a
workflow from a worker through a check and a review to a merge into an
integration branch; work cut off by an Emacs restart is recovered. Tasks
come from a br (Rust Beads) workspace in each repository, and the king can
plan an epic there as tasks with dependencies. An epic's ready tasks are
not yet started on their own, and there is no research workflow yet. The
path through real agents has been run once for a worker and not yet for
the king.

## Using it

You need [agent-shell](https://github.com/xenodium/agent-shell) set up for
Claude Code, and `br`, the Rust Beads issue tracker, on `exec-path` (or
named by `rat-kingdom-task-br-program`). For Codex workers you also need
agent-shell's Codex support set up:
[codex-acp](https://github.com/agentclientprotocol/codex-acp) installed
and `agent-shell-openai-authentication` set.

```elisp
(add-to-list 'load-path "/path/to/rat-kingdom.el")
(require 'rat-kingdom)
```

`M-x rat-kingdom-king` starts the king, a Claude Code session you talk to,
or shows it if it is running. Tell it which repository to work in and what
you want done. It registers the repository, writes stories, hands each to
a worker and reviews what comes back. It hears from the engine when a
story is merged, stops or wants a review, but only between its turns and
never while you have something half typed.

What happens to a story:

1. A worker, another Claude Code session or a Codex one, starts in the
   background in a worktree under `~/.emacs.d/rat-kingdom/worktrees/`, on a branch
   `rats/S-xxxx` cut from the repository's target branch, `rk/integration`.
2. When the worker reports that it is done, its commit is merged in a
   scratch worktree and the repository's check, if it has one, runs there.
3. In the `story` workflow the king then reviews the diff. In `story-lite`
   there is no review.
4. The target branch is moved to the merge. If it moved meanwhile, the
   story is checked again first.

A failed check, a merge conflict or a review that asks for changes sends
the story back to a new worker in the same worktree, with the reason. A
story that cannot go on is parked at `blocked` with a reason until the
king or you move it.

At most three workers run at once (`rat-kingdom-story-max-workers`; nil
for no limit). A story started beyond that waits "for a free worker" and
gets one, oldest first, as soon as another worker finishes, blocks, ends or
is stopped. Waiting does not count as one of its workers.

If a worktree needs something before the code builds or its tests run,
such as installed dependencies, give the repository a setup command: tell
the king "add ~/src/app with check `npm test` and setup `npm ci`", or
answer the setup prompt of `M-x rat-kingdom-add-repo`. It runs, without a
shell, in each new worktree before its worker starts, and in the scratch
worktree before the check. A setup that fails stops the story with its
output.

Finished work lands on the target branch only. Your checkout is not
touched and nothing is pushed. Merge or discard that branch yourself.

### Tasks

br is required: every registered repository has a br workspace, the
`.beads` directory of your own checkout, and that is where rat-kingdom
reads its ready tasks, claims them for stories and closes them when the
work is merged. br is never run in a worker's worktree.

Registering a repository whose checkout has no `.beads` runs
`br init --prefix PREFIX` there and checks that br kept the prefix. The
prefix is the repository's name unless you give another: `task_prefix` to
the king's `repo_add`, or the prefix prompt of `M-x rat-kingdom-add-repo`.
The new workspace is kept out of Git: `/.beads/` is added, once, to
`info/exclude` in the repository's common Git directory (shared by its
linked worktrees), never to `.gitignore`, so `git status` does not change.
Set `rat-kingdom-task-br-untracked` to nil if you would sooner track
`.beads` yourself. A `.beads` that is already there, tracked or not, is
left exactly as it is.

If br is not installed, refuses the prefix or keeps a different one,
registration fails with br's message and nothing is registered; whatever
br had made is removed. Turning on `rat-kingdom-mode` and `M-x
rat-kingdom-tasks-refresh` make the workspace of every registered
repository that lacks one. One that fails is reported as a warning and in
the king's `status`, and the others carry on.

### Planning an epic

Ask the king to plan a piece of work as an epic. It proposes the stories
and the dependencies between them, and waits for you to agree. Then it
calls `epic_create`, which takes the repository, the epic's title, a
description of its goal and how it will be judged as a whole, and the
stories as a JSON array. Each story has a `key` of its own in the plan
(`a`, `parser`), a `title` and a `description`, and may have `depends_on`
(keys of other stories), `agent`, `workflow` and `priority`.

The whole plan is checked before anything is written: every key unique,
every title and description given, every `depends_on` naming a key in
the plan, no cycle, every agent and workflow known, priorities from 0 to
4. Any problem creates nothing, and every problem is named. Then br gets
the epic (`--type epic`), each story as a task of it (`--parent`),
created after the tasks it depends on, and the dependencies
(`br dep add TASK DEPENDS-ON`). The king is shown the epic's id, a table
of each story's key, task, title, dependencies, agent and workflow, and
which tasks are ready now. If br fails partway, the answer says exactly
which ids were created and which dependencies recorded. br has no clean
delete, only tombstones, so nothing is removed; delete them with
`br delete` if you do not want them.

`task_create` adds one task the same way: a title and description,
and optionally a priority, a type (task, bug, feature or chore), an epic
as `parent`, the ids it `depends_on`, an `agent` and a `workflow`. The
parent and the tasks depended on must already exist.

Neither tool starts anything. A task becomes available when the tasks it
depends on are closed, as their stories are merged, and `status` lists it
under Available tasks with its epic and agent. Work starts only when the
king starts a story for it with `story_start` and its `task`. The task's
agent and workflow are kept as the br labels `rk-agent:NAME` and
`rk-workflow:NAME`, and `story_start` uses them unless it is given
others. An epic itself is never available.

### Choosing the agent

Each story's workers run Claude Code or OpenAI Codex. Tell the king which
("start a story in app, with codex, to …"): `story_start` takes `agent`,
`claude` or `codex`. Left out, it is the task's `rk-agent:` label if the
story is for a task that has one, and otherwise `rat-kingdom-default-agent`,
which is `claude` unless you change it. `M-x rat-kingdom-start-story` asks, with
that as the default. The king itself is always Claude Code.

The story keeps its agent. A worker that replaces another, after a failed
check, a merge conflict, a review that asks for changes or an Emacs restart,
runs the same agent, even if the default has changed since. `status` and
`story_show` say which agent each story has.

Codex runs in full access, the equivalent of `codex --yolo`: the codex-acp
session mode `agent-full-access`, which never asks for approval and has no
sandbox. rat-kingdom sets this on the sessions it starts. Your own
`agent-shell-openai-default-session-mode-id` is not changed. Codex reaches
rat-kingdom's tools (`finish`, `block`) through the same HTTP MCP endpoint
as Claude. codex-acp supports HTTP MCP servers.

`rat-kingdom-agent-shell-define-agent` adds another agent kind, or replaces
a built-in one. It takes a name and a function that returns an agent-shell
config.

### Pushing

No agent rat-kingdom starts, worker or king, Claude or Codex, can push,
whatever its permission mode. Each agent's process is started with Git
configuration in its environment (`GIT_CONFIG_COUNT`) that rewrites every
push URL to a remote helper that does not exist, so `git push` fails with
`rat-kingdom-refuses-to-push`, `--no-verify` or not. A Claude session is
also started with Claude tool rules denying `git push` and `gh`, and Emacs
refuses any permission request to run them. Nothing is written to your
Git configuration or hooks, so your own pushes are unaffected. A remote
with an explicit `pushurl` is not rewritten by Git. For Claude the other
two layers cover that case.

For Codex, the environment is the only layer. Codex ignores Claude's tool
rules, and in full-access mode it never asks permission, so Emacs has
nothing to refuse. Codex's `gh` is not blocked either, beyond
`GH_PROMPT_DISABLED`, and neither is a push to a remote with a `pushurl`.
Codex passes its environment to the commands it runs unless your
`~/.codex/config.toml` filters it. Do not set
`shell_environment_policy.inherit` to `core` or `none` for Codex workers:
that drops `GIT_CONFIG_*` and with it the block. Setting
`ignore_default_excludes = false` drops the `GIT_CONFIG_KEY_n` variables,
so every Git command in Codex then fails, pushes included. See DESIGN.md,
section 12.

The one way to push is the king's `publish` tool, which pushes one local
branch to the branch of the same name on one remote. The king is told to
use it only when you have asked for that push in the conversation. It runs
Git in Emacs with your own credentials, never forces (a push that is not a
fast-forward is refused and the error is reported), and writes a
`published` tuple as a receipt. `M-x rat-kingdom-publish` does the same by
hand.

Everything the king does has a command, for when you would sooner do it
by hand: `rat-kingdom-add-repo`, `rat-kingdom-start-story`,
`rat-kingdom-move-story`, `rat-kingdom-review-story`,
`rat-kingdom-cancel-story`, `rat-kingdom-publish`. `M-x
rat-kingdom-inspect` shows the space. `M-x rat-kingdom-king-restart`
restarts the king's session in place, keeping the conversation, so that it
fetches its tools afresh.

### After a restart

Turning on `rat-kingdom-mode`, which `rat-kingdom-king` does, recovers
what the last Emacs left in flight. A worker that was cut off is replaced
by a new one in the same worktree, told to look at what is there. A check
or setup that was running runs again. The king takes up its earlier
session; `C-u M-x rat-kingdom-king` starts a new one instead.

### Telling a worker something

Ask the king to tell a story's worker something, a correction or a detail
it left out, and it calls `tell` with the story and the text. The message
waits in the space as a `message` tuple owned by the story, and the
answer says what became of it:

- a worker between turns is given it at once, as its next prompt;
- a worker in the middle of a turn is given it when the turn ends, and can
  read it sooner with its `inbox` tool, which workers are told to check
  during long turns and before they call `finish`;
- a story with no worker right now, because it is queued for a free
  worker, being checked or reviewed, or stopped, keeps it for its next
  worker, which finds it in its prompt.

A worker that has already reported with `finish` or `block` is never
given one. So a message sent while a story is at its check or review is
only read if the story goes back to a worker; if it passes and is merged,
the message is archived unread. `status` says how many messages wait on
each story, and `story_show` lists them. A message is removed only once
it has been handed over, so a restart keeps it, and a worker that
replaces one cut off by a restart finds it in its prompt.

### Facts

A worker that learns something a later worker in the same repository
would want to know, such as a convention, a pitfall, how to run the tests
or where something lives, records it with its `note_fact` tool: the fact,
and optionally a topic and the files it concerns. A fact is a `fact`
tuple scoped to the repository with no owner, so it outlives the story
that wrote it. Every worker started later in that repository is told the
repository's facts in its prompt, newest first, at most 40 of them and
8000 characters (`rat-kingdom-fact-brief-max-count`,
`rat-kingdom-fact-brief-max-chars`). A fact may be at most 1500
characters (`rat-kingdom-fact-max-length`).

The king can look into the space with `query`, which only reads: one
category, optionally narrowed by scope, identity, owner and a text the
payload contains, newest first, archived tuples too if asked. Ask it
"what facts do we have for myrepo?". It removes a fact that turned out
wrong with `fact_forget`. Other code can add its own section to a
worker's prompt through `rat-kingdom-story-brief-functions`.

### Workflows

A workflow is data: places, and the step taken from each.

```elisp
(rat-kingdom-workflow-define 'story-lite
  :places '(ready checking integrating done blocked)
  :start 'ready
  :final '(done)
  :steps '((implement :from ready :spawn rat :to checking)
           (check :from checking :check t :pass integrating :fail ready)
           (integrate :from integrating :merge t :to done :stale checking)))
```

A definition that does not hold together is refused: an unknown place, two
steps from one place, a place with no way on, no way to a final place. A
repository names the workflow its stories follow, and a story can name
its own.

## Requirements

Emacs 29.1 or later, built with SQLite support, Git, and br (Rust Beads)
for tasks. Starting an agent needs agent-shell.

## The tuplespace

```elisp
(require 'rat-kingdom-space)

(setq space (rat-kingdom-space-open "~/.emacs.d/rat-kingdom/space.db"))

;; Write a tuple.
(rat-kingdom-space-out space 'available :scope "myrepo" :identity "T-1"
               :payload '(:priority 2))

;; Read by pattern.  $name is a variable, _ matches anything.
(rat-kingdom-space-scan space '(available :scope "myrepo" :priority $p))

;; Take one.  Only one taker gets it.
(rat-kingdom-space-in space '(available :scope "myrepo"))

;; Archive everything a finished story owned.
(rat-kingdom-space-sweep space "S-1")
```

## Reactions

```elisp
(require 'rat-kingdom-reaction)

;; When a task is available, take it and start a story for it.
(rat-kingdom-defreaction start-story
  :take (available :scope $repo :identity $task)
  (rat-kingdom-space-out rat-kingdom-reaction-space 'story
                         :scope $repo :identity $task
                         :payload '(:at ready)))

(rat-kingdom-reaction-attach space)
```

A firing is one transaction: the take and whatever the body writes commit
together, or not at all. The commentary in each file has the details.

## Looking inside

`M-x rat-kingdom-inspect` lists the space in `rat-kingdom-space-default-file`
(`~/.emacs.d/rat-kingdom/space.db`).

| Key   | Does                                     |
|-------|------------------------------------------|
| `t`   | list the live tuples                     |
| `l`   | list the operations log, newest first    |
| `A`   | list the archive, newest first           |
| `/`   | narrow the tuples to a pattern           |
| `RET` | show the row at point in full            |
| `d`   | retract the tuple at point, after asking |
| `+`   | write a tuple                            |
| `g`   | re-read the space                        |

## Development

```sh
eldev test
eldev compile -W
eldev lint
```

After pulling or merging changes to rat-kingdom, run `M-x rat-kingdom-reload`
to load them into the running Emacs. Running agents, the open space, the tool
endpoint and the king are kept, and no agent is started or stopped, with one
exception. The king's tools and instructions are fixed when its session
starts, so a reload that changes them restarts the king's session in place:
it is stopped and its session taken up again, keeping the conversation, with
its tools fetched afresh and the new instructions given to it. That waits
until the king is between turns and you have nothing half typed in its
buffer; until then the reload message tells you, and the king is restarted
when it next ends a turn. News for the king waits meanwhile. With
`rat-kingdom-king-restart-on-reload` set to nil the reload only tells you to
run `M-x rat-kingdom-king-restart`.

Reloading only works if no default lives in a `defvar`'s initial value, since
`defvar` never overwrites a variable that is already bound. So:

- Put built-in configuration in a `defconst`, with the variable, if any,
  holding only what is added to it or nil meaning "the default".
- Start a hook variable as nil and register its built-in members with
  `add-hook` at top level, after the variable is defined.
- Keep `defvar` for state that must survive a reload: live runs, grants,
  timers, the open space, and registries filled by `-define` calls, which
  replace an entry of the same name.
- Add a new file to `rat-kingdom--files` in rat-kingdom.el.

The king's instructions list its tools from the tools defined for the role
`king`, through `{tools}` in `rat-kingdom-king-instructions`. So a new king
tool is listed without editing them, and the reload that adds it restarts
the king to give it the new tool.

## License

GPL-3.0-or-later.
