# margay `ps` / `ls` aliases + shell completion for `up` / `down`

**Status:** Approved, not yet implemented.
**Date:** 2026-07-15
**Builds on:** worktree targeting for up/down (`docs/worktrees-listing-and-targeting.md`, shipped).

## Motivation

Two ergonomic gaps, no new capability:

1. `status` and `worktrees` are the two commands typed most often, and they
   are the two longest. `ps` and `ls` are what the fingers reach for.
2. Targeting a worktree by name (`margay up feat-payments`) requires
   remembering the name and typing it exactly. The names are already known
   to margay — git lists the worktrees, the conf declares the services — so
   the shell should offer them on TAB. In zsh that means a highlighted
   carousel: TAB opens it, arrow keys cycle it, Enter accepts.

## Decisions

| Question | Decision |
|---|---|
| `ps` / `ls` | **aliases**, not renames: `ps` → `cmd_status`, `ls` → `cmd_worktrees`. Both old names keep working indefinitely; help leads with the short names |
| Carousel mechanism | zsh `menu-select` via the standard completion system. TAB opens, ↑↓ cycle, ↵ accepts. No custom ZLE widget, no rebinding of ↑/↓ (they stay history) |
| Interactive `-i` picker | **not doing.** menu-select covers the ask; an in-terminal picker would add raw-mode/TTY handling and its own test surface for no gain here |
| Shell coverage | zsh + bash. zsh gets the carousel; bash gets plain TAB candidates. No fish |
| Candidate source | one hidden subcommand, `margay __complete <up\|down>`, prints `candidate<TAB>description`. Shell scripts render; they never compute |
| Naming/visibility | `__complete` (Cobra convention — the `__` marks "not for humans"), omitted from the help usage line, exactly as `conf-json` already is |
| `down` candidates | only worktrees with **live registry rows**, plus `--all`. Stopping a worktree with nothing running is a no-op; offering it is noise |
| Failure behavior | `__complete` **never dies, never writes stderr, always exits 0** — see Silence contract below |
| `env_file` | `__complete` does **not** source it. Completion must be side-effect-free and fast; candidates don't need project env vars |

## Why a subcommand instead of logic in the shell scripts

What counts as a valid `up` target is a real grammar — service-vs-worktree
precedence, exact-then-substring matching, the collision guard — and it is
already written once, in bash, across `margay::cmd_up` and
`margay::worktree_resolve`. Reimplementing candidate derivation in zsh and
again in bash would make three copies that drift apart the first time those
rules change. `__complete` keeps one source of truth and leaves the shell
scripts as dumb renderers.

This is the pattern `conf-json` already established for `lib/ui.py`: a
machine-readable helper subcommand, hidden from help, consumed by a
non-human caller.

## Data flow

```
margay up <TAB>
  → _margay (zsh) / _margay_bash (bash)
      → margay __complete up        → candidate<TAB>description lines
  → zsh:  _describe → menu-select carousel (↑↓ cycle, ↵ accept)
    bash: compgen -W → plain candidate list
```

## The silence contract

A completion helper that writes to stderr or exits non-zero turns a TAB
press into garbage on the user's prompt. Therefore every failure path in
`__complete` — outside a git repo, no `.margay.conf` for this repo,
unreadable/absent registry — prints nothing and exits 0.

Concretely this means `__complete` **cannot reuse `margay::context`**, which
calls `die` on both of the first two conditions. It re-derives the context on
a soft path: `git rev-parse` guarded, `config_find`/`config_load` guarded,
each failure short-circuiting to a silent `exit 0`.

## Implementation sketch

- `margay`:
  - `main()` case gains `status|ps)` and `worktrees|ls)`; the two usage
    strings lead with `ps` / `ls` and note the long aliases. `__complete` is
    dispatched but **not** listed in usage.
  - new `margay::cmd_complete <up|down>`:
    - soft context: `git rev-parse --is-inside-work-tree` → else exit 0;
      `PRIMARY="$(margay::primary_worktree)"`.
    - `up`: `git worktree list --porcelain | margay::worktrees_parse |
      margay::worktrees_join` → emit `basename<TAB>sandbox` (`—` when idle)
      per row; then `config_find`/`config_load` guarded → emit
      `<svc><TAB>service` for each `$services`. Also the flags
      `--fresh --empty --use`.
    - `down`: same join, filtered to rows with a non-empty sandbox column;
      plus `--all<TAB>every sandbox everywhere`.
- `completions/_margay` (zsh): `#compdef margay`; `_arguments -C` with
  `':command:->cmd' '*::arg:->args'`, dispatching on `$line[1]` (the
  subcommand — note `$words[1]` is `margay` itself) to per-command
  `_describe` calls fed by `margay __complete "$line[1]"`. Two `_describe` groups for `up`
  (`worktrees`, `services`) so zsh shows group headings in the menu.
  Requires `zmodload zsh/complist` + `zstyle ':completion:*' menu select`
  for the carousel; install.sh adds the zstyle only if the user has no
  `menu select` style already set.
- `completions/margay.bash` (bash): `complete -F _margay_bash margay sandbox`;
  `compgen -W "$(margay __complete "${COMP_WORDS[1]}" | cut -f1)"`.
- `install.sh`: symlink `completions/_margay` into a `$fpath` dir
  (`~/.local/share/zsh/site-functions`, adding it to `$fpath` in `.zshrc` if
  absent) and source `margay.bash` from `.bashrc`. Idempotent, matching the
  existing symlink/gitignore-guard style. Completion for the `sandbox` compat
  alias comes free from the same registration.

## Testing

Unit (`test/margay_test.sh`, existing fixture style):

- `ps` output is byte-identical to `status`; `ls` to `worktrees`.
- `__complete up` lists worktree basenames **and** declared services;
  a worktree with a live sandbox carries its `service:port` description.
- `__complete down` lists only worktrees with live registry rows, plus
  `--all`; an idle worktree is absent.
- Silence contract, one test per path — outside a git repo, and inside a repo
  with no conf: assert exit 0, empty stdout, **empty stderr**.

Syntax: `zsh -n completions/_margay`, `bash -n completions/margay.bash` (skip
the zsh check with a note if zsh is absent from the box).

Not automated: the menu-select carousel itself. Driving zsh's interactive
completion UI in CI costs more than it protects; the candidate *data* is
fully covered above, and the rendering is a stock zsh mechanism.

## Not doing (YAGNI)

`-i`/`--interactive` picker; a ↓-arrow ZLE widget; fish completion;
completion for `unregister` / `ui` flags; caching `__complete` output;
`--json` output from `__complete`.
