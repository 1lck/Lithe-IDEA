# macOS application updates

Lithe uses Sparkle 2.9.6 for in-app updates. The existing menu, welcome screen,
and settings entry points keep Lithe's non-modal update offers, release details,
Later and Skip Version actions. Sparkle's standard windows handle downloads and
installation after the user chooses Install. Sparkle owns
scheduled checks, skipped versions, download progress, cancellation, archive
validation, installation, and relaunch. Lithe confirms unsaved documents when
Sparkle requests application termination and bounds shutdown after confirmation.
If termination is cancelled or delayed, the original update entries offer
Continue Installation, which reopens Sparkle's existing retry window. The active
installation and unsaved-document confirmation remain in effect.

## Configure a stable release

Configure the Sparkle key pair before the first Sparkle release. An Apple
Developer account is not required for EdDSA-signed differential updates.
The three Developer ID settings are optional and must be configured together:

| Name | Storage | Value |
| --- | --- | --- |
| `SPARKLE_PUBLIC_KEY` | Repository variable | Sparkle's base64 Ed25519 public key |
| `SPARKLE_PRIVATE_KEY` | Repository secret | The exported Sparkle private key |
| `MACOS_SIGNING_IDENTITY` | Optional repository variable | Developer ID Application signing identity |
| `MACOS_SIGNING_CERTIFICATE` | Optional repository secret | Base64-encoded PKCS#12 certificate and private key |
| `MACOS_SIGNING_PASSWORD` | Optional repository secret | PKCS#12 export password |

Use the pinned tools returned by `zsh scripts/prepare-sparkle-tools.sh`.
Generate the Sparkle key with `generate_keys --account lithe` and export it
with `generate_keys --account lithe -x <private-key-file>`. Keep an offline
backup of the private key. Do not commit the export or paste it into an issue.
Both architectures must use the same key. Key rotation requires a separately
planned migration; replacing the repository secret alone breaks existing clients.

Without a Developer ID certificate, the workflow keeps the existing ad-hoc app
signing and uses Sparkle EdDSA signatures to authenticate updates. When configured,
the Apple identity is imported into a temporary runner keychain and removed after
the build. Developer ID signing does not by itself notarize the app; notarization
remains a separate release concern. EdDSA signatures do not establish Apple
Gatekeeper trust or guarantee that macOS launch warnings disappear. A newly
downloaded DMG may still require the existing trusted-source Gatekeeper recovery
steps. Do not automatically clear quarantine as part of the updater.

Local builds without `LITHE_SPARKLE_PUBLIC_KEY` have no update feed.
A manual check offers the published Release page. They still embed the framework
so the executable can launch. Windows update configuration is unchanged.
Automatic startup checks remain idle when both feed and key are absent; partial
or invalid configuration still reports an error.

## Publish full and differential updates

The stable workflow keeps the DMG, SHA-256 checksum, and `latest-macos.json`
for old clients and Homebrew. It additionally publishes, for each architecture:

- `Lithe-<version>-<architecture>.zip`, containing the signed `Lithe.app`;
- `appcast-<architecture>.xml`, with a full archive enclosure and available deltas;
- signed `.delta` assets with architecture suffixes to avoid Release name collisions.

The app embeds its architecture-specific feed URL and public key during packaging.
It requires a signed feed and verifies archives before extraction. Sparkle also
validates Apple code signatures during installation. The workflow checks that
every enclosure has a signature and an existing asset of the declared length.
Stable feeds embed `docs/releases/v<version>.md` as plain-text descriptions before
signing, matching Lithe's native details view. Details open the offered item's
version-specific Release URL, falling back to the installed channel's Release URL.

The generator selects at most three earlier stable versions with matching ZIP
assets from GitHub releases, ordered by semantic version. It
excludes previews, drafts, the current version, and newer versions. GitHub
Release ZIPs are the persistent baseline archive; retain them after publication.
Sparkle may omit a delta if it cannot generate a useful patch. Missing baselines
produce a full-only feed; API and download errors fail the workflow.

The first Sparkle-enabled version is a full update through the legacy manifest.
Later versions can use deltas. Sparkle falls back to the full archive when a delta
is unavailable or cannot be applied. `brew upgrade --cask lithe` continues to
download the full DMG.

## Follow the preview channel

The scheduled macOS Preview workflow builds the `preview` branch daily. It pins
one source revision and build timestamp for both architectures. The build number
is `<workflow run number>.<run attempt>`, so rebuilding a failed run produces a
new identity even when the display version stays the same. Re-running only the
publish job after partially uploading assets is not supported; re-run all jobs
to allocate a new identity. A stale or duplicate build cannot replace the feed.

GitHub executes scheduled workflows from the default branch (`main`). After
review on `preview`, the updated workflow must also reach `main` for the daily
schedule to use it. A manual dispatch using this workflow revision can exercise
the new path earlier. Changing only the checked-out application source does not
change the workflow definition used by the schedule.

Preview apps embed `LitheUpdateChannel=preview` and use
`appcast-preview-<architecture>.xml` under the rolling Preview release tag.
Stable apps continue to use the stable feed; no update-channel selector or
automatic channel switch is introduced. Sparkle uses the embedded feed instead
of a persisted feed override. Both channels use the same configured EdDSA key.

The update offer shows **Preview Update**, the current and target build numbers,
the new build's date, and a short instability notice. It has **Install Preview**,
**Later**, and **Skip Build** actions. Preview release notes are neither displayed
nor downloaded. The installed version in Welcome and Settings includes Preview
and the build number. Stable release-note presentation is unchanged.

Preview ZIPs use immutable names such as `Lithe-preview-142.1-arm64.zip`. The
latest three matching ZIPs on the rolling release are differential baselines.
Full archives and deltas are uploaded before either appcast is replaced.
Historical assets are retained so cached feeds remain usable; automated pruning
is not implemented. The rolling DMGs retain their existing filenames for manual
downloads. If storage cleanup is needed, preserve current feed assets and any
archives needed for future baselines, allowing for clients with cached feeds.

An old Preview build that predates this integration must be updated manually
once using the rolling DMG. It does not already know about the new preview feed.
Subsequent Preview builds can use in-app differential updates. The first run
still needs `SPARKLE_PUBLIC_KEY` and `SPARKLE_PRIVATE_KEY` configured; it does not
require an Apple Developer account.

## Verify before release

Run the focused Swift timing harness, the full macOS suite, and package checks:

```sh
./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter 'UpdateCheckerTests|UpdateManifestTests'
./scripts/test-macos.sh
./scripts/verify-macos-package.sh
sparkle_tools=$(zsh scripts/prepare-sparkle-tools.sh)
ruby scripts/test-sparkle-update.rb "$sparkle_tools"
actionlint .github/workflows/release-macos.yml .github/workflows/release-preview-macos.yml .github/workflows/ci-macos.yml
```

The local Sparkle integration check creates disposable ad-hoc-signed fixtures.
It checks full-only bootstrap, consecutive-version delta generation, byte-for-byte
patch application, code signature integrity, EdDSA rejection after corruption,
architecture-specific delta names, signed feeds, and full fallback metadata.
It does not install or launch Lithe or use production credentials.

Before shipping, test actual signed releases on both architectures: legacy DMG
upgrade into the first Sparkle version; Sparkle upgrade into the next version;
missing and corrupted deltas; interrupted downloads; insufficient permissions;
cancelled authorization; and cancelling termination with unsaved documents.
Confirm that the installed version relaunches and that all test applications and
installer helpers exit. Local fixture checks do not replace these installation tests.
