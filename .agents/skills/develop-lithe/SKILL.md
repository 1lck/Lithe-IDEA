---
name: develop-lithe
description: Apply Lithe repository architecture, cross-platform contracts, coding rules, hardcoding restrictions, and validation workflow. Use for every implementation, refactor, review, debugging, test, build, or documentation task in the Lithe repository.
---

# Develop Lithe

Follow these instructions for all work in this repository. Prefer the existing
architecture, nearby code, and executable verification scripts over generic
framework conventions.

## Read the relevant source of truth

- Read the implementation and tests around a change before editing it.
- For ownership or dependency changes, read
  `docs/architecture/repository-layout.md` and the relevant platform boundary
  document.
- For cross-platform behavior, read `shared/contracts/application-boundary.md`,
  `shared/contracts/rust-core-api.md`, and the related fixtures.
- Do not introduce a new architectural direction as part of an unrelated task.

## Respect repository ownership

| Path | Responsibility |
| --- | --- |
| `macos/Sources/Lithe/Views/` | SwiftUI/AppKit presentation and view-local rendering |
| `macos/Sources/Lithe/Models/` | UI-facing models and the `AppModel` aggregate |
| `macos/Sources/Lithe/Application/` | Feature models, state transitions, and user actions |
| `macos/Sources/Lithe/Services/` | Product workflow orchestration |
| `macos/Sources/Lithe/Core/` | Platform-neutral ports and typed Rust operations |
| `macos/Sources/Lithe/Platform/MacOS/` | macOS adapters and composition |
| `rust/lithe-core/` | Deterministic shared commands, models, validation, and C ABI |
| `windows/` | React/Tauri Windows product and Rust platform adapters |
| `Plugins/mac/` | macOS-owned plugin packages |
| `Plugins/win/` | Windows-owned plugin packages |
| `shared/` | Cross-platform contracts and fixtures, not compiled implementation |
| `infra/` | Repository-level development and validation infrastructure |
| `third_party/` | Upstream code; leave unchanged unless the task explicitly targets it |

macOS is the current reference product. Windows is an independent React/Tauri
implementation and must not import Swift source or depend on macOS types.

## Preserve application boundaries

- Views receive `AppModel` or a dedicated feature model. They must not call the
  Rust C ABI, construct platform adapters, or depend on concrete workflow
  services.
- Application feature models own UI state transitions and coordinate user
  actions. Keep platform setup out of `AppModel`.
- Services orchestrate workflows through ports. They must not directly create
  `Process`, `Pipe`, `FileManager`, `FileHandle`, watchers, persistence stores,
  or concrete `Mac*` adapters.
- Core and application code must remain free of SwiftUI, AppKit, CoreServices,
  Tauri, WebView2, Win32, and concrete platform implementations.
- `MacServiceContainer` is the macOS composition root. Platform capabilities
  belong in `macos/Sources/Lithe/Platform/MacOS/`.
- Deterministic behavior shared by both products belongs in `rust/lithe-core/`.
  Native filesystem, process, terminal, runtime, security, persistence, and UI
  behavior belongs in platform adapters.
- Windows feature code must import `@/platform/tauri-core` instead of the Tauri
  core API directly. Shared operations route through `lithe-core`; Windows-only
  terminal, watcher, credential, process, and WebView behavior stays in the
  Tauri host or a platform plugin.

## Keep shared contracts deterministic

- Use UTF-8 JSON for process and language boundaries.
- Use workspace-relative paths with `/` separators as identifiers. Absolute
  paths are allowed only in platform-owned diagnostics.
- Use one-based line numbers and `null` for missing locations.
- Keep lists and serialized results deterministically ordered.
- Represent asynchronous operations with explicit `idle`, `loading`, `ready`,
  and `failed` outcomes where the application contract requires them.
- Return stable error codes and user-facing messages. Put platform-specific
  details in the contract's `details` field.
- Preserve `operationID`, cancellation, timeout, and stale-result semantics for
  process-backed features.
- Add or update a shared fixture before a second platform relies on new shared
  behavior.
- Treat command names, JSON fields, error codes, and the C ABI as compatibility
  surfaces. Update contract documentation and every consumer when they change.

## Follow the codebase's language conventions

Apply the style used by surrounding files. Prefer descriptive names, focused
types and functions, explicit ownership, and straightforward control flow.
Avoid unrelated cleanup, speculative abstractions, and new dependencies that
the existing stack can reasonably avoid.

### Swift and macOS

- Use the Swift 6.2 toolchain. The application target intentionally uses Swift
  5 language mode while tests use Swift 6 language mode; do not change these
  modes as part of unrelated work.
- Put presentation in Views, feature state in Application, orchestration in
  Services, interfaces in Core ports, and native APIs in Platform/MacOS.
- Use the existing Swift Testing patterns under `macos/Tests/LitheTests/`.
- Keep platform-specific types from leaking through shared or application
  interfaces.

### Rust

- Run `cargo fmt` and follow existing crate and module conventions.
- Keep shared results deterministic and preserve the JSON envelope and C ABI.
- Return structured failures across the boundary; do not expose unstable Rust
  implementation details as contract error codes.
- Add tests in the owning crate for changes to commands, parsing, validation,
  ordering, cancellation, or serialization.

#### Rust Core comments

Apply the following comment standard to first-party code under
`rust/lithe-core/`. It does not require comment coverage in the database helpers,
Windows/Tauri Rust crates, generated code, or third-party sources.

- Write comments in English and keep them accurate when behavior changes.
- Start each production module with a concise `//!` description of its
  responsibility or architectural boundary.
- Use `///` for exported APIs, shared request and response types, core domain
  types, and C ABI functions. Document ownership and add `# Safety` for unsafe
  entry points; describe errors only when the failure contract is not obvious.
- Document enums, structs, variants, and fields whenever their names alone do
  not make their semantics, allowed values, units, ownership, or protocol role
  immediately clear. This requirement applies to internal types as well as
  exported contracts.
- Use `//` inside implementations to explain non-obvious decisions and
  constraints involving compatibility, determinism, ordering, security,
  performance, or cross-platform behavior.
- In tests, comment the scenario, regression risk, or boundary being protected
  when the test name and assertions do not make that intent clear.
- Do not narrate statements, restate descriptive names, or add comments to
  trivial accessors and straightforward control flow solely for coverage.
- Run `./scripts/verify-rust-core-comments.sh` before slower Rust Core checks.
  It enforces module documentation, exported Rustdoc, English comments, and
  unsafe API safety sections without requiring documentation on every internal
  helper. Still review changed internal types and implementations for the
  semantic cases above, which a static check cannot judge reliably.

### Windows React and Tauri

- Use Bun for frontend scripts and Tauri 2 for the Windows host. Keep React
  feature code in `windows/tauri/src/features`, reusable UI in
  `windows/tauri/src/ui`, the invoke boundary in
  `windows/tauri/src/platform`, and native Rust behavior in
  `windows/tauri/src-tauri`.
- Do not restore a parallel C++/Qt application layer or one Tauri command per
  shared Core operation. Translate compatibility command names through the
  central platform dispatcher.
- Add frontend tests for product behavior and Rust tests in the owning crate.
  Verify WebView2, ConPTY, installer, signing, and updater behavior on Windows.

## Avoid hardcoded environment details

- Never commit credentials, tokens, private endpoints, signing material, or
  personal data.
- Do not embed developer-machine paths, workspace roots, home directories,
  temporary directories, or tool installation paths in application logic.
- Resolve executables, storage locations, and platform defaults through the
  appropriate adapter or configuration mechanism.
- Keep stable product constants named and centralized. Do not duplicate magic
  strings or numbers across platforms.
- Test fixtures may use clearly fake values, but must not contain real secrets
  or machine-specific paths.

## Handle failures explicitly

- Do not silently discard errors. Return, translate, or log them at the layer
  that has enough context to act on them.
- Preserve stable contract error categories when crossing Rust, Swift,
  TypeScript, Tauri, or process boundaries.
- User-facing failures should be actionable without exposing credentials,
  environment contents, or unnecessary internal details.
- Comments should explain non-obvious constraints or decisions, not narrate the
  code.

## Run validation that matches the change

Run the smallest relevant checks while iterating, then the broader affected set
before handoff.

| Change | Minimum relevant validation |
| --- | --- |
| Swift application or tests | `./scripts/test-macos.sh` |
| Core, Services, Views, or composition boundaries | `./scripts/verify-service-boundaries.sh` |
| Shared application behavior or JSON fixtures | `./scripts/verify-shared-contracts.sh` |
| Rust Core, JSON C ABI, or Swift bridge | `./scripts/verify-rust-core.sh` |
| Core feature behavior | `./scripts/verify-core.sh` |
| Git graph behavior | `./scripts/verify-git-graph.sh` |
| Windows boundaries from macOS/Linux | `./scripts/verify-windows-boundaries.sh` |
| Windows implementation on Windows | `./scripts/build-windows.ps1 -Configuration Release`, then `cargo test --manifest-path windows/tauri/src-tauri/Cargo.toml` |

Also run tests for directly affected crates or targets. If the current machine
cannot run a platform-specific check, state that clearly; do not claim an
unexecuted check passed.

## Keep changes reviewable

- Preserve existing uncommitted work and avoid modifying unrelated files.
- Do not commit generated output such as `.build/`, `.swiftpm/`, `target/`,
  `dist/`, `DerivedData/`, fixture build directories, or local IDE settings.
- Do not perform broad formatting or dependency updates as part of a focused
  fix.
- Do not use destructive Git commands, create commits, push branches, or change
  release metadata unless the task explicitly requests it.
- Update architecture or contract documentation when behavior, ownership, or a
  compatibility surface changes. Do not rewrite docs for an implementation-only
  refactor that leaves the documented behavior intact.

## Complete the work honestly

Before reporting completion, confirm that the change is in the owning layer,
relevant tests or verification scripts were run, shared consumers were checked,
and no machine-specific hardcoding was introduced. Report what changed, what
was verified, and any remaining platform or test limitations.
