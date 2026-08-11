# Windows implementation

Windows is an independent Qt Widgets/C++ implementation. Shared behavior is
provided by `rust/lithe-core` through its C ABI and JSON command protocol; the
macOS SwiftUI/AppKit application is not a Windows dependency.

## Use the Qt/C++ implementation

Qt Widgets, C++23, Win32 adapters, and the Rust core ABI are the supported
Windows development baseline. New Windows work must extend this implementation
and its existing boundaries. Electron, Node.js, and other parallel desktop
runtimes are not part of the supported Windows architecture.

## Development environment

Use a Windows 10/11 environment with:

- Visual Studio 2022/MSVC and the Windows SDK.
- CMake 3.24 or later.
- Stable Rust with the `x86_64-pc-windows-msvc` target.
- Qt 6 built for MSVC 2022 64-bit when building the Qt workbench.

JDK and Maven are only needed for Java and Maven features. NSIS is only needed
for Windows installer packaging.

The exact versions used by CI may change independently of these ranges. The
Windows build script configures the Rust library and CMake build; Qt must be
available to CMake through the normal Windows toolchain environment.

## Development boundary

Keep Windows-specific UI, file watching, PTY/ConPTY, runtime discovery,
installer, update, and native platform logic under `windows/`. Reuse shared
behavior through `rust/lithe-core`, `shared/contracts`, and `shared/fixtures`.
See the [Windows development plan](../docs/architecture/windows-development-plan.md)
for implementation scope and ordering.

## Terminal

The terminal is a real VT/ANSI emulator. `windows/app/algorithms/terminal_emulator.cpp`
wraps libvterm (vendored, pure C, under `windows/third_party/libvterm/`) into a
cell grid with SGR colors, a bounded 2000-row scrollback, cursor tracking, and
an alternate screen. `TerminalSession` owns one emulator per ConPTY session and
tracks display metadata (start time, elapsed readout, working-directory name,
exit code) that the UI chrome reads; `TerminalSurface` (Qt) renders the grid,
forwards keys, and resizes the PTY with the widget. The superseded
`TerminalBuffer` text-row parser has been removed.

`TerminalPanel` shows the sessions as tabs in one Mac-style header row on the
tool-header background: a terminal glyph + the localized "终端" title on the
left, pill-style session tabs (rounded subtle-selection active state, per-tab
`×` close buttons), and a right-aligned status bar (`TerminalStatusBar`, the
QTabWidget corner widget) with a state dot (green while running), the session
display title, the current-directory name, a per-session elapsed readout
(`MM:SS`), the exit code once a session stops (green on 0, orange otherwise),
and the `+` / `∨` / `…` / `−` icon-style toolbar buttons. Tab titles are
index-based (`Local`, `Local (2)`, `Local (3)`) like the macOS terminal, with a
lifecycle suffix while a session is starting, stopping, exited, or failed. The
canvas pads the surface by 8px on the macOS background color `#121315`.

Still open: clickable links, OSC cwd/title reporting, and a per-session shell
picker.

## Validation

Run the Windows/Qt build and platform-specific tests only in a Windows + MSVC
+ Qt environment or Windows CI. macOS can run platform-independent checks, but
it cannot replace Windows validation for Qt, Win32, ConPTY, registry, DPAPI,
installer, update, or signing behavior.

When changing Windows boundaries, run
`scripts/verify-windows-boundaries.ps1` or the platform-equivalent validation
command used by CI.
