#!/usr/bin/env bash
# Runs the Lithe editor performance baseline (the ^BenchmarkEditor benchmarks of the rope, syntax
# and editorview packages) and reports the results against desktop/benchmarks/editor-budgets.json.
#
# Usage:
#   scripts/desktop/perf/editor-bench.sh run [--bench REGEX] [--count N] [--benchtime T]
#                                            [--large-bytes SIZE] [--out FILE] [--base FILE]
#   scripts/desktop/perf/editor-bench.sh record --machine LABEL --kind physical|vm|software-gpu
#                                               [--large-bytes SIZE] [--force]
#   scripts/desktop/perf/editor-bench.sh compare BASE CANDIDATE
#   scripts/desktop/perf/editor-bench.sh report FILE [--base FILE]
#
# run     Runs the benchmarks, saves the raw output and a Markdown report under .artifacts/editor-perf.
# record  Runs the benchmarks with enough samples for history (count 6, benchtime 500ms) and appends
#         them to desktop/benchmarks/history/LABEL.jsonl with Viva's perfhistory tool. It refuses to
#         run on a loaded machine, because background load inflates every result.
# compare Runs perfhistory compare of CANDIDATE against BASE (threshold 15%, ignoring results under
#         20 ns) and prints the budget report of CANDIDATE.
# report  Prints the budget report of an existing benchmark output file.
#
# Results are reports. A result over its budget never fails this script; only a benchmark that does
# not compile, panics or cannot be read does. The baseline is not part of required CI: run it
# locally when you change the editor modules. Record only on an idle machine, with nothing else
# running, and use the same machine and kind for every entry of one history file.
#
# LITHE_EDITOR_PERF_LARGE_BYTES (for example 10MiB, default 10 MiB) sets the large document size;
# --large-bytes exports it for the run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../../.." && pwd -P)"
PACKAGES=(./internal/editor/rope ./internal/editor/syntax ./internal/editorview)
OUT_DIR="$ROOT_DIR/.artifacts/editor-perf"
BUDGETS="$ROOT_DIR/desktop/benchmarks/editor-budgets.json"
HISTORY_DIR="$ROOT_DIR/desktop/benchmarks/history"

usage() {
    cat >&2 <<'EOF'
Usage:
  editor-bench.sh run [--bench REGEX] [--count N] [--benchtime T] [--large-bytes SIZE]
                      [--out FILE] [--base FILE]
  editor-bench.sh record --machine LABEL --kind physical|vm|software-gpu
                         [--large-bytes SIZE] [--force]
  editor-bench.sh compare BASE CANDIDATE
  editor-bench.sh report FILE [--base FILE]

Defaults for run: --bench '^BenchmarkEditor' --count 1 --benchtime 200ms.
Results are reports: a budget overrun never fails the script.
record must run on an idle machine; --force skips the load check.
EOF
}

usage_error() {
    printf 'editor-bench: %s\n\n' "$1" >&2
    usage
    exit 2
}

die() {
    printf 'editor-bench: %s\n' "$1" >&2
    exit 1
}

require_tool() {
    if ! command -v "$1" >/dev/null 2>&1; then
        die "$1 is required but was not found on PATH. $2"
    fi
}

# An option needs a non-empty value: $1 is the option, $2 its value.
require_value() {
    if [[ $# -lt 2 || -z "$2" ]]; then
        usage_error "$1 requires a value"
    fi
}

require_file() {
    if [[ ! -f "$1" ]]; then
        die "$2 not found: $1"
    fi
}

# Prints a path as absolute, so it stays valid when a tool runs in another directory.
absolute_path() {
    printf '%s/%s\n' "$(cd "$(dirname "$1")" && pwd -P)" "$(basename "$1")"
}

load_average_1m() {
    case "$(uname -s)" in
        Darwin) LC_ALL=C sysctl -n vm.loadavg | awk '{ print $2 }' ;;
        Linux) awk '{ print $1 }' /proc/loadavg ;;
        *) return 1 ;;
    esac
}

cpu_count() {
    case "$(uname -s)" in
        Darwin) sysctl -n hw.ncpu ;;
        *) nproc ;;
    esac
}

# Refuses to record on a loaded machine: Viva measured a 35 us result becoming 134 us at load 10,
# so a baseline recorded under load would hide or invent regressions.
require_idle_machine() {
    local force="$1"
    local load cores threshold
    if [[ "$force" == true ]]; then
        printf '%s\n' 'editor-bench: --force given, skipping the idle machine check.' >&2
        return 0
    fi
    load="$(load_average_1m)" || die 'Cannot read the 1-minute load average. Run on an idle machine and pass --force to skip this check.'
    cores="$(cpu_count)" || die 'Cannot read the CPU count. Run on an idle machine and pass --force to skip this check.'
    if [[ ! "$load" =~ ^[0-9]+([.][0-9]+)?$ || ! "$cores" =~ ^[0-9]+$ ]]; then
        die "Unrecognised load '$load' or CPU count '$cores'. Run on an idle machine and pass --force to skip this check."
    fi
    threshold="$(awk -v cores="$cores" 'BEGIN { printf "%.2f", cores / 4 }')"
    if awk -v load="$load" -v threshold="$threshold" 'BEGIN { exit !(load + 0 > threshold + 0) }'; then
        die "The 1-minute load average is $load on $cores cores (limit $threshold). A loaded machine inflates results (Viva measured 35 us becoming 134 us at load 10), so a recorded baseline would be wrong. Close other work and retry, or pass --force to record anyway."
    fi
}

# Runs the benchmarks and saves the raw output. A benchmark that fails to build or panics makes
# go test fail, and pipefail turns that into a failure of this script.
run_benchmarks() {
    local bench="$1" count="$2" benchtime="$3" large_bytes="$4" out="$5"
    mkdir -p "$(dirname "$out")"
    if [[ -n "$large_bytes" ]]; then
        export LITHE_EDITOR_PERF_LARGE_BYTES="$large_bytes"
    fi
    printf 'Running %s (count %s, benchtime %s) into %s\n' "$bench" "$count" "$benchtime" "$out" >&2
    if ! go -C "$ROOT_DIR/desktop" test -run '^$' -bench "$bench" -benchmem -count "$count" \
        -benchtime "$benchtime" -timeout 60m "${PACKAGES[@]}" | tee "$out"; then
        die "go test failed; the output so far is in $out"
    fi
}

render_report() {
    local candidate="$1" base="${2:-}"
    local args=(--budgets "$BUDGETS")
    if [[ -n "$base" ]]; then
        args+=(--base "$base")
    fi
    node "$SCRIPT_DIR/editor-perf-report.mjs" "${args[@]}" "$candidate"
}

# Prints the report and saves it next to the raw output.
write_report() {
    local out="$1" base="${2:-}"
    local report="${out%.txt}.md"
    render_report "$out" "$base" | tee "$report"
    printf 'Report written to %s\n' "$report" >&2
}

timestamp() {
    date -u +%Y%m%dT%H%M%SZ
}

cmd_run() {
    local bench='^BenchmarkEditor' count=1 benchtime=200ms large_bytes='' out='' base=''
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --bench) require_value "$@"; bench="$2"; shift 2 ;;
            --count) require_value "$@"; count="$2"; shift 2 ;;
            --benchtime) require_value "$@"; benchtime="$2"; shift 2 ;;
            --large-bytes) require_value "$@"; large_bytes="$2"; shift 2 ;;
            --out) require_value "$@"; out="$2"; shift 2 ;;
            --base) require_value "$@"; base="$2"; shift 2 ;;
            *) usage_error "Unknown option for run: $1" ;;
        esac
    done
    if [[ ! "$count" =~ ^[1-9][0-9]*$ ]]; then
        usage_error "--count must be a positive integer, not $count"
    fi
    require_tool go 'Install Go (see desktop/go.mod for the version).'
    require_tool node 'Install Node.js; the report generator needs it.'
    if [[ -n "$base" ]]; then
        require_file "$base" 'Base file'
    fi
    if [[ -z "$out" ]]; then
        out="$OUT_DIR/run-$(timestamp).txt"
    fi
    run_benchmarks "$bench" "$count" "$benchtime" "$large_bytes" "$out"
    write_report "$out" "$base"
}

cmd_record() {
    local machine='' kind='' large_bytes='' force=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --machine) require_value "$@"; machine="$2"; shift 2 ;;
            --kind) require_value "$@"; kind="$2"; shift 2 ;;
            --large-bytes) require_value "$@"; large_bytes="$2"; shift 2 ;;
            --force) force=true; shift ;;
            *) usage_error "Unknown option for record: $1" ;;
        esac
    done
    if [[ -z "$machine" ]]; then
        usage_error 'record requires --machine LABEL'
    fi
    if [[ ! "$machine" =~ ^[A-Za-z0-9._-]+$ ]]; then
        usage_error "--machine must contain only letters, digits, dot, underscore and dash, not $machine"
    fi
    case "$kind" in
        physical | vm | software-gpu) ;;
        *) usage_error 'record requires --kind physical, vm or software-gpu' ;;
    esac
    require_tool go 'Install Go (see desktop/go.mod for the version).'
    require_tool node 'Install Node.js; the report generator needs it.'
    require_idle_machine "$force"

    local out
    out="$OUT_DIR/record-$(timestamp).txt"
    run_benchmarks '^BenchmarkEditor' 6 500ms "$large_bytes" "$out"
    mkdir -p "$HISTORY_DIR"
    go -C "$ROOT_DIR/desktop" run github.com/vivaui/viva/tools/perfhistory record \
        -machine "$machine" -kind "$kind" -dir "$HISTORY_DIR" < "$out"
    printf 'Appended the run to %s/%s.jsonl\n' "$HISTORY_DIR" "$machine" >&2
    write_report "$out" ''
}

cmd_compare() {
    if [[ $# -ne 2 ]]; then
        usage_error 'compare needs BASE and CANDIDATE'
    fi
    local base="$1" candidate="$2"
    require_tool go 'Install Go (see desktop/go.mod for the version).'
    require_tool node 'Install Node.js; the report generator needs it.'
    require_file "$base" 'Base file'
    require_file "$candidate" 'Candidate file'

    # The tool runs in desktop/, so a relative base path must be made absolute first.
    local base_path status=0
    base_path="$(absolute_path "$base")"
    go -C "$ROOT_DIR/desktop" run github.com/vivaui/viva/tools/perfhistory compare \
        -threshold 0.15 -min-ns 20 "$base_path" < "$candidate" || status=$?
    if [[ "$status" -eq 1 ]]; then
        printf '%s\n' 'perfhistory found regressions; this is a report, not a gate' >&2
    elif [[ "$status" -ne 0 ]]; then
        die "perfhistory failed with exit status $status"
    fi
    render_report "$candidate" "$base"
}

cmd_report() {
    local file='' base=''
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --base) require_value "$@"; base="$2"; shift 2 ;;
            -*) usage_error "Unknown option for report: $1" ;;
            *)
                if [[ -n "$file" ]]; then
                    usage_error "Unexpected extra argument: $1"
                fi
                file="$1"
                shift
                ;;
        esac
    done
    if [[ -z "$file" ]]; then
        usage_error 'report needs FILE'
    fi
    require_tool node 'Install Node.js; the report generator needs it.'
    require_file "$file" 'Benchmark output'
    if [[ -n "$base" ]]; then
        require_file "$base" 'Base file'
    fi
    render_report "$file" "$base"
}

main() {
    local command="${1:-}"
    if [[ $# -gt 0 ]]; then
        shift
    fi
    case "$command" in
        run) cmd_run "$@" ;;
        record) cmd_record "$@" ;;
        compare) cmd_compare "$@" ;;
        report) cmd_report "$@" ;;
        help | -h | --help | '')
            usage
            exit 2
            ;;
        *) usage_error "Unknown command: $command" ;;
    esac
}

main "$@"
