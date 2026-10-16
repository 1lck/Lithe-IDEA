#!/bin/zsh
set -euo pipefail
# Exit 3 only for a different installed identity; malformed archives are errors.
archive="${1:?Usage: verify-sparkle-baseline.sh archive app-name bundle-id}"
app_name="${2:?}"
bundle_id="${3:?}"
[[ "$app_name" == Lithe || "$app_name" == Lithe-Dev ]] || exit 2
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT
unzip -Z -1 "$archive" > "$temporary/entries"
grep -Fxq "$app_name.app/Contents/Info.plist" "$temporary/entries" || exit 3
unzip -p "$archive" "$app_name.app/Contents/Info.plist" > "$temporary/Info.plist"
actual_id=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$temporary/Info.plist")
[[ "$actual_id" == "$bundle_id" ]] || exit 3
