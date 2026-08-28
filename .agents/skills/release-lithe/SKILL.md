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
- Keep user-facing language focused on outcomes. Do not publish a raw commit or
  pull-request list as the release description.

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

The download sections cover the project page, both macOS architectures,
Windows x64, and the complete Release Assets page. Use versioned asset URLs
that match the packaging workflows. Upgrade instructions cover macOS DMG,
Homebrew, and Windows. Compatibility sections include platform preview or
signing limitations only when they actually apply to that version.

Use the most recent stable file under `docs/releases/` as the formatting
reference, but verify every statement and URL for the new version instead of
copying stale details.

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
