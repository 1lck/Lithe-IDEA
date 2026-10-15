# macOS application updates

Why Sparkle+EdDSA over requiring a Developer ID, why stable/preview stay on
separate feeds and default-domain suites, why rollback only trusts the
client-embedded key, and the asset-retention tradeoffs are recorded in
[`.agents/notes/implemented/process/2026-09-13-macos-update-signing-and-release-strategy.md`](../../.agents/notes/implemented/process/2026-09-13-macos-update-signing-and-release-strategy.md).
This document is the operational runbook: how to configure secrets, how the
release workflows behave step by step, and how to verify a release.

Lithe uses Sparkle 2.10.0 for in-app updates. The existing menu, welcome screen,
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

## Keep the runtime bundle immutable

The app bundle inside a published ZIP is the exact byte baseline used to build
Sparkle deltas. It is therefore a read-only input after installation. Runtime
files such as language-server indexes, Eclipse/OSGi state, downloaded archives,
plugin state, logs, and lock files belong in the platform cache, Application
Support, temporary storage, or the user's workspace. A resource resolver may
read `Bundle.main.resourceURL`, but it must never use that path as a write
destination.

JDTLS is the one bundled runtime that writes next to its own files: Equinox
stores its framework state in the `-configuration` directory. Rust Core copies
the packaged `config.ini` into
`Caches/Lithe/language-servers/jdtls-configuration/<sha256>/configuration/` and
passes that directory instead, so its OSGi files cannot modify
`Contents/Resources`. The Windows product uses the same Core path with
`app_cache_dir()`. New runtime resources must document their lifecycle, owner,
writable location, and whether they affect signing or delta generation in the
code or an Agent Note.

The full ZIP fallback is not a successful differential update: it only means
Sparkle recovered by downloading the complete archive. Before publishing, run
the bundle immutability guard and the resolver test, then exercise a signed app's
typical startup and language-service workflow and compare the app bundle file
list and SHA-256 values with the clean release artifact. If a workflow changes
the bundle, fix its storage boundary before generating another delta.

## Choose Stable or AutoBuild

Update settings default to **Stable (Recommended)**, regardless of the installed
channel. Selecting **AutoBuild Rolling** requires risk confirmation. A persistent
warning explains that nightly builds may contain unfinished features, serious bugs,
or other problems and recommends stable releases for most users. Invalid saved
preferences fall back to Stable. Channel preference and installed identity are
separate; changing the preference does not replace the installed application.

The scheduled workflow runs from the default branch (`main`), pins one `preview`
source SHA, and captures one whole-second UTC timestamp for macOS and Windows.
The numeric Sparkle identity `20261015.124354` encodes exactly
`2026-10-15T12:43:54Z`. Welcome, Settings, update offers, the release title, and
release notes show **AutoBuild — Built at 2026-10-15 12:43:54 UTC** (localized
as **AutoBuild — 构建自 … UTC**). Workflow run/attempt counters do not order
versions. Equal or older times cannot replace a published build. Retrying
publication retains the artifact's original time instead of relabeling old bytes.

Publication waits for both macOS architectures and the reusable Windows installer
build, all carrying the same source, version, build and timestamp.
The publisher checks both existing appcasts before any remote mutation: the new
time must be strictly later than each published `pubDate`, and the numeric build
must increase. As long as the `preview-0.3.0` release remains, its appcasts also
pass the strict baseline check, even when AutoBuild exists but is empty or has only
an incomplete checkpoint. Exact-plan recovery applies only to AutoBuild. Legacy builds
such as `58.1` remain readable baselines; new builds
must use timestamp identities. New publications at duplicate seconds and backward
clocks fail without inventing a counter. Before replacing data or feeds, the publisher
uploads `autobuild-publication.json`, binding source, version, build, timestamp and the
sorted target asset sizes and SHA-256 hashes. A byte-identical checkpoint permits
resuming the same publication with the original artifacts, including completing tag,
metadata and cleanup after feed replacement. An already-current feed must match the
local bytes exactly; older feeds still pass the strict baseline check. Missing feeds
or empty `starter` uploads can be repaired only with this matching checkpoint.
Changed bytes/source at the same instant and older retries against newer checkpoints
fail before mutation. The checkpoint itself is retained and verified with the assets.

The rolling tag stays `AutoBuild`. New packages write
`LitheUpdateChannel=autobuild`; legacy `preview` metadata remains readable.
The feed is `releases/download/AutoBuild/appcast-preview-<architecture>.xml`.
Sparkle uses the selected channel's feed. Skipped versions and automatic-check
preferences remain separate under `app.lithe.desktop.sparkle.stable` and
`app.lithe.desktop.sparkle.autobuild`; legacy preferences are not migrated.
Both channels retain the configured EdDSA key.

Same-channel macOS updates retain Sparkle download, signature verification, and
installation. Crossing channels requires a full installation and never compares
stable semantic versions with rolling times. Old offers are dismissed before
switching, and active work blocks channel changes. AutoBuild offers **Install
AutoBuild**, **Later**, and **Skip Build**. Its concise risk notice replaces
release-note downloading. The full signed **Return to Stable** remains available.
Windows retains the native Stable-to-Stable updater; AutoBuild and cross-channel
checks explicitly offer manual full installation from the release page because
no signed rolling Tauri manifest is published. They never claim freshness or
open the browser silently during scheduled checks.

ZIPs retain compatible names such as `Lithe-preview-20261015.124354-arm64.zip`.
AutoBuild keeps only the current full ZIP per architecture and deltas targeting
the current build. Previous ZIPs are temporary delta inputs; older clients can
use the current full archive after checking again. Historical cached feed URLs
are not retained.

The publisher runs from `github.workflow_sha`, not from the application checkout.
It reads the official plugin registry/index with `git fetch/show` at the pinned
application SHA, selects each registered downloadable plugin's latest numeric
semantic version and all distinct variants, downloads existing ZIPs from indexed
`Lithe-IDEA` organization releases, and verifies the index SHA-256 before any
release mutation. It mirrors byte-identical signed packages plus SHA sidecars;
no plugin key, rebuilding, re-signing or canonical marketplace URL change is needed.
Bundled Java is excluded; current downloadable PHP and Go packages are 1.0.0.

After local validation and strict published-baseline time checks, all installers, archives, deltas and plugin mirrors upload
before either XML feed. The complete desired manifest is verified remotely using
asset SHA-256 digests, or a bounded download when a digest is unavailable. Only
then does the publisher explicitly force PATCH `git/refs/tags/AutoBuild` to the
source SHA, update and verify metadata, and remove every stale AutoBuild asset,
including obsolete installers and plugin versions. Failed download, hash,
upload or manifest verification prevents stale-asset cleanup. GitHub does not
provide atomic multi-file replacement; partial uploads can remain on failure.
Stable releases and upstream plugin releases are outside this publisher's scope.

Only after complete verified publication and cleanup can `preview-0.3.0` and its
tag be retired. Clients using that old feed require one manual AutoBuild
reinstall. A second compatibility tag is not retained. AutoBuild release notes
warn in Chinese and English that ordinary users should use Stable.

Each appcast's `pubDate` matches the app timestamp. With no eligible baseline,
the first publication uses a full signed archive. Both Sparkle keys remain
required; an Apple Developer account is optional. The default-branch publisher
and preview-client changes must both be available before using the new schedule.

## Return from AutoBuild to stable

Preview builds expose Return to Stable in Settings and Welcome. Confirmation
downloads the latest stable `latest-macos.json` and the architecture-specific full
DMG over HTTPS. This path intentionally accepts a lower version and never requests
a delta. It supports stable releases published before the Sparkle migration.

The stable publisher signs each full DMG using `SPARKLE_PRIVATE_KEY` and embeds
the detached signature in the architecture asset's optional `edSignature` field.
The stable workflow requires both signatures when producing `latest-macos.json`;
older clients ignore this additive schema-1 field. The rollback client requires
the signature and verifies it with its embedded `SUPublicEDKey` before mounting
or copying anything. It never accepts a key supplied by the downloaded manifest.
SHA-256 and ad-hoc code signing alone do not authenticate the publisher.

The installer verifies the manifest SHA-256, DMG Ed25519 signature, app code signature, bundle identifier,
display version, executable architecture, stable channel (or legacy missing channel),
and minimum macOS version. It stages the app on the destination volume. Native
copying, mounting and verification run on a worker queue with bounded processes.
Download cancellation or preparation failure leaves the installed app intact.
Preparation failures record the tool name, exit code and up to 2048 characters
of path-redacted output through the injected `MacApplicationLogWriter` sink in
`lithe.log`, the same file read by Diagnostics Export;
the UI retains its short recovery message.

Previously published stable DMGs without `edSignature` are refused by automatic
rollback and offer manual installation instead. To enable them without rebuilding,
an authorized maintainer must obtain and verify the original binaries, sign each
with the existing Sparkle private key using `sign_update --ed-key-file - -p`, save
the public signature as `<DMG filename>.edsig`, and regenerate the manifest with
`create-macos-update-manifest.rb --require-signatures`. Publishing that manifest
is a separate release operation; no existing live release is modified by this PR.

Install and Restart uses the same unsaved-document confirmation and bounded
shutdown as application updates. The independent helper starts only after that
confirmation succeeds; cancellation returns to the prepared state without a
helper. Sparkle cannot install downgrades, so its installer is not used here.
Normal Sparkle checks/install actions are blocked while rollback is active; a
pending Preview offer is dismissed before starting the full download.

The helper waits at most 120 seconds for the original process to exit and never
kills it. It renames the original app to `previous.app` inside the private sibling
directory `.lithe-stable-<id>`, then moves the staged app into place. Replacement
or launch-command failure restores the original when possible. The previous app
and `installation.log` remain in that directory for recovery. A successful launch
command does not prove the new app cannot later crash; real downgrade acceptance
testing remains required. Gatekeeper recovery instructions still apply.

The current app's parent directory must be writable. Protected locations fail
before exiting and offer the stable Release page for manual installation; this
path does not request administrator privileges. No project, setting or workspace
data is deleted or migrated backward. Users are warned that Preview-only settings
may not be understood by the older stable app. The installed stable app resumes
its own update channel (Sparkle or the legacy updater, depending on its version).

## Verify before release

Run the focused Swift timing harness, the full macOS suite, and package checks:

```sh
./scripts/verify-runtime-bundle-immutability.sh
./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh -- --filter 'StableRollbackTests|UpdateCheckerTests|UpdateManifestTests'
./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh --max-seconds 60 -- --filter StableRollbackDiskImageIntegrationTests
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
