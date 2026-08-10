## Purpose

A Windows terminal whose output is rendered as a real terminal emulator (ANSI/VT
colors, cursor, alternate screen) and whose input is typed directly into the surface
and forwarded to the shell, so that colored tool output and full-screen TUIs display
correctly and the shell receives keystrokes the way it does on the macOS app.

## ADDED Requirements

### Requirement: Terminal output is rendered as an ANSI/VT emulator

The system SHALL render terminal output by interpreting ANSI/VT control sequences,
not as plain monochrome text. Rendering SHALL support SGR text attributes including
foreground and background color (standard, 256-color, and truecolor), bold, and
inverse/reverse; cursor positioning and relative movement; line and display erase;
and an alternate screen buffer.

#### Scenario: Colored output is shown in color
- **WHEN** a session's shell emits text containing SGR color sequences (for example, a compiler diagnostic or `ls --color`)
- **THEN** the rendered output displays the text in the colors specified by those sequences, rather than stripped to plain monochrome text

#### Scenario: A full-screen TUI renders coherently
- **WHEN** the user runs a full-screen terminal application (such as `vim`, `less`, or a curses program) inside a session
- **THEN** the application's full-screen layout is rendered correctly on the alternate screen, and returning to the shell restores the prior scrollback view

#### Scenario: The cursor is rendered
- **WHEN** output positions the cursor (cursor-position sequences, line wrapping, carriage return, newline)
- **THEN** the rendered surface reflects the cursor at the intended position and shows a visible cursor caret

### Requirement: The user types directly into the terminal surface

The terminal surface SHALL accept keyboard input directly and forward it to the
session's shell process as terminal input bytes, rather than requiring a separate
single-line input field. Forwarded input SHALL cover printable characters, Enter
(carriage return / line feed as appropriate), Backspace, Tab, the arrow keys, and
Ctrl+C (the interrupt byte). Pasting text into the surface SHALL forward the pasted
bytes to the shell.

#### Scenario: Keystrokes reach the running shell
- **WHEN** the terminal surface is focused and the user types characters, presses Enter, Backspace, Tab, or the arrow keys
- **THEN** the corresponding input bytes are delivered to the active session's shell, and the shell's line editor reacts as if typed in a normal terminal

#### Scenario: Ctrl+C interrupts the foreground command from the keyboard
- **WHEN** the surface is focused, a foreground command is running, and the user presses Ctrl+C
- **THEN** the interrupt byte is sent to the active session and the foreground command is interrupted (equivalent to the existing Interrupt action)

#### Scenario: Pasted text is forwarded
- **WHEN** the user pastes text into the terminal surface
- **THEN** the pasted bytes are sent to the active session's shell

### Requirement: The PTY geometry follows the surface size

The system SHALL keep the pseudo-terminal's column/row geometry aligned with the
visible size of the terminal surface. When the surface is resized (window resize,
docking, splitter drag), the system SHALL compute the new column/row count from the
surface's cell size and apply it to the active session's transport, so the shell and
any full-screen application redraw to the new geometry.

#### Scenario: Resizing the surface resizes the shell view
- **WHEN** the user resizes the terminal surface (for example by dragging the workbench splitter or resizing the window)
- **THEN** the active session's pseudo-terminal is resized to the new column/row count and the shell output reflows to the new width

#### Scenario: Geometry is not stuck at a fixed default
- **WHEN** a session runs in a surface wider and taller than 120 columns by 40 rows
- **THEN** the shell's reported terminal size matches the actual surface size, not the fixed 120×40 default

### Requirement: Per-session emulator state survives switching

The emulator state for a session — including its screen contents, alternate-screen
state, scrollback, and cursor — SHALL be held by the session, so that switching the
active terminal tab away and back preserves that session's exact rendered state.

#### Scenario: Screen and scrollback are preserved across switches
- **WHEN** session A has accumulated output and a cursor position, the user switches to session B, then back to session A
- **THEN** session A's rendered screen, scrollback, and cursor are restored exactly as they were before the switch

### Requirement: Output and scrollback stay bounded

The terminal SHALL keep its scrollback bounded by a configured maximum so that
sustained output cannot grow memory without limit, while recent output remains visible
and reachable by scrolling.

#### Scenario: Scrollback is capped
- **WHEN** a session produces output that exceeds the configured scrollback limit
- **THEN** the oldest scrollback content is evicted so total scrollback size stays bounded, and recent output remains reachable by scrolling back

### Requirement: Existing multi-session behavior is preserved

This change SHALL not regress the terminal capability's existing behavior:
concurrent sessions, per-session output isolation, scoped Clear/Interrupt/Restart,
reliable whole-process-tree teardown on close-project and app-exit, and safe discard
of stale callbacks SHALL continue to hold.

#### Scenario: Multi-session and scoped actions still work
- **WHEN** two sessions run concurrently and the user clears, interrupts, or restarts the active one
- **THEN** only the active session is affected and the other session continues running unchanged

### Requirement: The emulator is testable off-Windows

The terminal-emulator parsing and rendering-model logic SHALL be verifiable without a
real Windows pseudo-console, using a substitute transport. Verification of real
ANSI/VT rendering against a real pseudo-console SHALL be confined to Windows CI.

#### Scenario: Emulator parsing is verified off-Windows
- **WHEN** a developer builds and runs the emulator unit tests on a non-Windows machine
- **THEN** the tests feed VT byte sequences to the emulator and assert the resulting rendered grid, without requiring a real pseudo-console

#### Scenario: Real rendering is verified on Windows CI
- **WHEN** Windows CI runs the terminal integration test
- **THEN** it drives a real ConPTY session and asserts that colored and cursor-positioning output renders as expected
