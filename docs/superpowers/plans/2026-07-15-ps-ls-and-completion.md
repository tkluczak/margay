# margay `ps`/`ls` + shell completion — Implementation Plan

> **STATUS: EXECUTED on `feat/ps-ls-completion`. Three code snippets below were
> WRONG and are corrected inline, each marked `CORRECTED`. Do not copy this
> plan's code as reference without reading those notes — read the shipped code
> instead. What was wrong:**
> 1. **Task 3** — guarding `config_load` with `&&` does not stop `set -e` from
>    aborting on a failing statement *inside* the sourced conf. Broke the
>    silence contract (rc=1). Needs a subshell.
> 2. **Task 4** — splitting zsh candidates from flags with `grep '^--'`
>    misgroups a worktree whose basename starts with `--`. Replaced by an
>    explicit `kind` field in `__complete`'s output.
> 3. **Task 5** — `grep -q 'zsh/site-functions'` false-positives on Homebrew's
>    own `FPATH=".../share/zsh/site-functions:${FPATH}"` line, silently
>    skipping margay's fpath entry so completion never loads.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add `ps`/`ls` aliases and TAB completion of worktree/service names for `margay up` and `margay down`.

**Architecture:** Purely additive. Candidate derivation goes into `lib/engine.sh` as two pure functions that read joined worktree rows on stdin (unit-testable without git — the pattern `worktrees_join`/`worktree_resolve` already use). A thin hidden entrypoint command `margay __complete <up|down>` supplies git+conf context and calls them. Two dumb shell scripts render the output: zsh as a `menu-select` carousel, bash as a plain list. No existing command's behavior changes.

**Tech Stack:** bash 3.2+ (macOS system bash), zsh completion system (`_describe`, `zsh/complist`), `jq`, `git`.

**Spec:** `docs/superpowers/specs/2026-07-15-ps-ls-and-completion-design.md`

## Global Constraints

- **The silence contract:** `margay __complete` MUST always exit 0, print nothing to stderr, and print nothing to stdout on any failure path (not a git repo; no `.margay.conf`; unreadable registry). A completion helper that errors dumps garbage onto the user's prompt mid-TAB. This is why it MUST NOT call `margay::context` (which calls `die`).
- `__complete` MUST NOT source `env_file` — completion is side-effect-free and fast.
- `__complete` MUST NOT appear in either usage string in `main()`, exactly as `conf-json` already doesn't.
- Idle sandbox/db columns are the **ASCII hyphen `-`**, not an em-dash — that is what `margay::worktrees_join` already emits via `${sandbox:--}`.
- Existing names keep working: `status` and `worktrees` are never removed.
- Target bash is macOS system bash **3.2** — no associative arrays, no `mapfile`.
- Test style: no framework. `test/margay_test.sh` sources `lib/*.sh` and uses `assert_eq`/`assert_ok`/`assert_fail`. `test/integration_test.sh` runs `"$MARGAY"` in a fixture repo and uses `assert_contains`. Match the surrounding style.

---

### Task 1: Pure candidate helpers in `lib/engine.sh`

**Files:**
- Modify: `lib/engine.sh` (append to the `# ---- worktrees ----` section, after `margay::worktrees_join`)
- Test: `test/margay_test.sh` (append before the `# --- projects.json` section)

**Interfaces:**
- Consumes: `margay::worktrees_join` output format — `path<TAB>branch<TAB>sandbox<TAB>db`, one row per worktree, `-` when idle.
- Produces:
  - `margay::complete_up_candidates <services>` — joined rows on **stdin**, space-separated service list as **$1**. Emits `candidate<TAB>description` lines: one per worktree (basename, description = sandbox column), then one per service (name, description = literal `service`). Always rc 0.
  - `margay::complete_down_candidates` — joined rows on **stdin**, no args. Emits `candidate<TAB>description` for worktrees whose sandbox column is not `-`, then `--all<TAB>every sandbox everywhere`. Always rc 0.

- [ ] **Step 1: Write the failing tests**

Append to `test/margay_test.sh`, immediately before the `# --- projects.json (static project registry) ---` line:

```bash
# --- completion candidates ---
CROWS="$(printf '%s\n' \
  "/tmp/prj	main	-	-" \
  "/tmp/prj/.claude/worktrees/feat-x	feature/x	api:7100 ui:7160	mydb" \
  "/tmp/prj/.claude/worktrees/det	HEAD	-	-")"

UPC="$(margay::complete_up_candidates "api ui" <<<"$CROWS")"
assert_eq "prj	-" "$(printf '%s\n' "$UPC" | sed -n 1p)" "up cand: idle worktree keeps ASCII -"
assert_eq "feat-x	api:7100 ui:7160" "$(printf '%s\n' "$UPC" | sed -n 2p)" "up cand: live worktree shows service:port"
assert_eq "det	-" "$(printf '%s\n' "$UPC" | sed -n 3p)" "up cand: detached worktree by basename"
assert_eq "api	service" "$(printf '%s\n' "$UPC" | sed -n 4p)" "up cand: services follow worktrees"
assert_eq "ui	service" "$(printf '%s\n' "$UPC" | sed -n 5p)" "up cand: second service"
assert_eq "5" "$(printf '%s\n' "$UPC" | grep -c .)" "up cand: no extra rows"

DNC="$(margay::complete_down_candidates <<<"$CROWS")"
assert_eq "feat-x	api:7100 ui:7160" "$(printf '%s\n' "$DNC" | sed -n 1p)" "down cand: only live worktrees"
assert_eq "--all	every sandbox everywhere" "$(printf '%s\n' "$DNC" | sed -n 2p)" "down cand: --all offered"
assert_eq "2" "$(printf '%s\n' "$DNC" | grep -c .)" "down cand: idle worktrees absent"

assert_eq "--all	every sandbox everywhere" "$(margay::complete_down_candidates </dev/null)" "down cand: empty input still offers --all"
assert_eq "" "$(margay::complete_up_candidates "" </dev/null)" "up cand: empty input, no services → empty"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash test/margay_test.sh 2>&1 | tail -15`
Expected: FAIL lines mentioning `complete_up_candidates` / `complete_down_candidates` — bash reports `command not found`, so the `assert_eq` comparisons come back empty and the suite exits 1.

- [ ] **Step 3: Write the implementation**

Append to `lib/engine.sh`, directly after the closing `}` of `margay::worktrees_join`:

```bash
# Completion candidates for `up`: worktrees (by basename, described by their
# live sandbox) then declared services. Joined rows on stdin, services in $1.
# Emits "candidate<TAB>description". Pure: no git, no registry, never fails.
margay::complete_up_candidates() {
  local services="${1:-}" path branch sandbox db svc
  while IFS=$'\t' read -r path branch sandbox db; do
    [[ -z "$path" ]] && continue
    printf '%s\t%s\n' "${path##*/}" "$sandbox"
  done
  for svc in $services; do
    printf '%s\tservice\n' "$svc"
  done
  return 0
}

# Completion candidates for `down`: only worktrees that actually have a live
# sandbox (stopping an idle one is a no-op), plus --all. Joined rows on stdin.
margay::complete_down_candidates() {
  local path branch sandbox db
  while IFS=$'\t' read -r path branch sandbox db; do
    [[ -z "$path" ]] && continue
    [[ "$sandbox" == "-" ]] && continue
    printf '%s\t%s\n' "${path##*/}" "$sandbox"
  done
  printf -- '--all\tevery sandbox everywhere\n'
  return 0
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash test/margay_test.sh 2>&1 | tail -15`
Expected: the 11 new `ok:` lines, and a final `all passed`.

- [ ] **Step 5: Commit**

```bash
git add lib/engine.sh test/margay_test.sh
git commit -m "feat(engine): pure completion-candidate helpers for up/down"
```

---

### Task 2: `ps` / `ls` aliases

**Files:**
- Modify: `margay` — `main()` case block and both usage strings (currently lines ~297-312)
- Test: `test/integration_test.sh` (one helper at the top; assertions appended before the final `echo "----"` summary block)

**Note:** `integration_test.sh` currently defines only `assert_contains`. Tasks 2-4 need `assert_eq` and `assert_ok` too — add them once, next to `assert_contains` at the top (Step 1), not mid-file.

**Interfaces:**
- Consumes: existing `margay::cmd_status`, `margay::cmd_worktrees` (unchanged).
- Produces: `margay ps` and `margay ls` as dispatchable subcommands.

- [ ] **Step 1: Write the failing tests**

First add the two missing helpers at the top of `test/integration_test.sh`, on the line directly after the existing `assert_contains` definition (they mirror the wording `test/margay_test.sh` uses):

```bash
assert_eq()   { if [[ "$1" == "$2" ]]; then echo "ok: $3"; else echo "FAIL: $3 — expected [$1] got [$2]"; FAILS=$((FAILS+1)); fi; }
assert_ok()   { if "$@"; then echo "ok: $*"; else echo "FAIL: expected success: $*"; FAILS=$((FAILS+1)); fi; }
```

Then append the assertions, immediately before the final `echo "----"` line:

```bash
# --- ps / ls aliases ---
assert_eq "$(cd "$REPO" && "$MARGAY" status)" "$(cd "$REPO" && "$MARGAY" ps)" "ps is byte-identical to status"
assert_eq "$(cd "$REPO" && "$MARGAY" worktrees)" "$(cd "$REPO" && "$MARGAY" ls)" "ls is byte-identical to worktrees"
help_out="$(cd "$REPO" && "$MARGAY" help)"
assert_contains "$help_out" "ps" "help mentions ps"
assert_contains "$help_out" "ls" "help mentions ls"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash test/integration_test.sh 2>&1 | tail -12`
Expected: FAIL on "ps is byte-identical to status" — `margay ps` hits the `*)` catch-all and prints `margay: unknown subcommand: ps` to stderr, so its stdout is empty and does not match `status`'s table.

- [ ] **Step 3: Write the implementation**

In `margay`, in `main()`, replace these two case arms:

```bash
    status)   margay::cmd_status ;;
    worktrees) margay::cmd_worktrees ;;
```

with:

```bash
    status|ps)      margay::cmd_status ;;
    worktrees|ls)   margay::cmd_worktrees ;;
```

Then replace **both** usage strings (the `help)` arm and the `*)` arm) with this identical text, leading with the short names:

```
usage: margay up [worktree] [service ...] [--use NAME=PORT|URL|none] [--fresh|--empty] | down [worktree|--all] | ps (status) | ls (worktrees) | unregister [path|project] | ui [--port N] [--proxy-port N]
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash test/integration_test.sh 2>&1 | tail -12`
Expected: `ok: ps is byte-identical to status`, `ok: ls is byte-identical to worktrees`, `ok: help mentions ps`, `ok: help mentions ls`, then `all passed`.

- [ ] **Step 5: Commit**

```bash
git add margay test/integration_test.sh
git commit -m "feat(cli): ps and ls aliases for status and worktrees"
```

---

### Task 3: The hidden `__complete` subcommand

**Files:**
- Modify: `margay` — add `margay::cmd_complete` (place it directly after `margay::cmd_worktrees`), and dispatch it in `main()`
- Test: `test/integration_test.sh` (append after the Task 2 block)

**Interfaces:**
- Consumes: `margay::complete_up_candidates` / `margay::complete_down_candidates` (Task 1); `margay::primary_worktree`, `margay::worktrees_parse`, `margay::worktrees_join`, `margay::config_find`, `margay::config_load` (existing).
- Produces: `margay __complete <up|down>` printing `candidate<TAB>description` lines. Consumed by Task 4's shell scripts.

**Why this cannot reuse `margay::context`:** `context` calls `die` when outside a git repo or when no conf is found, which writes to stderr and exits 1 — violating the Global Constraints silence contract. `cmd_complete` re-derives the same context with every failure short-circuiting to a silent `return 0`. It also skips `context`'s `env_file` sourcing and `projects_learn` write, both of which are side effects a TAB press must not cause.

- [ ] **Step 1: Write the failing tests**

Append to `test/integration_test.sh`, after the Task 2 block:

```bash
# --- __complete ---
cmpl="$(cd "$REPO" && "$MARGAY" __complete up 2>/dev/null)"
assert_contains "$cmpl" "wt-b" "__complete up lists the worktree basename"
assert_contains "$cmpl" "$(printf 'api\tservice')" "__complete up lists api as a service"
assert_contains "$cmpl" "$(printf 'ui\tservice')" "__complete up lists ui as a service"
dcmpl="$(cd "$REPO" && "$MARGAY" __complete down 2>/dev/null)"
assert_contains "$dcmpl" "--all" "__complete down offers --all"

# silence contract: exit 0, empty stdout, empty stderr on every failure path
NOGIT="$(mktemp -d)"
err="$( (cd "$NOGIT" && "$MARGAY" __complete up) 2>&1 1>/dev/null )"; rc=$?
assert_eq "" "$err" "__complete outside a git repo: silent stderr"
assert_eq "0" "$rc" "__complete outside a git repo: exit 0"
assert_eq "" "$( (cd "$NOGIT" && "$MARGAY" __complete up) 2>/dev/null )" "__complete outside a git repo: empty stdout"

NOCONF="$(mktemp -d)"
( cd "$NOCONF" && git init -q && git commit -q --allow-empty -m init )
err2="$( (cd "$NOCONF" && "$MARGAY" __complete up) 2>&1 1>/dev/null )"; rc2=$?
assert_eq "" "$err2" "__complete with no conf: silent stderr"
assert_eq "0" "$rc2" "__complete with no conf: exit 0"
# a conf-less repo still has worktrees to offer, just no services
assert_contains "$( (cd "$NOCONF" && "$MARGAY" __complete up) 2>/dev/null )" "$(basename "$NOCONF")" \
  "__complete with no conf still lists worktrees"

if [[ "$help_out" == *__complete* ]]; then
  echo "FAIL: __complete leaked into help"; FAILS=$((FAILS+1))
else echo "ok: __complete is hidden from help"; fi
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash test/integration_test.sh 2>&1 | tail -14`
Expected: FAIL on "__complete up lists the worktree basename" (stdout empty — `__complete` hits the `*)` catch-all) and FAIL on "__complete outside a git repo: silent stderr" (the catch-all prints `margay: unknown subcommand: __complete` and exits 1).

- [ ] **Step 3: Write the implementation**

In `margay`, add this function directly after the closing `}` of `margay::cmd_worktrees`:

```bash
# Hidden completion helper — consumed by completions/_margay and
# completions/margay.bash, never by humans (kept out of the usage line).
# Silence contract: ALWAYS exit 0, never write stderr, print nothing on any
# failure path — a completion helper that errors dumps garbage on the user's
# prompt. Hence the soft context: no margay::context (it calls die), no
# env_file sourcing, no projects_learn.
margay::cmd_complete() {
  local what="${1:-}" rows joined conf primary
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  primary="$(margay::primary_worktree 2>/dev/null)" || return 0
  rows="$(git worktree list --porcelain 2>/dev/null)" || return 0
  joined="$(printf '%s\n' "$rows" | margay::worktrees_parse | margay::worktrees_join 2>/dev/null)" || return 0
  case "$what" in
    up)
      local wt svcs=""
      wt="$(git rev-parse --show-toplevel 2>/dev/null)" || return 0
      # conf is optional here: a conf-less repo still has worktrees to offer.
      # CORRECTED — the line below was originally:
      #   margay::config_load "$conf" >/dev/null 2>&1 && svcs="${services:-}"
      # which is BROKEN. config_load does `source "$conf"` in the LIVE shell,
      # and this entrypoint runs under `set -euo pipefail`. The `&&` guards
      # only config_load's own rc — NOT statements inside the sourced conf. A
      # conf with any unguarded non-zero command (e.g. a bare `command -v
      # docker >/dev/null`) aborted the process with rc=1, breaking the
      # silence contract. The subshell contains the errexit trip; the inner
      # (...) is also load-bearing, scoping 2>/dev/null over BOTH commands so
      # config_load's own _cerr output cannot leak to stderr.
      if conf="$(margay::config_find "$wt" "$primary" 2>/dev/null)"; then
        svcs="$( (margay::config_load "$conf" && printf '%s' "${services:-}") 2>/dev/null )" || svcs=""
      fi
      printf '%s\n' "$joined" | margay::complete_up_candidates "$svcs"
      printf -- '--fresh\tdrop and recreate the db\n'
      printf -- '--empty\tcreate the db without seeding\n'
      printf -- '--use\tNAME=PORT|URL|none — override a dependency\n'
      ;;
    down)
      printf '%s\n' "$joined" | margay::complete_down_candidates
      ;;
  esac
  return 0
}
```

In `main()`, add the dispatch arm directly below `conf-json)`. It MUST NOT be added to either usage string:

```bash
    __complete) margay::cmd_complete "$@" ;;
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bash test/integration_test.sh 2>&1 | tail -14`
Expected: all new lines `ok:`, including `ok: __complete is hidden from help`, then `all passed`.

- [ ] **Step 5: Verify the silence contract by hand**

Run: `cd /tmp && /Users/tk/Tools/margay/margay __complete up; echo "rc=$?"`
Expected: exactly one line of output, `rc=0`. Any other stdout or stderr is a Global Constraints violation — fix before committing.

- [ ] **Step 6: Commit**

```bash
git add margay test/integration_test.sh
git commit -m "feat(cli): hidden __complete subcommand for shell completion"
```

---

### Task 4: zsh + bash completion scripts

**Files:**
- Create: `completions/_margay` (zsh)
- Create: `completions/margay.bash` (bash)
- Test: `test/integration_test.sh` (append after the Task 3 block)

**Interfaces:**
- Consumes: `margay __complete <up|down>` (Task 3), emitting `candidate<TAB>description`.
- Produces: two files for Task 5's `install.sh` to wire up.

**zsh note:** `$words[1]` is `margay` itself, **not** the subcommand — the subcommand is `$line[1]` under `_arguments -C`. `_describe` wants `name:description` pairs, so the TAB in `__complete`'s output is translated to `:`, and any literal `:` in a description is escaped first (`_describe` treats `:` as its separator).

- [ ] **Step 1: Write the failing test**

Append to `test/integration_test.sh`, after the Task 3 block:

```bash
# --- completion scripts ---
COMPDIR="$HERE/../completions"
assert_ok test -f "$COMPDIR/_margay"
assert_ok test -f "$COMPDIR/margay.bash"
assert_ok bash -n "$COMPDIR/margay.bash"
if command -v zsh >/dev/null 2>&1; then
  assert_ok zsh -n "$COMPDIR/_margay"
else
  echo "ok(skip): zsh not installed — skipping _margay syntax check"
fi
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/integration_test.sh 2>&1 | tail -8`
Expected: FAIL on `test -f .../completions/_margay` — the directory does not exist yet.

- [ ] **Step 3: Write the zsh script**

Create `completions/_margay`:

**CORRECTED.** The original `_margay_pairs` + `grep '^--'` split shown here was
replaced. `__complete` now emits a third `kind` field (`worktree`/`service`/
`flag`) and the script groups on it, because a `--`-prefixed split misgroups a
worktree whose directory basename starts with `--` (git constrains branch
names that way, but not worktree directory basenames). Grouping by kind also
lets the script call `__complete` **once** per TAB instead of twice — each call
costs a `git worktree list` plus a per-worktree `jq` pass. Read the shipped
`completions/_margay` for the real thing; the corrected shape is:

```zsh
#compdef margay sandbox
# zsh completion for margay. Renders `margay __complete` output; computes
# nothing itself — the targeting grammar lives in margay, not here.

# Turn "candidate<TAB>description<TAB>kind" lines whose kind field matches the
# awk condition in $2 into _describe's "candidate:description" pairs.
# Descriptions may contain ':' (e.g. "api:7100"), which _describe treats as its
# separator — so escape those before swapping the TAB. The kind field is used
# only for filtering; it is dropped before _describe ever sees it.
_margay_filter() {
  awk -F'\t' "$2"' { print $1 "\t" $2 }' <<<"$1" | sed 's/:/\\:/g; s/\t/:/'
}

_margay() {
  local -a cmds
  cmds=(
    'up:start a sandbox'
    'down:stop a sandbox'
    'ps:running sandboxes (alias of status)'
    'ls:worktrees and their sandboxes (alias of worktrees)'
    'status:running sandboxes'
    'worktrees:worktrees and their sandboxes'
    'unregister:forget a project'
    'ui:web control panel'
    'help:usage'
  )

  local curcontext="$curcontext" state line
  _arguments -C ':command:->cmd' '*::arg:->args' && return 0

  case "$state" in
    cmd) _describe -t commands 'margay command' cmds ;;
    args)
      # $line[1] is the subcommand ($words[1] is 'margay' itself)
      case "$line[1]" in
        up)
          local raw
          raw="$(margay __complete up 2>/dev/null)"
          local -a wts flags
          wts=("${(@f)$(_margay_filter "$raw" '$3!="flag"')}")
          flags=("${(@f)$(_margay_filter "$raw" '$3=="flag"')}")
          _describe -t worktrees 'worktree or service' wts
          _describe -t flags 'flag' flags
          ;;
        down)
          local rawd
          rawd="$(margay __complete down 2>/dev/null)"
          local -a dwts
          dwts=("${(@f)$(_margay_filter "$rawd" '1')}")
          _describe -t worktrees 'worktree' dwts
          ;;
      esac
      ;;
  esac
}

_margay "$@"
```

- [ ] **Step 4: Write the bash script**

Create `completions/margay.bash`:

```bash
# bash completion for margay. Renders `margay __complete` output; computes
# nothing itself. bash has no menu-select carousel — TAB lists candidates.
# shellcheck shell=bash

_margay_bash() {
  local cur prev cands
  cur="${COMP_WORDS[COMP_CWORD]}"

  if (( COMP_CWORD == 1 )); then
    COMPREPLY=( $(compgen -W "up down ps ls status worktrees unregister ui help" -- "$cur") )
    return 0
  fi

  case "${COMP_WORDS[1]}" in
    up|down)
      # cut -f1: drop the descriptions, bash shows bare candidates
      cands="$(margay __complete "${COMP_WORDS[1]}" 2>/dev/null | cut -f1)"
      COMPREPLY=( $(compgen -W "$cands" -- "$cur") )
      ;;
    *) COMPREPLY=() ;;
  esac
  return 0
}

complete -F _margay_bash margay sandbox
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash test/integration_test.sh 2>&1 | tail -8`
Expected: `ok: test -f .../_margay`, `ok: test -f .../margay.bash`, `ok: bash -n ...`, and the zsh syntax check (or its skip line), then `all passed`.

- [ ] **Step 6: Verify the carousel by hand**

This is the one thing the suite cannot check — driving zsh's interactive menu in CI costs more than it protects.

```bash
cd /Users/tk/Tools/margay
zsh -f -c 'fpath=(./completions $fpath); autoload -Uz compinit; compinit -u; zmodload zsh/complist; zstyle ":completion:*" menu select; PATH="$PWD:$PATH"; print "now type: margay up <TAB>"; exec zsh -i'
```

Expected: `margay up` + TAB shows a highlighted list under a `worktree or service` heading; ↑↓ cycle the highlight; Enter accepts. Type `exit` to leave. If candidates appear but the highlight doesn't move, `menu select` isn't active — confirm `zmodload zsh/complist` ran.

- [ ] **Step 7: Commit**

```bash
git add completions/_margay completions/margay.bash test/integration_test.sh
git commit -m "feat(completions): zsh carousel + bash TAB completion for up/down"
```

---

### Task 5: `install.sh` wiring + README

**Files:**
- Modify: `install.sh` (insert after the symlink block, before the "Migrate from the old ~/bin location" block)
- Modify: `README.md` (command table + an install note)

**Interfaces:**
- Consumes: `completions/_margay`, `completions/margay.bash` (Task 4).
- Produces: no code interface — this is the last task.

**Idempotency:** `install.sh` is idempotent by contract (its own header says so) and re-runs on every update. Every write below is guarded by a `grep -q` presence check, matching the existing `.margay.conf` gitignore-guard style.

- [ ] **Step 1: Write the installer block**

In `install.sh`, insert after the `case ":$PATH:"` block and before the `# Migrate from the old ~/bin location:` comment:

```bash
# Shell completion. zsh gets a menu-select carousel; bash gets plain TAB.
zfunc="$HOME/.local/share/zsh/site-functions"
mkdir -p "$zfunc"
ln -sf "$HERE/completions/_margay" "$zfunc/_margay"
echo "✔ symlinked $zfunc/_margay"
zrc="${ZDOTDIR:-$HOME}/.zshrc"
if [[ -f "$zrc" ]]; then
  # CORRECTED — this guard was originally `grep -q 'zsh/site-functions'`, an
  # unanchored match over the whole file. Homebrew's documented macOS setup
  # adds FPATH="$(brew --prefix)/share/zsh/site-functions:${FPATH}", which
  # contains that substring — so margay's fpath line was silently skipped and
  # completion never loaded. Match the literal line we ourselves write.
  if ! grep -qF "fpath=($zfunc \$fpath)" "$zrc" 2>/dev/null; then
    printf '\n# margay completion\nfpath=(%s $fpath)\n' "$zfunc" >> "$zrc"
    echo "✔ added $zfunc to fpath in $zrc"
  fi
  # The carousel needs complist + the menu-select style. Never clobber a
  # user's existing menu style — only add one if they have none.
  if ! grep -q "zstyle ':completion:\*' menu" "$zrc" 2>/dev/null; then
    printf "zmodload zsh/complist\nzstyle ':completion:*' menu select\n" >> "$zrc"
    echo "✔ enabled zsh menu-select (arrow-key carousel) in $zrc"
  else
    echo "! $zrc already sets a completion menu style — leaving it alone"
  fi
  echo "  restart zsh (or: exec zsh) to pick up completion"
fi
brc="$HOME/.bashrc"
if [[ -f "$brc" ]] && ! grep -q 'completions/margay.bash' "$brc" 2>/dev/null; then
  printf '\n# margay completion\n[ -f "%s" ] && source "%s"\n' \
    "$HERE/completions/margay.bash" "$HERE/completions/margay.bash" >> "$brc"
  echo "✔ sourced margay bash completion from $brc"
fi
```

- [ ] **Step 2: Verify the installer is idempotent**

Run it twice and confirm the second run adds nothing:

```bash
cp ~/.zshrc /tmp/zshrc.bak 2>/dev/null || true
bash install.sh >/dev/null 2>&1
before="$(grep -c margay ~/.zshrc 2>/dev/null || echo 0)"
bash install.sh >/dev/null 2>&1
after="$(grep -c margay ~/.zshrc 2>/dev/null || echo 0)"
[[ "$before" == "$after" ]] && echo "PASS: idempotent ($before lines both runs)" || echo "FAIL: $before → $after"
```

Expected: `PASS: idempotent`. If it FAILs, a `grep -q` guard isn't matching what it writes. Restore with `cp /tmp/zshrc.bak ~/.zshrc` if needed.

- [ ] **Step 3: Confirm the full suite still passes**

Run: `bash test/margay_test.sh 2>&1 | tail -3 && bash test/integration_test.sh 2>&1 | tail -3`
Expected: `all passed` from both. (`install.sh` runs the unit suite itself on every install, so a red suite breaks installation.)

- [ ] **Step 4: Update the README**

In `README.md`, add these rows to the command table (match the existing row format — check it first, don't assume):

```
| `margay ps` | running sandboxes across all projects (alias: `status`) |
| `margay ls` | this repo's worktrees and their sandboxes (alias: `worktrees`) |
```

And add this note to the install section:

```markdown
### Tab completion

`install.sh` wires up completion for both zsh and bash. In zsh, `margay up <TAB>`
opens a carousel of this repo's worktrees (with their live `service:port`s) and
declared services — arrow keys cycle it, Enter accepts. `margay down <TAB>` offers
only worktrees that actually have something running, plus `--all`.

Restart your shell after installing. If the list appears but arrows don't move a
highlight, your `.zshrc` sets its own completion menu style — margay leaves that
alone. Add `zmodload zsh/complist; zstyle ':completion:*' menu select` to opt in.
```

- [ ] **Step 5: Commit**

```bash
git add install.sh README.md
git commit -m "feat(install): wire up zsh/bash completion; document ps/ls"
```

---

## Verification

After Task 5, the whole feature end-to-end:

- [ ] `bash test/margay_test.sh` → `all passed`
- [ ] `bash test/integration_test.sh` → `all passed`
- [ ] `cd /tmp && margay __complete up; echo rc=$?` → no output, `rc=0` (silence contract)
- [ ] `margay help` → shows `ps` and `ls`, does **not** show `__complete`
- [ ] `margay ps` and `margay ls` → same output as `status` / `worktrees`
- [ ] In a fresh zsh: `margay up <TAB>` → carousel; ↑↓ cycle; Enter accepts
- [ ] `margay down <TAB>` → only worktrees with live sandboxes, plus `--all`
