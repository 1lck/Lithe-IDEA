#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
binary_path="$project_root/.build/debug/Lithe"
sample_seconds=${LITHE_BASELINE_SAMPLE_SECONDS:-5}
baseline_root=$(mktemp -d /private/tmp/lithe-runtime-baseline.XXXXXX)
output_path="$baseline_root/lithe.log"
app_pid=""

cleanup() {
    if [[ -n "$app_pid" ]] && kill -0 "$app_pid" 2>/dev/null; then
        kill -TERM "$app_pid" 2>/dev/null || true
        wait "$app_pid" 2>/dev/null || true
    fi
    rm -f "$output_path"
    rmdir "$baseline_root" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

cd "$project_root"
swift build >/dev/null

LITHE_PERFORMANCE_BASELINE=1 "$binary_path" --open-project "$baseline_root" >"$output_path" 2>&1 &
app_pid=$!

ready_line=""
for _ in {1..150}; do
    if ! kill -0 "$app_pid" 2>/dev/null; then
        print -u2 "Lithe exited before the first window became ready"
        sed -n '1,120p' "$output_path" >&2
        exit 1
    fi
    ready_line=$(grep -m 1 '^LITHE_BASELINE_READY ' "$output_path" || true)
    [[ -n "$ready_line" ]] && break
    sleep 0.1
done

if [[ -z "$ready_line" ]]; then
    print -u2 "Timed out waiting for the Lithe readiness marker"
    exit 1
fi

ready_rss_kib=$(ps -o rss= -p "$app_pid" | tr -d ' ')
sleep "$sample_seconds"
stable_rss_kib=$(ps -o rss= -p "$app_pid" | tr -d ' ')
child_pids=$(pgrep -P "$app_pid" 2>/dev/null || true)
child_count=$(echo "$child_pids" | awk 'NF { count += 1 } END { print count + 0 }')

echo "$ready_line ready_rss_kib=$ready_rss_kib stable_rss_kib=$stable_rss_kib direct_children=$child_count sample_seconds=$sample_seconds"
