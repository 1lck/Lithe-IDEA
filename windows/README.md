# Windows implementation

Windows is an independent WinUI 3/C++ implementation. Shared behavior is
provided by `rust/lithe-core` through its C ABI and JSON command protocol; the
macOS SwiftUI/AppKit application is not a Windows dependency.

## Phase 1 status

The source implementation for workspace/files/editor, search and replacement,
Git/Diff/conflicts/Shelf, Local History, settings, terminal, and workbench
session restoration is complete for the first Windows validation pass. Project
compilation and execution, Java/Maven/JDT LS parity, Run/Debug, and breakpoints
are explicitly outside this phase. Windows CI and rendered UI validation remain
the final acceptance gates and are not claimed by macOS static checks.

## Use the WinUI 3 implementation

WinUI 3 with C++/WinRT, C++23, Win32 adapters, and the Rust core ABI are the
supported Windows development baseline. The app is unpackaged and uses a
self-contained Windows App SDK deployment. New Windows work must extend this
implementation and its existing boundaries. The former Qt source remains only
as a temporary behavior reference during migration; it is not the release UI.

## Development environment

Use a Windows 10/11 environment with:

- Visual Studio 2022/MSVC and the Windows SDK.
- CMake 3.24 or later.
- Stable Rust with the `x86_64-pc-windows-msvc` target.
- The WinUI 3 and C++ desktop development workloads installed in Visual Studio.

JDK and Maven are only needed for Java and Maven features. NSIS is only needed
for Windows installer packaging.

The WinUI project currently pins Windows App SDK `2.2.0` and C++/WinRT
`3.0.260715.1`. Build the complete Windows client from a Visual Studio 2022
developer PowerShell:

```powershell
.\scripts\build-windows.ps1 -Configuration Release -BuildWinUI
.\windows\build-winui\x64\Release\Lithe.exe
```

## Development boundary

Keep Windows-specific UI, file watching, PTY/ConPTY, runtime discovery,
installer, update, and native platform logic under `windows/`. Reuse shared
behavior through `rust/lithe-core`, `shared/contracts`, and `shared/fixtures`.
See the [Windows development plan](../docs/architecture/windows-development-plan.md)
for implementation scope and ordering.
The source-level visual and interaction contract is documented in the
[Windows UI parity contract](../docs/architecture/windows-ui-parity.md). It
maps the macOS `LitheTheme` tokens to WinUI resources and defines the states
that must be present before the final Windows rendering pass.
The final CI and disposable-workspace checklist is in the [Windows validation
handoff](../docs/architecture/windows-testing-handoff.md).

## Validation

Run the WinUI build and platform-specific tests only in a Windows + MSVC
environment or Windows CI. macOS can run the platform-independent C++ and Rust
tests plus static XAML and boundary checks, but it cannot replace Windows
validation for generated C++/WinRT code, Win32, ConPTY, registry, DPAPI,
installer, update, or signing behavior.

When changing Windows boundaries, run
`scripts/verify-windows-boundaries.ps1` or the platform-equivalent validation
command used by CI. Before the final Windows pass, also run
`scripts/verify-winui-static.sh` on macOS; it checks XAML structure, event
handlers, centralized Lithe resources, and duplicate generated names without
requiring WinUI rendering.
