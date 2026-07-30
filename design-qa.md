# Lithe Settings QA

## Evidence

- Visual direction: existing Lithe/IDEA-style tool windows and the current application design system.
- Implementation target: application-level Settings sheet opened from the left activity rail or `Command-,`.
- Viewport: intended for the existing macOS window minimum of 980 x 640.
- State: General, Editor, and Terminal categories implemented.

## Functional Checks

- Debug build passes with Swift 6.2.
- Settings persist through `UserDefaults`.
- Editor font size, Tab width, Code Vision visibility, auto-save delay, and terminal shell are connected to production behavior.
- Settings can be opened from both the workbench gear button and the standard macOS `Command-,` shortcut.
- Restore Defaults updates and persists every exposed preference.

## Findings

- [P1] Final visual capture is blocked because the Mac is locked.
  Evidence: Computer Use reports that automatic unlock failed, so the packaged Settings sheet cannot be opened or captured.
  Impact: layout, clipping, and interaction states cannot receive a final visual sign-off in this pass.
  Fix: unlock the Mac, open Settings, capture all three categories, and compare them against the established Lithe tool-window styling.

## Patches Since Previous QA

- Added a persistent `AppSettings` model.
- Added an application-level categorized Settings sheet.
- Added Editor, Files, and Terminal preferences with live behavior.
- Added a left-rail gear button and standard macOS Settings command.

final result: blocked
