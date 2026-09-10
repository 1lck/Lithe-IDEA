#!/bin/zsh

set -euo pipefail

ROOT_DIR="${0:A:h:h}"
INFO_PLIST="$ROOT_DIR/macos/Resources/Info.plist"
DEFAULT_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST")
VERSION="${LITHE_VERSION:-$DEFAULT_VERSION}"
ARCH="${LITHE_ARCH:-universal}"
DIST_ROOT="${LITHE_DIST_ROOT:-$ROOT_DIR/dist}"
case "$ARCH" in
    universal)
        APP_DIR="$DIST_ROOT/Lithe.app"
        DMG_PATH="$DIST_ROOT/Lithe-${VERSION}.dmg"
        ;;
    arm64|x86_64)
        APP_DIR="$DIST_ROOT/Lithe-$ARCH.app"
        DMG_PATH="$DIST_ROOT/Lithe-${VERSION}-${ARCH}.dmg"
        ;;
    *)
        print -u2 -- "Unsupported app architecture: $ARCH"
        exit 1
        ;;
esac
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/lithe-dmg.XXXXXX")"
trap 'rm -rf -- "$STAGING_DIR"' EXIT

if [[ ! -d "$APP_DIR" ]]; then
    print -u2 -- "Missing app bundle: $APP_DIR"
    exit 1
fi

cp -R "$APP_DIR" "$STAGING_DIR/Lithe.app"
ln -s /Applications "$STAGING_DIR/Applications"

# Temporary diagnostics for the intermittent "hdiutil: create failed - Resource
# busy" seen on macos-14 CI runners. hdiutil rejects the request within seconds
# rather than timing out, which points at something holding the staging tree or
# a stale attached device rather than at slow I/O. Capture that state on the
# runner so a failure carries evidence instead of guesswork.
#
# Everything here writes to stderr: callers parse the last stdout line as the
# produced disk image path.
#
# Remove this block once the root cause is identified.
report_disk_image_state() {
    local stage="$1"
    print -u2 -- "--- dmg diagnostics ($stage): attached disk images ---"
    /usr/bin/hdiutil info >&2 || true
    print -u2 -- "--- dmg diagnostics ($stage): openers of the staging tree ---"
    # Use a non-recursive directory lookup: recursive `+D` can take minutes on
    # a large app bundle and would make the diagnostic path look like a hung
    # package build. lsof still reports processes holding the staging root.
    /usr/sbin/lsof +d "$STAGING_DIR" >&2 || true
    print -u2 -- "--- dmg diagnostics ($stage): mounted volumes ---"
    /bin/ls -1 /Volumes >&2 || true
    print -u2 -- "--- dmg diagnostics ($stage): end ---"
}

hdiutil_options=(
    -volname "Lithe"
    -srcfolder "$STAGING_DIR"
    -ov
    -format UDZO
)
if [[ -n "${LITHE_DMG_DIAGNOSTICS:-}" ]]; then
    report_disk_image_state "before create"
    hdiutil_options+=(-debug)
fi

create_log="$STAGING_DIR/hdiutil-create.log"
hdiutil_status=0
for attempt in 1 2 3; do
    rm -f -- "$DMG_PATH" "$create_log"
    hdiutil create "${hdiutil_options[@]}" "$DMG_PATH" > "$create_log" 2>&1 || hdiutil_status=$?
    if (( hdiutil_status == 0 )); then
        break
    fi
    cat "$create_log" >&2
    if ! grep -Eiq 'resource busy|0x0000C010|49168' "$create_log" || (( attempt == 3 )); then
        break
    fi
    print -u2 -- "hdiutil create reported a transient busy resource; retrying ($attempt/3)."
    sleep $(( attempt * 2 ))
    hdiutil_status=0
done
if (( hdiutil_status != 0 )); then
    if [[ -n "${LITHE_DMG_DIAGNOSTICS:-}" ]]; then
        report_disk_image_state "after failed create"
    fi
    exit $hdiutil_status
fi

print -r -- "$DMG_PATH"
