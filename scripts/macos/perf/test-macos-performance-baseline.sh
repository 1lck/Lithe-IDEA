#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
measure_script="$script_dir/measure-macos-performance-baseline.sh"
test_root=$(mktemp -d /private/tmp/lithe-performance-baseline-stats.XXXXXX)
trap 'rm -rf "$test_root"' EXIT

assert_stats() {
    local name="$1"
    local expected="$2"
    local log_path="$3"
    local actual
    actual=$("$measure_script" --stats "$name" "$log_path")
    [[ "$actual" == "$expected" ]] || {
        print -u2 "Unexpected statistics for $name:"
        print -u2 "expected: $expected"
        print -u2 "actual:   $actual"
        exit 1
    }
}

empty_log="$test_root/empty.log"
: > "$empty_log"
assert_stats editor.input $'0\tNA\tNA\tNA' "$empty_log"

single_log="$test_root/single.log"
print 'LITHE_PERF_SIGNPOST name=editor.input duration_ms=7.500' > "$single_log"
assert_stats editor.input $'1\t7.500\t7.500\t7.500' "$single_log"

multiple_log="$test_root/multiple.log"
print -l \
    'LITHE_PERF_SIGNPOST name=editor.input duration_ms=4.000' \
    'LITHE_PERF_SIGNPOST name=editor.input duration_ms=1.000' \
    'LITHE_PERF_SIGNPOST name=editor.input duration_ms=9.000' \
    'LITHE_PERF_SIGNPOST name=editor.input duration_ms=3.000' \
    'LITHE_PERF_SIGNPOST name=editor.input duration_ms=8.000' \
    'LITHE_PERF_SIGNPOST name=appmodel.relay duration_ms=100.000' \
    > "$multiple_log"
assert_stats editor.input $'5\t4.000\t9.000\t9.000' "$multiple_log"
assert_stats appmodel.relay $'1\t100.000\t100.000\t100.000' "$multiple_log"

print "macOS performance baseline statistics test passed."
