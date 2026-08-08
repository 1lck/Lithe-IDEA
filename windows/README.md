# Windows implementation

Windows is an independent Qt Widgets/C++ implementation. Shared behavior is
provided by `rust/lithe-core` through its C ABI and JSON command protocol; the
macOS SwiftUI/AppKit application is not a Windows dependency.

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

## Validation

Run the Windows/Qt build and platform-specific tests only in a Windows + MSVC
+ Qt environment or Windows CI. macOS can run platform-independent checks, but
it cannot replace Windows validation for Qt, Win32, ConPTY, registry, DPAPI,
installer, update, or signing behavior.

When changing Windows boundaries, run
`scripts/verify-windows-boundaries.ps1` or the platform-equivalent validation
command used by CI.
