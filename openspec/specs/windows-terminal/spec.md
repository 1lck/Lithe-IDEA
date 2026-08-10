## Purpose

A Windows terminal that renders output as a real terminal emulator (ANSI/VT
colors, cursor, alternate screen) and can run more than one shell session at
once. Each session is independently started, viewed, switched, controlled, and
torn down; typed input is forwarded directly to the shell; and closing a tab, a
project, or the application reliably stops the whole process tree of every
session.

## Requirements

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

### Requirement: Concurrent terminal sessions

The system SHALL allow more than one terminal session to exist and run concurrently in the
same workspace. Each session SHALL be independently created, selected, closed, and switched
without affecting the running state, output, or lifetime of any other session.

#### Scenario: Two sessions run independently
- **WHEN** a user creates a second terminal session while a first session is running a long-lived shell process
- **THEN** both sessions report a running state simultaneously and the first session continues running uninterrupted

#### Scenario: Output stays within its session
- **WHEN** the active session produces output while an inactive session also exists
- **THEN** that output appears only in the producing session and is never appended to any other session's view

#### Scenario: Closing one session leaves others running
- **WHEN** a user closes one session out of several running sessions
- **THEN** the remaining sessions keep running and retain their output and state

### Requirement: Per-session isolation of state

Each terminal session SHALL independently hold its own output buffer, scroll position,
pending input, title, selected shell, working directory, and exit status. Switching the
active session SHALL NOT lose the inactive session's scroll position, buffered content,
title, or exit status.

#### Scenario: Scroll position is preserved across switches
- **WHEN** a user scrolls back in session A, switches to session B, and switches back to session A
- **THEN** session A's viewport is restored to the same scroll position it had before the switch

#### Scenario: Buffered content is preserved across switches
- **WHEN** session A produces output, the user switches away to session B and back
- **THEN** all of session A's prior output that was within the bounded buffer is still present

#### Scenario: Input targets the active session
- **WHEN** the user types and submits input while a session is active
- **THEN** the input is delivered only to the active session and the active session regains input focus after switching

### Requirement: Session lifecycle states

The system SHALL expose each session's lifecycle as exactly one of these observable states:
`starting`, `running`, `exiting`, `exited`, or `start-failed`. State transitions SHALL be
reported to the UI as they happen. A restart SHALL be observable as a distinct new session
lifecycle so that callbacks belonging to the previous lifecycle can be discarded.

#### Scenario: A healthy session transitions starting to running
- **WHEN** a user creates a new session with a valid shell
- **THEN** the session is first observable as `starting` and then as `running` once the shell process is alive and ready for input

#### Scenario: A failed launch is reported as start-failed
- **WHEN** a session is created with a shell that cannot be launched
- **THEN** the session becomes `start-failed` and the error condition is observable to the user

#### Scenario: Stopping transitions through exiting to exited
- **WHEN** a running session is stopped or its shell exits
- **THEN** the session becomes `exited` and its exit status becomes observable

### Requirement: Shell selection with correct environment

The system SHALL let the user choose which available shell a new session uses, from the
configured shell preference plus any additional detected shells. A new session SHALL start
in the workspace's current working directory and SHALL be launched with the environment
appropriate to the chosen shell.

#### Scenario: New session uses the selected shell
- **WHEN** the user selects a specific shell from the shell menu and creates a new session
- **THEN** the new session runs that selected shell

#### Scenario: New session starts in the workspace directory
- **WHEN** a session is created while a workspace is open
- **THEN** the session's shell starts with its working directory set to the open workspace root

#### Scenario: Default shell comes from configuration
- **WHEN** the user has configured a shell preference and creates a new session without choosing otherwise
- **THEN** the configured shell is used for the new session

### Requirement: Scoped session actions

Clear, Interrupt, and Restart SHALL affect only the targeted session and SHALL NOT alter
the output, input, or lifetime of any other session.

#### Scenario: Clear empties only the target session
- **WHEN** the user clears the active session
- **THEN** only the active session's visible output is cleared; every other session's output is unchanged

#### Scenario: Interrupt targets only the active session
- **WHEN** the user issues an interrupt on the active session
- **THEN** the interrupt is delivered only to the active session and any other running session is unaffected

#### Scenario: Restart relaunches only the target session
- **WHEN** the user restarts the active session
- **THEN** only that session is stopped and relaunched, and every other session keeps its state and continues running

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
and reachable by scrolling. High-volume output SHALL NOT block the user-interface thread
or corrupt any session's state.

#### Scenario: Scrollback is capped
- **WHEN** a session produces output that exceeds the configured scrollback limit
- **THEN** the oldest scrollback content is evicted so total scrollback size stays bounded, and recent output remains reachable by scrolling back

#### Scenario: Sustained heavy output keeps the UI responsive
- **WHEN** a session produces output continuously at a high rate
- **THEN** the user interface remains responsive to input and tab switching throughout

### Requirement: Reliable process-tree teardown

On closing the last remaining session, closing the project, switching the workspace, or
exiting the application, the system SHALL terminate the entire process tree of every
session — the shell and all of its descendant processes — and SHALL leave no orphaned
processes behind.

#### Scenario: Closing the last tab kills the whole tree
- **WHEN** a user closes the last remaining session whose shell has spawned child processes
- **THEN** both the shell and all of its descendant processes are terminated and no processes from that session remain

#### Scenario: Application exit kills every session's tree
- **WHEN** the user exits the application while one or more sessions are still running with descendant processes
- **THEN** all sessions' shells and their descendant processes are terminated and none remain after exit

#### Scenario: Workspace switch tears down the prior workspace's sessions
- **WHEN** the user switches from one open workspace to another while terminal sessions are running in the first workspace
- **THEN** the prior workspace's sessions are stopped and their entire process trees are terminated

### Requirement: Safe discard of stale callbacks

Output, error, and exit callbacks belonging to a session that has been closed, whose
workspace has switched away, or whose user-interface control has been destroyed SHALL be
safely discarded and SHALL NOT mutate any freed or unrelated user-interface state.

#### Scenario: Late output from a closed session is dropped
- **WHEN** output arrives for a session after that session has been closed
- **THEN** the output is discarded without affecting any visible session view

#### Scenario: Exit callback after teardown is a no-op
- **WHEN** an exit notification arrives after the session's owning UI control has been destroyed
- **THEN** the notification is ignored and no freed UI state is touched

### Requirement: Existing multi-session behavior is preserved

Terminal changes SHALL NOT regress the capability's existing behavior:
concurrent sessions, per-session output isolation, scoped Clear/Interrupt/Restart,
reliable whole-process-tree teardown on close-project and app-exit, and safe discard
of stale callbacks SHALL continue to hold.

#### Scenario: Multi-session and scoped actions still work
- **WHEN** two sessions run concurrently and the user clears, interrupts, or restarts the active one
- **THEN** only the active session is affected and the other session continues running unchanged

### Requirement: Terminal user-interface usability

The terminal area SHALL provide a stable-sized tab bar with new/close affordances and an
indication of the current session's state; shell selection via a menu; and Clear, Interrupt,
and Restart as standard icon buttons with tooltips. Tab titles, long working-directory paths,
exit codes, and error states SHALL remain legible without overlap under narrow windows and
high-DPI scaling, in both light and dark themes, including terminal text, selection, focus,
disabled, and error states.

#### Scenario: Narrow window and high DPI do not cause overlap
- **WHEN** the terminal area is resized to a narrow width at high-DPI scaling with a long working directory and a non-zero exit code
- **THEN** the tab title, path, exit code, and error state do not overlap and remain readable

#### Scenario: Light and dark themes both stay legible
- **WHEN** the user switches between light and dark themes
- **THEN** terminal text, selection, focus, disabled, and error states remain clearly readable in both themes

#### Scenario: Long paths are presented without breaking layout
- **WHEN** a session's working directory path is too long to fit its tab
- **THEN** the path is presented in a way that does not break the tab-bar layout and the full path is reachable to the user

### Requirement: The terminal model and emulator are testable off-Windows

The terminal-emulator parsing/rendering-model logic and the terminal model and UI logic SHALL
be verifiable without a real Windows pseudo-console, using a substitute transport that records
inputs and emits scripted output and lifecycle transitions. Verification against the real
Windows pseudo-console SHALL be confined to Windows CI.

#### Scenario: Emulator and model tests run off-Windows
- **WHEN** a developer builds and runs the emulator and terminal model/UI tests on a non-Windows machine
- **THEN** the tests feed VT byte sequences and scripted lifecycle events and assert the resulting grid and behavior, without requiring a real pseudo-console

#### Scenario: Real pseudo-console behavior is verified on Windows CI
- **WHEN** Windows CI runs the terminal integration test
- **THEN** it drives a real ConPTY session and asserts session start, interactive input/output, interrupt, restart, colored/cursor rendering, and full process-tree cleanup
