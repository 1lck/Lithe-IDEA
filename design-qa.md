# Lithe Design QA — Git Workspace Refinement

## Evidence

- Source visual truth: `/var/folders/r0/qpfjznh96yl028rd750kf5q80000gn/T/codex-clipboard-224a4d2e-d22b-4e22-b964-480b011c87be.png`
- Supporting workbench source: `/var/folders/r0/qpfjznh96yl028rd750kf5q80000gn/T/codex-clipboard-0e9ed4b5-cfe2-43b2-b96f-fb04688ce027.png`
- Implementation: `/Users/lick/code/my-code/building-project/Lithe-IDEA/dist/Lithe.app`
- Implementation screenshot: unavailable for the current refinement pass because the Mac is locked
- Target viewport: 1440 × 900 px, dark appearance
- Target state: Commit sidebar active, source file open, bottom Git Log visible, current branch selected, first commit selected
- Full-view comparison evidence: blocked; the source image was opened, but the current implementation could not be captured
- Focused-region comparison evidence: blocked for the same reason

## Findings

- [P0] Current implementation cannot be visually verified while macOS is locked.
  Location: native Lithe window capture.
  Evidence: the Computer Use runtime returned `The Mac is locked and automatic unlock could not unlock it` on repeated capture attempts.
  Impact: layout, clipping, line-number placement, Git panel proportions, typography, colors, and interaction states cannot be truthfully accepted against the reference.
  Fix: manually unlock the Mac, relaunch `dist/Lithe.app`, capture the target Git state, create full-view and focused side-by-side comparisons, then fix all P0/P1/P2 differences.

## Implemented Since the Previous QA Pass

- Added real local/remote branch and tag discovery.
- Added a real 150-entry Git commit history with author, date, subject, decorations, and parent information.
- Added per-commit changed-file loading and commit details.
- Rebuilt the Commit sidebar with IDEA-like tabs, toolbar, grouped changes, staging checkboxes, Amend, commit message, and local commit actions.
- Added an IDEA-like bottom Git tool window with reference tree, searchable commit timeline, changed-file pane, and commit detail pane.
- Added rounded tool-window surfaces, denser top bar, branch context, updated dark tokens, and tighter editor chrome.
- Added a separate non-overlapping AppKit line-number gutter.
- Completed Debug and Release builds and verified the signed App Bundle.

## Implementation Checklist

- [x] Git data layer and real repository content
- [x] Commit sidebar layout and interactions
- [x] Bottom Git Log three-column layout and interactions
- [x] Workbench density, panel rounding, and line-number implementation
- [x] Debug and Release build verification
- [ ] Capture the current native Git state after macOS is unlocked
- [ ] Produce normalized full-view and focused comparisons
- [ ] Fix visible P0/P1/P2 differences and repeat capture

## Required Fidelity Surfaces

- Fonts and typography: pending visual comparison.
- Spacing and layout rhythm: pending visual comparison.
- Colors and visual tokens: pending visual comparison.
- Image and icon fidelity: SF Symbols are used as the native macOS icon library; rendered fidelity is pending visual comparison.
- Copy and content: real repository data is connected; truncation and density are pending visual comparison.

final result: blocked
