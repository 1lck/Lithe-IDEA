# Module Runtime Architecture

This document is the source of truth for feature isolation, lazy activation,
disablement, sleep, wake, and resource ownership in Lithe. Repository layer
rules still come from `repository-layout.md` and platform ownership rules from
`mac-service-boundaries.md`.

## Required outcome

A module is a runtime and dependency boundary, not merely a hidden UI surface
or a source directory. The completed architecture must satisfy all of these
invariants:

1. A disabled module is never instantiated and starts no task, timer, session,
   watcher, connection, or child process.
2. An inactive on-demand module is instantiated only when one of its declared
   capabilities is requested or the user explicitly activates it.
3. Every long-lived resource is registered to exactly one module resource
   scope.
4. A sleeping module has no active leases and owns zero active resources. Its
   instance is released and may be reconstructed later.
5. Active Run, Test, Build, Debug, Terminal, import/export, transaction, or
   other non-interruptible work blocks sleep with an observable reason.
6. Modules communicate only through Module API capabilities, immutable events,
   and declared contributions. They do not import another feature module's
   implementation.
7. Adding a module requires a target, manifest, factory, and registration. It
   must not require adding concrete service fields to `AppServices` or feature
   fields to `AppModel`.
8. Module identity, state, dependency, and lifecycle contracts remain
   platform-neutral. This migration implements them in the macOS reference
   product; Windows adoption is a separate effort owned by the Windows team.
9. Optional modules run in the application process and can therefore affect
   that process. Before optional module activation, the host persists an
   activation marker. An uncleared marker quarantines that module on the next
   launch, where it can be disabled or explicitly re-enabled without first
   constructing the module.
10. Safe Mode starts only required modules. It does not invoke optional module
    factories and does not overwrite the user's normal enabled preferences.

## Layers

```text
Lithe App Shell
    -> LitheApplicationKernel
        -> LitheModuleAPI
        -> platform capability ports
        -> registered feature module factories
```

- `LitheModuleAPI` contains stable IDs, manifests, lifecycle contracts,
  capabilities, events, leases, and resource interfaces. It imports no UI,
  platform adapter, Rust bridge, or feature implementation.
- `LitheApplicationKernel` validates the dependency graph, lazily constructs
  modules, controls state transitions, resolves capabilities, and enforces
  resource-zero sleep and shutdown.
- Platform composition roots register platform capabilities and module
  factories. They do not construct every feature service at application start.
- Feature modules are separate build targets. A feature target imports Module
  API and only the narrow shared model/port targets it needs.

## Module boundaries

| Module | Scope | Default | Long-lived resource ownership |
| --- | --- | --- | --- |
| Workspace Foundation | workspace | eager, required | workspace watcher and document persistence tasks |
| Git Review | workspace | on demand | Git observation and refresh tasks |
| Search & Index | workspace | on demand | index workers and caches |
| Local History | workspace | on demand | snapshot/retention tasks |
| Language Intelligence | workspace | on demand | Rust LSP sessions, LSP processes, polling tasks |
| Build / Run / Test | workspace | on demand | build, run, test processes and output sessions |
| Debug | workspace | on demand | debuggee and debug-adapter processes/sessions |
| Terminal | workspace | on demand | PTY, shell processes, terminal sessions |
| Database | workspace | disabled by default for new installs | sidecar requests, connections, backup timer and import/export tasks |
| AI Assistance | application | disabled until configured | credential-backed network requests |

Workspace Foundation is the only feature module that cannot be disabled while
a project is open. Editor rendering and application settings remain in the app
shell/design-system layers rather than becoming background modules.

## Dependency rules

- Module dependencies form an acyclic graph and are declared in manifests.
- A module depends on capability IDs, not another module's concrete service.
- A capability has one active provider. Multiple candidates require an explicit
  selection policy before registration; silent last-writer-wins is forbidden.
- Events communicate completed facts and never request synchronous work.
- UI/tool-window/settings contributions are inert data registered on the
  `ModuleFactory`, including placement, order, action ID, renderer ID, and
  visibility metadata. Reading this catalog must not instantiate the module.
  Workbench iterates contributions and delegates to platform action/renderer
  registries; it must not switch on module types or contribution IDs.
- Platform processes, files, PTY, keychain, and native UI are obtained through
  ports supplied in the module context.

## Lifecycle

```text
disabled -> inactive -> activating -> active -> idle
                    ^                 |          |
                    |                 |          v
                    +------ sleeping <- preparingToSleep
```

Failures are explicit. A module with active leases enters `sleepBlocked`; a
module whose resources remain active after stop also enters `sleepBlocked` or
`failed`. Hiding a panel never changes lifecycle state by itself.

This is recovery isolation, not process isolation. A defect in an in-process
module may terminate the current app process. The durable activation marker,
process-lifetime native-plugin marker, automatic quarantine, and `--safe-mode`
launch option ensure the next launch can recover without loading optional
module code.

Native plugin code loading has a separate durable marker from module
activation. The host writes every module ID owned by the package before it
loads the Bundle or asks its principal class for factories, and keeps the IDs
of successfully loaded native plugins marked until a clean application
termination. If that marker is still present on the next launch, those modules
are quarantined before any plugin Bundle is touched. A thrown load or
factory-validation error also quarantines its modules while allowing required
built-in modules to start. Multiple project containers share one process-level
recovery coordinator so a later container cannot mistake the current process's
marker for an interrupted prior launch.

## Plugin package lifecycle

Official plugin packages use a static `plugin.json` manifest. The host scans
and decodes this file, checks host/API compatibility, verifies one-to-one
module ownership, validates the complete dependency graph, and checks the
same-Team-ID code-signing policy before loading native code. Disabled,
quarantined, and Safe Mode plugins are filtered before `Bundle` creation.

The macOS package store keeps versioned package directories and an atomic
`installation.json` active-version pointer. Installation and verification are
staged before the pointer changes. A damaged optional package contributes a
management issue but cannot replace the required host catalog or prevent the
app shell from starting. Recovery actions use the installation record, so a
user can roll back or schedule removal even when the active manifest cannot be
decoded.

Process-backed language ownership comes from verified installed manifests, not
only from Bundles loaded in the current process. A disabled, quarantined, or
failed-to-load language package therefore keeps its language IDs reserved: the
host reports the capability unavailable and never restores a legacy built-in
LSP, run, or test process path.

Swift native bundles are not treated as safely unloadable. Disabling a loaded
plugin immediately shuts down its module graph and releases registered
resources, but the Bundle remains mapped until the process exits. Installation,
update, rollback, and uninstall therefore expose a restart-required state;
pending pointer changes and removals are finalized before plugin scanning on
the next launch.

The host passes plugin factories a read-only `PluginHostContext`. Services in
that context are addressed by stable IDs and exposed through narrow protocols
from shared contract targets. A plugin never imports the executable target or
constructs a macOS adapter. This keeps a new module's host integration to its
service protocol, service registration, static manifest, and package build.

Internal lifecycle modules and downloadable plugins are separate concepts.
Search, Git, Local History, Terminal, Debug, AI Assistance, Java/Maven
execution, Workspace Foundation, and the application/editor shell remain
statically composed even when they use `ModuleRuntime` for lazy activation or
sleep.

Only three process- or connection-owning backends may ship through the native
package path in 0.3.0:

1. database connections and their sidecar-owned resources;
2. language-server discovery, startup, sessions, and polling;
3. non-Java language support packages and their child processes.

Each language package groups installation, update, and disablement while
declaring separate LSP, execution/test, and optional debug lifecycles. Execution
and testing may share one module because they use the same language toolchain;
each operation still receives its own process session. LSP remains a separate
module so editing intelligence can stop, fail, or sleep independently. Their UI
and application-facing state remain built in and consume narrow capability
protocols. Java and Maven project execution remain built in behind the same
provider shape.

Go Support is the first released official native package. Its inert manifest
adds Go recognition to the Rust-backed language catalog without loading the
Bundle or probing `go`/`gopls`. Opening a Go document activates only the Go LSP
module. Running a current file, a Rust-detected `go.main`/`go.command` project
configuration, a service, or a test activates the Go Execution module and uses
a host-created process session tagged to that module. There is no built-in Go
process fallback once the package owns the capability, including after the
package is disabled and the app restarts. Running and testing sessions hold
module leases, so background sleep cannot interrupt active work. Once the last
session ends, the module becomes idle and its ten-minute policy may release it.
Disabling or sleeping the module stops every session in its resource pool and
waits for the operating-system process to exit, with bounded force termination;
failure leaves the module in an observable failed state. Successful document
synchronization refreshes the Go LSP idle timestamp, and LSP shutdown waits for
the Rust runtime's terminal state before the module is considered stopped.

An official package is added to `OfficialPluginCatalog` only after its Bundle,
host contract, disable/sleep behavior, and resource cleanup tests exist.
Packages live under
`Contents/Resources/OfficialPlugins`; macOS reserves direct children of
`Contents/PlugIns` for standard code bundles.

The sleep sequence is:

1. reject new activity;
2. verify no active lease;
3. prepare and persist recoverable state;
4. stop module-owned services;
5. stop registered resources;
6. verify the active resource count is zero;
7. remove exported capabilities and release the module instance.

Wake reconstructs the instance from its factory, activates declared
dependencies first, restores persisted state, then republishes capabilities.

## Current resource migration inventory

| Existing resource | Owning module after migration |
| --- | --- |
| `MacDirectoryWatcher` and workspace refresh tasks | Workspace Foundation |
| Git observation/refresh tasks | Git Review |
| search index and replacement work | Search & Index |
| snapshot retention and history operations | Local History |
| Java language-server discovery, Rust LSP sessions, LSP processes, polling | built-in Language Intelligence module |
| non-Java language-server discovery, Rust LSP sessions, LSP processes, polling | owning language support plugin |
| Java/Maven build, run, and test processes | built-in Execution module |
| non-Java run/test providers and child processes | owning language support plugin |
| `JavaDebugService`, DAP sessions, debuggee processes | Debug |
| `MacTerminalTransport`, PTY and shell | Terminal |
| database sidecar requests, connections, and connection-owned timers | Database Connections plugin |
| database UI and workspace state | built-in Database module |
| commit-message HTTP requests and imported credentials | AI Assistance |
| update checker | application shell, not workspace module |

## Migration and completion gates

Migration proceeds without changing public Rust JSON commands or platform
behavior:

1. Introduce Module API and Kernel with graph, lifecycle, resource, lease, and
   lazy-factory tests.
2. Wrap the current graph behind module factories while preserving behavior.
3. Extract database connection ownership behind a native plugin capability.
4. Extract LSP startup/session ownership behind a native plugin capability.
5. Keep Java/Maven execution built in and extract non-Java LSP/run/test/debug
   providers into per-language packages, beginning with Go Support.
6. Keep other feature targets statically composed and eliminate concrete
   feature fields from `AppServices` and `AppModel` where lifecycle isolation
   benefits from it.
7. Add settings/status UI from module snapshots and contributions.
8. Add a boundary verifier that rejects imports between feature targets and
   direct process ownership outside platform/Rust resource adapters.

### Target extraction prerequisite

Feature targets cannot depend on the `Lithe` executable target. Before moving
Search, History, Git, Execution, Debug, Terminal, Database, and AI
implementations, extract their platform-neutral models and ports into a
`LitheCoreContracts` library. The initial ownership set includes search/result
models, local-history DTOs, run/debug DTOs, terminal primitives, and the
Workspace/Git/History/process/HTTP capability ports. Feature targets then
depend only on `LitheModuleAPI`, `LitheCoreContracts`, and narrowly selected
workflow libraries. Empty feature targets or targets that re-export the
executable are not considered module isolation.

Completion requires executable macOS tests proving disabled factories are not
called, dependency activation order is deterministic, active leases prevent
sleep, sleep releases instances and all resources, wake reconstructs state,
shutdown releases every module, capability collisions fail, and the existing
macOS, Rust, and shared-contract verification suites pass. Windows source,
build files, and Qt composition are outside this migration's change scope.
