# margay ui v4 — service tree, dependency picker + mock mode, full-height logs

**Status:** Approved, not yet implemented.
**Date:** 2026-07-13
**Builds on:** `2026-07-13-web-ui-v3-design.md` (merged as PR #3) and the
IPv6-upstream proxy fix (merged as PR #4).

## Motivation

Living with v3 and a real two-repo project (spendprism webapp + service)
surfaced three problems:

1. **After Keycloak login the browser lands on `localhost:<port>`**, dropping
   the per-worktree proxy URL. The webapp pins `VITE_OIDC_REDIRECT_URI` to the
   Keycloak-registered port band; margay never overrides it.
2. **The sidebar shows one flat group per registered repo**, so a project
   split across two repos appears as two identically-named groups, and nothing
   shows which backend a frontend is paired with. Pairing itself is
   "last-started live instance" — silent and recency-based, wrong when two
   backends are up. And there is no way to start the webapp without any
   backend even though it has a mock mode (`VITE_MOCK_BOOKING=1`, MSW).
3. **The log viewport is a fixed-height box**; on a tall window most of the
   pane is dead space.

## Scope decisions

| Question | Decision |
|---|---|
| Sidebar | **tree**: project → service (per registered repo/service) → worktree; registrations merge by `project` name; ✕ (unregister) moves to the service node |
| Pairing display | worktree rows of running instances show `→ <dep> :<port>` from the registry `uses` field |
| Pairing prompt | **ask only when ambiguous**: 0 live deps → offer mock / main_port; 1 → pair silently (explicitly, not by recency); 2+ → picker |
| Mock mode | **empty dep + conf decides**: new conf flag `service_<name>_uses_optional=1`; margay starts the service with `<DEP>_URL`/`<DEP>_PORT` unset; the start hook reacts (spendprism conf sets `VITE_MOCK_BOOKING=1`) |
| CLI | new `--use NAME=none` value forces the empty-dep path; valid only when `uses_optional` is set |
| Keycloak return URL | **conf-only**: webapp start hook writes `VITE_OIDC_REDIRECT_URI=` (empty) into the generated `.env.local`; app falls back to `window.location.origin`. One-time permissive dev realm change (outside margay) |
| Logs | right pane becomes a flex column; log viewport gets `flex:1; min-height:0` and fills the window |

## Engine changes (`margay`, `lib/config.sh`, `lib/engine.sh`)

- `service_<name>_uses_optional` — validated as `0`/`1`/empty in
  `margay::config_check`.
- `margay::resolve_dep` gains a `none` override: returns empty port/url with
  rc 0. `margay::launch` exports `<DEP>_PORT`/`<DEP>_URL` only when non-empty,
  records `uses: null` in the registry for the mock case.
- When resolution finds **no candidate** and `uses_optional=1`, launch
  proceeds with the empty-dep path instead of dying (CLI prints
  `backend → none (optional)`), keeping `main_port` as an *explicit* choice
  rather than a silent fallback: the automatic chain becomes
  live-instance → (optional? none : main_port → error).
  *Note this changes today's behavior only for services that opt in.*
- Deterministic single-candidate pairing: when exactly one live instance
  matches, it is chosen as today — no change needed beyond surfacing it.

## Server changes (`lib/ui.py`)

- `/api/state`: each running instance additionally exposes `uses` (the URL
  recorded at launch); each service block exposes `usesProject`,
  `usesOptional`, `mainPort` (parsed from the conf via the existing
  `margay <cmd> --json` plumbing or conf introspection — implementation
  detail for the plan).
- New `GET /api/pair-options?reg=<id>&service=<svc>`: returns
  `{candidates: [{project, service, branch, worktree, port}], optional: bool,
  mainPort: int|null}` — live instances of the dependency, pruned.
- `POST /api/up` accepts an optional `use` field, passed through as
  `--use <dep>=<value>` (`<port>` or `none`).

## UI changes (`lib/ui.html`)

- Sidebar tree per Scope; project header is a plain label (no ✕), service
  nodes carry the ✕ and the repo path tooltip.
- "up" on a service with a declared dependency first calls
  `/api/pair-options`:
  - 1 candidate → immediate `POST /api/up` with `use=<port>`;
  - 2+ → inline picker (right pane, replaces the summary block until
    answered): one row per candidate (`worktree · :port`), plus
    "mock mode — no backend" when `optional`;
  - 0 → if `optional`: "start in mock mode" / "start against main
    (:mainPort)" buttons; else the existing error toast plus a hint naming
    the dependency service to start first.
- Running worktree rows annotate pairing: `→ backend :8190`.
- Layout: `.detail { display:flex; flex-direction:column; height:100% }`,
  log viewport `flex:1; min-height:0; overflow-y:auto`.

## Out-of-repo steps (documented in README "cross-repo pairs" section)

- Keycloak dev realm, client `spendprism-webapp`: Valid redirect URIs `*`,
  Valid post-logout redirect URIs `+`, Web origins `*`
  (`kcadm.sh update clients/<id> -r spendprism -s 'redirectUris=["*"]'
  -s 'attributes."post.logout.redirect.uris"="+"' -s 'webOrigins=["*"]'`).
- `spendprism-webapp/.margay.conf`: append `VITE_OIDC_REDIRECT_URI=` to the
  generated `.env.local`; branch on `BACKEND_URL` for mock mode:

  ```bash
  service_web_uses_optional=1
  service_web_start() {
    { echo "VITE_API_URL=/api"; echo "VITE_OIDC_REDIRECT_URI="; } > .env.local
    if [[ -z "${BACKEND_URL:-}" ]]; then
      export VITE_MOCK_BOOKING=1
    else
      export VITE_API_URL=/api API_PROXY_TARGET="$BACKEND_URL"
    fi
    exec pnpm exec vite --port "$PORT" --strictPort
  }
  ```

## Testing (`test/ui_test.sh`)

- engine: `--use dep=none` with `uses_optional=1` → service starts, dep env
  vars unset in the child (assert via a start hook that echoes them);
  `--use dep=none` without the flag → error; no live dep + optional → starts
  with empty dep; no live dep + not optional + no main_port → error.
- server: `/api/pair-options` for 0/1/2 live candidates; `uses` surfaced in
  `/api/state`; `POST /api/up` forwards `use`.
- ui (DOM-less assertions as in v3): state regrouping produces one project
  node with two service children for two same-project registrations.
- Keycloak redirect: conf-only, verified manually (login lands back on
  `http://web.<wt>.spendprism.localhost/`).

## Non-goals

- Re-pairing a running instance (still restart).
- Branch-matched auto-pairing (deferred; picker covers the ambiguous case).
- Margay managing Keycloak realm config.
