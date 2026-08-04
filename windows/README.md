# Windows implementation

The Windows UI will be implemented with Qt Widgets and C++, while the shared application behavior will be provided by `rust/lithe-core` through its C ABI and JSON command protocol.

Windows code must not import or modify the SwiftUI/AppKit application. Match macOS product behavior through the Rust API, contracts, and fixtures in [`shared`](../shared/README.md), while keeping Windows-specific PTY/ConPTY, file-watching, terminal, installer, update, and native UI logic in this directory.

The C++ binding seam is under [`core`](core/): `CoreClient` owns the
UTF-8 response returned by the Rust C ABI and exposes the same JSON envelope to
Qt. Build it with `cmake -S windows -B windows/build && cmake --build
windows/build`; linking the Rust library is left to the Windows packaging
toolchain. The Qt Widgets application and Win32 adapters are still pending.

The platform-neutral C++ adapter ports and Win32 implementations are under
[`adapters`](adapters/). They use Win32 file APIs, `ReadDirectoryChangesW`,
ConPTY, process handles, runtime discovery, and per-key persistence without
leaking those types into `CoreClient` or the Qt feature models. The optional
Qt Widgets target in `CMakeLists.txt` is a functional workspace workbench; the
packaging toolchain supplies the Rust library through
`LITHE_RUST_CORE_LIBRARY`.
