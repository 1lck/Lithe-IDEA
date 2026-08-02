#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"
mkdir -p .build

swiftc \
  Sources/Lithe/Models/GitModels.swift \
  Sources/Lithe/Models/GitGraphModels.swift \
  Sources/Lithe/Services/GitGraphLayoutService.swift \
  scripts/GitGraphVerification.swift \
  -o .build/git-graph-verification

./.build/git-graph-verification

FIXTURE_DIR="$(scripts/create-git-graph-fixture.sh)"
MERGE_LINE="$(git -C "$FIXTURE_DIR" log --all --merges --format='%H %P' -1)"
MERGE_PARENT_COUNT="$(print -r -- "$MERGE_LINE" | awk '{ print NF - 1 }')"

if (( MERGE_PARENT_COUNT < 2 )); then
  print -u2 -r -- "GitGraph fixture verification failed: merge commit has fewer than two parents"
  exit 1
fi

git -C "$FIXTURE_DIR" show-ref --verify --quiet refs/heads/feature/orders
git -C "$FIXTURE_DIR" show-ref --verify --quiet refs/remotes/origin/main
git -C "$FIXTURE_DIR" show-ref --verify --quiet refs/tags/v0.1.0

print -r -- "GitGraph fixture verification passed: merge parents, rebased branch, remote ref, and tag"
