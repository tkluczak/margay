# margay `claude` — resume the worktree's Claude session inside tmux

**Status:** Approved design, not yet implemented.
**Date:** 2026-07-12

## Motivation

Claude Code sessions run attached to whatever terminal they were started in.
Moving one into tmux — so it survives terminal closes and can be reattached
from anywhere — means exiting Claude and resuming it inside a tmux session.
`margay claude` makes that one idempotent command: it attaches to (or creates)
a tmux session named after the worktree, with Claude resumed inside. Flow:
exit your Claude session → `margay claude` → same conversation, now inside
tmux.

## Command

### `margay claude [worktree]`

Attach to (or create) the per-worktree tmux session, resuming the worktree's
most recent Claude Code session in it.

**Resolution:** no argument → the current worktree
(`git rev-parse --show-toplevel`). With an argument → resolved through the
existing `margay::worktree_resolve` against `git worktree list --porcelain`
(exact basename/branch match beats substring; ambiguous → error listing all
candidates; miss → error pointing at `margay worktrees`). Works without a
`.margay.conf` — naming needs only git, like `margay worktrees`.

**Session name:** the worktree directory basename, sanitized for tmux —
`.` and `:` become `-` (tmux forbids both in session names). Examples:
`~/Projects/acme-feat-payments` → `acme-feat-payments`; the primary checkout
`~/Projects/acme` → `acme`.

**Behavior:**

1. **Guards (in order):**
   - `tmux` on PATH, else die: `tmux not found — install it first`.
   - `claude` on PATH, else die: `claude CLI not found`.
   - Must be inside a git worktree (when no argument is given, and to resolve
     the worktree list when one is).
2. **Session exists** (`tmux has-session -t =<name>` — the `=` prefix forces
   an exact match, no prefix matching):
   - Outside tmux: `exec tmux attach -t =<name>`.
   - Inside tmux (`$TMUX` set): `tmux switch-client -t =<name>`.
   - Whatever runs in the existing session is untouched — no second Claude is
     spawned.
3. **Session doesn't exist** — create it with cwd = worktree path and the
   first window running the resume command:
   - Outside tmux: `exec tmux new-session -s <name> -c <worktree> <cmd>`.
   - Inside tmux: `tmux new-session -d -s <name> -c <worktree> <cmd>`, then
     `tmux switch-client -t =<name>`.

**Resume command (`<cmd>`):** `claude --continue` when the worktree has a
prior Claude Code session, plain `claude` otherwise (so a worktree that never
ran Claude gets a fresh session in the right directory instead of a window
that errors and closes instantly).

**Prior-session detection:** Claude Code stores per-directory sessions under
`~/.claude/projects/<encoded-path>/*.jsonl`, where `<encoded-path>` is the
worktree's absolute path with every character outside `[A-Za-z0-9-]` replaced
by `-` (e.g. `/Users/tk/Projects/acme` → `-Users-tk-Projects-acme`; verified
against a real `~/.claude/projects/` including dots and spaces in paths). The
worktree "has a prior session" when that directory contains at least one
`*.jsonl` file. If the encoding ever drifts from Claude Code's, the failure
mode is benign: a fresh `claude` starts instead of `--continue`, or
`--continue` runs and Claude itself reports nothing to resume.

## Implementation

### Files touched

- **`./margay`** — add `margay::cmd_claude`; wire into the `main()` `case`;
  update the one-line `usage:` / `help` string.
- **`lib/engine.sh`** — two small pure helpers, unit-testable without tmux,
  git, or the filesystem:
  - `margay::tmux_session_name <path>` — echoes the sanitized basename.
  - `margay::claude_project_dir <path>` — echoes the encoded
    `~/.claude/projects/...` directory for an absolute path.
- **`README.md`** — document the subcommand.
- **`test/margay_test.sh`** — unit tests (below).

### Helpers

```bash
# worktree path → tmux session name (basename; '.' and ':' → '-')
margay::tmux_session_name() {
  local base="${1##*/}"
  echo "${base//[.:]/-}"
}

# absolute path → Claude Code per-project session dir
margay::claude_project_dir() {
  local enc
  enc="$(echo "$1" | sed 's/[^A-Za-z0-9-]/-/g')"
  echo "${CLAUDE_CONFIG_DIR:-$HOME/.claude}/projects/$enc"
}
```

`margay::cmd_claude` composes these with the guard checks, `has-session`, and
the attach/create branching described above. Detection at the call site:

```bash
cmd="claude"
if compgen -G "$(margay::claude_project_dir "$WT")/*.jsonl" >/dev/null; then
  cmd="claude --continue"
fi
```

### Usage string (updated)

```
usage: margay up [worktree] [service ...] [--use NAME=PORT|URL] [--fresh|--empty]
     | down [worktree|--all] | claude [worktree] | status | worktrees
```

(When the approved `new`/`rm` spec lands, `claude [worktree]` slots into that
usage string the same way.)

## Testing

- **`test/margay_test.sh` (unit):**
  - `margay::tmux_session_name` — plain basename, basename with dots
    (`acme.web` → `acme-web`), basename with a colon.
  - `margay::claude_project_dir` — plain path, path with dots and spaces,
    honors `CLAUDE_CONFIG_DIR` override.
  - Guard: `margay claude` dies with the tmux message when `tmux` is not on
    PATH (run with a stripped PATH).
- **Manual verification** (needs a live terminal, not scriptable in the
  suite): attach-or-create from outside tmux, `switch-client` from inside
  tmux, idempotence (second invocation attaches to the same session), fresh
  `claude` in a worktree with no prior session.

## Out of scope (YAGNI)

- No service windows inside the session (services stay backgrounded via
  `up`).
- No flags (`--shell`, `--fresh`, etc.).
- No tmux session cleanup on `margay rm` — can be added when the `new`/`rm`
  spec is implemented.

## Decisions (resolved during brainstorming)

| Question | Decision |
|---|---|
| What moves into tmux | The Claude Code session: exit, then resume via `claude --continue` inside tmux. |
| Invocation | margay subcommand run from the shell (not a Claude slash command). |
| Session naming | Worktree directory basename, `.`/`:` sanitized to `-`. |
| Command name | `margay claude`. |
| Session exists | Attach / switch-client; never spawn a second Claude. |
| No prior Claude session | Fall back to plain `claude` in the worktree. |
| Conf requirement | None — works without `.margay.conf`. |
