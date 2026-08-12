# Windows final validation handoff

Development is intentionally complete before Windows rendering is checked.
The remaining work is CI and interactive validation on the Windows VM/device;
these checks are not claimed by the macOS static verification.

## Final CI

Run `.github/workflows/ci-windows.yml` (or its equivalent) and require Rust,
C++/CTest, WinUI/MSBuild, boundary verification, and the WinUI static contract
check to pass. A failed build is a development defect, not a UI discrepancy.

## Interactive smoke path

Use a disposable workspace and a local Git repository. For every item, record
the expected state and any Windows-only deviation:

| Area | Preparation | Expected checks |
| --- | --- | --- |
| Workspace/session | Open a folder, close it, reopen it | invalid path filtering, project isolation, tabs, expanded folders and layout restore |
| Editor | Open/save two files, leave one dirty | tab selection, line/column status, external conflict keep/reload, close protection |
| Search | Search and replace in a small tree | case/word/regex/mask, preview selection, partial failure feedback |
| Git changes | Initialize repository and create staged/unstaged files | stage, unstage, discard, hunk actions, commit safety and Diff navigation |
| Branches | Create local branches and commits | checkout, branch create/rename/delete, pull strategy, merge/rebase preflight |
| Integration | Create a controlled conflict | conflict dialog, open Diff, filter blocked paths, rollback one file, retry/continue/abort/skip |
| Shelf/history | Make staged and working-tree edits | separate Shelf patches, restore failure retention, Local History Diff and restore-before-write |
| Workbench | Resize panes and switch tool windows | minimum sizes, DPI scaling, theme/language, keyboard focus and command palette |

Project compilation, Java/Maven execution, Run/Debug and breakpoints are
deliberately outside this phase and must not be used as a reason to fail the
first UI validation pass.

## Known platform adaptations

Windows title-bar treatment, native file picker, native confirmation dialog
chrome, system menu, and keyboard modifier names may differ from macOS. These
are expected adaptations. Information hierarchy, command availability,
feedback states, and relative pane layout should remain equivalent.

