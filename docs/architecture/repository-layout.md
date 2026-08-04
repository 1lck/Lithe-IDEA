# Keep platform implementations independent

Lithe uses two independent platform implementations with a small set of shared contracts. macOS remains the reference product and keeps its existing SwiftUI/AppKit architecture. Windows is being developed as a separate Qt Widgets/C++ implementation without changing the macOS runtime.

## Use the current repository layout

```text
Lithe-IDEA/
├── Sources/Lithe/          # macOS SwiftUI/AppKit application
│   ├── Application/        # platform-neutral service graph and UI facades
│   ├── Core/               # ports and pure domain logic
│   └── Platform/MacOS/     # macOS composition root and adapters
├── Resources/              # macOS metadata, localization, and runtime assets
├── Package.swift           # macOS Swift package
├── rust/                   # Rust shared application core and C ABI
├── Sources/LitheRustCore/  # Swift Package C bridge for the Rust library
├── windows/                # Windows Qt/C++ implementation
├── shared/                 # Cross-platform contracts and acceptance fixtures
├── Fixtures/               # Existing reusable Java and Git fixtures
├── scripts/                # build, packaging, and cross-platform verification scripts
├── docs/                   # Product, architecture, release, and QA documentation
└── .github/workflows/      # Platform-specific CI and release workflows
```

The Windows implementation is split into explicit layers:

```text
windows/core/               C++ client for the Rust C ABI
windows/adapters/           platform ports and Win32 adapters
windows/qt/                 Qt Widgets workbench
```

The macOS package stays at the repository root. Moving it under another application directory would change local commands, release automation, and existing documentation without improving the Windows boundary. Both macOS and Windows consume the Rust core through the same JSON C ABI.

## Share contracts before code

Add content to `shared/` only when both platforms consume the same stable input or expected output. Prefer schemas, fixtures, command names, error categories, and acceptance cases.

Keep these areas platform-owned:

| macOS | Windows |
| --- | --- |
| SwiftUI/AppKit views and state | Qt Widgets views and state |
| FSEvents | `ReadDirectoryChangesW` |
| macOS PTY and shell handling | ConPTY and Windows shell handling |
| DMG installation and update | Windows installation and update |
| macOS runtime discovery | Windows runtime discovery |

The Rust core currently owns deterministic workspace traversal, search,
workspace-relative file operations, Git models and mutations, history
metadata, Maven descriptor/diagnostic parsing, and Java source parsing. The
platform implementations still own filesystem watchers, native file dialogs,
Git executable environment, JDK/Maven discovery, JDT LS and Java/Maven/Debug
processes, terminal sessions, native UI, and installers or updates. See
[`shared/contracts/application-boundary.md`](../../shared/contracts/application-boundary.md)
for the cross-platform split.

## Keep generated files out of the repository

The following directories are local outputs and can be recreated:

- `.build/` and `.swiftpm/`;
- `dist/`;
- `Fixtures/**/target/`;
- `DerivedData/`;
- untracked visual QA artifacts.

Keep only the screenshots referenced by the public README files. Keep source assets, fixture metadata, release notes, and verification scripts even when the running application does not load them directly.
