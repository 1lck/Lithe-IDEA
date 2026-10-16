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
[[ "$channel" == autobuild ]] && channel=preview
if [[ "$channel" == preview ]]; then
    : "${LITHE_PREVIEW_TAG:?}"
    [[ "$LITHE_PREVIEW_TAG" == AutoBuild ]] || { print -u2 -- "AutoBuild requires the fixed AutoBuild tag"; exit 1; }
    ruby scripts/autobuild-identity.rb --identity "$LITHE_BUILD_NUMBER" "${LITHE_BUILD_TIMESTAMP:?}"
    archive="Lithe-preview-$LITHE_BUILD_NUMBER-$LITHE_ARCH.zip"
    release_tag="$LITHE_PREVIEW_TAG"
    feed_name="appcast-preview-$LITHE_ARCH.xml"
elif [[ "$channel" != stable ]]; then
    print -u2 -- "Invalid update channel"; exit 1
fi
app_name=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleName' "dist/Lithe-$LITHE_ARCH.app/Contents/Info.plist")
[[ "$app_name" == Lithe || "$app_name" == Lithe-Dev ]] || { print -u2 -- "Unsupported app name: $app_name"; exit 1; }
ditto "dist/Lithe-$LITHE_ARCH.app" "$temporary/bundle/$app_name.app"
ditto -c -k --sequesterRsrc --keepParent "$temporary/bundle/$app_name.app" "$archives/$archive"

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
    node scripts/download-sparkle-baseline.mjs "$GITHUB_REPOSITORY" "$tag" "$name" "$archives"
    bundle_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "dist/Lithe-$LITHE_ARCH.app/Contents/Info.plist")
    if zsh scripts/verify-sparkle-baseline.sh "$archives/$name" "$app_name" "$bundle_id"; then
        :
    else
        baseline_status=$?
        (( baseline_status == 3 )) || exit "$baseline_status"
        # Pre-isolation AutoBuild belongs to another app. Its first migration is
        # a separate full installation, never a delta or in-place identity change.
        [[ "$name" == "${name:t}" && "$name" == *.zip ]] || exit 2
        print -u2 -- "Skipping baseline with a different installed identity: $name"
        rm -- "$archives/$name"
    fi
done < "$temporary/baselines"

if [[ "$channel" == stable ]]; then
    # Keep legacy DMGs while authenticating full-package rollback with the same
    # publisher key used for Sparkle archives. Only the public signature is saved.
    print -r -- "$LITHE_SPARKLE_PRIVATE_KEY" | "$tools/sign_update" --ed-key-file - -p \
        "dist/Lithe-$LITHE_VERSION-$LITHE_ARCH.dmg" > "dist/Lithe-$LITHE_VERSION-$LITHE_ARCH.dmg.edsig"
    notes="docs/releases/v$LITHE_VERSION.md"
    test -s "$notes" || { print -u2 -- "Missing release notes: $notes"; exit 1; }
    # The native details view consumes plain text, not rendered HTML.
    cp "$notes" "$archives/${archive%.zip}.txt"
fi
print -r -- "$LITHE_SPARKLE_PRIVATE_KEY" | "$tools/generate_appcast" \
    --embed-release-notes \
    --ed-key-file - --versions "$LITHE_BUILD_NUMBER" \
    --maximum-versions 1 --maximum-deltas 3 \
    --download-url-prefix "https://github.com/$GITHUB_REPOSITORY/releases/download/$release_tag/" \
    --link "https://github.com/$GITHUB_REPOSITORY/releases/tag/$release_tag" \
    -o "$archives/$feed_name" "$archives"
ruby scripts/name-sparkle-deltas.rb "$archives/$feed_name" "$LITHE_ARCH"
if [[ "$channel" == preview ]]; then
    ruby scripts/set-preview-appcast-date.rb "$archives/$feed_name" "${LITHE_BUILD_TIMESTAMP:?}" "$LITHE_BUILD_NUMBER"
fi
print -r -- "$LITHE_SPARKLE_PRIVATE_KEY" | "$tools/sign_update" \
    --ed-key-file - "$archives/$feed_name"
mkdir -p "dist/sparkle-$LITHE_ARCH"
cp "$archives/$archive" "$archives/$feed_name" "dist/sparkle-$LITHE_ARCH/"
for delta in "$archives"/*.delta(N); do
    cp "$delta" "dist/sparkle-$LITHE_ARCH/"
done
if [[ "$channel" == preview ]]; then
    ruby scripts/verify-sparkle-appcast.rb "dist/sparkle-$LITHE_ARCH/$feed_name" "$LITHE_BUILD_NUMBER" "$LITHE_BUILD_TIMESTAMP"
else
    ruby scripts/verify-sparkle-appcast.rb "dist/sparkle-$LITHE_ARCH/$feed_name" "$LITHE_BUILD_NUMBER"
fi
