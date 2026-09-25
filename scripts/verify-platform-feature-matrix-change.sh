#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

base_revision="${1:-${MATRIX_BASE_SHA:-}}"
head_revision="${2:-${MATRIX_HEAD_SHA:-HEAD}}"
if [[ -z "$base_revision" ]]; then
  echo "matrix change gate skipped: provide <base> <head> or MATRIX_BASE_SHA"
  exit 0
fi

changed_files="$(git diff --name-only "$base_revision" "$head_revision")"
platform_changes="$(git diff --name-only "$base_revision" "$head_revision" -- \
  macos/Sources \
  windows/tauri/src \
  windows/tauri/src-tauri \
  Plugins/mac \
  Plugins/win \
  frontend/editor \
  rust/lithe-core \
  shared/contracts)"

if [[ -z "$platform_changes" ]]; then
  echo "matrix change gate passed: no platform implementation paths changed"
  exit 0
fi

if grep -Fxq "shared/platform-feature-matrix.json" <<< "$changed_files"; then
  echo "matrix change gate passed: platform implementation changes include the matrix source"
  exit 0
fi

if [[ "${MATRIX_UPDATE_EXEMPT:-false}" == "true" ]]; then
  echo "matrix change gate passed: explicit matrix-exempt label is present"
  exit 0
fi

echo "platform implementation paths changed without shared/platform-feature-matrix.json:"
printf '  %s\n' "$platform_changes"
echo "Update the matrix, or apply the matrix-exempt label for a reviewed non-user-visible refactor."
exit 1
