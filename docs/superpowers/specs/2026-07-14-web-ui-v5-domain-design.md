# margay ui v5 — custom base domain / network-exposed mode (`--domain`)

**Status:** Approved, not yet implemented.
**Date:** 2026-07-14
**Builds on:** ui v4 (#5) + on_up hook (#6).

## Motivation

Development moves to a headless homelab VM reached over VPN. Sandboxes must
be reachable from other devices at `http://<svc>.<wt>.<proj>.devel.local/`
(wildcard DNS `address=/devel.local/<VM-IP>` via dnsmasq — user-managed),
not through per-client tunnels. Today margay hardcodes the `.localhost`
suffix and deliberately refuses non-loopback peers on both the proxy and
the control panel.

## Decisions

| Question | Decision |
|---|---|
| Knob | one flag: `margay ui --domain devel.local` (default from `MARGAY_DOMAIN` env, else `localhost`) |
| Exposure | a non-`localhost` domain **implies** exposure: proxy and UI bind the wildcard address and accept remote peers; with the default `localhost` behavior is bit-for-bit today's (loopback-locked) |
| Hostnames | suffix swap only: `<proj>.<domain>`, `<wt>.<proj>.<domain>`, `<svc>.<wt>.<proj>.<domain>` |
| Control panel | in domain mode `origin_ok` additionally accepts `Host`/`Origin` = `<domain>:<ui-port>` (DNS-rebinding check retained, just widened to the declared name) |
| Hooks | ui.py exports `MARGAY_DOMAIN` to the margay CLI it shells; `margay::launch` computes `MARGAY_ROOT_HOST`/`MARGAY_SERVICE_HOST` with suffix `${MARGAY_DOMAIN:-localhost}` — on_up (Keycloak) registrations automatically carry the real domain |
| Security posture | exposure is VPN/firewall's job; README states plainly that `--domain` serves every sandbox and the control panel to whatever can reach the VM |
| Linux `:80` | out of scope for code; README server note: run the UI under systemd with `AmbientCapabilities=CAP_NET_BIND_SERVICE`, or use `--proxy-port 8080` (URLs then carry the port) |

## Implementation sketch

- `lib/ui.py`: module `DOMAIN = {"name": "localhost"}`; `--domain` flag +
  `MARGAY_DOMAIN` env default; replace the string-literal `localhost`
  suffixes in `build_routes()`/`state()`; `exposed()` helper =
  `DOMAIN != "localhost"`; `ProxyServer.verify_request` and the
  per-request guard pass when exposed; bind order: exposed → wildcard
  directly; `origin_ok` accepts the domain host; `run_margay` env gains
  `MARGAY_DOMAIN`.
- `margay` (engine): on_up host computation suffix `${MARGAY_DOMAIN:-localhost}`.
- Tests: second UI instance with `--domain devel.test` — state URL suffixes,
  proxy routing by `Host: web.<wt>.fake.devel.test`, control API accepts
  `Host: devel.test:<port>` and still 403s unknown hosts; python-import
  asserts on the exposed guard; integration: `MARGAY_DOMAIN=devel.test
  margay up` → hook sees `*.devel.test` hosts.

## Out of scope

- Path-based routing, TLS, auth on the proxy — VPN is the perimeter.
- dnsmasq/Keycloak-authority/VM systemd config (documented, not managed).
