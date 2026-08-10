# Test handoff — windows-terminal-sessions

Entry points, preconditions, expected state, and error paths for the multi-session
terminal. Scenarios marked **[CI-only]** require real ConPTY / a Windows + MSVC + Qt
build and are run on Windows CI, not a developer machine.

## Feature model + Qt widget (run on any platform, offscreen for Qt)

### Entry: `lithe_windows_terminal_model_tests` / `lithe_windows_terminal_panel_tests`
- Preconditions: none (fake transport, no ConPTY).
- Expected state: create/select/close/restart, multi-session output isolation,
  per-session buffer preserved across switch, Clear/Interrupt/Restart scoped to the
  active session, duplicate `close()` safe, `closeAll()` empties + bumps epoch,
  heavy output stays bounded (oldest rows evicted), restart drops stale-launch output.
- Error paths: launch with no shell configured → no session created; `restart()` with no
  prior launch → no-op; close unknown id → no-op.

## Real ConPTY **[CI-only]**

### Entry: `lithe_windows_terminal_transport_tests` + `WorkbenchWindow` (Windows CI)
- Preconditions: Windows + MSVC + Qt + Rust core; a workspace folder is open.
- Expected state:
  - Two or more sessions run concurrently; switching tabs preserves each session's
    output, scroll position, and input focus.
  - Interrupt (Ctrl+C / `\x03`) stops only the targeted session's foreground command.
  - Restart relaunches only the targeted session under a new launch id.
  - Closing the last tab terminates that session's whole process tree (shell +
    descendants) — verified empty via the descendant-tree walk.
  - Closing the project / switching workspace stops the prior workspace's sessions'
    trees; quitting the app leaves no orphaned processes.
- Error paths: shell executable missing/invalid → session shows `start-failed`
  (tab title "(failed)"); late output after a restart or close is dropped silently.

## Visual / UX (manual, on a real Windows desktop) **[manual]**
- Narrow window + high DPI: tab title, long working-directory path, exit code, and error
  state do not overlap.
- Light and dark themes: terminal text, selection, focus, disabled, and error states
  remain legible.
- Clear / Interrupt / Restart icon buttons show tooltips.

## Known follow-ups not covered here
- Task 3.1 (explicit coalesced flush queue) is a perf refinement; output is already
  bounded (buffer ≤ 2000 rows, render capped) and marshaled off the transport thread.
- Shell detection currently offers the configured shell + `cmd.exe`; detection of
  `pwsh.exe` / `powershell.exe` via PATH is deferred.
