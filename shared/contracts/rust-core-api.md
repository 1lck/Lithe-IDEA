# Rust Core API

The Rust core is the shared application runtime for macOS SwiftUI and Windows
Qt/C++. Both bindings call the same C ABI:

```c
const char *lithe_core_version(void);
char *lithe_core_execute_json(const char *request);
int32_t lithe_core_cancel(const char *operation_id);
void lithe_core_free_string(char *value);
```

The macOS package uses the small C bridge in `Sources/LitheRustCore/`. The
canonical C declarations are in `rust/lithe-core/include/lithe_core.h`.
Windows can link the same `staticlib` or `cdylib` and call these functions from
C++.
Strings returned by the core are UTF-8 JSON allocated by Rust. The caller must
release response strings with `lithe_core_free_string`.

## Envelope

Every request has this shape:

```json
{
  "id": "request-id",
  "operationId": "operation-id",
  "timeoutMilliseconds": 30000,
  "command": "workspace.search",
  "payload": {}
}
```

`operationId` is optional for compatibility and defaults to `id` when `id` is
present. `timeoutMilliseconds` is optional; a positive value starts a
cooperative deadline. `lithe_core_cancel` is thread-safe and returns `1` when
the operation is active. Cancellation and deadlines are checked at command
boundaries, workspace traversal points, and Git process waits. They return
`cancelled` or `timed_out` in the standard error envelope.

Successful responses contain `ok: true` and `data`. Failed responses contain a
stable error code and a user-facing message:

```json
{
  "id": "request-id",
  "ok": false,
  "error": {
    "code": "invalid_request",
    "message": "Invalid JSON request"
  }
}
```

## Commands

| Command | Purpose |
| --- | --- |
| `core.ping` | Verify the ABI and protocol version |
| `workspace.snapshot` | Enumerate visible workspace nodes and relative file paths |
| `workspace.search` | Search visible file names and UTF-8 text files |
| `workspace.searchEverywhere` | Search visible file names, Java types/methods, and UTF-8 text files |
| `workspace.replacePreview` | Return deterministic replacement lines and complete replacement text |
| `file.read` | Read a UTF-8 file using a workspace-relative path |
| `file.write` | Write a UTF-8 file using a workspace-relative path |
| `history.record` | Store a versioned text snapshot and metadata |
| `history.entries` | List valid history entries for one file or a workspace |
| `history.content` | Read a stored history snapshot by relative storage path |
| `history.relocate` | Move a file's history records after a rename |
| `shelf.create` | Store separate staged and working-tree patches for one workspace |
| `shelf.list` | List valid versioned Shelves for one workspace |
| `shelf.restore` | Read both patches from a Shelf without deleting it |
| `shelf.delete` | Delete one validated Shelf after a successful restore |
| `maven.scan` | Parse a Maven project descriptor and recursively return modules/profiles |
| `maven.diagnostics` | Parse stable Maven compiler diagnostics from build output |
| `java.runConfigurations` | Scan Java sources for main classes and return Maven/Spring run configurations |
| `java.codeVision` | Return Java declaration usage counts for editor code vision |
| `java.className` | Resolve a Java source package and simple name into a runtime class name |
| `java.sourceDefinition` | Locate a Java type, method, or field declaration in source text |
| `java.serverPort` | Parse Spring server port settings from properties or YAML text |
| `java.structure` | Parse Java editor structure, implementation candidates, and inlay hints |
| `git.status` | Resolve the repository, current branch, and working-tree changes |
| `git.command` | Execute one argument-based Git operation and return combined output plus exit code |
| `git.write` | Validate and execute shared Git mutations such as stage, commit, branch, checkout, remote sync, clone, and stash |
| `git.checkoutPreflight` | List working-tree paths that would block switching to a reference |
| `git.conflictMarkers` | List staged paths that still contain conflict markers |
| `git.integrationPreflight` | Decide whether a merge or rebase can start, and which dirty paths block it |
| `git.pullPreflight` | Report upstream tracking, ahead/behind counts, divergence, and local dirtiness |
| `git.operationState` | Describe an in-progress merge, rebase, cherry-pick, or revert |
| `git.diff` | Produce a structured working-tree, index, reference, or commit patch |
| `git.shelfPatches` | Collect deterministic staged and working-tree patches for Shelf creation |
| `git.apply` | Apply or check a patch in `stage`, `unstage`, `discard`, or Shelf restore mode |
| `git.history` | Return deterministic refs, commits, parent hashes, decorations, and pagination state |
| `git.commit` | Return one structured commit by revision |
| `git.commitFiles` | Return files changed by one commit |
| `git.comparison` | Return files changed between a reference and the working tree |
| `git.stashes` | Return structured stash references and messages |
| `git.checkoutPreflight` | Return dirty paths that a checkout would overwrite |
| `git.pullPreflight` | Return upstream, divergence, and local-change state before pulling |
| `git.integrationPreflight` | Return paths blocking a merge or rebase |
| `git.conflictMarkers` | Return staged paths that still contain conflict markers |
| `git.operationState` | Return an in-progress merge, rebase, cherry-pick, or revert state |
| `git.blame` | Return structured line blame metadata |

Workspace paths in responses are relative and use `/` separators. Line numbers
are one-based. `git.status.repositoryRoot` may be an absolute path when the
opened workspace is a subdirectory of the repository; all Git change paths are
relative to that repository root. The core rejects absolute paths and `..`
traversal for file commands. Native file dialogs, file watching, PTY/ConPTY,
Java processes, and runtime discovery remain platform adapters.

The protocol version is currently `1`. Add a fixture under `shared/fixtures/`
before changing a response shape or search rule.

`git.command` accepts `{ "root": string, "arguments": string[], "input": string? }`.
Arguments are passed directly to the Git executable without a shell. A
successful process launch returns `{ "output": string, "exitCode": number }`
even when Git exits non-zero; process-start and workspace failures use the
standard error envelope. When a stash restore leaves unresolved merge
conflicts, the response may also include
`stashRestore: { "stashReference": string, "conflictedPaths": string[] }`.
The key is omitted when restore completed cleanly.

`git.write` accepts a typed mutation request. Its required `operation` values are
`stage`, `unstage`, `discard`, `discardAll`, `stageAll`, `commit`, `cherryPick`, `revert`,
`reset`, `createBranch`, `renameBranch`, `deleteBranch`, `merge`, `rebase`,
`fetch`, `pull`, `push`, `checkout`, `checkoutRevision`, `clone`, `stashPush`,
`stashApply`, `stashPop`, `stashDrop`, `operationContinue`, `operationAbort`,
and `operationSkip`. Optional fields are `paths`,
`reference`, `referenceKind`, `revision`, `name`, `message`, `remote`,
`destination`, `mode`, `includeUntracked`, `checkout`, `amend`, `force`, and
`autoStash`. `force` and `autoStash` default to `false`.

The core validates pathspecs, revisions, branch names, references, reset modes,
stash references, and operation-specific required fields before invoking Git.
Successful process launch returns `{ "output": string, "exitCode": number }`
even when Git exits non-zero. The same optional `stashRestore` object as
`git.command` may appear when stash apply/pop or auto-stash checkout leaves
conflicts. Invalid arguments use the standard
`invalid_request` error envelope. `checkout` uses `referenceKind` values
`local`, `remote`, or `tag`; `clone` uses `remote` as its source and
`destination` as its target path. `force` permits a checkout that would
overwrite local edits; `autoStash` stashes dirty work, switches, then restores
the stash. Both default to `false`. `operationContinue`, `operationAbort`, and
`operationSkip` resolve whichever merge, rebase, cherry-pick, or revert Git
left in progress — they use the operation currently reported by Git instead of
trusting a client-supplied operation kind. The command response may contain a
structured `stashRestore` object with `stashReference` and `conflictedPaths`
when a stash restore keeps its entry because conflicts remain.

The Git safety commands expose structured state so clients do not parse
localized process output:

`git.checkoutPreflight` accepts `{ "root": string, "reference": string }` and
returns `{ "blockingPaths": string[] }` — dirty paths that also differ between
HEAD and the target reference.

`git.conflictMarkers` accepts `{ "root": string }` and returns
`{ "paths": string[] }` for staged files that still contain conflict markers.

`git.integrationPreflight` accepts
`{ "root": string, "reference": string, "operation": "merge" | "rebase" }` and
returns `{ "blockingPaths": string[], "blocksEntirely": boolean }`. Merge
blocking paths are the overlap between dirty files and the merge result; rebase
blocking paths are the full dirty set, and `blocksEntirely` is then true when
any local change exists.

`git.pullPreflight` accepts `{ "root": string }` and returns
`{ "upstream": string | null, "ahead": number, "behind": number,
"diverged": boolean, "hasLocalChanges": boolean }`. `upstream` is null when the
branch tracks nothing. `diverged` is true when both ahead and behind are
positive.

`git.operationState` accepts `{ "root": string }` and returns
`{ "kind": string, "reference": string | null, "step": number | null,
"total": number | null, "conflictedPaths": string[] }`. `kind` is empty when
nothing is in progress (no sequential Git operation). `step` and `total` are
populated only for rebase progress.

`git.diff` accepts `root`, `pathspecs`, optional `reference` or `commit`,
`staged`, `untracked`, `contextLines`, and `ignoreAllWhitespace`, and returns `{ "patch": string, "rows": [],
"hunks": [] }`. Rows contain one-based `oldLine`/`newLine` values where
available, `left`/`right` text, a `kind` (`context`, `changed`, `addition`,
`removal`, or `information`), and an optional `hunkId`. For `context` and
`information` rows both sides carry identical text, so `right` is omitted and
clients must fall back to `left`. Hunk entries contain their header and the
patch text needed for partial apply; rows are not duplicated per hunk, so
clients group `rows` by `hunkId` instead.
`git.shelfPatches` accepts `{ "root": string }` and returns `{ "stagedPatch": string,
"workingTreePatch": string }`. The core first resolves `git.status`, then collects
each staged, tracked worktree, and untracked path with the appropriate diff mode;
clients do not concatenate pathspecs or invoke Git directly. Patch ordering follows
the stable status path ordering, and an empty patch means that side has no changes.
`git.apply` accepts `root`, `patch`, and `mode`; supported modes are `stage`,
`unstage`, `discard`, `restoreIndex`, `worktree`, `restoreIndexCheck`, and
`worktreeCheck`. The two `*Check` modes only test whether the reverse patch
already applies, so Shelf restoration can be retried after a partial failure.
It returns
`{ "output": string, "exitCode": number }`. `restoreIndex` applies a saved
index patch to both the index and worktree; `worktree` applies only to the
worktree. Pathspecs must be workspace-relative and must not contain absolute
paths or `..` components.

`git.history` accepts `root`, an optional full `reference`, and `limit` (the
core clamps it to `1...5000`). It returns `references`, `commits`, and
`hasMore`; commit parents are explicit so clients can render merge topology
without re-parsing Git output.

`git.commit` accepts `root` and a revision, returning one `commit` object.
`git.blame` accepts `root` and a workspace-relative `path`; its line numbers
are one-based and author timestamps are Unix seconds.

`workspace.search` accepts `maxResults` for a total result cap. Callers that
need separate buckets may also provide `maxFileResults` and
`maxContentResults`; each category is capped independently and the total cap
still applies.

`workspace.searchEverywhere` uses the same query options and visibility fields,
and additionally accepts `maxSymbolResults`. Results are ordered as file,
type, symbol, and content matches. Java type and method results include a
one-based line, `symbolName`, and the matching source line in `preview`.

`workspace.replacePreview` accepts `root`, `query`, `replacement`, the same
query options, optional workspace-relative `paths`, optional `textOverrides`
keyed by relative path, and visibility fields. It returns `{ "files": [] }`
where each file contains replacement matches and the complete
`replacementText` to write. The command never writes files; callers can record
history before using `file.write` for the selected files.

The `history.*` commands accept an adapter-selected `storageRoot`; history
metadata never stores an absolute workspace or storage path. `history.record`
accepts `workspaceRoot`, a relative `path`, a `reason`, and optional UTF-8
`content`; when content is omitted the core reads the workspace file. Records
are versioned, de-duplicated against the latest snapshot, capped at 100 entries
per file, and pruned after 30 days. Invalid metadata and missing snapshot files
are ignored. `history.entries` returns Unix-second timestamps and relative
`contentPath` values. `history.content` rejects traversal, and
`history.relocate` updates metadata and storage paths at the command boundary.

The `shelf.*` commands accept an adapter-selected `storageRoot` and a
workspace root. Shelf data is stored under a versioned, workspace-isolated
directory and includes separate `staged.patch` and `working-tree.patch` files.
`shelf.create` returns an id and byte counts; `shelf.list` returns deterministic
newest-first summaries; `shelf.restore` returns both patch strings and does not
delete or mutate the Shelf; `shelf.delete` is an explicit operation. Shelf ids
reject absolute paths, separators, and traversal. A failed restore therefore
leaves the original Shelf available for retry.

`maven.scan` accepts `{ "root": string }` and returns `null` when the root does
not contain a readable `pom.xml`. A project response contains `groupId`,
`artifactId`, `version`, `packaging`, recursive `modules`, `profiles`, and
`hasWrapper`. Module paths are workspace-relative and use `/` separators.
Malformed XML returns `parse_failed`.

`maven.diagnostics` accepts `{ "root": string, "output": string }` and returns
`{ "issues": [] }`. Diagnostic paths may be absolute or workspace-relative;
the response preserves the path text, uses one-based line and column values,
and normalizes severity to `error` or `warning`. Duplicate issue lines are
removed deterministically.

`java.runConfigurations` accepts `{ "root": string, "paths": string[],
"modulePaths": string[] }`. Paths are relative Java files. The response
contains detected `mainClasses` and deterministic `configurations`; process
launching remains a platform adapter responsibility.

`java.codeVision` accepts a workspace root, a target Java path, and Java source
paths. It returns declaration locations and usage counts; Git blame attribution
is joined by the UI from the shared Git result. `java.className` accepts Java
source text and a file simple name and returns the fully qualified runtime class
name.

`java.sourceDefinition` accepts `source`, `declarationName`, and an optional
`memberName`, returning zero-based `line` and UTF-16 `utf16Column` or `null`
when no declaration is found.

`java.structure` accepts Java `source` and optional `declarationSources`. It
returns `foldRegions`, `implementationMarkers`, and `inlayHints`. Line numbers
are zero-based because these values are editor offsets; UTF-16 columns and
hidden ranges match the native text editor coordinate system. The parser is
platform-independent and does not start a Java process or contact JDT.
