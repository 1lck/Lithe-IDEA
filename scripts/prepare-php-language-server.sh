#!/bin/zsh

set -euo pipefail

ROOT_DIR="${0:A:h:h}"
MANIFEST="$ROOT_DIR/Plugins/mac/Official/PhpSupport/language-server.json"
OUTPUT_DIR=""
CACHE_DIR="${LITHE_PHP_LANGUAGE_SERVER_CACHE:-$ROOT_DIR/.artifacts/php-language-server-downloads}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --manifest) MANIFEST="$2"; shift 2 ;;
        --output) OUTPUT_DIR="$2"; shift 2 ;;
        --cache) CACHE_DIR="$2"; shift 2 ;;
        *) print -u2 -- "Usage: $0 [--manifest path] --output directory [--cache directory]"; exit 2 ;;
    esac
done

[[ -f "$MANIFEST" ]] || { print -u2 -- "PHP language-server manifest was not found: $MANIFEST"; exit 1; }
[[ -n "$OUTPUT_DIR" ]] || { print -u2 -- "PHP language-server output directory is required"; exit 2; }

manifest_value() {
    /usr/bin/plutil -extract "$1" raw -o - "$MANIFEST"
}

archive_url="$(manifest_value archiveURL)"
archive_sha256="$(manifest_value archiveSHA256)"
archive_format="$(manifest_value archiveFormat)"
archive_root="$(manifest_value archiveRoot)"
entrypoint="$(manifest_value entrypoint)"
license_path="$(manifest_value license)"

[[ "$archive_format" == "tarGzip" ]] || {
    print -u2 -- "Unsupported PHP language-server archive format: $archive_format"
    exit 1
}
[[ "$archive_url" == https://* ]] || { print -u2 -- "PHP language-server archive URL must use HTTPS"; exit 1; }
print -r -- "$archive_sha256" | /usr/bin/grep -Eq '^[0-9A-Fa-f]{64}$' || {
    print -u2 -- "PHP language-server checksum must be a 64-character SHA-256 value"
    exit 1
}

file_sha256() {
    shasum -a 256 "$1" | awk '{print tolower($1)}'
}

download_verified_file() {
    local url="$1"
    local expected_sha256="$2"
    local destination="$3"
    local description="$4"
    local temporary_path="$destination.download.$$"
    local actual_sha256

    if [[ -f "$destination" ]]; then
        actual_sha256="$(file_sha256 "$destination")"
        if [[ "$actual_sha256" == "$expected_sha256" ]]; then
            return 0
        fi
        rm -f -- "$destination"
    fi

    rm -f -- "$temporary_path"
    print -u2 -- "Downloading $description: $url"
    if ! curl \
        --fail \
        --location \
        --retry 3 \
        --retry-all-errors \
        --connect-timeout 15 \
        --max-time 300 \
        --output "$temporary_path" \
        "$url"; then
        rm -f -- "$temporary_path"
        return 1
    fi
    actual_sha256="$(file_sha256 "$temporary_path")"
    if [[ "$actual_sha256" != "$expected_sha256" ]]; then
        print -u2 -- "$description checksum mismatch: expected $expected_sha256, got $actual_sha256"
        rm -f -- "$temporary_path"
        return 1
    fi
    mv -f -- "$temporary_path" "$destination"
}

mkdir -p -- "$CACHE_DIR"
archive_path="$CACHE_DIR/intelephense-$archive_sha256.tgz"
download_verified_file "$archive_url" "$archive_sha256" "$archive_path" "Intelephense $archive_root"

extraction_root="$(mktemp -d "$CACHE_DIR/extract.XXXXXX")"
trap 'rm -rf -- "$extraction_root"' EXIT
/usr/bin/tar -xzf "$archive_path" -C "$extraction_root"

package_root="$extraction_root/$archive_root"
entrypoint_path="$package_root/$entrypoint"
license_file="$package_root/$license_path"
[[ -f "$entrypoint_path" ]] || { print -u2 -- "Intelephense entrypoint is missing: $entrypoint"; exit 1; }
[[ -f "$license_file" ]] || { print -u2 -- "Intelephense license is missing: $license_path"; exit 1; }

rm -rf -- "$OUTPUT_DIR"
mkdir -p -- "$OUTPUT_DIR"
cp -R "$package_root" "$OUTPUT_DIR/package"
cp "$license_file" "$OUTPUT_DIR/LICENSE.txt"
cp "$MANIFEST" "$OUTPUT_DIR/language-server.json"

mkdir -p -- "$OUTPUT_DIR/bin"
cat > "$OUTPUT_DIR/bin/intelephense" <<EOF
#!/bin/zsh

set -euo pipefail

SCRIPT_DIR="\${0:A:h}"
NODE_EXECUTABLE="\${LITHE_NODE_PATH:-}"
if [[ -z "\$NODE_EXECUTABLE" ]]; then
    NODE_EXECUTABLE="\$(command -v node || true)"
fi
if [[ -z "\$NODE_EXECUTABLE" || ! -x "\$NODE_EXECUTABLE" ]]; then
    print -u2 -- "Intelephense requires Node.js. Install Node.js or set LITHE_NODE_PATH."
    exit 127
fi
exec "\$NODE_EXECUTABLE" "\$SCRIPT_DIR/../package/$entrypoint" "\$@"
EOF
chmod 755 "$OUTPUT_DIR/bin/intelephense"

print -r -- "$OUTPUT_DIR"
