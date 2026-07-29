# Lithe Design QA — Git Workspace Refinement

## Evidence

- Source visual truth: `/var/folders/r0/qpfjznh96yl028rd750kf5q80000gn/T/codex-clipboard-224a4d2e-d22b-4e22-b964-480b011c87be.png`
- Supporting workbench source: `/var/folders/r0/qpfjznh96yl028rd750kf5q80000gn/T/codex-clipboard-0e9ed4b5-cfe2-43b2-b96f-fb04688ce027.png`
- Implementation: `/Users/lick/code/my-code/building-project/Lithe-IDEA/dist/Lithe.app`
- Implementation screenshot: `design-qa-artifacts/implementation-git-final.png`
- Viewport: implementation 1280 × 768 px; source normalized to 1280 × 768 px
- State: dark appearance; Commit sidebar active; README open; Git Log visible; `main` selected; multi-file commit selected
- Full-view comparison: `design-qa-artifacts/comparison-git-final.png`
- Focused Git comparison: `design-qa-artifacts/comparison-git-final-focus.png`

## Findings

No actionable P0, P1, or P2 findings remain.

- [P3] The reference contains a larger secondary tool icon inventory.
  Location: left and right activity rails.
  Evidence: IntelliJ displays debugger, database, terminal, plugin, and service icons; Lithe keeps only Project, Commit, Search, and Git Log.
  Impact: visual chrome is lighter, but the confirmed product workflows remain fully reachable.
  Fix: add tool icons only when their real features enter scope; do not add decorative inactive controls.

## Required Fidelity Surfaces

- Fonts and typography: IntelliJ uses JetBrains UI and its editor font; Lithe intentionally uses native SF Pro and SF Mono. Relative hierarchy, compact row height, truncation, and monospaced code treatment match the normalized reference.
- Spacing and layout rhythm: the window now matches the reference hierarchy—compact integrated top bar, rounded top Commit/editor surfaces, matching top-to-bottom split, and a bottom Git panel with branch, timeline, files, and detail columns.
- Colors and visual tokens: near-black surfaces, low-contrast dividers, graphite selections, blue active rows, green graph nodes, warning status colors, and muted secondary text align with the source.
- Image and icon fidelity: the source contains no product imagery. Lithe uses crisp native SF Symbols as the closest macOS icon system instead of copied IntelliJ assets.
- Copy and content: Lithe branding and real repository content replace IntelliJ-specific project data while preserving the same information density and labels where useful.

## Patches Made During This QA Pass

- Removed the extra macOS safe-area titlebar offset from the workbench.
- Matched the top editor/Commit region and bottom Git panel proportions to the reference.
- Top-aligned the branch tree and commit-file content instead of vertically centering them.
- Rebalanced the Git three-column widths.
- Added branch selection and searchable real commit history.
- Added grouped, collapsible directory rows for multi-file commit contents.
- Verified commit selection, commit search, branch filtering, file details, line numbers, and panel visibility in the signed native app.
- Rebuilt and recaptured the App Bundle after the final fixes.

## Implementation Checklist

- [x] Commit sidebar composition and realistic repository changes
- [x] Current branch, local/remote references, and tag groups
- [x] Searchable commit timeline and selected-row state
- [x] Multi-file directory tree and commit detail area
- [x] Integrated title bar, rounded panels, line-number gutter, and compact editor chrome
- [x] Full-view and focused side-by-side comparison
- [x] Debug build, Release build, Info.plist, and code-sign verification

## Follow-up Polish

- Expand the activity rails only as real product capabilities are implemented.
- Add richer merge lanes when testing against repositories with non-linear history.

final result: passed
