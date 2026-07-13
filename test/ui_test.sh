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
REPO="$(mktemp -d)"
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

echo "----"
if (( FAILS )); then echo "$FAILS failure(s)"; exit 1; else echo "all passed"; exit 0; fi
