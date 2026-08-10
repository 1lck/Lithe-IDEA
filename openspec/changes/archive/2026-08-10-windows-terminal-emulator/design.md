## Context

See `proposal.md` for motivation. The starting point: `TerminalSession` owns a
`TerminalBuffer` (`windows/app/algorithms/terminal_buffer.{h,cpp}`) that parses a
subset of CSI (cursor move/erase) and **strips SGR color**; `TerminalView` renders
`session->render()` into a read-only `QPlainTextEdit` and takes input from a separate
`QLineEdit`. The ConPTY output pipe already delivers real VT bytes; nothing renders
them. The transport already has `resize(cols, rows)` (`ports.h`) but the Qt layer never
calls it, so the console is fixed at 120×40.

Hard constraints (unchanged): dependency direction `qt -> app -> adapters/core`;
`windows/app` (algorithms + services) MUST NOT include Qt or Win32 headers
(`verify-windows-boundaries.ps1`); the terminal stays off the `rust/lithe-core` JSON
protocol. A new dependency is allowed only if it is pure C/C++ with no Qt/Win32.

## Goals / Non-Goals

**Goals:**
- Render real ANSI/VT output (SGR color, cursor, alt-screen, scrollback) so colored
  tool output and full-screen TUIs display correctly.
- Let the user type directly into the surface; forward keystrokes to the PTY.
- Resize the PTY with the surface.
- Keep per-session emulator state alive across tab switches.
- Stay testable off-Windows for the parsing/model, with real-ConPTY rendering on CI.

**Non-Goals (explicitly deferred to follow-up changes):**
- Clickable file/URL links and `file:line:col` editor navigation.
- Live OSC working-directory + process-title tracking.
- The rich status readout (running dot / cwd / exit code / elapsed timer).
- Per-session shell choice and restart-with-new-shell.
- Nerd-font preference and user-settable font/theme.
- Styled selection / mouse reporting / bracketed paste.

## Decisions

### D1. Use `libvterm` for VT parsing (not a Qt/KDE widget, not extending `TerminalBuffer`)
`libvterm` is a small, pure-C, MIT-licensed VT100/ANSI parser+screen library (used by
Neovim and others). It parses SGR (incl. 256-color/truecolor), cursor, erase,
alt-screen, OSC, and exposes a cell grid plus a damage callback. It has **no Qt or
Win32 dependency**, so it is permitted inside `windows/app`.

Add it via CMake `FetchContent` from the official repo at a pinned tag (or vendor a
snapshot under `windows/third_party/libvterm/`). Build it as a static lib and link
`lithe_windows_algorithms`.

*Alternatives considered:*
- **QTermWidget / Konsole part**: a complete Qt terminal widget — rendering, parsing,
  input, all done. Rejected: pulls in KDE Frameworks dependencies, breaking the
  self-contained Windows baseline and bloating the build.
- **Extend `TerminalBuffer`** to parse SGR/cursor/alt-screen: re-implements libvterm
  piecemeal — more code, more edge cases, less complete (truecolor, alt-screen,
  damage tracking), higher bug risk for no benefit.

### D2. A `TerminalEmulator` wrapper in `windows/app/algorithms/`, owned by the session
Add `terminal_emulator.{h,cpp}` wrapping a `VTerm*` + `VTermScreen*`. Public surface:
`write(bytes)` (feed ConPTY output), `resize(cols, rows)`, `reset()`, and a read API
for the renderer (`rows()`, `cols()`, `cell(row,col)` returning the glyph + SGR attrs,
`cursorRow/Col()`, scrollback access). It tracks damaged rows via libvterm's screen
damage callback so the renderer can repaint only what changed. Bounded scrollback is
kept in a ring buffer maintained by the wrapper (libvterm's own screen is only the
visible viewport).

`TerminalSession` owns a `TerminalEmulator` instead of a `TerminalBuffer`; output is
routed `transport -> session.onOutput -> emulator.write(bytes)`. The emulator is the
session's renderable state, so it survives widget recreation on tab switch.

### D3. A `TerminalSurface` Qt widget replaces `QPlainTextEdit` + `QLineEdit`
New `windows/qt/terminal_surface.{h,cpp}` (`QWidget`). It:
- `paintEvent`: reads the active session's `TerminalEmulator` grid and draws cells with
  `QPainter` (glyph + fg/bg color + bold/inverse), plus the caret. Uses a monospace
  `QFont` and its metrics to compute the cell size.
- `keyPressEvent` / `inputMethodEvent` / paste: translate to input bytes and call
  `session->send(bytes)` (D4).
- `resizeEvent`: compute cols/rows from widget size ÷ cell size and call
  `session->resize(cols, rows)` (D5).
- Owns a vertical scrollbar for scrollback; mouse-wheel scrolls.
- Asks the model/session for a repaint (via the existing output-sink queued
  connection) when damaged rows arrive.

`TerminalView` becomes a thin holder that creates one `TerminalSurface` per session and
binds it; the `QLineEdit` is removed.

### D4. Qt-key → VT-byte translation table
A small free function `windows/qt/terminal_keys.{h,cpp}` maps `QKeyEvent` to the
terminal input bytes: printable UTF-8 as-is; Enter → `\r`; Backspace → `\x7f`; Tab →
`\t`; Ctrl+<letter> → the control byte (Ctrl+C → `\x03`); arrows/Home/End/PgUp/PgDn →
the CSI sequences; F1–F12 → their sequences. Start with the set the Mac surface
effectively forwards; exotic combos (Ctrl+arrow, Meta+key) are added later.

### D5. PTY resize is driven by the widget through the existing port
`TerminalTransport::resize(cols, rows)` already exists and is already implemented by
`Win32TerminalTransport` (`ResizePseudoConsole`). `TerminalSession` exposes
`resize(cols, rows)` which forwards to the transport (and resizes its emulator). The
widget's `resizeEvent` calls it. No port change.

### D6. `TerminalBuffer` is superseded and removed
Once the emulator is the output model and the panel/view/model tests are migrated,
`terminal_buffer.{h,cpp}` and its unit test are deleted. (Kept temporarily while
tests migrate, to avoid a dead-code flag in the interim commit.)

## Risks / Trade-offs

- **New external C dependency** → `libvterm` via pinned `FetchContent`, vendored
  fallback. Pure C, so `verify-windows-boundaries.ps1` permits it in `windows/app`.
  CI must build it (CMake) — verify on the first CI run.
- **`QPainter` cell rendering under heavy output** → repaint only damaged rows
  (libvterm damage callback) and coalesce paint requests via the existing queued
  connection; cap repaint frequency. The heavy-output test (terminal_model_test)
  carries over to the emulator.
- **Input translation gaps** → ship the common set first (printables, Enter, Backspace,
  Tab, Ctrl+C, arrows, F-keys); document what's deferred. A missed combo degrades
  gracefully (Qt falls back to the key char).
- **Scrollback correctness** → the wrapper's ring buffer is unit-tested (eviction,
  scroll-then-write); the spec's bounded-scrollback scenario covers it.
- **`TerminalBuffer` removal** → migrate its tests first, then delete in the same
  change to avoid a dangling unused target.

## Migration Plan

Incremental, each step keeps Windows CI green:

1. **Add `libvterm`** via `FetchContent` + a `lithe_windows_libvterm` static target;
   confirm it builds on CI.
2. **`TerminalEmulator` + unit tests** (feed VT, assert grid: colors, cursor,
   alt-screen, scrollback eviction). Pure C++; g++-testable off-Windows.
3. **`TerminalSurface` widget + `terminal_keys`**; offscreen Qt test asserting
   keystroke→byte translation and resize→transport.resize with a fake.
4. **Switch the session** to own a `TerminalEmulator`; route output to it; add
   `TerminalSession::resize`.
5. **Re-host `TerminalView`** on `TerminalSurface`; remove the `QLineEdit`.
6. **Real-ConPTY integration test**: drive a session with colored/cursor output and
   assert the emulator grid (Windows CI).
7. **Remove `TerminalBuffer`** + its test; update CMake.

Rollback: steps 1–3 are additive and removable. Step 4–5 is the switchover; revert
restores the `TerminalBuffer`/`QPlainTextEdit` path.

## Open Questions

- **Scrollback depth default**: 2000 rows matches the Mac value and the current
  `TerminalBuffer::MaximumRows`. Confirm or pick a different default during step 2.
- **Font**: keep `QFontDatabase::systemFont(FixedFont)` for now (Nerd-font is a
  follow-up non-goal); confirm the cell-size math handles the chosen font's metrics.
- **Selection/copy scope**: ship basic text selection + clipboard copy in the surface,
  or defer entirely to a follow-up? Recommend shipping basic copy (select-drag →
  Ctrl+C copies) since it is cheap and expected; styled selection is follow-up.
