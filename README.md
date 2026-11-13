# rk3

Swarm orchestration for coding agents, inside Emacs. A king you talk to,
workers in their own Git worktrees, and a tuplespace they coordinate
through. See [DESIGN.md](DESIGN.md).

**Status:** early. Only the tuplespace (`rk3-space.el`) exists. Nothing
here starts an agent yet.

## Requirements

Emacs 29.1 or later, built with SQLite support.

## The tuplespace

```elisp
(require 'rk3-space)

(setq space (rk3-space-open "~/.rk3/space.db"))

;; Write a tuple.
(rk3-space-out space 'available :scope "myrepo" :identity "T-1"
               :payload '(:priority 2))

;; Read by pattern.  $name is a variable, _ matches anything.
(rk3-space-scan space '(available :scope "myrepo" :priority $p))

;; Take one.  Only one taker gets it.
(rk3-space-in space '(available :scope "myrepo"))

;; Archive everything a finished story owned.
(rk3-space-sweep space "S-1")
```

The commentary in `rk3-space.el` describes tuples, patterns, modalities
and the operations log.

## Development

```sh
eldev test
eldev compile -W
eldev lint
```

## License

GPL-3.0-or-later.
