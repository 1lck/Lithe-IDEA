# Repository Layout and Sharing Rules

Lithe contains two independent platform applications connected by a small set
of shared contracts. macOS is the current reference product. Windows is a
Qt/C++ implementation in progress; it must not import Swift source or depend
on macOS types.

## Top-level layout

```text
Lithe-IDEA/
├── Sources/Lithe/          # macOS SwiftUI/AppKit application
│   ├── Application/        # feature models and application service graph
│   ├── Core/               # ports, Rust operations, and terminal primitives
│   ├── Models/             # UI-facing models and value types
│   ├── Platform/MacOS/     # macOS composition root and adapters
│   ├── Services/           # workflow orchestration
│   └── Views/              # SwiftUI/AppKit presentation
├── Sources/LitheRustCore/  # Swift Package C bridge declarations
├── Tests/LitheTests/       # Swift Testing unit tests
├── rust/lithe-core/        # shared Rust commands, models, and C ABI
├── windows/                # C++ CoreClient, Win32 adapters, and Qt UI
├── shared/                 # contracts and cross-platform fixtures
├── Fixtures/               # reusable Java, Maven, Spring Boot, and Git data
├── scripts/                # build, packaging, fixture, and verification tools
├── docs/                   # product, architecture, release, and QA docs
├── Resources/              # macOS metadata, icons, localization, and assets
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

The Windows implementation has the corresponding native layers:

```text
windows/qt/       Qt Widgets workbench and UI state
windows/core/     C++ client for the Rust JSON C ABI
windows/adapters/ Win32 file, watcher, process, terminal, runtime, and storage adapters
```

Both platforms consume `rust/lithe-core` through the same JSON envelope and
command names. Shared behavior belongs in `shared/contracts/` and should have
a fixture under `shared/fixtures/` before the second platform relies on it.

## Ownership rules

| Shared Rust Core | Platform-owned adapters |
| --- | --- |
| Workspace traversal and search rules | Root selection and directory watching |
| UTF-8 file command validation and results | Native file APIs, permissions, and persistence paths |
| Git models, validation, parsing, and mutations | Executable environment and credentials |
| History metadata and snapshot rules | History storage location and file movement |
| Language provider catalog, lightweight language features, LSP state, Maven, and Java source parsing | Language-server/JDK/Maven discovery and child processes |
| Error codes, cancellation, deadlines, and JSON envelope | PTY/ConPTY, signals, handles, and native UI |

The UI must depend on feature models and shared models, not on a concrete
adapter. Core and Services must remain free of AppKit, SwiftUI, Win32, Qt,
`Process`, and direct platform file APIs.

Language tooling has an additional protocol/application split: Rust owns the
transport-independent LSP state and normalized results, while platform services
own provider routing and process lifecycle. The complete rules are in
[`language-tooling.md`](language-tooling.md).

## Repository hygiene

Do not commit generated outputs such as `.build/`, `.swiftpm/`, `dist/`,
`DerivedData/`, fixture build directories, or local IDE configuration. Keep
release notes, contract fixtures, verification scripts, and the screenshots
referenced by the public README files.
