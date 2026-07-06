# shellcheck shell=bash
# config.sh — .margay.conf discovery, loading, validation.
type die >/dev/null 2>&1 || die() { echo "margay: $*" >&2; return 1; }

margay::svc_var() { local v="service_${1}_${2}"; echo "${!v:-}"; }
margay::svc_fn_exists() { declare -F "service_${1}_${2}" >/dev/null; }

margay::parse_ports() {
  [[ "$1" =~ ^([0-9]+)-([0-9]+)$ ]] || { echo "margay: bad ports spec '$1' (want LO-HI)" >&2; return 1; }
  local lo="${BASH_REMATCH[1]}" hi="${BASH_REMATCH[2]}"
  (( lo <= hi )) || { echo "margay: bad ports spec '$1' (LO>HI)" >&2; return 1; }
  echo "$lo $hi"
}

margay::config_find() {
  if   [[ -f "$1/.margay.conf" ]]; then echo "$1/.margay.conf"
  elif [[ -f "$2/.margay.conf" ]]; then echo "$2/.margay.conf"
  else return 1; fi
}

_cerr() { echo "margay: conf: $*" >&2; return 1; }

margay::config_validate() {
  [[ -n "${project:-}"  ]] || { _cerr "'project' is required"; return 1; }
  [[ -n "${services:-}" ]] || { _cerr "'services' is required"; return 1; }
  local s db dep val needs_db=0 needs_seed=0
  for s in $services; do
    margay::parse_ports "$(margay::svc_var "$s" ports)" >/dev/null \
      || { _cerr "service_${s}_ports missing or malformed"; return 1; }
    margay::svc_fn_exists "$s" start \
      || { _cerr "service_${s}_start() is required"; return 1; }
    db="$(margay::svc_var "$s" db)"; db="${db:-none}"
    case "$db" in
      none) ;; empty) needs_db=1 ;; seed) needs_db=1; needs_seed=1 ;;
      *) _cerr "service_${s}_db must be none|empty|seed (got '$db')"; return 1 ;;
    esac
    dep="$(margay::svc_var "$s" needs)"
    if [[ -n "$dep" ]]; then
      [[ " $services " == *" $dep "* ]] \
        || { _cerr "service_${s}_needs '$dep' is not a declared service"; return 1; }
    fi
    val="$(margay::svc_var "$s" uses_project)"
    if [[ -n "$val" ]]; then
      [[ "$val" == *:* && -n "${val%%:*}" && -n "${val#*:}" ]] \
        || { _cerr "service_${s}_uses_project must be '<project>:<service>' (got '$val')"; return 1; }
    fi
  done
  if (( needs_db )); then
    declare -F postgres_psql >/dev/null || { _cerr "postgres_psql() required when a service declares a db"; return 1; }
    [[ -n "${postgres_url:-}" ]]        || { _cerr "postgres_url required when a service declares a db"; return 1; }
  fi
  if (( needs_seed )); then
    declare -F postgres_dump >/dev/null   || { _cerr "postgres_dump() required for db=seed"; return 1; }
    [[ -n "${postgres_seed_from:-}" ]]    || { _cerr "postgres_seed_from required for db=seed"; return 1; }
  fi
  # port ranges within one project must not overlap
  local a b lo1 hi1 lo2 hi2
  for a in $services; do
    for b in $services; do
      [[ "$a" == "$b" ]] && continue
      read -r lo1 hi1 <<<"$(margay::parse_ports "$(margay::svc_var "$a" ports)")"
      read -r lo2 hi2 <<<"$(margay::parse_ports "$(margay::svc_var "$b" ports)")"
      if (( lo1 <= hi2 && lo2 <= hi1 )); then
        _cerr "port ranges of '$a' and '$b' overlap"; return 1
      fi
    done
  done
  margay::topo_services >/dev/null
}

margay::topo_services() {
  local order="" visiting="" visited="" s
  _mg_visit() {
    local n="$1" d
    [[ " $visited " == *" $n "* ]] && return 0
    [[ " $visiting " == *" $n "* ]] && { _cerr "dependency cycle involving '$n'"; return 1; }
    visiting="$visiting $n"
    d="$(margay::svc_var "$n" needs)"
    if [[ -n "$d" ]]; then _mg_visit "$d" || return 1; fi
    visited="$visited $n"; order="$order $n"
  }
  for s in $services; do _mg_visit "$s" || return 1; done
  echo "${order# }"
}

margay::config_load() {
  # shellcheck source=/dev/null
  source "$1" || { _cerr "failed to source $1"; return 1; }
  margay::config_validate
}
