#!/bin/bash
set -euo pipefail
: "${GITHUB_REPOSITORY:?}"
: "${RELEASE_TAG:?}"
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
release_id=$(gh api "repos/$GITHUB_REPOSITORY/releases/tags/$RELEASE_TAG" --jq .id)
gh api --paginate --slurp "repos/$GITHUB_REPOSITORY/releases/$release_id/assets?per_page=100" > "$temporary/assets.json"
ruby -rjson -e 'puts JSON.parse(File.read(ARGV[0])).flatten(1).map { |a| a.fetch("name") }.select { |n| n.match?(/\Aappcast-preview-(arm64|x86_64)\.xml\z/) }' "$temporary/assets.json" > "$temporary/feeds"
feeds=(dist/sparkle-arm64/appcast-preview-arm64.xml dist/sparkle-x86_64/appcast-preview-x86_64.xml)
while IFS= read -r name; do
    gh release download "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --pattern "$name" --dir "$temporary"
    feeds+=("$temporary/$name")
done < "$temporary/feeds"
ruby -rjson -e 'puts JSON.generate(Dir.glob("dist/sparkle-*/*").map { |p| File.basename(p) } + Dir.glob("dist/*.dmg*").map { |p| File.basename(p) })' > "$temporary/incoming.json"
ruby scripts/preview-asset-retention.rb "$temporary/assets.json" "$temporary/incoming.json" "${feeds[@]}" > "$temporary/delete-ids"
while IFS= read -r asset_id; do
    gh api --method DELETE "repos/$GITHUB_REPOSITORY/releases/assets/$asset_id"
done < "$temporary/delete-ids"
