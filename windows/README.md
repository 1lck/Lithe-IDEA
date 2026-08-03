# Windows implementation

The Windows UI will be implemented with Qt Widgets and C++, while the shared application behavior will be provided by `rust/lithe-core` through its C ABI and JSON command protocol.

Windows code must not import or modify the SwiftUI/AppKit application. Match macOS product behavior through the Rust API, contracts, and fixtures in [`shared`](../shared/README.md), while keeping Windows-specific PTY/ConPTY, file-watching, terminal, installer, update, and native UI logic in this directory.

The Windows UI and binding layer have not been added yet. The first Rust API commands available for that work are documented in [`shared/contracts/rust-core-api.md`](../shared/contracts/rust-core-api.md).
