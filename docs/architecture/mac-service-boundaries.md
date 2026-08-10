# macOS Service Boundaries

The macOS application uses a stable Rust Core boundary and a native adapter
layer. SwiftUI and AppKit render the product, application feature models own UI
state transitions, and macOS adapters provide capabilities that cannot be
shared with Windows.

## Runtime graph

```text
SwiftUI / AppKit Views
          ↓
AppModel: UI state, navigation, feature composition
          ↓
Application Feature Models
          ↓
AppServices + Swift Services
     ┌────┴───────────────┐
     ↓                    ↓
Rust operations       macOS ports/adapters
     ↓                    ↓
Rust Core + JSON C ABI  FileSystem / FSEvents / Process / PTY / UI
```

`MacServiceContainer` is the macOS composition root. It creates the Rust Core
bridge, Rust-backed workspace/Git/history/Java operations, Swift services, and
macOS adapters, then injects them into `AppServices`. A future Windows
composition root must construct the same application-facing ports with Windows
implementations.

## Source ownership

| Directory | Responsibility |
| --- | --- |
| `Sources/Lithe/Views/` | SwiftUI/AppKit presentation, input, navigation destinations, and view-local rendering. |
| `Sources/Lithe/Models/` | UI-facing models and value types. `AppModel` is the observable aggregate, not the platform composition root. |
| `Sources/Lithe/Application/` | Workspace, Document, Git, Search, Java, Terminal, Project History, and UI Feature Models. These coordinate state and user actions. |
| `Sources/Lithe/Services/` | Product workflow orchestration. Language feature routing and LSP/Maven/Run/Debug lifecycles remain Swift workflows behind ports; transport-independent LSP state and normalized results live in Rust. |
| `Sources/Lithe/Core/Ports/` | Platform-neutral interfaces for process, terminal, storage, runtime discovery, file operations, watchers, and native UI capabilities. |
| `Sources/Lithe/Core/Rust*` | Typed operations and model conversion for the shared Rust JSON contract. |
| `Sources/Lithe/Platform/MacOS/` | FSEvents, file operations, persistence, process sessions, PTY, runtime discovery, native UI, shortcuts, and updates. |
| `rust/lithe-core/` | Shared commands, validation, parsing, ordering, Git operations, history, and JSON/C ABI. |

## Rules

Core ports and application code must not import SwiftUI, AppKit, CoreServices,
or concrete `Mac*` types. They must not construct `Process`, `Pipe`,
`FileManager`, `UserDefaults`, or `FileHandle` directly.

Services must receive those capabilities through ports. A Service may own a
workflow state machine, such as language-provider routing or Maven/Debug
lifecycle, but it must not decide how the operating system starts, watches,
stores, or terminates the underlying resource. LSP JSON-RPC state and message
normalization belong to Rust Core, not a language-specific Swift service.

Views receive `AppModel` or a dedicated UI Feature Model. They must not receive
concrete workflow services, call the Rust C ABI directly, or construct platform
adapters.

The Rust Core owns deterministic cross-platform behavior:

- workspace snapshots, UTF-8 file reads/writes, search, and replacement preview;
- Git status, Diff, History, Blame, Stash, branch operations, remote sync,
  Clone, Commit, and patch application;
- Local History metadata and snapshot operations;
- Maven descriptor and diagnostic parsing;
- Java source structure, code vision, class-name, and run-configuration parsing;
- lightweight language features, LSP JSON-RPC state, framing, capabilities,
  diagnostics, and normalized feature results;
- request envelopes, cancellation, deadlines, error codes, validation, and
  stable JSON ordering.

macOS owns the platform side of these capabilities:

- workspace selection, FSEvents, atomic/native file operations, permissions,
  persistence location, and Finder integration;
- language-server/JDK/Maven discovery and process sessions;
- LSP/Java/Maven/Debug process transports, terminal PTY, shell, signals, and
  native handles;
- native window, menu, clipboard, shortcut, installer, and update behavior.

## Verification

Run this check after changing an application boundary:

```bash
scripts/verify-service-boundaries.sh
```

The script rejects platform imports and concrete adapter references in Core and
Services, direct workflow-service dependencies in Views, platform composition
in `AppModel`, and an oversized UI aggregate. Shared JSON behavior is checked
with `scripts/verify-shared-contracts.sh` and `scripts/verify-rust-core.sh`.

## Remaining migration work

The current boundary is usable and enforced, but it is not a claim that every
workflow has moved into Rust. Language provider routing, LSP process lifecycle,
Maven execution, Java Run/Debug sessions, and terminal session state are still
Swift application workflows using platform ports. Their remaining lifecycle
events should be promoted into shared contracts before Windows implements
equivalent UI. See [`language-tooling.md`](language-tooling.md) for the language
tooling split.
