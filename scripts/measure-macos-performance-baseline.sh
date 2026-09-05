#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
binary_path="$project_root/.build/release/Lithe"
output_path="${LITHE_PERFORMANCE_OUTPUT:-$project_root/.artifacts/macos-performance-baseline.tsv}"
runs=3
scenario=""
fixture_label=""
interactive=false
sample_seconds=${LITHE_BASELINE_SAMPLE_SECONDS:-2}
baseline_root=$(mktemp -d /private/tmp/lithe-performance-baseline.XXXXXX)
app_pid=""

usage() {
    cat <<'EOF'
Usage:
  scripts/measure-macos-performance-baseline.sh --list
  scripts/measure-macos-performance-baseline.sh --scenario T --fixture 500KiB [options]

Options:
  --scenario ID       T, N, D, S, Term, or R
  --fixture SIZE      10KiB, 500KiB, or 2MiB
  --runs COUNT        Number of runs (default: 3)
  --interactive       Keep each app session open for manual scenario actions
  --output PATH       Write the TSV report to PATH
  --list              Print the fixed scenarios and fixtures
EOF
}

fixture_bytes() {
    case "$1" in
        10KiB) print 10240 ;;
        500KiB) print 512000 ;;
        2MiB) print 2097152 ;;
        *) return 1 ;;
    esac
}

scenario_title() {
    case "$1" in
        T) print "连续输入" ;;
        N) print "打开大文件后空闲" ;;
        D) print "连续拖动分栏" ;;
        S) print "Search Everywhere" ;;
        Term) print "终端高频输出" ;;
        R) print "Run/Tests 输出" ;;
        *) return 1 ;;
    esac
}

list_definitions() {
    print "Scenarios:"
    for item in T N D S Term R; do
        print "  $item\t$(scenario_title "$item")"
    done
    print "Fixtures:"
    print "  10KiB\t10240 bytes"
    print "  500KiB\t512000 bytes"
    print "  2MiB\t2097152 bytes"
}

terminate_app() {
    if [[ -z "$app_pid" ]] || ! kill -0 "$app_pid" 2>/dev/null; then
        app_pid=""
        return
    fi

    kill -TERM "$app_pid" 2>/dev/null || true
    for _ in {1..50}; do
        if ! kill -0 "$app_pid" 2>/dev/null; then
            wait "$app_pid" 2>/dev/null || true
            app_pid=""
            return
        fi
        sleep 0.1
    done
    kill -KILL "$app_pid" 2>/dev/null || true
    wait "$app_pid" 2>/dev/null || true
    app_pid=""
}

cleanup() {
    terminate_app
    rm -rf "$baseline_root"
}
trap cleanup EXIT INT TERM

generate_fixture() {
    local fixture_root="$1"
    local bytes="$2"
    mkdir -p "$fixture_root"
    perl -e '
        my $size = 0 + $ARGV[0];
        my $line = "let performanceFixtureLine = \"editor baseline input\"\n";
        my $text = $line x (int($size / length($line)) + 1);
        print substr($text, 0, $size);
    ' "$bytes" > "$fixture_root/EditorPerformance.swift"
}

wait_for_ready() {
    local output_file="$1"
    local ready_line=""
    for _ in {1..150}; do
        if ! kill -0 "$app_pid" 2>/dev/null; then
            print -u2 "Lithe exited before readiness"
            sed -n '1,120p' "$output_file" >&2
            return 1
        fi
        ready_line=$(grep -m 1 '^LITHE_BASELINE_READY ' "$output_file" || true)
        [[ -n "$ready_line" ]] && break
        sleep 0.1
    done
    [[ -n "$ready_line" ]] || {
        print -u2 "Timed out waiting for LITHE_BASELINE_READY"
        return 1
    }
    print "$ready_line"
}

median() {
    printf '%s\n' "$@" | sort -n | awk '
        { values[NR] = $1 }
        END {
            if (NR == 0) exit 1
            if (NR % 2 == 1) print values[(NR + 1) / 2]
            else print int((values[NR / 2] + values[NR / 2 + 1]) / 2)
        }
    '
}

while (( $# > 0 )); do
    case "$1" in
        --list)
            list_definitions
            exit 0
            ;;
        --scenario)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            scenario="$2"
            shift 2
            ;;
        --fixture)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            fixture_label="$2"
            shift 2
            ;;
        --runs)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            runs="$2"
            shift 2
            ;;
        --interactive)
            interactive=true
            shift
            ;;
        --output)
            [[ $# -ge 2 ]] || { usage >&2; exit 2; }
            output_path="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            print -u2 "Unknown argument: $1"
            usage >&2
            exit 2
            ;;
    esac
done

[[ -n "$scenario" ]] || { print -u2 "--scenario is required"; usage >&2; exit 2; }
scenario_title "$scenario" >/dev/null || { print -u2 "Unknown scenario: $scenario"; exit 2; }
[[ -n "$fixture_label" ]] || { print -u2 "--fixture is required"; usage >&2; exit 2; }
bytes=$(fixture_bytes "$fixture_label") || { print -u2 "Unknown fixture: $fixture_label"; exit 2; }
[[ "$runs" == <-> && "$runs" -gt 0 ]] || { print -u2 "--runs must be a positive integer"; exit 2; }
if "$interactive" && [[ ! -t 0 ]]; then
    print -u2 "--interactive requires a terminal so the manual step can be acknowledged"
    exit 2
fi

mkdir -p "${output_path:h}"
printf 'scenario\tfixture\trun\tready_ms\tready_rss_kib\tstable_rss_kib\n' > "$output_path"
cd "$project_root"
swift build -c release --product Lithe >/dev/null
[[ -x "$binary_path" ]] || { print -u2 "Release binary not found: $binary_path"; exit 1; }

fixture_root="$baseline_root/$fixture_label"
generate_fixture "$fixture_root" "$bytes"
[[ "$(wc -c < "$fixture_root/EditorPerformance.swift" | tr -d ' ')" == "$bytes" ]] || {
    print -u2 "Generated fixture has an unexpected byte count"
    exit 1
}

typeset -a stable_samples
for (( run = 1; run <= runs; run++ )); do
    output_file="$baseline_root/run-$run.log"
    : > "$output_file"
    LITHE_PERFORMANCE_BASELINE=1 \
    LITHE_PERFORMANCE_SCENARIO="$scenario" \
    LITHE_PERFORMANCE_FIXTURE_BYTES="$bytes" \
        "$binary_path" --open-project "$fixture_root" > "$output_file" 2>&1 &
    app_pid=$!

    ready_line=$(wait_for_ready "$output_file")
    ready_ms=$(print "$ready_line" | sed -n 's/.*elapsed_ms=\([0-9][0-9]*\).*/\1/p')
    ready_rss_kib=$(ps -o rss= -p "$app_pid" | tr -d ' ')
    if "$interactive"; then
        print "Run $run/$runs: perform scenario $scenario ($(scenario_title "$scenario")) on fixture $fixture_label."
        print "Press Return after the scenario window is complete."
        read -r
    else
        sleep "$sample_seconds"
    fi
    stable_rss_kib=$(ps -o rss= -p "$app_pid" | tr -d ' ')
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$scenario" "$fixture_label" "$run" "$ready_ms" "$ready_rss_kib" "$stable_rss_kib" \
        >> "$output_path"
    stable_samples+=("$stable_rss_kib")
    terminate_app
done

stable_median=$(median "${stable_samples[@]}")
print -r -- "median_stable_rss_kib=$stable_median scenario=$scenario fixture=$fixture_label runs=$runs report=$output_path"
