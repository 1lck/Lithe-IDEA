# Design QA: Windows Source Control diff

- Added-file reference: `D:/Downloads/document/xwechat_files/wxid_id17m8qt937c22_c153/temp/RWTemp/2026-08/1aede52250875b292d874992a7f6d5b7/f38120ff65bc487d72adb50de30e6dc7.png`
- Split modified-file reference: `D:/Downloads/document/xwechat_files/wxid_id17m8qt937c22_c153/temp/RWTemp/2026-08/1aede52250875b292d874992a7f6d5b7/2d6a05680ba07a8527dd10e69bdecacc.png`
- Native Windows added-file capture: `design-qa-artifacts/native-windows-added-diff.png`
- Native Windows modified-file capture: `design-qa-artifacts/native-windows-split-diff.png`
- Combined reference/implementation input: `design-qa-artifacts/native-reference-comparison.png`
- Native viewport: 1362 x 856, dark theme.

## Result

The working-tree diff now follows the reference hierarchy: file/status title, compact diff toolbar, explicit version header, blue hunk header, and semantic code body. The implementation keeps Lithe's native Windows chrome and design tokens while matching the reference's information architecture.

### Added file

- The untracked three-line fixture reports `+3 -0` in Source Control and `+3` on the file row.
- Selecting the file opens the diff surface, not a normal text editor or serialized patch.
- The header identifies `ADDED`, `WORKTREE`, and `Added version`.
- The hunk range is visible as `@@ -0,0 +1,3 @@`.
- All three source rows use the full-width added background with an added rail and independent line numbers.
- Side-by-side mode is disabled because a new file has no previous version.

### Modified file

- The left pane is labeled `Index version`; the right pane is labeled `Current version`.
- Both panes use independent line-number gutters and compact source streams.
- Removed content is red on the left and added content is green on the right.
- The center connector gutter is 28 px and shows curved transition bands with direction markers.
- The layout does not add fake blank code rows to the side that does not own a line.

### Interaction and native verification

- Verified in the running Tauri Windows application through native window capture and input.
- Clicking both untracked and tracked file rows opens the expected diff.
- Unified/side-by-side controls follow file type, and the whitespace control remains interactive.
- The temporary tracked-file change used for split verification was restored; the test repository was left with only the user's original untracked `c.txt`.

### Automated verification

- `bun test`: 51 passed, 0 failed.
- `bun run typecheck`: passed.
- `bun run lint -- ...`: passed for the changed files; existing unrelated repository warnings remain.

No actionable P0, P1, or P2 visual mismatch remains in the requested added-file and modified-file diff flows.

final result: passed
