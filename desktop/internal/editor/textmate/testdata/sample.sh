#!/usr/bin/env bash
# Build the thing
set -euo pipefail
NAME="${1:-world}"
readonly COUNT=$((2 + 3))
greet() {
  local who=$1
  echo "Hello, $who! ${NAME^^}" >&2
  printf '%s\n' 'single $quoted'
}
for f in *.txt; do
  if [[ -f "$f" && $COUNT -gt 1 ]]; then
    cat "$f" | grep -E '^a' || true
  fi
done
case "$NAME" in
  a*) greet "$(whoami)" ;;
  *) exit 1 ;;
esac
cat <<EOT
here $NAME
EOT
