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
| Git | changes, commits, branches, diffs, history, worktree-aware PR publication context, validation, and mutation results | Git executable discovery, credentials, process environment |
| GitHub | remote parsing, trusted request plans, normalized branch comparisons and pull requests/reviews/comments, deterministic ordering, and stable errors | OAuth configuration, HTTPS, browser opening, and operating-system credential storage |
| Runtime | Java/Maven requirements, normalized candidates, and effective toolchain references | JDK/Maven probing and executable paths |
| Language tooling | provider catalog, local fallback results, complete LSP process/session runtime, capabilities, diagnostics, UTF-16 edits, and normalized feature results | executable/environment discovery and UI provider routing |
| Java/Maven/Spring | deterministic Maven-root selection, project structure, modules and profiles; compiler diagnostic parsing; Java source structure, symbols, code vision, run-configuration detection, Spring configuration/bean/endpoint indexing, and JDTLS/Java Debug adapter policy | JDK/Maven discovery, local dependency-repository selection, Java/Maven child processes, and sockets |
| Run/Debug | versioned configuration documents, three-layer resolution, diagnostics, platform-neutral launch plans, DAP framing/state, reverse terminal requests, breakpoint relocation, stepping filters, threads, stacks, variables, and events | project and preference persistence, native edit reporting, adapter discovery, PTY/ConPTY debuggee launch, child processes, sockets, native termination, and UI |
| Terminal | input bytes, output bytes, lifecycle | PTY/ConPTY, shell and environment |
| Workbench background | versioned source (`none`, bundled slot `01`–`10`, or `custom`) and opacity | UI, image rendering, bundled-resource packaging, local-image access permission and persistence |
| Local History | revision metadata, text content, restore result | persistence location and file operations |
| Modules | stable IDs, manifests, enabled state, lifecycle snapshots, dependencies, capabilities, and contributions | native factories, processes, timers, PTY/ConPTY, watchers, connections, and UI rendering |
| Community integrations | Discourse authorization sessions, RSA-OAEP callback verification, user API protocol models, and normalized community data | opening the system browser, receiving URL callbacks, and credential-vault persistence |

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

## Document Lifecycle Contract

An open document, rather than an editor widget, owns live text for the lifetime
of its tab. Recreating Monaco, `NSTextView`, syntax services, or an LSP binding
must reattach to that document and must not read an older memoized snapshot.

Persistence state is one of `clean`, `dirty`, `saving`, or `conflict`.
`saving` retains `operationId` and the immutable revision being written. A save
completion only clears dirty state when it still owns that operation and no
newer revision exists. A watcher may reload a clean document, but an external
change to a dirty or saving document enters `conflict` and preserves live text
until the user chooses Keep Editor or Load Disk Version. Platforms own text and
native I/O; Rust Core owns the deterministic boundary-event decisions.

Workspace visibility and project detection exclude nested checkout containers
named `.worktree` or `.worktrees` by default, so a copied project is not treated
as a second set of sources or runnable services.

Process-backed features use the shared request fields `operationID` and
optional `timeoutMilliseconds`. Adapters emit lifecycle states `starting`,
`running`, `stopping`, `finished`, and `failed`; `operationID` lets the UI
ignore stale termination events after a restart. `stop()` is the cancellation
operation and must terminate the platform process without changing feature
state owned by another operation.

Java workspace activation is a shared Core decision over visible relative
paths. Any workspace containing a non-ignored `.java` source starts one JDT LS
session asynchronously, even without Maven or Gradle metadata. That session is
owned by the workspace and remains alive until the workspace closes or the user
explicitly restarts it. `ready` means JDT LS has completed project import, not
merely that the process answered `initialize`.

JDT LS runs only on the Temurin JDK 21 bundled with Lithe. This runtime is
independent of project Run/Debug JDK selection and has no user-configurable
path. A missing or invalid bundle is a packaging failure. The application shows
preparing, ready, failure, and timeout notifications; a navigation command while
preparing ends after the notice and is never replayed later.

macOS and Windows adapters discover the selected JDT LS installation's Equinox
launcher JAR, platform configuration directory, Lombok agent, Java Debug
Server, and bundled Java executable. Java Test-capable adapters additionally
submit ordered extension bundles; Rust Core owns their ordering and
de-duplication, the JVM flags, and direct `java`/`java.exe` startup with array
arguments. The macOS TestNG runner remains a packaged native resource used only
when a TestNG session starts. Packaged JDT LS therefore has no runtime dependency
on shell wrappers, PowerShell, or the user's `PATH`. Legacy wrappers are an
external-plan compatibility fallback and are not the packaged execution path.

Java test discovery remains a language-service workflow rather than a UI or
Debug Core parser. When the Tests tool window is opened or refreshed, the
language facade asks the Java Test extension for each candidate source file's
class and method tree, then projects stable fully qualified identifiers into
the native list. Closing the tool window, changing workspace, or reloading the
Java runtime cancels the owning discovery operation; late results cannot replace
the current workspace's tree. Discovery does not create a Debug session, result
socket, adapter connection, or target JVM.

Starting one JUnit or TestNG file, class, or method creates a short-lived native
loopback result listener on demand. JDT LS owns project/test metadata, Rust Core
owns deterministic DAP launch argument projection, and the Debug module owns the
adapter session. Repeated launch, stop, project close, runtime reload, and launch
failure all cancel the active operation and release the listener. The selected
Run configuration remains the source of project-scoped Java runtime selection;
JDT LS remains authoritative for the test runner classpath, working directory,
and test-specific VM and program arguments.

Platforms observe JDT LS version and non-recursive build-file metadata, while
Rust Core alone validates and reduces those observations to the opaque workspace
fingerprint. macOS and Windows adapters must not duplicate its ordering,
de-duplication, or serialization rules.

Editor changes use versioned incremental document synchronization and do not
restart the session or clear its index. Workspace watchers coalesce Maven and
Gradle changes before one project refresh and publish normalized watched-file
events. Platform adapters mark selected JDT LS caches as recently used, ask
Rust Core which inactive caches exceed the 30-day retention period, and delete
only those validated directories. **Java: Rebuild Index** remains the explicit
recovery path for the current workspace key.

Language feature clients route through a provider interface rather than
depending directly on an LSP session. Process-free providers remain available
when an executable is missing. LSP-backed features are enabled only after the
server advertises them during initialize or dynamic registration. The shared
core owns JSON-RPC state, stdio, process lifecycle, and normalized results;
platform adapters own executable and provider-resource discovery. Detailed
invariants are documented in
[`language-tooling.md`](../../docs/architecture/language-tooling.md).

Session lifecycle is a single discriminated state, never a set of booleans.
Capability negotiation is separately `unknown` or `known`; a known capability
is then supported or unsupported. Failures retain stable `code`, `stage`, exit
code, and diagnostic detail across the Rust, Swift, and TypeScript boundaries.
Domain and adapter layers return stable reasons rather than user-facing prose;
each product's presentation layer owns localized notification text.

Debugger stepping policy is portable. Rust Core owns adapter defaults,
normalization, validation, adapter launch projection, and the `isFiltered`
classification on normalized stack frames. Platform products own preference
persistence and decide whether matching consecutive frames are collapsed or
expanded in their native call-stack UI. No Debug session, adapter process, or
background task is created merely because stepping preferences exist.

Exception pause metadata is portable when the adapter advertises the standard
exception-information request. Rust Core normalizes the exception type,
description, break mode, stack trace, evaluation name, and nested details;
native products decide how that data is presented beside the current frame's
ordinary scopes and variables. An adapter that supplies no object reference
does not make the exception itself expandable through this contract.

Debugger variable paging is portable. Rust Core owns the standard DAP
`filter`, zero-based `start`, and positive `count` request projection and
normalizes adapter-reported `namedVariables` and `indexedVariables` counts to
non-negative values. Native products own tree expansion and page-size policy;
the macOS reference product loads at most 100 children per request, appends
named children before indexed children, exposes an in-tree load-more action,
and discards stale pages after the selected frame changes. A native client must
also stop offering more pages when an adapter returns more children than were
requested or repeats an already loaded page.

Debugger terminal launch ownership is split at the native boundary. Rust Core
advertises terminal support, validates and normalizes DAP `runInTerminal`
reverse requests, correlates the platform response, and rejects stale or
duplicate completions. The platform Terminal module owns PTY/ConPTY creation,
direct executable-and-argument startup, environment application, process IDs,
terminal presentation, and native termination. A Debug session is still lazy:
neither a terminal nor a debuggee process exists until an adapter requests one.

Debugger disconnect ownership is portable. A session started with `launch`
owns its local debuggee and sends `terminateDebuggee: true` when stopping. A
session started with `attach` does not own the remote JVM and sends
`terminateDebuggee: false`; closing the native transport must therefore detach
without killing the remote process. A session stopped before launch or attach
also uses the non-terminating policy.

For JDT LS, the standard initialize handshake and project-import readiness use
separate Core-owned deadlines. Project import fails only after 45 seconds
without changed progress or the 10-minute absolute safety cap; platform clients
must not impose a shorter readiness deadline. The terminal timeout code is
`serviceReadyTimeout`, and its details preserve the last import, download, and
cache snapshot for both products.

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

GitHub authorization is independent of a Lithe account. Device Flow is the
preferred path, and its token is stored only in the platform credential store.
The application boundary never exposes that token to a view or persistence
fixture. See [`github.md`](github.md).

## UI Boundary

The UI sends commands to an application feature model and renders state from
that model. It must not construct `Process`, file watchers, terminals, runtime
locators, Git command runners, or persistence stores. Platform-specific actions
such as directory picking, file-browser reveal, clipboard access, and native
shortcut monitoring are capability ports, not application logic.

## Workbench Background Contract

[`workbench-background-v1.schema.json`](workbench-background-v1.schema.json)
defines the portable background preference. It stores only a stable bundled
slot ID, `custom`, or `none`, plus opacity. A bundled slot is the same product
identifier on every platform; each product packages and renders its own copy of
that slot's image. `custom` deliberately contains no path, bookmark, token, or
image bytes. Native file access authorization and local-image metadata are
platform-private, so a preference can be understood on another platform
without leaking an unusable absolute path or macOS security-scoped bookmark.

Search and Git examples are kept in `shared/fixtures/`. New behavior should
add a fixture before adding a second platform implementation.

Run configuration behavior is exposed through the `runConfig.*` commands.
Platform clients coordinate inspection, generation, resolution, typed document
edits, and launch planning, but must not implement a second JSON merger,
toolchain matcher, ID generator, argument parser, or Java/Maven argument
builder. Opening a project inspects existing files without writing; generation
is an explicit user action. Shared project overrides stay in
`.lithe/run/configurations.json`. Machine-local overrides may live in
`.lithe/run/local.json` or in a host-owned document supplied as
`localDocument`; absolute toolchain paths belong only in that local layer and
are excluded from project visibility and Git by default. Generic runtime
executables such as Node are selected in `.lithe/toolchains/local.json`; this
machine-local document is also excluded from Git by default. Missing or
incompatible toolchains block only configurations that consume the affected
toolchain, while diagnostics without a configuration ID apply to the project.
Runtime consumption is declared by the detector from the actual command rather
than inferred from the provider namespace. An automatically discovered runtime
path is session-effective: validation and launch share it, but persistence
still requires an explicit user selection.

Maven tool-window execution uses `maven.launchPlan`; platform views do not
assemble Maven arguments. Portable profile and Skip Tests defaults conform to
[`maven-portable-configuration-v1.schema.json`](maven-portable-configuration-v1.schema.json).
The transient Core request conforms to
[`maven-launch-context-v1.schema.json`](maven-launch-context-v1.schema.json).
External `settings.xml`, Maven executable, and Maven JDK paths remain in a
machine-local store. They may be supplied transiently to Core for planning and
fingerprinting, but Core never opens `settings.xml` or serializes those paths
into the portable project context.

The Java language-server startup consumes that same context. Core exposes the
selected `settings.xml` to JDT LS as
`java.configuration.maven.userSettings`, then applies the sorted Profile set
to the reactor and every recursively declared Maven module after JDT LS
reports `ServiceReady`. The Java session remains `initializing` until those
project updates all succeed; a rejected or timed-out update fails the session
instead of silently retaining the previous Maven model.

Maven-backed Run and Debug launch planning consumes the current project Maven
context. A Run Configuration's explicit Profiles and toolchain paths take
precedence; explicit `cwd` and `extensions.maven.skipTests` values also take
precedence, including `skipTests: false`. Unset values inherit the project
settings. The shared Core applies the final Maven argument order for all three
entry points. Tool-window module launches add `-am`; Run and Debug retain their
existing `-pl <module>` behavior without implicitly building dependencies.
