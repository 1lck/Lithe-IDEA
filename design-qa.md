# Lithe Design QA

## Evidence

- Source visual truth: `/var/folders/r0/qpfjznh96yl028rd750kf5q80000gn/T/codex-clipboard-0e9ed4b5-cfe2-43b2-b96f-fb04688ce027.png` and `/var/folders/r0/qpfjznh96yl028rd750kf5q80000gn/T/codex-clipboard-29a4ee85-d0a4-4105-a962-0de14acaf39c.png`
- Normalized source captures: `design-qa-artifacts/reference-workbench.png` and `design-qa-artifacts/reference-welcome.png`
- Implementation captures: `design-qa-artifacts/implementation-workbench-final.png` and `design-qa-artifacts/implementation-welcome.png`
- Full-view comparison: `design-qa-artifacts/comparison-workbench-final.png` and `design-qa-artifacts/comparison-welcome.png`
- Focused comparison: `design-qa-artifacts/comparison-workbench-focus.png`
- Viewport: implementation 1280 × 768 px; source captures normalized to the same viewport for comparison
- State: dark appearance; project opened; project tree visible; README selected in the editor. Welcome screen compared separately with one recent project.

## Findings

No actionable P0, P1, or P2 findings remain.

- [P3] Editor navigation can become denser in a later iteration.
  Location: editor gutter and project tree.
  Evidence: IntelliJ shows line numbers and slightly denser tree rows; Lithe currently prioritizes a stable native text surface and larger hit targets.
  Impact: minor loss of orientation in long files, without blocking browsing, editing, saving, or Git review.
  Fix: add a non-overlapping AppKit line-number ruler and an optional compact-density setting after the core workflow is stable.

## Required Fidelity Surfaces

- Fonts and typography: the reference uses JetBrains UI typography; Lithe intentionally uses native SF Pro and SF Mono to remain a macOS-first product. Hierarchy, weights, truncation, and code readability are consistent at the target viewport.
- Spacing and layout rhythm: the top toolbar, activity rail, project sidebar, tabs, editor, and status bar preserve the reference composition. The wider 360 pt sidebar is an intentional readability adjustment for paths.
- Colors and visual tokens: both states use a neutral near-black hierarchy, low-contrast separators, muted secondary text, and blue selection/accent states. Contrast is sufficient in the inspected states.
- Image quality and asset fidelity: neither screen relies on product imagery. Native SF Symbols are sharp at display scale and are the appropriate macOS icon library for Lithe's own brand.
- Copy and content: IntelliJ product and plugin copy was replaced with Lithe-specific project, review, search, Git, and explicit Run-placeholder language. The reduced welcome navigation matches the confirmed scope.

## Intentional Deviations

- The toolbar and activity rail are simpler because test, debugger, terminal, plugins, and language-service features are explicitly outside the current scope.
- The welcome screen contains only Projects and Open because New Project, Clone Repository, Customize, Plugins, and Learn are not part of the MVP.
- Lithe uses native macOS controls and branding instead of copying IntelliJ assets or trade dress.

## Patches Made Since the Previous QA Pass

- Removed the custom line-number ruler that obscured editor contents.
- Top-aligned the project tree and widened the sidebar.
- Fixed Git path decoding for Chinese filenames.
- Added a distinct empty-diff state instead of an indefinite loading indicator.
- Removed nonfunctional settings affordances.
- Excluded `.DS_Store` and internal `design-qa-artifacts` from the workspace tree.
- Rebuilt and recaptured the signed app bundle after the fixes.

## Implementation Checklist

- [x] Welcome screen composition and recent-project interaction
- [x] IDEA-inspired workbench hierarchy with Lithe branding
- [x] Project tree, tabs, editor, save, search, and external-change states
- [x] Git changes, side-by-side diff, stage, unstage, discard, and commit states
- [x] Native dark-theme visual consistency at 1280 × 768
- [x] Final build, bundle signing, and visual recapture

## Follow-up Polish

- Add line numbers without reducing editor reliability.
- Consider an optional compact project-tree density after real-project feedback.

final result: passed
