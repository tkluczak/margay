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

### Tab completion

`install.sh` wires up completion for both zsh and bash. In zsh, `margay up <TAB>`
opens a carousel of this repo's worktrees (with their live `service:port`s) and
declared services — arrow keys cycle it, Enter accepts. `margay down <TAB>` offers
only worktrees that actually have something running, plus `--all`.

Restart your shell after installing. If the list appears but arrows don't move a
highlight, your `.zshrc` sets its own completion menu style — margay leaves that
alone. Add `zmodload zsh/complist; zstyle ':completion:*' menu select` to opt in.

## Usage

```
usage: margay up [worktree] [service ...] [--use NAME=PORT|URL|none] [--fresh|--empty] | down [worktree|--all] | ps (status) | ls (worktrees) | unregister [path|project] | ui [--port N] [--proxy-port N]
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
margay up web --use backend=none   # start with NO backend (needs uses_optional=1;
                                   # the start hook can e.g. enable mock mode)

margay up feat-payments        # target another worktree by branch or dirname
margay up feat-payments web    # one service in that worktree

margay status              # everything margay is running, across all projects
margay ps                  # alias for status
margay worktrees           # this repo's worktrees + their live sandboxes/DBs
margay ls                  # alias for worktrees
margay down                # stop the current worktree's sandboxes
margay down feat-payments  # stop another worktree's
margay down --all          # stop everything margay started
```

### `margay ui [--port N] [--proxy-port N] [--domain D] [--trusted-proxy]` (and `--no-browser`)

Local web control panel at `http://127.0.0.1:7997` (foreground; Ctrl-C stops).
Shows every project you have ever run `margay up` in (auto-learned into
`~/.margay/projects.json`) in a two-pane layout: a left sidebar tree —
project → service (one node per registered repo's declared service; repos
sharing a `project` name merge under one heading) → worktree (named by
directory, primary checkout shown as **primary**, running rows annotated
with their pairing, e.g. `→ backend :8190`) — and a right pane with the
selected worktree's detail. Pressing **up** on a service that declares a
dependency pairs explicitly: one live instance pairs silently, several open
a picker, none offers mock mode / `main_port` when the dependency is
optional. The log area fills the remaining window height (drag the divider
to pin it). The detail
pane shows a summary (name, branch, path, one-click up/down) with a dedicated
URLs block (root URL and one line per running service, clickable), followed by
auto-opened log tabs — one per running service, plus a command tab for up/down
output; all tabs are per-worktree and tab state (active tab, follow flag) is
remembered.

While the UI runs it also serves a reverse proxy on port 80 (override with
`--proxy-port`), giving every sandbox a stable address instead of a port:
`http://<worktree>.<project>.localhost/` (the primary checkout is
`http://<project>.localhost/`; individual services at
`http://<service>.<worktree>.<project>.localhost/`). The control panel itself
is reachable at `http://margay.localhost/` through the same proxy
(or `http://margay.localhost:N/` with `--proxy-port N`). WebSockets are
proxied, so HMR and realtime features work. If port 80 is taken the UI
falls back to plain `localhost:<port>` links (both sandboxes and the control
panel; startup advertises which URL to use). On macOS the proxy binds the
wildcard address (loopback-only enforced per connection) because the OS
restricts low-port binds on specific addresses. Needs `python3` (stdlib
only); the rest of margay does not.

#### Running on a server / VM (`--domain`)

By default everything is loopback-locked. `--domain devel.local` (or
`MARGAY_DOMAIN=devel.local` in the environment) switches the hostname scheme
to `http://<service>.<worktree>.<project>.devel.local/` for sandboxes and
`http://margay.devel.local/` for the control panel, **and exposes both
the proxy and the control panel to the network** — any device that can reach
the VM can browse sandboxes and press up/down. Your VPN/firewall is the
perimeter; margay adds no auth in this mode. Note: `margay.<domain>` is
reserved for the control panel; a project literally named `margay` loses the
proxy hostname to it and falls back to port-based URLs instead.

Checklist for a homelab VM:

- **DNS:** wildcard the domain at your resolver, e.g. dnsmasq/Pi-hole
  `address=/devel.local/<VM-IP>`. (mDNS alone cannot resolve wildcard
  subdomains — you need a real DNS server for `*.devel.local`.)
- **Port 80 on Linux:** binding ports below 1024 needs privilege. Either run
  the UI with `AmbientCapabilities=CAP_NET_BIND_SERVICE` under a *system*
  systemd unit, use `--proxy-port 8080` (URLs then carry `:8080`), or front it
  with a reverse proxy that owns 80/443 (next bullet).
- **Behind a reverse proxy (Nginx Proxy Manager etc.):** run margay's proxy on
  an unprivileged port and let NPM terminate TLS on `<domain>`. Point one NPM
  proxy host at `*.<domain> → http://<vm>:8080` with **Websockets Support on**
  and the **Host header preserved** (NPM's default — margay routes entirely on
  `Host`). Then add `--trusted-proxy`: the control panel (`margay.<domain>`)
  accepts requests behind TLS termination, and every sandbox link it shows
  points at the public `https://<host>/` origin instead of margay's internal
  `:<proxy-port>`. Both honour `X-Forwarded-Proto/Host` **only** when forwarded
  over loopback, so the panel's own CSRF/origin guard keeps working while a
  cross-origin `Origin` is still rejected. A non-standard TLS front (e.g.
  `:8443`) is carried through into the links via `X-Forwarded-Host`. See
  `examples/margay-ui.service` for a ready systemd user unit.
  (If NPM runs in Docker, `<vm>` is the host gateway — `host.docker.internal`
  or the bridge IP — not `127.0.0.1`, which is the container itself.)
- **Hooks:** `service_<name>_on_up()` sees the real hostnames
  (`MARGAY_ROOT_HOST=<wt>.<proj>.devel.local`), so e.g. Keycloak
  redirect-URI registration follows the domain automatically. Set
  `MARGAY_DOMAIN` in the shell too if you run `margay up` over SSH directly.
- **Apps with absolute localhost URLs** (e.g. an OIDC authority of
  `http://localhost:8788`) must be pointed at the domain
  (`http://devel.local:8788`) in the machine-local conf/env — remote
  browsers can't reach the VM's localhost.

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

## Cross-repo pairs (frontend ↔ backend)

A frontend repo declares its backend with
`service_web_uses_project="<project>:<service>"`. On `up`, margay resolves
the pairing in this order: an explicit `--use <dep>=<port|url|none>` →
last-started live instance of that service → `main_port` (non-optional
services only) → error. The result is injected into `start()` as
`<DEP>_PORT`/`<DEP>_URL` and recorded per instance (visible in `status` and
the UI). Add `service_<name>_uses_optional=1` to make the dependency
optional: with no live instance (or `--use <dep>=none`) the service starts
with those vars **unset**, and the start hook decides what that means —
`examples/spendprism-webapp.margay.conf` flips the app into its MSW mock
mode.

**Keeping the proxy URL through an OIDC login (Keycloak):** if the app pins
its redirect with an env var (e.g. `VITE_OIDC_REDIRECT_URI`), the login
round-trip lands back on `localhost:<port>` and abandons the
per-worktree proxy URL. Blank the var in the generated `.env.local` so the
app falls back to `window.location.origin`, and loosen the **dev** realm
client once — Valid redirect URIs `*`, Valid post-logout redirect URIs `+`,
Web origins `*` (hostname wildcards like `http://*.p.localhost` are not
valid Keycloak patterns, hence the catch-all; dev realms only):

```bash
kcadm.sh update clients/<client-uuid> -r <realm> \
  -s 'redirectUris=["*"]' -s 'webOrigins=["*"]' \
  -s 'attributes."post.logout.redirect.uris"="+"'
```

Prefer to keep the realm strict? Skip the wildcard and let margay register
each sandbox's exact origins instead: declare `service_<name>_on_up()` —
margay runs it after every successful `up` with `MARGAY_ROOT_HOST` /
`MARGAY_SERVICE_HOST` set to the proxy hostnames (and `PORT`), so the hook
can idempotently append `http://$MARGAY_ROOT_HOST/*` etc. to the client's
redirect URIs (set Web origins to `+` once so CORS follows the redirect
list). A failing hook only warns — the sandbox still comes up. See the
`service_web_on_up()` example in `examples/spendprism-webapp.margay.conf`.

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
