# Lithe Commit Pane Vertical Resize QA

## Evidence

- User report: `/var/folders/r0/qpfjznh96yl028rd750kf5q80000gn/T/codex-clipboard-48cd0bf9-b2e6-495d-a8ee-cd3f541f9e1f.png`
- Packaged implementation: `/Users/lick/code/my-code/building-project/Lithe-IDEA/dist/Lithe.app`
- Implementation capture: `design-qa-artifacts/commit-resize-implementation.png`
- Combined source/implementation comparison: `design-qa-artifacts/commit-resize-comparison.jpg`
- State: 1280 x 768, dark appearance, Changes sidebar active, three changed files

## Findings

- [Resolved P1] The divider above the Commit controls was decorative and the Commit area was fixed at 124 points, so it could not be resized.
  - Replaced the fixed divider with the shared vertical `SplitHandleView`.
  - Dragging upward increases the Commit area; dragging downward decreases it.
  - Commit height is constrained to 124...320 points.
  - The changes list retains at least 120 points of usable height.
- [Verified] The packaged app exposes `Vertical pane resize handle` with the expected `Drag up or down to resize` help text.
- [Blocked QA] Computer Use could inspect the live packaged window but its coordinate drag operation returned `noWindowsAvailable`, so end-to-end pointer movement could not be recorded in this run.

## Verification

- Isolated-cache Debug build: passed
- Production package and ad-hoc signing: passed
- Live packaged-app inspection: passed
- Vertical resize handle presence and accessibility description: passed
- Static layout at default height: passed; controls remain visible without overlap
- Automated pointer drag up/down: blocked by the desktop automation driver

final result: blocked
