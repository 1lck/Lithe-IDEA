# Keep platform implementations independent

Lithe uses two independent platform implementations with a small set of shared contracts. macOS remains the reference product and keeps its existing SwiftUI/AppKit architecture. Windows will reproduce the same product behavior with Qt Widgets and C++ without changing the macOS runtime.

## Use the current repository layout

```text
Lithe-IDEA/
├── Sources/Lithe/          # macOS SwiftUI/AppKit application
├── Resources/              # macOS metadata, localization, and runtime assets
├── Package.swift           # macOS Swift package
├── windows/                # Windows Qt/C++ implementation
├── shared/                 # Cross-platform contracts and acceptance material
├── Fixtures/               # Existing reusable Java and Git fixtures
├── scripts/                # macOS build and repository verification scripts
├── docs/                   # Product, architecture, release, and QA documentation
└── .github/workflows/      # Platform-specific CI and release workflows
```

The macOS package stays at the repository root. Moving it under another application directory would change local commands, release automation, and existing documentation without improving the Windows boundary.

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

Git, search, Java, Maven, and JDT LS may have separate implementations. Verify their behavior with the same fixtures instead of coupling the applications through a shared runtime library.

## Keep generated files out of the repository

The following directories are local outputs and can be recreated:

- `.build/` and `.swiftpm/`;
- `dist/`;
- `Fixtures/**/target/`;
- `DerivedData/`;
- untracked visual QA artifacts.

Keep only the screenshots referenced by the public README files. Keep source assets, fixture metadata, release notes, and verification scripts even when the running application does not load them directly.
