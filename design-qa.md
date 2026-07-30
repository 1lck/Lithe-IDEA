# Lithe Adaptive Pane Layout QA

## Evidence

- Source visual truth: `/var/folders/r0/qpfjznh96yl028rd750kf5q80000gn/T/codex-clipboard-6e49ec9e-1c72-4bc6-a5cb-611a266d3f5d.png`
- Additional reported state: `/var/folders/r0/qpfjznh96yl028rd750kf5q80000gn/T/codex-clipboard-e9a19764-215f-4cfc-b069-58e22649dbe0.png`
- Implementation: `/Users/lick/code/my-code/building-project/Lithe-IDEA/dist/Lithe.app`
- Implementation screenshot: `design-qa-artifacts/adaptive-layout-fixed.jpeg`
- Full-view comparison: `design-qa-artifacts/adaptive-layout-comparison.jpg`
- Viewport: source normalized from 1440 x 864 to 1280 x 768; implementation 1280 x 768
- State: dark appearance, Changes sidebar active, short Swift side-by-side Diff open, Git tool window hidden
- Focused comparison: not required because the defect affects the macro position and width of both complete content regions; text and controls remain readable in the full-view comparison.

## Findings

- [Resolved P1] Short Changes and Diff content moved toward the vertical center after pane resizing.
  - Cause: both two-axis ScrollViews left the content height unconstrained, allowing macOS to place the short ideal-size stack within the resized viewport.
  - Fix: bind each scroll content container to at least the current GeometryReader height with top-leading alignment.
- [Resolved P1] Diff rows could retain their ideal content width instead of filling the resized editor.
  - Cause: the LazyVStack used only a minimum width inside a horizontally scrolling container, and individual rows did not explicitly expand.
  - Fix: bind the diff stack to the current viewport width (with a 980-point horizontal-scroll floor) and make information and code rows fill that width.

No actionable P0, P1, or P2 findings remain in the rendered comparison.

## Required Fidelity Surfaces

- Fonts and typography: unchanged; SF Pro and monospaced Diff text retain existing sizes, weights, and line heights.
- Spacing and layout rhythm: Changes now starts eight points below its toolbar and Diff starts directly below the version header at every rendered size.
- Colors and tokens: unchanged; selection, addition, removal, editor, divider, and sidebar tokens remain consistent.
- Image and icon fidelity: no raster product imagery is used; existing SF Symbols remain aligned and sharp.
- Copy and content: no labels changed; paths, counts, version names, and actions remain visible.

## Patches

- Added GeometryReader-backed width and minimum-height constraints to the Changes list.
- Added current-width and minimum-height constraints to Diff content.
- Expanded information rows and paired code rows to the full computed Diff width.

## Verification

- Isolated-cache Debug build: passed
- Production package and ad-hoc signing: passed
- Packaged app render with short Changes and Diff data: passed
- Combined source/implementation comparison: passed
- Automated pointer drag replay: unavailable because the macOS Computer Use service returned `noWindowsAvailable`; initial and repaired rendered states plus responsive geometry constraints were verified.

final result: passed
