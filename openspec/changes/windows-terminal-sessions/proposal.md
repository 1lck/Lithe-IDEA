## Why

The Windows workbench ships exactly one ConPTY terminal. `WorkbenchWindow` owns a
single `std::unique_ptr<Win32TerminalTransport>` directly (`workbench_window.h:319`),
bypassing both the `app` feature-model layer and the application-boundary contract
(`shared/contracts/application-boundary.md:59`, which forbids the UI from constructing
terminals). The single session is stopped only in the `~WorkbenchWindow` destructor
(`workbench_window.cpp:931`); `openWorkspaceRoot` (`workbench_window.cpp:1776`) ignores
it, so a running shell keeps its old working directory across a workspace switch, and a
reliable "close project" path does not exist.

Developers need more than one terminal at once (build, server log, and an interactive
shell in parallel), each with its own lifecycle and visible state — and they must be able
to trust that closing the last tab, closing the project, or quitting the app kills the
**entire** process tree (shell + children), not just the root. This is
[issue #31 (W3)](https://github.com/1lck/Lithe-IDEA/issues/31) and Phase 4 of
`docs/architecture/windows-development-plan.md` (lines 266-292). A dependency-free
`TerminalBuffer` (`windows/app/algorithms/terminal_buffer.{h,cpp}`) already exists and is
unit-tested but is **not wired in** today; this change puts it behind a proper feature
model and consumes it from Qt.

## What Changes

- Introduce a **terminal feature model** in `windows/app/` that owns the session
  collection, the current session id, and all state transitions — Qt talks to the model,
  never to a transport or ConPTY handle directly.
- Introduce a **terminal session abstraction**: each session independently owns its
  ConPTY transport, its bounded `TerminalBuffer`, title, resolved shell, working
  directory, exit status, and per-session handler tokens.
- Add a **session lifecycle** to the terminal port surface (`windows/adapters/ports.h`):
  `starting | running | exiting | exited | start-failed`, with `operationID`-scoped
  callbacks so the UI can ignore stale events after a restart — matching the
  `ProcessSession` lifecycle already used by Java/Maven/LSP.
- Support **new / select / close / switch** terminal tabs and a **shell selector**
  (configured shell from `AppSettings::terminalShellPath`, plus detected
  `cmd.exe` / `pwsh.exe` / `powershell.exe`).
- Add scoped **Clear, Interrupt (Ctrl+C / SIGINT byte), and Restart** actions that affect
  only the targeted session.
- Drive the existing `TerminalBuffer` for output rendering (bounded scrollback, ANSI/CSI/OSC
  parsing, stable layout) instead of the raw `QPlainTextEdit` byte dump.
- Guarantee **process-tree teardown**: on close-last-tab, close-project, workspace switch,
  and app exit, every session's Job Object (`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`) is
  terminated, and stale output/exit callbacks are dropped before Qt controls are freed.
- Keep heavy output off the UI thread with a **bounded buffering** policy that coalesces
  reads and never grows without limit.
- Restructure the Qt terminal UI: a fixed-size tab bar, new/close affordances, current-state
  indicator, Clear/Interrupt/Restart icon buttons with tooltips, readable across light/dark
  themes, narrow windows, and high DPI.
- Add a **fake transport** for platform-independent feature/Qt tests, and keep the real
  ConPTY integration test gated to Windows CI.

No `**BREAKING**` changes to shared contracts or the Rust core: the terminal stays off the
`rust/lithe-core` JSON protocol (it remains a `windows/`-local feature, per
`application-boundary.md:30`).

## Capabilities

### New Capabilities
- `windows-terminal`: Multi-session Windows terminal — session lifecycle, the collection/
  current-session feature model, per-session buffer/state, new/select/close/switch,
  shell selection, Clear/Interrupt/Restart, and reliable process-tree teardown.

### Modified Capabilities
<!-- None: openspec/specs/ is empty today; this is the first Windows terminal spec. -->

## Impact

- **New code** under `windows/app/`:
  - terminal feature model + session type + state machine (pure C++, no Qt/Win32 includes —
    enforced by `scripts/verify-windows-boundaries.ps1` lines 60-78).
  - reuse of `windows/app/algorithms/terminal_buffer.{h,cpp}` for rendering.
- **`windows/adapters/ports.h`**: extend the terminal port with lifecycle events
  (`ProcessLifecycleState`/`ProcessLifecycleEvent`, reusing the `ProcessSession` shape)
  and `operationID` so restarts can drop stale callbacks.
- **`windows/adapters/win32_terminal_transport.{h,cpp}`**: emit lifecycle states; keep the
  existing Job-Object teardown; no change to the public `HANDLE`/`HPCON` surface (boundary
  script forbids them in public headers, lines 23-32).
- **`windows/qt/`**: replace the single-session panel in `workbench_window.{h,cpp}` with a
  tabbed terminal view + Clear/Interrupt/Restart/shell-selector; hook
  `openWorkspaceRoot` and `~WorkbenchWindow` to the model's teardown. Plan-driven: pull the
  new widgets into dedicated Qt types rather than enlarging `workbench_window.cpp`
  (`windows-development-plan.md:286`).
- **`windows/tests/`**: add a fake transport + feature-model test (runs on non-Windows) and a
  Qt offscreen test; move/keep the real ConPTY test under `LITHE_BUILD_QT_UI` for Windows CI.
- **`windows/CMakeLists.txt`**: new sources in `lithe_windows_app`/`lithe_windows_qt`; new
  test targets.
- **Out of scope (non-goals from the issue)**: SSH/remote/container terminals, a full
  terminal-emulator rewrite, plugin system, session persistence/restore, and a
  Java/Maven run console.
