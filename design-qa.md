# Lithe Unified Acceptance QA

## Evidence

- App: `/Users/lick/code/my-code/building-project/Lithe-IDEA/dist/Lithe.app`
- Fixture: `/private/tmp/lithe-qa-fixture` on `feature/demo`, with one modified and two unversioned Swift files
- Viewport: 1280 x 768, dark appearance
- Git reference: `/var/folders/r0/qpfjznh96yl028rd750kf5q80000gn/T/codex-clipboard-224a4d2e-d22b-4e22-b964-480b011c87be.png`
- Diff reference: `/var/folders/r0/qpfjznh96yl028rd750kf5q80000gn/T/codex-clipboard-8f786a42-1ed9-40ea-918b-12888e38f50b.png`
- Git implementation: `design-qa-artifacts/lithe-git-log.jpeg`
- Diff implementation: `design-qa-artifacts/lithe-diff.jpeg`
- Git comparison: `design-qa-artifacts/git-log-comparison.jpg`
- Diff comparison: `design-qa-artifacts/diff-comparison.jpg`

## Acceptance Results

- Project tree context menus expose create, open, duplicate, rename, Finder, copy-path, refresh, and recoverable Trash operations.
- Project tree expansion survives workspace refreshes and filesystem-driven snapshots.
- Changes refresh automatically through filesystem events; no periodic polling was introduced.
- Modified files open an IDEA-style side-by-side diff with version labels, changed-line highlighting, word highlighting, difference navigation, whitespace options, stage, and discard actions.
- Top branch switcher supports search, checkout, create branch, and checkout revision.
- Git Log branch context menus expose create, compare, checkout for non-current local branches, update, push, and rename as applicable.
- Sidebar/editor, workbench/Git, Git refs/timeline, Git timeline/details, and Git files/metadata splits were dragged and remained usable.
- Git Log and Diff layouts were compared against the supplied IDEA references in combined images at the same viewport.

## Findings And Patches

- [Resolved P1] A non-current local branch did not expose Checkout in the Git Log context menu. Added the action and verified it appears for `main` while `feature/demo` is current.
- [Resolved P2] Refreshing the project snapshot collapsed expanded directories. Moved expansion state to the sidebar and retained it across the temporary loading state; verified `Sources` stays open after Refresh.
- [P3] Resize gutters remain deliberately low contrast until hover or drag, matching the quiet IDEA treatment. No action required.

## Visual Review

- Git workspace: pane hierarchy, Commit sidebar, reference tree, timeline, changed-files tree, commit metadata, dark tokens, and dense typography align with the source. The fixture has one commit, so the timeline is intentionally sparse.
- Diff review: toolbar hierarchy, two-column headers, line-number gutters, deletion/addition colors, word-level highlight, and transfer arrows align with the source. The fixture is shorter than the source file, so unused editor space is expected.
- No clipped controls, overlapping text, broken dividers, or unreadable active states were found at 1280 x 768.

## Verification

- `swift build --disable-sandbox` with isolated Swift and Clang module caches: passed
- Production package and ad-hoc signing through `scripts/package-app.sh`: passed
- Desktop interaction pass against the packaged app: passed
- Combined-image visual comparison: passed
- Remaining actionable P0/P1/P2 findings: none

final result: passed
