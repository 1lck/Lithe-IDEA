# Lithe Split Handle Stability QA

## Scope

- Shared component: `Sources/Lithe/Views/SplitHandleView.swift`
- Affected surfaces: workspace sidebar, workspace vertical split, Changes commit pane, Git Log reference/detail columns, Git Log files/detail rows
- Reported issue: pane boundaries repeatedly oscillate while dragging

## Root Cause

- `DragGesture` measured translation in the moving handle's local coordinate space.
- Resizing moved the handle and therefore moved that coordinate origin during the same gesture.
- Subsequent translation values fed the layout movement back into their own measurement, producing visible jitter across every consumer of the shared handle.

## Resolution

- Measure the shared drag gesture in the stable global coordinate space.
- Preserve existing per-pane start values, direction handling, minimum sizes, and maximum sizes.
- No consumer-specific patches were required.

## Verification

- All `SplitHandleView` consumers reviewed: passed
- Isolated-cache Debug build: passed
- Production package and ad-hoc signing: passed
- Swift formatting/diff validation: passed
- Live pointer drag: blocked because the Mac was locked and Computer Use could not unlock it

final result: blocked
