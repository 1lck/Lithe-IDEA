#!/bin/zsh
set -euo pipefail

ROOT_DIR="${0:A:h:h}"

if (( $# != 1 )); then
    print -u2 -- "Usage: $0 path/to/Info.plist"
    exit 2
fi

info_plist="$1"
if [[ ! -f "$info_plist" ]]; then
    print -u2 -- "Missing app Info.plist: $info_plist"
    exit 1
fi

cd "$ROOT_DIR"

revision="${LITHE_BUILD_GIT_REVISION:-}"
if [[ -z "$revision" ]]; then
    revision=$(git rev-parse --verify HEAD 2>/dev/null || true)
fi
[[ -n "$revision" ]] || revision="unknown"

branch="${LITHE_BUILD_GIT_BRANCH:-${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-}}}"
if [[ -z "$branch" ]]; then
    branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)
fi
[[ -n "$branch" ]] || branch="detached"

dirty="${LITHE_BUILD_GIT_DIRTY:-}"
if [[ -z "$dirty" ]]; then
    if git rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        && [[ -n "$(git status --porcelain --untracked-files=normal)" ]]; then
        dirty="true"
    else
        dirty="false"
    fi
fi
if [[ "$dirty" != "true" && "$dirty" != "false" ]]; then
    print -u2 -- "LITHE_BUILD_GIT_DIRTY must be true or false"
    exit 2
fi

build_timestamp="${LITHE_BUILD_TIMESTAMP:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}"

set_plist_value() {
    local key="$1"
    local type="$2"
    local value="$3"

    if /usr/libexec/PlistBuddy -c "Print :$key" "$info_plist" >/dev/null 2>&1; then
        /usr/libexec/PlistBuddy -c "Set :$key $value" "$info_plist"
    else
        /usr/libexec/PlistBuddy -c "Add :$key $type $value" "$info_plist"
    fi
}

set_plist_value LitheBuildGitRevision string "$revision"
set_plist_value LitheBuildGitBranch string "$branch"
set_plist_value LitheBuildGitDirty bool "$dirty"
set_plist_value LitheBuildTimestamp string "$build_timestamp"

display_revision="$revision"
if (( ${#display_revision} > 12 )); then
    display_revision="${display_revision[1,12]}"
fi
print -u2 -- "Lithe build source: $ROOT_DIR"
print -u2 -- "Lithe build identity: revision=$display_revision branch=$branch dirty=$dirty timestamp=$build_timestamp"
