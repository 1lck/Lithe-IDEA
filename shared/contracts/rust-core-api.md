# Rust Core API

The Rust core is the shared application runtime for macOS SwiftUI and Windows
React/Tauri. macOS calls the stable C ABI while the Tauri host links the Rust
crate directly. The C ABI remains:

```c
const char *lithe_core_version(void);
char *lithe_core_execute_json(const char *request);
char *lithe_core_lsp_provider_catalog_json(const char *workspace_root);
int32_t lithe_core_cancel(const char *operation_id);
void lithe_core_free_string(char *value);
```

The macOS package uses the small C bridge in `Sources/LitheRustCore/`. The
canonical C declarations are in `rust/lithe-core/include/lithe_core.h`.
Native clients can link the same `staticlib` or `cdylib`; Rust hosts call
`lithe_core::execute_json` and `lithe_core::cancel_operation` directly.
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
| `community.discourse.auth.begin` | Create an ephemeral RSA-OAEP authorization session and return the Discourse browser URL |
| `community.discourse.auth.complete` | Decrypt, validate, and consume one Discourse user API key callback |
| `community.discourse.auth.revoke` | Revoke the current Discourse user API key |
| `community.discourse.topics` | List normalized latest or top topic summaries |
| `community.discourse.topic` | Read one topic with ordered, sanitized post HTML |
| `community.discourse.categories` | List normalized visible categories |
| `community.discourse.search` | Search normalized topics and sanitized posts |
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
| `history.rename` | Set or clear a user-visible label on a history entry |
| `history.delete` | Delete one history entry and its snapshot |
| `maven.scan` | Parse a Maven project descriptor and recursively return modules/profiles |
| `maven.diagnostics` | Parse stable Maven compiler diagnostics from build output |
| `lsp.applyTextEdits` | Apply LSP UTF-16 text edits with range validation |
| `lsp.plainSnippet` | Convert LSP snippet insert text into plain editor text |
| `lsp.builtinCompletions` | Return lightweight current-file identifier completions |
| `lsp.builtinHover` | Return lightweight current-symbol hover text |
| `lsp.builtinNavigation` | Return lightweight current-file definition/reference locations |
| `lsp.startServer` | Start one Rust-owned process/session and begin initialization |
| `lsp.stopServer` | Gracefully shut down a session, with a bounded force-stop fallback |
| `lsp.syncDocument` | Open a document or apply a full-text or incremental `didChange` with monotonic versions |
| `lsp.closeDocument` | Close a document and clear its diagnostics |
| `lsp.request` | Submit a typed semantic request and return an opaque operation ID |
| `lsp.cancelOperation` | Cancel one pending semantic operation |
| `lsp.pollEvents` | Drain ordered typed lifecycle/feature/diagnostic/result/log events |
| `lsp.waitEvents` | Block until queued events exist or a timeout elapses, then drain them |
| `lsp.clearDiagnostics` | Clear every diagnostic owned by a session |
| `lsp.snapshot` | Return a diagnostic runtime snapshot for testing and control surfaces |
| `lsp.destroyServer` | Remove a terminal session handle from the registry |
| `java.runConfigurations` | Scan Java sources for main classes and return Maven/Spring run configurations |
| `java.codeVision` | Return Java declaration usage counts for editor code vision |
| `java.className` | Resolve a Java source package and simple name into a runtime class name |
| `java.sourceDefinition` | Locate a Java type, method, or field declaration in source text |
| `java.serverPort` | Parse Spring server port settings from properties or YAML text |
| `java.structure` | Parse Java editor structure, implementation candidates, and inlay hints |
| `spring.index` | Build a deterministic Spring configuration, bean, injection, and endpoint index |
| `runConfig.inspect` | Inspect `.lithe` run documents, versions, and staleness without writing files |
| `runConfig.generate` | Generate deterministic Java/Maven configurations and toolchain requirements |
| `runConfig.resolve` | Merge generated, project, and local layers and return diagnostics |
| `runConfig.updateOptions` | Apply typed option edits and return an updated project or local document |
| `runConfig.createUserConfiguration` | Validate a typed user configuration and return an updated document |
| `runConfig.createLaunchPlan` | Project one effective configuration into a platform-neutral Run or Debug plan |
| `git.status` | Resolve the repository, current branch, and working-tree changes |
| `git.watchContext` | Resolve the repository and absolute Git metadata roots needed by native file watchers |
| `git.pullRequestContext` | Resolve worktree-aware PR branch defaults, publication state, and uncommitted-change state |
| `git.command` | Execute one argument-based Git operation and return combined output plus exit code |
| `git.write` | Validate and execute shared Git mutations such as stage, commit, branch, checkout, remote sync, clone, and stash |
| `git.diff` | Produce a structured working-tree, index, reference, or commit patch |
| `git.apply` | Apply or check a patch in `stage`, `unstage`, `discard`, or Shelf restore mode |
| `git.history` | Return deterministic refs, commits, parent hashes, decorations, and pagination state |
| `git.commit` | Return one structured commit by revision |
| `git.commitFiles` | Return files changed by one commit |
| `git.comparison` | Return files changed between a reference and the working tree |
| `git.stashes` | Return structured stash references and messages |
| `git.checkoutPreflight` | Return local paths that would block switching to a reference |
| `git.pullPreflight` | Report the configured upstream, ahead/behind counts, divergence, and tracked local changes without fetching |
| `git.integrationPreflight` | Return local paths that block a merge, rebase, cherry-pick, or revert |
| `git.conflictMarkers` | Return staged text files that still contain conflict markers |
| `git.operationState` | Report an interrupted merge, rebase, cherry-pick, or revert and its conflicted paths |
| `git.blame` | Return structured line blame metadata |
| `github.parseRemote` | Parse a canonical GitHub HTTPS or SSH remote into owner/name |
| `github.requestPlan` | Validate one GitHub operation and produce a trusted platform HTTP request plan |
| `github.normalizeResponse` | Normalize raw GitHub JSON and HTTP status into deterministic data or a stable error |

Workspace paths in responses are relative and use `/` separators. Line numbers
are one-based. `git.status.repositoryRoot` may be an absolute path when the
opened workspace is a subdirectory of the repository; all Git change paths are
relative to that repository root. `git.status.ahead` and `behind` report the
current branch's tracking counts and are zero when no upstream is configured.
The core rejects absolute paths and `..`
traversal for file commands. Native file dialogs, file watching, PTY/ConPTY,
Java processes, and runtime discovery remain platform adapters.

The protocol version is currently `1`. Add a fixture under `shared/fixtures/`
before changing a response shape or search rule.

GitHub command shapes, authorization behavior, and supported pull-request
operations are documented in [`github.md`](github.md). Rust Core performs no
network or credential I/O for these commands.

`community.discourse.auth.begin` accepts an HTTPS `origin`, stable `clientId`,
user-visible `applicationName`, platform-owned `authRedirect`, and a non-empty
array of supported `scopes`. It returns an opaque `flowId`, an
`authorizationUrl` that requests RSA-OAEP padding, and an `expiresAt` Unix
timestamp. The private key and nonce remain in Rust memory and expire after ten
minutes. `community.discourse.auth.complete` accepts that `flowId` and the full
`callbackUrl`; it consumes the flow, verifies the callback target, decrypts the
payload, and checks the nonce before returning `userApiKey` and `apiVersion`.
Platform hosts open the browser, receive their registered URL scheme, and store
the returned credential in Keychain or Windows Credential Manager. They do not
implement Discourse cryptography or callback validation.

The authenticated community commands accept `origin`, `userApiKey`, and
`clientId` plus their operation-specific fields. Rust owns HTTPS requests,
authentication headers, a 30-second request timeout, a 5 MB response limit,
Discourse JSON decoding, deterministic post ordering, and HTML sanitization.
Platform clients never issue a parallel Discourse request or parse a second
response shape. Credential vault reads and writes remain native adapters; the
credential is passed to Core only for the duration of one command.

`git.watchContext` accepts `{ "root": string }`. When `root` is not inside a
Git repository, it returns `null`. Otherwise it returns
`{ "repositoryRoot": string, "gitDirectory": string, "gitCommonDirectory": string }`;
all three fields are absolute filesystem paths.

`git.pullRequestContext` accepts `{ "root": string }` and returns
`currentBranch`, `suggestedBaseBranch`, `suggestedPublishBranch`,
`requiresPublish`, `detached`, and `hasUncommittedChanges`. For detached
worktrees, Core uses the worktree HEAD reflog's oldest commit and refs pointing
at that commit to suggest the branch from which the worktree started. For a
named branch, `requiresPublish` remains true until its current HEAD is present
on the same branch under `origin`, because GitHub repository identity is also
resolved from `origin`.

`git.command` accepts `{ "root": string, "arguments": string[], "input": string? }`.
Arguments are passed directly to the Git executable without a shell. A
successful process launch returns `{ "output": string, "exitCode": number }`
even when Git exits non-zero; process-start and workspace failures use the
standard error envelope.

`git.write` accepts a typed mutation request. Its required `operation` values are
`stage`, `unstage`, `discard`, `discardAll`, `stageAll`, `commit`, `cherryPick`, `revert`,
`reset`, `createBranch`, `publishBranch`, `renameBranch`, `deleteBranch`, `merge`, `rebase`,
`fetch`, `pull`, `push`, `checkout`, `checkoutRevision`, `clone`, `stashPush`,
`stashApply`, `stashPop`, `stashDrop`, `operationContinue`, `operationAbort`, and
`operationSkip`. Optional fields are `paths`, `reference`, `referenceKind`,
`revision`, `name`, `message`, `remote`, `destination`, `mode`,
`includeUntracked`, `checkout`, and `amend`.

The core validates pathspecs, revisions, branch names, references, reset modes,
stash references, and operation-specific required fields before invoking Git.
Successful process launch returns `{ "output": string, "exitCode": number }`
even when Git exits non-zero. Invalid arguments use the standard
`invalid_request` error envelope. `checkout` uses `referenceKind` values
`local`, `remote`, or `tag`; `clone` uses `remote` as its source and
`destination` as its target path. `publishBranch` validates `name`, creates
and checks out that branch at a detached HEAD when needed, then pushes it with
an upstream. If the push fails, the local branch is intentionally retained so
the user can fix credentials or connectivity and retry without losing commits.

`operationContinue`, `operationAbort`, and `operationSkip` inspect Git metadata
to select the active merge, rebase, cherry-pick, or revert instead of accepting
an operation kind from the caller. Continue is rejected while conflicted paths
remain, and skip is supported only for a rebase. All three return the normal
`{ "output": string, "exitCode": number }` process result when Git is invoked;
an absent or unsupported operation state uses the `invalid_request` envelope.

`git.checkoutPreflight` accepts `{ "root": string, "reference": string }` and
returns `{ "blockingPaths": string[] }`. The sorted, de-duplicated result
contains tracked paths that are both locally modified and different between
HEAD and the target, plus untracked paths that the target reference tracks.

`git.pullPreflight` accepts `{ "root": string }` and returns `upstream` as a
string or `null`, numeric `ahead` and `behind` counts, `diverged`, and
`hasLocalChanges`. It reads the existing tracking reference without fetching;
`diverged` is true only when both counts are non-zero. `hasLocalChanges` checks
tracked changes and excludes untracked files. A branch with no configured
upstream returns `null`, zero counts, and false for both booleans.

`git.integrationPreflight` accepts `{ "root": string, "reference": string,
"operation": string }`, where `operation` is `merge`, `rebase`, `cherryPick`,
or `revert`. It returns sorted, de-duplicated `blockingPaths` and
`blocksEntirely`. Merge, cherry-pick, and revert report only dirty tracked paths
that overlap files the operation would write. Rebase reports every dirty
tracked path and sets `blocksEntirely` to true when that set is non-empty.

`git.conflictMarkers` accepts `{ "root": string }` and returns
`{ "paths": string[] }`. Paths are sorted and de-duplicated staged text files
whose staged content has a line beginning with an opening, closing, or diff3
conflict marker. A bare
`=======` line is not treated as a conflict marker.

`git.operationState` accepts `{ "root": string }` and returns `kind`,
`reference`, `step`, `total`, and sorted, de-duplicated `conflictedPaths`.
`kind` is an empty string when no operation is active; otherwise it is `merge`,
`rebase`, `cherryPick`, or `revert`. `reference`, `step`, and `total` are
nullable, and the progress counters are populated only for a rebase. State is
read from Git's own metadata, so operations started outside Lithe are reported.

`git.diff` accepts `root`, `pathspecs`, optional `reference` or `commit`,
`staged`, `untracked`, `contextLines`, and `ignoreAllWhitespace`, and returns `{ "patch": string, "rows": [],
"hunks": [] }`. Rows contain one-based `oldLine`/`newLine` values where
available, `left`/`right` text, a `kind` (`context`, `changed`, `addition`,
`removal`, or `information`), and an optional `hunkID`. For `context` and
`information` rows both sides carry identical text, so `right` is omitted and
clients must fall back to `left`. Hunk entries contain their header and the
patch text needed for partial apply; rows are not duplicated per hunk, so
clients group `rows` by `hunkID` instead.
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
core clamps it to `1...5000`). It returns `references`, `commits`, `hasMore`,
and the optional effective `userName` and `userEmail` from repository Git
configuration. Commit parents are explicit so clients can render merge
topology without re-parsing Git output. The identity fields let clients
implement a stable `me` filter without guessing from recent commits.

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

`lsp.applyTextEdits` accepts `{ "text": string, "edits": [] }`, where each edit
has an LSP range with zero-based `line` and UTF-16 `utf16Column` fields plus
`newText`. Ranges are validated and overlapping edits return
`invalid_request` with details `overlappingEdits`; invalid positions return
details `invalidRange`. Successful responses return `{ "text": string }`.

`lsp.plainSnippet` accepts `{ "value": string }` and returns `{ "text": string }`
after removing LSP tab stops and replacing simple placeholder defaults such as
`${1:name}` with `name`.

`lsp.builtinCompletions`, `lsp.builtinHover`, and `lsp.builtinNavigation` are
the no-process lightweight language path. They accept current-file text, an
absolute `filePath`, and a zero-based LSP position. Completion returns
current-file identifiers with text edits for the active prefix. Hover returns
the current identifier as markdown. Navigation returns current-file locations;
definition prefers declaration-looking occurrences, while references returns
all matching identifier occurrences. These commands are deliberately
text-level fallbacks; precise type-aware behavior belongs to a started language
server.

The LSP provider catalog is returned by `lithe_core_lsp_provider_catalog_json`.
Each provider descriptor may include `languageServerLaunch` with ordered
`executableNames` and `arguments`; Swift adapters use this metadata when they
need to discover a real language-server executable; the selected launch plan is
then submitted to the Rust-owned runtime. Built-in descriptors are merged by provider ID with the optional
`.lithe/lsp/language-providers.json` workspace document. See
[`language-tooling.md`](../../docs/architecture/language-tooling.md) for routing,
discovery, lifecycle, and compatibility rules.

The `lsp.*Server`, `lsp.*Document`, `lsp.request`, `lsp.pollEvents`, and
`lsp.waitEvents`
commands are the semantic LSP runtime boundary. `lsp.startServer` accepts the
provider ID, selected executable/arguments/environment, root URI, working
directory, initialization options, optional runtime executable and cache
directory, plus initialize/request/shutdown deadlines. Rust owns the returned
session's child process, stdin/stdout/stderr, framing buffer, JSON-RPC request
IDs, document versions, pending deadlines, capabilities, diagnostics, and
graceful/forced termination.

`lsp.syncDocument` accepts `{ sessionId, uri, languageId, text?, contentChanges? }`.
The first sync emits `didOpen` at version 1. Later syncs emit `didChange` with
increasing versions. When the server advertised incremental `textDocumentSync`
and `contentChanges` includes LSP ranges, the notification carries those
range-based edits and does not require a full document `text` field. Otherwise
the change is a full-text replacement. `lsp.request` accepts a semantic `operation` plus
the operation-specific URI, position, range, diagnostics, item, action, or
command fields, and returns `{ operationId }`. Supported operations include
completion, hover, definition/declaration/type-definition, references,
implementation, rename, formatting, code actions and resolve, execute command,
inlay hints, folding ranges, code lens, and provider virtual documents.
The `virtualDocument` operation accepts `{ sessionId, operation,
virtualUri }` without a document `uri`. Its terminal `requestCompleted` event
returns `{ text }`, where `text` is the provider-resolved UTF-8 source for the
opaque virtual URI.

`lsp.pollEvents` drains events ordered by per-session `sequence`. `lsp.waitEvents`
accepts `{ sessionId, timeoutMilliseconds }` and waits on a session event
channel until events are queued or the timeout elapses, then drains the same
typed events. Hosts should use `waitEvents` so idle sessions do not poll.
Event types
include `stateChanged`, `featuresChanged`, `diagnostics`,
`requestCompleted`, `serverInfoChanged`, and `log`. Every request completes at
most once with either `result` or a structured runtime error containing
provider/session, stage, optional method/document/request, stable code, and
optional process-exit detail. Late responses after cancellation or deadline
are ignored. Diagnostics are accepted only for documents open in the current
session, and versioned diagnostics must match the current document version.

The client reducer, raw JSON-RPC message, frame, and parser functions are
internal Rust implementation seams; they are not public application commands.
Completion, hover, navigation, edit, hint, folding, and code-lens responses are
normalized by Rust before they cross the application boundary. Unknown server
requests receive JSON-RPC `Method not found` instead of being silently ignored.

The `history.*` commands accept an adapter-selected `storageRoot`; history
metadata never stores an absolute workspace or storage path. `history.record`
accepts `workspaceRoot`, a relative `path`, a `reason`, and optional UTF-8
`content`; when content is omitted the core reads the workspace file. Records
are versioned, de-duplicated against the latest snapshot, capped at 100 entries
per file, and pruned after 30 days. Invalid metadata and missing snapshot files
are ignored. `history.entries` returns Unix-second timestamps and relative
`contentPath` values. `history.content` rejects traversal,
`history.relocate` updates metadata and storage paths, and `history.rename` and
`history.delete` validate both the relative file path and entry ID before
changing stored metadata.

`maven.scan` accepts `{ "root": string, "paths"?: string[] }` and returns
`null` when neither the root nor the supplied visible workspace-relative paths
contain a readable `pom.xml`. Candidates are tried in shallowest-first order,
with `/`-normalized lexical paths breaking ties, until one parses successfully;
a malformed candidate does not hide a valid nested project. A project response
contains its workspace `relativePath`,
`groupId`, `artifactId`, `version`, `packaging`, recursive `modules`, `profiles`,
and `hasWrapper`. Module paths are relative to the selected Maven root and use
`/` separators. Malformed XML returns `parse_failed`.

`maven.diagnostics` accepts `{ "root": string, "output": string }` and returns
`{ "issues": [] }`. Diagnostic paths may be absolute or workspace-relative;
the response preserves the path text, uses one-based line and column values,
and normalizes severity to `error` or `warning`. Duplicate issue lines are
removed deterministically.

`java.runConfigurations` accepts `{ "root": string, "paths": string[],
"modulePaths": string[] }`. Java and module paths are workspace-relative. The response
contains detected `mainClasses` and deterministic `configurations`; process
launching remains a platform adapter responsibility.

The `runConfig.*` commands implement the versioned project protocol described
by the JSON Schemas in this directory. `runConfig.inspect` accepts `root` and
never writes files. `runConfig.generate` accepts `root`, relative Java `paths`,
and relative `modulePaths`; it returns generated configuration and toolchain
requirement documents for the platform adapter to write atomically.

`runConfig.resolve` accepts `root`, optional local `toolchainCandidates`, and
optional `localDocument`. When `localDocument` is present, Core uses that JSON
object as the local layer instead of reading `.lithe/run/local.json`. It merges
configurations by stable ID using this precedence:
`local.json > configurations.json > generated.json`. Scalars and arrays are
replaced by the higher layer, while toolchain maps merge by key. It returns
effective configurations, their source, the team default, structured
diagnostics for stale, orphaned, missing, disabled, and toolchain mismatch
states, and the effective global `toolchain`. A document-level `toolchain`
object in the local layer (e.g.
`{ "java": { "homePath": ... }, "maven": { "executablePath": ..., "javaHomePath": ... } }`)
is applied to every configuration's `extensions.java.*` and is authoritative
over per-configuration toolchain paths.

`runConfig.updateOptions` and `runConfig.createUserConfiguration` are pure
document transformations. They validate scope, paths, supported types, stable
IDs, main classes, modules, and argument parsing, then return UTF-8 JSON in the
`document` field. The platform adapter selects the target project or local
file and performs the atomic write. These commands never write files.
For project-scoped option updates, selected toolchain paths must resolve inside
`root` and are persisted with `/`-separated project-relative paths. Local-scoped
updates may carry host absolute paths. `runConfig.updateOptions` and
`runConfig.inspect` accept the same optional `localDocument` override.
When `updateOptions` carries a `toolchain` object (`javaHomePath`,
`mavenExecutablePath`, `mavenJavaHomePath`), it writes the document-level
global toolchain into the local layer instead of patching a configuration;
project scope rejects this payload because toolchain paths are machine-local.

`runConfig.createLaunchPlan` accepts `root`, `configurationId`, optional
`currentFile` and `classPath`, optional `debugPort`, and optional
`localDocument`. It returns a toolchain
reference, argument array, project-relative working directory, and structured
environment references. It does not return a shell command or platform
executable path. All project paths use `/`, reject absolute paths and `..`
traversal, and remain relative to `root`. A `java.main` configuration without a
Maven toolchain launches through `project-jdk` and the configuration's Java
source path.

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

`spring.index` accepts `root`, workspace-relative `paths`, optional trusted
absolute `metadataRepositories` (and the legacy singular `metadataRepository`),
optional `textOverrides` keyed by relative path, and
`refreshDependencyMetadata`. The command reads Spring configuration
metadata from workspace JSON files and dependency JARs, indexes application
configuration documents and Java source, and returns deterministically ordered
`properties`, `values`, `propertyReferences`, `diagnostics`, `beans`,
`injections`, and `endpoints` collections. Locations use relative paths and
one-based lines and columns.

`properties` include type, documentation, default value, and an optional Java
declaration. `values` include profile/override state and an optional declaration
target. `propertyReferences` represent Java `@Value` uses. Bean resolution
accounts for component names, `@Bean` aliases, interfaces, `@Qualifier`,
`@Resource`, `@Primary`, field injection, and constructor injection. Endpoint
entries expand multiple controller/method paths and retain the exact declared
HTTP method set.

Dependency metadata is cached in the Rust process. Project-open indexing sets
`refreshDependencyMetadata` to `true`; debounced unsaved-buffer indexing leaves
it `false`, so editing Java or configuration files does not repeatedly traverse
and open the local dependency repository. The repository path is selected by
the platform composition layer and is never persisted in shared results.
