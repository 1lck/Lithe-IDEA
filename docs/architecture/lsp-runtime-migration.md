# Rust LSP Runtime Migration

This document records the ownership audit that preceded the `feat/LSP`
runtime migration. It is intentionally implementation-oriented: each phase
names the state owner, the compatibility code that must disappear, and the
evidence required before the phase is complete.

The Windows application is not part of this iteration. The public Rust
contract remains cross-platform, but adapting the Qt client is tracked by the
Windows workstream.

## Baseline ownership audit

At commit `7fae1da`, Rust owned the protocol reducer while Swift still owned
the live runtime:

```text
Swift LanguageToolingSessionManager
  -> Swift StdioLanguageServerSession
       - child process and stdio
       - Content-Length read buffer
       - initialized / stopping state
       - opened-document set and pending documents
       - request completion handlers and timeout tasks
       - shutdown fallback
  -> Rust LspHost handle
       - JSON-RPC construction and parsing
       - request IDs
       - document versions
       - negotiated capabilities
       - diagnostics
```

That split left the following duplicated or competing state:

| Concern | Swift baseline | Rust baseline |
| --- | --- | --- |
| Document lifecycle | `openedDocumentURIs`, `pendingDocuments` | `open_documents` |
| Initialization | `isInitialized` and process callbacks | `initialized` |
| Request lifecycle | `responseHandlers`, timeout tasks | `pending_requests` |
| Transport | `readBuffer`, raw process send/receive | stateless frame/parser functions |
| Diagnostics | provider projection plus legacy Java store | URI-indexed diagnostics |
| Shutdown | timer and force terminate | shutdown JSON-RPC reducer |

The old public command surface also exposed implementation details:
`lsp.clientOpenDocument`, `lsp.clientChangeDocument`,
`lsp.clientApplyServerMessage`, `lsp.sessionExecute`, `lsp.frameMessage`, and
`lsp.parseServerMessages`.

## Target ownership

```text
SwiftUI / application facade
  -> semantic Rust commands
       startServer / stopServer
       syncDocument / closeDocument
       completion / hover / navigation / rename / format / code actions
       resolve / execute / cancel
       pollEvents
  -> Rust LSP engine
       provider adapter and launch configuration
       process + stdin/stdout/stderr
       lifecycle state machine
       framing + JSON-RPC
       document and version store
       pending request deadlines and terminal outcomes
       negotiated capabilities
       diagnostics by session/document/version
       graceful shutdown, crash handling, and restart isolation
```

Swift may retain UI projections and application-level completion closures
keyed by opaque operation IDs. It must not retain LSP request IDs, raw JSON,
framing buffers, child-process handles, document-open truth, or protocol
timeouts.

## Migration phases

### 1. State convergence

- Add one Rust lifecycle enum covering process start through terminal states.
- Replace split open/change calls with `syncDocument`; Rust decides whether to
  emit `didOpen` version 1 or `didChange` with the next version.
- Track request metadata and deadlines in Rust.
- Store diagnostic version metadata and clear it on close, stop, crash,
  restart, provider reconfiguration, and workspace replacement.

Primary files:

- `rust/lithe-core/src/lsp/interface/{engine,host,client,types}.rs`
- `rust/lithe-core/src/lsp/tests.rs`

### 2. Runtime and transport

- Spawn and own the language-server child process in Rust using a
  cross-platform process abstraction.
- Move stdin/stdout/stderr, partial-frame buffering, and malformed-frame
  failure handling into the Rust session.
- Add an event queue drained through `lsp.pollEvents`.
- Implement initialize, request, and shutdown deadlines; fail every pending
  request exactly once on timeout, cancellation, crash, stop, or restart.

Primary files:

- `rust/lithe-core/src/lsp/interface/{engine,transport}.rs`
- `rust/lithe-core/src/protocol/command.rs`
- `rust/lithe-core/src/runtime/dispatcher.rs`

### 3. Application facade

- Reduce `StdioLanguageServerSession.swift` to semantic commands, event
  polling, model conversion, and opaque operation completion delivery.
- Stop constructing `RawProcessSession` for LSP. DAP keeps its independent
  transport boundary.
- Remove state-passing and raw-message APIs from `RustCoreBridge.swift`.
- Keep `LanguageToolingSessionManager` as the UI-facing provider router and
  read-only projection.

Primary files:

- `Sources/Lithe/Services/StdioLanguageServerSession.swift`
- `Sources/Lithe/Services/StdioLanguageProviderRuntime.swift`
- `Sources/Lithe/Services/LanguageToolingSessionManager.swift`
- `Sources/Lithe/Core/RustCoreBridge.swift`
- `Sources/Lithe/Core/Ports/LanguageTooling.swift`

### 4. Provider convergence and legacy deletion

- Keep Maven, Run, Debug, JDK discovery, and local lightweight parsing outside
  the LSP runtime.
- Put JDTLS launch arguments, Java configuration responses, and virtual source
  semantics behind the Rust provider adapter.
- Delete the empty Java diagnostics and implementation-marker compatibility
  paths rather than retaining a second potential truth source.
- Delete the legacy client/session/frame/parse command surface after the
  production facade has migrated.

Primary files:

- `rust/lithe-core/src/lsp/languages/jdt.rs`
- `Sources/Lithe/Application/JavaFeatureModel.swift`
- `Sources/Lithe/Models/JavaDiagnosticModels.swift`
- `Sources/Lithe/Views/CodeEditorView.swift`

## Completion evidence

The migration is complete only when tests demonstrate all of the following:

1. A spawned process that never initializes cannot become ready.
2. An initialize error cannot become ready.
3. Two syncs emit open version 1 and change version 2.
4. A crash fails pending operations with `serverExited`.
5. A request deadline removes the pending request.
6. A late response after timeout is ignored.
7. Responses from an old session cannot affect a restarted session.
8. Old-session and old-document-version diagnostics are ignored.
9. Closing a document clears Rust document and diagnostic state.
10. Shutdown sends exit after the response and force-terminates on timeout.
11. Malformed `Content-Length` produces a transport failure.
12. A partial stdout frame is retained and completed in Rust.
13. Consecutive frames are parsed in order.
14. Dynamic capability registration and unregistration update availability.
15. Workspace replacement stops the old root and clears its state.

Architecture searches must additionally show no production Swift ownership of
LSP `Content-Length`, raw JSON-RPC request IDs, frame buffers, open-document
sets, pending LSP requests, or language-server child processes.
