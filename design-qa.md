# Lithe Repeated Pane Resize QA

## Evidence

- Source visual truth (reported failure): `/var/folders/r0/qpfjznh96yl028rd750kf5q80000gn/T/codex-clipboard-258623c3-09ae-4d14-ac82-fb9e4b42fd9d.png`
- Implementation: `/Users/lick/code/my-code/building-project/Lithe-IDEA/dist/Lithe.app`
- Implementation screenshot: `design-qa-artifacts/nested-scroll-fixed.jpeg`
- Full-view comparison: `design-qa-artifacts/nested-scroll-comparison.jpg`
- Viewport: source normalized from 1440 x 864 to 1280 x 768; implementation 1280 x 768
- State: dark appearance, Changes sidebar active, short Swift side-by-side Diff open, Git tool window hidden
- Focused comparison: not required because the failure affects the complete Changes and Diff content frames and remains readable in the full-view comparison.

## Findings

- [Resolved P1] Repeated pane resizing could collapse Diff rows to their minimum intrinsic width while the editor frame remained full width.
  - Cause: a single two-axis SwiftUI ScrollView left both axes unbounded for LazyVStack measurement and could reuse a stale cross-axis layout after repeated geometry changes.
  - Fix: replace the two-axis scroll container with a horizontally scrolling outer container and a vertically scrolling inner container whose width and height are explicitly bound to the current geometry.
- [Resolved P1] The same two-axis measurement behavior could vertically center a short Changes list after resizing.
  - Fix: use the same nested-scroll structure so the vertical list always receives a bounded viewport and starts at its top edge.

No actionable P0, P1, or P2 findings remain in the rendered comparison.

## Required Fidelity Surfaces

- Fonts and typography: unchanged; SF Pro and monospaced Diff text retain their established sizes and weights.
- Spacing and layout rhythm: Changes begins below its toolbar; Diff rows span the complete review width directly below the version header.
- Colors and tokens: unchanged; editor, sidebar, divider, selection, addition, and removal tokens remain consistent.
- Image and icon fidelity: no raster product imagery is present; SF Symbols remain aligned and sharp.
- Copy and content: no labels changed; paths, counts, version titles, and Git actions remain visible.

## Patches

- Removed the combined vertical/horizontal ScrollViews from Changes and Diff.
- Added independent horizontal and vertical scroll layers with explicit live viewport dimensions.
- Kept LazyVStack inside a width-bounded vertical scroll context to preserve large-Diff efficiency without cross-axis layout collapse.

## Verification

- Isolated-cache Debug build: passed
- Production package and ad-hoc signing: passed
- Packaged app render and accessibility hierarchy: passed; both affected areas expose independent nested scroll containers
- Combined failure/implementation comparison: passed
- Automated pointer drag replay: unavailable because the macOS Computer Use service returned `noWindowsAvailable`; the failure-producing two-axis component structure has been removed rather than patched with additional frame modifiers.

final result: passed
