# margay ui v6 — the control panel at `margay.<domain>`

**Status:** Approved, not yet implemented.
**Date:** 2026-07-15
**Builds on:** ui v2 (host-routing proxy), ui v5 (`--domain`, #7).

## Motivation

The proxy already serves every sandbox under a memorable name
(`<svc>.<wt>.<proj>.localhost`). The control panel itself — the one page you
open every day — is still at `localhost:7997`, a port you have to remember or
scroll back for. It is the only thing in margay's URL space that doesn't have
a name, and the proxy that would give it one is already running.

## Decisions

| Question | Decision |
|---|---|
| Name | `margay.<domain>` — `margay.localhost` by default |
| Replace or add | **both**: the UI keeps listening on `--port`; the proxy adds a route to it. Startup line and browser auto-open **prefer** the pretty URL, fall back to the port URL |
| Fallback | when the proxy can't bind (`:80` needs privileges), there is no route and the panel is reachable only at `localhost:<port>` — today's behavior, unchanged |
| Collision | a project slugged `margay` would also claim `margay.<domain>`. **The control panel wins.** The reserved host is seeded into `routes`/`claimed` **before** the project loop, so the existing collision branch handles the project untouched: it falls back to **port links for everything** and gets the UI's existing "slug collision — port links only" badge. Startup also **warns** — never silent. *(amended: an earlier draft had the panel's route overwrite project routes afterwards, keeping `api.margay.localhost` alive and shadowing only the root. That does not survive contact with `state()` — `collision` gates every service URL (`lib/ui.py:206`) and `hintUrl` is emitted unconditionally from `base` (`lib/ui.py:211`), so the UI would have gone on advertising `margay.localhost` for that project while the proxy served the panel there. Seeding first reuses already-tested machinery, needs no `state()`/`ui.html` change, and the existing badge is honest.)* |
| Warning trigger | only on real collision — a **known** project (in `projects.json`) whose slug is `margay`; not every boot. Keyed off known rather than *live* projects so it still fires when nothing is running yet |
| Exposed mode | works: `margay.<domain>` in `--domain` mode, mirroring v5's posture. **No new exposure** — the panel is already reachable at `<domain>:<ui-port>` there; this is the same reach under a nicer name |
| `origin_ok` | widened to accept `margay.<domain>` (and `margay.<domain>:<proxy-port>` when the proxy isn't on `:80`). Required, not optional — see below |
| Route placement | inside `build_routes()`, so every consumer (including `_gateway_page`) sees it for free |

## Why `origin_ok` must change (the load-bearing detail)

`Host` is **not** in `HOP_HEADERS` (`lib/ui.py:387`), so `_proxy` forwards it
verbatim (`lib/ui.py:443`). A request through the proxy therefore reaches the
UI handler as `Host: margay.localhost`, which today's guard rejects — it
accepts only `{127.0.0.1:<port>, localhost:<port>}` (+ `<domain>:<port>` when
exposed). Without widening, the pretty URL 403s on every control action.

**This does not weaken the rebinding defence.** The guard exists so a page on
`evil.com` cannot drive a panel that starts/stops services and runs hooks: the
browser stamps `Host: evil.com`, which isn't in the set. Adding
`margay.localhost` gives an attacker nothing — to make a browser send that
`Host`, the browser must actually navigate to `margay.localhost`, which
RFC 6761 pins to loopback; the `Origin` then matches and the request is
same-origin anyway. The existing `Host: evil.example` and cross-site `Origin`
rejections (`test/ui_test.sh:221-225`) must keep passing unchanged.

Note the safety here rests on `.localhost` being loopback-pinned **by the
resolver**, not on anything margay enforces. In `--domain` mode that pinning
does not apply — but v5 already decided a non-`localhost` domain implies
exposure, and the panel is already served to the network there.

## Data flow

```
browser → http://margay.localhost/
  → ProxyServer :80        peer_ok(client) → loopback (or exposed)
      _proxy: host = "margay.localhost"
      routes.get(host) → <ui-port>          # the new entry
  → UI Handler :7997       Host: margay.localhost (forwarded verbatim)
      origin_ok: "margay.localhost" ∈ hosts # the widened set
  → the panel
```

## Implementation sketch

- `lib/ui.py`:
  - a module-level `UI = {"port": None}` set by `main()` once the UI listener
    binds, mirroring the existing `PROXY = {"port": None}` idiom.
  - `build_routes()`: **before** the `for (project, wt_path), rows in ordered`
    loop, if `UI["port"]` is set, seed `routes[reserved] = UI["port"]` and
    `claimed.add(reserved)` where `reserved = "margay." + DOMAIN["name"]`. The
    panel wins by construction, and a project slugged `margay` then hits the
    existing `if base in claimed or base in routes` branch — no new code path.
    **Its `(routes, info)` signature is unchanged**: `_proxy` unpacks it as
    `routes, _ = build_routes()` (`lib/ui.py:423`), so adding a third return
    value would break that call site for a value only `main()` wants, once, at
    startup.
  - No change to `state()`, `host_url()`, or `lib/ui.html`.
  - The collision warning is computed in `main()` at startup, independently of
    `build_routes()`: read `projects.json` and warn if any **known** project
    slugs to `margay`. Keyed off known projects rather than live registry rows
    so the warning still fires when nothing is running yet — the shadowing is
    a property of the project's name, not of whether it happens to be up.
  - `origin_ok()`: add `margay.<domain>` to `hosts`, plus
    `margay.<domain>:<proxy-port>` when `PROXY["port"]` is set and isn't 80.
  - `main()`: after the proxy binds, print the pretty URL as the primary line;
    keep the port URL as the fallback line when it didn't. Browser auto-open
    (unless `--no-browser`) targets whichever was chosen. Emit the collision
    warning computed as described above (read directly from `projects.json`,
    independently of `build_routes()`).
- No change to `ProxyHandler`, `_tunnel` (websockets ride the same route),
  `peer_ok`, or the `margay` CLI.

## Testing

`test/ui_test.sh` already starts a real UI + proxy on random ports and drives
the proxy by `Host` header — this follows that grain. Note the suite runs the
proxy on a **random non-80 port**, so the `margay.<domain>:<proxy-port>` form
is the one under test.

- `Host: margay.localhost` through the proxy returns the panel (200 + its
  HTML), not the gateway page.
- **A control-API `POST` through the proxy succeeds.** This is the assertion
  that pins the `origin_ok` widening; without it the request 403s.
- `Host: evil.example` and cross-site `Origin` still 403 — the existing
  assertions at `test/ui_test.sh:221-225` must keep passing.
- Collision: with a project slugged `margay` live in the fixture registry,
  `margay.localhost` serves the **panel**, and that project's `state()` rows
  come back with `collision: true` and port-link service URLs — i.e. it
  degrades exactly as any other slug collision already does.
  Separately, with `margay` present in the fixture `projects.json`, startup
  prints the warning (asserted against the captured startup output).
- Proxy down: no `margay.*` route; the panel still answers on its port.
- `--domain devel.test`: `margay.devel.test` routes to the panel.

## Not doing (YAGNI)

A configurable panel hostname (`--ui-host`); HTTPS; redirecting
`localhost:<port>` → the pretty URL; a route when the proxy is down;
reserving any name other than `margay`.
