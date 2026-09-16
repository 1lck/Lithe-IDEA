#!/bin/zsh
set -euo pipefail

root=${0:A:h:h}
if [[ "${1:-}" == "--help" ]]; then
    print 'Usage: scripts/probe-macos-monaco.sh [--workbench-tests | --logic-only | --manual [file]]'
    print 'Requires Swift, Bun, and Node; installs the locked shared editor dependencies.'
    print 'Set LITHE_MONACO_PACKAGE_DIR to reuse an existing Monaco installation.'
    print 'Automatic runs require an unlocked, awake display. Manual sessions close after 10 minutes.'
    print '--logic-only validates bridge/worker correctness without animation frames or screenshots.'
    print 'Saves only .artifacts/monaco-probe/document-copy.java; never modifies the input file.'
    exit 0
fi
if (( $# > 0 )) && [[ "$1" != "--manual" && "$1" != "--logic-only" && "$1" != "--workbench-tests" ]]; then
    print -u2 'Unexpected argument. See --help.'
    exit 2
fi
output="$root/.artifacts/monaco-probe"
run_output="$output"
asset_output="$output/assets"
build_args=()
host_args=("$@")
if [[ "${1:-}" == "--logic-only" ]]; then
    run_output="$output/logic"
elif [[ "${1:-}" == "--workbench-tests" ]]; then
    run_output="$root/.artifacts/monaco-workbench/test-results"
    asset_output="$root/.artifacts/monaco-workbench/test-assets"
    build_args+=(--workbench-tests)
    host_args+=(--logic-only)
fi
monaco_dir="${LITHE_MONACO_PACKAGE_DIR:-$root/frontend/editor/node_modules/monaco-editor}"
mkdir -p "$run_output"
if [[ "${1:-}" != "--manual" ]]; then
    print '{"status":"running","error":"Run did not complete"}' > "$run_output/result.json"
fi
bun install --frozen-lockfile --cwd "$root/frontend/editor"
bun "$root/macos/Experiments/Monaco/build.ts" "$monaco_dir" "${build_args[@]}"
swiftc -O -swift-version 5 -framework AppKit -framework WebKit \
    "$root/macos/Experiments/Monaco/main.swift" -o "$output/LitheMonacoProbe"
swift --version > "$output/toolchain.txt" 2>&1
child_pid=""
cleanup() {
    if [[ -n "$child_pid" ]] && kill -0 "$child_pid" 2>/dev/null; then
        kill -TERM "$child_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT INT TERM
"$output/LitheMonacoProbe" "$asset_output" "$run_output" "${host_args[@]}" &
child_pid=$!
probe_result=0
wait "$child_pid" || probe_result=$?
child_pid=""
if [[ "${1:-}" != "--manual" ]]; then
    node "$root/macos/Experiments/Monaco/report.mjs" "$@"
fi
print "Probe output: $run_output"
exit "$probe_result"
