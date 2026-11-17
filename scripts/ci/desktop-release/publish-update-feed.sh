#!/usr/bin/env bash
# Signs and publishes the stable update feed for the Desktop Release packages in DIR:
#
#   publish-update-feed.sh <dir>
#
# The environment names the release: GH_TOKEN, GITHUB_REPOSITORY, DESKTOP_VERSION and
# RELEASE_TAG (desktop-v<version>, whose release already holds the packages). VIVA_UPDATE_KEY is
# the feed's Ed25519 private key (base64); without it nothing is published, so a repository that
# has not made its keys yet still releases. Only this script, in its own job, is given the key.
#
# The clients read https://github.com/<repository>/releases/download/desktop-update-feed/
# stable.json and its .sig (desktop/internal/buildinfo/update.go). The feed lists this version's
# update archives where RELEASE_TAG serves them: the macOS zips, the Windows installer and zip
# and the Linux tar.gz. Beside it, stable.notes.md holds docs/releases/v<version>.md under the
# first line <!-- lithe-update-notes version=<version> -->, which the update dialog shows before
# the user decides to download; the notes are not signed, because the signed feed alone decides
# what gets installed.
#
# Delta updates are made, as Motty makes them, from the version the published feed offers: its
# zip or tar.gz for each platform is downloaded from that release, checked against the digest the
# feed lists and the release's .sha256, and handed to viva feed --patch-from, which writes the
# patches beside this version's archives; they are uploaded to RELEASE_TAG. Running again for the
# version the feed already offers rebuilds the same patches. A platform whose previous archive
# cannot be fetched or does not match gets no patch, nor does Windows from a version whose client
# cannot install one (WINDOWS_PATCH_FROM), and with no feed published yet there are no patches:
# users download the full package then. A feed that already offers a newer version is
# left as it is.
set -euo pipefail

if [[ $# -ne 1 || ! -d "$1" ]]; then
    printf '%s\n' "Usage: $0 <directory of packages>" >&2
    exit 2
fi
DIR="$1"
for name in GH_TOKEN GITHUB_REPOSITORY DESKTOP_VERSION RELEASE_TAG; do
    if [[ -z "${!name:-}" ]]; then
        printf '%s\n' "$name is not set." >&2
        exit 2
    fi
done
VERSION="$DESKTOP_VERSION"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    printf '%s\n' "DESKTOP_VERSION must be MAJOR.MINOR.PATCH, not $VERSION." >&2
    exit 2
fi
SUMMARY="${GITHUB_STEP_SUMMARY:-/dev/null}"

# The key goes to viva feed alone, not to gh, go or anything else this script starts.
SIGNING_KEY="${VIVA_UPDATE_KEY:-}"
unset VIVA_UPDATE_KEY
if [[ -z "$SIGNING_KEY" ]]; then
    printf '%s\n' 'VIVA_UPDATE_KEY is not set; the stable update feed is not published.' | tee -a "$SUMMARY"
    exit 0
fi

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
FEED_TAG="desktop-update-feed"
FEED_NAME="stable"
NOTES_SOURCE="$ROOT_DIR/docs/releases/v$VERSION.md"
if [[ ! -s "$NOTES_SOURCE" ]]; then
    printf '%s\n' "docs/releases/v$VERSION.md is missing; the update dialog shows it." >&2
    exit 1
fi
node "$ROOT_DIR/scripts/ci/common/desktop-packages.mjs" verify "$VERSION" "$DIR"

WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT
mkdir -p "$WORK/archives" "$WORK/previous" "$WORK/current" "$WORK/out"

digest() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d ' ' -f 1
    else
        shasum -a 256 "$1" | cut -d ' ' -f 1
    fi
}

# This version's update archives; the dmg, deb and rpm are not installed by the updater.
shopt -s nullglob
ARCHIVES=()
for path in "$DIR/lithe-$VERSION-darwin-"*.zip "$DIR/lithe-$VERSION-windows-"*-setup.exe \
    "$DIR/lithe-$VERSION-windows-"*.zip "$DIR/lithe-$VERSION-linux-"*.tar.gz; do
    cp -- "$path" "$WORK/archives/"
    ARCHIVES+=("$(basename "$path")")
done
shopt -u nullglob
if [[ ${#ARCHIVES[@]} -eq 0 ]]; then
    printf '%s\n' "$DIR holds no update archives of $VERSION." >&2
    exit 1
fi

# The feed published now, if any. An error other than a missing release fails the run rather
# than replacing a feed this run could not read.
FEED_RELEASE=false
CURRENT=""
if names="$(gh release view "$FEED_TAG" --repo "$GITHUB_REPOSITORY" --json assets --jq '.assets[].name' 2>"$WORK/view.err")"; then
    FEED_RELEASE=true
    if grep -qx "$FEED_NAME.json" <<< "$names"; then
        gh release download "$FEED_TAG" --repo "$GITHUB_REPOSITORY" --pattern "$FEED_NAME.json" --dir "$WORK/current"
        CURRENT="$WORK/current/$FEED_NAME.json"
    fi
elif ! grep -qi 'not found' "$WORK/view.err"; then
    cat "$WORK/view.err" >&2
    exit 1
fi

# Reads the published feed against VERSION: "newer <version>" when it offers a later one; else
# "base <version>" naming the version to patch from (empty for none), followed by one
# "digest <archive> <sha256>" line per archive the feed lists for that version.
read_feed() {
    node -e '
const fs = require("fs");
const [file, version, app] = process.argv.slice(1);
const feed = JSON.parse(fs.readFileSync(file, "utf8"));
const parse = (v) => {
  const m = /^(\d+)\.(\d+)\.(\d+)$/.exec(v || "");
  if (!m) throw new Error(`the published stable feed offers ${v}, not MAJOR.MINOR.PATCH`);
  return m.slice(1).map(Number);
};
if (feed.app !== app || feed.channel !== "stable") {
  throw new Error(`the published stable feed is for ${feed.app} ${feed.channel}, not ${app} stable`);
}
const latest = feed.latest || {};
const [a, b] = [parse(latest.version), parse(version)];
const order = a.findIndex((n, i) => n !== b[i]);
const assets = latest.assets || [];
if (order >= 0 && a[order] > b[order]) {
  console.log(`newer ${latest.version}`);
} else if (order >= 0) {
  console.log(`base ${latest.version}`);
  for (const asset of assets) console.log(`digest ${decodeURIComponent(asset.url.split("/").pop())} ${asset.sha256}`);
} else {
  const from = assets.flatMap((asset) => asset.patches || []).map((patch) => patch.from_version).find(Boolean);
  console.log(`base ${from || ""}`);
}
' "$CURRENT" "$VERSION" "$(sed -n 's/^id = "\([^"]*\)"$/\1/p' "$ROOT_DIR/desktop/viva.toml" | head -n 1)"
}

PREVIOUS=""
FEED_DIGESTS="$WORK/feed-digests"
: > "$FEED_DIGESTS"
if [[ -n "$CURRENT" ]]; then
    read_feed > "$WORK/feed-read"
    read -r kind found < <(head -n 1 "$WORK/feed-read") || true
    if [[ "$kind" == newer ]]; then
        printf '%s\n' "The stable update feed already offers $found, later than $VERSION; it is left as it is." | tee -a "$SUMMARY"
        exit 0
    fi
    PREVIOUS="${found:-}"
    sed -n 's/^digest //p' "$WORK/feed-read" > "$FEED_DIGESTS"
fi

# The first version whose Windows client installs a patch. Lithe 0.8.0 and 0.8.1 delete the
# application a patch rebuilt once they quit, before Viva's helper has read it, so a patch quits
# them without updating them (vivaui/viva#334); a client of those versions gets the full
# installer instead, which they install correctly. The version is the one the client runs, the
# version the published feed offers, so the rule applies for as long as anyone still runs them.
WINDOWS_PATCH_FROM="0.8.2"

# Succeeds when MAJOR.MINOR.PATCH $1 is earlier than $2.
version_before() {
    local -a a b
    local i
    IFS=. read -ra a <<< "$1"
    IFS=. read -ra b <<< "$2"
    for i in 0 1 2; do
        if ((a[i] != b[i])); then
            ((a[i] < b[i]))
            return
        fi
    done
    return 1
}

PATCH_ARGS=()
PATCHED=()
if [[ -n "$PREVIOUS" ]]; then
    for archive in "${ARCHIVES[@]}"; do
        if [[ ! "$archive" =~ ^"lithe-$VERSION-"(darwin|windows|linux)-(amd64|arm64)\.(zip|tar\.gz)$ ]]; then
            continue
        fi
        os="${BASH_REMATCH[1]}" arch="${BASH_REMATCH[2]}" ext="${BASH_REMATCH[3]}"
        if [[ "$os" == windows ]] && version_before "$PREVIOUS" "$WINDOWS_PATCH_FROM"; then
            printf '%s\n' "::notice::No delta update for $os/$arch from $PREVIOUS: its client cannot install a Windows patch, so it downloads the full installer."
            continue
        fi
        old="lithe-$PREVIOUS-$os-$arch.$ext"
        mkdir -p "$WORK/previous/$os-$arch"
        if ! gh release download "desktop-v$PREVIOUS" --repo "$GITHUB_REPOSITORY" --pattern "$old" \
            --pattern "$old.sha256" --dir "$WORK/previous/$os-$arch" >/dev/null 2>"$WORK/previous.err"; then
            printf '%s\n' "::warning::No delta update for $os/$arch: $old could not be downloaded from desktop-v$PREVIOUS ($(head -n 1 "$WORK/previous.err"))."
            continue
        fi
        actual="$(digest "$WORK/previous/$os-$arch/$old")"
        listed="$(cut -d ' ' -f 1 "$WORK/previous/$os-$arch/$old.sha256" 2>/dev/null || true)"
        fed="$(awk -v name="$old" '$1 == name { print $2 }' "$FEED_DIGESTS")"
        if [[ "$actual" != "$listed" || ( -s "$FEED_DIGESTS" && "$actual" != "$fed" ) ]]; then
            printf '%s\n' "::warning::No delta update for $os/$arch: $old from desktop-v$PREVIOUS does not match its published digest."
            continue
        fi
        PATCH_ARGS+=(-patch-from "$os/$arch=$PREVIOUS=$WORK/previous/$os-$arch/$old")
        PATCHED+=("$os/$arch")
    done
fi

VIVA_BIN="$("$ROOT_DIR/scripts/desktop/build-viva-tool.sh")"
VIVA_UPDATE_KEY="$SIGNING_KEY" "$VIVA_BIN" feed -C "$ROOT_DIR/desktop" -dir "$WORK/archives" \
    -out "$WORK/out/$FEED_NAME.json" -version "$VERSION" -channel stable \
    -base-url "https://github.com/$GITHUB_REPOSITORY/releases/download/$RELEASE_TAG" \
    -notes "https://github.com/$GITHUB_REPOSITORY/releases/tag/$RELEASE_TAG" \
    "${PATCH_ARGS[@]+"${PATCH_ARGS[@]}"}"
SIGNING_KEY=""
if [[ ! -s "$WORK/out/$FEED_NAME.json" || ! -s "$WORK/out/$FEED_NAME.json.sig" ]]; then
    printf '%s\n' "viva feed did not write $FEED_NAME.json and its signature." >&2
    exit 1
fi

# The patches go up before the feed that lists them.
shopt -s nullglob
PATCHES=("$WORK/archives/"*.patch)
shopt -u nullglob
if [[ ${#PATCHES[@]} -gt 0 ]]; then
    gh release upload "$RELEASE_TAG" "${PATCHES[@]}" --repo "$GITHUB_REPOSITORY" --clobber
fi

{
    printf '<!-- lithe-update-notes version=%s -->\n' "$VERSION"
    cat -- "$NOTES_SOURCE"
} > "$WORK/out/$FEED_NAME.notes.md"

if [[ "$FEED_RELEASE" != true ]]; then
    gh release create "$FEED_TAG" --repo "$GITHUB_REPOSITORY" --title "Lithe Desktop update feeds" \
        --notes "Lithe 桌面端的更新源，由 Desktop Release 和 Desktop AutoBuild 工作流维护，应用内更新读取这里的文件。请从各版本的 release 下载安装包。

The update feeds of Lithe Desktop, kept by the Desktop Release and Desktop AutoBuild workflows for the in-app updater. Download the packages from each version's release." \
        --prerelease --latest=false ${GITHUB_SHA:+--target "$GITHUB_SHA"} >/dev/null || \
        gh release view "$FEED_TAG" --repo "$GITHUB_REPOSITORY" >/dev/null
fi
# The notes go first: until the feed arrives they name a version no client is offered, which
# the dialog does not show.
gh release upload "$FEED_TAG" "$WORK/out/$FEED_NAME.notes.md" "$WORK/out/$FEED_NAME.json" \
    "$WORK/out/$FEED_NAME.json.sig" --repo "$GITHUB_REPOSITORY" --clobber

{
    printf '%s\n' "Published the stable update feed for $VERSION."
    if [[ ${#PATCHED[@]} -gt 0 ]]; then
        printf '%s\n' "Delta updates from $PREVIOUS: ${PATCHED[*]}."
    elif [[ -n "$PREVIOUS" ]]; then
        printf '%s\n' "No delta updates from $PREVIOUS: users download the full packages."
    else
        printf '%s\n' 'No earlier stable feed: users download the full packages.'
    fi
} | tee -a "$SUMMARY"
