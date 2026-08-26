# Repository Layout and Sharing Rules

Lithe contains two independent platform applications connected by a small set
of shared contracts. macOS is the current reference product. Windows is a
React/Tauri implementation; it must not import Swift source or depend on macOS
types.

## Top-level layout

```text
Lithe-IDEA/
├── macos/Sources/Lithe/          # macOS SwiftUI/AppKit application
│   ├── Application/        # composition, feature models, and lifecycle policy
│   ├── Core/               # ports, language catalogs, and typed Rust operations
│   ├── Models/             # UI aggregate, bridges, and domain-grouped value types
│   ├── Platform/MacOS/     # macOS composition root and adapters
│   ├── Services/           # workflows grouped by product domain
│   └── Views/              # SwiftUI/AppKit presentation grouped by feature
├── macos/Sources/Lithe*Module/   # independently owned built-in modules
├── macos/Sources/LitheModuleAPI/ # module lifecycle, catalog, and plugin contracts
├── macos/Sources/LitheCoreContracts/ # platform-neutral feature contracts
├── macos/Sources/LitheRustCore/  # Swift Package C bridge declarations
├── macos/Resources/        # macOS metadata, icons, localization, and assets
├── Plugins/
│   ├── mac/Official/       # macOS plugin manifests, source, tests, and Bundle metadata
│   └── win/                # Windows-owned plugin packages
├── macos/Tests/LitheTests/       # Swift Testing unit tests
├── rust/lithe-core/        # shared Rust commands, models, and C ABI
├── windows/                # React/Tauri Windows application and Rust adapters
├── shared/                 # contracts and cross-platform fixtures
├── shared/fixtures/projects/ # reusable Java, Maven, Spring Boot, and Git data
├── scripts/                # build, packaging, fixture, and verification tools
├── docs/                   # product, architecture, release, and QA docs
├── infra/docker/           # repository-owned containerized validation environments
├── third_party/            # pinned upstream manifests and narrowly required source patches
└── Package.swift           # macOS Swift Package Manager definition
```

## Platform layers

The macOS package is intentionally kept at the repository root so existing
SwiftPM, release, and preview commands remain stable:

```text
SwiftUI/AppKit → AppModel → Application Feature Models → AppServices
                                      ├── Rust Core operations
                                      └── macOS ports and adapters
```

The Windows implementation has the corresponding web/native layers:

```text
windows/tauri/src/           React workbench, feature stores, and presentation
windows/tauri/src/platform/  frontend boundary for shared and native commands
windows/tauri/src-tauri/     Tauri composition and Windows-owned Rust adapters
```

Both platforms consume `rust/lithe-core` through the same JSON envelope and
command names. The Windows Tauri host links the Rust crate directly while
macOS uses the C ABI. Shared behavior belongs in `shared/contracts/` and should
have a fixture under `shared/fixtures/` before the second platform relies on it.

## Swift source organization

Directories inside the macOS executable target express ownership rather than
visibility. SwiftPM discovers them recursively, so moving a file between these
directories must not require a target or product change:

```text
macos/Sources/Lithe/
├── Application/
│   ├── Composition/  # application service graphs and module resource owners
│   ├── Features/     # UI-facing state transitions and user actions
│   └── Lifecycle/    # application-level lifecycle policy and errors
├── Core/
│   ├── Language/     # language-provider catalog adapters
│   ├── Ports/        # platform-neutral interfaces
│   └── Rust/         # typed Rust JSON/C ABI adapters
├── Models/
│   ├── AppModel/     # AppModel aggregate and focused extensions
│   ├── Bridges/      # executable-target conformance bridges
│   └── <Domain>/     # editor, diff, Java, runtime, search, and workspace values
├── Services/<Domain>/ # product workflows grouped by their owning domain
└── Views/<Feature>/   # presentation grouped by the user-facing feature
```

Feature module targets use the smallest applicable subset of the following
convention. A directory should exist only when the target owns that kind of
code:

```text
macos/Sources/Lithe<Feature>Module/
├── Module/       # module entrypoint and feature graph
├── Application/  # feature state and UI-facing coordination
├── Models/       # domain and value types
├── Ports/        # interfaces owned by the feature
├── Services/     # workflows
├── Runtime/      # process, protocol, and session implementations
└── Providers/    # provider implementations
```

Official language-support plugins additionally use `Capabilities/`, `Plugin/`,
and `Support/` for exported language abilities, the native plugin entrypoint,
and shared identifiers. New files should be named after their primary type;
use `Type+Concern.swift` only for a focused extension or executable-target
bridge. Do not rename module IDs, capability IDs, JSON fields, C symbols, or
plugin entrypoint names as part of physical source reorganization.

Plugin packages are platform-owned. macOS plugins live under `Plugins/mac/`
and Windows plugins under `Plugins/win/`; neither platform may compile source
from the other platform's plugin tree. Shared plugin wire contracts and
fixtures remain under `shared/` rather than either platform directory.

## Rust Core packages

`rust/lithe-core/src/lib.rs` is only the crate composition root and public API. Rust implementation files are grouped by stable ownership boundary instead of being added beside `lib.rs`:

```text
rust/lithe-core/src/
├── protocol/    # command names, wire contracts, responses, errors, events, cancellation
├── runtime/     # JSON dispatcher and C ABI exports
├── project/     # files/search, local history, Markdown, Maven project inspection
├── execution/   # run configuration, launch/toolchain models, project detectors
├── languages/   # language-specific source inspection such as Java
├── git/         # Git validation, parsing, state, and mutations
├── lsp/         # generic LSP, lightweight fallback, provider/Swift adapters
└── tests/       # command-level tests grouped by the same domains
```

The dependency direction is `protocol <- domain packages <- runtime/FFI`. A domain may use protocol contracts, but it must not depend on the runtime dispatcher. `execution/types.rs` is the shared type layer for configuration and detectors, so those modules do not import each other through the package facade. `lsp/mod.rs` and the other package `mod.rs` files are compatibility facades; new implementation logic belongs in an owned submodule rather than in the facade.

Moving Rust files must not change JSON command strings, Serde field names, error codes, or the exported C symbols. Directory-sensitive fixtures and embedded resources must use `CARGO_MANIFEST_DIR` instead of paths derived from a module's current depth.

### Rust Core comment standard

First-party production modules under `rust/lithe-core/` start with an English
`//!` description of their responsibility or boundary. Exported APIs, shared
request and response structures, core domain types, and C ABI functions use
`///`; unsafe entry points document pointer ownership and `# Safety`
requirements. Enums, structs, variants, and fields whose names do not make
their semantics, allowed values, units, ownership, or protocol role immediately
clear are documented even when they are internal. Implementation comments explain non-obvious compatibility,
determinism, ordering, security, performance, or cross-platform constraints.
They should explain why the code has its shape instead of narrating individual
statements. Tests document scenarios or regression risks only when their names
and assertions are not already sufficient.

## Ownership rules

| Shared Rust Core | Platform-owned adapters |
| --- | --- |
| Workspace traversal and search rules | Root selection and directory watching |
| UTF-8 file command validation and results | Native file APIs, permissions, and persistence paths |
| Git models, validation, parsing, and mutations | Executable environment and credentials |
| History metadata and snapshot rules | History storage location and file movement |
| Language provider catalog, lightweight features, complete LSP runtime, Maven, and Java source parsing | Language-server/JDK/Maven discovery; Maven/Debug child processes |
| Error codes, cancellation, deadlines, and JSON envelope | PTY/ConPTY, signals, handles, and native UI |

The UI must depend on feature models and shared models, not on a concrete
adapter. Core and Services must remain free of AppKit, SwiftUI, Tauri, WebView2,
Win32, `Process`, and direct platform file APIs.

Language tooling has an additional protocol/application split: Rust owns the
complete LSP process/session runtime and normalized results, while platform
services own discovery, provider routing, and UI projection. The complete rules are in
[`language-tooling.md`](language-tooling.md).

## Repository hygiene

Do not commit generated outputs such as `.build/`, `.swiftpm/`, `dist/`,
`DerivedData/`, fixture build directories, or local IDE configuration. Keep
release notes, contract fixtures, verification scripts, and the screenshots
referenced by the public README files.

`third_party/` is not a general upstream archive. Prefer an immutable manifest,
verified build-time download, and an artifact-local license/notice over a full
repository snapshot. Complete upstream source belongs there only when Lithe
actually compiles a documented local patch. Platform runtime assets and plugin
payloads stay with their owning platform resource or plugin package.

`infra/` owns repository-level development and validation infrastructure that
is not an implementation detail of macOS, Windows, or the shared Rust Core.
Container definitions used to validate database helpers belong under
`infra/docker/`; product Docker features remain in their owning platform code.
