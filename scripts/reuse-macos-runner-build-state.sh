#!/bin/zsh
# Keeps one self-hosted runner's SwiftPM and Cargo build outputs between jobs
# while removing every other untracked file left by the previous job.
#
# actions/checkout runs with clean: false on self-hosted runners, so this script
# owns the cleanup. Each runner has its own work directory: build state is never
# shared between runners, worktrees, or concurrent jobs. Decision record:
# .agents/notes/implemented/process/2026-09-13-ci-build-cache-and-artifact-strategy.md
set -euo pipefail

ROOT_DIR="${0:A:h:h}"
IDENTITY=""
LIMIT_GB=40
MIN_FREE_GB=25

while [[ $# -gt 0 ]]; do
    case "$1" in
        --identity) IDENTITY="$2"; shift 2 ;;
        --limit-gb) LIMIT_GB="$2"; shift 2 ;;
        --min-free-gb) MIN_FREE_GB="$2"; shift 2 ;;
        *) print -u2 -- "Unknown option: $1"; exit 2 ;;
    esac
done

if [[ -z "$IDENTITY" ]]; then
    print -u2 -- "--identity is required"
    exit 2
fi
for value in "$LIMIT_GB" "$MIN_FREE_GB"; do
    if [[ ! "$value" =~ '^[1-9][0-9]*$' ]]; then
        print -u2 -- "Size limits must be positive integers in GB"
        exit 2
    fi
done

cd "$ROOT_DIR"

# Compilation outputs are reused incrementally. The dependency stores are kept
# too; prepare-macos-dependency-cache still validates them before every use.
BUILD_STATE=(.build rust/target)
DEPENDENCY_STORES=(.artifacts/cargo-home .artifacts/swiftpm-cache .artifacts/jdtls-downloads .artifacts/jdk-downloads)
exclusions=()
for kept in "${BUILD_STATE[@]}" "${DEPENDENCY_STORES[@]}"; do
    exclusions+=(-e "/$kept")
done
# Stale untracked sources would otherwise be compiled by SwiftPM's target globs.
git clean -ffdxq "${exclusions[@]}"

discard_build_state() {
    print -- "Discarding runner build state: $1"
    rm -rf -- "${BUILD_STATE[@]}"
}

IDENTITY_FILE=".build/.lithe-runner-build-identity"
identity_hash="$(print -rn -- "$IDENTITY" | shasum -a 256 | cut -d ' ' -f 1)"
if [[ -d .build || -d rust/target ]]; then
    if [[ ! -f "$IDENTITY_FILE" ]]; then
        discard_build_state "no toolchain identity recorded"
    elif [[ "$(<"$IDENTITY_FILE")" != "$identity_hash" ]]; then
        discard_build_state "toolchain identity changed"
    fi
fi

kept_paths=()
for kept in "${BUILD_STATE[@]}" "${DEPENDENCY_STORES[@]}"; do
    [[ -e "$kept" ]] && kept_paths+=("$kept")
done
used_kb=0
if (( ${#kept_paths} > 0 )); then
    used_kb="$(du -sk "${kept_paths[@]}" | awk '{ total += $1 } END { print total + 0 }')"
fi
free_kb="$(df -Pk . | awk 'NR == 2 { print $4 }')"
if (( used_kb > LIMIT_GB * 1024 * 1024 )); then
    discard_build_state "$(( used_kb / 1024 / 1024 )) GB exceeds the ${LIMIT_GB} GB limit"
elif (( free_kb < MIN_FREE_GB * 1024 * 1024 )); then
    discard_build_state "only $(( free_kb / 1024 / 1024 )) GB of disk space is free"
fi

mkdir -p .build
print -rn -- "$identity_hash" > "$IDENTITY_FILE"
print -- "Runner build state: $(( used_kb / 1024 )) MB kept before this job, $(( free_kb / 1024 / 1024 )) GB free"
