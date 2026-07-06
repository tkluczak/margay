# margay worktrees + worktree targeting for up/down

**Status:** Design approved (brainstormed 2026-07-06); implementation pending
**Date:** 2026-07-06
**Extends:** `docs/design.md` (the shipped v1 design)

## Motivation

Two workflow gaps once several worktrees exist:

1. No single view of "which worktrees does this repo have, and which of them have live sandboxes" — `git worktree list` knows the first half, `margay status` the second.
2. Starting a sandbox for a worktree requires `cd`'ing into it. From the main tree one should be able to say `margay up feat-payments` and have that worktree's stack come up.

## Command surface (new/changed)

```
margay worktrees                                  # list current repo's worktrees + sandbox status
margay up   [worktree] [service ...] [flags…]     # worktree: at most one, resolved per grammar below
margay down [worktree] | [--all]                  # same targeting; no target = current worktree (unchanged)
```

## `margay worktrees` (listing)

- Runs from any checkout of the repo, **conf-less** (git + registry only; works in apricot). Outside a git repo → existing `die "not inside a git worktree"`.
- Data flow: `git worktree list --porcelain` → parse `worktree <path>` / `branch refs/heads/<name>` / `detached` records → `margay::registry_prune` once → join rows by `worktreePath`.
- Output: one line per worktree, git's order (primary first). Columns:
  `WORKTREE` (path, `$HOME` shortened to `~`) · `BRANCH` (`(detached)` when detached) · `SANDBOX` (space-joined `service:port` of live registry rows at that path, `—` if none) · `DB` (distinct dbName(s), `—` if none).

## Worktree targeting for `up` / `down`

Each positional arg of `up` resolves in this order:

1. **Declared service** (exact match against the loaded conf's `services`) → service, current behavior.
2. **Worktree, exact**: the worktree directory basename OR its branch name. Exact matches are collected across both namespaces; if they point at two *different* worktrees, that's ambiguous (die listing both).
3. **Worktree, unique substring**: substring match across both namespaces (basenames + branch names of the repo's worktrees). >1 worktree matched → die listing candidates; 0 matched → die listing declared services and worktrees.
4. **Collision guard**: a worktree whose basename/branch equals a declared service resolves as the *service*, with a warning to use the full branch name to target the worktree.

Constraints: at most one worktree target per invocation (second → die). Worktree + services combine: `margay up feat-payments api` starts only `backend` in that worktree.

`down [worktree]` accepts worktree targeting via steps 2–3 only (services are meaningless to `down`, so the step-4 collision guard does not apply — a worktree named like a service is targetable by `down` directly): stops that worktree's registry rows from wherever you stand. No target → current worktree (unchanged). `--all` unchanged. `status` stays global, unchanged.

## Mechanics

- New pure helpers in `lib/engine.sh`, both taking the porcelain text as input (stdin or arg) so they unit-test without git:
  - `margay::worktrees_join` — porcelain in, TSV out (`path<TAB>branch<TAB>sandbox<TAB>db`), joining the pruned registry by `worktreePath`.
  - `margay::worktree_resolve <query>` — porcelain in, resolves per grammar steps 2–3, echoes `path<TAB>branch`; exit 1 miss, exit 2 ambiguous (caller formats the die message with candidates).
- Entrypoint: `margay::cmd_worktrees` (thin: run git, call join, format table); `up`/`down` arg loops try service-match first, then `worktree_resolve`; on a worktree hit set `WORKTREE=<path>`, `BRANCH=<its branch>` *before* the existing flow. Everything downstream (config_find worktree-else-primary, db slug, `cd "$WORKTREE"` launch, registry record) already keys off those two variables — no other changes.
- `up`'s conf must load before service-vs-worktree disambiguation (services come from the conf), so `context()` splits: derive PRIMARY + load conf first, resolve targets, then fix WORKTREE/BRANCH. `down`'s targeting needs no conf.
- Detached-HEAD worktree targeted by `up`: allowed; BRANCH falls back to the literal `HEAD` (db slug `head`) — identical to what `git rev-parse --abbrev-ref HEAD` yields when standing inside a detached worktree today, so remote targeting and cd'ing in behave the same.

## Errors

- Ambiguous substring → `margay: 'x' matches multiple worktrees: <list>`.
- No match → `margay: 'x' is neither a declared service (<services>) nor a worktree (run 'margay worktrees')`.
- Two worktree targets → `margay: at most one worktree target per invocation`.

## Testing

- Unit (`test/margay_test.sh`, porcelain fixtures + fixture registry): join with empty registry / one sandbox / two services same worktree / dead-PID pruned / detached; resolve exact-basename, exact-branch, unique substring, ambiguous (rc 2), miss (rc 1).
- Integration (`test/integration_test.sh`, existing fake repo): `git worktree add` a second worktree; from the main tree `margay up <branch-substring>` starts the sandbox with the worktree's branch+path in the registry; `margay worktrees` shows `service:port` on that row and `—` on the main row; `margay down <name>` stops it; collision case (worktree named like a service) resolves to the service with a warning.

## Not doing (YAGNI)

Cross-project listing (that's `status`), `--json`, filter flags, `wt` alias, multiple worktree targets, targeting by full path (cd there instead).
