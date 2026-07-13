#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARGAY="$HERE/../margay"
export MARGAY_HOME="$(mktemp -d)"
FAILS=0
assert_contains() { if [[ "$1" == *"$2"* ]]; then echo "ok: $3"; else echo "FAIL: $3 — [$1] lacks [$2]"; FAILS=$((FAILS+1)); fi; }

REPO="$(mktemp -d)"
( cd "$REPO" && git init -q && git commit -q --allow-empty -m init )
cat > "$REPO/.margay.conf" <<'EOF'
project="fake"
services="api ui"
service_api_ports="7150-7154"
service_api_start() { exec sleep 300; }
service_ui_ports="7160-7164"
service_ui_needs="api"
service_ui_start() { [[ -n "$API_PORT" && -n "$API_URL" ]] || exit 1; exec sleep 300; }
EOF

out="$(cd "$REPO" && "$MARGAY" up 2>&1)"
assert_contains "$out" "api up → http://localhost:7150" "up starts api on first port"
assert_contains "$out" "ui up → http://localhost:7160" "up starts ui"
sleep 1
st="$(cd "$REPO" && "$MARGAY" status)"
assert_contains "$st" "fake" "status shows project"
assert_contains "$st" "7150" "status shows api port"
assert_contains "$st" "http://localhost:7150" "status shows ui→api uses"
assert_contains "$(jq -r '.[0].project' "$MARGAY_HOME/projects.json")" "fake" \
  "up auto-learns the project into projects.json"
assert_contains "$(jq -r '.[0].primaryPath' "$MARGAY_HOME/projects.json")" "$REPO" \
  "auto-learn records the primary path"
down="$(cd "$REPO" && "$MARGAY" down 2>&1)"
assert_contains "$down" "stopped pid" "down stops"
sleep 1
st2="$(cd "$REPO" && "$MARGAY" status)"
if [[ "$st2" == *7150* ]]; then echo "FAIL: registry not emptied"; FAILS=$((FAILS+1)); else echo "ok: registry emptied"; fi

# --- worktree targeting ---
( cd "$REPO" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m base \
    && git worktree add -q "$REPO/.claude/worktrees/wt-b" -b feat-b )

up_out="$(cd "$REPO" && "$MARGAY" up feat-b api 2>&1)"
assert_contains "$up_out" "branch feat-b" "targeted up runs against the worktree's branch"
assert_contains "$up_out" "api up → http://localhost:715" "targeted up starts api"
wt_path="$(jq -r '.[0].worktreePath' "$MARGAY_HOME/registry.json")"
assert_contains "$wt_path" ".claude/worktrees/wt-b" "registry records the TARGET worktree path"

lst="$(cd "$REPO" && "$MARGAY" worktrees)"
assert_contains "$lst" "feat-b" "worktrees lists the new worktree"
assert_contains "$lst" "api:715" "worktrees shows the sandbox on the target row"

miss="$(cd "$REPO" && "$MARGAY" up zzz 2>&1)" && { echo "FAIL: up zzz should fail"; FAILS=$((FAILS+1)); } || true
assert_contains "$miss" "neither a declared service" "miss error names both namespaces"

two="$(cd "$REPO" && "$MARGAY" up feat-b wt-b 2>&1)" && { echo "FAIL: two targets should fail"; FAILS=$((FAILS+1)); } || true
assert_contains "$two" "at most one worktree target" "double target rejected"

( cd "$REPO" && git worktree add -q "$REPO/.claude/worktrees/api" -b api-wt )
coll="$(cd "$REPO" && "$MARGAY" up api --use api=1 2>&1 || true)"
assert_contains "$coll" "also names a worktree" "collision resolves as service with a note"
( cd "$REPO" && "$MARGAY" down >/dev/null 2>&1 || true )   # stop anything the collision case started in cwd

( cd "$REPO" && git worktree add -q "$REPO/.claude/worktrees/ui-redesign" -b ui-redesign )
sub_note="$(cd "$REPO" && "$MARGAY" up ui 2>&1 || true)"
if [[ "$sub_note" == *"also names a worktree"* ]]; then echo "FAIL: substring-only match must not trigger the collision note"; FAILS=$((FAILS+1)); else echo "ok: no false collision note on substring"; fi
( cd "$REPO" && "$MARGAY" down >/dev/null 2>&1 || true )

down_out="$(cd "$REPO" && "$MARGAY" down feat-b 2>&1)"
assert_contains "$down_out" "stopped pid" "targeted down stops the worktree's sandbox"
sleep 1
st_after="$(cd "$REPO" && "$MARGAY" status)"
if [[ "$st_after" == *"feat-b"* ]]; then echo "FAIL: feat-b sandbox survived targeted down"; FAILS=$((FAILS+1)); else echo "ok: targeted down cleaned registry"; fi

# --- regression: db-preparation failure must not report false success ---
REPO2="$(mktemp -d)"
( cd "$REPO2" && git init -q && git commit -q --allow-empty -m init )
cat > "$REPO2/.margay.conf" <<'EOF'
project="failproj"
services="x"
postgres_psql() { return 1; }
postgres_url="postgres://x/{db}"
service_x_ports="7170-7174"
service_x_db="empty"
service_x_start() { exec sleep 300; }
EOF

out2="$(cd "$REPO2" && "$MARGAY" up 2>&1)"; rc2=$?
if (( rc2 != 0 )); then echo "ok: up exits non-zero when db preparation fails"
else echo "FAIL: up exited 0 despite failing db preparation — [$out2]"; FAILS=$((FAILS+1)); fi
if [[ "$out2" == *"✔"* ]]; then echo "FAIL: up printed a ✔ despite failing db preparation — [$out2]"; FAILS=$((FAILS+1))
else echo "ok: no ✔ printed on db preparation failure"; fi
st3="$(cd "$REPO2" && "$MARGAY" status)"
if [[ "$st3" == *"failproj"* ]]; then echo "FAIL: registry polluted despite failed up — [$st3]"; FAILS=$((FAILS+1))
else echo "ok: registry stays empty after failed up"; fi

# --- unknown subcommand must fail, bare/help must not ---
"$MARGAY" bogus >/dev/null 2>&1
if [[ $? == 1 ]]; then echo "ok: unknown subcommand exits 1"
else echo "FAIL: unknown subcommand did not exit 1"; FAILS=$((FAILS+1)); fi
"$MARGAY" >/dev/null 2>&1
if [[ $? == 0 ]]; then echo "ok: bare margay exits 0"
else echo "FAIL: bare margay did not exit 0"; FAILS=$((FAILS+1)); fi
"$MARGAY" help >/dev/null 2>&1
if [[ $? == 0 ]]; then echo "ok: margay help exits 0"
else echo "FAIL: margay help did not exit 0"; FAILS=$((FAILS+1)); fi

# --- unregister ---
unreg="$(cd "$REPO" && "$MARGAY" unregister 2>&1)"
assert_contains "$unreg" "unregistered" "unregister (no arg) removes current repo"
# After unregister, projects.json should only have the failproj entry from REPO2 (auto-learn now happens in margay::context, before launches can fail)
assert_contains "$(jq 'length' "$MARGAY_HOME/projects.json")" "1" "projects.json has failproj from REPO2"
bad="$("$MARGAY" unregister nothing-here 2>&1)" \
  && { echo "FAIL: unregister miss should fail"; FAILS=$((FAILS+1)); } || true
assert_contains "$bad" "no registered project matches" "unregister miss error"

echo "----"
if (( FAILS )); then echo "$FAILS failure(s)"; exit 1; else echo "all passed"; exit 0; fi
