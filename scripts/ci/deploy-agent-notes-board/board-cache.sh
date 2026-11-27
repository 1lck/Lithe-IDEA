#!/usr/bin/env bash
# Keeps the engineering board's GitHub cache between Pages runs on the data branch
# engineering-board-cache of this repository:
#
#   board-cache.sh restore   # before the build: copy github.json from the branch into the checkout
#   board-cache.sh save      # after the build: commit the checkout's github.json to the branch
#
# The board build reads and writes .artifacts/agent-notes-board/cache/github.json
# (scripts/agent-notes/engineering-board-github.mjs), one record per line in a stable order, so
# each commit on the branch stores only the records that changed. Without the branch, or when it
# cannot be read, restore leaves the cache alone and the build reads everything from GitHub. The
# branch holds only github.json and a README; nothing merges it, and deleting it makes the next
# run start from an empty cache. A push needs contents: write; main's ruleset does not cover the
# branch. BOARD_CACHE_REMOTE names the remote (default origin).
set -euo pipefail

if [[ $# -ne 1 || ( "$1" != restore && "$1" != save ) ]]; then
    printf '%s\n' "Usage: $0 restore|save" >&2
    exit 2
fi
ACTION="$1"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
CACHE="$ROOT_DIR/.artifacts/agent-notes-board/cache/github.json"
REMOTE="${BOARD_CACHE_REMOTE:-origin}"
BRANCH="engineering-board-cache"
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

git() { command git -C "$ROOT_DIR" "$@"; }
note() { printf '%s\n' "$1" | tee -a "$SUMMARY"; }

# Prints the branch's commit, or nothing when the branch does not exist yet. Fails when the
# remote cannot be asked.
remote_tip() {
    local refs
    refs="$(git ls-remote --heads "$REMOTE" "refs/heads/$BRANCH")" || return 1
    printf '%s' "${refs%%[[:space:]]*}"
}

# Makes the branch's commit available locally without fetching its history.
fetch_tip() {
    git cat-file -e "$1^{commit}" 2>/dev/null \
        || git fetch --quiet --no-tags --depth=1 "$REMOTE" "refs/heads/$BRANCH"
}

restore() {
    local tip
    if ! tip="$(remote_tip)" || { [[ -n "$tip" ]] && ! fetch_tip "$tip"; }; then
        note "Could not read $BRANCH from $REMOTE; the board reads everything from GitHub this time."
        return 0
    fi
    if [[ -z "$tip" ]]; then
        note "$BRANCH does not exist yet; the board reads everything from GitHub this time."
        return 0
    fi
    mkdir -p "$(dirname "$CACHE")"
    local temp="$CACHE.restore.$$"
    if ! git show "$tip:github.json" > "$temp"; then
        rm -f "$temp"
        note "$BRANCH ${tip:0:12} has no github.json; the board reads everything from GitHub this time."
        return 0
    fi
    mv "$temp" "$CACHE"
    note "Restored the board cache from $BRANCH ${tip:0:12} ($(wc -c < "$CACHE" | tr -d ' ') bytes)."
}

readme() {
    cat <<'EOF'
# engineering-board-cache

这个分支只保存工程看板的 GitHub 增量缓存 `github.json`，由 Deploy Agent Notes Board 工作流在每次运行后写入，下次运行先读它，再只向 GitHub 读取变化的记录。

- 不要手动修改，也不要合并到 `main`。
- 删除这个分支后，下一次运行从空缓存全量读取并重新创建它。
- 格式和读写规则见 `scripts/agent-notes/engineering-board-github.mjs` 与 `scripts/ci/deploy-agent-notes-board/board-cache.sh`。

This branch only holds the engineering board's GitHub cache. The Pages workflow writes it; do not edit or merge it. Deleting it makes the next run read everything from GitHub.
EOF
}

save() {
    if [[ ! -s "$CACHE" ]]; then
        printf '%s\n' "$CACHE does not exist; build the board before saving its cache." >&2
        return 1
    fi
    local tip
    tip="$(remote_tip)"
    if [[ -n "$tip" ]]; then
        fetch_tip "$tip"
    fi
    local data readme_blob tree
    data="$(git hash-object -w -- "$CACHE")"
    readme_blob="$(readme | git hash-object -w --stdin)"
    tree="$(printf '100644 blob %s\tREADME.md\n100644 blob %s\tgithub.json\n' "$readme_blob" "$data" | git mktree)"
    if [[ -n "$tip" && "$(git rev-parse "$tip^{tree}")" == "$tree" ]]; then
        note "The board cache is unchanged; $BRANCH stays at ${tip:0:12}."
        return 0
    fi

    local fetched source message commit
    fetched="$(head -c 4096 "$CACHE" | grep -o '"fetchedAt":"[^"]*"' | head -n 1 | cut -d '"' -f 4 || true)"
    source="${GITHUB_SHA:-$(git rev-parse HEAD)}"
    message="Update engineering board cache"$'\n\n'"Fetched from GitHub at ${fetched:-unknown time}; board built from ${source}."
    if [[ -n "${GITHUB_SERVER_URL:-}" && -n "${GITHUB_REPOSITORY:-}" && -n "${GITHUB_RUN_ID:-}" ]]; then
        message+=$'\n'"Run: $GITHUB_SERVER_URL/$GITHUB_REPOSITORY/actions/runs/$GITHUB_RUN_ID"
    fi
    local parents=()
    if [[ -n "$tip" ]]; then
        parents=(-p "$tip")
    fi
    commit="$(GIT_AUTHOR_NAME='github-actions[bot]' \
        GIT_AUTHOR_EMAIL='41898282+github-actions[bot]@users.noreply.github.com' \
        GIT_COMMITTER_NAME='github-actions[bot]' \
        GIT_COMMITTER_EMAIL='41898282+github-actions[bot]@users.noreply.github.com' \
        git commit-tree "$tree" ${parents[@]+"${parents[@]}"} -m "$message")"
    # Not forced: a run that lost a race to another one fails here instead of dropping its commit.
    git push --quiet "$REMOTE" "$commit:refs/heads/$BRANCH"
    note "Saved the board cache to $BRANCH ${commit:0:12} ($(wc -c < "$CACHE" | tr -d ' ') bytes)."
}

"$ACTION"
