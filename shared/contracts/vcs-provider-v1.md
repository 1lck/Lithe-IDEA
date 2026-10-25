# VCS provider contract v1

> **Status: Core implemented (P1); no host uses it yet.** Core accepts the
> `vcsProviders` manifest capability and the commands below. The macOS and
> Windows hosts do not start providers yet, so no build shows a plugin VCS.
> The decision record is
> [Unified VCS model and providers](../../.agents/notes/proposed/architecture/2026-10-22-unified-vcs-provider-model.md);
> example data is in [`shared/fixtures/vcs/model-v1.json`](../fixtures/vcs/model-v1.json)
> and [`plugins/v1/fixtures/vcs-provider.plugin.json`](plugins/v1/fixtures/vcs-provider.plugin.json).

This contract defines one VCS-neutral model for the features every version
control system has: roots, file status, base content, history, annotation,
check-in, rollback, and update. A **provider** implements it for one VCS as a
plugin process speaking the LSP base protocol, the same process kind as
[build providers](plugins/v1/README.md#build-providers). Subversion is the
first provider.

Git is not part of this layer yet. Core recognizes `.git` markers so a nested
working copy is assigned to the right root, and the `git.*` commands keep
serving Git roots unchanged. Features that only exist in one VCS (Git log
graph, rebase, worktrees, stash; Subversion locks, properties, relocate) are
not modeled here.

## Shared rules

- UTF-8 JSON; every list has a deterministic order.
- Paths inside a root are root-relative with `/` separators and no empty,
  `.`, or `..` segment. A root's identity is a workspace-relative `id` (`""`
  for the workspace, `..` segments for an enclosing directory); its native
  `path` is a platform binding, never a portable identity.
- Missing values are `null`.
- Hosts never parse or order revision IDs; only the provider compares them.
- Remote locations are display data; Core removes user info, query, and
  fragment before they leave it.
- Secrets never appear in arguments, results, console events, or logs.

## Manifest (plugin API level 3)

```json
{
  "pluginAPIVersion": 3,
  "requires": { "serverProcess": 1, "vcsProviders": 1 },
  "permissions": ["languageServer.launch", "process.vcs"],
  "activationEvents": ["onVcsRoot:svn"],
  "vcsProviders": [
    {
      "id": "svn",
      "displayName": "Subversion",
      "detection": { "markers": [{ "name": ".svn", "type": "directory" }] },
      "metadataPaths": [".svn/wc.db"],
      "tool": { "commands": ["svn"], "validationArguments": ["--version", "--quiet"] },
      "launch": { "kind": "runtime", "tool": "node", "minimumVersion": "20.3", "entry": "provider/main.mjs" },
      "arguments": ["--stdio"],
      "mayUseNetwork": true
    }
  ]
}
```

| Field | Rule |
| --- | --- |
| `id` | `[a-z][a-z0-9-]{0,31}`; unique in the plugin. `git` is reserved (`plugin.vcs.reserved`). |
| `displayName` | One line of 1-64 characters. |
| `detection.markers` | 1-8 entries directly inside a root; `type` is `directory` or `file`. |
| `metadataPaths` | Up to 16 root-relative paths the host watches to refresh status. |
| `tool` | Optional. Bare command names the host resolves like a `systemCommand` launch, and an optional probe. |
| `launch`, `arguments`, `validationArguments`, `runtimeDependencies`, `initializationOptions` | The shared server-process fields. |
| `mayUseNetwork` | Shown in the install review. |

A plugin declares at most 8 providers. A non-empty `vcsProviders` requires the
`languageServer.launch` and `process.vcs` permissions, the activation event
`onVcsRoot:<id>` for every provider, and `requires.vcsProviders` and
`requires.serverProcess`. Capabilities are not declared in the manifest: they
belong to the running process and are negotiated.

The install review lists one program per provider, of kind
`packagedVcsProvider`, `systemVcsProvider`, or `runtimeVcsProvider`, with
`vcs`, `vcsTool` (the declared `tool`), and `mayUseNetwork`, plus the
runtime it needs. Changing the tool or the launch is a new program the user
approves again.

`plugins.declarative.languageServerLaunchPlan` with `vcsProviderID` plans
the process and adds `vcsProvider`, the descriptor below.

## Provider descriptor

```json
{
  "vcs": "svn",
  "displayName": "Subversion",
  "origin": { "kind": "plugin", "pluginID": "io.github.lithe-idea.svn-support" },
  "markers": [{ "name": ".svn", "type": "directory" }],
  "metadataPaths": [".svn/wc.db"],
  "tool": { "commands": ["svn"], "validationArguments": ["--version", "--quiet"] },
  "mayUseNetwork": true
}
```

The built-in Git entry is `{ vcs: "git", displayName: "Git", origin: { kind:
"builtIn" }, markers }` with the `.git` directory and file markers.

## Core commands

| Command | Purpose |
| --- | --- |
| `vcs.detectRoots` | Providers, roots, ambiguous directories, and applied mappings of a workspace |
| `vcs.ownerOf` | The root that owns each workspace path |
| `lsp.vcsRequest` | Sends one operation to a negotiated provider session |
| `vcs.decodeReply` | Validates a provider's reply and returns the normalized result |

### `vcs.detectRoots`

```json
{
  "workspaceRoot": "/abs/workspace",
  "plugins": [{ "manifest": { } }],
  "mappings": [{ "id": "mixed", "vcs": "svn" }]
}
```

Core validates every manifest again; a rejected one is listed as
`rejected: [{ index, error }]` and the rest still count. When two plugins claim
one VCS, an official plugin wins, then the lower plugin ID; the loser is listed
in `conflicts: [{ pluginID, vcs, by }]`. A relative `workspaceRoot` fails the
call.

```json
{
  "status": "ok",
  "detection": {
    "providers": [ ],
    "roots": [{ "id": "services/legacy", "vcs": "svn", "path": "/abs/workspace/services/legacy", "mapped": false }],
    "ambiguous": [{ "id": "mixed", "vcs": ["git", "svn"] }],
    "unusedMappings": [],
    "truncated": false,
    "rejected": [],
    "conflicts": []
  }
}
```

Roots come from static markers; detection never starts a process. One
breadth-first walk reads the markers directly inside each directory down to
eight levels below the workspace, at most 20,000 directories. It never enters a
marker directory (`.git`, `.svn`), a symbolic link, or a dependency or build
directory such as `node_modules`, `target`, or `.worktrees`. When the workspace
itself has no marker, its ancestors are checked, because a Subversion working
copy has one `.svn` at its top; the enclosing root's `id` is `..`, `../..`, ….
`truncated` is `true` only when the directory budget ran out, so a root may be
missing.

A directory with markers of several VCSs is ambiguous until a mapping names
one of them; Core never guesses. Mappings that name no ambiguous directory, or
a VCS whose markers are not there, are returned in `unusedMappings`. Roots and
ambiguous directories are ordered by depth (enclosing first), then `id`.

### `vcs.ownerOf`

```json
{ "roots": ["", "services/legacy"], "ambiguous": ["mixed"], "paths": ["README.md", "mixed/a.txt"] }
```

returns `{ status: "ok", owners: [{ path, root }] }` in request order. A path
belongs to the deepest root that contains it; inside an unmapped ambiguous
directory it belongs to no root (`null`), not to an enclosing one. At most
100,000 paths per call.

### `lsp.vcsRequest`

```json
{
  "sessionId": "…",
  "operationId": "…",
  "vcs": "svn",
  "operation": "checkin",
  "root": "/abs/workspace/services/legacy",
  "tool": "/opt/homebrew/bin/svn",
  "arguments": { "paths": ["src/Main.java"], "message": "Fix" },
  "timeoutMilliseconds": 600000
}
```

The host names an operation, never a method, so a session cannot be used as a
generic JSON-RPC tunnel. Core refuses the request before writing it when the
session did not negotiate a provider for `vcs`
(`notSupported`, details `vcs.provider.unavailable`), when the provider did not
negotiate the operation's capability (`notSupported`, details
`vcs.capability.unsupported`), or when the arguments are malformed
(`invalidRequest`). `timeoutMilliseconds` is capped at one hour; the session's
request timeout applies when it is absent. The result arrives as a
`requestCompleted` event with `result: { value: <reply> }`; a failure carries
one of the error codes below.

| Operation | Method | Capability | Arguments |
| --- | --- | --- | --- |
| `status` | `lithe/vcs/status` | `status` | `{ includeIgnored? }` |
| `baseContent` | `lithe/vcs/baseContent` | `baseContent` | `{ path }` |
| `history` | `lithe/vcs/history` | `history` | `{ cursor?, limit? }` |
| `fileHistory` | `lithe/vcs/fileHistory` | `fileHistory` | `{ path, cursor?, limit? }` |
| `annotate` | `lithe/vcs/annotate` | `annotate` | `{ path }` |
| `checkin` | `lithe/vcs/checkin` | `checkin` | `{ paths, message }` |
| `rollback` | `lithe/vcs/rollback` | `rollback` | `{ paths }` |
| `update` | `lithe/vcs/update` | `update` | `{ revision? }` |
| `fileOperation` | `lithe/vcs/fileOperation` | `fileOperations` | `{ kind: "add" \| "delete", paths }` or `{ kind: "move", from, to }` |
| `resolve` | `lithe/vcs/resolve` | `conflicts` | `{ paths }` |
| `cleanup` | `lithe/vcs/cleanup` | `cleanup` | `{}` |

`paths` holds 1-10,000 root-relative paths; Core sorts and deduplicates them.
A history page has 1-500 entries (100 by default). A check-in message is
non-empty text of at most 1 MiB. Unknown argument fields fail.

Core adds `root: { path }` and `tool: { executable } | null` to the params.
The provider receives, for example:

```json
{ "paths": ["src/Main.java"], "message": "Fix", "root": { "path": "/abs/…/legacy" }, "tool": { "executable": "/opt/homebrew/bin/svn" } }
```

### `vcs.decodeReply`

```json
{ "operation": "status", "capabilities": { "status": 1, "…": 1 }, "request": { }, "reply": { } }
```

`capabilities` is what the session reported in its `vcsProvider` event,
`request` the arguments the host sent, and `reply` the `value` of the
completed request. The result is `{ status: "ok", result }` or
`{ status: "rejected", error: { code: "plugin.vcs.invalidOutput", … } }`.

## Negotiation

The host offers `capabilities.experimental.litheVcs: { "versions": [1] }` in
`initialize`, to plugin-owned sessions only. The provider answers:

```json
{ "litheVcs": { "version": 1, "vcs": "svn", "capabilities": { "status": 1, "baseContent": 1, "checkin": 1, "rollback": 1, "update": 1 } } }
```

A session is a provider only when the answer names an offered version, a valid
VCS ID, and every required capability. Unknown capabilities, and known ones at
another version, are ignored. Core then publishes a runtime event of kind
`vcsProvider` with `result: { vcs, capabilities }`; the host compares `vcs`
with the manifest entry it launched and stops a session that answered another
one. A session without a valid answer receives no `lithe/vcs/*` request.

| Capability | Required | Meaning |
| --- | --- | --- |
| `status` | yes | File status of a root |
| `baseContent` | yes | Content of a file at its base revision (Diff, gutter) |
| `checkin` | yes | Record selected changes as a new revision |
| `rollback` | yes | Discard local changes of selected files |
| `history` | no | Paged revision history of a root |
| `fileHistory` | no | Paged revision history of one path |
| `annotate` | no | Per-line revision of a file |
| `update` | no | Bring remote revisions into the working copy |
| `push` | no | Check-in is local; publishing is a separate step |
| `staging` | no | Changes carry a staged/unstaged dimension |
| `fileOperations` | no | Add, move, and delete must go through the VCS to be tracked |
| `conflicts` | no | Report and resolve conflicted files |
| `cleanup` | no | Recover an interrupted working copy |

UI behavior is chosen from capabilities only, never from `vcs`. A provider
without `push` commits directly to the server; the host labels the action
accordingly and does not offer "Commit and Push". Version 1 has no operation
for `push`: a provider that negotiates it tells the host the VCS has a
publishing step, which a later version will model.

## Replies

### Revision

```json
{ "id": "1234", "display": "r1234", "kind": "number" }
```

`kind` is `hash`, `number`, or `opaque` (the default) and only affects
presentation. `display` defaults to `id`. `id` is passed back to the provider
unchanged.

### `status`

```json
{
  "head": { "revision": { "id": "1234", "display": "r1234", "kind": "number" }, "branch": null, "location": "https://svn.example.invalid/repo/trunk" },
  "changes": [
    { "path": "src/Main.java", "oldPath": null, "status": "modified", "flags": ["locked", "propertiesModified"] }
  ],
  "truncated": false
}
```

`status` is one of `modified`, `added`, `deleted`, `missing` (removed from disk
without telling the VCS), `renamed`, `copied`, `replaced`, `typeChanged`,
`unversioned`, `ignored`, `conflicted`, `switched`; any other value is invalid.
Only `renamed` and `copied` may name an `oldPath`.

`flags` refine a status: `external`, `locked`, `lockedByOther`,
`propertiesModified`, `submodule`, `treeConflict`. Core drops unknown flags so
a newer provider can add optional data within version 1, and sorts the rest.

A provider that negotiated `staging` gives every change
`staging: "staged" | "unstaged" | "partial"`; any other provider gives none.
Changelist membership is host state and never part of a reply.

Core sorts `changes` by `path` and rejects duplicates. It caps a snapshot at
100,000 changes and sets `truncated: true`, as does a provider that stopped
early; a truncated snapshot must not be presented as complete.

### Other operations

| Operation | Reply | Rules |
| --- | --- | --- |
| `baseContent` | `{ content: string \| null, binary: bool }` | `null` content: the file has no base (added or unversioned); binary content is not sent. At most 32 MiB. |
| `history`, `fileHistory` | `{ entries: [{ revision, author, date, message, changes, changesTruncated }], nextCursor }` | Provider order (newest first) is kept; more entries than requested is invalid. Each entry lists at most 10,000 changes. |
| `annotate` | `{ revisions: [{ revision, author, date, message }], lines: [id \| null] }` | Each line names a listed revision ID or `null`; only used revisions are returned, sorted by ID. At most 500,000 lines. |
| `checkin` | `{ revision }` | The new revision, or `null` when the VCS does not report one. |
| `update` | `{ revision, conflicts: [path] }` | Conflicted paths, sorted and inside the root. |
| `rollback`, `fileOperation`, `resolve`, `cleanup` | `{}` | Unknown fields are ignored. |

A path that is absolute, has a `..` segment, or otherwise leaves the root, a
missing required field, or a size limit exceeded makes the reply invalid.

## Provider messages

| Direction | Method | Version 1 behavior |
| --- | --- | --- |
| provider → host | `lithe/vcs/execution` | Notification of a command the provider ran: `{ command: [executable, ...arguments], exitCode: number \| null, durationMilliseconds, stderr }`, with `stderr` cut to 16 KiB and no stdout. Core passes it on as a session `log` event (`message` is the method, `detail` the params as JSON); routing it to the project console is host work (P3). Arguments are shown as sent, so a provider never puts a credential in them. |
| provider → host | `lithe/vcs/authenticate` | Not accepted yet: Core answers `-32601`. A provider runs its client non-interactively and fails with `vcs.authentication.failed`. |

Both sides ignore unknown fields in params and results. `$/cancelRequest` and
the request deadline end a request with `requestCancelled` or
`requestTimeout`.

## Error codes

| Code | Raised by | Meaning |
| --- | --- | --- |
| `vcs.provider.unavailable` | Core (`details` of `notSupported`) | The session negotiated no provider, or one for another VCS |
| `vcs.capability.unsupported` | Core (`details` of `notSupported`) | The operation needs a capability the provider did not negotiate |
| `plugin.vcs.reserved` | Core (manifest) | A plugin declared the reserved `git` ID |
| `plugin.vcs.invalidOutput` | Core | A reply failed validation, exceeded a limit, or had no result |
| `vcs.provider.failed` | Core | The provider failed without one of the codes below |
| `vcs.authentication.failed` | provider | Credentials were missing or rejected |
| `vcs.conflict` | provider | The operation stopped on conflicted files |
| `vcs.outOfDate` | provider | The server rejected a check-in because the working copy is out of date |
| `vcs.tool.unavailable` | provider | The VCS client could not be run |
| `vcs.workingCopy.locked` | provider | The working copy is locked by an interrupted operation; `cleanup` may help |
| `vcs.workingCopy.unsupported` | provider | The working copy format is not supported |

A provider reports its code in the JSON-RPC `error.data.code`. Core keeps only
the provider codes listed here; any other code, including Core's own, becomes
`vcs.provider.failed`. The provider's message (at most 4 KiB) is passed on and
must not contain credentials.

## Subversion provider notes

Subversion is provided by the community plugin
[lithe-plugin-svn](https://github.com/Lithe-IDEA/lithe-plugin-svn)
(`io.github.lithe-idea.svn-support`), released independently of Lithe. It calls
the user's `svn` client, 1.8 or newer, and parses its `--xml` output. Its README
documents how each operation maps to svn and how svn errors map to contract
codes; its tests check those replies against a pinned Lithe Core.
