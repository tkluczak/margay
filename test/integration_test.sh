#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARGAY="$HERE/../margay"
export MARGAY_HOME="$(mktemp -d)"
FAILS=0
assert_contains() { if [[ "$1" == *"$2"* ]]; then echo "ok: $3"; else echo "FAIL: $3 — [$1] lacks [$2]"; FAILS=$((FAILS+1)); fi; }
assert_eq()   { if [[ "$1" == "$2" ]]; then echo "ok: $3"; else echo "FAIL: $3 — expected [$1] got [$2]"; FAILS=$((FAILS+1)); fi; }
assert_ok()   { if "$@"; then echo "ok: $*"; else echo "FAIL: expected success: $*"; FAILS=$((FAILS+1)); fi; }

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

# --- optional dependencies + --use NAME=none ---
REPO3="$(mktemp -d)"
( cd "$REPO3" && git init -q && git commit -q --allow-empty -m init )
cat > "$REPO3/.margay.conf" <<'EOF'
project="optproj"
services="api web"
service_api_ports="7170-7174"
service_api_start() { exec sleep 300; }
service_web_ports="7180-7184"
service_web_uses_project="optproj:api"
service_web_uses_optional=1
service_web_main_port=9999
service_web_start() { echo "DEP=[${API_URL:-unset}]"; exec sleep 300; }
EOF

opt_out="$(cd "$REPO3" && "$MARGAY" up web 2>&1)"
assert_contains "$opt_out" "api → none (optional)" "optional dep, no live instance: announces none"
sleep 1
opt_log="$(jq -r '[.[] | select(.project=="optproj" and .service=="web")] | last | .log' "$MARGAY_HOME/registry.json")"
assert_contains "$(cat "$opt_log")" "DEP=[unset]" "optional dep, no live instance: env unset (main_port NOT used)"
assert_contains "$(jq -r '[.[] | select(.project=="optproj" and .service=="web")] | last | .uses' "$MARGAY_HOME/registry.json")" "null" \
  "optional none records uses=null"
( cd "$REPO3" && "$MARGAY" down >/dev/null 2>&1 )

( cd "$REPO3" && "$MARGAY" up api >/dev/null 2>&1 )
none_out="$(cd "$REPO3" && "$MARGAY" up web --use api=none 2>&1)"
assert_contains "$none_out" "api → none (optional)" "--use api=none skips a live instance"
sleep 1
none_log="$(jq -r '[.[] | select(.project=="optproj" and .service=="web")] | last | .log' "$MARGAY_HOME/registry.json")"
assert_contains "$(cat "$none_log")" "DEP=[unset]" "--use api=none: env unset despite live api"
( cd "$REPO3" && "$MARGAY" down >/dev/null 2>&1 )

strict_none="$(cd "$REPO" && "$MARGAY" up ui --use api=none 2>&1)" \
  && { echo "FAIL: --use api=none on non-optional service should fail"; FAILS=$((FAILS+1)); } || true
assert_contains "$strict_none" "uses_optional" "non-optional none rejected with hint"
( cd "$REPO" && "$MARGAY" down >/dev/null 2>&1 || true )
# --- conf-json ---
cj="$(cd "$REPO3" && "$MARGAY" conf-json 2>&1)"
ok_cj="$(printf '%s' "$cj" | python3 -c '
import json, sys
d = json.load(sys.stdin)
web = [s for s in d["services"] if s["name"] == "web"][0]
api = [s for s in d["services"] if s["name"] == "api"][0]
assert d["project"] == "optproj", d
assert web["usesProject"] == "optproj:api" and web["usesOptional"] is True, web
assert web["mainPort"] == 9999 and web["needs"] is None, web
assert api["usesProject"] is None and api["usesOptional"] is False and api["mainPort"] is None, api
assert api["ports"] == "7170-7174", api
print("CONF-JSON-OK")
' 2>&1)"
assert_contains "$ok_cj" "CONF-JSON-OK" "conf-json emits full dependency metadata"
cj2="$(cd "$REPO" && "$MARGAY" conf-json 2>&1)"
assert_contains "$cj2" '"needs":"api"' "conf-json carries same-project needs"

( cd "$REPO3" && "$MARGAY" unregister >/dev/null 2>&1 )   # keep the later projects.json count stable

# --- service_<name>_on_up hook (proxy-hostname registration) ---
REPO4="$(mktemp -d)"
( cd "$REPO4" && git init -q && git commit -q --allow-empty -m init )
cat > "$REPO4/.margay.conf" <<EOF
project="hookproj"
services="api"
service_api_ports="7185-7189"
service_api_start() { exec sleep 300; }
service_api_on_up() { echo "HOOK root=\$MARGAY_ROOT_HOST svc=\$MARGAY_SERVICE_HOST port=\$PORT" > "$REPO4/hook.out"; }
EOF
( cd "$REPO4" && "$MARGAY" up >/dev/null 2>&1 )
assert_contains "$(cat "$REPO4/hook.out" 2>/dev/null)" "root=hookproj.localhost svc=api.hookproj.localhost port=7185"   "on_up: primary hook sees project root host, service host and port"
( cd "$REPO4" && "$MARGAY" down >/dev/null 2>&1 )

( cd "$REPO4" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m base \
    && git worktree add -q "$REPO4/.claude/worktrees/My+WT" -b feat-hook )
( cd "$REPO4" && "$MARGAY" up feat-hook >/dev/null 2>&1 )
assert_contains "$(cat "$REPO4/hook.out" 2>/dev/null)" "root=my-wt.hookproj.localhost svc=api.my-wt.hookproj.localhost"   "on_up: worktree hook host is the dash-slugged basename"
( cd "$REPO4" && "$MARGAY" down feat-hook >/dev/null 2>&1 )

( cd "$REPO4" && MARGAY_DOMAIN=devel.test "$MARGAY" up >/dev/null 2>&1 )
assert_contains "$(cat "$REPO4/hook.out" 2>/dev/null)" "root=hookproj.devel.test svc=api.hookproj.devel.test" \
  "on_up: MARGAY_DOMAIN changes the hook host suffix"
( cd "$REPO4" && "$MARGAY" down >/dev/null 2>&1 )

cat > "$REPO4/.margay.conf" <<EOF
project="hookproj"
services="api"
service_api_ports="7185-7189"
service_api_start() { exec sleep 300; }
service_api_on_up() { exit 1; }
EOF
hook_fail="$(cd "$REPO4" && "$MARGAY" up 2>&1)"; hook_rc=$?
assert_contains "$hook_fail" "warning: service_api_on_up failed" "on_up: failing hook warns"
assert_contains "$hook_fail" "api up → http://localhost:7185" "on_up: failing hook does not block the up"
if [[ "$hook_rc" == 0 ]]; then echo "ok: on_up failure keeps exit 0"; else echo "FAIL: on_up failure changed exit code"; FAILS=$((FAILS+1)); fi
( cd "$REPO4" && "$MARGAY" down >/dev/null 2>&1; "$MARGAY" unregister >/dev/null 2>&1 )

# --- ps / ls aliases ---
assert_eq "$(cd "$REPO" && "$MARGAY" status)" "$(cd "$REPO" && "$MARGAY" ps)" "ps is byte-identical to status"
assert_eq "$(cd "$REPO" && "$MARGAY" worktrees)" "$(cd "$REPO" && "$MARGAY" ls)" "ls is byte-identical to worktrees"
help_out="$(cd "$REPO" && "$MARGAY" help)"
assert_contains "$help_out" "ps" "help mentions ps"
assert_contains "$help_out" "ls" "help mentions ls"

# --- unregister ---
unreg="$(cd "$REPO" && "$MARGAY" unregister 2>&1)"
assert_contains "$unreg" "unregistered" "unregister (no arg) removes current repo"
# After unregister, projects.json should only have the failproj entry from REPO2 (auto-learn now happens in margay::context, before launches can fail)
assert_contains "$(jq 'length' "$MARGAY_HOME/projects.json")" "1" "projects.json has failproj from REPO2"
bad="$("$MARGAY" unregister nothing-here 2>&1)" \
  && { echo "FAIL: unregister miss should fail"; FAILS=$((FAILS+1)); } || true
assert_contains "$bad" "no registered project matches" "unregister miss error"

# --- __complete ---
cmpl="$(cd "$REPO" && "$MARGAY" __complete up 2>/dev/null)"
assert_contains "$cmpl" "wt-b" "__complete up lists the worktree basename"
assert_contains "$cmpl" "$(printf 'api\tservice')" "__complete up lists api as a service"
assert_contains "$cmpl" "$(printf 'ui\tservice')" "__complete up lists ui as a service"
dcmpl="$(cd "$REPO" && "$MARGAY" __complete down 2>/dev/null)"
assert_contains "$dcmpl" "--all" "__complete down offers --all"

# silence contract: exit 0, empty stdout, empty stderr on every failure path
NOGIT="$(mktemp -d)"
err="$( (cd "$NOGIT" && "$MARGAY" __complete up) 2>&1 1>/dev/null )"; rc=$?
assert_eq "" "$err" "__complete outside a git repo: silent stderr"
assert_eq "0" "$rc" "__complete outside a git repo: exit 0"
assert_eq "" "$( (cd "$NOGIT" && "$MARGAY" __complete up) 2>/dev/null )" "__complete outside a git repo: empty stdout"

NOCONF="$(mktemp -d)"
( cd "$NOCONF" && git init -q && git commit -q --allow-empty -m init )
err2="$( (cd "$NOCONF" && "$MARGAY" __complete up) 2>&1 1>/dev/null )"; rc2=$?
assert_eq "" "$err2" "__complete with no conf: silent stderr"
assert_eq "0" "$rc2" "__complete with no conf: exit 0"
# a conf-less repo still has worktrees to offer, just no services
assert_contains "$( (cd "$NOCONF" && "$MARGAY" __complete up) 2>/dev/null )" "$(basename "$NOCONF")" \
  "__complete with no conf still lists worktrees"

# regression: a conf that SOURCES successfully (no syntax error) but contains
# an unguarded statement that returns non-zero (a bare `false`) used to trip
# this script's `set -e` mid-source, since config_load sources the conf
# inline into the caller's shell. That aborted the whole __complete process
# instead of the mandated rc=0 — only the *service* candidates should be
# lost, worktree candidates must still print.
FAILCONF="$(mktemp -d)"
( cd "$FAILCONF" && git init -q && git commit -q --allow-empty -m init )
cat > "$FAILCONF/.margay.conf" <<'EOF'
project="failsvc"
services="api"
service_api_ports="7170-7174"
service_api_start() { exec sleep 300; }
false
EOF
errF="$( (cd "$FAILCONF" && "$MARGAY" __complete up) 2>&1 1>/dev/null )"; rcF=$?
assert_eq "" "$errF" "__complete with a conf failing statement: silent stderr"
assert_eq "0" "$rcF" "__complete with a conf failing statement: exit 0"
assert_contains "$( (cd "$FAILCONF" && "$MARGAY" __complete up) 2>/dev/null )" "$(basename "$FAILCONF")" \
  "__complete with a conf failing statement still lists worktree candidates"

# regression: a conf that SOURCES CLEANLY (no syntax error, no failing statements)
# but FAILS VALIDATION (e.g., sets project but no services) — config_load's _cerr
# writes to stderr, and the silence contract requires those writes be captured
# by the inner (...) subshell's 2>/dev/null, not leaked by a bare $(... 2>/dev/null).
FAILVAL="$(mktemp -d)"
( cd "$FAILVAL" && git init -q && git commit -q --allow-empty -m init )
cat > "$FAILVAL/.margay.conf" <<'EOF'
project="badconf"
EOF
errV="$( (cd "$FAILVAL" && "$MARGAY" __complete up) 2>&1 1>/dev/null )"; rcV=$?
assert_eq "" "$errV" "__complete with conf failing validation: silent stderr"
assert_eq "0" "$rcV" "__complete with conf failing validation: exit 0"
assert_contains "$( (cd "$FAILVAL" && "$MARGAY" __complete up) 2>/dev/null )" "$(basename "$FAILVAL")" \
  "__complete with conf failing validation still lists worktree candidates"

if [[ "$help_out" == *__complete* ]]; then
  echo "FAIL: __complete leaked into help"; FAILS=$((FAILS+1))
else echo "ok: __complete is hidden from help"; fi

echo "----"
if (( FAILS )); then echo "$FAILS failure(s)"; exit 1; else echo "all passed"; exit 0; fi
