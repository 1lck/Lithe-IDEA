#!/bin/zsh
set -euo pipefail

script_dir=${0:A:h}
project_root=${script_dir:h}
case "$(uname -m)" in
    arm64) macos_triple="arm64-apple-macosx" ;;
    x86_64) macos_triple="x86_64-apple-macosx" ;;
    *)
        print -u2 "Unsupported host architecture: $(uname -m)"
        exit 1
        ;;
esac
build_root="$project_root/.build/$macos_triple/release"
binary_path="$build_root/Lithe"
output_path="${LITHE_PERFORMANCE_OUTPUT:-$project_root/.artifacts/macos-performance-baseline.tsv}"
runs=3
scenario=""
fixture_label=""
interactive=false
stats_name=""
stats_path=""
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
  --stats NAME PATH   Parse signpost statistics from an existing log
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

prepare_baseline_app() {
    local app_dir="$1"
    local bundle_identifier="$2"
    mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
    cp "$binary_path" "$app_dir/Contents/MacOS/Lithe"
    cp "$project_root/macos/Resources/Info.plist" "$app_dir/Contents/Info.plist"
    cp -R "$build_root/Lithe_Lithe.bundle" \
        "$app_dir/Contents/Resources/Lithe_Lithe.bundle"
    cp -R "$build_root/SwiftTerm_SwiftTerm.bundle" \
        "$app_dir/Contents/Resources/SwiftTerm_SwiftTerm.bundle"
    cp "$project_root/macos/Resources/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
    cp -R "$project_root/macos/Resources/Fonts" "$app_dir/Contents/Resources/Fonts"
    cp -R "$project_root/macos/Resources/IDEAIcons" "$app_dir/Contents/Resources/IDEAIcons"
    cp -R "$project_root/macos/Resources/DatabaseIcons" "$app_dir/Contents/Resources/DatabaseIcons"
    for localization in en.lproj zh-Hans.lproj; do
        if [[ -d "$project_root/macos/Resources/$localization" ]]; then
            cp -R "$project_root/macos/Resources/$localization" \
                "$app_dir/Contents/Resources/$localization"
        fi
    done
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $bundle_identifier" \
        "$app_dir/Contents/Info.plist"
    codesign --force --deep --sign - "$app_dir" >/dev/null
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
    ' "$bytes" > "$fixture_root/EditorPerformance.txt"
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

signpost_stats() {
    local name="$1"
    local output_file="$2"
    awk -v target="$name" '
        /^LITHE_PERF_SIGNPOST / {
            event_name = ""
            duration = ""
            for (i = 1; i <= NF; i++) {
                split($i, pair, "=")
                if (pair[1] == "name") event_name = pair[2]
                if (pair[1] == "duration_ms") duration = pair[2] + 0
            }
            if (event_name == target && duration != "") durations[++count] = duration
        }
        END {
            if (count == 0) {
                print "0\tNA\tNA\tNA"
                exit
            }
            for (i = 1; i <= count; i++) {
                for (j = i + 1; j <= count; j++) {
                    if (durations[j] < durations[i]) {
                        value = durations[i]
                        durations[i] = durations[j]
                        durations[j] = value
                    }
                }
            }
            if (count % 2 == 1) {
                p50 = durations[(count + 1) / 2]
            } else {
                p50 = (durations[count / 2] + durations[count / 2 + 1]) / 2
            }
            p95_index = int(count * 0.95)
            if (count * 0.95 > p95_index) p95_index++
            if (p95_index < 1) p95_index = 1
            printf "%d\t%.3f\t%.3f\t%.3f\n", count, p50, durations[p95_index], durations[count]
        }
    ' "$output_file"
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
        --stats)
            [[ $# -ge 3 ]] || { usage >&2; exit 2; }
            stats_name="$2"
            stats_path="$3"
            shift 3
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

if [[ -n "$stats_name" ]]; then
    [[ -f "$stats_path" ]] || { print -u2 "Signpost log not found: $stats_path"; exit 1; }
    signpost_stats "$stats_name" "$stats_path"
    exit 0
fi

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
printf 'scenario\tfixture\trun\tready_ms\tready_rss_kib\tstable_rss_kib\teditor_input_count\teditor_input_p50_ms\teditor_input_p95_ms\teditor_input_max_ms\tappmodel_relay_count\tappmodel_relay_p50_ms\tappmodel_relay_p95_ms\tappmodel_relay_max_ms\tsplit_drag_count\tsplit_drag_p50_ms\tsplit_drag_p95_ms\tsplit_drag_max_ms\tsearch_everywhere_count\tsearch_everywhere_p50_ms\tsearch_everywhere_p95_ms\tsearch_everywhere_max_ms\n' > "$output_path"
cd "$project_root"
scripts/build-macos.sh \
    --configuration release \
    --triple "$macos_triple" >/dev/null
[[ -x "$binary_path" ]] || { print -u2 "Release binary not found: $binary_path"; exit 1; }

fixture_root="$baseline_root/$fixture_label"
generate_fixture "$fixture_root" "$bytes"
[[ "$(wc -c < "$fixture_root/EditorPerformance.txt" | tr -d ' ')" == "$bytes" ]] || {
    print -u2 "Generated fixture has an unexpected byte count"
    exit 1
}

typeset -a stable_samples
for (( run = 1; run <= runs; run++ )); do
    output_file="$baseline_root/run-$run.log"
    app_bundle="$baseline_root/Lithe-$run.app"
    prepare_baseline_app "$app_bundle" "app.lithe.performance.$$.${run}"
    : > "$output_file"
    LITHE_PERFORMANCE_BASELINE=1 \
    LITHE_PERFORMANCE_SCENARIO="$scenario" \
    LITHE_PERFORMANCE_FIXTURE_BYTES="$bytes" \
        "$app_bundle/Contents/MacOS/Lithe" --open-project "$fixture_root" > "$output_file" 2>&1 &
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
    read -r editor_input_count editor_input_p50 editor_input_p95 editor_input_max \
        <<< "$(signpost_stats editor.input "$output_file")"
    read -r appmodel_relay_count appmodel_relay_p50 appmodel_relay_p95 appmodel_relay_max \
        <<< "$(signpost_stats appmodel.relay "$output_file")"
    read -r split_drag_count split_drag_p50 split_drag_p95 split_drag_max \
        <<< "$(signpost_stats split.drag "$output_file")"
    read -r search_everywhere_count search_everywhere_p50 search_everywhere_p95 search_everywhere_max \
        <<< "$(signpost_stats search.everywhere "$output_file")"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$scenario" "$fixture_label" "$run" "$ready_ms" "$ready_rss_kib" "$stable_rss_kib" \
        "$editor_input_count" "$editor_input_p50" "$editor_input_p95" "$editor_input_max" \
        "$appmodel_relay_count" "$appmodel_relay_p50" "$appmodel_relay_p95" "$appmodel_relay_max" \
        "$split_drag_count" "$split_drag_p50" "$split_drag_p95" "$split_drag_max" \
        "$search_everywhere_count" "$search_everywhere_p50" "$search_everywhere_p95" "$search_everywhere_max" \
        >> "$output_path"
    stable_samples+=("$stable_rss_kib")
    terminate_app
done

stable_median=$(median "${stable_samples[@]}")
print -r -- "median_stable_rss_kib=$stable_median scenario=$scenario fixture=$fixture_label runs=$runs report=$output_path"
