# Lithe Java Code Vision and Blame QA

## Evidence

- Code Vision source: `/var/folders/r0/qpfjznh96yl028rd750kf5q80000gn/T/codex-clipboard-bf3616cc-6767-4dd5-aa93-c8daa73b072f.png`
- Blame source: `/var/folders/r0/qpfjznh96yl028rd750kf5q80000gn/T/codex-clipboard-a74fbe52-4805-4b07-8e07-602f8457bac7.png`
- Commit-selection source: `/var/folders/r0/qpfjznh96yl028rd750kf5q80000gn/T/codex-clipboard-fa5fd580-6cf5-44da-a7aa-787efa8616dc.png`
- Code Vision implementation: `design-qa-artifacts/java-usages-final.png`
- Blame implementation: `design-qa-artifacts/java-blame-final.png`
- Full-view comparisons: `design-qa-artifacts/java-code-vision-comparison.jpg` and `design-qa-artifacts/java-blame-comparison.jpg`
- Viewport: 1280 x 768, dark mode.
- State: `Calculator.java` open in the Java fixture; Code Vision, usages, and Blame states captured separately.

## Full-View Comparison

- Java declarations show usage counts and the latest author directly after the declaration, matching the IDEA placement and subdued visual hierarchy.
- Blame expands the editor gutter into an aligned date-and-author column without shifting or covering source text.
- The bottom usages and Git Log tool windows follow the existing compact Lithe workbench layout while preserving the interaction shown by IDEA.

## Focused Comparison

- Typography: editor hints and Blame metadata use compact system/monospaced text with subdued contrast comparable to the references; no wrapping or truncation appears in the fixture.
- Spacing: Code Vision stays attached to declaration text; Blame rows track editor line height and scroll position.
- Colors: hints use secondary foreground colors; editor, gutter, selected commit, and tool-window surfaces remain consistent with Lithe's dark tokens.
- Assets: the feature uses native SF Symbols already established by Lithe; the references contain no custom imagery requiring replacement.
- Copy: `2 usages`, author name, dates, commit hash, and usage locations reflect real repository data.
- Interaction: clicking `2 usages` returned two `App.java` locations; clicking an author opened Blame; clicking a Blame row opened Git Log and selected commit `3da7d97` with its details.

## Findings

- No actionable P0, P1, or P2 mismatch remains for the requested Code Vision, Blame, and commit-jump flow.
- Dataset size differs from the IDEA screenshots, but the information structure and interaction are equivalent and use real fixture data.

## Patches Since Previous QA

- Added Java declaration Code Vision for usage counts and Git authors.
- Added project-wide Java occurrence indexing and JDT LS usage navigation.
- Added line-aligned Git Blame with directly interactive row buttons.
- Added line-specific accessibility labels for every Blame row.
- Added commit lookup, Git Log opening, selection, and auto-scroll.
- Prevented normal JDT LS stderr warnings from leaking into the visible usages status.

final result: passed
