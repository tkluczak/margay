# margay `ui` — local web UI: project registry, worktree up/down, live logs

**Status:** Implemented.
**Date:** 2026-07-13

## Motivation

margay's state is visible only through `margay status` and only covers what is
currently running; margay itself only knows about a project while you stand
inside its repo. The web UI adds a persistent, glanceable view: every project
you have ever margay'd, each project's worktrees, what is running where, live
log tails — and one-click `up` / `down` on any worktree without cd'ing there.
The UI is a control panel over the existing CLI, not a second engine: every
mutation shells out to `margay`, so UI-started services are indistinguishable
from terminal-started ones.

## Scope decisions

| Question | Decision |
|---|---|
| How projects become known | **auto-learn**: every `margay up` upserts the project into `$MARGAY_HOME/projects.json`; `margay unregister` (and a UI button) removes entries |
| Run controls in the UI | **plain up/down only** — all services, default DB behavior; `--fresh`, `--empty`, `--use`, per-service selection stay CLI-only |
| Server lifecycle | **on-demand foreground**: `margay ui` starts it, opens the browser, Ctrl-C stops; no daemon, no launchd |
| Implementation | **single-file Python stdlib server** (`lib/ui.py`) + one framework-free HTML page; core margay stays bash + jq |

## Static project registry: `$MARGAY_HOME/projects.json`

```json
[
  { "project": "acme", "primaryPath": "/Users/tk/Projects/acme", "lastUp": "2026-07-13T10:12:03Z" }
]
```

- **Auto-learn**: a new `margay::projects_learn` in `engine.sh`, called at the
  end of `margay::context`, upserts keyed on `primaryPath`, updating `project`
  and `lastUp`. Running `margay up` anywhere is what registers a project.
- **Removal**: new subcommand `margay unregister [path|project]` (defaults to
  the current repo); the UI's remove button calls the same logic. Removal only
  hides the project from the UI — it never touches worktrees, databases, or
  running processes. A removed project **re-appears on the next `up`**; that is
  the documented consequence of auto-learn, not a bug (no blocklist).
- **Staleness**: a `primaryPath` missing on disk renders greyed out with only
  the remove button; no auto-pruning (the path may be an unmounted volume).
- **Worktrees are never stored**: the server enumerates them live via
  `git -C <primaryPath> worktree list --porcelain`, reusing the existing
  parsing helpers, so the list is always accurate.

## Server: `lib/ui.py`

Python 3 stdlib only (`http.server`, `json`, `subprocess`). Started by
`margay ui [--port N]`; default port **7997**, binds **127.0.0.1 only**, opens
the browser on start. `ThreadingHTTPServer`; all mutating requests are
serialized behind a single lock (registry writes are not concurrent-safe),
reads stay concurrent.

### Endpoints

- `GET /` — the single HTML page.
- `GET /api/state` — everything the page needs in one call: projects from
  `projects.json`, each project's live worktree list, joined with running
  services from `registry.json` (matched on `worktreePath`; dead-pid entries
  filtered the same way `registry_prune` does). The page polls this every ~2 s.
- `GET /api/log?file=<path>&offset=<n>` — bytes from `offset` plus the new
  offset. If `offset` exceeds the file size (rotation/truncation), reset to 0
  and re-serve. **Path check**: only files under `$MARGAY_HOME/logs/` are
  served — the endpoint must not read arbitrary files.
- `POST /api/up` `{worktreePath}` / `POST /api/down` `{worktreePath}` — runs
  the real `margay up` / `margay down` with `cwd = worktreePath`, captures
  stdout+stderr, returns it (HTTP 500 on non-zero exit, body = captured
  output). The server never writes `registry.json` itself.
- `POST /api/unregister` `{primaryPath}` — shells out to
  `margay unregister <primaryPath>` (the CLI accepts an explicit path, so cwd
  does not matter). Like up/down, the server never edits margay's JSON files
  itself.

## Page

One HTML file, vanilla JS, inline CSS, no framework, no build step, no
external resources.

- **Layout**: one card per project (name + primary path); worktrees as rows
  showing branch, path, and — when running — services with clickable
  `localhost:<port>` links, DB name, pids. Stale projects grey with only a
  remove button.
- **Actions**: **Up** on an idle worktree row, **Down** on a running one.
  While in flight the row shows a spinner; the command's output lands in a
  collapsible pane on the row (failed `up` output included, verbatim).
- **Logs**: each running service has a **log** toggle opening a tail pane
  (monospace, auto-scroll with a follow toggle; initial fetch = last ~64 KB,
  then offset polling). Multiple panes may be open at once.
- **Refresh model**: full re-render from `GET /api/state` every 2 s; the only
  client state preserved across renders is which log panes are open. Terminal
  actions (`margay up` in a shell) appear within one poll tick.

Explicitly out of scope (reachable later without redesign): service pickers,
`--fresh`/`--empty` toggles, log search, worktree creation from the UI.

## Engine changes

1. `margay::registry_record` gains a **`log` field** (the service's log path)
   so the UI reads it from the registry instead of re-deriving the slugified
   filename.
2. New `margay::projects_learn` upsert in `engine.sh` (see above).
3. Dispatcher gains `unregister` and `ui`. `ui` checks for `python3` and exits
   with a clear message if missing — core margay stays usable without Python.

## Error handling

- `margay` exit codes are the source of truth; the server relays captured
  output on failure and the UI shows it verbatim.
- Missing/empty `registry.json` or `projects.json` → `/api/state` returns
  empty lists, not errors.
- A worktree whose `.margay.conf` vanished fails through the normal `up`
  error path — no special-casing.

## Testing

Following existing `test/` conventions:

- Shell tests: `projects_learn` upsert/dedupe, `unregister` (by path and by
  project name), `registry_record` `log` field.
- Server test: start `ui` on a random port against a fixture `$MARGAY_HOME`;
  curl `/api/state` (empty and populated), the log endpoint (offset advance,
  offset-reset on truncation, path-escape rejection), and `POST /api/up`
  against a mocked `margay`.
- The HTML page is eyeballed, not unit-tested.
