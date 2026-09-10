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
ditto "dist/Lithe-$LITHE_ARCH.app" "$temporary/bundle/Lithe.app"
ditto -c -k --sequesterRsrc --keepParent "$temporary/bundle/Lithe.app" "$archives/$archive"

# Only prior stable Sparkle releases are baselines. Missing history is normal
# for the bootstrap release; an API or download failure must fail publication.
gh api "repos/$GITHUB_REPOSITORY/releases?per_page=100" > "$temporary/releases.json"
ruby scripts/select-sparkle-baselines.rb "$temporary/releases.json" "$LITHE_VERSION" "$LITHE_ARCH" > "$temporary/baselines"
while IFS=$'\t' read -r tag name; do
    [[ -n "$tag" ]] || continue
    gh release download "$tag" --repo "$GITHUB_REPOSITORY" --pattern "$name" --dir "$archives"
done < "$temporary/baselines"

print -r -- "$LITHE_SPARKLE_PRIVATE_KEY" | "$tools/generate_appcast" \
    --ed-key-file - --versions "$LITHE_BUILD_NUMBER" \
    --maximum-versions 1 --maximum-deltas 3 \
    --download-url-prefix "https://github.com/$GITHUB_REPOSITORY/releases/download/v$LITHE_VERSION/" \
    --link "https://github.com/$GITHUB_REPOSITORY/releases/tag/v$LITHE_VERSION" \
    -o "$archives/appcast-$LITHE_ARCH.xml" "$archives"
ruby scripts/name-sparkle-deltas.rb "$archives/appcast-$LITHE_ARCH.xml" "$LITHE_ARCH"
print -r -- "$LITHE_SPARKLE_PRIVATE_KEY" | "$tools/sign_update" \
    --ed-key-file - "$archives/appcast-$LITHE_ARCH.xml"
mkdir -p "dist/sparkle-$LITHE_ARCH"
cp "$archives/$archive" "$archives/appcast-$LITHE_ARCH.xml" "dist/sparkle-$LITHE_ARCH/"
for delta in "$archives"/*.delta(N); do
    cp "$delta" "dist/sparkle-$LITHE_ARCH/"
done
ruby scripts/verify-sparkle-appcast.rb "dist/sparkle-$LITHE_ARCH/appcast-$LITHE_ARCH.xml" "$LITHE_BUILD_NUMBER"
