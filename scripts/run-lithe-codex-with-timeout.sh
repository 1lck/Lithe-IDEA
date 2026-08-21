#!/usr/bin/env bash

set -euo pipefail

events_file="${LITHE_CODEX_EVENTS_FILE:?LITHE_CODEX_EVENTS_FILE is required}"
stderr_file="${LITHE_CODEX_STDERR_FILE:?LITHE_CODEX_STDERR_FILE is required}"
timeout_duration="${LITHE_CODEX_TIMEOUT:-20m}"
wrapper_directory="$(cd "$(dirname "$0")" && pwd -P)"

path_entries=()
IFS=: read -r -a original_path_entries <<< "${PATH:-}"
for entry in "${original_path_entries[@]}"; do
    if [[ -n "$entry" && "$entry" != "$wrapper_directory" ]]; then
        path_entries+=("$entry")
    fi
done
search_path="$(IFS=:; echo "${path_entries[*]}")"
real_codex="$(PATH="$search_path" command -v codex || true)"
if [[ -z "$real_codex" ]]; then
    echo "Could not locate the Codex CLI behind the Lithe watchdog wrapper" >&2
    exit 127
fi

timeout_binary="$(command -v timeout || command -v gtimeout || true)"
if [[ -z "$timeout_binary" ]]; then
    echo "The Lithe Codex watchdog requires timeout or gtimeout" >&2
    exit 127
fi

mkdir -p "$(dirname "$events_file")" "$(dirname "$stderr_file")"
: > "$events_file"
: > "$stderr_file"

echo "[lithe-review] Codex watchdog timeout=${timeout_duration}" >&2
echo "[lithe-review] Codex JSONL=${events_file}" >&2
echo "[lithe-review] Codex stderr=${stderr_file}" >&2

set +e
"$timeout_binary" --signal=TERM --kill-after=30s "$timeout_duration" "$real_codex" "$@" \
    > >(tee -a "$events_file") \
    2> >(tee -a "$stderr_file" >&2)
codex_status=$?
set -e

if [[ "$codex_status" -eq 124 || "$codex_status" -eq 137 ]]; then
    echo "[lithe-review] Codex watchdog terminated the process after ${timeout_duration} (status ${codex_status})" >&2
else
    echo "[lithe-review] Codex exited with status ${codex_status}" >&2
fi
exit "$codex_status"
