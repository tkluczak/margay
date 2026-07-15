# bash completion for margay. Renders `margay __complete` output; computes
# nothing itself. bash has no menu-select carousel — TAB lists candidates.
# shellcheck shell=bash

_margay_bash() {
  local cur cands
  cur="${COMP_WORDS[COMP_CWORD]}"

  if (( COMP_CWORD == 1 )); then
    COMPREPLY=( $(compgen -W "up down ps ls status worktrees unregister ui help" -- "$cur") )
    return 0
  fi

  case "${COMP_WORDS[1]}" in
    up|down)
      # cut -f1: drop the descriptions, bash shows bare candidates
      cands="$(margay __complete "${COMP_WORDS[1]}" 2>/dev/null | cut -f1)"
      COMPREPLY=( $(compgen -W "$cands" -- "$cur") )
      ;;
    *) COMPREPLY=() ;;
  esac
  return 0
}

complete -F _margay_bash margay sandbox
