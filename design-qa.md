# Lithe Bottom Navigation and Activity Bar QA

## Evidence

- Source visual truth: `/var/folders/r0/qpfjznh96yl028rd750kf5q80000gn/T/codex-clipboard-07bd22de-6541-44cc-8d0d-ecea3e9abf98.png`
- Implementation screenshot: `design-qa-artifacts/bottom-breadcrumb-activity-final.png`
- Full-view comparison: `design-qa-artifacts/bottom-breadcrumb-activity-comparison.jpg`
- Viewport: 1280 x 768, dark mode.
- State: `Calculator.java` open with Java Code Vision visible and no bottom tool window expanded.

## Full-View Comparison

- The file hierarchy has moved from the editor header to the bottom status bar, matching IDEA's full-width navigation placement.
- Terminal and Git appear as compact bottom-aligned activity buttons in the left rail instead of large filled tool buttons.
- The editor gains the vertical space previously occupied by the upper breadcrumb row.

## Focused Comparison

- Typography: path labels use compact 11-point system text with the same muted hierarchy as the reference; labels remain single-line.
- Spacing and layout: the status bar is 26 points high, separators are tightly spaced, and the right-side line/column and encoding metadata remain fixed.
- Colors: secondary path segments use Lithe's muted foreground; the active Java method and tool indicator use the existing accent token.
- Image and icon fidelity: native SF Symbols provide file, class, method, Terminal, Git, status, and chevron icons; no placeholder or handcrafted assets are used.
- Copy and content: the bar displays the real relative path, enclosing Java class/method, caret position, UTF-8, indentation, Git change count, and repository status.
- Interaction: path segments select the project tool window, class/method segments navigate to declarations, Terminal opens the PTY tool window, and Git opens the Git Log tool window.

## Findings

- No actionable P0, P1, or P2 mismatch remains for the requested bottom path and left-side Git/Terminal controls.
- The reference contains additional third-party/problem tool icons that are outside the currently implemented Lithe feature set; no inert placeholders were added.

## Patches Since Previous QA

- Moved breadcrumbs from the editor header into the bottom status bar.
- Added caret-aware Java class and method breadcrumbs.
- Added clickable navigation behavior to file and symbol path items.
- Added responsive detailed and compact status groups.
- Restyled Terminal and Git activity buttons with a narrow IDEA-style selection indicator.

final result: passed
