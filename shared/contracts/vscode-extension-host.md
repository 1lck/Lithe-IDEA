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
| `host/resolveCompletion` | request | `{ token, index, uri }` | normalized completion item, or `invalidParams` for expired identity |
| `host/provideLanguageFeature` | request | `{ kind, handle, uri, line, character }` | provider result, or `unsupportedApi` |
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
| `lithe/languageProviderRegistered` | notification | `{ kind, handle, selector, options }` | |
| `lithe/languageProviderUnregistered` | notification | `{ handle }` | |
| `lithe/diagnosticsChanged` | notification | `{ id, delta }` | |
| `lithe/diagnosticsCleared` | notification | `{ id }` | |

### Language provider preview

`host/provideLanguageFeature` targets the exact registered `handle`; unknown or
unregistered handles fail with `invalidParams`. `line` and `character` are
positive one-based line and UTF-16 column numbers. Supported calls currently
cover completion, hover, definition and references. Other language APIs, including formatting and rename registration, continue
to fail explicitly with `unsupportedApi` until their full path is implemented.

Completion returns `{ completions: [...] }`, with each item containing `label`,
`detail`, `documentation` (text or null), `insertText`, `insertTextFormat` (LSP), `sortText`, `filterText`,
`kind` (LSP completion kind), `textEdit: { range, text }`, and
`additionalTextEdits: [{ range, text }]`, and opaque `data: { token, index }`
for later resolution. Ranges use the shared one-based shape.
Hover is null or `{ contents, range }`; `contents` is markdown text.
Navigation returns `[{ uri, range }]`, with URI strings, never Theia URI objects.
Cancellation reaches the extension callback. Completion lists are retained for
on-demand `host/resolveCompletion`, allowing the upstream extension to add
imports and documentation after selection. The cache holds at most 32 lists;
a new request for the same provider/document, document edit/close, unregister,
or host shutdown expires old identities and releases their upstream resources.
A late resolve result for an expired list fails instead of applying stale edits.
The token is a Lithe identity, not a Theia DTO. Snippets use the existing Lithe
completion application path. Commands on acceptance are not yet supported and
remain required before enabling Java by default.

`lithe/diagnosticsChanged.delta` contains `[uri, diagnostics]` pairs. Each
pair replaces that collection's diagnostics for the URI; an empty array clears
that URI. Each diagnostic contains `message`, `range`, `severity` (LSP: error=1,
warning=2, information=3, hint=4), nullable `source` and `code`, `tags`, and
`relatedInformation: [{ uri, range, message }]`. Clearing a collection or
closing its host generation must remove only diagnostics owned by that source.
The host normalizes Theia marker values before crossing the process boundary.

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

## Managed runtime bundle layout

The macOS adapter reads `Contents/Resources/ExtensionHost/manifest.json` only
when the preview module is activated. No system Node discovery is performed.
The manifest is a packaging contract, distinct from the process protocol:

```json
{
  "schemaVersion": 1,
  "nodePaths": {
    "darwin-arm64": "runtimes/darwin-arm64/bin/node",
    "darwin-x64": "runtimes/darwin-x64/bin/node"
  },
  "entrypoint": "host/dist/main.js",
  "extensionPaths": ["extensions/redhat.java", "extensions/vscjava.vscode-java-debug"]
}
```

All paths are relative to this resource root. Absolute paths, traversal and
symlinks escaping the root are rejected; Node must be executable, the entrypoint
must exist, and every extension directory must contain `package.json`. Host
Node dependencies remain beside `host/dist` in `host/node_modules`. The matching
Node directory is prepended to the child's PATH. Packaging must supply pinned,
verified upstream artifacts; this locator does not download or install them.

Global state is under the platform application-support directory. Workspace
state and logs are isolated by a digest of the canonical workspace URI. The
initialization defaults to an untrusted workspace and does not activate any
extension. The module exports its capability only after initialization succeeds;
load failures trigger process cleanup. Editor-triggered activation and workflow
acceptance remain required before the preview can replace the production provider.

`extension-host/runtime-lock.json` pins Node 22.23.2 and the universal Open VSX
packages for `redhat.java` 1.56.0 and `vscjava.vscode-java-debug` 0.58.1, including
SHA-256 digests. The universal Java package relies on Lithe's configured JDK;
it does not add a second platform-specific bundled JDK.

On macOS, prepare a new resource directory with
`bun extension-host/scripts/package-runtime.ts darwin-arm64,darwin-x64 <output>`.
Every cached archive is rehashed before extraction. Production npm dependencies
are installed from `bun.lock` in an isolated staging directory with lifecycle
scripts disabled and macOS optional binaries for both architectures. Original
licenses and source links accompany the resource bundle. Existing output
directories are never overwritten.

`bun extension-host/scripts/verify-runtime.ts <output> darwin-arm64` executes
the bundled Node and checks initialization with the two official extensions,
then shuts down the process. Use `darwin-x64` to exercise Intel (Rosetta is
required on Apple Silicon), or both platforms with `--layout-only` to check
architecture and package identities without starting Node. This verifies
loading, not Java project import or language readiness.

Set `LITHE_EXTENSION_HOST_ROOT=<output>` when running `scripts/package-app.sh`
to include the preview resources. Packaging validates the requested app
architectures before copying; the existing app signing step includes these
resources. Default distribution remains unchanged until migration acceptance.
The manual managed-runtime CI lane downloads and verifies this combination;
ordinary PR tests use the local probe and do not require VSIX downloads.

The macOS preview validates resources before asking for workspace trust. Only
explicit consent for that host activation allows `workspaceTrusted: true`.
Cancellation or denial occurs before creating a host or reserving Java provider
ownership. Preparation is itself an owned module resource so shutdown can cancel
a pending prompt or runtime probe. Initialization alone never activates plugins.

The platform passes the prepared bundled JDK home as
`configuration.user["java.jdt.ls.java.home"]`. Project SDKs are independently
mapped to `configuration.user["java.configuration.runtimes"]`; an explicitly
configured SDK wins over a discovered SDK for the same execution environment.
The server's bundled JDK must not silently replace an invalid project SDK.

## Provider migration ownership

Before starting an extension host that replaces a native language provider,
Lithe validates its packaged resources, reserves the language, shuts down the
native provider's owning module, and confirms the native session has stopped.
All native startup entry points must reject reuse or creation while reserved.
Missing resources must not tear down a healthy native provider.

Revoking provider registrations or closing IPC does not release this reservation.
Only successful host process-group cleanup permits native fallback. A failed
cleanup keeps the reservation and resource active for retry. Workspace shutdown
starts owned cleanup immediately and module teardown awaits its result.

The native document adapter captures each editor event synchronously and sends
those snapshots in order. A successful save notification refers to a clean
current buffer; completing an older write while newer input remains dirty does
not mark that buffer saved. Repeated notifications for the same saved version
are deduplicated. Closing and reopening a URI establishes a new document
identity, so a late close from the previous editor object cannot close it.
Stopping the bridge or losing the host connection removes its subscription and
cancels queued deliveries; a failed delivery invalidates the connection rather
than continuing with an uncertain mirror.
