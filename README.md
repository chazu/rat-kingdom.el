# rat-kingdom

Swarm orchestration for coding agents, inside Emacs. A king you talk to,
workers in their own Git worktrees, and a tuplespace they coordinate
through. See [DESIGN.md](DESIGN.md).

**Status:** early, and usable for one story at a time or a few in
parallel. You talk to a king; it starts stories; each story follows a
workflow from a worker through a check and a review to a merge into an
integration branch; work cut off by an Emacs restart is recovered. There
are no epics, task tracker or research workflow yet. The path through real
agents has been run once for a worker and not yet for the king.

## Using it

You need [agent-shell](https://github.com/xenodium/agent-shell) set up for
Claude Code.

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

1. A worker, another Claude Code session, starts in the background in a
   worktree under `~/.emacs.d/rat-kingdom/worktrees/`, on a branch
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

### Pushing

No agent rat-kingdom starts, worker or king, can push, whatever Claude
Code's permission mode. Each agent's process is started with Git
configuration in its environment (`GIT_CONFIG_COUNT`) that rewrites every
push URL to a remote helper that does not exist, so `git push` fails with
`rat-kingdom-refuses-to-push`, `--no-verify` or not. Its session is also
started with Claude tool rules denying `git push` and `gh`, and Emacs
refuses any permission request to run them. Nothing is written to your
Git configuration or hooks, so your own pushes are unaffected. A remote
with an explicit `pushurl` is not rewritten by Git; the other two layers
cover it.

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

Emacs 29.1 or later, built with SQLite support, and Git. Starting an
agent needs agent-shell.

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

## License

GPL-3.0-or-later.
