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
assert_eq()       { if [[ "$1" == "$2" ]]; then echo "ok: $3"; else echo "FAIL: $3 — expected [$1] got [$2]"; FAILS=$((FAILS+1)); fi; }
assert_contains() { if [[ "$1" == *"$2"* ]]; then echo "ok: $3"; else echo "FAIL: $3 — [$1] lacks [$2]"; FAILS=$((FAILS+1)); fi; }

# fixture: a primary repo + a worktree (for proxy routing test)
PRIMARY="$(cd "$(mktemp -d)" && pwd -P)"
( cd "$PRIMARY" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
REPOBASE="$(cd "$(mktemp -d)" && pwd -P)"
REPO="$REPOBASE/wt"
( cd "$PRIMARY" && git worktree add -b test "$REPO" main 2>/dev/null || mkdir -p "$REPO" )
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

# --- proxy: bind fallback ---
BUSY=$(( (RANDOM % 2000) + 27000 ))
python3 -c 'import socket,sys,time; s=socket.socket(); s.bind(("127.0.0.1",int(sys.argv[1]))); s.listen(1); time.sleep(30)' "$BUSY" &
BUSY_PID=$!
sleep 0.3
TMPOUT="$(mktemp)"
(MARGAY_BIN="$MOCK" python3 -u "$HERE/../lib/ui.py" --port $((PORT+1)) --proxy-port "$BUSY" --no-browser 2>&1) > "$TMPOUT" &
FB_PID=$!
sleep 1.5
http_code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$((PORT+1))/api/state" 2>/dev/null)"
kill $FB_PID 2>/dev/null
sleep 0.2
out="$(cat "$TMPOUT")"
assert_eq "200" "$http_code" "proxy: UI serves even when the proxy port is taken"
assert_contains "$out" "cannot bind proxy port" "proxy: bind failure warning shown"
kill $BUSY_PID 2>/dev/null

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

print("PYHELP_OK")
PYEOF
}
out="$(pyhelp 2>&1)"; assert_contains "$out" "PYHELP_OK" "routing helpers pass python assertions"

echo "----"
if (( FAILS )); then echo "$FAILS failure(s)"; exit 1; else echo "all passed"; exit 0; fi
