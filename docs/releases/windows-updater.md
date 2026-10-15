# Windows in-app updates

The Windows application reuses the Tauri v2 updater with the existing NSIS
bundle for same-channel stable updates. Stable releases publish a signed updater
installer and `latest.json` alongside the normal Windows installer. The packaged
application checks the configured `latest` stable GitHub Release manifest.
The checked-in development Tauri configuration intentionally has empty endpoints
and public key; a development build without release configuration cannot perform
a signed in-place update.

## Choosing an update channel

Settings > Updates offers **Stable (recommended)** and **AutoBuild**. The default
is Stable. Selecting AutoBuild requires explicit acknowledgement: this rolling
development release is likely to contain many bugs and unfinished features, and
ordinary users should stay on Stable. The warning remains next to the selector.

The validated choice is stored in application local storage under
`lithe-update-channel`, independently of version reminders and skipped versions.
Only `stable` and `autobuild` are accepted. Missing, malformed or inaccessible
storage defaults to Stable; a failed write is shown and does not change the
selection. An explicit AutoBuild choice survives restart and replacement installs
that retain the same application identifier and user data.

The installed build identity is separate from this preference. Preview packaging
must set `VITE_UPDATE_CHANNEL=autobuild` for the frontend build; stable builds omit
it or set it to `stable`. This identity does not silently opt the user into rolling
updates. Legacy installers without this identity cannot reliably be distinguished
by their display version.

| Selected channel | Installed build | Behavior |
| --- | --- | --- |
| Stable | Stable | Existing signed Tauri update check, download, unsaved-buffer handling and restart |
| AutoBuild | Either | Explicit manual installer route at `https://github.com/1lck/Lithe-IDEA/releases/tag/AutoBuild` |
| Stable | AutoBuild | Explicit manual installer route at the existing stable canonical releases `/latest` URL |

AutoBuild currently publishes an installer and SHA-256 checksum, not the signed
Tauri feed required by the automatic updater. Its display version can be `0.3.0`
while stable is `0.6.0`, and repeated rolling builds can retain the same version.
Neither a lower nor an equal display version proves freshness. These routes
therefore return `manualDownload` / `manual-download` with no fabricated target
version or claim that the application is current. They do not perform a Tauri
version comparison or install an unsigned payload through Tauri.

A manual check opens a dialog with the selected release URL and installation
instructions. Settings checks show a **View release downloads** action. The user
must acknowledge the instructions before Lithe opens the browser: choose the
Windows installer, save work, close Lithe, then run the installer. Opening the
page does not mean an update was downloaded or installed. Lithe does not fetch
release metadata or verify that the installed rolling build is the latest.
Scheduled checks do not open a browser or display an unsolicited install dialog.
Channel changes and duplicate operations are blocked while a check, browser open,
or install (including the unsaved-buffer prompt) is in progress.

## Requirements for future signed rolling updates

Before enabling automatic rolling installation, the AutoBuild publisher must
provide all of the following:

- A signed Tauri NSIS updater installer, its `.sig`, and a `latest.json` feed
  pointing to the actual `1lck/Lithe-IDEA` AutoBuild release assets.
- A matching trusted public key and correct per-channel endpoints in the packaged
  Tauri configuration. SHA-256 files and Authenticode alone do not replace the
  updater signature. Frontend channel labels cannot switch Tauri's native feed.
- A monotonic build/version identity for repeated rolling builds, an installed
  channel identity, and an explicit policy for first transitions and cross-channel
  downgrades. Do not work around this by pretending a lower semver is newer or
  reporting equal-version rolling builds as current.
- Validation of signature rejection, channel transition policy, update resource
  cleanup and the installed application's resource immutability.

The current manual route creates no download cache, writes no installed resources
and does not change Tauri signature verification.

## One-time repository configuration

An owner of the release repository must generate the updater signing keypair:

```powershell
cd windows/tauri
bun run tauri signer generate -w <secure-backup-directory>/lithe-updater.key
```

The command writes the password-protected private key to the requested path and
the shareable public key alongside it. Back up the private key and its password
before configuring GitHub; GitHub Actions secrets cannot be read back later.

Store the generated values in the release repository settings:

| Kind | Name | Value |
| --- | --- | --- |
| Actions secret | `TAURI_SIGNING_PRIVATE_KEY` | Complete generated private key file contents |
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
- `Lithe-<version>-windows-x64-updater.exe`
- `Lithe-<version>-windows-x64-updater.exe.sig`
- `latest.json`

`latest.json` points at the versioned updater installer in the same GitHub
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
