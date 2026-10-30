#!/bin/zsh
# End-to-end check of the macOS update download relay against a local Sparkle feed.
#
# Builds two signed fixture apps (1.0.0/100 and 2.0.0/200), an appcast with a delta, and
# runs SparkleRelayEndToEndTests through the real Sparkle installer for each scenario:
# delta and full updates with a dropped connection, a server that dies mid-download and
# comes back in a later session, and an archive re-uploaded under the same name while the
# server ignores a stale If-Range. Everything lives in a temporary directory that is
# removed on exit, together with the fixture's defaults and caches.
#
# Usage: scripts/release/sparkle/test-sparkle-relay-e2e.sh [--keep]
set -euo pipefail

script_dir="${0:A:h}"
repo="${script_dir:h:h:h}"
port="${LITHE_E2E_PORT:-18765}"
keep=0; [[ "${1:-}" == "--keep" ]] && keep=1
fixture_id=app.lithe.e2e.fixture
root=$(mktemp -d "${TMPDIR:-/tmp}/lithe-sparkle-relay-e2e.XXXXXX")
server=""
failures=0

stop_server() {
    [[ -n "$server" ]] || return 0
    kill "$server" 2>/dev/null || true
    wait "$server" 2>/dev/null || true
    server=""
}
cleanup() {
    stop_server
    defaults delete "$fixture_id" >/dev/null 2>&1 || true
    rm -rf "$HOME/Library/Caches/$fixture_id"
    if (( keep )); then print -r -- "kept $root"; else rm -rf "$root"; fi
}
trap cleanup EXIT

# --- fixture -------------------------------------------------------------------------
tools=$(zsh "$repo/scripts/release/sparkle/prepare-sparkle-tools.sh")
fix="$root/fixture"
mkdir -p "$fix/apps" "$fix/archives" "$fix/feed-delta" "$fix/feed-full" "$fix/feed-stale"
# Throwaway EdDSA key: 32 bytes of 0x01. Never used outside this fixture.
private_key=$(printf '\x01%.0s' {1..32} | base64)
public_key=$(swift -e 'import CryptoKit; import Foundation; print(try Curve25519.Signing.PrivateKey(rawRepresentation: Data(repeating: 1, count: 32)).publicKey.rawRepresentation.base64EncodedString())')
print -r -- 'int main(void){return 0;}' > "$fix/main.c"
cc -o "$fix/fixture" "$fix/main.c"
head -c 24000000 /dev/urandom > "$fix/payload.bin"

make_app() { # <version> <build>
    local app="$fix/apps/$2/LitheE2E.app"
    mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cp "$fix/fixture" "$app/Contents/MacOS/LitheE2E"
    cp "$fix/payload.bin" "$app/Contents/Resources/payload.bin"
    if [[ "$2" == 200 ]]; then # change one MiB so the delta stays small
        dd if=/dev/urandom of="$app/Contents/Resources/payload.bin" bs=1048576 seek=10 count=1 conv=notrunc 2>/dev/null
    fi
    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>LitheE2E</string>
<key>CFBundleIdentifier</key><string>$fixture_id</string>
<key>CFBundleName</key><string>LitheE2E</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$1</string>
<key>CFBundleVersion</key><string>$2</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>SUPublicEDKey</key><string>$public_key</string>
<key>SUFeedURL</key><string>http://127.0.0.1:$port/appcast.xml</string>
<key>SUEnableAutomaticChecks</key><false/>
</dict></plist>
PLIST
    codesign --force --deep --sign - "$app" 2>/dev/null
    ditto -c -k --sequesterRsrc --keepParent "$app" "$fix/archives/LitheE2E-$1.zip"
}
make_app 1.0.0 100
make_app 2.0.0 200
print -r -- "$private_key" | "$tools/generate_appcast" --ed-key-file - --versions 200 --maximum-deltas 3 \
    --download-url-prefix "http://127.0.0.1:$port/" -o "$fix/archives/appcast.xml" "$fix/archives" >/dev/null
cp "$fix/archives/LitheE2E-2.0.0.zip" "$fix/archives/appcast.xml" "$fix/archives"/*.delta "$fix/feed-delta/"
cp "$fix/archives/LitheE2E-2.0.0.zip" "$fix/feed-full/"
ruby -e 's=File.read(ARGV[0]); s.sub!(%r{<sparkle:deltas>.*?</sparkle:deltas>}m, ""); File.write(ARGV[1], s)' \
    "$fix/archives/appcast.xml" "$fix/feed-full/appcast.xml"
# Same names, different archive bytes: what a client sees before a tag is re-uploaded.
cp "$fix/feed-full/appcast.xml" "$fix/feed-stale/"
head -c "$(stat -f%z "$fix/feed-full/LitheE2E-2.0.0.zip")" /dev/urandom > "$fix/feed-stale/LitheE2E-2.0.0.zip"

print -r -- "Building tests…"
(cd "$repo/macos" && swift build --build-tests >/dev/null)

# --- scenarios -----------------------------------------------------------------------
start_server() { # <feed dir> <log> [env…]
    local feed=$1 log=$2; shift 2
    env "$@" python3 -I "$script_dir/sparkle-relay-e2e-server.py" "$feed" "$port" "$log" &
    server=$!
    for _ in {1..50}; do
        curl -s -o /dev/null "http://127.0.0.1:$port/appcast.xml" && return 0
        sleep 0.1
    done
    print -r -- "server did not start on port $port" >&2
    return 1
}

run_session() { # <work> [env…]
    local work=$1; shift
    (cd "$repo/macos" && env LITHE_E2E_APP="$work/LitheE2E.app" \
        LITHE_E2E_FEED="http://127.0.0.1:$port/appcast.xml" LITHE_E2E_EXPECTED_BUILD=200 \
        LITHE_E2E_PARTIALS="$work/partials" "$@" \
        swift test --skip-build --filter SparkleRelayEndToEndTests 2>&1) > "$work/test.log"
}

check() { # <scenario> <description> <condition…>
    local scenario=$1 description=$2; shift 2
    if "$@"; then print -r -- "  ok   $description"
    else print -r -- "  FAIL $description"; failures=$((failures + 1)); fi
}

verify_installed() { # <scenario> <work>
    local work=$2
    check "$1" "Sparkle installed build 200" \
        test "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$work/LitheE2E.app/Contents/Info.plist")" = 200
    check "$1" "code signature is intact" codesign --verify --deep "$work/LitheE2E.app"
    check "$1" "payload matches 2.0.0" cmp -s "$work/LitheE2E.app/Contents/Resources/payload.bin" \
        "$fix/apps/200/LitheE2E.app/Contents/Resources/payload.bin"
    check "$1" "no partial download left" test -z "$(ls -A "$work/partials")"
    check "$1" "test passed" grep -q "Test updateDownloadsThroughRelayAndInstalls() passed" "$work/test.log"
}

new_work() { # <scenario>
    local work="$root/$1"
    mkdir -p "$work/partials"
    ditto "$fix/apps/100/LitheE2E.app" "$work/LitheE2E.app"
    print -r -- "$work"
}

scenario() { # <name> <feed> <drop>
    local work; work=$(new_work "$1")
    print -r -- "== $1"
    start_server "$fix/feed-$2" "$work/server.log" DROP_FIRST="$3"
    run_session "$work" || true
    stop_server
    verify_installed "$1" "$work"
    if [[ "$3" == 1 ]]; then
        check "$1" "download resumed with Range" grep -q '"status": 206' "$work/server.log"
    fi
}

scenario delta-dropped delta 1
scenario full-dropped full 1
scenario full-clean full 0

for name in server-restart reupload; do
    work=$(new_work "$name")
    print -r -- "== $name"
    first_feed=full; second_env=()
    [[ "$name" == reupload ]] && { first_feed=stale; second_env=(IGNORE_IF_RANGE=1); }
    start_server "$fix/feed-$first_feed" "$work/server.log" DROP_FIRST=1 EXIT_AFTER_DROP=1
    run_session "$work" LITHE_E2E_EXPECT_FAILURE=1 || true
    stop_server
    check "$name" "first session fails and keeps the partial" test -n "$(ls -A "$work/partials")"
    check "$name" "first session reports a network cause" grep -q "E2E failure=" "$work/test.log"
    start_server "$fix/feed-full" "$work/server.log" "${second_env[@]}"
    run_session "$work" || true
    stop_server
    verify_installed "$name" "$work"
    check "$name" "second session asks to resume" grep -q '"range": "bytes=' "$work/server.log"
    if [[ "$name" == reupload ]]; then
        check "$name" "stale prefix discarded and archive fetched again" \
            zsh -c "grep '\"path\": \"LitheE2E' '$work/server.log' | tail -1 | grep -q '\"status\": 200, \"range\": null'"
    fi
done

if (( failures )); then
    print -r -- "$failures check(s) failed; rerun with --keep to inspect $root" >&2
    exit 1
fi
print -r -- "All Sparkle relay scenarios passed."
