#!/bin/zsh
set -euo pipefail
plist="${1:?Usage: configure-sparkle-app.sh Info.plist architecture}"
architecture="${2:?}"
channel="${LITHE_UPDATE_CHANNEL:-stable}"
# Older callers use preview; the published channel is now named AutoBuild.
[[ "$channel" == preview ]] && channel=autobuild
[[ "$channel" == stable || "$channel" == autobuild ]] || { print -u2 -- "Invalid update channel"; exit 1; }
repository="${GITHUB_REPOSITORY:-1lck/Lithe-IDEA}"
stable_release_url="https://github.com/$repository/releases/latest"
autobuild_release_url="https://github.com/$repository/releases/tag/AutoBuild"
autobuild_feed_url="https://github.com/$repository/releases/download/AutoBuild/appcast-preview-$architecture.xml"
if [[ "$channel" == autobuild ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleName Lithe-Dev" "$plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Lithe-Dev" "$plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier app.lithe.desktop.dev" "$plist"
    release_url="$autobuild_release_url"
    feed_url="$autobuild_feed_url"
else
    release_url="$stable_release_url"
    feed_url="$release_url/download/appcast-$architecture.xml"
fi
/usr/libexec/PlistBuddy -c "Add :LitheUpdateChannel string $channel" "$plist"
/usr/libexec/PlistBuddy -c "Add :SUDefaultsDomain string app.lithe.desktop.sparkle.$channel" "$plist"
/usr/libexec/PlistBuddy -c "Add :LitheUpdateReleaseURL string $release_url" "$plist"
/usr/libexec/PlistBuddy -c "Add :LitheStableReleaseURL string $stable_release_url" "$plist"
/usr/libexec/PlistBuddy -c "Add :LitheStableFeedURL string $stable_release_url/download/appcast-$architecture.xml" "$plist"
/usr/libexec/PlistBuddy -c "Add :LitheAutoBuildReleaseURL string $autobuild_release_url" "$plist"
/usr/libexec/PlistBuddy -c "Add :LitheAutoBuildFeedURL string $autobuild_feed_url" "$plist"
if [[ -n "${LITHE_SPARKLE_PUBLIC_KEY:-}" ]]; then
    [[ "$architecture" == arm64 || "$architecture" == x86_64 ]] || { print -u2 -- "Sparkle feeds require an architecture-specific app"; exit 1; }
    /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $LITHE_SPARKLE_PUBLIC_KEY" "$plist"
    /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $feed_url" "$plist"
fi
