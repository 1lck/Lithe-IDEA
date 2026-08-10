## 1. Add the `libvterm` dependency

- [x] 1.1 Add `libvterm` to `windows/CMakeLists.txt` via `FetchContent` (pinned tag) or a vendored snapshot under `windows/third_party/libvterm/`; build it as a static `lithe_windows_libvterm` target.
- [x] 1.2 Confirm it compiles on Windows CI (and that the source/docs boundary stays clean: pure C, no Qt/Win32 includes).

## 2. TerminalEmulator (pure C++, replaces TerminalBuffer)

- [x] 2.1 Add `windows/app/algorithms/terminal_emulator.{h,cpp}`: wraps a `VTerm`/`VTermScreen`; exposes `write(bytes)`, `resize(cols, rows)`, `reset()`, `rows()`, `cols()`, `cell(row,col)` (glyph + SGR attrs), cursor position, scrollback (bounded ring buffer), and a damaged-rows notification for the renderer.
- [x] 2.2 Bound scrollback (default 2000 rows, matching `TerminalBuffer::MaximumRows`); evict oldest past the cap.
- [x] 2.3 Add `windows/tests/terminal_emulator_test.cpp` (plain `main` + `assert`): feed VT byte sequences and assert the rendered grid — SGR fg/bg color, bold/inverse, 256-color/truecolor, cursor positioning, line/display erase, alternate-screen enter/leave, scrollback eviction. Must build and pass off-Windows (g++; no `#ifdef _WIN32` body).
- [x] 2.4 Register in `lithe_windows_algorithms` (+ link `lithe_windows_libvterm`) and add the test target to `LITHE_WINDOWS_TEST_TARGETS`.

## 3. Input translation + Qt surface widget

- [x] 3.1 Add `windows/qt/terminal_keys.{h,cpp}`: map `QKeyEvent` to terminal input bytes — printables (UTF-8), Enter `\r`, Backspace `\x7f`, Tab `\t`, Ctrl+letter (Ctrl+C `\x03`), arrows/Home/End/PgUp/PgDn, F1–F12. Document the supported set.
- [x] 3.2 Add `windows/qt/terminal_surface.{h,cpp}` (`QWidget`): `paintEvent` reads the bound `TerminalEmulator` grid and draws cells (glyph + fg/bg + bold/inverse) + caret via `QPainter` using a monospace `QFont` and its metrics; `keyPressEvent`/paste call `terminal_keys` and forward bytes to the session; `resizeEvent` computes cols/rows and calls `session->resize`; vertical scrollbar for scrollback; repaint on damaged-rows notification (queued).
- [x] 3.3 Add `windows/tests/terminal_surface_test.cpp` (Qt offscreen): assert keystroke→byte translation (incl. Ctrl+C, arrows, Enter) via a fake transport, and that resizing the widget calls `transport.resize` with the expected cols/rows.
- [x] 3.4 Register sources in `lithe_windows_qt` and the test in `LITHE_WINDOWS_TEST_TARGETS`.

## 4. Route output and resize through the emulator

- [x] 4.1 `TerminalSession`: replace the `TerminalBuffer` member with a `TerminalEmulator`; route `onOutput` bytes to `emulator.write(bytes)`; add `TerminalSession::resize(cols, rows)` forwarding to the transport and emulator; `clear()` resets the emulator.
- [x] 4.2 Update `terminal_model_test.cpp` and `terminal_panel_test.cpp` assertions that read `render()` to read the emulator's grid/text instead (or keep a `render(maxChars)`-style plain-text snapshot on the emulator for backward-compatible assertions).

## 5. Re-host the Qt view on the surface widget

- [x] 5.1 `TerminalView`: replace the `QPlainTextEdit` + `QLineEdit` with a `TerminalSurface` bound to the session's emulator; remove the line-input returnPressed logic.
- [x] 5.2 Ensure focus is requested when the session becomes active (tab switch / new session), mirroring the Mac `requestInputFocus`.
- [x] 5.3 Verify per-session emulator state (screen, scrollback, cursor, alt-screen) survives tab switches via the existing `terminal_panel_test` (extend if needed).

## 6. Real-ConPTY integration test

- [x] 6.1 Extend `windows/tests/terminal_integration_test.cpp` (or add a sibling) to drive a real ConPTY `cmd` session with colored output (e.g. `echo [ESC[31m]RED[ESC[0m]`) and cursor movement, then assert the emulator grid shows the color and cursor position.
- [x] 6.2 Assert PTY resize: resize the surface (or call `session.resize`) and verify the shell's reported `$COLUMNS`/`$LINES` (or equivalent) reflects the new geometry.

## 7. Remove the superseded TerminalBuffer

- [x] 7.1 Delete `windows/app/algorithms/terminal_buffer.{h,cpp}` and `windows/tests/windows_algorithms_test.cpp::testTerminalBuffer` (migrate any still-relevant cases to `terminal_emulator_test.cpp`).
- [x] 7.2 Update `windows/CMakeLists.txt`: drop `terminal_buffer.cpp` from `lithe_windows_algorithms`.

## 8. Build, boundary, docs, CI

- [x] 8.1 `scripts/verify-windows-boundaries.ps1` passes (libvterm is pure C; `windows/app` still Qt/Win32-free; no `HANDLE`/`HPCON` in public headers).
- [x] 8.2 Windows CI green: `build-windows.ps1 -BuildQt` + `ctest`; confirm libvterm builds and the new emulator/surface tests pass.
- [x] 8.3 Update `docs/architecture/windows-development-plan.md` and `windows/README.md` if the terminal dependency/rendering notes change; note the follow-ups (links, OSC cwd/title, status bar, per-session shell) are still open.
