---
name: release-lithe
description: Check and sync the Viva fork before every desktop release, choose version numbers for the Lithe app and Lithe plugins, and prepare and validate stable Lithe release notes and publishing workflows. Use when preparing any desktop release (a desktop-v* prerelease or a stable release), deciding a version number, drafting docs/releases files, cutting a stable version, publishing a GitHub Release, or changing release automation.
---

# Release Lithe

Apply this Skill after `develop-lithe`. Each section applies to these
releases:

- "Sync Viva before a desktop release" applies to every release of the
  desktop app: `desktop-v*` prereleases and stable releases. Plugin releases
  skip it.
- "Choose the version number" applies to every release of the Lithe app and
  of every Lithe plugin.
- The remaining sections apply to stable app releases. Preview releases keep
  their existing workflow unless the task explicitly includes them.

## Sync Viva before a desktop release

The desktop app links the Viva commit that the `replace` directive in
`desktop/go.mod` pins: a commit on `main` of
[Lithe-IDEA/Lithe-viva](https://github.com/Lithe-IDEA/Lithe-viva), the fork of
[vivaui/viva](https://github.com/vivaui/viva). `desktop/go.mod` still writes
the fork's former path `github.com/Lithe-IDEA/viva`, which GitHub redirects.
The procedure, with the exact commands, is the section "发版前同步上游" of
`.agents/notes/implemented/process/2026-11-11-viva-fork-maintenance-and-commit-pin.md`.

Before choosing the version or writing release notes, check these four
things:

1. Upstream commits missing from fork `main`.
2. Open pull requests in the fork. Each one is a patch of ours that fork
   `main` does not contain yet.
3. Whether the `replace` target in `desktop/go.mod` at the release target
   commit is the head of fork `main`.
4. Lithe workarounds for Viva: the open items of issue
   [#1821](https://github.com/1lck/Lithe-IDEA/issues/1821), and comments or
   skipped tests under `desktop/` that cite a Viva pull request or issue.

Checks 1 to 3 decide whether the release waits. When any of them finds
something, stop and remind the user before going further: give the count and
the list for each check, add the list from check 4, and say that the release
waits for the sync. Check 4 alone does not stop the release, because a
workaround stays until upstream offers a replacement; the sync re-examines
every item on it.

Do not merge into or push to the fork, and do not change the pin, unless the
user asks for the sync. When the user asks, follow the Note:

- Merge upstream `main` into fork `main` with a merge commit, never a squash.
- Merge every one of our patches into fork `main`. Where a patch conflicts
  with upstream, or upstream solves the same problem differently, keep
  upstream's approach and drop ours.
- Bump the pin in one Lithe pull request that also replaces each Lithe
  workaround upstream now covers with the new approach and deletes the old
  logic.
- Deliver the sync report the Note specifies, in that pull request's
  description and to the user.

Continue the release only when one of these holds:

- Checks 1 to 3 find nothing.
- The pin bump from the sync is merged into main and the release target
  commit contains it. Choose the version and write the notes from that
  commit, because the sync changes what the release contains.
- The user explicitly decides to release without the sync. Tell the user
  what stays unsynced, and repeat it in the final release report.

## Choose the version number

Every release uses a `MAJOR.MINOR.PATCH` version. This covers stable app
releases, `desktop-v*` desktop prereleases, and plugins, including the
community plugins in the Lithe-IDEA organization. Compare the release with the
previous published version of the same artifact, stable or prerelease. The app
and plugins use different rules for which part to increment.

### The app

Release the app in small steps. A backward-compatible release increments
PATCH, even when it adds features:

| Part | Increment when | Compatibility | From 1.2.3 |
| --- | --- | --- | --- |
| PATCH | The release is backward compatible: bug fixes, improvements, and new features | Fully compatible; users upgrade without doing anything | 1.2.4 |
| MINOR | The user explicitly asks for a MINOR release for this version | Backward compatible; nothing users rely on changes | 1.3.0 |
| MAJOR | The release contains at least one breaking change | Not compatible with the previous version; users may need to change something | 2.0.0 |

- Do not increment MINOR because a release contains new features. List the
  features in the release notes instead.
- Increment MINOR only when the user asks for it for the release being
  prepared. A request applies to that one release and does not carry over to
  later releases. Do not propose a MINOR increment yourself.

A change to the app is breaking when a user of the previous version cannot
upgrade without doing something, or loses something they relied on. These
changes are breaking:

- Removing or renaming a user-visible feature, command, setting, or keyboard
  shortcut.
- Dropping a plugin contract or plugin API version that installed plugins use,
  so that those plugins stop loading.
- Changing the format of settings, project state, or other stored data without
  migrating the previous version's data automatically.
- Raising the minimum supported operating system version, or dropping a
  platform or CPU architecture.

### Plugins

A plugin increments MINOR for features and PATCH for everything else:

| Part | Increment when | From 1.2.3 |
| --- | --- | --- |
| PATCH | The release changes the package but adds no feature: bug fixes, performance, wording, refactoring, packaging | 1.2.4 |
| MINOR | The release adds at least one feature | 1.3.0 |
| MAJOR | The user asks for it because the release is a major overhaul of the plugin | 2.0.0 |

- A feature is a change committed as `feat`: something users can newly do or
  see, such as a command, task, run entry, run configuration type, setting,
  build option, language feature, or supported tool. A release with both
  features and fixes increments MINOR.
- A feature that needs a host capability or plugin contract version that no
  published host supports still increments MINOR. Publish that release as a
  prerelease.
- Breaking changes do not increment MAJOR. Increment MAJOR only when the user
  asks for it for the release being prepared; do not propose it yourself.
- These plugin changes are breaking. The release notes list each one with what
  users must do:
  - Requiring a host or plugin contract version that hosts able to run the
    previous version do not support, so that those users can no longer install
    or update the plugin.
  - Removing or renaming a feature, command, task, run entry, setting, or build
    option that the previous version declared.
  - Changing a setting key or value format, so that values users saved are lost
    or read differently.
  - Requiring an external program the previous version did not need, or a newer
    version of one it already ran.

### Every version number

- Versions below 1.0.0 follow the same rules. Do not apply the semantic
  versioning exception for initial development: a breaking change to app
  0.y.z releases 1.0.0, not 0.(y+1).0.
- PATCH and MINOR keep counting past 9: 0.8.9 is followed by 0.8.10, not
  0.9.0. The desktop update check and the Lithe Store compare each part as a
  number.
- Incrementing MAJOR resets MINOR and PATCH to 0. Incrementing MINOR resets
  PATCH to 0.
- The version number does not say whether a release is a prerelease. Publish
  a release as a prerelease when no stable host can use it yet, whatever its
  number. Keep the plain number and the plain tag (`v<version>`, or
  `desktop-v<version>` for the desktop app), with no `-beta` or similar suffix.
- The desktop app shows its version without the preview label only when the
  Desktop Release built it for the commit of its `desktop-v<version>` tag:
  `scripts/ci/desktop-release/package-release.sh` packages with
  `package-desktop.sh --stable`, which adds the `lithe_stable` build tag, and
  fails when a packaged program lacks it. Every other build, including the
  daily `desktop-AutoBuild` and local packages, shows the version with the
  preview label. This label is independent of the GitHub prerelease flag. Pass
  `--stable` nowhere else.
- Never reuse a published version or publish a lower one. A published package
  is never modified; every change ships as a new version. The only exception
  is a version reset that the user explicitly requests for one artifact:
  delete all of its GitHub Releases and tags, remove all of its versions from
  the Lithe Store index, and publish again from 0.0.1. Never reset a version
  on your own initiative.
- Every app MAJOR release, and every plugin release with a breaking change,
  lists each breaking change, together with what users must do, in its
  upgrade or compatibility notes.

## Prepare the release notes first

- Create `docs/releases/v<version>.md` and commit it before creating the tag or
  manually dispatching either stable release workflow.
- Derive the content from the commits, pull requests, tests, packaging changes,
  and known limitations between the previous stable tag and the target commit.
  Do not invent features, compatibility claims, download assets, or fixes.
- Treat the release notes as a required release artifact. A missing or empty
  file blocks the release; never fall back to GitHub-generated notes.
- Keep the release description short, plain-language, and focused on what users
  can do or notice after updating. Write from the user's point of view: explain
  the problem solved or workflow improved before naming the implementation.
- Include all meaningful user-facing changes, grouping related changes when that
  makes the release easier to scan. Do not impose a fixed number of highlights.
  Each highlight should answer “What does this change mean for me?” in one
  sentence. Avoid internal names and jargon such as
  implementation class names, protocol phases, rendering backends, or test
  terminology. Mention a technical name only when a user must recognize it in
  the UI or follow a setup step, and explain it in plain language.
- Do not publish a raw commit or pull-request list as the release description.
- Every stable release description must include the macOS Gatekeeper recovery
  note below in both languages. Keep the command exactly as written and remind
  users to use it only for an app downloaded from a source they trust:

  Chinese:
  `xattr -dr com.apple.quarantine /Applications/Lithe.app`

  English:
  `xattr -dr com.apple.quarantine /Applications/Lithe.app`

## Trace the host capabilities that plugins need

Most new host capabilities exist because a plugin needed them. Every desktop
release names the plugin versions that need a capability the release adds, so
users can see which Lithe version a plugin requires and every addition stays
traceable to the plugin that asked for it.

1. List what the release adds to the plugin API. Read `PINNED_CORE_REVISION`
   in `scripts/desktop/build-desktop-core.sh` at the previous release tag and
   at the target commit, and compare the two Core revisions in the Core
   repository:
   - `git diff <previous> <target> -- rust/crates/plugin-model/src/capabilities.rs`
     shows the capability versions added to `SUPPORTED_CAPABILITIES`.
   - The entries added to `shared/plugins/reference/protocol-changelog.md`
     between the two revisions show the new host methods and host
     notifications.
   - Count an addition only when the desktop app at the target commit also
     implements it; Core can accept a capability version before the desktop
     host declares it.
2. Find the plugin behind each addition. The Core and desktop pull requests
   that added it name the plugin that needs it. Confirm it in that plugin's
   repository: the `requires` object of its `plugin.json` names the capability
   version, or its backend calls the host method. Take the first plugin version
   that needs the addition, whether it is already published or is the version
   on the plugin's `main` that waits for this release.
3. Under `#### 🔌 插件需要的新宿主能力` and
   `#### 🔌 New host capabilities that plugins need`, write one bullet per
   plugin version: the repository link, the plugin name and version (mark a
   prerelease or an unpublished version), each capability with its version or
   each host method, what the plugin uses it for, and any fix in this release
   the plugin also relies on. Precede the bullets with one sentence that says
   what an older Lithe does with those plugin versions, as the contract states
   it: for example, Lithe refuses to install a plugin whose `requires` names a
   capability version it lacks.
4. Do not list additions that no plugin needs yet. When nothing qualifies,
   omit the category in both languages.

## Use the bilingual structure

Write Simplified Chinese first and English second, separated by `---`. Keep the
two sections equivalent in meaning. Use these literal required headings and
this order:

1. `## 中文`, a short release summary, `### 下载`, and `### 重点更新`.
2. A brief overview sentence under `### 重点更新`, then `#### ✨ 新功能`,
   `#### ⚡ 改进`, `#### 🛠 修复`, and `#### 🔌 插件需要的新宿主能力`;
   omit categories with no changes.
3. `### 升级说明` and `### 兼容性与已知问题`.
4. A comparison link from the previous stable tag to the new tag.
5. `## English`, a short release summary, `### Downloads`, and `### Highlights`.
6. A matching overview under `### Highlights`, then `#### ✨ New features`,
   `#### ⚡ Improvements`, `#### 🛠 Fixes`, and
   `#### 🔌 New host capabilities that plugins need`; omit the same empty
   categories.
7. `### Upgrade instructions` and `### Compatibility and known issues`.
8. The equivalent English comparison link.
9. At the very bottom, `### 🙌 感谢贡献者` followed by `### 🙌 Contributors`, with
   equivalent contributor names or GitHub profile links in both languages.

The download sections cover the project page, both macOS architectures,
Windows x64, and the complete Release Assets page. Use versioned asset URLs
that match the packaging workflows. Upgrade instructions cover macOS DMG,
Homebrew, and Windows. The compatibility section must include the Gatekeeper
note, plus platform preview or signing limitations only when they actually
apply to that version.

## User-facing writing checklist

- Lead with the result: “启动项目更快”“终端输出更流畅”“打开文件不再反复报错”.
- Replace implementation descriptions with the visible effect on editing,
  running, debugging, Git, databases, or updates.
- Keep each bullet to one idea and one sentence; combine related fixes when the
  user impact is the same.
- Use everyday words. If a technical term is unavoidable, add a short
  explanation the first time it appears.
- Do not claim performance numbers, compatibility, security, or fixes unless
  the target commit and release checks verify them.
- Include the Gatekeeper recovery instructions as a small, actionable note:

  Chinese: “如果 macOS 提示无法打开 Lithe.app，请在‘应用程序’中按住 Control
  点按应用并选择‘打开’；如果仍被阻止，可在终端执行
  `xattr -dr com.apple.quarantine /Applications/Lithe.app`。仅对可信来源的应用使用。”

  English: “If macOS says it cannot open Lithe.app, Control-click it in
  Applications and choose Open. If it is still blocked, run
  `xattr -dr com.apple.quarantine /Applications/Lithe.app` in Terminal. Use
  this only for an app from a source you trust.”

Use [the reusable release template](../../../docs/releases/TEMPLATE.md) as the
formatting source of truth. Copy it to `docs/releases/v<version>.md`, replace
all placeholders, and remove its authoring comment. Previous releases are only
factual references; do not inherit their structure or stale claims.

Keep change bullets as single Markdown source lines with no nested lists. Aim
for roughly 40 Chinese characters or 20 English words when practical; this is
a writing target, not a display-width guarantee. Put the platform first only
when a change is platform-specific. Group by new capability, improvement, or
fix, not by implementation layer. Credit verified contributors together at
the bottom; optional per-item attribution must be verified and stay concise.
Do not copy another project's features, identities, or compatibility claims.
Run `node scripts/release/notes/validate-stable-release-notes.mjs docs/releases/v<version>.md`
before committing the notes.

## Contributors

- Add a contributor list at the bottom of every stable release description,
  after the English comparison link.
- Build the list from the commits and merged pull requests between the
  previous stable tag and the new tag. Verify names and profile links against
  GitHub before publishing; do not infer identities from an email address.
- Include human contributors who made code, documentation, design, testing, or
  release work relevant to the version. Exclude automation accounts such as
  `github-actions[bot]` unless the release explicitly needs to credit them.
- Keep the list short and readable. Do not include a raw commit log or every
  incidental merge author.
- Use the same people and links in the Chinese and English sections. If no
  human contribution can be verified for a release, write a brief equivalent
  sentence instead of leaving the section empty.

## Validate before publishing

- For a desktop release, confirm that "Sync Viva before a desktop release"
  allows continuing: the release target commit pins the head of fork `main`,
  and fork `main` contains upstream `main`, or the user's decision to skip
  the sync is recorded in the release report.
- For a desktop release, confirm that the plugin capability category follows
  “Trace the host capabilities that plugins need”: every capability version
  and host method the release adds for a plugin has a bullet naming the
  plugin repository and version.
- Confirm that the version follows “Choose the version number” when compared
  with the previous published version, that the filename is exactly
  `docs/releases/v<version>.md`, and that the file is non-empty.
- Check that Chinese and English describe the same release and that download
  filenames match the artifacts produced by both platform workflows.
- Check the comparison range, current platform requirements, bundled tools,
  signing status, updater availability, and known issues against the target
  commit and release configuration.
- For a desktop release, check the in-app update feed it publishes: the
  `update-feed` job of `desktop-release.yml` runs
  `scripts/ci/desktop-release/publish-update-feed.sh` once the release holds
  the packages. The repository needs the Actions secret `VIVA_UPDATE_KEY`, the
  Ed25519 private key from `viva update-keygen`, which only that job receives
  and which is never committed. It also needs the variable
  `LITHE_UPDATE_PUBLIC_KEYS`, the matching public keys separated by commas,
  which every package carries. One of those public keys belongs to a backup
  private key kept offline, outside GitHub. A lost key is replaced by the
  backup. A leaked key must be removed from the variable and followed by a
  release signed with the remaining key, because clients accept any key they
  carry and adding a key does not revoke one. Without the secret the job
  publishes nothing and installed copies are not offered the release; without
  the variable the packages cannot check for updates at all. The update dialog shows
  `docs/releases/v<version>.md` as what the update changes, so the notes must
  read well there too. A feed that already offers a later version is left as
  it is. When the feed rules change after a release (for example which clients
  get a patch), dispatch `desktop-release.yml` with that release's `version` and
  `feed_only` on: it builds and uploads nothing but signs the feed again from
  the published packages with the current script. It is a publication like any
  other and needs the user's explicit request. See
  `.agents/notes/implemented/feature/2026-11-15-desktop-update-channels-and-dialog.md`.
- For a desktop release, confirm that the published release is marked Latest
  on GitHub. The `release` job of `desktop-release.yml` marks it Latest
  unless a published desktop release has a higher version, so that
  `releases/latest` and the README download links lead to it. Never pass
  `--latest=false` for the release of the highest desktop version.
- Run `actionlint` after changing a GitHub Actions workflow. Run any focused
  packaging or manifest checks required by `develop-lithe` for other release
  changes.

Creating tags, pushing commits, dispatching workflows, or editing a live GitHub
Release changes external state. Perform those actions only when the user has
explicitly requested them. Preparing and validating the local release artifact
does not authorize publication.
