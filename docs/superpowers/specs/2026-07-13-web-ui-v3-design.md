# margay ui v3 — two-pane layout (worktree list → detail), macOS :80 bind fix

**Status:** Implemented.
**Date:** 2026-07-13
**Builds on:** `2026-07-13-web-ui-v2-design.md` (merged as PR #2).

## Motivation

Living with the v2 card grid surfaced two problems. First, the URLs — the
feature's whole point — have no prominent home: a running card shows one root
link, service URLs hide in dock tab headers, and idle cards show nothing when
the proxy is down. Second, on stock macOS the proxy never actually binds:
`bind(127.0.0.1, 80)` requires root (macOS only exempts *wildcard* binds from
the privileged-port rule), so every user silently got the fallback. v3
replaces the grid+dock with the master-detail layout (mockup A revisited) and
fixes the bind.

## Scope decisions

| Question | Decision |
|---|---|
| Layout | **two-pane**: worktree list left (grouped by project), selected worktree's detail right — summary on top, log tabs below |
| Log tabs | **pre-opened** for every running service of the selected worktree, plus a command tab when up/down has run; no chip-clicking |
| Tab state | remembered **per worktree** (open command tab, active tab, follow flags); switching worktrees swaps the whole tab set |
| URLs | a dedicated **URLs block** in the summary: root URL + one line per service URL, clickable; port-form when the proxy is down |
| :80 bind | try `127.0.0.1:<port>` first; on `EACCES` retry the **wildcard** address with a loopback-only peer guard; warn + fall back only if both fail |
| Server API | **unchanged** — v2's `/api/state` fields already carry everything the new page needs |

## The :80 bind fix (`lib/ui.py`)

macOS (Mojave+) exempts only wildcard binds from the privileged-port rule;
`bind("127.0.0.1", 80)` fails `EACCES` for normal users. New bind sequence in
`main()`:

1. `ThreadingHTTPServer(("127.0.0.1", args.proxy_port), ProxyHandler)` — works
   on platforms that allow it and for high `--proxy-port` values everywhere.
2. On `PermissionError`/`EACCES`: retry `ThreadingHTTPServer(("", args.proxy_port), …)`
   (wildcard). Security posture is preserved by a **peer guard**: a module
   function `loopback_peer(ip) -> bool` (true for `127.*`, `::1`,
   `::ffff:127.*`) checked as the first act of every ProxyHandler request;
   non-loopback peers get a 403 and connection close. The UI listener (7997,
   unprivileged) keeps its plain `127.0.0.1` bind and strict Host guard.
3. If both binds fail: today's warning + port-link fallback.

Startup prints which mode bound (`margay proxy → …` line unchanged; add
`(wildcard bind, loopback-only)` suffix in the wildcard case).

Tests: `loopback_peer()` truth table in the python harness; the existing
random-high-port proxy tests keep exercising path 1; the wildcard path gets a
dedicated test that binds `("", port)` explicitly (high port — the EACCES
trigger itself isn't reproducible without root) and asserts both that loopback
requests succeed and the guard rejects a spoofed non-loopback peer (unit-level
via `loopback_peer`).

## Page rebuild (`lib/ui.html`)

Still one file, vanilla JS, no framework, no external resources; `esc()`/
`jsq()` discipline unchanged. Full-height flex row:

- **Left sidebar** (fixed width ~240px, scrollable): per project a header
  (project name, remove-✕; muted primary path in a tooltip) and one row per
  worktree: status dot, name (**primary** label for the primary checkout),
  compact up/down button. Selected row highlighted. Nothing else.
- **Right pane, top — summary** for the selected worktree: name + branch +
  full path (copyable text, not tooltip-only here), the **URLs block** — root
  URL first, then one `service → url` line each (subdomain form when the
  proxy is up, `localhost:<port>` otherwise; collision badge when relevant) —
  plus db names and pids, and the same up/down button.
- **Right pane, below — logs**: tab strip + panes, mechanics carried over
  from v2's dock (offset polling, follow toggle, 256 KiB cap, drag-resize of
  the summary/logs divider persisted in `localStorage`), but scoped to the
  selected worktree and **auto-opened**: selecting a worktree opens one tab
  per running service (active = first service); command output from up/down
  goes to that worktree's command tab, auto-focused.
- **Selection model**: client-side; last selection remembered in
  `localStorage` (keyed by worktree path); default = first running worktree,
  else first worktree. The 2 s poll re-renders sidebar and summary; log panes
  update in place exactly as v2's dock did. A worktree that disappears
  (pruned project) falls back to the default selection.
- Empty state (no projects) unchanged from v2.

## Testing

- Python harness: `loopback_peer()` truth table (`127.0.0.1`, `127.9.9.9`,
  `::1`, `::ffff:127.0.0.1` true; `192.168.1.10`, `10.0.0.1`, `2001:db8::1`
  false).
- Wildcard-bind proxy test: start a ui instance with the wildcard path forced
  (new internal env `MARGAY_UI_WILDCARD=1` used only by tests to skip attempt
  1), assert routing still works via 127.0.0.1 requests.
- Page smoke asserts updated: `id="sidebar"`, `id="detail"`, `id="logtabs"`
  markers replace the grid/dock markers.
- All v2 server tests unchanged and green.
- Manual eyeball: selection switching, pre-opened tabs, URLs block accuracy
  (proxy up and down), command tab, divider resize, both color schemes.

## Out of scope

Unchanged from v2: service pickers, fresh/empty toggles, log search, worktree
creation, HTTPS. The v2 follow-up list (cross-level slug overlap, 502 listing
restriction, etc.) remains separate.
