# Application Boundary Contract

The application boundary describes product behavior that a SwiftUI/AppKit or
React/Tauri Windows UI can consume. It does not describe widgets, threads, processes,
or operating-system APIs. It defines the cross-platform contract; current
product scope and setup are documented in [`README.md`](../../README.md); the
verification scripts are the executable source of boundary checks.

## Data Rules

- All payloads are UTF-8 JSON when exchanged across a process or language boundary.
- Workspace paths are relative to the opened workspace and use `/` separators.
- Absolute paths may appear at native editor/process boundaries and as LSP
  `file://` URIs, but are not persisted as cross-platform identifiers.
- Product-facing line numbers are one-based. Editor/LSP positions explicitly use
  zero-based lines and UTF-16 columns. Missing locations are `null`.
- Lists have deterministic ordering so contract fixtures can be compared directly.
- Every asynchronous operation exposes `idle`, `loading`, `ready`, and `failed` outcomes.
- Failures contain a stable `code` and user-facing `message`; platform details belong in `details`.

## Feature Contracts

| Feature | Shared input/output | Platform-owned implementation |
| --- | --- | --- |
| Workspace | visible snapshot, relative paths, file metadata, deterministic ordering | workspace root selection, native dialogs, and watchers |
| Documents | relative-path validation, UTF-8 read/write results, dirty/save state | native file integration and external-change notifications |
| Search | query matching, deterministic result ordering, symbols, and replacement preview | workspace lifecycle and optional index persistence |
| Git | changes, commits, branches, diffs, history, validation, and mutation results | Git executable discovery, credentials, process environment |
| Runtime | Java/Maven requirements, normalized candidates, and effective toolchain references | JDK/Maven probing and executable paths |
| Language tooling | provider catalog, local fallback results, complete LSP process/session runtime, capabilities, diagnostics, UTF-16 edits, and normalized feature results | executable/environment discovery and UI provider routing |
| Java/Maven/Spring | deterministic Maven-root selection, project structure, modules and profiles; compiler diagnostic parsing; Java source structure, symbols, code vision, run-configuration detection, Spring configuration/bean/endpoint indexing, and JDTLS adapter policy | JDK/Maven discovery, local dependency-repository selection, Java/Maven child processes, sockets, and JDB transport |
| Run/Debug | versioned configuration documents, three-layer resolution, diagnostics, and platform-neutral launch plans | project file persistence, child processes, sockets, and JDB transport |
| Terminal | input bytes, output bytes, lifecycle | PTY/ConPTY, shell and environment |
| Local History | revision metadata, text content, restore result | persistence location and file operations |
| Modules | stable IDs, manifests, enabled state, lifecycle snapshots, dependencies, capabilities, and contributions | native factories, processes, timers, PTY/ConPTY, watchers, connections, and UI rendering |

## Module Lifecycle Contract

The macOS reference product implements the built-in manifest in
`shared/fixtures/modules/built-in-v1.json`. Module IDs and manifest fields are
platform-neutral compatibility surfaces. A future Windows implementation may
adopt the contract independently without sharing Swift implementation code or
being coupled to the macOS migration schedule. An implementation of this
contract must preserve these invariants:

- A disabled module is not instantiated and owns no task, timer, watcher,
  session, connection, or child process.
- An on-demand module is instantiated only after its capability is requested.
- Sleeping stops every owned resource and releases the module instance.
- Active non-interruptible work holds a lease that blocks sleep with a reason.
- Wake reconstructs the module, activates declared dependencies first, and
  republishes capabilities and contributions.
- Required modules cannot be disabled. A provider cannot be disabled while an
  enabled module depends on it.
- Module state is one of `disabled`, `inactive`, `activating`, `active`, `idle`,
  `preparingToSleep`, `sleeping`, `sleepBlocked`, or `failed`.
- Native plugin manifests, compatibility, ownership, and signatures are
  validated before Bundle loading. A failed optional package is reported to
  plugin management and does not prevent required modules from starting.
- Successfully loaded native plugin module IDs remain durably marked for the
  process lifetime. An unclean exit leaves the mark behind, so the next launch
  quarantines those modules before constructing any plugin Bundle. A clean
  application termination clears the mark.
- Disabling a loaded in-process native plugin stops its module-owned resources
  immediately. Its code remains mapped until restart, and the next launch
  skips the Bundle before invoking its principal class or factories.
- Plugin update, rollback, and uninstall operations that affect mapped code
  are finalized before plugin scanning on the next launch.
- Native plugin factories receive a read-only host context. Host services use
  stable IDs and shared protocols; plugin code cannot import a platform
  composition root or the application executable.
- AI Assistance, Terminal, Git, Search, Local History, Debug, and Java/Maven
  execution are built-in lifecycle modules. They are not marketplace plugins.
- Java language tooling remains part of the built-in product. Every other
  language provider is represented by an independently configurable bundled
  language-support plugin; Go uses the signed native-package path while the
  remaining providers share the host's generic language-server module.
- A downloadable language support package may declare language-server,
  execution, testing, and debug module IDs under one language ID. All referenced
  modules must be owned by the same package. Execution and testing may share a
  module when they share one toolchain lifecycle; language-server and debug
  lifecycles remain independently addressable.
- Plugin-owned Run and Test operations may reuse deterministic shared launch
  plans, but the actual child process must use a session owned by the plugin
  module. A disabled plugin language must not fall back to a built-in process
  provider.
- Process-backed language ownership comes from verified installed manifests,
  including packages that are disabled, quarantined, or failed to load. Those
  states make the capability unavailable; they never restore a host process
  fallback.
- Extension execution shutdown completes only after its operating-system
  process exits. A bounded force-stop failure remains visible as an active
  module resource. Active Run and Test sessions hold leases; successful LSP
  document synchronization refreshes the owning module's idle timer.
- Language package manifests include inert file-extension, file-name, and
  project-file recognition metadata. The host may use this metadata to suggest
  an uninstalled plugin, but it must not load the Bundle or probe a toolchain
  during recognition.

Platform products do not share module-runtime implementation code. The stable
manifest, lifecycle semantics, and deterministic JSON representation are the
portable boundary.

Workspace visibility and project detection exclude nested checkout containers
named `.worktree` or `.worktrees` by default, so a copied project is not treated
as a second set of sources or runnable services.

Process-backed features use the shared request fields `operationID` and
optional `timeoutMilliseconds`. Adapters emit lifecycle states `starting`,
`running`, `stopping`, `finished`, and `failed`; `operationID` lets the UI
ignore stale termination events after a restart. `stop()` is the cancellation
operation and must terminate the platform process without changing feature
state owned by another operation.

Language feature clients route through a provider interface rather than
depending directly on an LSP session. Process-free providers remain available
when an executable is missing. LSP-backed features are enabled only after the
server advertises them during initialize or dynamic registration. The shared
core owns JSON-RPC state and normalized results; platform adapters own stdio and
process lifecycle. Detailed invariants are documented in
[`language-tooling.md`](../../docs/architecture/language-tooling.md).

## Error Codes

Use stable categories rather than platform error strings:

- `invalid_request`
- `workspace_not_found`
- `permission_denied`
- `not_supported`
- `runtime_missing`
- `process_start_failed`
- `process_failed`
- `parse_failed`
- `cancelled`
- `timed_out`
- `unknown`

## UI Boundary

The UI sends commands to an application feature model and renders state from
that model. It must not construct `Process`, file watchers, terminals, runtime
locators, Git command runners, or persistence stores. Platform-specific actions
such as directory picking, file-browser reveal, clipboard access, and native
shortcut monitoring are capability ports, not application logic.

Search and Git examples are kept in `shared/fixtures/`. New behavior should
add a fixture before adding a second platform implementation.

Run configuration behavior is exposed through the `runConfig.*` commands.
Platform clients coordinate inspection, generation, resolution, typed document
edits, and launch planning, but must not implement a second JSON merger,
toolchain matcher, ID generator, argument parser, or Java/Maven argument
builder. Opening a project inspects existing files without writing; generation
is an explicit user action. Local absolute paths belong only in
`.lithe/**/local.json` and are excluded from project visibility and Git by
default.
