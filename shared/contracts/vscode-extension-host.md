# VS Code extension host protocol (v1)

Status: prototype for issue #737. No product launches the host yet; macOS and
Windows supervisors will implement the Lithe side of this contract.

The extension host (`extension-host/`) is a Node process that runs unmodified
VS Code extensions. Theia's plugin-side API implementation and its internal RPC
stay inside that process. Lithe only sees the UTF-8 JSON messages defined here,
so Theia types never become a Lithe compatibility surface.

The TypeScript definitions in `extension-host/src/protocol.ts` mirror this
document; update both together.

## Process and transport

- The supervisor starts `node <host>/dist/main.js` with stdin and stdout as
  pipes. Messages are single-line JSON objects terminated by `\n`, in both
  directions. stdout carries nothing else: the host redirects every other
  stdout write, including extension output, to stderr.
- stderr is the host diagnostic log. Lithe records it and must keep reading it.
- On POSIX the supervisor starts the host as a process group leader; on
  Windows it assigns the host to a job object that kills its members when
  closed. Stopping the host always ends that whole tree, which covers
  grandchildren and a crashed host.
- The host exits after `host/shutdown` has been answered, or when stdin
  closes. Before exiting it deactivates extensions within the requested
  timeout, flushes extension state, then sends SIGTERM (and after 3 seconds
  SIGKILL) to child processes extensions left running. Worst case:
  `timeoutMilliseconds + 6` seconds.
- The host never activates an extension on its own. Lithe sends every
  activation event, so safe mode, disabled modules, and untrusted workspaces
  can keep extension code from running.

## Envelope

```json
{ "kind": "request", "id": 1, "method": "host/initialize", "params": { } }
{ "kind": "response", "id": 1, "result": { } }
{ "kind": "response", "id": 1, "error": { "code": "invalidParams", "message": "…", "details": null } }
{ "kind": "notification", "method": "host/documentChanged", "params": { } }
{ "kind": "cancel", "id": 1 }
```

- Both peers issue requests with their own increasing integer ids.
- `cancel` names a request the *receiver* is handling. The receiver answers it
  at once with `cancelled` and discards any later result for that id.
- Every host -> Lithe request has a deadline (`requestTimeoutMilliseconds`,
  default 30000). On expiry the host sends `cancel` and fails the extension's
  call with `timeout`; a late response is ignored.
- `error.code` is one of: `invalidParams`, `methodNotFound`,
  `notInitialized`, `alreadyInitialized`, `cancelled`, `timeout`,
  `commandNotFound`, `commandFailed`, `documentNotFound`,
  `staleDocumentVersion`, `unsupportedApi`, `shuttingDown`, `internalError`.
  `details` carries structured context or `null`. A line that is not a valid
  message is logged to stderr and dropped; an extension that fails to load is
  listed in the initialize result's `failedExtensions`.
- A notification the host cannot apply is reported as `lithe/log` with level
  `error`, source `protocol`, and the error code in the message.

## Values

- Documents and resources are identified by URI strings (`file:///…`, or other
  schemes an extension owns). Workspace-relative paths are not used here
  because extensions address JDK sources and virtual documents outside the
  workspace.
- Ranges use one-based lines and one-based UTF-16 columns:
  `{ "startLine", "startColumn", "endLine", "endColumn" }`.
- A VS Code `Uri` inside command arguments or results is encoded as
  `{ "$uri": "<string>" }` in both directions. Values JSON cannot express
  (functions, `undefined`) become `null`.

## Lithe -> host

| Method | Kind | Params | Result |
| --- | --- | --- | --- |
| `host/initialize` | request | see below | see below |
| `host/activateByEvent` | request | `{ event }`, e.g. `*`, `onStartupFinished`, `workspaceContains:pom.xml`, `onLanguage:java` | `null` after activation finished |
| `host/executeCommand` | request | `{ command, arguments }` | command result; `commandNotFound` or `commandFailed` |
| `host/shutdown` | request | `{ timeoutMilliseconds? }` (default 10000) | `null`, then the process exits |
| `host/documentOpened` | notification | `{ uri, languageId, version, text, isDirty }` | |
| `host/documentChanged` | notification | `{ uri, version, changes: [{ range, rangeOffset, rangeLength, text }], isDirty }` | |
| `host/documentSaved` | notification | `{ uri }` | |
| `host/documentClosed` | notification | `{ uri }` | |

`host/initialize` params:

```json
{
  "protocolVersion": 1,
  "workspaceFolders": [{ "uri": "file:///work/app", "name": "app" }],
  "extensionPaths": ["/abs/extensions/redhat.java-1.56.0"],
  "storage": { "globalStoragePath": "/abs", "workspaceStoragePath": "/abs", "logPath": "/abs" },
  "configuration": { "defaults": {}, "user": {}, "workspace": {} },
  "environment": { "language": "en", "appName": "Lithe", "shell": "/bin/zsh" },
  "workspaceTrusted": true,
  "commands": ["lithe.openSettings"],
  "requestTimeoutMilliseconds": 30000
}
```

- `initialize` is accepted once; other requests before it fail with
  `notInitialized`.
- Configuration layers, lowest first: defaults contributed by the loaded
  extensions (`contributes.configuration` and `configurationDefaults`),
  `configuration.defaults`, `user`, `workspace`. Keys may be dotted
  (`"java.home"`) or nested objects.
- `workspaceTrusted` (default `false`) is Lithe's decision and becomes
  `vscode.workspace.isTrusted`; the host never prompts.
- `commands` lists Lithe commands extensions may execute; together with
  extension handlers it answers `vscode.commands.getCommands()`.

Result: `{ protocolVersion, apiVersion, extensions: [{ id, version, displayName,
activationEvents, commands: [{ command, title }] }], failedExtensions: [{ path,
message }] }`, sorted by id. `activationEvents` include the ones VS Code infers
from contributions (for example `onCommand:<contributed command>`).

### Documents

Lithe owns document content, versions, dirty state, undo, and saving. The host
keeps a mirror only so extensions can read documents synchronously.

- A document's `version` strictly increases. A change whose version is not
  greater than the mirrored one is rejected with `staleDocumentVersion`; a
  change for an unknown document with `documentNotFound`.
- Re-announcing an already mirrored version with `host/documentOpened` is a
  no-op; a newer version must arrive as `host/documentChanged`.

## Host -> Lithe

| Method | Kind | Params | Result |
| --- | --- | --- | --- |
| `lithe/openDocument` | request | `{ uri }` | `{ uri, languageId, version, text, isDirty }` or `documentNotFound` |
| `lithe/applyWorkspaceEdit` | request | `{ edits: [{ uri, range, text, expectedVersion }] }` | `{ applied }` |
| `lithe/saveDocument` | request | `{ uri }` | `{ saved }` |
| `lithe/executeCommand` | request | `{ command, arguments }` | result, or `commandNotFound` |
| `lithe/findFiles` | request | `{ include, baseUri, exclude, useDefaultExcludes, useIgnoreFiles, maxResults }` | `{ uris }` |
| `lithe/showMessage` | request | `{ severity, message, detail, modal, actions }` | `{ selectedIndex }` (`null` when dismissed) |
| `lithe/log` | notification | `{ level, source, message }` | |
| `lithe/unsupportedApi` | notification | `{ api }`, e.g. `LanguagesMain.$registerHoverProvider` | |
| `lithe/commandRegistered` / `lithe/commandUnregistered` | notification | `{ command, title? }` | |
| `lithe/progress` | notification | `{ id, phase: start/report/end, title, message, increment, cancellable }` | |

Ordering rules the extension API depends on:

- Before answering `lithe/applyWorkspaceEdit` with `applied: true`, Lithe sends
  `host/documentChanged` for every open document it changed. When
  `expectedVersion` is not `null` and differs from Lithe's version, Lithe
  applies nothing and answers `applied: false`.
- Before answering `lithe/saveDocument` with `saved: true`, Lithe sends
  `host/documentSaved`.
- `lithe/findFiles` patterns use VS Code glob syntax, relative to `baseUri` or
  to every workspace folder when it is `null`. Lithe applies its own
  `files.exclude` and ignore rules.

`lithe/commandRegistered` reports commands an extension registers without
declaring them in `package.json`; declared ones are already in the initialize
result.

## Unsupported APIs

Every VS Code API Lithe has not implemented fails inside the extension with an
error naming the Theia main-side method, and is reported once per host through
`lithe/unsupportedApi`. It never answers with a fake success. These reports
are the per-extension compatibility inventory.

`workspace.fs` for `file:` URIs is served inside the host directly from disk,
like VS Code's disk provider; Lithe observes those writes through its file
watchers. Other schemes fail with `FileSystemError.Unavailable`.
