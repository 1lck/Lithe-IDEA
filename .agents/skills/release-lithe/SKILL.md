---
name: release-lithe
description: Prepare and validate stable Lithe release notes and publishing workflows. Use when drafting docs/releases files, cutting a stable version, publishing a GitHub Release, or changing stable release automation.
---

# Release Lithe

Apply this Skill after `develop-lithe` for stable releases. Preview releases
keep their existing workflow unless the task explicitly includes them.

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
2. Optional product-area groupings when they make the changes easier to scan.
3. `### 升级说明` and `### 兼容性与已知问题`.
4. A comparison link from the previous stable tag to the new tag.
5. `## English`, a short release summary, `### Downloads`, and `### Highlights`.
6. English counterparts for any optional product-area groupings.
7. `### Upgrade instructions` and `### Compatibility and known issues`.
8. The equivalent English comparison link.
9. At the very bottom, `### 贡献者` followed by `### Contributors`, with
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

Use the most recent stable file under `docs/releases/` as the formatting
reference, but verify every statement and URL for the new version instead of
copying stale details.

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

- Confirm the version uses `MAJOR.MINOR.PATCH`, the filename is exactly
  `docs/releases/v<version>.md`, and the file is non-empty.
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
