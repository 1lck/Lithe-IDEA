# Application Boundary Contract

The application boundary describes product behavior that a SwiftUI/AppKit or
Qt/Windows UI can consume. It does not describe widgets, threads, processes,
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
| Java/Maven | Maven project structure, modules and profiles; compiler diagnostic parsing; Java source structure, symbols, code vision, run-configuration detection, and JDTLS adapter policy | JDK/Maven discovery, Java/Maven child processes, sockets, and JDB transport |
| Run/Debug | versioned configuration documents, three-layer resolution, diagnostics, and platform-neutral launch plans | project file persistence, child processes, sockets, and JDB transport |
| Terminal | input bytes, output bytes, lifecycle | PTY/ConPTY, shell and environment |
| Local History | revision metadata, text content, restore result | persistence location and file operations |

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
