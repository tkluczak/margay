#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export MARGAY_HOME="$(mktemp -d)"
mkdir -p "$MARGAY_HOME/logs"
PORT=$(( (RANDOM % 2000) + 18000 ))
PROXYPORT=$(( (RANDOM % 2000) + 21000 ))
UPSTREAM_PORT=$(( (RANDOM % 2000) + 23000 ))
UPSTREAM2_PORT=$(( (RANDOM % 2000) + 25000 ))
BASE="http://127.0.0.1:$PORT"
FAILS=0
BUSY_PID=""
FB_PID=""
WILD_PID=""
assert_eq()       { if [[ "$1" == "$2" ]]; then echo "ok: $3"; else echo "FAIL: $3 — expected [$1] got [$2]"; FAILS=$((FAILS+1)); fi; }
assert_contains() { if [[ "$1" == *"$2"* ]]; then echo "ok: $3"; else echo "FAIL: $3 — [$1] lacks [$2]"; FAILS=$((FAILS+1)); fi; }

# fixture: a primary repo + a worktree (for proxy routing test)
PRIMARY="$(cd "$(mktemp -d)" && pwd -P)"
( cd "$PRIMARY" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
REPOBASE="$(cd "$(mktemp -d)" && pwd -P)"
REPO="$REPOBASE/wt"
( cd "$PRIMARY" && git worktree add -q "$REPO" -b test )
cat > "$MARGAY_HOME/projects.json" <<EOF
[{"project":"fake","primaryPath":"$PRIMARY","lastUp":"2026-07-13T00:00:00Z"},
 {"project":"gone","primaryPath":"/nonexistent/margay-test","lastUp":"2026-07-01T00:00:00Z"}]
EOF
LOG="$MARGAY_HOME/logs/fake-main-api.log"
printf 'hello log\n' > "$LOG"

# mock upstream standing in for running services (python one-liner servers)
python3 -c '
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"upstream says hi from " + self.path.encode()
        self.send_response(200); self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Upstream", "mock"); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
' "$UPSTREAM_PORT" &
UPSTREAM_PID=$!
python3 -c '
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"upstream says hi from " + self.path.encode()
        self.send_response(200); self.send_header("Content-Length", str(len(body)))
        self.send_header("X-Upstream", "mock"); self.end_headers(); self.wfile.write(body)
    def log_message(self, *a): pass
http.server.ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
' "$UPSTREAM2_PORT" &
UPSTREAM2_PID=$!
trap 'kill $UI_PID $UPSTREAM_PID $UPSTREAM2_PID 2>/dev/null' EXIT

# Registry fixture: REPO worktree has services on the mock upstream ports, web is the leaf
cat > "$MARGAY_HOME/registry.json" <<EOF
[{"project":"fake","service":"api","branch":"main","worktreePath":"$REPO","port":$UPSTREAM_PORT,
  "dbName":null,"uses":null,"log":"$LOG","pid":$$,"startedAt":"2026-07-13T00:00:00Z"},
 {"project":"fake","service":"web","branch":"main","worktreePath":"$REPO","port":$UPSTREAM2_PORT,
  "dbName":null,"uses":"http://localhost:$UPSTREAM_PORT","log":null,"pid":$$,"startedAt":"2026-07-13T00:00:01Z"},
 {"project":"fake","service":"dead","branch":"main","worktreePath":"$REPO","port":9999,
  "dbName":null,"uses":null,"log":null,"pid":999999,"startedAt":"2026-07-13T00:00:02Z"}]
EOF

# mock margay for POST endpoints (up succeeds, down fails)
MOCK="$MARGAY_HOME/mock-margay"
cat > "$MOCK" <<'EOF'
#!/usr/bin/env bash
echo "mock: $* (cwd=$PWD)"
[[ "$1" == "down" ]] && exit 1
exit 0
EOF
chmod +x "$MOCK"
export MARGAY_BIN="$MOCK"

python3 "$HERE/../lib/ui.py" --port "$PORT" --proxy-port "$PROXYPORT" --no-browser &
UI_PID=$!
sleep 0.5  # allow upstreams to bind first
up=0
for _ in $(seq 1 25); do
  curl -sf "$BASE/api/state" >/dev/null 2>&1 && { up=1; break; }
  sleep 0.2
done
assert_eq "1" "$up" "server answers /api/state"

st="$(curl -s "$BASE/api/state")"
assert_eq "fake"  "$(jq -r '.projects[0].project' <<<"$st")"          "state: projects sorted by name"
assert_eq "true"  "$(jq -r '.projects[0].exists'  <<<"$st")"          "state: live project exists=true"
assert_eq "false" "$(jq -r '.projects[1].exists'  <<<"$st")"          "state: stale project exists=false"
assert_eq "0"     "$(jq -r '.projects[1].worktrees | length' <<<"$st")" "state: stale project has no worktrees"
# Find the worktree with services (should be REPO, likely at index 1)
WT_WITH_SERVICES="$(jq -r '.projects[0].worktrees | map(select(.services | length > 0)) | .[0]' <<<"$st")"
assert_eq "$REPO" "$(jq -r '.path' <<<"$WT_WITH_SERVICES")" "state: worktree enumerated live"
assert_eq "2"     "$(jq -r '.services | length' <<<"$WT_WITH_SERVICES")" "state: dead pid filtered"
assert_eq "api"   "$(jq -r '.services[0].service' <<<"$WT_WITH_SERVICES")" "state: live service present"
assert_eq "$LOG"  "$(jq -r '.services[0].log' <<<"$WT_WITH_SERVICES")" "state: service carries log path"
assert_eq "0"     "$(grep -c _normalized_path <<<"$st" || true)" "state: no internal keys leak"

# --- /api/state identity and URLs ---
# Compute SLUG for linked worktree
SLUG="$(python3 -c "import sys; sys.path.insert(0, '$HERE/../lib'); import ui; print(ui.slugify('$(basename "$REPO")'))")"
# Check PRIMARY worktree (no services)
PRIMARY_WT="$(jq '.projects[0].worktrees[] | select(.path=="'"$PRIMARY"'")' <<<"$st")"
assert_eq "$(basename "$PRIMARY")" "$(jq -r '.name' <<<"$PRIMARY_WT")" "state: primary worktree name is dir basename"
assert_eq "true" "$(jq -r '.isPrimary' <<<"$PRIMARY_WT")" "state: primary worktree flagged as primary"
assert_eq "http://fake.localhost:$PROXYPORT/" "$(jq -r '.hintUrl' <<<"$PRIMARY_WT")" "state: primary hintUrl is project root"
assert_eq "null" "$(jq -r '.url' <<<"$PRIMARY_WT")" "state: primary with no services has null url"
assert_eq "false" "$(jq -r '.collision' <<<"$PRIMARY_WT")" "state: primary no collision"

# Check REPO worktree (with services)
REPO_WT="$(jq '.projects[0].worktrees[] | select(.path=="'"$REPO"'")' <<<"$st")"
assert_eq "false" "$(jq -r '.isPrimary' <<<"$REPO_WT")" "state: linked worktree not primary"
assert_eq "http://$SLUG.fake.localhost:$PROXYPORT/" "$(jq -r '.url' <<<"$REPO_WT")" "state: unique leaf gives worktree its root url"
assert_eq "http://$SLUG.fake.localhost:$PROXYPORT/" "$(jq -r '.hintUrl' <<<"$REPO_WT")" "state: linked worktree hintUrl matches base"
assert_eq "http://api.$SLUG.fake.localhost:$PROXYPORT/" \
  "$(jq -r '.services[] | select(.service=="api") | .url' <<<"$REPO_WT")" \
  "state: api service url is service-prefixed subdomain"
assert_eq "http://web.$SLUG.fake.localhost:$PROXYPORT/" \
  "$(jq -r '.services[] | select(.service=="web") | .url' <<<"$REPO_WT")" \
  "state: web service url is service-prefixed subdomain"
assert_eq "false" "$(jq -r '.collision' <<<"$REPO_WT")" "state: no collision flag"

# --- /api/log ---
r="$(curl -s "$BASE/api/log?file=$LOG&offset=-1")"
assert_eq "hello log" "$(jq -r '.data' <<<"$r" | head -1)" "log: initial tail returns content"
assert_eq "10" "$(jq -r '.offset' <<<"$r")" "log: initial tail returns next offset"
printf 'more\n' >> "$LOG"
r="$(curl -s "$BASE/api/log?file=$LOG&offset=10")"
assert_eq "more" "$(jq -r '.data' <<<"$r" | head -1)" "log: offset poll returns only the delta"
assert_eq "15" "$(jq -r '.offset' <<<"$r")" "log: offset advances"
printf 'new\n' > "$LOG"   # truncate: 15 > 4
r="$(curl -s "$BASE/api/log?file=$LOG&offset=15")"
assert_eq "new" "$(jq -r '.data' <<<"$r" | head -1)" "log: truncation resets to 0"
assert_eq "4" "$(jq -r '.offset' <<<"$r")" "log: offset after reset"
code="$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/log?file=/etc/hosts&offset=-1")"
assert_eq "404" "$code" "log: path outside logs dir rejected"
code="$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/log?file=$MARGAY_HOME/logs/../registry.json&offset=-1")"
assert_eq "404" "$code" "log: ../ escape rejected"
code="$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/log?file=$MARGAY_HOME/logs/nope.log&offset=-1")"
assert_eq "404" "$code" "log: missing file is 404"
mkdir -p "$MARGAY_HOME/logs/subdir"
code="$(curl -s -o /dev/null -w '%{http_code}' "$BASE/api/log?file=$MARGAY_HOME/logs/subdir&offset=-1")"
assert_eq "404" "$code" "log: directory under logs is 404"

# --- POST /api/up /api/down /api/unregister ---
r="$(curl -s -X POST -H 'Content-Type: application/json' \
     -d "{\"worktreePath\":\"$REPO\"}" "$BASE/api/up")"
assert_eq "true" "$(jq -r '.ok' <<<"$r")" "up: ok on exit 0"
assert_contains "$(jq -r '.output' <<<"$r")" "mock: up (cwd=$REPO)" "up: runs margay in the worktree"
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
     -d "{\"worktreePath\":\"$REPO\"}" "$BASE/api/down")"
assert_eq "500" "$code" "down: non-zero exit maps to 500"
r="$(curl -s -X POST -d "{\"worktreePath\":\"$REPO\"}" "$BASE/api/down")"
assert_eq "false" "$(jq -r '.ok' <<<"$r")" "down: ok=false on failure"
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST \
     -d '{"worktreePath":"/nonexistent/margay-test"}' "$BASE/api/up")"
assert_eq "400" "$code" "up: missing worktree dir is 400"
r="$(curl -s -X POST -d '{"primaryPath":"/nonexistent/margay-test"}' "$BASE/api/unregister")"
assert_contains "$(jq -r '.output' <<<"$r")" "mock: unregister /nonexistent/margay-test" \
  "unregister: shells out to margay unregister <path>"
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -d '{}' "$BASE/api/unregister")"
assert_eq "400" "$code" "unregister: primaryPath required"
code="$(curl -s -o /dev/null -w '%{http_code}' -X POST -d 'not json' "$BASE/api/up")"
assert_eq "400" "$code" "bad json is 400"
code="$(curl -s -o /dev/null -w '%{http_code}' -H 'Origin: http://evil.example' -X POST \
     -d "{\"worktreePath\":\"$REPO\"}" "$BASE/api/up")"
assert_eq "403" "$code" "POST with cross-site Origin rejected"
code="$(curl -s -o /dev/null -w '%{http_code}' -H 'Host: evil.example' "$BASE/api/state")"
assert_eq "403" "$code" "request with rebound Host rejected"

# --- served page ---
page="$(curl -s "$BASE/")"
assert_contains "$page" "<title>margay</title>" "GET / serves the page"
assert_contains "$page" "/api/state" "page polls /api/state"
assert_contains "$page" 'id="dock"' "page has the dock"
assert_contains "$page" 'class="grid"' "page has card grids"

# --- proxy: host routing ---
SLUG="$(python3 -c "import sys; sys.path.insert(0, '$HERE/../lib'); import ui; print(ui.slugify('$(basename "$REPO")'))")"
r="$(curl -s -H "Host: web.$SLUG.fake.localhost" "http://127.0.0.1:$PROXYPORT/hello")"
assert_contains "$r" "upstream says hi from /hello" "proxy: service host reaches its upstream"
assert_eq "mock" "$(curl -s -o /dev/null -w '%{header_json}' -H "Host: web.$SLUG.fake.localhost" "http://127.0.0.1:$PROXYPORT/" | jq -r '.["x-upstream"][0]')" \
  "proxy: upstream headers pass through"
r="$(curl -s -H "Host: $SLUG.fake.localhost" "http://127.0.0.1:$PROXYPORT/root")"
assert_contains "$r" "upstream says hi from /root" "proxy: worktree root routes to the leaf service"
code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: nope.fake.localhost" "http://127.0.0.1:$PROXYPORT/")"
assert_eq "502" "$code" "proxy: unknown host is 502"
r="$(curl -s -H "Host: nope.fake.localhost" "http://127.0.0.1:$PROXYPORT/")"
assert_contains "$r" "$SLUG.fake.localhost" "proxy: 502 page lists live URLs"

# --- proxy: websocket tunnel ---
WSPORT=$(( (RANDOM % 2000) + 27000 ))
python3 - "$WSPORT" <<'PYEOF' &
import socket, sys
srv = socket.socket(); srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
srv.bind(("127.0.0.1", int(sys.argv[1]))); srv.listen(1)
c, _ = srv.accept()
data = b""
while b"\r\n\r\n" not in data:
    data += c.recv(4096)
c.sendall(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
frame = c.recv(4096)          # echo whatever "frame" bytes arrive
c.sendall(b"ECHO:" + frame)
c.close()
PYEOF
WS_UP_PID=$!
sleep 0.3
# point a third live registry row at it so it gets a host
# NOTE: the pid must be a LIVE process for the whole test run — pass the test
# shell's $$, never os.getpid() of this short-lived python (it would be pruned).
python3 - "$MARGAY_HOME" "$REPO" "$WSPORT" "$$" <<'PYEOF'
import json, sys
home, repo, port, pid = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
reg = json.load(open(home + "/registry.json"))
reg.append({"project":"fake","service":"ws","branch":"main","worktreePath":repo,"port":port,
            "dbName":None,"uses":None,"log":None,"pid":pid,"startedAt":"2026-07-13T12:00:00Z"})
json.dump(reg, open(home + "/registry.json", "w"))
PYEOF
r="$(python3 - "$PROXYPORT" "ws.$SLUG.fake.localhost" <<'PYEOF'
import socket, sys
s = socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=5)
s.sendall(("GET /realtime HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
           "Sec-WebSocket-Key: dGVzdA==\r\nSec-WebSocket-Version: 13\r\n\r\n" % sys.argv[2]).encode())
resp = b""
while b"\r\n\r\n" not in resp:
    resp += s.recv(4096)
assert b"101" in resp.split(b"\r\n")[0], resp
s.sendall(b"PAYLOAD-BYTES")
out = s.recv(4096)
print(out.decode())
PYEOF
)"
assert_contains "$r" "ECHO:PAYLOAD-BYTES" "proxy: websocket handshake and bytes splice both ways"
kill $WS_UP_PID 2>/dev/null
trap 'kill ${UI_PID:-} ${UPSTREAM_PID:-} ${UPSTREAM2_PID:-} ${WS_UP_PID:-} ${BUSY_PID:-} ${FB_PID:-} ${WILD_PID:-} 2>/dev/null' EXIT

# --- proxy: bind fallback ---
BUSY=$(( (RANDOM % 2000) + 27000 ))
python3 -c 'import socket,sys,time; s=socket.socket(); s.bind(("127.0.0.1",int(sys.argv[1]))); s.listen(1); time.sleep(30)' "$BUSY" &
BUSY_PID=$!
sleep 0.3
TMPOUT="$(mktemp)"
(MARGAY_BIN="$MOCK" python3 -u "$HERE/../lib/ui.py" --port $((PORT+1)) --proxy-port "$BUSY" --no-browser 2>&1) > "$TMPOUT" &
FB_PID=$!
sleep 1.5
resp_fallback="$(curl -s -w '\n%{http_code}' "http://127.0.0.1:$((PORT+1))/api/state" 2>/dev/null)"
http_code="${resp_fallback##*$'\n'}"
st_fallback="${resp_fallback%$'\n'*}"
kill $FB_PID 2>/dev/null
sleep 0.2
out="$(cat "$TMPOUT")"
assert_eq "200" "$http_code" "proxy: UI serves even when the proxy port is taken"
assert_contains "$out" "cannot bind proxy port" "proxy: bind failure warning shown"
# Verify state when proxy is down: url should be null, hintUrl should be null, service urls should be port form
WT_FALLBACK="$(jq '.projects[0].worktrees | map(select(.services | length > 0)) | .[0]' <<<"$st_fallback")"
assert_eq "null" "$(jq -r '.url' <<<"$WT_FALLBACK")" "fallback: worktree url is null without proxy"
assert_eq "null" "$(jq -r '.hintUrl' <<<"$WT_FALLBACK")" "fallback: hintUrl is null without proxy"
assert_contains "$(jq -r '.services[0].url' <<<"$WT_FALLBACK")" "http://localhost:" "fallback: service url is port form"
kill $BUSY_PID 2>/dev/null

# --- proxy: wildcard bind path (MARGAY_UI_WILDCARD skips the loopback attempt) ---
WILDPORT=$(( (RANDOM % 2000) + 29000 ))
WILD_LOG="$MARGAY_HOME/wildcard-ui.log"
MARGAY_UI_WILDCARD=1 MARGAY_BIN="$MOCK" python3 "$HERE/../lib/ui.py" \
  --port $((PORT+2)) --proxy-port "$WILDPORT" --no-browser > "$WILD_LOG" 2>&1 &
WILD_PID=$!
for _ in $(seq 1 25); do curl -sf "http://127.0.0.1:$((PORT+2))/api/state" >/dev/null 2>&1 && break; sleep 0.2; done
r="$(curl -s -H "Host: web.$SLUG.fake.localhost" "http://127.0.0.1:$WILDPORT/wild")"
assert_contains "$r" "upstream says hi from /wild" "wildcard bind: proxy routes via loopback"
assert_contains "$(cat "$WILD_LOG")" "wildcard bind, loopback-only" "wildcard bind: startup line says so"
kill $WILD_PID 2>/dev/null

# --- routing helpers (python import harness) ---
# NOTE: this block mutates $MARGAY_HOME/projects.json and registry.json fixtures;
# it must run AFTER all running-server assertions
pyhelp() {
  MARGAY_HOME="$MARGAY_HOME" python3 - "$HERE/../lib" <<'PYEOF'
import json, os, sys
sys.path.insert(0, sys.argv[1])
import ui

assert ui.slugify("Feature/Analytics BC") == "feature-analytics-bc", ui.slugify("Feature/Analytics BC")
assert ui.slugify("wt_a..b") == "wt-a-b", ui.slugify("wt_a..b")

home = os.environ["MARGAY_HOME"]
wt = "/tmp/routes-wt"; pr = "/tmp/routes-primary"
rows = [
  {"project":"vp","service":"backend","worktreePath":wt,"port":8380,"uses":None,
   "pid":os.getpid(),"startedAt":"2026-07-13T10:00:00Z","log":None,"branch":"b","dbName":None},
  {"project":"vp","service":"web","worktreePath":wt,"port":5373,"uses":"http://localhost:8380",
   "pid":os.getpid(),"startedAt":"2026-07-13T10:00:01Z","log":None,"branch":"b","dbName":None},
]
leaves = ui.leaf_services(rows)
assert [r["service"] for r in leaves] == ["web"], leaves   # backend is used by web

json.dump([{"project":"vp","primaryPath":pr,"lastUp":"2026-07-13T00:00:00Z"}],
          open(home + "/projects.json", "w"))
prim = [{"project":"vp","service":"api","worktreePath":pr,"port":7100,"uses":None,
         "pid":os.getpid(),"startedAt":"2026-07-13T09:00:00Z","log":None,"branch":"main","dbName":None}]
json.dump(rows + prim, open(home + "/registry.json", "w"))

routes, info = ui.build_routes()
assert routes["routes-wt.vp.localhost"] == 5373, routes            # unique leaf owns the root
assert routes["web.routes-wt.vp.localhost"] == 5373, routes
assert routes["backend.routes-wt.vp.localhost"] == 8380, routes
assert routes["vp.localhost"] == 7100, routes                      # primary = project root
assert routes["api.vp.localhost"] == 7100, routes
assert info[wt] == {"host": "routes-wt.vp.localhost", "collision": False}, info

# two independent services -> no root mapping
rows2 = [dict(rows[0], uses=None), dict(rows[1], uses=None)]
json.dump(rows2, open(home + "/registry.json", "w"))
routes2, info2 = ui.build_routes()
assert "routes-wt.vp.localhost" not in routes2, routes2
assert info2[wt]["host"] is None and info2[wt]["collision"] is False, info2

# slug collision: wt_a vs wt-a — earliest startedAt wins
ca = dict(rows[0], worktreePath="/tmp/col/wt_a", startedAt="2026-07-13T08:00:00Z", port=7201)
cb = dict(rows[0], worktreePath="/tmp/col/wt-a", startedAt="2026-07-13T08:30:00Z", port=7202)
json.dump([ca, cb], open(home + "/registry.json", "w"))
routes3, info3 = ui.build_routes()
assert routes3["wt-a.vp.localhost"] == 7201, routes3
assert info3["/tmp/col/wt_a"]["host"] == "wt-a.vp.localhost", info3
assert info3["/tmp/col/wt-a"] == {"host": None, "collision": True}, info3

assert ui.host_url("x.vp.localhost") == "http://x.vp.localhost/", "PROXY None -> bare host"
ui.PROXY["port"] = 80
assert ui.host_url("x.vp.localhost") == "http://x.vp.localhost/", ui.host_url("x.vp.localhost")
ui.PROXY["port"] = 8123
assert ui.host_url("x.vp.localhost") == "http://x.vp.localhost:8123/", ui.host_url("x.vp.localhost")

# regression: primary must NOT collide with its own project's worktrees,
# even when a worktree started earlier (base is a dot-suffix of their hosts)
early_wt = dict(rows[0], worktreePath="/tmp/routes-wt", startedAt="2026-07-13T07:00:00Z", port=7301)
late_prim = dict(rows[0], worktreePath=pr, startedAt="2026-07-13T09:30:00Z", port=7302)
json.dump([early_wt, late_prim], open(home + "/registry.json", "w"))
routes4, info4 = ui.build_routes()
assert routes4["vp.localhost"] == 7302, routes4
assert info4[pr]["collision"] is False, info4
assert routes4["routes-wt.vp.localhost"] == 7301, routes4

# loopback_peer truth table
for ip in ("127.0.0.1", "127.9.9.9", "::1", "::ffff:127.0.0.1"):
    assert ui.loopback_peer(ip), ip
for ip in ("192.168.1.10", "10.0.0.1", "2001:db8::1", "8.8.8.8"):
    assert not ui.loopback_peer(ip), ip

print("PYHELP_OK")
PYEOF
}
out="$(pyhelp 2>&1)"; assert_contains "$out" "PYHELP_OK" "routing helpers pass python assertions"

echo "----"
if (( FAILS )); then echo "$FAILS failure(s)"; exit 1; else echo "all passed"; exit 0; fi
