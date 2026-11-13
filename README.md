# rat-kingdom

Swarm orchestration for coding agents, inside Emacs. A king you talk to,
workers in their own Git worktrees, and a tuplespace they coordinate
through. See [DESIGN.md](DESIGN.md).

**Status:** early. The tuplespace (`rat-kingdom-space.el`) and reactions
(`rat-kingdom-reaction.el`) exist. Nothing here starts an agent yet.

## Requirements

Emacs 29.1 or later, built with SQLite support.

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

## Development

```sh
eldev test
eldev compile -W
eldev lint
```

## License

GPL-3.0-or-later.
