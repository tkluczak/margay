#!/usr/bin/env bash
# install.sh — put margay on PATH and guard .margay.conf. Idempotent.
# Usage: bash install.sh
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

fail=0
for dep in jq git lsof; do
  command -v "$dep" >/dev/null 2>&1 || { echo "✗ missing dependency: $dep" >&2; fail=1; }
done
(( fail )) && { echo "install aborted — install the missing tools first" >&2; exit 1; }
command -v docker >/dev/null 2>&1 \
  || echo "! docker not found — fine unless a project's conf uses postgres hooks"

bindir="$HOME/.local/bin"
mkdir -p "$bindir"
ln -sf "$HERE/margay" "$bindir/margay"
ln -sf "$HERE/margay" "$bindir/sandbox"   # compat alias
echo "✔ symlinked ~/.local/bin/margay (+ sandbox alias) → $HERE/margay"
case ":$PATH:" in
  *":$bindir:"*) ;;
  *) echo "! ~/.local/bin is not on PATH — add:  export PATH=\"\$HOME/.local/bin:\$PATH\"" ;;
esac

# Migrate from the old ~/bin location: drop stale symlinks that point at this repo.
for old in "$HOME/bin/margay" "$HOME/bin/sandbox"; do
  if [[ -L "$old" && "$(readlink "$old")" == "$HERE/margay" ]]; then
    rm "$old"
    echo "✔ removed old symlink $old"
  fi
done
rmdir "$HOME/bin" 2>/dev/null && echo "✔ removed empty ~/bin" || true

# Global gitignore guard: .margay.conf must never be committable in project repos.
ignore="$(git config --global core.excludesFile 2>/dev/null || true)"
ignore="${ignore:-$HOME/.config/git/ignore}"
ignore="${ignore/#\~/$HOME}"
mkdir -p "$(dirname "$ignore")"
grep -qx '.margay.conf' "$ignore" 2>/dev/null || echo '.margay.conf' >> "$ignore"
echo "✔ .margay.conf guarded in global gitignore ($ignore)"

echo "▶ sanity: running the unit suite"
out="$(bash "$HERE/test/margay_test.sh" 2>&1)" \
  || { printf '%s\n' "$out" >&2; echo "✗ tests failed" >&2; exit 1; }
echo "✔ all tests passed"

cat <<'EOF'

Next: drop a .margay.conf into each project repo's PRIMARY checkout
(machine-local, never committed — see examples/ for annotated starters),
then from any worktree:  margay up
EOF
