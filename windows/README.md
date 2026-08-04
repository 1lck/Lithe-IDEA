# Windows implementation status

Windows is an independent Qt Widgets/C++ implementation. Shared application
behavior is provided by `rust/lithe-core` through its C ABI and JSON command
protocol; the macOS SwiftUI/AppKit application is not a Windows dependency.

Match macOS product behavior through the Rust API, contracts, and fixtures in
[`shared`](../shared/README.md). Keep Windows-specific file watching,
PTY/ConPTY, terminal, runtime discovery, installer, update, and native UI logic
in this directory.

The current implementation has three layers:

- [`core`](core/): `CoreClient` owns the UTF-8 response returned by the Rust C
  ABI and exposes the shared JSON envelope to C++.
- [`adapters`](adapters/): platform-neutral ports and Win32 implementations for
  file access, watching, processes, runtime discovery, terminal transport, and
  persistence.
- [`qt`](qt/): a working workspace workbench skeleton with project selection,
  tree browsing, file read/write, search, refresh, and watcher refresh.

Build the platform-independent C++ targets with:

```sh
cmake -S windows -B windows/build
cmake --build windows/build
```

The Qt target is optional and requires Qt 6. A Windows toolchain must also
provide the Rust library through `LITHE_RUST_CORE_LIBRARY` before packaging.
Real Windows compilation, Rust library packaging, installer/update behavior,
and full macOS feature parity remain incomplete. Run
`scripts/verify-windows-boundaries.sh` when changing the Windows boundaries.
