#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export MARGAY_HOME="$(mktemp -d)"
mkdir -p "$MARGAY_HOME/logs"
PORT=$(( (RANDOM % 2000) + 18000 ))
BASE="http://127.0.0.1:$PORT"
FAILS=0
assert_eq()       { if [[ "$1" == "$2" ]]; then echo "ok: $3"; else echo "FAIL: $3 — expected [$1] got [$2]"; FAILS=$((FAILS+1)); fi; }
assert_contains() { if [[ "$1" == *"$2"* ]]; then echo "ok: $3"; else echo "FAIL: $3 — [$1] lacks [$2]"; FAILS=$((FAILS+1)); fi; }

# fixture: a real repo (for worktree enumeration) + a stale project
REPO="$(cd "$(mktemp -d)" && pwd -P)"
( cd "$REPO" && git init -q && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m init )
cat > "$MARGAY_HOME/projects.json" <<EOF
[{"project":"fake","primaryPath":"$REPO","lastUp":"2026-07-13T00:00:00Z"},
 {"project":"gone","primaryPath":"/nonexistent/margay-test","lastUp":"2026-07-01T00:00:00Z"}]
EOF
LOG="$MARGAY_HOME/logs/fake-main-api.log"
printf 'hello log\n' > "$LOG"
cat > "$MARGAY_HOME/registry.json" <<EOF
[{"project":"fake","service":"api","branch":"main","worktreePath":"$REPO","port":7100,
  "dbName":null,"uses":null,"log":"$LOG","pid":$$,"startedAt":"2026-07-13T00:00:00Z"},
 {"project":"fake","service":"dead","branch":"main","worktreePath":"$REPO","port":7101,
  "dbName":null,"uses":null,"log":null,"pid":999999,"startedAt":"2026-07-13T00:00:00Z"}]
EOF

python3 "$HERE/../lib/ui.py" --port "$PORT" --no-browser &
UI_PID=$!
trap 'kill $UI_PID 2>/dev/null' EXIT
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
assert_eq "$REPO" "$(jq -r '.projects[0].worktrees[0].path' <<<"$st")" "state: worktree enumerated live"
assert_eq "1"     "$(jq -r '.projects[0].worktrees[0].services | length' <<<"$st")" "state: dead pid filtered"
assert_eq "api"   "$(jq -r '.projects[0].worktrees[0].services[0].service' <<<"$st")" "state: live service present"
assert_eq "$LOG"  "$(jq -r '.projects[0].worktrees[0].services[0].log' <<<"$st")" "state: service carries log path"
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

echo "----"
if (( FAILS )); then echo "$FAILS failure(s)"; exit 1; else echo "all passed"; exit 0; fi
