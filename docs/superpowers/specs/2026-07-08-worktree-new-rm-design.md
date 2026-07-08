# margay `new` / `rm` — worktree lifecycle commands

**Status:** Approved design, not yet implemented.
**Date:** 2026-07-08

## Motivation

margay today runs services *in* existing git worktrees (`up`, `down`, `status`,
`worktrees`) but never creates or removes the worktrees themselves — the user
does that with raw `git worktree add` / `git worktree remove` and then runs
margay separately. This adds the two missing lifecycle commands so margay owns
the whole cycle: `new` creates a worktree (and optionally starts its sandbox),
`rm` is the true inverse of `up` + create — it stops the sandbox, drops the
branch DB, and removes the worktree, leaving nothing orphaned.

## Commands

### `margay new <name> [--from <ref>] [--up]`

Creates a worktree as a sibling of the primary checkout and optionally starts
its sandbox.

**Path convention:** `<parent-of-primary>/<primary-basename>-<name>`.
Primary `~/Projects/acme` + `new feat-x` → `~/Projects/acme-feat-x`.
If `<name>` contains `/` (e.g. `feat/payments`), slashes are replaced with `-`
in the **directory name only** (`acme-feat-payments`); the git branch keeps its
real name (`feat/payments`).

**Branch handling:**

- If a branch named `<name>` already exists
  (`git show-ref --verify --quiet refs/heads/<name>`):
  `git worktree add <dest> <name>` (check it out).
- Otherwise, create it: `git worktree add <dest> -b <name> <base>`, where
  `<base>` is:
  - the value of `--from <ref>` if given, else
  - the branch currently checked out in the **primary** checkout
    (`git -C "$PRIMARY" symbolic-ref --short -q HEAD`), else
  - the primary's HEAD commit (`git -C "$PRIMARY" rev-parse HEAD`) when the
    primary is detached.

**`--up`:** after a successful `git worktree add`, run the normal up flow for
the new worktree — **all** declared services, in dependency order. Implemented
by delegating to `margay::cmd_up "$name"` (which resolves `<name>` to the new
worktree). Without `--up`, `new` only creates the worktree. Starting a subset of
services is intentionally out of scope for `new` — run `margay up <name> <svc>`
afterward. This keeps `new`'s argument parsing unambiguous (no trailing
service-name list to disambiguate from flags).

**Guards / errors:**

- Must be run inside a git worktree of the repo (needs to locate the primary).
- Refuse if `<dest>` already exists (do not clobber).
- Git's own errors are surfaced verbatim: branch already checked out in another
  worktree, invalid `--from` ref, etc.

### `margay rm <worktree> [--branch] [--force]`

The inverse of `up` + create.

**Resolution:** `<worktree>` is resolved with the existing
`margay::worktree_resolve` against `git worktree list --porcelain`
(exact basename/branch match beats substring; ambiguous → error listing all
candidates; miss → error pointing at `margay worktrees`).

**Order of operations:**

1. **Pre-checks (before touching anything):**
   - Must be inside a git worktree.
   - Refuse if the resolved target is the **primary** worktree
     (`margay::primary_worktree`).
   - Refuse if the target is the worktree you are currently standing in
     (`git rev-parse --show-toplevel`) — message tells the user to run it from
     the primary or another worktree, because `git worktree remove` cannot
     remove the current worktree anyway.
   - If the target tree is dirty (`git -C <dest> status --porcelain` non-empty)
     and `--force` was **not** passed, die early — before stopping any service
     or dropping any DB.
2. **`margay down <target>`** — stop the worktree's services, reap orphaned port
   listeners, remove its registry rows (reuses `margay::cmd_down`).
3. **Drop the branch DB** — only if the project declares a DB (i.e.
   `postgres_psql` is defined after loading the conf). Compute the DB name with
   `margay::db_name "$project" "$branch"`, check `margay::db_exists`, and
   `margay::db_drop` it (which uses `WITH (FORCE)`). Silently skipped for
   projects with no DB.
4. **`git worktree remove <dest>`** — adds `--force` when the user passed
   `--force`.
5. **`--branch`** — after a successful removal, delete the git branch:
   `git branch -d <branch>` normally, `git branch -D <branch>` when combined
   with `--force`.

Each step echoes what it did. `rm` is **non-interactive** (no confirmation
prompt) — consistent with `down`, and the branch DB is disposable by design. The
git branch is preserved unless `--branch` is given. `--force` covers both the
dirty-tree pre-check and the hard branch delete (`-D`).

## Implementation

### Files touched

- **`./margay`** — add `margay::cmd_new` and `margay::cmd_rm`; wire both into the
  `main()` `case`; update the one-line `usage:` / `help` string.
- **`lib/engine.sh`** — add a small pure helper
  `margay::worktree_dest <primary> <name>` that echoes the destination path
  (applying the `/`→`-` directory rule), so path naming is unit-testable in
  isolation without touching git or the filesystem.

### `margay::worktree_dest`

```bash
# primary name → sibling dest path (dir suffix flattens '/' to '-')
margay::worktree_dest() {
  local primary="$1" name="$2" parent base dir
  parent="$(dirname "$primary")"
  base="$(basename "$primary")"
  dir="${name//\//-}"
  echo "$parent/$base-$dir"
}
```

### Usage string (updated)

```
usage: margay new <name> [--from <ref>] [--up]
     | rm <worktree> [--branch] [--force]
     | up [worktree] [service ...] [--use NAME=PORT|URL] [--fresh|--empty]
     | down [worktree|--all] | status | worktrees
```

## Testing

- **`test/margay_test.sh` (unit):** `margay::worktree_dest` — simple name, name
  with a slash, primary path with a trailing component. Pure function, no git.
- **`test/integration_test.sh` (end-to-end, real temp git repo):**
  - `new` with a non-existent name creates the sibling directory and a new
    branch based on the primary's HEAD.
  - `new` with an existing branch name checks that branch out into the new
    worktree (no new branch created).
  - `new --from <ref>` bases the new branch on the given ref.
  - `rm` removes the worktree directory, drops the branch DB (mock
    `postgres_psql` / `postgres_dump` hooks in the fixture conf), and **keeps**
    the branch by default.
  - `rm --branch` additionally deletes the git branch.
  - Guard: `rm` refuses to remove the primary worktree.
  - Guard: `rm` refuses a dirty target without `--force`, and proceeds with it.

## Decisions (resolved during brainstorming)

| Question | Decision |
|---|---|
| Scope | Full lifecycle: `new` = git add (+ optional `--up`); `rm` = down + drop DB + git remove. |
| Worktree path | Sibling `../<repo>-<name>`. |
| Branch on `new` | Create new (from primary HEAD or `--from`), else check out existing. |
| Branch on `rm` | Keep by default; `--branch` also deletes it. |
| Command names | `new` / `rm`. |
| `--up` granularity | Starts all services; no per-service subset on `new`. |
| `rm` interactivity | Non-interactive, echoes each step; `--force` gates dirty-tree + hard branch delete. |
