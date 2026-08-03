# Application Boundary Contract

The application boundary describes product behavior that a SwiftUI/AppKit or
Qt/Windows UI can consume. It does not describe widgets, threads, processes,
or operating-system APIs.

## Data Rules

- All payloads are UTF-8 JSON when exchanged across a process or language boundary.
- Workspace paths are relative to the opened workspace and use `/` separators.
- Absolute paths may appear only in platform-owned diagnostics and are never used as identifiers.
- Line numbers are one-based. Missing locations are `null`.
- Lists have deterministic ordering so contract fixtures can be compared directly.
- Every asynchronous operation exposes `idle`, `loading`, `ready`, and `failed` outcomes.
- Failures contain a stable `code` and user-facing `message`; platform details belong in `details`.

## Feature Contracts

| Feature | Shared input/output | Platform-owned implementation |
| --- | --- | --- |
| Workspace | relative paths, file metadata, snapshot state | directory enumeration, hidden-file rules, watchers |
| Documents | path, UTF-8 text, dirty state, save result | file handles, atomic writes, external-change notifications |
| Search | query options, relative result paths, lines, symbols | indexing storage and file reads |
| Git | changes, commits, branches, diffs, operation result | Git executable discovery, process and credential environment |
| Runtime | selected Java/Maven settings, discovery result | JDK/Maven probing and executable paths |
| Run/Debug | configuration, lifecycle, output, diagnostics | child processes, sockets, JDB transport |
| Terminal | input bytes, output bytes, lifecycle | PTY/ConPTY, shell and environment |
| Local History | revision metadata, text content, restore result | persistence location and file operations |

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
- `unknown`

## UI Boundary

The UI sends commands to an application feature model and renders state from
that model. It must not construct `Process`, file watchers, terminals, runtime
locators, Git command runners, or persistence stores. Platform-specific actions
such as directory picking, file-browser reveal, clipboard access, and native
shortcut monitoring are capability ports, not application logic.

Search and Git examples are kept in `shared/fixtures/`. New behavior should
add a fixture before adding a second platform implementation.
