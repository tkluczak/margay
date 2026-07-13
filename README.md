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
bash ~/Projects/tools/margay/install.sh   # symlinks ~/.local/bin/margay, guards .margay.conf in the global gitignore, runs the test suite
```

Then drop a machine-local `.margay.conf` (see `examples/`) into each project
repo's primary checkout. Updates: `git pull` — nothing to rebuild.

## Usage

```
usage: margay up [worktree] [service ...] [--use NAME=PORT|URL] [--fresh|--empty] | down [worktree|--all] | status | worktrees
```

From inside any worktree of a configured repo:

```bash
margay up                  # every declared service, in dependency order
margay up web              # just web; its declared dep resolves to a running
                           # instance (start it first, or pass --use)
margay up api --fresh      # drop + recreate the branch DB before starting
margay up api --empty      # create the branch DB but skip seeding
margay up web --use api=8300                              # pin a dep to a port…
margay up web --use backend=https://staging.acme.dev:443  # …or a URL

margay up feat-payments        # target another worktree by branch or dirname
margay up feat-payments web    # one service in that worktree

margay status              # everything margay is running, across all projects
margay worktrees           # this repo's worktrees + their live sandboxes/DBs
margay down                # stop the current worktree's sandboxes
margay down feat-payments  # stop another worktree's
margay down --all          # stop everything margay started
```

### `margay ui [--port N] [--proxy-port N]` (and `--no-browser`)

Local web control panel at `http://127.0.0.1:7997` (foreground; Ctrl-C stops).
Shows every project you have ever run `margay up` in (auto-learned into
`~/.margay/projects.json`) in a two-pane layout: a left sidebar listing all
worktrees grouped by project (named by directory, primary checkout shown as
**primary**) and a right pane with the selected worktree's detail. The detail
pane shows a summary (name, branch, path, one-click up/down) with a dedicated
URLs block (root URL and one line per running service, clickable), followed by
auto-opened log tabs — one per running service, plus a command tab for up/down
output; all tabs are per-worktree and tab state (active tab, follow flag) is
remembered.

While the UI runs it also serves a reverse proxy on port 80 (override with
`--proxy-port`), giving every sandbox a stable address instead of a port:
`http://<worktree>.<project>.localhost/` (the primary checkout is
`http://<project>.localhost/`; individual services at
`http://<service>.<worktree>.<project>.localhost/`). WebSockets are
proxied, so HMR and realtime features work. If port 80 is taken the UI
falls back to plain `localhost:<port>` links. On macOS the proxy binds the
wildcard address (loopback-only enforced per connection) because the OS
restricts low-port binds on specific addresses. Needs `python3` (stdlib
only); the rest of margay does not.

### `margay unregister [path|project]`

Remove a project from the UI's list (defaults to the current repo). Touches
nothing else — no worktrees, databases, or processes — and the project
re-appears on the next `margay up` there.

What that looks like (with the `examples/rust-vite.margay.conf` setup):

```
$ margay up
▶ acme · branch feat-payments
  ✔ api up → http://localhost:8285   (pid 4711, log: ~/.margay/logs/acme-feat_payments-api.log)
  api → http://localhost:8285
  ✔ web up → http://localhost:5283   (pid 4712, log: ~/.margay/logs/acme-feat_payments-web.log)

$ margay status
PROJECT  SERVICE  BRANCH         PORT  DB                     USES
acme     api      feat-payments  8285  acme_sb_feat_payments  -
acme     web      feat-payments  5283  -                      http://localhost:8285
```

Flags (mutually exclusive where noted):

- `--fresh` — drop and recreate the branch DB (re-seeds when `db="seed"`).
  Mutually exclusive with `--empty`.
- `--empty` — create the branch DB without seeding, even for `db="seed"`.
- `--use NAME=PORT|URL` — satisfy a dependency explicitly instead of resolving
  it. Without it, a dep resolves to a running instance in the same worktree
  first, then the most recently started instance anywhere, then the service's
  `main_port` fallback if declared — otherwise `up` refuses and tells you.

### Environment (.env handling)

Declare `env_file=".env.dev"` in `.margay.conf` and every sandbox inherits it
— sourced (`set -a`) from the **primary checkout**, not the worktree, so fresh
worktrees need no `.env` copying and there is one canonical env per machine.
If the file is missing from the primary checkout, `up` errors out.

Each service then starts with this layering, later layers winning:

1. `env_file` from the primary checkout.
2. Engine variables: `PORT` (always); `DB_NAME` + `DB_URL` when the service
   declares a db; `<DEP>_PORT` + `<DEP>_URL` when it declares `needs` or
   `uses_project` (dep name uppercased, e.g. `api` → `API_URL`).
3. Whatever your `service_<name>_start()` exports itself.

So a shared `.env.dev` can hold the defaults while each sandbox still gets its
own port and branch DB — see the layering caveats under conf authoring notes
below.

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
