#!/usr/bin/env bash
# Resolves the version a Desktop Release run publishes and checks that the tree is ready for it:
#
#   resolve-release-version.sh <version or desktop-v tag>
#
# The version must be MAJOR.MINOR.PATCH, equal the [app] version of desktop/viva.toml (the
# version the package carries), and have stable release notes at docs/releases/desktop-v<version>.md.
# When GITHUB_OUTPUT is set, version and tag are written to it.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
if [[ $# -ne 1 ]]; then
    echo "Usage: $0 <version or desktop-v tag>" >&2
    exit 2
fi
version="${1#desktop-v}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "The release version must have the form MAJOR.MINOR.PATCH: $version" >&2
    exit 1
fi

manifest_version="$(sed -n 's/^version = "\([0-9.]*\)"$/\1/p' "$ROOT_DIR/desktop/viva.toml")"
if [[ "$manifest_version" != "$version" ]]; then
    echo "desktop/viva.toml has version \"$manifest_version\"; set it to \"$version\" before releasing $version." >&2
    exit 1
fi

tag="desktop-v$version"
node "$ROOT_DIR/scripts/release/notes/validate-stable-release-notes.mjs" "$ROOT_DIR/docs/releases/$tag.md"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    {
        echo "version=$version"
        echo "tag=$tag"
    } >> "$GITHUB_OUTPUT"
fi
echo "Desktop release $version ($tag)"
