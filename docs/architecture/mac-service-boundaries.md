# macOS Service Boundaries

The macOS implementation is being separated around a Rust application core. The
Swift ports remain useful for capabilities that are genuinely macOS-owned, while
the Rust core owns behavior that the future Windows UI must consume unchanged.

## Layers

```text
Sources/Lithe/Core/Ports/       Platform-neutral capability interfaces
Sources/Lithe/Core/Terminal/    Pure terminal buffer and escape parsing
Sources/Lithe/Application/      Platform-neutral service graph and UI feature facades
Sources/Lithe/Platform/MacOS/  FSEvents, FileManager, Process, PTY, and shell adapters
Sources/Lithe/Services/        Product workflows and domain orchestration
Sources/Lithe/Models/           SwiftUI-facing application state
Sources/Lithe/Views/            SwiftUI/AppKit presentation
rust/lithe-core/                Cross-platform commands, models, errors, and events
Sources/LitheRustCore/          C ABI bridge used by the Swift application
```

Core ports must not import SwiftUI, AppKit, CoreServices, or use `Process` and
`Pipe` directly. macOS implementations belong under `Platform/MacOS`.

Current ports include:

- `ProcessRunner` for synchronous commands such as Git and runtime probes;
- `StreamingProcess` for text-output Java, Maven, and debug processes;
- `RawProcessSession` for byte-oriented LSP traffic;
- `TerminalTransport` for shell sessions and PTY behavior;
- `WorkspaceFileSystem` and `WorkspaceFileOperations` for workspace I/O;
- `FileStorage` for search index and Local History persistence;
- `KeyValueStore` for preferences and project/workbench state;
- `ArchiveEntryReader` for JDK source archive lookup;
- `RuntimeLocator` for JDK/Maven discovery and executable selection;
- `DirectoryChangeSource` for external file events.
- `PlatformUI` for directory picking, file-browser reveal, and clipboard access;
- `ShortcutDetector` for native shortcut monitoring.

`AppServices` is the platform-neutral service graph. `MacServiceContainer`
constructs it with macOS adapters; a Windows composition root will construct an
equivalent graph with Windows adapters. `AppModel` owns macOS presentation
state and application orchestration, but it no longer knows how to construct
platform adapters. Its `MavenFeatureModel`, `JavaRunFeatureModel`,
`JavaDebugFeatureModel`, and `RuntimeSettingsFeatureModel` projections are the
only service-facing objects passed into the corresponding views.

Services no longer construct `Process`, `Pipe`, `FileManager`, `UserDefaults`,
shell transports, or runtime discovery directly. Views must not receive
concrete workflow services; they receive an application model or UI feature
model and send user actions through that boundary.

Small native interactions used by application workflows also go through ports:
`AppModel` must not import AppKit or call `NSOpenPanel`, `NSWorkspace`,
`NSPasteboard`, or `NSEvent` directly. The macOS implementations live under
`Platform/MacOS/UI/`.

The update checker remains deliberately macOS-owned under
`Platform/MacOS/Updates/`, because DMG mounting, application replacement,
`NSWorkspace`, and privileged installation are not cross-platform service
logic. Windows will provide a separate update implementation.

Run `./scripts/verify-service-boundaries.sh` after service changes. The check
guards the boundary against direct platform API or Mac adapter references being
added back into `Core` or `Services`, and prevents concrete workflow services
from being passed directly into views.

## Migration Rule

The Rust core is the public application boundary for both platforms. Migrate one
capability at a time, keep the existing Swift implementation as a fallback until
the macOS behavior is verified, and add a shared fixture before exposing the
capability to Windows.

The current Rust boundary includes workspace snapshots and search,
workspace-relative file operations, Git status/diff/apply/write/history and
related models, Local History storage, Maven descriptor and diagnostic parsing,
and Java source parsing and model operations. It owns deterministic parsing,
validation, ordering, and JSON protocol behavior.

The platform boundary remains responsible for filesystem watchers and native
dialogs, Git executable discovery and credentials, JDK/Maven discovery, JDT LS,
Java/Maven/Debug processes and transports, terminal sessions, native UI,
installers, and updates. These services continue to use Swift ports on macOS
and will use equivalent Windows adapters; they are not duplicated inside the
Rust core.
