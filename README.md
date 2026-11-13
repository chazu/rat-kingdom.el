# rat-kingdom

Swarm orchestration for coding agents, inside Emacs. A king you talk to,
workers in their own Git worktrees, and a tuplespace they coordinate
through. See [DESIGN.md](DESIGN.md).

**Status:** early. One story can go from a task to a merged commit: a
worker in its own worktree, a check, a merge into an integration branch.
There is no king, no review step and no workflow engine yet, and the path
through a real agent has not been exercised.

## Trying it

You need [agent-shell](https://github.com/xenodium/agent-shell) set up for
Claude Code.

```elisp
(add-to-list 'load-path "/path/to/rat-kingdom.el")
(require 'rat-kingdom)
```

1. `M-x rat-kingdom-add-repo` registers a repository and, if you give one,
   the command that must pass before work is merged. It creates the branch
   `rk/integration` from `HEAD`.
2. `M-x rat-kingdom-start-story` asks for a task. A Claude Code session
   starts in the background, in a worktree under
   `~/.emacs.d/rat-kingdom/worktrees/`, on a branch `rats/S-xxxx`.
3. `M-x rat-kingdom-inspect` shows the story's token move: `implementing`,
   `checking`, then gone, which means merged and archived (`A` shows the
   archive). A story that stops is at `blocked` with a `:reason`.

Finished work lands on `rk/integration` only. Your checkout is not touched
and nothing is pushed. Merge or discard that branch yourself.

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

## License

GPL-3.0-or-later.
