# shellcheck shell=bash
# engine.sh — generic engine helpers for margay: registry, ports,
# db-on-hooks, dependency resolution. Sourced by ./margay and by the
# test suites (test/margay_test.sh, test/integration_test.sh).

# Guarded so pure lib functions (e.g. resolve_dep) can be sourced standalone
# by the test harness, which does not source the entrypoint's die().
type die >/dev/null 2>&1 || die() { echo "margay: $*" >&2; return 1; }

# ---- CONFIG (only project-specific values; see plan Global Constraints) ----
MARGAY_HOME="${MARGAY_HOME:-$HOME/.margay}"
REGISTRY="$MARGAY_HOME/registry.json"
PROJECTS="$MARGAY_HOME/projects.json"
LOG_DIR="$MARGAY_HOME/logs"
# ---- END CONFIG ----

margay::slugify() {
  echo "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/_/g; s/^_+//; s/_+$//'
}

# Host-name slug — MUST mirror slugify() in lib/ui.py (dashes, not underscores)
# so hooks see the same hostnames the proxy actually routes.
margay::host_slug() {
  echo "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9-]/-/g; s/-+/-/g; s/^-+//; s/-+$//'
}

margay::db_name() {
  local slug; slug="$(margay::slugify "$2")"
  echo "${1}_sb_${slug}" | cut -c1-63
}

margay::primary_worktree() {
  git worktree list --porcelain | awk '/^worktree /{print $2; exit}'
}

margay::registry_init() {
  mkdir -p "$MARGAY_HOME" "$LOG_DIR"
  [[ -f "$REGISTRY" ]] || echo '[]' > "$REGISTRY"
}

margay::registry_add() {
  margay::registry_init
  local tmp; tmp="$(mktemp)"
  jq --argjson o "$1" '. + [$o]' "$REGISTRY" > "$tmp" && mv "$tmp" "$REGISTRY"
}

margay::registry_used_ports() {
  margay::registry_init
  jq -r --arg p "$1" --arg s "$2" \
    '[.[] | select(.project==$p and .service==$s) | .port] | join(" ")' "$REGISTRY"
}

margay::registry_last_instance() {
  margay::registry_init
  jq -r --arg p "$1" --arg s "$2" \
    '[.[] | select(.project==$p and .service==$s)] | sort_by(.startedAt) | last | .port // empty' "$REGISTRY"
}

margay::registry_prune() {
  margay::registry_init
  local alive=() pid
  while read -r pid; do
    [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && alive+=("$pid")
  done < <(jq -r '.[].pid' "$REGISTRY")
  local list='[]'
  if ((${#alive[@]})); then
    list="$(printf '%s\n' "${alive[@]}" | jq -R 'tonumber' | jq -s '.')"
  fi
  local tmp; tmp="$(mktemp)"
  jq --argjson a "$list" '[ .[] | select(.pid as $p | $a | index($p)) ]' "$REGISTRY" > "$tmp" && mv "$tmp" "$REGISTRY"
}

margay::registry_remove_by_pid() {
  margay::registry_init
  local tmp; tmp="$(mktemp)"
  jq --argjson p "$1" '[ .[] | select(.pid != $p) ]' "$REGISTRY" > "$tmp" && mv "$tmp" "$REGISTRY"
}

# ---- projects.json: static registry of every project ever margay'd ----
margay::projects_init() {
  mkdir -p "$MARGAY_HOME"
  [[ -f "$PROJECTS" ]] || echo '[]' > "$PROJECTS"
}

# Upsert keyed on primaryPath; refreshes project name and lastUp.
margay::projects_learn() {   # project primaryPath
  margay::projects_init
  local tmp; tmp="$(mktemp)"
  jq --arg p "$1" --arg path "$2" --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '[ .[] | select(.primaryPath != $path) ] + [{project:$p, primaryPath:$path, lastUp:$at}]' \
    "$PROJECTS" > "$tmp" && mv "$tmp" "$PROJECTS"
  return 0
}

# Remove entries whose primaryPath OR project equals the query.
# rc 0 if something was removed, 1 otherwise.
margay::projects_remove() {   # query
  margay::projects_init
  local before after tmp
  before="$(jq 'length' "$PROJECTS")"
  tmp="$(mktemp)"
  jq --arg q "$1" '[ .[] | select(.primaryPath != $q and .project != $q) ]' \
    "$PROJECTS" > "$tmp" && mv "$tmp" "$PROJECTS"
  after="$(jq 'length' "$PROJECTS")"
  [[ "$after" -lt "$before" ]]
}

# Args: project service branch worktree port db uses pid [log]
margay::registry_record() {
  jq -nc \
    --arg project "$1" --arg service "$2" --arg branch "$3" --arg wt "$4" \
    --argjson port "$5" --arg db "$6" --arg uses "$7" --argjson pid "$8" \
    --arg log "${9:-}" \
    --arg at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '{project:$project,service:$service,branch:$branch,worktreePath:$wt,port:$port,
      dbName:(if $db=="" then null else $db end),
      uses:(if $uses=="" then null else $uses end),
      log:(if $log=="" then null else $log end),
      pid:$pid,startedAt:$at}'
}

margay::log_path() { margay::registry_init; echo "$LOG_DIR/$1-$(margay::slugify "$3")-$2.log"; }

margay::first_free_in_set() {
  local lo="$1" hi="$2" used=" $3 " p
  for ((p=lo; p<=hi; p++)); do
    [[ "$used" != *" $p "* ]] && { echo "$p"; return 0; }
  done
  return 1
}

margay::os_port_free() {
  ! lsof -nP -iTCP:"$1" -sTCP:LISTEN >/dev/null 2>&1
}

margay::alloc_port() {   # $1 = service; conf must be loaded
  local svc="$1" lo hi used p range
  margay::registry_prune
  range="$(margay::parse_ports "$(margay::svc_var "$svc" ports)")" || return 1
  read -r lo hi <<<"$range"
  used="$(margay::registry_init; jq -r '[.[] | .port] | join(" ")' "$REGISTRY")"
  for ((p=lo; p<=hi; p++)); do
    [[ " $used " == *" $p "* ]] && continue
    margay::os_port_free "$p" && { echo "$p"; return 0; }
  done
  return 1
}

margay::env_name() { echo "$1" | tr '[:lower:]' '[:upper:]' | sed 's/[^A-Z0-9]/_/g'; }

margay::use_override() {
  local pair
  for pair in $1; do
    [[ "$pair" == "$2="* ]] && { echo "${pair#*=}"; return 0; }
  done
  echo ""
}

margay::resolve_dep() {   # project service worktree override main_port → "port url"
  local proj="$1" svc="$2" wt="$3" ov="$4" main="${5:-}" port
  if [[ -n "$ov" ]]; then
    case "$ov" in
      http://*|https://*)
        [[ "$ov" =~ :([0-9]+)(/|$) ]] || { die "bad --use URL (need an explicit :port): $ov"; return 1; }
        port="${BASH_REMATCH[1]}"
        echo "$port $ov"; return 0 ;;
      *[!0-9]*) die "bad --use value: $ov"; return 1 ;;
      *) echo "$ov http://localhost:$ov"; return 0 ;;
    esac
  fi
  margay::registry_prune
  port="$(jq -r --arg p "$proj" --arg s "$svc" --arg wt "$wt" \
    '[.[] | select(.project==$p and .service==$s and .worktreePath==$wt)] | sort_by(.startedAt) | last | .port // empty' "$REGISTRY")"
  [[ -z "$port" ]] && port="$(margay::registry_last_instance "$proj" "$svc")"
  [[ -z "$port" && -n "$main" ]] && port="$main"
  [[ -n "$port" ]] || return 1
  echo "$port http://localhost:$port"
}

margay::url_for_db() { echo "${postgres_url//\{db\}/$1}"; }

margay::db_exists() {   # 0=exists 1=absent 2=hook failure
  local out
  out="$(postgres_psql -tAc "SELECT 1 FROM pg_database WHERE datname='$1'" </dev/null)" || return 2
  [[ "$out" == "1" ]]
}
margay::db_create() { postgres_psql -c "CREATE DATABASE \"$1\"" </dev/null >/dev/null; }
margay::db_drop()   { postgres_psql -c "DROP DATABASE IF EXISTS \"$1\" WITH (FORCE)" </dev/null >/dev/null; }
margay::db_seed()   { postgres_dump "$postgres_seed_from" | postgres_psql -d "$1" >/dev/null; }

# ---- worktrees ----
# Parse `git worktree list --porcelain` into "path<TAB>branch" lines.
# branch is the short name; literal HEAD for a detached worktree.
margay::worktrees_parse() {
  local line path="" branch=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      "worktree "*)           [[ -n "$path" ]] && printf '%s\t%s\n' "$path" "${branch:-HEAD}"
                              path="${line#worktree }"; branch="" ;;
      "branch refs/heads/"*)  branch="${line#branch refs/heads/}" ;;
      detached)               branch="HEAD" ;;
    esac
  done
  [[ -n "$path" ]] && printf '%s\t%s\n' "$path" "${branch:-HEAD}"
  return 0
}

# Resolve a worktree query against worktrees_parse output (stdin).
# Exact (basename|branch) beats substring. rc: 0 unique (echoes the row),
# 1 miss, 2 ambiguous (echoes all candidate rows).
margay::worktree_resolve() {
  local q="$1" path branch base exacts="" subs="" hits n
  while IFS=$'\t' read -r path branch; do
    base="${path##*/}"
    if [[ "$base" == "$q" || "$branch" == "$q" ]]; then
      exacts="${exacts}${path}	${branch}"$'\n'
    elif [[ "$base" == *"$q"* || "$branch" == *"$q"* ]]; then
      subs="${subs}${path}	${branch}"$'\n'
    fi
  done
  hits="$exacts"
  [[ -z "$hits" ]] && hits="$subs"
  [[ -z "$hits" ]] && return 1
  n="$(printf '%s' "$hits" | grep -c .)"
  printf '%s' "$hits"
  [[ "$n" -eq 1 ]] || return 2
  return 0
}

# 0 iff some row's basename or branch EQUALS the query (exact only).
margay::worktree_exact_exists() {
  local q="$1" path branch
  while IFS=$'\t' read -r path branch; do
    [[ "${path##*/}" == "$q" || "$branch" == "$q" ]] && return 0
  done
  return 1
}

# Join worktrees_parse rows (stdin) with live registry rows by worktreePath.
# Emits "path<TAB>branch<TAB>sandbox<TAB>db"; sandbox/db are — when empty.
margay::worktrees_join() {
  margay::registry_prune
  local path branch sandbox db
  while IFS=$'\t' read -r path branch; do
    sandbox="$(jq -r --arg wt "$path" \
      '[.[] | select(.worktreePath==$wt) | "\(.service):\(.port)"] | join(" ")' "$REGISTRY")"
    db="$(jq -r --arg wt "$path" \
      '[.[] | select(.worktreePath==$wt) | .dbName // empty] | unique | join(" ")' "$REGISTRY")"
    printf '%s\t%s\t%s\t%s\n' "$path" "$branch" "${sandbox:--}" "${db:--}"
  done
}
