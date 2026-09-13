#!/bin/zsh
set -euo pipefail

if (( $# != 2 )); then
    print -u2 -- "Usage: $0 SOURCE_RESOURCES DESTINATION_RESOURCES"
    exit 2
fi

source_resources=${1:A}
destination_resources=${2:A}
if [[ "$source_resources" == "$destination_resources" ]]; then
    print -u2 -- "Localization packaging must not overwrite source resources"
    exit 2
fi

for localization in en.lproj zh-Hans.lproj; do
    if [[ ! -f "$source_resources/$localization/Localizable.strings" ]]; then
        print -u2 -- "Missing localization: $source_resources/$localization/Localizable.strings"
        exit 1
    fi
done

mkdir -p "$destination_resources"
for localization in en.lproj zh-Hans.lproj; do
    mkdir -p "$destination_resources/$localization"
    cp -R "$source_resources/$localization/" "$destination_resources/$localization/"
    # Explicit SwiftUI locales can reload string tables on every lookup. Binary
    # plists avoid reparsing the entire text table while preserving live language
    # switching. Compile only the bundle copy, before its caller signs the app.
    for table in "$destination_resources/$localization"/**/*.strings(N) \
                 "$destination_resources/$localization"/**/*.stringsdict(N); do
        /usr/bin/plutil -convert binary1 "$table"
    done
done
