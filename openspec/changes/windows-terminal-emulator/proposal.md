## Why

The Windows terminal today renders output as **plain monochrome text** in a
`QPlainTextEdit`, fed by a `TerminalBuffer` that parses cursor-move/erase CSI but
**strips every SGR color sequence** (`terminal_buffer.cpp` does not handle `'m'`).
Input is a separate `QLineEdit` that only forwards whole lines. Consequences:

- No colors, no cursor, no bold/inverse — compiler and tool output loses all meaning.
- Full-screen TUIs (`vim`, `htop`, `less`) render as broken streaming text.
- The running shell **cannot receive arrow keys, Ctrl+C from the keyboard, Tab, or
  paste** — only the Interrupt button's `\x03` works; line editing is line-at-a-time.

The macOS terminal (`Sources/Lithe/Views/TerminalView.swift` +
`MacTerminalTransport.swift`) uses **SwiftTerm**, a real VT100/ANSI emulator: the user
types directly into the surface, colors/cursor/alt-screen render, and the PTY is
resized with the window. This change closes that gap on Windows — the single biggest
Mac-parity item, and the foundation that link-clicking, working-directory tracking, and
a rich status bar will later build on.

## What Changes

- Introduce a real **VT/ANSI terminal emulator** in the pure-C++ app layer, backed by
  `libvterm` (lightweight C library). It parses ConPTY output (SGR 256-color/truecolor,
  cursor positioning, erase, alternate-screen, scrollback) and exposes a renderable
  cell grid. It supersedes `TerminalBuffer` as the terminal's output model.
- Add a **Qt terminal surface widget** that renders that grid (cells with
  foreground/background color + attributes, a visible cursor, selection) and forwards
  **keystrokes directly to the PTY** (printable chars, arrows, Enter, Backspace, Tab,
  Ctrl+C, paste) via the transport, replacing the `QLineEdit`.
- **Resize the PTY** with the widget: map font-metric cell size to columns/rows and
  call the existing `TerminalTransport::resize(cols, rows)` (which today is never
  invoked, leaving the console stuck at 120×40).
- Per-session emulator state (grid, scrollback, cursor, alt-screen) **survives tab
  switches** because it lives in the session, not the widget.
- Preserve existing multi-session, scoped Clear/Interrupt/Restart, and whole-tree
  teardown behavior — this is a rendering/input change, not a lifecycle change.

No `**BREAKING**` changes to ports or the Rust core: the terminal stays off the
`rust/lithe-core` JSON protocol. `TerminalTransport` gains nothing new (`resize`
already exists); only the Qt layer and a new app-layer emulator component are added.

## Capabilities

### New Capabilities
- `windows-terminal`: extends the terminal capability (introduced by the sibling
  `windows-terminal-sessions` change) with real emulator rendering, direct keystroke
  input, and PTY resize. (Not yet present under `openspec/specs/` because the sibling
  change has not been archived; this delta adds requirements additively.)

### Modified Capabilities
<!-- None — openspec/specs/ has no archived terminal spec yet. -->

## Impact

- **New external dependency**: `libvterm` (C, MIT). Added via CMake `FetchContent`
  (pinned) or vendored under `windows/third_party/`. Pure C, no Qt/Win32 headers, so it
  is permitted inside `windows/app` by `verify-windows-boundaries.ps1`.
- **New app-layer code**: a `TerminalEmulator` (libvterm wrapper) under
  `windows/app/algorithms/` (replaces `TerminalBuffer`'s role), with unit tests that
  feed VT bytes and assert the rendered grid — pure C++, runs off-Windows with g++.
- **New Qt widget**: `windows/qt/terminal_surface.{h,cpp}` (renders the grid, forwards
  keys, resizes). Replaces `QPlainTextEdit` + `QLineEdit` in `terminal_view`.
- **Superseded**: `TerminalBuffer` is no longer the terminal's output model; it is
  removed (or kept only while tests migrate) in this change.
- **Session**: `TerminalSession` owns a `TerminalEmulator` instead of a `TerminalBuffer`;
  the model/panel wiring is unchanged.
- **Out of scope (follow-up changes)**: clickable file/URL links, live OSC
  working-directory + title tracking, the rich status readout, per-session shell
  choice/restart-with-shell, Nerd-font preference. These all layer on a real emulator
  and are deliberately deferred to keep this change reviewable.
