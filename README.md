# margay

Worktree sandbox runner — stand in any git worktree, `margay up`, and get that
branch's services running in isolation (own ports, own branch-keyed DB, env
inherited from the primary checkout). A very good tree climber.

Per-project config: `.margay.conf` in the repo's primary checkout (shell DSL,
compose-style services). See `examples/` and `docs/`.

State: `~/.margay/` (registry + logs). Tests: `bash test/margay_test.sh`.

## Install (new machine)

Plain bash — no build step. Dependencies: bash 3.2+, jq, git, lsof
(docker only if a project's conf uses postgres hooks).

```bash
git clone <this-repo> ~/Projects/tools/margay
bash ~/Projects/tools/margay/install.sh   # symlinks ~/bin/margay, guards .margay.conf in the global gitignore, runs the test suite
```

Then drop a machine-local `.margay.conf` (see `examples/`) into each project
repo's primary checkout. Updates: `git pull` — nothing to rebuild.

```
usage: margay up [worktree] [service ...] [--use NAME=PORT|URL] [--fresh|--empty] | down [worktree|--all] | status | worktrees
```

## Conf authoring notes

- **Vite projects:** invoke vite directly and `exec` it —
  `exec pnpm exec vite --port "$PORT" --strictPort`. `pnpm run dev -- --port`
  (or any `pnpm <script> -- --port` form) does **not** forward the flag
  through to the underlying `vite` process, so the sandbox silently binds
  Vite's default port instead of the one margay allocated. See
  `examples/*.conf` for the pattern in context.
- **Env layering guarantee:** `env_file` (from the primary checkout) is
  sourced first, `set -a`; the engine's own `PORT`/`DB_NAME`/`DB_URL`/
  `<DEP>_PORT`/`<DEP>_URL` variables and anything your `start()` fn exports
  are applied after and win over whatever `env_file` set. Don't re-source
  `env_file` inside `start()` — it would undo that ordering.
- **`start()` should `exec` the final process.** Whatever PID margay
  captures from the backgrounded subshell is what `down`/`status` track;
  if `start()` doesn't `exec` into the real server (e.g. it's a wrapper
  script that forks), margay ends up killing the wrapper and orphaning
  the actual process.

## Worktrees

- `margay worktrees` — every worktree of the current repo with its live
  sandboxes (`service:port`) and branch DBs. Works without a `.margay.conf`.
- `margay up <worktree> [service ...]` / `margay down <worktree>` — target
  another worktree from wherever you stand (the main tree included).
  `<worktree>` matches the directory basename or branch name, exactly or as
  a unique substring: `margay up feat-payments`. A name that is also a
  declared service resolves as the service (a note tells you when — only
  when the name exactly matches a worktree's basename or branch, not on a
  mere substring hit).
- When the target worktree carries its own committed `.margay.conf`,
  service names are validated against *that* conf: a service declared only
  there is valid, and one declared only in the primary conf is rejected.
