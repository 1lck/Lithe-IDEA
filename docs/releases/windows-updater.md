# Windows in-app updates

The Windows application uses the Tauri v2 updater with the existing NSIS
bundle. Stable releases publish a signed updater archive and `latest.json`
alongside the normal Windows installer. The application checks the manifest at
the `latest` stable GitHub Release for the repository that built it.

## One-time repository configuration

An owner of the release repository must generate the updater signing keypair:

```powershell
cd windows/tauri
bunx tauri signer generate
```

Store the generated values in the release repository settings:

| Kind | Name | Value |
| --- | --- | --- |
| Actions secret | `TAURI_SIGNING_PRIVATE_KEY` | Complete generated private key |
| Actions secret | `TAURI_SIGNING_PRIVATE_KEY_PASSWORD` | Private-key password; omit this secret when the key has no password |
| Actions variable | `TAURI_UPDATER_PUBLIC_KEY` | Complete generated public key |

Never commit the private key or its password. The public key is injected into
the packaged application by the release workflow and is safe to store as a
repository variable.

The existing `WINDOWS_SIGNING_CERTIFICATE_BASE64`,
`WINDOWS_SIGNING_CERTIFICATE_PASSWORD`, and `WINDOWS_TIMESTAMP_SERVER` settings
continue to control Windows Authenticode signing. Authenticode and Tauri updater
signatures serve different purposes and should both be configured for a public
release.

## Stable release artifacts

The `Release Windows` workflow publishes:

- `Lithe-<version>-windows-x64.exe`
- `Lithe-<version>-windows-x64.exe.sha256`
- `Lithe-<version>-windows-x64.nsis.zip`
- `Lithe-<version>-windows-x64.nsis.zip.sig`
- `latest.json`

`latest.json` points at the versioned updater archive in the same GitHub
Release. The workflow fails instead of publishing an unsigned updater when the
updater keypair is not configured.

## Release verification

Before announcing a stable release, install the preceding Windows version and
verify this sequence against the new release:

1. **Help > Check for Updates** reports the new version and release notes.
2. Download progress reaches completion.
3. Unsaved buffers are handled before the application exits.
4. The updater installs the signed NSIS bundle and relaunches Lithe.
5. The relaunched application reports the new version.
6. A second manual check reports that the application is current.

Also verify that a manifest with a modified signature is rejected. Use a
temporary keypair and a fork Release for development tests; never reuse a test
private key for official releases.
