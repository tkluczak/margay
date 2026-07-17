# margay ui v6 — control panel at `margay.<domain>` — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Serve the margay control panel at `http://margay.localhost/` through the proxy that already routes every sandbox, instead of only `localhost:7997`.

**Architecture:** Purely additive, entirely inside `lib/ui.py`. `build_routes()` already returns a `{host → upstream port}` dict that `_proxy` looks up; the panel becomes one more entry pointing at the UI's own port. Seeding that entry *before* the project loop makes the panel win any name collision through the existing collision branch, with no new code path. `origin_ok()` must widen to accept the proxied `Host`, because `_proxy` forwards it verbatim.

**Tech Stack:** Python 3 stdlib only (`http.server`, `http.client`, `socket`, `threading`) — `lib/ui.py` has no third-party deps and must keep none.

**Spec:** `docs/superpowers/specs/2026-07-15-ui-v6-control-panel-host-design.md`

## Global Constraints

- **The reserved host is `"margay." + DOMAIN["name"]`** — `margay.localhost` by default. Derive it from `DOMAIN["name"]`, never hardcode `"margay.localhost"`; `--domain` changes the suffix at runtime.
- **`build_routes()` keeps its `(routes, info)` signature.** `_proxy` unpacks it as `routes, _ = build_routes()` (`lib/ui.py:423`); a third return value breaks that call site.
- **No change to `state()`, `host_url()`, `ProxyHandler`, `peer_ok`, `lib/ui.html`, or the `margay` CLI.** If a task seems to need one, stop — the design is wrong.
- **The existing rebinding guard must keep biting.** `test/ui_test.sh:221-225` asserts `Host: evil.example` → 403 and cross-site `Origin` → 403. These must still pass unchanged.
- **The panel only gets a route when the proxy actually bound.** `PROXY["port"] is None` (bind failed) → no `margay.*` route, panel reachable only at `localhost:<port>`. That is today's behavior and must not regress.
- Python 3 stdlib only — no new imports beyond what `lib/ui.py` already uses.
- Test style: no framework. `test/ui_test.sh` starts real servers on random ports and drives them with `curl`, asserting via `assert_eq`. Match it.
- **Do not reuse these shell variable names in new test code** — `test/ui_test.sh` already binds them, and shadowing one silently breaks an existing test: `PORT`, `PROXYPORT`, `UPSTREAM_PORT`, `UPSTREAM2_PORT`, `BASE`, `REPO`, `SLUG`, `MARGAY_HOME`, `DOMPORT`, `DOM_LOG`, `DOM_PID`, and **`V6PORT`** (already taken by the IPv6-loopback upstream test near the end of the file — despite "v6" here meaning "ui version 6", it means "IPv6" there). New names in this plan are prefixed `PANEL*`.
- The suite runs the proxy on a **random non-80 port**, so `margay.<domain>:<proxy-port>` is the form under test — the bare `:80` form is exercised only by the unit-level reasoning in Task 1.

---

### Task 1: The reserved route

**Files:**
- Modify: `lib/ui.py` — add `UI` module state next to `PROXY` (line ~74); seed the reserved host in `build_routes()` (line ~130-131); set `UI["port"]` in `main()` (line ~555)
- Test: `test/ui_test.sh`

**Interfaces:**
- Consumes: `DOMAIN["name"]` (module state, set by `main()` from `--domain`); `PROXY = {"port": None}` idiom at `lib/ui.py:74`.
- Produces: `UI = {"port": None}` module dict, set by `main()` once the UI listener binds. `build_routes()` returns `routes` containing `"margay." + DOMAIN["name"] → UI["port"]` whenever `UI["port"]` is set. Task 2 relies on `UI["port"]` being populated.

- [ ] **Step 1: Write the failing test**

Append to `test/ui_test.sh`, immediately before its final summary block (the `echo "----"` / FAILS report — read the end of the file and place this above it):

**Why this asserts 403 and not 200.** `do_GET` calls `origin_ok()` before
anything else (`lib/ui.py:290-292`), and widening that guard is Task 2's job —
so the panel cannot return 200 yet. But the three states are distinguishable,
which is what makes this a real test:

| state | response |
|---|---|
| no route (now) | **502** — the proxy's `_gateway_page`, via `_send_html(status=502)` (`lib/ui.py:518`) |
| route exists, guard not yet widened (after this task) | **403** — the request reached the *panel* and its guard rejected it |
| route + widened guard (after Task 2) | **200** |

A 403 therefore proves the route works: the proxy handed the request to the
UI instead of answering 502 itself. Task 2 flips this same assertion to 200.

```bash
# --- v6: control panel at margay.localhost ---
# 403 (not 200) is correct here: the route exists so the proxy forwards to the
# panel, whose origin_ok still rejects the proxied Host until Task 2 widens it.
# 502 would mean the route is missing entirely (proxy gateway page).
code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: margay.localhost" "http://127.0.0.1:$PROXYPORT/")"
assert_eq "403" "$code" "v6: margay.localhost reaches the panel through the proxy (guard widens in the next commit)"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/ui_test.sh 2>&1 | tail -8`
Expected: FAIL with **got [502]** — there is no such route, so `_proxy` falls through to `_gateway_page(routes)`, which answers 502. Seeing 502 here (rather than 403) is what proves the assertion is measuring the route's existence.

- [ ] **Step 3: Add the `UI` module state**

In `lib/ui.py`, directly below the existing `PROXY` line (~74):

```python
PROXY = {"port": None}   # set by main() once the proxy listener binds
UI = {"port": None}      # set by main() once the control-panel listener binds
```

- [ ] **Step 4: Seed the reserved host in `build_routes()`**

In `build_routes()`, replace this line (~130-131):

```python
    routes, info = {}, {}
    claimed = set()
```

with:

```python
    routes, info = {}, {}
    claimed = set()
    # The control panel reserves margay.<domain>. Seeded BEFORE the project
    # loop so a project slugged "margay" hits the existing `base in claimed`
    # branch and degrades to port links like any other slug collision — no
    # separate code path, and state()/ui.html need no changes.
    if UI["port"] is not None:
        reserved = "margay.%s" % DOMAIN["name"]
        routes[reserved] = UI["port"]
        claimed.add(reserved)
```

- [ ] **Step 5: Set `UI["port"]` in `main()`**

In `main()`, directly after the UI server binds successfully — i.e. after the `try/except OSError` block that creates `srv` (~line 555-558), before the proxy `attempts` block:

```python
    UI["port"] = args.port
```

- [ ] **Step 6: Run test to verify it passes**

Run: `bash test/ui_test.sh 2>&1 | tail -8`
Expected: `ok: v6: margay.localhost reaches the panel through the proxy` — the code moved 502 → 403 — and the suite's normal `all passed`. **The suite must be fully green before you commit.** If you still see 502, the seeding isn't taking effect; if you see 200, `origin_ok` already accepts the host and the plan's model of the code is wrong — report that rather than adjusting the assertion to match.

- [ ] **Step 7: Add the `--domain` route assertion**

The reserved host is derived from `DOMAIN["name"]`, so it must follow
`--domain`. The suite already runs a `--domain devel.test` instance (search for
`DOMPORT` / `--domain devel.test`). Add this assertion inside that block,
immediately **before** its `kill $DOM_PID` line — it must run while that
instance is alive, and it reuses that instance rather than starting another:

Same 403-not-200 reasoning as Step 1: this proves the reserved host follows
`--domain` (the request reached the panel rather than the proxy's 502 gateway).
Task 2 flips it to 200.

```bash
code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: margay.devel.test" "http://127.0.0.1:$DOMPORT/")"
assert_eq "403" "$code" "v6: margay.<domain> follows --domain (guard widens in the next commit)"
```

- [ ] **Step 8: Run the domain assertion**

Run: `bash test/ui_test.sh 2>&1 | grep -E 'follows --domain|domain:'`
Expected: `ok: v6: margay.<domain> follows --domain`, and every pre-existing `domain:` line still `ok:`.

- [ ] **Step 9: Commit**

```bash
git add lib/ui.py test/ui_test.sh
git commit -m "feat(ui): reserve margay.<domain> as a proxy route to the control panel"
```

---

### Task 2: Widen `origin_ok` for the proxied Host

**Files:**
- Modify: `lib/ui.py` — `origin_ok()` (~line 278-288)
- Test: `test/ui_test.sh`

**Interfaces:**
- Consumes: `UI["port"]` and the reserved route from Task 1; `PROXY["port"]` (`None` when the proxy didn't bind); `DOMAIN["name"]`.
- Produces: no new symbols. `origin_ok()` accepts the proxied host so control-API calls work through `margay.<domain>`.

**Why this is required, not cosmetic:** `Host` is not in `HOP_HEADERS` (`lib/ui.py:387`), so `_proxy` forwards it verbatim (`lib/ui.py:443`). A request through the proxy reaches the UI handler as `Host: margay.localhost` (or `margay.localhost:<proxy-port>`), which the current guard rejects — it accepts only `{127.0.0.1:<port>, localhost:<port>}` plus `<domain>:<port>` when exposed.

**Why it stays safe:** the guard exists so a page on `evil.com` cannot drive a panel that starts services and runs hooks — the browser stamps `Host: evil.com`, which is not in the set. Adding `margay.localhost` gives an attacker nothing: to make a browser send that `Host` it must actually navigate to `margay.localhost`, which RFC 6761 pins to loopback, and the `Origin` then matches same-origin anyway.

- [ ] **Step 1: Flip Task 1's two assertions from 403 to 200**

Task 1 asserted 403 because the guard hadn't widened yet — it proved the route
reached the panel. Widening the guard is this task, so those two assertions now
become 200. **Edit them in place; do not add duplicates.**

In `test/ui_test.sh`, in the `# --- v6: control panel at margay.localhost ---`
block, replace the assertion and its explanatory comment with:

```bash
code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: margay.localhost" "http://127.0.0.1:$PROXYPORT/")"
assert_eq "200" "$code" "v6: margay.localhost serves the panel through the proxy"
body="$(curl -s -H "Host: margay.localhost" "http://127.0.0.1:$PROXYPORT/")"
case "$body" in
  *"<html"*|*"<!doctype"*|*"<!DOCTYPE"*) echo "ok: v6: margay.localhost returns the panel HTML" ;;
  *) echo "FAIL: v6: margay.localhost returned no HTML — [${body:0:80}]"; FAILS=$((FAILS+1)) ;;
esac
```

And in the `--domain devel.test` block, replace that assertion with:

```bash
code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: margay.devel.test" "http://127.0.0.1:$DOMPORT/")"
assert_eq "200" "$code" "v6: margay.<domain> follows --domain"
```

- [ ] **Step 2: Write the new failing tests**

Append to `test/ui_test.sh`, directly after the Task 1 block:

```bash
# v6: the control API works through the proxy (this is what pins origin_ok)
code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: margay.localhost" \
     "http://127.0.0.1:$PROXYPORT/api/state")"
assert_eq "200" "$code" "v6: control API reachable via margay.localhost"
code="$(curl -s -o /dev/null -w '%{http_code}' \
     -H "Host: margay.localhost" -H "Origin: http://margay.localhost" \
     -X POST -d '{"worktreePath":"/nonexistent-v6"}' "http://127.0.0.1:$PROXYPORT/api/up")"
if [[ "$code" == "403" ]]; then
  echo "FAIL: v6: POST via margay.localhost rejected by origin_ok (403)"; FAILS=$((FAILS+1))
else
  echo "ok: v6: POST via margay.localhost passes the origin guard (got $code)"
fi
```

Note the POST asserts **not-403** rather than a specific success code: the
target worktree doesn't exist, so `/api/up` legitimately answers 4xx/5xx. What
matters is that it is not the *origin guard* rejecting it.

- [ ] **Step 3: Run tests to verify they fail**

Run: `bash test/ui_test.sh 2>&1 | grep -E 'v6:'`
Expected: **five** failing v6 assertions, all for the same reason — `origin_ok` rejecting the forwarded `Host: margay.localhost:<PROXYPORT>`:
- the two you flipped in Step 1 (panel via proxy → got 403 not 200; `--domain` → got 403 not 200)
- "margay.localhost returns the panel HTML" (the body is the 403 JSON, not HTML)
- "control API reachable via margay.localhost" (403, not 200)
- "POST via margay.localhost rejected by origin_ok (403)"

- [ ] **Step 4: Write the implementation**

In `lib/ui.py`, replace `origin_ok()` (~278-288) with:

```python
    def origin_ok(self):
        port = self.server.server_address[1]
        hosts = {"127.0.0.1:%d" % port, "localhost:%d" % port}
        if exposed():
            hosts.add("%s:%d" % (DOMAIN["name"], port))
        # Requests arriving through the proxy carry the reserved host verbatim
        # (Host is not a hop header), so it must be accepted or every control
        # action via margay.<domain> 403s. Safe: reaching this handler with
        # that Host means the browser navigated to it, which .localhost pins
        # to loopback (RFC 6761) — a cross-origin page cannot forge it.
        if PROXY["port"] is not None:
            reserved = "margay.%s" % DOMAIN["name"]
            hosts.add(reserved if PROXY["port"] == 80
                      else "%s:%d" % (reserved, PROXY["port"]))
        if self.headers.get("Host", "") not in hosts:
            return False
        origin = self.headers.get("Origin")
        if origin and origin not in {"http://%s" % h for h in hosts}:
            return False
        return True
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash test/ui_test.sh 2>&1 | grep -E 'v6:' && bash test/ui_test.sh 2>&1 | tail -3`
Expected: all five v6 assertions now `ok:`, and `all passed`.

- [ ] **Step 6: Verify the guard still bites**

Run: `bash test/ui_test.sh 2>&1 | grep -E 'rebound Host|cross-site Origin|unknown hosts|custom-domain host'`
Expected: every line `ok:`. If any became FAIL, the widening was too broad — the reserved host must be the *only* addition.

- [ ] **Step 7: Commit**

```bash
git add lib/ui.py test/ui_test.sh
git commit -m "fix(ui): accept the proxied reserved Host in origin_ok"
```

---

### Task 3: Startup URL preference, browser open, and the collision warning

**Files:**
- Modify: `lib/ui.py` — `main()` (~line 576-590)
- Test: `test/ui_test.sh`

**Interfaces:**
- Consumes: `UI["port"]` and the reserved route (Task 1); `PROXY["port"]`; `host_url(host)` (`lib/ui.py:100-103`), which already returns `http://<host>/` when the proxy is on 80 or absent and `http://<host>:<proxy-port>/` otherwise; `read_json(PROJECTS)`; `slugify(name)`.
- Produces: no new symbols — final task.

- [ ] **Step 1: Write the failing test**

Append to `test/ui_test.sh`, directly after the Task 2 block. This starts a *separate* instance with its own `MARGAY_HOME`, whose `projects.json` **and** live `registry.json` both name a project `margay` — so one fixture covers the warning, the pretty URL, and the collision degradation. Model it on the existing `--domain` instance further up the file (read that block first and match its shape).

**Variable naming:** use the `PANEL*` prefix. Do **not** use `V6PORT` — the suite already binds it for the IPv6-loopback upstream test.

`pid: $$` marks the fixture row live (the suite's main registry fixture uses the same trick, since `pid_alive` checks a real pid).

```bash
# v6: collision — a project named "margay" is shadowed by the panel
PANELHOME="$(mktemp -d)"
PANELPORT=$(( PORT + 5 )); PANELPROXY=$(( PROXYPORT + 5 ))
PANELUP=$(( UPSTREAM_PORT + 5 ))
cat > "$PANELHOME/projects.json" <<EOF
[{"project":"margay","primaryPath":"$REPO","lastUp":"2026-07-15T00:00:00Z"}]
EOF
cat > "$PANELHOME/registry.json" <<EOF
[{"project":"margay","service":"api","branch":"main","worktreePath":"$REPO","port":$PANELUP,
  "dbName":null,"uses":null,"log":null,"pid":$$,"startedAt":"2026-07-15T00:00:00Z"}]
EOF
MARGAY_HOME="$PANELHOME" python3 "$HERE/../lib/ui.py" --port "$PANELPORT" \
  --proxy-port "$PANELPROXY" --no-browser > "$PANELHOME/out.log" 2>&1 &
PANELPID=$!
for _ in $(seq 1 40); do
  curl -sf "http://127.0.0.1:$PANELPORT/api/state" >/dev/null 2>&1 && break
  sleep 0.25
done
panelout="$(cat "$PANELHOME/out.log")"
assert_contains "$panelout" "reserved" "v6: warns that project 'margay' is shadowed by the panel"
assert_contains "$panelout" "http://margay.localhost:$PANELPROXY/" \
  "v6: startup advertises the pretty panel URL"
# the panel wins the host …
code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: margay.localhost" "http://127.0.0.1:$PANELPROXY/")"
assert_eq "200" "$code" "v6: panel wins margay.localhost over the same-named project"
# … and that project degrades exactly like any other slug collision
pst="$(curl -s "http://127.0.0.1:$PANELPORT/api/state")"
PANELWT="$(jq '.projects[0].worktrees[] | select(.path=="'"$REPO"'")' <<<"$pst")"
assert_eq "true" "$(jq -r '.collision' <<<"$PANELWT")" \
  "v6: shadowed project is marked collision"
assert_eq "http://localhost:$PANELUP" \
  "$(jq -r '.services[] | select(.service=="api") | .url' <<<"$PANELWT")" \
  "v6: shadowed project falls back to port links"
kill "$PANELPID" 2>/dev/null
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash test/ui_test.sh 2>&1 | tail -10`
Expected: FAIL on the warning and the pretty-URL assertions — `main()` prints neither; its panel line is still `margay ui → http://127.0.0.1:<port>`. The three collision assertions ("panel wins", "marked collision", "port links") should already PASS if Task 1 landed correctly — they verify Task 1's seeding, and this is the first fixture that exercises it. If any of those three FAIL, stop: Task 1's seeding is wrong, and no amount of `main()` work in this task will fix it.

- [ ] **Step 3: Write the implementation**

In `lib/ui.py`'s `main()`, replace this block (~586-590):

```python
    sys.stdout.flush()
    url = "http://127.0.0.1:%d" % args.port
    print("margay ui → %s   (Ctrl-C to stop)" % url)
    if not args.no_browser:
        webbrowser.open(url)
```

with:

```python
    # Prefer the pretty URL, but only when the proxy actually bound — with no
    # proxy there is no margay.<domain> route and the port is the only way in.
    if PROXY["port"] is not None:
        reserved = "margay.%s" % DOMAIN["name"]
        url = host_url(reserved).rstrip("/")
        # Warn once if a KNOWN project would want this host. Keyed off
        # projects.json, not live registry rows, so it still fires when
        # nothing is running yet — the shadowing is a property of the name.
        if any(isinstance(p, dict) and slugify(p.get("project")) == "margay"
               for p in read_json(PROJECTS)):
            print("margay ui: warning: project 'margay' wants %s — reserved for "
                  "the control panel; that project falls back to port links" % reserved)
    else:
        url = "http://127.0.0.1:%d" % args.port
    sys.stdout.flush()
    print("margay ui → %s   (Ctrl-C to stop)" % url)
    if not args.no_browser:
        webbrowser.open(url)
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash test/ui_test.sh 2>&1 | grep -E '^(ok|FAIL).*v6:' && bash test/ui_test.sh 2>&1 | tail -3`
Expected: every `v6:` line `ok:` — the warning, the pretty URL, and the three collision assertions — then `all passed`.

- [ ] **Step 5: Verify the no-proxy fallback by hand**

The panel must stay reachable when the proxy can't bind. Occupy the proxy port, then start the UI against it:

```bash
python3 -c "
import socket, subprocess, sys, time, urllib.request
blocker = socket.socket(); blocker.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
blocker.bind(('127.0.0.1', 21999)); blocker.listen(1)
p = subprocess.Popen([sys.executable, 'lib/ui.py', '--port', '17999',
                      '--proxy-port', '21999', '--no-browser'],
                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
time.sleep(2)
try:
    code = urllib.request.urlopen('http://127.0.0.1:17999/api/state', timeout=5).getcode()
    print('panel on its port:', code, '(expect 200)')
finally:
    p.terminate(); out = p.communicate()[0]; blocker.close()
print('--- startup output ---'); print(out)
print('advertises port URL, not margay.localhost:',
      'margay.localhost' not in out and '127.0.0.1:17999' in out)
"
```

Expected: `panel on its port: 200`, the output warns it cannot bind the proxy port, `advertises port URL, not margay.localhost: True`.

- [ ] **Step 6: Commit**

```bash
git add lib/ui.py test/ui_test.sh
git commit -m "feat(ui): advertise the panel at margay.<domain>, warn on name collision"
```

---

### Task 4: README

**Files:**
- Modify: `README.md`

**Interfaces:** none — docs only.

- [ ] **Step 1: Update the README**

Find the section documenting `margay ui` and its URLs (search for `margay ui` and for the `<svc>.<wt>.<proj>.localhost` pattern — READ the surrounding formatting and match it; do not assume a table or a fence). Document:

- the control panel is at `http://margay.localhost/` when the proxy holds `:80`
- with `--proxy-port N` it is `http://margay.localhost:N/`
- when the proxy cannot bind, it falls back to `http://localhost:7997/` (or `--port N`)
- with `--domain devel.local` it is `http://margay.devel.local/`, carrying the same exposure `--domain` already implies
- `margay.<domain>` is reserved: a project named `margay` falls back to port links and startup says so

- [ ] **Step 2: Confirm the suite is still green**

Run: `bash test/ui_test.sh 2>&1 | tail -3`
Expected: `all passed`. (Docs-only, but cheap to confirm nothing else drifted.)

- [ ] **Step 3: Commit**

```bash
git add README.md
git commit -m "docs: the control panel lives at margay.<domain>"
```

---

## Verification

- [ ] `bash test/ui_test.sh` → `all passed`
- [ ] `bash test/margay_test.sh` → `all passed` (untouched, but the proxy shares the registry)
- [ ] `bash test/integration_test.sh` → `all passed`
- [ ] The rebinding guard still bites: `Host: evil.example` → 403, cross-site `Origin` → 403
- [ ] Proxy down → panel still answers on `localhost:<port>`, startup advertises the port URL
- [ ] By hand: `margay ui`, then open `http://margay.localhost/` — the panel loads, and starting/stopping a sandbox from it works (that exercises `origin_ok` on a real POST)
