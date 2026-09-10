#!/bin/zsh
set -euo pipefail
plist="${1:?Usage: configure-sparkle-app.sh Info.plist architecture}"
architecture="${2:?}"
channel="${LITHE_UPDATE_CHANNEL:-stable}"
[[ "$channel" == stable || "$channel" == preview ]] || { print -u2 -- "Invalid update channel"; exit 1; }
repository="${GITHUB_REPOSITORY:-1lck/Lithe-IDEA}"
if [[ "$channel" == preview ]]; then
    : "${LITHE_PREVIEW_TAG:?Preview builds require a rolling release tag}"
    [[ "$LITHE_PREVIEW_TAG" == [a-zA-Z0-9]* && "$LITHE_PREVIEW_TAG" != *[^a-zA-Z0-9._-]* ]] || exit 1
    release_url="https://github.com/$repository/releases/tag/$LITHE_PREVIEW_TAG"
    feed_url="https://github.com/$repository/releases/download/$LITHE_PREVIEW_TAG/appcast-preview-$architecture.xml"
else
    release_url="https://github.com/$repository/releases/latest"
    feed_url="$release_url/download/appcast-$architecture.xml"
fi
/usr/libexec/PlistBuddy -c "Add :LitheUpdateChannel string $channel" "$plist"
/usr/libexec/PlistBuddy -c "Add :LitheUpdateReleaseURL string $release_url" "$plist"
if [[ -n "${LITHE_SPARKLE_PUBLIC_KEY:-}" ]]; then
    [[ "$architecture" == arm64 || "$architecture" == x86_64 ]] || { print -u2 -- "Sparkle feeds require an architecture-specific app"; exit 1; }
    /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $LITHE_SPARKLE_PUBLIC_KEY" "$plist"
    /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $feed_url" "$plist"
fi
