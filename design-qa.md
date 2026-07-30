# Lithe Settings QA

## Evidence

- Visual direction: existing Lithe/IDEA-style tool-window design system.
- General screenshot: `design-qa-artifacts/settings-general-final.png`
- Editor screenshot: `design-qa-artifacts/settings-editor-final.png`
- Terminal screenshot: `design-qa-artifacts/settings-terminal-final.png`
- Viewport: 760 x 520 Settings sheet inside the packaged macOS application.
- State: General, Editor, and Terminal categories captured in dark mode.

## Full-View Comparison

- The sheet follows Lithe's established compact dark tool-window hierarchy: 44-point title bar, 190-point category rail, unframed content area, and 50-point action footer.
- Category selection, group boundaries, controls, and footer actions remain aligned without clipping at the application's minimum window size.
- The Settings sheet is available from both the Welcome screen via `Command-,` and the workbench activity rail.

## Focused Comparison

- Typography: 12-14 point system text matches existing tool-window density, with a 20-point page title and no wrapping or truncation.
- Spacing: category rows, group padding, control alignment, and footer actions use consistent 3/8/13/16/24-point rhythm.
- Colors: existing Lithe window, sidebar, divider, selection, primary, and secondary tokens are used throughout.
- Image and icon fidelity: native SF Symbols are used for settings categories and actions; no placeholder or handcrafted assets are present.
- Copy: labels describe actual behavior and expose units for font size, delay, and indentation.

## Functional Verification

- `Command-,` opens Settings from Welcome.
- The left activity-rail gear opens Settings from a project.
- Auto-save reveals its delay picker and persists the selected `0.5 seconds` value after restart.
- Editor font size persisted at `14 pt`; Tab width persisted at `2 spaces`.
- Code Vision hid immediately when disabled and returned when restored.
- Default shell persisted as `bash` after restart.
- Restore Defaults reset auto-save, font size, Tab width, Code Vision, and shell across all categories.
- Production build, code signing, and `Info.plist` validation pass.

## Findings

- No actionable P0, P1, or P2 issues remain.
- Auto-save file writing was not exercised against a user project during UI QA to avoid modifying user content; scheduling and save code paths compile and are connected to editor change events.

## Patches Since Previous QA

- No production-code patch was required during final acceptance.
- Replaced the locked-screen blocker with captured General, Editor, and Terminal evidence.

## Git Change Kinds QA

### Evidence

- Test repository: `/private/tmp/lithe-diff-status-qa.EkGXNH`
- Change-list screenshot: `design-qa-artifacts/git-change-kinds.jpeg`
- Moved-file Diff screenshot: `design-qa-artifacts/git-moved-diff.jpeg`
- Added-file Diff screenshot: `design-qa-artifacts/git-added-diff.jpeg`
- Repository state: one added, one modified, one deleted, and one moved Java file.

### Functional Verification

- Added files use a green plus treatment and an `ADDED` Diff badge; the left side is an empty file and the right side contains the added source.
- Modified files use an amber pencil treatment and a `MODIFIED` Diff badge with the textual change rendered.
- Deleted files use a red minus treatment with a struck-through filename and a `DELETED` Diff badge; the right side is an empty file.
- Moved files use a blue arrow treatment and show `oldName -> newName`; the Diff header preserves both the original and destination paths.
- The NUL-delimited porcelain parser preserves paths containing spaces and consumes both path records emitted by Git for rename and copy changes.

### Findings

- No actionable P0, P1, or P2 issues remain.
- The moved fixture has unchanged content, so its Diff correctly reports zero textual differences while retaining the path transition.

## Added And Deleted Single-File Diff QA

### Evidence

- Source visual truth: `/var/folders/r0/qpfjznh96yl028rd750kf5q80000gn/T/codex-clipboard-c9f90dad-da89-4f91-abb8-7503f9ae02d7.png` and `/var/folders/r0/qpfjznh96yl028rd750kf5q80000gn/T/codex-clipboard-ec1475ac-994f-42f9-80c0-8afeaca2fbe4.png`.
- Added implementation: `design-qa-artifacts/git-added-single-file.jpeg`.
- Deleted implementation: `design-qa-artifacts/git-deleted-single-file.jpeg`.
- Combined comparison: `design-qa-artifacts/git-single-file-comparison.jpeg`.
- Viewport: 1280 x 768 packaged macOS application in dark mode.
- State: untracked added Java file and staged deleted Java file.

### Full-View Comparison

- Added and deleted files now use the full Diff width instead of reserving an empty comparison pane.
- Added source lines use a full-width green treatment; deleted source lines use a full-width red treatment.
- Modified files were regression-tested and retain the side-by-side repository/index/current-version comparison.

### Focused Comparison

- Typography: monospaced source, compact line numbers, status badges, and toolbar labels retain the established Lithe density.
- Spacing: the single version header, hunk header, line-number gutter, change marker, and source text align without a center gutter.
- Colors: semantic green/red backgrounds, markers, and line numbers follow the source references and existing Lithe theme tokens.
- Image and icon fidelity: native SF Symbols remain consistent with the rest of the macOS application; no new raster assets are required by this code editor surface.
- Copy: `Single file`, `Added version`, and `Deleted version` describe the actual rendering mode without referring to a nonexistent empty pane.

### Findings

- No actionable P0, P1, or P2 issues remain.
- The reference screenshots use different project content and viewport proportions; comparison is based on the matching Diff state and component region.

### Patches Since Previous QA

- Added a dedicated full-width renderer for added and deleted files.
- Preserved the side-by-side renderer for modified, moved, and copied files.

## Flexible Commit Message QA

### Evidence

- Source visual truth: `/var/folders/r0/qpfjznh96yl028rd750kf5q80000gn/T/codex-clipboard-cc6ccf88-1377-4b8a-b5f2-c2309f37144c.png`.
- Implementation screenshot: `design-qa-artifacts/commit-message-multiline.jpeg`.
- Focused comparison: `design-qa-artifacts/commit-message-flex-comparison.jpeg`.
- Viewport: 1280 x 768 packaged macOS application in dark mode.
- State: Commit tool window with seven lines of commit text and its internal scrollbar active.

### Full-View Comparison

- The Commit message editor now consumes the flexible space between the Amend row and action row.
- The surrounding change list, buttons, staged count, and tool-window boundaries remain aligned.
- The Commit area can use all height left after the required 120-point minimum change-list height; the previous 320-point cap is removed.

### Focused Comparison

- Typography: commit text and placeholder retain the existing 12.5-point system style without clipping.
- Spacing: the editor keeps the original inset, border, radius, and eight-point stack rhythm while expanding vertically.
- Colors: existing editor, divider, primary, and secondary theme tokens are unchanged.
- Image and icon fidelity: this native editor requires no image assets; existing SF Symbols remain unchanged.
- Copy: the `Commit Message` placeholder returns after clearing the editor.

### Functional Verification

- Seven lines of text were entered successfully and the native editor exposed its internal scrollbar.
- Clearing the editor restored the placeholder and disabled Commit actions.
- SwiftUI's accessibility driver disconnected when synthesizing a native divider drag; the sizing path was therefore verified through the uncapped geometry calculation and the rendered flexible `TextEditor`, not a recorded automated drag gesture.

### Findings

- No actionable P0, P1, or P2 issues remain.

### Patches Since Previous QA

- Replaced the content-sized, four-line `TextField` with a flexible scrolling `TextEditor`.
- Removed the 320-point Commit-area maximum while preserving the minimum list and editor heights.

final result: passed
