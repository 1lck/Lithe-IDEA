#!/bin/zsh
set -euo pipefail
ROOT_DIR="${0:A:h:h}"
cd "$ROOT_DIR"
: "${LITHE_ARCH:?}"
: "${LITHE_VERSION:?}"
: "${LITHE_BUILD_NUMBER:?}"
: "${GITHUB_REPOSITORY:?}"
: "${LITHE_SPARKLE_PRIVATE_KEY:?}"
[[ "$LITHE_ARCH" == arm64 || "$LITHE_ARCH" == x86_64 ]] || exit 2
tools=$(zsh scripts/prepare-sparkle-tools.sh)
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
archives="$temporary/archives"
mkdir -p "$archives" "$temporary/bundle"
archive="Lithe-$LITHE_VERSION-$LITHE_ARCH.zip"
release_tag="v$LITHE_VERSION"
feed_name="appcast-$LITHE_ARCH.xml"
channel="${LITHE_UPDATE_CHANNEL:-stable}"
if [[ "$channel" == preview ]]; then
    : "${LITHE_PREVIEW_TAG:?}"
    archive="Lithe-preview-$LITHE_BUILD_NUMBER-$LITHE_ARCH.zip"
    release_tag="$LITHE_PREVIEW_TAG"
    feed_name="appcast-preview-$LITHE_ARCH.xml"
elif [[ "$channel" != stable ]]; then
    print -u2 -- "Invalid update channel"; exit 1
fi
ditto "dist/Lithe-$LITHE_ARCH.app" "$temporary/bundle/Lithe.app"
ditto -c -k --sequesterRsrc --keepParent "$temporary/bundle/Lithe.app" "$archives/$archive"

# Only prior Sparkle builds in the selected channel are baselines. Missing history is normal
# for the bootstrap release; an API or download failure must fail publication.
gh api --paginate --slurp "repos/$GITHUB_REPOSITORY/releases?per_page=100" > "$temporary/release-pages.json"
ruby -rjson -e 'puts JSON.generate(JSON.parse(File.read(ARGV[0])).flatten(1))' "$temporary/release-pages.json" > "$temporary/releases.json"
if [[ "$channel" == preview ]]; then
    ruby scripts/select-sparkle-baselines.rb "$temporary/releases.json" "$LITHE_BUILD_NUMBER" "$LITHE_ARCH" preview "$release_tag" > "$temporary/baselines"
else
    ruby scripts/select-sparkle-baselines.rb "$temporary/releases.json" "$LITHE_VERSION" "$LITHE_ARCH" > "$temporary/baselines"
fi
while IFS=$'\t' read -r tag name; do
    [[ -n "$tag" ]] || continue
    gh release download "$tag" --repo "$GITHUB_REPOSITORY" --pattern "$name" --dir "$archives"
done < "$temporary/baselines"

print -r -- "$LITHE_SPARKLE_PRIVATE_KEY" | "$tools/generate_appcast" \
    --ed-key-file - --versions "$LITHE_BUILD_NUMBER" \
    --maximum-versions 1 --maximum-deltas 3 \
    --download-url-prefix "https://github.com/$GITHUB_REPOSITORY/releases/download/$release_tag/" \
    --link "https://github.com/$GITHUB_REPOSITORY/releases/tag/$release_tag" \
    -o "$archives/$feed_name" "$archives"
ruby scripts/name-sparkle-deltas.rb "$archives/$feed_name" "$LITHE_ARCH"
print -r -- "$LITHE_SPARKLE_PRIVATE_KEY" | "$tools/sign_update" \
    --ed-key-file - "$archives/$feed_name"
mkdir -p "dist/sparkle-$LITHE_ARCH"
cp "$archives/$archive" "$archives/$feed_name" "dist/sparkle-$LITHE_ARCH/"
for delta in "$archives"/*.delta(N); do
    cp "$delta" "dist/sparkle-$LITHE_ARCH/"
done
ruby scripts/verify-sparkle-appcast.rb "dist/sparkle-$LITHE_ARCH/$feed_name" "$LITHE_BUILD_NUMBER"
