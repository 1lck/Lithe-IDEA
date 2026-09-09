# Update contract v1

The update contract separates portable update semantics from platform-owned
download and installation workflows.

## Normalized state

Both products expose one logical state machine:

`idle` → `checking` → `available` → `downloading` → `installing`

An unsuccessful operation enters `failed`. A successful check with no newer
version enters `upToDate`. The normalized update information contains the
current version, target version, release date, release notes, and release URL.

The complete JSON shape is defined by
[`update-v1.schema.json`](update-v1.schema.json). The platform feeds may keep
their native wire formats: macOS needs architecture-specific DMG checksums and
Windows needs the Tauri updater signature. Each platform adapter maps its feed
to this normalized model.

## Preferences

- `Later` suppresses the exact target version for 24 hours.
- `Skip version` suppresses the exact target version until a newer target is
  published.
- Either preference is cleared when the latest target version changes.
- Manual checks ignore suppression preferences.

## Error codes

Error codes are stable identifiers from the schema. HTTP status values and
platform diagnostics remain details of the platform adapter; they must not
become new cross-platform state variants.
