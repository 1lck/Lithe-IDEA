#!/bin/zsh
set -euo pipefail
# Exit 3 only for a different installed identity; malformed archives are errors.
archive="${1:?Usage: verify-sparkle-baseline.sh archive app-name bundle-id}"
app_name="${2:?}"
bundle_id="${3:?}"
[[ "$app_name" == Lithe || "$app_name" == Lithe-Dev ]] || exit 2
temporary=$(mktemp -d)
trap 'rm -rf -- "$temporary"' EXIT
unzip -Z -1 "$archive" > "$temporary/entries" || exit 1
unzip -tqq "$archive" > /dev/null || exit 1
metadata_path=""
for candidate in Lithe Lithe-Dev; do
    if grep -Fxq "$candidate.app/Contents/Info.plist" "$temporary/entries"; then
        [[ -z "$metadata_path" ]] || { print -u2 -- "Ambiguous baseline application metadata"; exit 1; }
        metadata_path="$candidate.app/Contents/Info.plist"
    fi
done
[[ -n "$metadata_path" ]] || { print -u2 -- "Missing baseline application metadata"; exit 1; }
unzip -p "$archive" "$metadata_path" > "$temporary/Info.plist" || exit 1
actual_name=$(plutil -extract CFBundleName raw -expect string -o - "$temporary/Info.plist") || exit 1
actual_id=$(plutil -extract CFBundleIdentifier raw -expect string -o - "$temporary/Info.plist") || exit 1
[[ -n "$actual_id" && "$actual_name.app/Contents/Info.plist" == "$metadata_path" ]] || {
    print -u2 -- "Invalid baseline application identity"; exit 1
}
# Only a successfully decoded, internally consistent application can be skipped.
[[ "$actual_name" == "$app_name" && "$actual_id" == "$bundle_id" ]] || exit 3
