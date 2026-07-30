# Lithe Settings QA

## Evidence

- Visual direction: existing Lithe/IDEA-style tool-window design system.
- General screenshot: `design-qa-artifacts/settings-general-final.png`
- Editor screenshot: `design-qa-artifacts/settings-editor-final.png`
- Terminal screenshot: `design-qa-artifacts/settings-terminal-final.png`
- Viewport: 760 x 520 Settings sheet inside the packaged macOS application.
- State: General, Editor, and Terminal categories captured in dark mode.

## Full-View Comparison

- The sheet follows Lithe's established compact dark tool-window hierarchy: 44-point title bar, 190-point category rail, unframed content area, and 50-point action footer.
- Category selection, group boundaries, controls, and footer actions remain aligned without clipping at the application's minimum window size.
- The Settings sheet is available from both the Welcome screen via `Command-,` and the workbench activity rail.

## Focused Comparison

- Typography: 12-14 point system text matches existing tool-window density, with a 20-point page title and no wrapping or truncation.
- Spacing: category rows, group padding, control alignment, and footer actions use consistent 3/8/13/16/24-point rhythm.
- Colors: existing Lithe window, sidebar, divider, selection, primary, and secondary tokens are used throughout.
- Image and icon fidelity: native SF Symbols are used for settings categories and actions; no placeholder or handcrafted assets are present.
- Copy: labels describe actual behavior and expose units for font size, delay, and indentation.

## Functional Verification

- `Command-,` opens Settings from Welcome.
- The left activity-rail gear opens Settings from a project.
- Auto-save reveals its delay picker and persists the selected `0.5 seconds` value after restart.
- Editor font size persisted at `14 pt`; Tab width persisted at `2 spaces`.
- Code Vision hid immediately when disabled and returned when restored.
- Default shell persisted as `bash` after restart.
- Restore Defaults reset auto-save, font size, Tab width, Code Vision, and shell across all categories.
- Production build, code signing, and `Info.plist` validation pass.

## Findings

- No actionable P0, P1, or P2 issues remain.
- Auto-save file writing was not exercised against a user project during UI QA to avoid modifying user content; scheduling and save code paths compile and are connected to editor change events.

## Patches Since Previous QA

- No production-code patch was required during final acceptance.
- Replaced the locked-screen blocker with captured General, Editor, and Terminal evidence.

final result: passed
