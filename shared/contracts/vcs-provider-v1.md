# VCS provider contract v1 (draft)

> **Status: draft, not implemented.** No Core command, plugin manifest field,
> host capability, or provider method below is accepted by any Lithe build yet.
> Names and fields may change until phase P1 lands. The decision record is
> [Unified VCS model and providers](../../.agents/notes/proposed/architecture/2026-10-22-unified-vcs-provider-model.md);
> example data is in [`shared/fixtures/vcs/model-v1.json`](../fixtures/vcs/model-v1.json).

This contract defines one VCS-neutral model for the features every version
control system has: roots, file status, base content, history, annotation,
check-in, rollback, and update. A **provider** implements it for one VCS. Git is
a built-in provider inside Core that adapts the existing `git.*` operations;
other systems (Subversion first) are plugin providers that run as LSP
base-protocol processes, the same process kind as
[build providers](plugins/v1/README.md#build-providers).

`git.*` commands, fields, and fixtures are unchanged by this contract. Features
that only exist in one VCS (Git log graph, rebase, worktrees, stash, push
dialog; Subversion locks UI, properties editor, relocate) stay in that
provider's own module or plugin and are not modeled here.

## Shared rules

- UTF-8 JSON; deterministic ordering of every list.
- Paths inside a root are root-relative with `/` separators. A root's own
  identity is a workspace-relative `id` (`..` allowed for enclosing roots); its
  native `path` is a platform binding, never a portable identity.
- Line numbers are one-based; missing values are `null`.
- Hosts never parse or order revision IDs; only the provider compares them.
- Remote locations (Subversion URLs, Git remotes) are display data with user
  info, query, and fragment removed before they leave Core.
- Secrets never appear in arguments, results, console events, or logs.

## Model

### Provider descriptor

```json
{
  "vcs": "git",
  "displayName": "Git",
  "origin": { "kind": "builtIn" },
  "capabilities": { "status": 1, "baseContent": 1, "checkin": 1, "rollback": 1, "push": 1, "staging": 1 }
}
```

`vcs` is a stable lowercase ID (`git`, `svn`, `hg`, …). Plugin providers report
`origin: { "kind": "plugin", "pluginID": "<id>" }`. Two installed providers may
not claim the same `vcs`; the second is reported as a conflict and not
registered.

`capabilities` maps capability IDs to the negotiated version. A missing key
means unsupported; the host hides the entry point. UI behavior is chosen from
capabilities only, never from `vcs`.

| Capability | Required | Meaning |
| --- | --- | --- |
| `status` | yes | File status for a root |
| `baseContent` | yes | Content of a file at its base revision (Diff, gutter) |
| `checkin` | yes | Record selected changes as a new revision |
| `rollback` | yes | Discard local changes of selected files |
| `history` | no | Paged revision history of a root |
| `fileHistory` | no | Paged revision history of one path |
| `annotate` | no | Per-line revision of a file |
| `update` | no | Bring remote revisions into the working copy |
| `push` | no | Check-in is local; publishing is a separate step |
| `staging` | no | Changes carry a staged/unstaged dimension |
| `fileOperations` | no | Add/move/delete must go through the VCS to be tracked |
| `conflicts` | no | Report and resolve conflicted files |
| `ignore` | no | Add paths to the VCS ignore list |
| `lock` | no | Lock/unlock files and report lock owners |
| `cleanup` | no | Recover an interrupted working copy |

A provider without `push` commits directly to the server; the host labels the
action accordingly and does not offer "Commit and Push".

### Root

```json
{ "id": "services/legacy", "vcs": "svn", "path": "<native path>", "location": "https://svn.example.invalid/repo/trunk" }
```

Core detects roots from static markers without starting a provider. A file
belongs to the deepest root that contains it. A directory that matches markers
of two providers is reported as `ambiguous` and stays unassigned until the user
maps it; Core never guesses. Roots are ordered by workspace containment, depth,
then `id`.

### Revision

```json
{ "id": "1234", "display": "r1234", "kind": "number" }
```

`kind` is `hash`, `number`, or `opaque` and only affects presentation (for
example monospace hashes). `id` is passed back to the provider unchanged.

### Status snapshot

```json
{
  "root": "services/legacy",
  "head": { "revision": { "id": "1234", "display": "r1234", "kind": "number" }, "branch": null, "location": "https://svn.example.invalid/repo/trunk" },
  "changes": [
    { "path": "src/Main.java", "oldPath": null, "status": "modified", "flags": ["propertiesModified"] }
  ],
  "truncated": false
}
```

`status` is one of `modified`, `added`, `deleted`, `missing` (removed from disk
without telling the VCS), `renamed`, `copied`, `replaced`, `typeChanged`,
`unversioned`, `ignored`, `conflicted`, `switched`. A plugin reply with any
other value fails with `plugin.vcs.invalidOutput`.

`flags` refine a status: `propertiesModified`, `locked`, `lockedByOther`,
`treeConflict`, `external`, `submodule`. Core drops unknown flags so a newer
provider can add optional data within version 1.

Providers with `staging` add `staging: "staged" | "unstaged" | "partial"` to each
change. Changelist membership is host state and never part of a provider
reply.

`changes` is ordered by `path`; Core sorts plugin replies, so a provider need
not. Core caps a snapshot at 100,000 changes and sets `truncated: true`; a
truncated snapshot must not be presented as complete.

Core rejects a plugin reply with `plugin.vcs.invalidOutput` when a path is
absolute, contains a `..` segment, or otherwise resolves outside the root, or
when a change carries `staging` although the provider did not negotiate the
`staging` capability.

## Core commands (planned)

| Command | Purpose |
| --- | --- |
| `vcs.providers` | Registered providers, their origin and negotiated capabilities |
| `vcs.roots` | Detected roots, ambiguous directories, and applied user mappings |
| `vcs.status` | Status snapshot of one root |
| `vcs.baseContent` | Base-revision content of one file |
| `vcs.history` / `vcs.fileHistory` | Paged history with an opaque cursor |
| `vcs.annotate` | Per-line revision of one file |
| `vcs.checkin` / `vcs.rollback` / `vcs.update` | Mutations, with the existing execution-event lifecycle |
| `vcs.fileOperation` | Track an add, move, or delete made in the project tree |

For the built-in Git provider Core executes the request itself. For a plugin
provider, Core follows the build-provider pattern: it returns
`provider: { method, params }`, the host sends it through the negotiated LSP
session, and Core decodes and validates the reply into the same result shape.
Exact plan/decode command names are fixed in P1.

## Plugin providers (planned, plugin API level 3)

### Manifest

```json
{
  "pluginAPIVersion": 3,
  "requires": { "vcsProviders": 1, "serverProcess": 1 },
  "vcsProviders": [
    {
      "id": "svn",
      "displayName": "Subversion",
      "detection": { "markers": [{ "name": ".svn", "type": "directory" }] },
      "metadataPaths": [".svn/wc.db"],
      "tool": { "commands": ["svn"], "validationArguments": ["--version", "--quiet"] },
      "launch": { "kind": "packaged", "path": "bin/lithe-svn-provider" }
    }
  ]
}
```

The manifest only states what the host must know before starting a process:
the VCS ID, detection markers, metadata paths to watch, the client tool the
provider drives, and the shared `serverProcess` launch fields. The host
resolves `tool.commands` with the same discovery as `systemCommand` launches
(PATH, user override) and sends the absolute path as `tool: { executable }` in
every request, as it does for build providers, so the provider does not repeat
tool lookup. A missing tool is reported once and the root stays visible as
unavailable rather than clean.

A non-empty `vcsProviders` requires `languageServer.launch` (the plugin starts
its own process, like an own-process build provider), a new `process.vcs`
permission (the provider changes the working copy and contacts remote
servers), and the activation event `onVcsRoot:<id>`. Detection never starts a
process; the host starts the provider after a root of its VCS is found, which
the install review must state.

### Negotiation

The host sends `capabilities.experimental.litheVcs: { "versions": [1] }` in
`initialize`. The provider answers
`{ "version": 1, "vcs": "<id>", "capabilities": { … } }`. A session without a
valid answer, or with a `vcs` different from the manifest entry, is not used as
a provider and receives no `lithe/vcs/*` request. Capabilities belong to the
running process and are not repeated in the manifest.

### Methods

| Direction | Method | Kind |
| --- | --- | --- |
| host → provider | `lithe/vcs/status`, `lithe/vcs/baseContent`, `lithe/vcs/history`, `lithe/vcs/fileHistory`, `lithe/vcs/annotate`, `lithe/vcs/checkin`, `lithe/vcs/rollback`, `lithe/vcs/update`, `lithe/vcs/fileOperation` | request |
| provider → host | `lithe/vcs/execution` | notification: an actual command started, produced output, or finished (project console) |
| provider → host | `lithe/vcs/authenticate` | request: credential challenge answered through the host's existing authentication UI; answers are never persisted by Lithe |

Both sides ignore unknown fields in params and results. Requests carry
`operationID`; `$/cancelRequest` and the host deadline end them with
`requestCancelled` or `requestTimeout`.

## Error codes (draft)

| Code | Meaning |
| --- | --- |
| `vcs.root.notFound` | The path is not inside a detected or mapped root |
| `vcs.root.ambiguous` | The directory matches several providers and is unmapped |
| `vcs.provider.unavailable` | The provider is not registered, not negotiated, or has exited |
| `vcs.capability.unsupported` | The request needs a capability the provider did not negotiate |
| `vcs.authentication.failed` | Credentials were rejected after the allowed retries |
| `vcs.outOfDate` | The server rejected a check-in because the working copy is out of date |
| `vcs.conflict` | The operation stopped on conflicted files |
| `plugin.vcs.invalidOutput` | A plugin reply failed validation or exceeded a limit |

Platform details go in `details`; messages must not contain credentials.

## Subversion provider notes

The official Subversion plugin calls the user's `svn` client and parses its
`--xml` output (`status`, `info`, `log`, `blame`). Every invocation uses
`--non-interactive`; passwords use `--password-from-stdin`. Subversion's own
credential cache answers first. Working copies older than format 1.7 (one
`.svn` per directory) are not supported.
