## Context

See `proposal.md` for motivation. The relevant starting point: today `WorkbenchWindow`
owns one `Win32TerminalTransport` directly (`workbench_window.h:319`), the output is a raw
`QPlainTextEdit` byte dump, `resize()` is never called, the terminal is touched only by
`~WorkbenchWindow` (`workbench_window.cpp:931`) and ignored by `openWorkspaceRoot`
(`workbench_window.cpp:1776`), and a dependency-free `TerminalBuffer`
(`windows/app/algorithms/terminal_buffer.{h,cpp}`, 2000×240 scrollback) is built and
unit-tested but unused. The Job-Object teardown primitive we need —
`CreateJobObjectW` + `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` then `TerminateJobObject` —
already exists in `Win32TerminalTransport::stopImpl` (`win32_terminal_transport.cpp:573`)
and in `Win32ProcessSession` (`win32_process_session.cpp:361`).

Hard constraints that shape every decision below (enforced by
`scripts/verify-windows-boundaries.ps1` and `windows/README.md`):
- dependency direction is `qt -> app -> adapters/core`;
- `windows/app` (algorithms and services) MUST NOT include Qt or Win32 headers;
- public headers MUST NOT expose `HANDLE`/`HPCON` or `<windows.h>`;
- the terminal stays off the `rust/lithe-core` JSON protocol (`application-boundary.md:30`).

## Goals / Non-Goals

**Goals:**
- Move terminal ownership out of `WorkbenchWindow` into a pure, testable `app`-layer model
  that the Qt panel renders and commands.
- Make session lifecycle observable and restart-safe (stale callbacks droppable).
- Guarantee whole-tree teardown on close-last-tab, close-project, workspace-switch, app-exit.
- Drive `TerminalBuffer` for rendering and add a bounded coalescing flush path.

**Non-Goals (design-level, beyond the proposal's non-goals):**
- A full VT/terminal-emulator renderer (mouse, alt-screen apps, bracketed paste). The
  existing `TerminalBuffer` parser + a minimal renderer is the scope.
- Resizing the PTY on dock/resize in the first cut (today nothing calls `resize()`; wiring
  it is tracked as an open question, not a requirement).
- Persisting and restoring terminal sessions across restarts.

## Decisions

### D1. A pure `app`-layer `TerminalModel` + `TerminalSession`, Qt only renders
Add `windows/app/services/terminal_model.{h,cpp}` and `terminal_session.{h,cpp}` (or a
`windows/app/terminal/` subfolder). `TerminalModel` owns the session collection, the current
session id, and a *terminal epoch*; `TerminalSession` owns its id, title, resolved shell
spec, working directory, exit code, state, a `TerminalBuffer`, and a `unique_ptr<TerminalTransport>`.

The model depends only on the `TerminalTransport` port (`ports.h`) and the `TerminalBuffer`
algorithm — no Qt, no Win32. This is what makes the fake-transport tests (spec:
*Cross-platform testability*) run on non-Windows. Qt constructs the model and renders state
from it; it never touches a transport or handle, satisfying `application-boundary.md:59`.

*Alternative considered:* leave the transport in Qt and just add a tab list. Rejected — it
keeps the boundary violation, is untestable on macOS, and makes teardown hooks ad hoc.

### D2. Extend the terminal port with lifecycle events + `operationID`
`TerminalTransport` (`ports.h:68`) currently exposes output/error/exit handlers but no
lifecycle states, unlike `ProcessSession` (`ports.h:51`) which emits
`starting|running|stopping|finished|failed`. Add lifecycle emission to the terminal path by
reusing the same `ProcessLifecycleState`/`ProcessLifecycleEvent` shape, and thread an
`operationID` through each launch (the transport already receives a `ProcessRequest` with
`operationID`, `win32_terminal_transport.cpp` `start`). The model tags each session launch
with its `operationID` and ignores lifecycle/output whose id no longer matches.

*Why over `isRunning()` polling:* push-driven states let the UI show `start-failed`
precisely and distinguish `starting` from `running` — required by the spec's *Session
lifecycle states*. Mirroring the existing `ProcessSession` shape keeps one lifecycle model
across all process-backed features.

### D3. Stale-callback safety via epoch + generation tokens
Two layers, mirroring `WorkbenchCoordinator`'s workspace-epoch pattern
(`workbench_coordinator.h:177`):
- A **terminal epoch** in the model, bumped on workspace switch and on `shutdown()`. Every
  callback the transport emits captures the epoch at scheduling time; the model drops any
  whose captured epoch != current.
- A per-session **launch generation** (`operationID`) so a restart's late output/exit for
  the previous launch is dropped even before the session id changes.

Combined with the existing `QMetaObject::invokeMethod(..., Qt::QueuedConnection)` marshaling
to the UI thread (`workbench_window.cpp:885`), this satisfies *Safe discard of stale
callbacks* without new locking in Qt. The model never calls into Qt after the Qt side has
disconnected its listener — Qt disconnects on panel destroy, and the model checks the epoch.

### D4. Whole-tree teardown reuses the existing Job Object; model drives when
No new Win32 teardown code. `Win32TerminalTransport::stop()` already calls
`TerminateJobObject(job, 130)` under `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`
(`win32_terminal_transport.cpp:581`), which kills the shell and every descendant. The model
adds the *when*: `TerminalModel::closeAll()` iterates sessions and stops each; it is called
from (a) close-last-tab, (b) the start of `openWorkspaceRoot` (before the workspace epoch
bumps), and (c) `~WorkbenchWindow` before other teardown. This closes the gap that today
`openWorkspaceRoot` ignores the terminal.

*Alternative:* a single shared Job Object for all sessions. Rejected — per-session jobs keep
teardown scoped (closing one tab shouldn't disturb others) and match the existing per-session
design.

### D5. Bounded output: buffer + coalesced UI-thread flush
The transport's reader thread already decodes UTF-8 incrementally
(`win32_terminal_transport.cpp:160`) and calls the output handler. Instead of appending
straight to a `QPlainTextEdit`, the handler pushes bytes onto the session's lock-free-ish
queue and the model schedules **one** coalesced flush on the UI thread (a `Qt::QueuedConnection`
that drains all pending bytes for all sessions, capped at N bytes per flush to bound work).
`TerminalBuffer` enforces `MaximumRows`/`MaximumColumns`, so total memory is bounded per
session regardless of input rate. This satisfies *Bounded output buffering* and keeps the UI
thread responsive under sustained output.

*Alternative:* throttle/drop bytes in the transport. Rejected — would lose data; the buffer
already drops only the *oldest* scrollback, which is the spec-correct eviction.

### D6. Qt UI broken into dedicated types, not more `workbench_window.cpp`
Following `windows-development-plan.md:286`, introduce `windows/qt/terminal_panel.{h,cpp}`
(tab bar + action toolbar + stacked views), `windows/qt/terminal_view.{h,cpp}` (renders one
session's `TerminalBuffer`), and a small shell-selector menu. `WorkbenchWindow` constructs
the panel, hands it the `TerminalModel`, and wires the three teardown hooks (D4) plus the
"Terminal" menu / command-palette entries. The existing single-session panel code in
`workbench_window.cpp:617-634` and `4553-4591` is removed.

*Open sub-decision (deferred, see Open Questions):* one shared `TerminalView` rebound on
switch vs. one view per session. Both satisfy *Per-session isolation* (scroll/buffer live in
the model); we pick during the UI step based on focus-behavior testing.

### D7. Shell selection reads config + detects available shells
Default shell = `AppSettings::terminalShellPath` (existing, `app_persistence.h:24`). The
shell menu additionally offers shells detected by `Win32RuntimeLocator` (`pwsh.exe`,
`powershell.exe`, `cmd.exe`). Each new session applies `workingDirectory = workspaceRoot`
and `environment = runtimeLocator_.environment()` — the same fields `startTerminal` sets today
(`workbench_window.cpp:4577`). This is data wiring, not a new abstraction.

### D8. Interrupt = the standard interrupt byte
Interrupt sends `\x03` (Ctrl+C) to the session transport's `send()`, matching what a
pseudo-console expects; Restart = `stop()` then a fresh `start()` under a new `operationID`
(generation bump, D3). Clear = reset the session's `TerminalBuffer` and view. All three
operate on the targeted session only (spec: *Scoped session actions*).

## Risks / Trade-offs

- **Heavy-output rendering cost** → coalesced flush + per-flush byte cap + bounded `TerminalBuffer`.
  The integration test (D9) exercises sustained output for responsiveness.
- **Stale callbacks after rapid restart/switch** → epoch + generation tokens (D3); covered by
  the "duplicate stop" and "stale callback" model tests.
- **Grandchild processes surviving teardown** (e.g. detached children) → `KILL_ON_JOB_CLOSE`
  already covers descendants in the job; the existing
  `win32_terminal_transport_test.cpp` snapshot walk is extended to multi-session close.
- **`workbench_window.cpp` growth** → enforced by the dedicated Qt types in D6 and the boundary
  script.
- **Lifecycle port change is a small incompatibility for any out-of-tree consumer** →
  `TerminalTransport` is `windows/`-internal (not in `rust/lithe-core` or `shared/`); the change
  is additive (new optional handler) and the only implementer/consumer is in-tree.

## Migration Plan

Incremental, each step keeps Windows CI green (matches the PR-boundary plan in
`windows-development-plan.md:342-355`, item 7):

1. **Port + lifecycle** — extend `TerminalTransport`/`Win32TerminalTransport` with lifecycle
   states and `operationID` (D2). Pure additive; existing single-session callers unchanged.
2. **Model + session** — add `TerminalModel`/`TerminalSession` (D1) with fake-transport unit
   tests (D9). Not yet wired to Qt.
3. **Re-host the single session** — `WorkbenchWindow` owns the model instead of a transport;
   output flows through `TerminalBuffer` + coalesced flush (D5). Behavior externally unchanged.
4. **Tabs + actions + shell selector** — D6/D7/D8 UI; multi-session create/select/close/switch,
   Clear/Interrupt/Restart.
5. **Teardown hooks** — D4 in `openWorkspaceRoot` and destructor; extend the integration test.
6. **Qt offscreen UI test + finalize** — D6 behavior coverage.

Rollback: steps 1-2 are additive and removable. Step 3 is the switchover; if it regresses, the
prior direct-transport path is one revert away (it is kept until step 3 lands, then deleted).

## Open Questions

- **One shared `TerminalView` rebound on switch, or one view per session?** Deferrable to the
  UI step; both preserve per-session scroll/buffer (held in the model). Decided by focus and
  scroll-restore behavior during testing.
- **Wire `transport.resize(columns, rows)` from the view now or defer?** Today nothing calls
  `resize()`; it is not in the spec's required behavior. Defer to a follow-up unless the
  rendered columns visibly mismatch the PTY default (120×40) during step 3.
