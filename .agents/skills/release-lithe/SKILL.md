---
name: release-lithe
description: Choose version numbers for the Lithe app and Lithe plugins, and prepare and validate stable Lithe release notes and publishing workflows. Use when deciding a version number, drafting docs/releases files, cutting a stable version, publishing a GitHub Release, or changing release automation.
---

# Release Lithe

Apply this Skill after `develop-lithe`. The version rules in the first section
apply to every release of the Lithe app and of every Lithe plugin. The other
sections apply to stable app releases; preview releases keep their existing
workflow unless the task explicitly includes them.

## Choose the version number

Every release uses a `MAJOR.MINOR.PATCH` version. This covers stable app
releases, `desktop-v*` desktop prereleases, and plugins, including the
community plugins in the Lithe-IDEA organization. Compare the release with the
previous published version of the same artifact, stable or prerelease. Then
increment the part that matches the most significant change in the release:

| Part | Increment when the release contains | Compatibility | From 1.2.3 |
| --- | --- | --- | --- |
| PATCH | Only backward-compatible bug fixes and small improvements | Fully compatible; users upgrade without doing anything | 1.2.4 |
| MINOR | New features, with every existing feature unchanged | Backward compatible; nothing users rely on changes | 1.3.0 |
| MAJOR | At least one breaking change | Not compatible with the previous version; users may need to change something | 2.0.0 |

A change is breaking when a user of the previous version cannot upgrade
without doing something, or loses something they relied on.

For the app, these changes are breaking:

- Removing or renaming a user-visible feature, command, setting, or keyboard
  shortcut.
- Dropping a plugin contract or plugin API version that installed plugins use,
  so that those plugins stop loading.
- Changing the format of settings, project state, or other stored data without
  migrating the previous version's data automatically.
- Raising the minimum supported operating system version, or dropping a
  platform or CPU architecture.

For a plugin, these changes are breaking:

- Requiring a host or plugin contract version that hosts able to run the
  previous version do not support, so that those users can no longer install
  or update the plugin.
- Removing or renaming a feature, command, task, run entry, setting, or build
  option that the previous version declared.
- Changing a setting key or value format, so that values users saved are lost
  or read differently.
- Requiring an external program the previous version did not need, or a newer
  version of one it already ran.

Apply these rules to every version number:

- Versions below 1.0.0 follow the same table. Do not apply the semantic
  versioning exception for initial development: a breaking change to 0.y.z
  releases 1.0.0, not 0.(y+1).0.
- Incrementing MAJOR resets MINOR and PATCH to 0. Incrementing MINOR resets
  PATCH to 0.
- The version number does not say whether a release is a prerelease. Publish
  a release as a prerelease when no stable host can use it yet, whatever its
  number. Keep the plain number and the plain tag (`v<version>`, or
  `desktop-v<version>` for the desktop app), with no `-beta` or similar suffix.
- Never reuse a published version or publish a lower one. A published package
  is never modified; every change ships as a new version. The only exception
  is a version reset that the user explicitly requests for one artifact:
  delete all of its GitHub Releases and tags, remove all of its versions from
  the Lithe Store index, and publish again from 0.0.1. Never reset a version
  on your own initiative.
- A MAJOR release lists every breaking change, together with what users must
  do, in its upgrade or compatibility notes.

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

## Use the bilingual structure

Write Simplified Chinese first and English second, separated by `---`. Keep the
two sections equivalent in meaning. Use these literal required headings and
this order:

1. `## 中文`, a short release summary, `### 下载`, and `### 重点更新`.
2. A brief overview sentence under `### 重点更新`, then `#### ✨ 新功能`,
   `#### ⚡ 改进`, and `#### 🛠 修复`; omit categories with no changes.
3. `### 升级说明` and `### 兼容性与已知问题`.
4. A comparison link from the previous stable tag to the new tag.
5. `## English`, a short release summary, `### Downloads`, and `### Highlights`.
6. A matching overview under `### Highlights`, then `#### ✨ New features`,
   `#### ⚡ Improvements`, and `#### 🛠 Fixes`; omit the same empty categories.
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

- Confirm that the version follows “Choose the version number” when compared
  with the previous published version, that the filename is exactly
  `docs/releases/v<version>.md`, and that the file is non-empty.
- Check that Chinese and English describe the same release and that download
  filenames match the artifacts produced by both platform workflows.
- Check the comparison range, current platform requirements, bundled tools,
  signing status, updater availability, and known issues against the target
  commit and release configuration.
- Run `actionlint` after changing a GitHub Actions workflow. Run any focused
  packaging or manifest checks required by `develop-lithe` for other release
  changes.

Creating tags, pushing commits, dispatching workflows, or editing a live GitHub
Release changes external state. Perform those actions only when the user has
explicitly requested them. Preparing and validating the local release artifact
does not authorize publication.
