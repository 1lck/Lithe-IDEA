# macOS product

This directory owns the macOS application implementation:

- `Sources/` contains the SwiftUI/AppKit host, built-in Swift modules, shared
  Swift contracts, and the macOS C bridge for the Rust Core.
- `Tests/` contains host and built-in-module tests plus verifier executables.
- `Resources/` contains app metadata, icons, fonts, localizations, and packaged
  macOS assets.

Official plugin packages remain under the repository-level
`Plugins/mac/Official/` directory so their manifests, sources, and tests are
co-located and visibly separate from the host application. The repository-level
`Package.swift` is the SwiftPM composition manifest that references both roots.

Do not put Windows implementation code, shared Rust implementation, downloaded
third-party source trees, or generated build artifacts in this directory.
