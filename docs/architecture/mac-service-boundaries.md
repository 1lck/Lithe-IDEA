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
| `macos/Sources/Lithe/Views/` | SwiftUI/AppKit presentation, input, navigation destinations, and view-local rendering. |
| `macos/Sources/Lithe/Models/` | UI-facing models and value types. `AppModel` is the observable aggregate, not the platform composition root. |
| `macos/Sources/Lithe/Application/` | Workspace, Document, Git, Search, Java, Terminal, Project History, and UI Feature Models. These coordinate state and user actions. |
| `macos/Sources/Lithe/Services/` | Product workflow orchestration. Language feature routing plus Maven/Run/Debug lifecycles remain Swift workflows; the LSP service is a semantic facade over the Rust runtime. |
| `macos/Sources/Lithe/Core/Ports/` | Platform-neutral interfaces for process, terminal, storage, runtime discovery, file operations, watchers, and native UI capabilities. |
| `macos/Sources/Lithe/Core/Rust/` | Typed operations and model conversion for the shared Rust JSON contract. |
| `macos/Sources/Lithe/Platform/MacOS/` | FSEvents, file operations, persistence, process sessions, PTY, runtime discovery, native UI, shortcuts, and updates. |
| `rust/lithe-core/` | Shared commands, validation, parsing, ordering, Git operations, history, and JSON/C ABI. |

## Rules

### Per-session composition and coordination

`AppCompositionBuilder` constructs the feature graph and the `AppModel` shell.
`AppModelFeatureGraph` owns the eager feature instances for one project session.
Keep new state transitions in their feature or coordinator, not in another
`AppModel` extension.

| Owner | Responsibility |
| --- | --- |
| `WorkbenchFeatureModel` | Sidebar selection, settings presentation, and the mutually exclusive bottom tool window. |
| `CommitDraftFeatureModel` | Commit text, amend selection, generation state, and generated-message replacement confirmation. |
| `WorkspaceSessionCoordinator` | Workspace and standalone-file session state, recent projects, native access leases, close requests, workspace rebuild task ownership, and workspace-feature reset. |
| `EditorSessionCoordinator` | Document/media tab membership, editor selection coordination, restoring saved document order and selection, and resetting editor content. |
| `ShortcutSessionCoordinator` | Native shortcut monitoring, registration and recording subscriptions, active-session gating, and final shutdown. |
| `DocumentLanguageCoordinator` | Document-triggered language activation and cleanup, plus per-document hint refresh task coalescing and cancellation. |
| `DocumentFeatureComposition` | Connects document and language feature ports to session, settings, notifications, and optional module actions. |
| `WorkspaceProjectionComposition` | Connects workspace projection callbacks to document, workbench, editor-session, and other application owners. |
| `AppModelObservationBinder` | Compatibility change notifications for callers that still observe the aggregate. |
| `ModuleCapabilityStore` | Cached optional module capabilities and their observation cleanup. |
| `ModuleSessionCoordinator` | Module event subscription, release-driven binding cleanup, database-sidebar fallback, and coalesced runtime shutdown. |
| `SearchSessionFeatureModel` | Transient search, everywhere-search, and project-replacement presentation state. |
| `SearchModuleCoordinator` | Search capability activation, observation, caching, and initial index warming. |
| `SearchWorkflowCoordinator` | Project and everywhere search execution, stale-result validation, and search-module idle policy. |
| `ProjectReplacementCoordinator` | Project replacement preview/application and replacement-session cleanup; document/history work is injected. |
| `DatabaseModuleCoordinator` | Database capability activation, observation, caching, and suspension. |
| `HistoryModuleCoordinator` | Local-history capability activation, workspace configuration, observation, caching, and feature reset. |
| `ExecutionModuleCoordinator` | Execution capability activation, shutdown ordering, caching, feature observation, feature-access assembly, and Maven/Run/language-test lifecycle stop/reset. |
| `RunWorkflowCoordinator` | Run-project snapshot readiness, stale-opening checks, and ownership of the deferred run action including its resumption. |
| `JavaTestWorkflowState` | Cancellable Java test discovery/debug task ownership, operation identity checks, and Java test result-server cleanup. |
| `JavaTestDebugWorkflowCoordinator` | Java test debug launch task orchestration, stale-operation cleanup, result-server handoff, and launch failure reporting; it does not own the generic Debug session. |
| `LanguageNavigationCoordinator` | The in-flight navigation request state, operation-identity checks that discard superseded results, and language-server location projection into application navigation and editor-location values. |
| `LanguageEditingCoordinator` | Shared language-editing request value normalization, deterministic completion merging, and language-server result handling. |
| `LanguageWorkspaceEditService` | Workspace-edit validation, application, and rollback; document mutation and UI notifications are injected. |
| `DebugLaunchPreparationCoordinator` | Generic Debug startup preflight and launch-configuration resolution; it does not own Debug session lifecycle or UI presentation. |
| `DebugSessionCleanupCoordinator` | Debug adapter state transitions: tool-window presentation, application activation on pause, and per-session terminal and Java result-server teardown. |
| `DebugModuleCoordinator` | Debug capability activation, shutdown ordering, caching, session-state observation, feature-access assembly, and feature stop/reset. |
| `TerminalModuleCoordinator` | Terminal capability activation, observation, session retry, and terminal-session shutdown. |
| `GitModuleCoordinator` | Git capability activation, observation, callback composition, caching, and feature reset. |
| `LanguageIntelligenceModuleCoordinator` | Language-intelligence capability activation, cache lookup, binding handoff, language-server stop/diagnostic cleanup, and workspace-state reset. |

Coordinators do not depend on `AppModel`. Composition code may capture it weakly
for application actions that have not yet moved to their final owner. The
workspace composition still uses these compatibility actions for module
activation, navigation, and project-service loading; it is not yet a fully
independent application graph.

A coordinator holds the dependencies it needs rather than receiving them as
per-call closures. Values available at construction — the plugin catalog, the
module runtime, the notification channel — are constructor parameters. Re-entry
into application entry points goes through a protocol in
`Application/Features/WorkflowActionPorts.swift`, which the aggregate conforms
to and the coordinator holds weakly via `connect(actions:)`. This keeps a
coordinator testable against a spy instead of the application shell, and
`verify-service-boundaries.sh` rejects re-introducing the removed callback
parameters.

State that decides a workflow belongs to the coordinator that owns the
workflow, not to the aggregate: `RunWorkflowCoordinator` owns
`pendingRunAction` and `LanguageNavigationCoordinator` owns the navigation
state. The aggregate exposes read-only forwards for views that still observe
it.

### AppModel extension scope

Each `AppModel` extension covers one tool window or one domain —
`+RunConfiguration`, `+Debugging`, `+LanguageTests`, `+CodeNavigation`,
`+LanguageEditing`. A file that grows past roughly 600 lines is aggregating
unrelated features again and is rejected by `verify-service-boundaries.sh`.
Add a new domain file rather than extending an existing one past its subject.

The shortcut coordinator is inactive until explicitly activated. Deactivation
stops native monitoring but retains settings subscriptions for reactivation.
Shutdown also disconnects subscriptions and prevents later reactivation.
Queued commands are rejected while inactive, recording, or shut down. Native
adapters still own event monitors; the coordinator uses only the detector port.

The module-session coordinator keeps observing during a project switch so
release events clear cached capabilities before later activation. Final session
shutdown disconnects the event subscription after runtime cleanup. Concurrent
shutdown requests join one task; releasing the application shell does not
cancel runtime cleanup already in progress. Product-specific language extension
cleanup remains an explicitly composed callback.

`GitLogView` receives `GitFeatureModel`, workbench presentation models, and
`GitLogNavigation` callbacks. Branch, tag, and commit operations call the Git
feature directly. Comparison and commit-diff navigation stay at the application
boundary because they also change editor selection. `WorkbenchModuleUIComposition`
connects those callbacks; neither Git Log nor its dialogs receive `AppModel`.
`BranchComparisonView` and `GitCommitDiffReviewView` also observe the Git feature
directly. The editor host supplies a comparison-refresh callback to preserve
editor-selection behavior without giving the comparison view the aggregate.
`GitWorktreesView` uses the same direct Git observation pattern. Its
`GitWorktreeActions` supplies project opening, Finder reveal, path copying, and
parent-directory selection, including the create-worktree sheet. Native
capabilities are connected in the workbench composition, not constructed in
the Git view.
`BranchSwitcherPopover` likewise observes the Git feature. The workbench
activates Git and loads history in the popup's task, dismissing on activation
failure unless the task was cancelled. Comparison navigation and destructive
confirmation remain explicit host callbacks; opening a branch row still opens
its action menu rather than checking out immediately.
`DiffReviewView` observes Git diff state directly. Hunk controls receive the
same feature for commands without adding a subscription for every hunk.
Discard buttons request confirmation from the feature; the workbench remains
responsible for rendering the existing confirmation dialogs.
`ChangesSidebarView` now observes Git state and invokes stash/shelf operations
directly. Its operation and stash-conflict banners receive focused dependencies.
Commit draft presentation observes `CommitDraftFeatureModel` directly. The
sidebar still uses `AppModel` for commit submission, AI request orchestration,
and editor navigation; this remaining migration is not covered by the
scoped-view aggregate ban yet.

### Platform boundaries

Core ports and application code must not import SwiftUI, AppKit, CoreServices,
or concrete `Mac*` types. They must not construct `Process`, `Pipe`,
`FileManager`, `UserDefaults`, or `FileHandle` directly.

Services must receive those capabilities through ports. A Service may own a
workflow state machine, such as language-provider routing or Maven/Debug
lifecycle, but it must not decide how the operating system starts, watches,
stores, or terminates the underlying resource. The Rust LSP runtime is the
sole owner of its child process, stdio, JSON-RPC state, document versions,
request deadlines, diagnostics, and message normalization.

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
- lightweight language features and the complete LSP runtime: process,
  stdio/framing, lifecycle, documents, deadlines, capabilities, diagnostics,
  provider adapters, and normalized feature results;
- request envelopes, cancellation, deadlines, error codes, validation, and
  stable JSON ordering.

macOS owns the platform side of these capabilities:

- workspace selection, FSEvents, atomic/native file operations, permissions,
  persistence location, and Finder integration;
- language-server/JDK/Maven discovery and platform environment resolution;
- Java/Maven/Debug process transports, terminal PTY, shell, signals, and
  native handles (LSP process transport belongs to Rust);
- native window, menu, clipboard, shortcut, installer, and update behavior.

## Verification

Run this check after changing an application boundary:

```bash
scripts/verify-service-boundaries.sh
```

The script rejects platform imports and concrete adapter references in Core and
Services, direct workflow-service dependencies in Views, platform composition
in `AppModel`, reverse `AppModel` references in feature implementation code and
the scoped Git views (log, comparison, commit diff, working-tree diff, worktrees,
and branch switcher), and
an oversized UI aggregate. Shared JSON behavior is checked
with `scripts/verify-shared-contracts.sh` and `scripts/verify-rust-core.sh`.

Workspace observation uses an injectable delay for external-file, Git-only,
and recovery debouncing. Production keeps the 350 ms delay. Unit tests can
hold and release that boundary with signals, assert that no refresh happens
before release, and verify cancellation on reset. Real FSEvents integration
tests continue to use the production delay and native watcher.

## Remaining migration work

The current boundary is usable and enforced, but it is not a claim that every
workflow has moved into Rust. Language provider routing remains an application
workflow, while the LSP process lifecycle and protocol state are shared Rust
contracts. Maven execution, Java Run/Debug sessions, and terminal session
state still use Swift platform ports. See
[`language-tooling.md`](language-tooling.md) for the language tooling split.
