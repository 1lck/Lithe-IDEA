#!/usr/bin/env bash
# Publishes the Desktop AutoBuild packages in DIR to the rolling prerelease RELEASE_TAG:
#
#   publish-autobuild.sh <dir>
#
# The environment names the build: GH_TOKEN, GITHUB_REPOSITORY, RELEASE_TAG, SOURCE_SHA,
# SOURCE_BRANCH, DESKTOP_VERSION, BUILD_NUMBER and BUILD_TIMESTAMP (ISO 8601 UTC, ending in Z);
# MACOS_SIGNED and WINDOWS_SIGNED (true or false) say whether the packages were signed.
#
# The release keeps only the latest build. Every file in DIR is uploaded over the asset of the same
# name, the tag moves to SOURCE_SHA, the title and notes describe this build, and assets this build
# did not produce (a previous version's packages, for example) are deleted. The release stays a
# prerelease that is never marked latest, so updaters reading the latest release never see it.
set -euo pipefail

if [[ $# -ne 1 || ! -d "$1" ]]; then
    printf '%s\n' "Usage: $0 <directory of packages>" >&2
    exit 2
fi
DIR="$1"
for name in GH_TOKEN GITHUB_REPOSITORY RELEASE_TAG SOURCE_SHA SOURCE_BRANCH DESKTOP_VERSION BUILD_NUMBER BUILD_TIMESTAMP; do
    if [[ -z "${!name:-}" ]]; then
        printf '%s\n' "$name is not set." >&2
        exit 2
    fi
done

FILES=()
NAMES=()
for path in "$DIR"/*; do
    if [[ -f "$path" ]]; then
        FILES+=("$path")
        NAMES+=("$(basename "$path")")
    fi
done
if [[ ${#FILES[@]} -eq 0 ]]; then
    printf '%s\n' "$DIR holds no packages to publish." >&2
    exit 1
fi

# The workflow reports whether the signing secrets exist; package-autobuild.sh signs exactly then.
# No notary credentials are configured, so the macOS package is never notarized.
if [[ "${MACOS_SIGNED:-false}" == true ]]; then
    MACOS_SIGNING_ZH='macOS 包已用 Developer ID 签名，但没有经过 Apple 公证。'
    MACOS_SIGNING_EN='The macOS package is signed with a Developer ID but is not notarized by Apple.'
else
    MACOS_SIGNING_ZH='macOS 包没有用 Developer ID 签名，也没有经过 Apple 公证。'
    MACOS_SIGNING_EN='The macOS package is not signed with a Developer ID and is not notarized by Apple.'
fi
if [[ "${WINDOWS_SIGNED:-false}" == true ]]; then
    WINDOWS_SIGNING_ZH='Windows 安装程序和程序已签名。'
    WINDOWS_SIGNING_EN='The Windows installer and program are signed.'
else
    WINDOWS_SIGNING_ZH='Windows 安装程序和程序没有签名。'
    WINDOWS_SIGNING_EN='The Windows installer and program are not signed.'
fi

SERVER_URL="${GITHUB_SERVER_URL:-https://github.com}"
COMMIT_URL="$SERVER_URL/$GITHUB_REPOSITORY/commit/$SOURCE_SHA"
SHORT_SHA="${SOURCE_SHA:0:12}"
BUILT_AT="${BUILD_TIMESTAMP/T/ }"
BUILT_AT="${BUILT_AT%Z} UTC"
TITLE="Lithe Desktop AutoBuild — 构建自 $BUILT_AT"
V="$DESKTOP_VERSION"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf -- "$WORK_DIR"' EXIT
NOTES="$WORK_DIR/notes.md"
# The Chinese text quotes button names with “ ”, which are prose, not shell quotes.
# shellcheck disable=SC1111
cat > "$NOTES" <<EOF
> [!WARNING]
> 这是从 \`$SOURCE_BRANCH\` 分支自动构建的测试版本，没有经过测试和人工验证，可能有未完成的功能或严重问题，请不要用于重要工作。日常使用请下载正式版本。
>
> This is an automatic build of the \`$SOURCE_BRANCH\` branch. It has not been tested or reviewed and may contain unfinished features or serious bugs, so do not use it for important work. For everyday use, download a stable release.

## 中文

这是 Lithe Desktop 的最新自动构建。这个发布只保留最新一次构建，每次构建都会替换全部下载文件。

- 源码：\`$SOURCE_BRANCH\` 分支，提交 [\`$SHORT_SHA\`]($COMMIT_URL)
- 版本：$V，构建号 $BUILD_NUMBER
- 构建时间：$BUILT_AT

### 下载

- macOS（Apple 芯片）：\`lithe-$V-darwin-arm64.dmg\`，或 \`lithe-$V-darwin-arm64.zip\`
- Windows x64：安装程序 \`lithe-$V-windows-amd64-setup.exe\`，或免安装的 \`lithe-$V-windows-amd64.zip\`
- Linux x64：\`lithe_${V}_amd64.deb\`，或 \`lithe-$V-linux-amd64.tar.gz\`
- Linux ARM64：\`lithe_${V}_arm64.deb\`，或 \`lithe-$V-linux-arm64.tar.gz\`

每个文件都有同名的 \`.sha256\` 校验文件。

### 注意事项

- macOS 只提供 Apple 芯片版本，不提供 Intel 版本。
- 自动构建不会自动更新，需要新构建时请重新下载。
- $MACOS_SIGNING_ZH如果 macOS 提示无法打开 Lithe Desktop.app，请在“应用程序”中按住 Control 点按应用并选择“打开”；如果仍被阻止，可在终端执行 \`xattr -dr com.apple.quarantine "/Applications/Lithe Desktop.app"\`。仅对可信来源的应用使用。
- $WINDOWS_SIGNING_ZH显示 SmartScreen 提示时，确认来源可信后选择“更多信息”，再选择“仍要运行”。

---

## English

This is the latest automatic build of Lithe Desktop. The release keeps only the latest build, and every build replaces all of its downloads.

- Source: the \`$SOURCE_BRANCH\` branch at commit [\`$SHORT_SHA\`]($COMMIT_URL)
- Version: $V, build $BUILD_NUMBER
- Built: $BUILT_AT

### Downloads

- macOS (Apple silicon): \`lithe-$V-darwin-arm64.dmg\`, or \`lithe-$V-darwin-arm64.zip\`
- Windows x64: the installer \`lithe-$V-windows-amd64-setup.exe\`, or the portable \`lithe-$V-windows-amd64.zip\`
- Linux x64: \`lithe_${V}_amd64.deb\`, or \`lithe-$V-linux-amd64.tar.gz\`
- Linux ARM64: \`lithe_${V}_arm64.deb\`, or \`lithe-$V-linux-arm64.tar.gz\`

Every file has a \`.sha256\` checksum file of the same name.

### Notes

- macOS builds are for Apple silicon only; there is no Intel build.
- AutoBuild does not update itself; download again to get a newer build.
- $MACOS_SIGNING_EN If macOS says it cannot open Lithe Desktop.app, Control-click it in Applications and choose Open. If it is still blocked, run \`xattr -dr com.apple.quarantine "/Applications/Lithe Desktop.app"\` in Terminal. Use this only for an app from a source you trust.
- $WINDOWS_SIGNING_EN If Windows shows a SmartScreen prompt, confirm that the source is trusted, choose More info, then choose Run anyway.
EOF

if ! gh release view "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --json tagName >/dev/null 2>&1; then
    # --target only applies when the tag does not exist yet; the ref update below moves an existing one.
    gh release create "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --target "$SOURCE_SHA" \
        --prerelease --latest=false --title "$TITLE" --notes-file "$NOTES"
fi

gh release upload "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --clobber "${FILES[@]}"
gh api --method PATCH "repos/$GITHUB_REPOSITORY/git/refs/tags/$RELEASE_TAG" \
    -f sha="$SOURCE_SHA" -F force=true >/dev/null
gh release edit "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" \
    --title "$TITLE" --notes-file "$NOTES" --prerelease --latest=false --draft=false >/dev/null

CURRENT="$(printf '%s\n' "${NAMES[@]}")"
while IFS= read -r asset; do
    if [[ -n "$asset" ]] && ! grep -Fxq -- "$asset" <<<"$CURRENT"; then
        printf '%s\n' "Deleting $asset, which this build did not produce."
        gh release delete-asset "$RELEASE_TAG" "$asset" --repo "$GITHUB_REPOSITORY" --yes
    fi
done < <(gh release view "$RELEASE_TAG" --repo "$GITHUB_REPOSITORY" --json assets --jq '.assets[].name')

printf '%s\n' "Published ${#FILES[@]} files to $SERVER_URL/$GITHUB_REPOSITORY/releases/tag/$RELEASE_TAG"
