# margay ui v2 — subdomain proxy, worktree-name identity, card-grid + dock layout

**Status:** Implemented.
**Date:** 2026-07-13
**Builds on:** `2026-07-13-web-ui-design.md` (shipped as PR #1, branch `worktree-web-ui`).

## Motivation

Three problems surfaced from real use of the v1 UI. First, the page is noisy:
full worktree paths repeat on every row, rows are titled by long branch names,
and inline log panes push the layout around as they open. Second, worktrees
are better known by their directory names (`keycloak-auth`) than their branch
names (`feat/keycloak-resource-server-auth`). Third, port-number URLs
(`localhost:5373`) are meaningless at a glance and change between runs —
sandboxes deserve stable, readable addresses.

## Scope decisions

| Question | Decision |
|---|---|
| Proxy lifecycle | **inside `margay ui`** — same process binds :80; subdomain URLs live only while the UI runs (accepted) |
| Root subdomain per worktree | **auto: the dependency leaf** — the running service no sibling depends on; every service also gets a service-prefixed subdomain; multiple leaves → service-prefixed only |
| Primary checkout | shown as **primary** (branch muted) and addressed as the project root: `http://<project>.localhost/` |
| Row identity | **worktree directory name**; branch demoted to muted text; full path tooltip-only |
| Layout | **card grid per project + one shared bottom dock** for logs and command output (chosen over two-pane and inline-expand in mockup review) |
| Service chips | click → that service's log opens/focuses in the dock |
| up/down output | streams into a per-worktree **"last command" dock tab** (auto-opened, focused); never inline on the card |

## URL scheme

Browsers resolve `*.localhost` to loopback on their own; macOS (Mojave+)
allows unprivileged binds to port 80. Labels are slugs: lowercase,
`[^a-z0-9-]` → `-`, applied to project and worktree names.

- `http://<worktree>.<project>.localhost/` → the worktree's leaf service
- `http://<service>.<worktree>.<project>.localhost/` → that service
- `http://<project>.localhost/` → the primary checkout's leaf service
- `http://<service>.<project>.localhost/` → that service in the primary

**Leaf detection** uses only the registry: a leaf is a running service of the
worktree whose `http://localhost:<port>` does not appear in any sibling row's
`uses` field. Exactly one leaf → it owns the root URL; zero or several →
that worktree has service-prefixed URLs only.

**Slug collisions** (two worktrees slugifying identically) resolve
deterministically: earliest `startedAt` wins the subdomain; the loser falls
back to port URLs and its card shows a badge saying so.

## The proxy (in `lib/ui.py`)

A second `ThreadingHTTPServer` on its own thread, default bind `:80`
(`--proxy-port` overrides; tests always use a random port). Routing is pure
`Host`-header matching against the registry, re-read per request (no cache).

- **Plain requests:** streamed HTTP/1.1 forwarding to `127.0.0.1:<port>`,
  hop-by-hop headers stripped, bodies piped both ways.
- **WebSocket upgrades:** forward the handshake; on `101` splice the two TCP
  sockets raw (`select` loop) until either side closes. Vite HMR and the
  realtime multiplexer must work through it. (Vite's default `allowedHosts`
  already accepts `*.localhost` — no app-side config.)
- **Unknown host / stopped sandbox:** a minimal 502 page listing the URLs
  that are live right now. **Upstream dead mid-request:** 502 naming the
  service.
- **Bind failure on :80** (occupied, denied): log a warning, skip the proxy,
  run the UI exactly as v1 — cards fall back to `localhost:<port>` links.
  The proxy is an enhancement, never a requirement.
- The strict Host guard on the 7997 control-panel listener is unchanged; the
  proxy listener accepts `*.localhost` hosts (that is its job) and never
  serves the control-panel API.

## `/api/state` additions

All derivation happens server-side so the page stays dumb. Each worktree
gains: `name` (directory basename), `isPrimary`, `slug`, `url` (subdomain
root, or `null` when the proxy is down / no unique leaf / slug collision
loser), and `hintUrl` (the would-be root URL, always present while the proxy
is up — idle cards render it greyed and non-clickable, per the approved
mockup). Each service row gains `url` (service-prefixed subdomain, or the
`localhost:<port>` fallback).

## Page rebuild (`lib/ui.html`)

Still one file, vanilla JS, no framework, no external resources.

- **Cards** in a responsive grid per project
  (`auto-fill, minmax(220px, 1fr)`): status dot, worktree name (or
  **primary**), muted branch, subdomain link, service chips when running,
  up/down button. Project header bar carries the project name, muted
  primary path, and the remove-✕.
- **Dock**: fixed-height bottom panel, drag-to-resize (height persisted in
  `localStorage`). Tabs: one per open log (`worktree · service`) plus one
  "last command" slot per worktree. Tab header line shows that service's
  direct URL, pid, and db. Follow toggle and clear per tab.
- **Render discipline:** the 2 s poll re-renders the card grid only; the
  dock updates in place — the offset-poller appends text, scroll position
  and follow state survive. This also retires two v1 annoyances: log-pane
  scroll reset and the command-output pane reopening every poll.
- Dock state (open tabs, active tab, height) lives in a client-side map
  keyed by `worktree/service`, surviving re-renders like v1's `openLogs`.

## Error handling

- Proxy errors are user-visible pages (502 + live-URL list), not silent
  drops.
- The UI works fully without the proxy; `/api/state` signals the fallback
  by `url: null` → cards render port links.
- Registry/projects file corruption behaves as in v1 (empty lists).

## Testing

Extends `test/ui_test.sh`'s live-server pattern; the proxy binds a random
port in tests (never :80).

- Routing via `curl -H 'Host: …'` against a fixture registry and a mock
  upstream (tiny python HTTP server on a random port): worktree root → leaf,
  service prefix, primary as project root, unknown host → 502, collision
  behavior.
- Leaf detection: web+backend fixture (backend's URL in web's `uses`) → web
  owns the root; two independent services → no root mapping.
- WebSocket tunnel: mock upstream completes the 101 handshake and echoes
  bytes; a short python client through the proxy asserts the echo.
- Bind-failure fallback: occupy the proxy port first; assert the UI still
  serves and `/api/state` URLs are `null`/port-form.
- Page smoke asserts updated for the new DOM (cards, dock markers).
- Manual eyeball in a real browser, including one full sandbox round-trip
  through subdomain URLs (app loads, HMR websocket connects, logs tail).

## Out of scope (unchanged from v1)

Service pickers, `--fresh`/`--empty` toggles, log search, worktree creation
from the UI, HTTPS on the proxy.
