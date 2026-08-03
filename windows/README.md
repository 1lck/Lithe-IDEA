# Windows implementation

The Windows application will be implemented independently from the macOS application. The planned stack is Qt Widgets with C++ services and Windows platform adapters.

Windows code must not import or modify the SwiftUI/AppKit application. Match macOS product behavior through the contracts and fixtures in [`shared`](../shared/README.md), while keeping Windows-specific process, path, file-watching, terminal, installer, and update logic in this directory.

No Windows implementation has been added yet.
