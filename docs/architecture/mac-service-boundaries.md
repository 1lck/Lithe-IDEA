# macOS Service Boundaries

The macOS implementation is being separated in Swift before any Rust migration.
The goal is to make platform behavior replaceable without changing the workbench
and application workflows.

## Layers

```text
Sources/Lithe/Core/Ports/       Platform-neutral capability interfaces
Sources/Lithe/Core/Terminal/    Pure terminal buffer and escape parsing
Sources/Lithe/Application/      Platform-neutral service graph and UI feature facades
Sources/Lithe/Platform/MacOS/  FSEvents, FileManager, Process, PTY, and shell adapters
Sources/Lithe/Services/        Product workflows and domain orchestration
Sources/Lithe/Models/           SwiftUI-facing application state
Sources/Lithe/Views/            SwiftUI/AppKit presentation
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

The update checker remains deliberately macOS-owned under
`Platform/MacOS/Updates/`, because DMG mounting, application replacement,
`NSWorkspace`, and privileged installation are not cross-platform service
logic. Windows will provide a separate update implementation.

Run `./scripts/verify-service-boundaries.sh` after service changes. The check
guards the boundary against direct platform API or Mac adapter references being
added back into `Core` or `Services`, and prevents concrete workflow services
from being passed directly into views.

## Migration Rule

Do not rewrite every service at once. Move one capability behind a port, keep
the existing product behavior, add or update a focused verification, and only
then migrate the next capability. Rust is a later implementation option for
the stable core; it is not required for this Swift boundary work.
