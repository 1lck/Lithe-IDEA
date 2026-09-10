#!/bin/zsh
set -euo pipefail
# Invoked only on the disposable GitHub runner. The workflow always removes
# this keychain, including when packaging or signing fails.
: "${RUNNER_TEMP:?}"
: "${GITHUB_ENV:?}"
: "${MACOS_SIGNING_CERTIFICATE:?Configure the Developer ID certificate secret}"
: "${MACOS_SIGNING_PASSWORD:?Configure the certificate password secret}"
: "${LITHE_CODESIGN_IDENTITY:?Configure the Developer ID Application identity}"
certificate="$RUNNER_TEMP/lithe-signing.p12"
keychain="$RUNNER_TEMP/lithe-signing.keychain-db"
password=$(openssl rand -base64 32)
trap 'rm -f "$certificate"' EXIT
print -rn -- "$MACOS_SIGNING_CERTIFICATE" | base64 --decode > "$certificate"
security create-keychain -p "$password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$password" "$keychain"
security import "$certificate" -P "$MACOS_SIGNING_PASSWORD" -A -t cert -f pkcs12 -k "$keychain"
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$password" "$keychain" >/dev/null
security list-keychains -d user -s "$keychain" login.keychain-db
print -r -- "LITHE_CODESIGN_IDENTITY=$LITHE_CODESIGN_IDENTITY" >> "$GITHUB_ENV"
