# Windows UI parity contract

This document is the implementation-time contract for the WinUI 3 workbench.
It exists because Windows rendering will be checked only after the feature work
is complete. It does not require a Windows machine and must be kept beside the
WinUI source instead of relying on memory or a late screenshot comparison.

## What parity means

WinUI does not need to copy AppKit controls pixel-for-pixel. It must preserve the
same information hierarchy, command discoverability, state feedback, keyboard
focus order, and relative layout. Differences that are intentional because of
Windows conventions (title bar, native dialogs, file picker, and system menu)
must be recorded as platform adaptations.

The following macOS surfaces are the reference set:

| Surface | WinUI entry | Required states |
| --- | --- | --- |
| Welcome/workspace | `MainWindow` welcome and workspace commands | no project, opening, invalid path, loaded, close with dirty files |
| Explorer/editor | left `TreeView`, editor `TabView`, editor gutter | empty, loading, dirty, external conflict, saved, missing file |
| Search/replace | Search tab and project-replace dialog | no query, loading, no results, partial selection, stale preview, partial failure |
| Git/Changes | Git tab and Changes list | clean, staged, unstaged, loading, command failure, operation in progress |
| Git conflict | checkout/integration conflict dialogs | blocked paths, smart stash, Shelf, force/cancel, restore conflict |
| Diff/history | Diff tab and Local History tab | empty, selected file, hunk actions, deleted file, restore-before-write |
| Shelf/session | Shelves tab and persisted workbench state | create, restore, failure retained, reopened workspace, invalid saved path |
| Settings | settings dialog | theme, language, persistence, update state, error |

## Tokens and layout rules

`Sources/Lithe/Theme/LitheTheme.swift` is the macOS source of truth. The WinUI
equivalents are in `windows/winui/App.xaml` under the `Lithe*` resource keys.
Use those resources for new surfaces. In particular, use the shared row/tab/
toolbar/status metrics and the window/sidebar/editor/raised background layers.

New XAML should follow these rules:

* Use `Grid` rows and columns for the workbench structure; do not place controls
  with absolute coordinates or negative margins.
* Give resizable panes a meaningful `MinWidth`/`MinHeight`, and use star sizing
  for the remaining space. Text that can grow must have wrapping or character
  ellipsis explicitly set.
* Keep the hierarchy `window -> sidebar/editor/tool window -> feature view`.
  A feature view owns its empty/loading/error state and does not silently alter
  another feature's layout.
* Every interactive control has a visible label, tooltip, or
  `AutomationProperties.Name`, and every destructive operation has a cancel
  path and a confirmation state.
* Chinese translations must fit the same layout. Do not use a translated string
  as a width constraint; constrain the control and allow wrapping/trimming.

## Development gate before Windows rendering

For each surface, the implementation is considered ready for final Windows
verification only when the source review can answer all of these questions:

1. Where is the macOS command represented in WinUI?
2. Which feature-model state drives each visible state?
3. What does the user see on cancellation, stale results, and failure?
4. What is the keyboard focus order and the default action?
5. Which dimensions and colors come from the shared resource tokens?
6. Which differences are intentional Windows adaptations?

The macOS screenshots and this matrix are the review evidence. A Windows build
and rendered UI pass remain the final acceptance step and are intentionally
outside this document's development-only checks.

