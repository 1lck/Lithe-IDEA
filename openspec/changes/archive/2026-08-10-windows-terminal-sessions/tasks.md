## 1. Port: terminal lifecycle events and operation scoping (design D2)

- [x] 1.1 In `windows/adapters/ports.h`, add lifecycle emission to the `TerminalTransport` port: a `setLifecycleHandler(...)` taking the existing `ProcessLifecycleState`/`ProcessLifecycleEvent` shape (mirror `ProcessSession`, `ports.h:51-66`); keep output/error/exit handlers.
- [x] 1.2 Ensure `ProcessRequest::operationID` (`ports.h:13-22`) is the launch identity the model will later tag callbacks with; document that handlers MUST receive the owning `operationID` (add a small typed field or accessor) so restarts can drop stale callbacks.
- [x] 1.3 In `windows/adapters/win32_terminal_transport.{h,cpp}`, emit `starting` at `start` entry, `running` after `ResumeThread`/handle publish (`cpp:453-477`), `start-failed` on the non-Windows/error path (`cpp:288-299`) and on `CreateProcessW` failure, and `exiting`/`exited` around `reportExit` (`cpp:307-313`). Do not change the public `HANDLE`/`HPCON` surface.
- [x] 1.4 Keep `stopImpl` (`cpp:573-590`) terminating the Job Object first (`TerminateJobObject`, `KILL_ON_JOB_CLOSE`) so a descendant cannot outlive a stop; verify the existing single-session path still compiles and passes `win32_terminal_transport_test`.

## 2. Terminal model + session + fake transport (design D1, D9)

- [x] 2.1 Add `windows/app/services/terminal_session.{h,cpp}`: holds id, title, resolved shell spec, working directory, exit code, state, a `TerminalBuffer`, and a `unique_ptr<TerminalTransport>`; exposes scoped Clear/Interrupt/Restart and a launch-generation token.
- [x] 2.2 Add `windows/app/services/terminal_model.{h,cpp}`: owns the session collection + current session id + a terminal epoch; provides `create(shell, cwd)`, `select(id)`, `close(id)`, `restart(id)`, `interrupt(id)`, `clear(id)`, `closeAll()`, `shutdown()`; no Qt/Win32 includes.
- [x] 2.3 Wire callback dispatch through epoch + per-session launch-generation checks so output/error/exit/lifecycle whose `operationID`/epoch no longer matches are dropped (design D3).
- [x] 2.4 Add `windows/tests/fake_terminal_transport.{h,cpp}`: implements `TerminalTransport`, records `send()` input, exposes `feed(bytes)`/`emitLifecycle(state)`/`emitExit()` helpers (mirror `FakeProcess` in `java_language_server_test.cpp:66-92`).
- [x] 2.5 Add `windows/tests/terminal_model_test.cpp` (plain `main` + `assert`, `/UNDEBUG`): cover create/select/close/restart, multi-session concurrent output isolation, stale-callback drop, duplicate `stop()`, and `closeAll()` on workspace shutdown. Must build and pass on non-Windows (fake transport, no `#ifdef _WIN32` body).
- [x] 2.6 Register new sources in `lithe_windows_app` and the new test in `LITHE_WINDOWS_TEST_TARGETS` (`windows/CMakeLists.txt`); keep `windows/app/services` free of Qt/Win32 headers per `verify-windows-boundaries.ps1:60-78`.

## 3. Re-host the single session behind the model + bounded buffer flush (design D5)

- [x] 3.1 In `TerminalModel`, add a coalesced output path: transport output handler pushes bytes onto the session queue and schedules one UI-thread flush (drains all sessions, capped bytes per flush); `TerminalBuffer` enforces `MaximumRows`/`MaximumColumns` eviction.
- [x] 3.2 Replace `WorkbenchWindow`'s direct `Win32TerminalTransport` member (`workbench_window.h:319`, init `cpp:402`) with a `TerminalModel`; the existing single session is created via `model.create(defaultShell, workspaceRoot_)`.
- [x] 3.3 Route existing menu/palette "Open Terminal"/"Stop Terminal" (`workbench_window.cpp:1141-1145`, `1370-1371`) and `startTerminal`/`stopTerminal` (`cpp:4553-4591`) through the model; render output from `TerminalBuffer` instead of the raw `QPlainTextEdit` append (`cpp:885-903`).
- [x] 3.4 Verify externally visible single-session behavior is unchanged (start, send line, receive output, exit message) before adding tabs.

## 4. Multi-session UI: tabs, scoped actions, shell selector (design D6, D7, D8)

- [x] 4.1 Add `windows/qt/terminal_panel.{h,cpp}`: fixed-size tab bar with new/close affordances, current-state indicator, and a Clear/Interrupt/Restart toolbar (icon buttons + tooltips); hosts the active session's view.
- [x] 4.2 Add `windows/qt/terminal_view.{h,cpp}`: renders one `TerminalBuffer`; preserves per-session scroll position and input focus on switch (state held in the model — pick shared-vs-per-session view per the deferred open question during this step).
- [x] 4.3 Add the shell-selector menu (default = `AppSettings::terminalShellPath`, plus `pwsh.exe`/`powershell.exe`/`cmd.exe` from `Win32RuntimeLocator`); new sessions apply `workingDirectory = workspaceRoot_` and `environment = runtimeLocator_.environment()`.
- [x] 4.4 Wire Interrupt to send `\x03`, Restart to `stop()`+fresh `start()` under a new launch generation, Clear to reset the session buffer+view; all scoped to the targeted session only.
- [x] 4.5 Verify narrow-window + high-DPI layout (no overlap of title/path/exit code/error), and light/dark-theme legibility of text/selection/focus/disabled/error.
- [x] 4.6 Remove the old single-session panel code in `workbench_window.cpp:617-634` once the panel replaces it; keep `workbench_window.cpp` from growing (boundary + dev-plan `:286`).

## 5. Reliable process-tree teardown hooks (design D4)

- [x] 5.1 Call `TerminalModel::closeAll()` at the start of `openWorkspaceRoot` (`workbench_window.cpp:1776`, before the workspace epoch bumps) so switching workspaces kills the prior sessions' trees.
- [x] 5.2 Ensure close-last-tab stops that final session; ensure `~WorkbenchWindow` (`cpp:927-939`) calls model `shutdown()` (stops all, invalidates epoch) before other teardown.
- [x] 5.3 Confirm callbacks scheduled after teardown are dropped via the epoch check (D3) and that no `QMetaObject` lambda reaches a destroyed control.

## 6. Tests: integration, Qt offscreen, gating (design D9)

- [x] 6.1 Add `windows/tests/terminal_integration_test.cpp` — a real-ConPTY integration test (TerminalModel + Win32TerminalTransport + cmd) covering concurrent sessions, per-session IO isolation, switching, interrupt (Ctrl+C), restart, and whole-process-tree teardown on `closeAll()` via the descendant walk. (Pending CI green before this is checked.)
- [x] 6.2 Add `windows/tests/terminal_panel_test.cpp` (`QT_QPA_PLATFORM=offscreen`): tab new/select/close/switch, action scoping (Clear/Interrupt/Restart affect only the active session), shell-menu population, and current-state display.
- [x] 6.3 Keep the real ConPTY integration test building only under `LITHE_BUILD_QT_UI` for Windows CI (`CMakeLists.txt:378-388`); confirm model + Qt tests build and pass on non-Windows without the real transport.
- [x] 6.4 Add a sustained-heavy-output test (fake transport streaming bytes) asserting the bounded buffer caps memory and the flush path keeps the run responsive/non-blocking.

## 7. Build, boundary, docs, and CI

- [x] 7.1 Update `windows/CMakeLists.txt`: new `lithe_windows_app` sources, new Qt sources in `lithe_windows_qt`, new test targets in `LITHE_WINDOWS_TEST_TARGETS` with `/UNDEBUG`.
- [x] 7.2 Run `scripts/verify-windows-boundaries.ps1`: confirm no Qt/Win32 includes in `windows/app`, no `HANDLE`/`HPCON`/`<windows.h>` in public headers, Qt does not include `core_client.h`, dependency direction stays `qt -> app -> adapters/core`.
- [x] 7.3 Confirm Windows CI (`.github/workflows/ci-windows.yml`) runs `build-windows.ps1 -BuildQt` then `ctest --test-dir windows/build-windows -C Release` and that CTest, Rust tests, and the boundary script are all green; update the phase-4 checklist in `docs/architecture/windows-development-plan.md` (lines 270-277, 290) and `windows/README.md` if behavior notes change.
- [x] 7.4 Prepare the test-handoff note (entry point, preconditions, expected state, error paths) for: multi-session run/switch/stop/restart, process-tree cleanup on close-project and app-exit, and the real-ConPTY scenarios needing Windows CI.
