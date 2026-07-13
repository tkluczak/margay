#!/usr/bin/env bash
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MARGAY_HOME="$(mktemp -d)"; export MARGAY_HOME
# shellcheck source=/dev/null
source "$HERE/../lib/engine.sh"
# shellcheck source=/dev/null
source "$HERE/../lib/config.sh"

FAILS=0
assert_eq()   { if [[ "$1" == "$2" ]]; then echo "ok: $3"; else echo "FAIL: $3 — expected [$1] got [$2]"; FAILS=$((FAILS+1)); fi; }
assert_ok()   { if "$@"; then echo "ok: $*"; else echo "FAIL: expected success: $*"; FAILS=$((FAILS+1)); fi; }
assert_fail() { if "$@"; then echo "FAIL: expected failure: $*"; FAILS=$((FAILS+1)); else echo "ok(!): $*"; fi; }

# --- test functions get appended below by later tasks ---

assert_eq "feature_analytics_bc" "$(margay::slugify 'feature/analytics-bc')" "slugify branch"
assert_eq "abc_123" "$(margay::slugify '  ABC/123!! ')" "slugify trims+lowers"
assert_eq "demo_sb_feature_analytics_bc" "$(margay::db_name demo 'feature/analytics-bc')" "db_name has project prefix"
assert_eq "64" "$(margay::db_name demo "$(printf 'x%.0s' {1..200})" | wc -c | tr -d ' ')" "db_name len incl newline<=64"

rm -f "$REGISTRY"
margay::registry_add "$(margay::registry_record demo api a /tmp/wt-a 7100 mydb '' "$$")"
margay::registry_add "$(margay::registry_record demo api b /tmp/wt-b 7101 '' '' 999999)"
margay::registry_add "$(margay::registry_record other api x /tmp/wt-x 7100 '' '' "$$")"
assert_eq "7100 7101" "$(margay::registry_used_ports demo api)" "used_ports scoped to project"
assert_eq "/tmp/logs/demo-a-api.log" \
  "$(margay::registry_record demo api a /tmp/wt-a 7100 '' '' 1 /tmp/logs/demo-a-api.log | jq -r .log)" \
  "record stores log path"
assert_eq "null" \
  "$(margay::registry_record demo api a /tmp/wt-a 7100 '' '' 1 | jq -r .log)" \
  "record log defaults to null"
margay::registry_prune
assert_eq "7100" "$(margay::registry_used_ports demo api)" "prune drops dead pid"
assert_eq "7100" "$(margay::registry_last_instance demo api)" "last live instance"
assert_eq "" "$(margay::registry_last_instance demo ghost)" "last instance: none"
assert_eq "null" "$(jq -r '.[0].uses' "$REGISTRY")" "empty uses stored as null"
assert_eq "mydb" "$(jq -r '.[0].dbName' "$REGISTRY")" "dbName stored"
margay::registry_remove_by_pid "$$"
assert_eq "" "$(margay::registry_used_ports demo api)" "remove_by_pid empties"

assert_eq "8190" "$(margay::first_free_in_set 8190 8199 '')" "first free empty"
assert_eq "8192" "$(margay::first_free_in_set 8190 8199 '8190 8191')" "first free skips used"
assert_fail margay::first_free_in_set 8190 8191 '8190 8191'   # exhausted

( source "$HERE/fixtures/valid.conf"
  rm -f "$REGISTRY"
  p="$(margay::alloc_port api)"
  [[ "$p" == 7100 ]] ) ; assert_eq 0 $? "alloc_port takes range from conf"

# --- config loader ---
try_conf() { ( source "$HERE/fixtures/$1" >/dev/null 2>&1 && margay::config_validate >/dev/null 2>&1 ); }
assert_ok   try_conf valid.conf
assert_fail try_conf missing-ports.conf
assert_fail try_conf bad-db.conf
assert_fail try_conf unknown-needs.conf
assert_fail try_conf seed-no-dump.conf
assert_fail try_conf overlap.conf
assert_fail try_conf bad-uses-project.conf

assert_eq "7100 7104" "$( (source "$HERE/fixtures/valid.conf"; margay::parse_ports "$(margay::svc_var api ports)") )" "parse_ports"
assert_fail margay::parse_ports "abc"
assert_fail margay::parse_ports "9000-8000"

CFT="$(mktemp -d)"; mkdir -p "$CFT/wt" "$CFT/primary"
assert_fail margay::config_find "$CFT/wt" "$CFT/primary"
cp "$HERE/fixtures/valid.conf" "$CFT/primary/.margay.conf"
assert_eq "$CFT/primary/.margay.conf" "$(margay::config_find "$CFT/wt" "$CFT/primary")" "find: primary fallback"
cp "$HERE/fixtures/valid.conf" "$CFT/wt/.margay.conf"
assert_eq "$CFT/wt/.margay.conf" "$(margay::config_find "$CFT/wt" "$CFT/primary")" "find: worktree wins"

# --- topo ---
assert_eq "api ui" "$( (source "$HERE/fixtures/valid.conf"; margay::topo_services) )" "topo: dep first"
assert_fail try_conf cycle.conf

# --- db ops via hooks ---
DBCAP="$(mktemp)"
postgres_psql() { echo "psql $*" >> "$DBCAP"; if [[ "$*" == *pg_database* ]]; then echo "1"; fi; cat >/dev/null; }
postgres_dump() { echo "dump $*" >> "$DBCAP"; echo "-- sql --"; }
postgres_url="postgres://u:p@localhost:5555/{db}"
postgres_seed_from="sourcedb"
assert_eq "postgres://u:p@localhost:5555/demo_sb_x" "$(margay::url_for_db demo_sb_x)" "url templating"
assert_ok margay::db_exists demo_sb_x
margay::db_create demo_sb_x
margay::db_seed  demo_sb_x
assert_ok grep -q 'psql -tAc' "$DBCAP"
assert_ok grep -q 'CREATE DATABASE' "$DBCAP"
assert_ok grep -q 'dump sourcedb' "$DBCAP"
assert_ok grep -q 'psql -d demo_sb_x' "$DBCAP"
unset -f postgres_psql postgres_dump

# --- dependency resolution ---
assert_eq "API" "$(margay::env_name api)" "env_name upper"
assert_eq "MY_SVC2" "$(margay::env_name my-svc2)" "env_name sanitizes"
assert_eq "8290" "$(margay::use_override 'api=8290 ui=9000' api)" "use_override hit"
assert_eq "" "$(margay::use_override 'api=8290' ghost)" "use_override miss"

rm -f "$REGISTRY"
assert_eq "8290 http://localhost:8290" "$(margay::resolve_dep demo api /tmp/wt '8290' '')" "override port"
assert_eq "1234 http://x:1234" "$(margay::resolve_dep demo api /tmp/wt 'http://x:1234' '')" "override url"
assert_fail margay::resolve_dep demo api /tmp/wt '' ''
assert_eq "8090 http://localhost:8090" "$(margay::resolve_dep demo api /tmp/wt '' 8090)" "main_port fallback"
margay::registry_add "$(margay::registry_record demo api a /tmp/other 7101 '' '' "$$")"
assert_eq "7101 http://localhost:7101" "$(margay::resolve_dep demo api /tmp/wt '' 8090)" "same-project last-started"
margay::registry_add "$(margay::registry_record demo api a /tmp/wt 7102 '' '' "$$")"
assert_eq "7102 http://localhost:7102" "$(margay::resolve_dep demo api /tmp/wt '' 8090)" "same-worktree wins"

assert_eq "9999 http://h:9999/path" "$(margay::resolve_dep demo api /tmp/wt 'http://h:9999/path' '')" "override url with path keeps port"
assert_fail margay::resolve_dep demo api /tmp/wt 'https://h/path' ''   # no explicit port in URL

# --- worktrees: parse + resolve ---
PORC="worktree /tmp/prj
HEAD 1111111111111111111111111111111111111111
branch refs/heads/main

worktree /tmp/prj/.claude/worktrees/feat-x
HEAD 2222222222222222222222222222222222222222
branch refs/heads/feature/x

worktree /tmp/prj/.claude/worktrees/det
HEAD 3333333333333333333333333333333333333333
detached
"
assert_eq "$(printf '/tmp/prj\tmain\n/tmp/prj/.claude/worktrees/feat-x\tfeature/x\n/tmp/prj/.claude/worktrees/det\tHEAD')" \
  "$(margay::worktrees_parse <<<"$PORC")" "parse: 3 rows, detached=HEAD"

assert_eq "/tmp/prj	main" \
  "$(printf 'worktree /tmp/prj\nHEAD 1111111111111111111111111111111111111111\nbranch refs/heads/main' | margay::worktrees_parse)" \
  "parse: final line without trailing newline"

assert_eq "/tmp/prj/.claude/worktrees/feat-x	feature/x" \
  "$(margay::worktree_resolve feat-x <<<"$(margay::worktrees_parse <<<"$PORC")")" "resolve: exact basename"
assert_eq "/tmp/prj/.claude/worktrees/feat-x	feature/x" \
  "$(margay::worktree_resolve feature/x <<<"$(margay::worktrees_parse <<<"$PORC")")" "resolve: exact branch"
assert_eq "/tmp/prj/.claude/worktrees/feat-x	feature/x" \
  "$(margay::worktree_resolve eat- <<<"$(margay::worktrees_parse <<<"$PORC")")" "resolve: unique substring"
assert_eq "/tmp/prj/.claude/worktrees/det	HEAD" \
  "$(margay::worktree_resolve det <<<"$(margay::worktrees_parse <<<"$PORC")")" "resolve: detached row"

rc=0; margay::worktree_resolve zzz <<<"$(margay::worktrees_parse <<<"$PORC")" >/dev/null || rc=$?
assert_eq "1" "$rc" "resolve: miss rc=1"
rc=0; out="$(margay::worktree_resolve t <<<"$(margay::worktrees_parse <<<"$PORC")")" || rc=$?
assert_eq "2" "$rc" "resolve: ambiguous rc=2"
assert_eq "2" "$(printf '%s\n' "$out" | grep -c .)" "resolve: ambiguous lists both candidates"

assert_ok   margay::worktree_exact_exists feat-x <<<"$(margay::worktrees_parse <<<"$PORC")"
assert_ok   margay::worktree_exact_exists feature/x <<<"$(margay::worktrees_parse <<<"$PORC")"
assert_fail margay::worktree_exact_exists eat- <<<"$(margay::worktrees_parse <<<"$PORC")"
assert_fail margay::worktree_exact_exists zzz <<<"$(margay::worktrees_parse <<<"$PORC")"

# --- worktrees: join ---
rm -f "$REGISTRY"
margay::registry_add "$(margay::registry_record prj api main /tmp/prj/.claude/worktrees/feat-x 7100 mydb '' "$$")"
margay::registry_add "$(margay::registry_record prj ui  main /tmp/prj/.claude/worktrees/feat-x 7160 '' 'http://localhost:7100' "$$")"
margay::registry_add "$(margay::registry_record prj api dead /tmp/prj/.claude/worktrees/det 7101 '' '' 999999)"
JOINED="$(margay::worktrees_parse <<<"$PORC" | margay::worktrees_join)"
assert_eq "/tmp/prj	main	-	-" "$(printf '%s\n' "$JOINED" | sed -n 1p)" "join: bare primary row"
assert_eq "/tmp/prj/.claude/worktrees/feat-x	feature/x	api:7100 ui:7160	mydb" \
  "$(printf '%s\n' "$JOINED" | sed -n 2p)" "join: two services aggregated"
assert_eq "/tmp/prj/.claude/worktrees/det	HEAD	-	-" \
  "$(printf '%s\n' "$JOINED" | sed -n 3p)" "join: dead pid pruned"
rm -f "$REGISTRY"

# --- projects.json (static project registry) ---
rm -f "$PROJECTS"
margay::projects_learn acme /tmp/proj/acme
margay::projects_learn beta /tmp/proj/beta
assert_eq "2" "$(jq 'length' "$PROJECTS")" "projects: learn adds entries"
margay::projects_learn acme2 /tmp/proj/acme
assert_eq "2" "$(jq 'length' "$PROJECTS")" "projects: learn upserts on primaryPath"
assert_eq "acme2" "$(jq -r '.[] | select(.primaryPath=="/tmp/proj/acme") | .project' "$PROJECTS")" \
  "projects: upsert updates the name"
assert_eq "true" "$(jq '[.[] | select(.primaryPath=="/tmp/proj/acme")][0].lastUp != null' "$PROJECTS")" \
  "projects: entries carry lastUp"
assert_ok   margay::projects_remove beta
assert_eq "1" "$(jq 'length' "$PROJECTS")" "projects: remove by project name"
assert_ok   margay::projects_remove /tmp/proj/acme
assert_eq "0" "$(jq 'length' "$PROJECTS")" "projects: remove by path"
assert_fail margay::projects_remove nothing-matches
rm -f "$PROJECTS"

echo "----"
if (( FAILS )); then echo "$FAILS failure(s)"; exit 1; else echo "all passed"; exit 0; fi
