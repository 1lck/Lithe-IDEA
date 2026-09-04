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

The macOS package uses the small C bridge in `macos/Sources/LitheRustCore/`. The
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
| `document.lifecycle` | Reduce a shared document save, external-change, or conflict event without reading text or disk |
| `history.record` | Store a versioned text snapshot and metadata |
| `history.entries` | List valid history entries for one file or a workspace |
| `history.content` | Read a stored history snapshot by relative storage path |
| `history.relocate` | Move a file's history records after a rename |
| `history.rename` | Set or clear a user-visible label on a history entry |
| `history.delete` | Delete one history entry and its snapshot |
| `maven.scan` | Parse a Maven project descriptor and recursively return modules/profiles |
| `maven.launchPlan` | Produce a deterministic Maven invocation from a versioned project context |
| `maven.diagnostics` | Parse stable Maven compiler diagnostics from build output |
| `debug.createSession` | Create a transport-neutral DAP session and return its initialize frame |
| `debug.launch` | Queue a launch or attach request, including during initialization |
| `debug.javaTestLaunch` | Normalize JUnit or TestNG launch metadata into Java DAP arguments |
| `debug.steppingFilters` | Return adapter defaults or normalize portable stepping filters |
| `debug.relocateBreakpoints` | Move source breakpoints across one exact UTF-16 editor replacement |
| `debug.setBreakpoints` | Replace and deterministically order one source's DAP breakpoints |
| `debug.setExceptionBreakpoints` | Replace and deterministically order one session's exception filters |
| `debug.setFunctionBreakpoints` | Replace and deterministically order one session's named function breakpoints |
| `debug.dataBreakpointInfo` | Resolve an adapter-owned data breakpoint identity for a paused variable or field |
| `debug.setDataBreakpoints` | Replace and deterministically order one session's resolved data breakpoints |
| `debug.setVariable` | Replace one visible variable value in its adapter-owned parent container |
| `debug.cancelOperation` | Cancel or time out one pending operation and ignore its late response |
| `debug.execute` | Submit continue, pause, next, step-in, or step-out control |
| `debug.inspect` | Request normalized threads, frames, scopes, variables, or evaluation |
| `debug.receive` | Reduce base64-encoded bytes received from a platform-owned DAP transport |
| `debug.runInTerminalResponse` | Complete one adapter-requested native terminal launch |
| `debug.disconnect` | Begin the DAP disconnect handshake without closing the native transport |
| `debug.destroySession` | Remove a session after the platform closes its native transport |
| `lsp.applyTextEdits` | Apply LSP UTF-16 text edits with range validation |
| `lsp.plainSnippet` | Convert LSP snippet insert text into plain editor text |
| `lsp.builtinCompletions` | Return lightweight current-file identifier completions |
| `lsp.builtinHover` | Return lightweight current-symbol hover text |
| `lsp.builtinNavigation` | Return lightweight current-file definition/reference locations |
| `lsp.startServer` | Start one Rust-owned process/session and begin initialization |
| `lsp.jdtWorkspaceKey` | Derive the deterministic JDT LS workspace-state directory key |
| `java.workspacePolicy` | Decide Java workspace activation and classify changed paths |
| `java.jdtWorkspaceFingerprint` | Reduce platform build-file observations to the portable JDT LS workspace fingerprint |
| `java.jdtCacheRetention` | Select expired inactive JDT LS workspace-state keys from platform metadata |
| `lsp.stopServer` | Gracefully shut down a session, with a bounded force-stop fallback |
| `lsp.syncDocument` | Open a document or apply a full-text or incremental `didChange` with monotonic versions |
| `lsp.workspaceFilesChanged` | Publish normalized created, changed, or deleted workspace files to one session |
| `lsp.closeDocument` | Close a document and clear its diagnostics |
| `lsp.request` | Submit a typed semantic request and return an opaque operation ID |
| `java.navigationMarkers` | Resolve versioned Java gutter markers from bounded JDT LS semantic requests |
| `java.resolveNavigation` | Resolve one Java gutter marker to normalized parent or implementation locations |
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
| `java.structure` | Parse Java editor folds, inlay hints, and portable syntax roles |
| `spring.index` | Build a deterministic Spring configuration, bean, injection, and endpoint index |
| `runConfig.inspect` | Inspect `.lithe` run documents, versions, and staleness without writing files |
| `runConfig.generate` | Generate deterministic Java/Maven configurations and toolchain requirements |
| `runConfig.resolve` | Merge generated, project, and local layers and return diagnostics |
| `runConfig.updateOptions` | Apply typed option edits and return an updated project or local document |
| `runConfig.saveEditorChanges` | Prepare the local and optional project documents for one editor save |
| `runConfig.createUserConfiguration` | Validate a typed user configuration and return an updated document |
| `runConfig.createLaunchPlan` | Project one effective configuration into a platform-neutral Run or Debug plan |
| `git.status` | Resolve the repository, current branch, and working-tree changes |
| `git.watchContext` | Resolve the repository and absolute Git metadata roots needed by native file watchers |
| `git.worktrees` | Return deterministic registered-worktree metadata without scanning each checkout |
| `git.pullRequestContext` | Resolve worktree-aware PR branch defaults, publication state, and uncommitted-change state |
| `git.command` | Execute one argument-based Git operation and return its arguments, streams, exit code, and ordered subprocess invocations |
| `git.write` | Validate and execute shared Git mutations such as stage, commit, branch, checkout, remote sync, clone, and stash |
| `git.diff` | Produce a structured working-tree, index, reference, or commit patch |
| `git.apply` | Apply or check a patch in `stage`, `unstage`, `discard`, or Shelf restore mode |
| `git.history` | Return the legacy combined reference snapshot and first bounded commit page |
| `git.references` | Return deterministic refs, recent local branches, ahead/behind state, and effective Git identity without scanning commit history |
| `git.historyPage` | Return one bounded commit page, parent hashes, decorations, and an opaque continuation cursor |
| `git.historyCursorClose` | Release an unfinished incremental history cursor and its Git process |
| `git.pushPreview` | Resolve a local branch push destination and the bounded commits not present on that remote base |
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
`git.worktrees.worktrees` is ordered with the primary worktree first and then
by path. Each entry contains `path`, `head`, nullable `branch`, `isCurrent`,
`isPrimary`, `isBare`, `isDetached`, `isLocked`, nullable `lockReason`,
`isPrunable`, and nullable `pruneReason`. The path is absolute because linked
worktrees may live outside the opened workspace; clients must treat it as an
opaque native boundary value and must not persist it as a portable identifier.
Core reads the list with one porcelain operation and does not run status in
each checkout.
For a rename or copy, each change uses the destination as `path` and preserves
the source as `originalPath`; platform mutations that act on the Git entry pass
both paths back to Core.
The core rejects absolute paths and `..`
traversal for file commands. Native file dialogs, file watching, PTY/ConPTY,
Java processes, and runtime discovery remain platform adapters.

`git.history.recentReferences` contains at most five existing local branches in
most-recently-used order. The current branch is first. Core derives checkout
history from the repository's HEAD reflog, de-duplicates branch names, ignores
detached or deleted references, and fills missing entries deterministically.
The remote HEAD target is preferred as the default branch, followed by `main`,
`master`, and the remaining local references in refname order.

The protocol version is currently `1`. Add a fixture under `shared/fixtures/`
before changing a response shape or search rule.

`document.lifecycle` accepts a discriminated `state` (`clean`, `dirty`,
`saving`, or `conflict`) and one typed `event`. It returns the next state plus
one platform effect such as `writeToDisk`, `reloadFromDisk`, or
`showConflict`. `saving` carries the snapshot revision and `operationId`, so a
stale completion cannot clear newer edits. Live text, editor models, selections,
watchers, and native file I/O stay platform-owned; local keystrokes update the
same revision semantics in-process and never cross the Rust boundary. The
portable examples are in `shared/fixtures/documents/lifecycle-v1.json`.

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
successful process launch returns `{ "arguments": string[], "output": string,
"stdout": string, "stderr": string, "exitCode": number, "invocations":
GitCommandInvocation[], "operationError": CoreError? }` even when Git exits
non-zero. `GitCommandInvocation` is `{ "arguments": string[], "stdout": string,
"stderr": string, "exitCode": number }`. The top-level `arguments`, streams,
and exit code always equal the final invocation for compatibility, and `output`
is that invocation's `stdout` followed by `stderr`; `invocations` records every
subprocess in execution order. Validation, process-start, and workspace failures
that occur before Git starts use the standard error envelope. If a follow-up
validation or probe fails after at least one subprocess was recorded, the
response retains the invocation trace and includes the failure as
`operationError`.

`git.write` accepts a typed mutation request. Its required `operation` values are
`stage`, `unstage`, `discard`, `discardAll`, `stageAll`, `commit`, `ignore`, `exclude`, `cherryPick`, `revert`,
`reset`, `editCommitMessage`, `deleteCommit`, `squashCommits`, `createBranch`, `publishBranch`,
`renameBranch`, `setUpstream`, `unsetUpstream`, `deleteBranch`, `updateBranch`, `merge`, `rebase`, `createWorktree`,
`removeWorktree`, `lockWorktree`, `unlockWorktree`, `repairWorktrees`, `pruneWorktrees`,
`fetch`, `pull`, `push`, `checkout`, `checkoutAndRebase`, `checkoutRevision`, `clone`, `stashPush`,
`stashApply`, `stashPop`, `stashDrop`, `deleteRemoteBranch`, `operationContinue`,
`operationAbort`, `operationSkip`, `createTag`, and `deleteTag`. Optional fields are `paths`, `reference`, `referenceKind`,
`gitReference`, `revision`, `revisions`, `name`, `message`, `remote`, `destination`, `mode`,
`includeUntracked`, `checkout`, `amend`, `force`, `pushTags`, `expectedPush`, and `autoStash`.

The core validates pathspecs, revisions, branch names, references, reset modes,
stash references, and operation-specific required fields before invoking Git.
`setUpstream` requires a typed remote `gitReference` and passes its complete
`refs/remotes/*` identity to Git, so a same-named local branch cannot make the
upstream ambiguous. `createWorktree` likewise requires a typed reference; for a
remote reference Core executes one `git worktree add --track -b` mutation using
the complete remote ref, so branch creation, checkout, and tracking setup do not
form separate platform-visible success states. Worktree mutations re-read Git's
registered list and reject arbitrary paths. Removal rejects the current,
primary, or locked worktree; dirty worktrees require an explicit `force` value.
`repairWorktrees` refreshes administrative links after a repository or worktree
has moved. `pruneWorktrees` removes registrations whose checkout is already missing and
does not recursively delete an arbitrary directory.

`updateBranch` requires a typed, non-current local `gitReference`. Core resolves
that branch's configured remote upstream and performs an atomic Fetch that
refreshes the remote-tracking ref and fast-forwards the local branch without
switching HEAD. Git rejects diverged branches and branches checked out by any
worktree, so the operation cannot discard local commits or mutate another active
checkout.
Successful process launch returns `{ "arguments": string[], "output": string,
"stdout": string, "stderr": string, "exitCode": number, "invocations":
GitCommandInvocation[], "operationError": CoreError?, "stashRestore":
GitStashRestore?, "warnings": GitOperationWarning[] }` even when Git exits non-zero.
`GitOperationWarning` is `{ "code": string, "message": string, "details"?: string }`
and reports a non-fatal follow-up failure after the requested mutation already
succeeded. Platform clients must retain the successful operation outcome while
presenting the warning. The top-level process fields
always describe the final subprocess, and `output` is that subprocess's
`stdout` followed by `stderr`. `invocations` records every Git subprocess for
composite operations such as `discardAll` and Smart Checkout in execution
order; each item contains the exact argument vector (excluding the executable
name), separate streams, and exit code. A follow-up validation or probe failure
after Git has started is returned in `operationError` alongside the retained
trace. A stash restore conflict is a logical operation failure represented by
`stashRestore`, even when a later diagnostic invocation exits successfully.
Consumers must therefore consider `operationError` and `stashRestore` in
addition to the compatibility `exitCode`. The shared compatibility fixtures are
`shared/fixtures/git/command-response-v1.json` and
`shared/fixtures/git/command-error-response-v1.json`. Invalid arguments found
before any Git subprocess use the standard `invalid_request` error envelope.
`checkout` uses `referenceKind` values
`local`, `remote`, or `tag`; `clone` uses `remote` as its source and
`destination` as its target path. `publishBranch` validates `name`, creates
and checks out that branch at a detached HEAD when needed, then pushes it with
an upstream. If the push fails, the local branch is intentionally retained so
the user can fix credentials or connectivity and retry without losing commits.

`git.pushPreview` accepts `root`, an optional complete local `gitReference` or
legacy `reference`, an optional bounded `limit`, and `pushTags`. It returns `localBranch`,
`localHead`, `remote`, `remoteBranch`, nullable `remoteTrackingOid`, nullable
`upstream`, exact reviewed `tags`, `commits`, and `hasMore` using
`shared/fixtures/git/push-preview-v1.json`. The push destination follows
`branch.<name>.pushRemote`, then `remote.pushDefault`, the configured upstream
remote, `branch.<name>.remote`, and finally `origin` or the first configured
remote. A destination without a fetched tracking reference previews commits not
reachable from that remote. A reviewed `push` mutation sends these resolved fields
back as `expectedPush`; Core rejects a stale local tip, destination, or tracking OID
before starting Git. `force` binds `--force-with-lease` to the reviewed destination
OID when `expectedPush` is present, and Core also validates the reviewed tag
identities; `pushTags` accepts `none`, `all`, or `reachable`
and maps to no tag option, `--tags`, or `--follow-tags` respectively. Legacy push
callers may omit `expectedPush`. A reviewed push uses the preview's immutable
`localHead` OID as the refspec source, so a repository change after validation
cannot add unreviewed commits to the operation. Because Git cannot infer an
upstream from an OID source, Core explicitly configures the reviewed local
branch after a successful first push.

New reference-based workflows send `gitReference` as `{ "fullName": string,
"shortName": string, "kind": "local" | "remote" | "tag" }`. Core verifies
that all three fields describe the same namespace and validates the full ref
with Git. The legacy `reference` and `referenceKind` fields remain accepted for
existing platform calls. `checkoutAndRebase` requires a local or remote branch
reference and a completely clean worktree; Core records the current local
branch before switching and rebases the checked-out branch onto that original
branch. A dirty tree or detached HEAD is rejected before checkout begins. When
remote checkout finds an existing same-named local branch, Core uses it only if
its configured upstream is the selected complete remote reference.

`pull` without an explicit reference retains current-upstream behavior. An
explicit remote reference may use either the preferred `gitReference` shape or
the legacy `reference` plus `referenceKind: "remote"` fields. Core validates and
safely splits `refs/remotes/<remote>/<branch>` against configured remote names,
then invokes pull with the explicit remote and branch using `mode` `ffOnly`,
`merge`, or `rebase`. Platforms must not parse the remote reference or construct
these Git arguments themselves.

`deleteRemoteBranch` requires a complete remote `gitReference`. Core resolves
the configured remote with longest-prefix matching and invokes a structured
remote branch deletion; platforms must not split `shortName` themselves.

When `commit` includes `paths`, Core stages the complete working-tree state of
those paths, including untracked files and deletions, then commits only those
paths. Other paths already present in the index remain staged and are not part
of the new commit. Core checks conflict markers after preparing that final
snapshot in an isolated temporary index initialized from the operation's HEAD
tree. The real index is not changed on any
staging, validation, hook, signing, or commit failure; successful commits
reconcile only the selected paths, preserving unrelated staging created while
the operation ran. Selected paths used to prepare and reconcile the snapshot
are passed to Git over NUL-delimited stdin with `--pathspec-from-file`, avoiding
platform command-line limits and preserving rename source/destination identity.
`git.diff` accepts `worktreeSnapshot: true` to review that same complete
working-tree snapshot against `HEAD` through an isolated temporary index. This
mode includes staged, unstaged, untracked, deleted, and same-path recreated
files without reading or mutating the real index and cannot be combined with
other diff reference modes.
A `commit` request without `paths` retains
the legacy behavior of committing the existing index. `ignore` appends root-anchored patterns to the
repository's top-level `.gitignore`; `exclude` appends the same patterns to the
worktree-aware Git metadata path for `info/exclude`. Both ignore operations
preserve existing content, escape Git pattern characters, de-duplicate rules,
and interpret a trailing `/` as a directory rule.

`editCommitMessage` rebuilds the selected commit and its later first-parent
descendants with the new `message`. `squashCommits` requires at least two
distinct, contiguous `revisions`, uses the newest selected tree, and rebuilds
later descendants. Both preserve commit author and committer attribution and
atomically update the checked-out branch reference. `deleteCommit` drops a
non-root commit and replays later commits; deleting HEAD resets to its parent.
All three operations reject a dirty worktree, detached HEAD, an active Git
operation, a target outside the current branch's first-parent chain, a rewrite
range containing a merge commit, or any rewritten commit reachable from
`refs/remotes`.

`createTag` uses `name` for the new tag, `revision` as its target commit or
revision, and an optional `message`: when the field is present (including an
empty value), it creates an annotated tag (`git tag -a`); an absent field
creates a lightweight tag. UI callers trim new user-entered messages. Core
passes the supplied annotation with verbatim cleanup so restore preserves
CRLF and trailing blank lines, and an explicit empty value preserves an empty
annotated tag. Tag names must satisfy the `git check-ref-format` refname rules and must not
begin with a dash; `shared/fixtures/git/tag-names.json` pins the boundary cases
for Core and host-side validation. Before invoking Git, `createTag` probes the
repository so a duplicate tag (`A tag named '<name>' already exists`) and an unresolvable
non-commit target (`Could not resolve tag target '<rev>'`) fail with stable
`invalid_request` messages instead of localized Git output. `deleteTag` uses
`name` and removes `refs/tags/<name>`; a missing tag fails with
`The tag '<name>' does not exist`. On success the response carries a
structured `tagDeletion` record — `{ "name": string, "deletedTarget": string,
"kind": "lightweight" | "annotated", "message": string? }` — where
`deletedTarget` is the peeled commit the deleted ref resolved to and
`message` is the original annotation with its line breaks preserved. Hosts
can rebuild the tag by replaying `createTag` with `name`, `deletedTarget`,
and `message`; the tagger identity and timestamp are intentionally not
preserved. Deletion supplies the observed unpeeled object ID to `update-ref`,
so a concurrent force-update fails atomically instead of deleting new state and
returning a stale recovery target. `deleteBranch` applies the same expected-OID
guard after checking the branch is fully merged and not checked out, then
on success, carries a structured `branchDeletion` record —
`{ "name": string, "deletedTarget": string }` — so hosts can offer to
recreate the branch at its previous commit; a missing branch fails with
`The branch '<name>' does not exist`. If the ref deletion succeeds but branch
configuration cleanup fails, the response contains both `branchDeletion` and a
`branch_config_cleanup_failed` warning; hosts must preserve the Restore action while surfacing the
cleanup diagnostic.

`operationContinue`, `operationAbort`, and `operationSkip` inspect Git metadata
to select the active merge, rebase, cherry-pick, or revert instead of accepting
an operation kind from the caller. Continue is rejected while conflicted paths
remain, and skip is supported only for a rebase. All three return the normal
Git process result when Git is invoked;
an absent or unsupported operation state uses the `invalid_request` envelope.

`git.checkoutPreflight` accepts `{ "root": string, "reference": string }` or
the preferred `{ "root": string, "gitReference": GitReference }` shape and
returns `{ "blockingPaths": string[] }`. The sorted, de-duplicated result
contains tracked paths that are both locally modified and different between
HEAD and the target, plus untracked paths that the target reference tracks.

`git.pullPreflight` accepts `{ "root": string }` and returns `upstream` as a
string or `null`, numeric `ahead` and `behind` counts, `diverged`, and
`hasLocalChanges`. It reads the existing tracking reference without fetching;
`diverged` is true only when both counts are non-zero. `hasLocalChanges` checks
tracked changes and excludes untracked files. A branch with no configured
upstream returns `null`, zero counts, and false for both booleans.

`git.integrationPreflight` accepts either `reference` or `gitReference` with
`root` and `operation`, where `operation` is `merge`, `rebase`, `cherryPick`,
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

`git.diff` accepts `root`, `pathspecs`, optional `reference`, `gitReference`,
`targetGitReference`, or `commit`, plus `emptyTreeBase` for a legacy target
reference whose comparison must begin at the repository's object-format-specific empty tree,
`staged`, `untracked`, `contextLines`, and `ignoreAllWhitespace`, and returns `{ "patch": string, "rows": [],
"hunks": [] }`. Rows contain one-based `oldLine`/`newLine` values where
available, `left`/`right` text, a `kind` (`context`, `changed`, `addition`,
`removal`, or `information`), and an optional `hunkID`. For `context` and
`information` rows both sides carry identical text, so `right` is omitted and
clients must fall back to `left`. Hunk entries contain their header and the
patch text needed for partial apply; rows are not duplicated per hunk, so
clients group `rows` by `hunkID` instead.
New reference-tree workflows use `gitReference`; Core validates its full
identity before constructing the diff invocation. When `targetGitReference` is
present, Core validates both complete identities and constructs the two-ref
range. The legacy `reference` field remains available for existing revision and
range comparisons.

`git.comparison` accepts `root` plus the same `reference` or `gitReference` /
`targetGitReference` forms and returns the deterministically ordered changed
files. Platforms must not construct a two-ref range themselves.
`git.apply` accepts `root`, `patch`, and `mode`; supported modes are `stage`,
`unstage`, `discard`, `restoreIndex`, `worktree`, `restoreIndexCheck`, and
`worktreeCheck`. The two `*Check` modes only test whether the reverse patch
already applies, so Shelf restoration can be retried after a partial failure.
It returns the normal Git process result. `restoreIndex` applies a saved
index patch to both the index and worktree; `worktree` applies only to the
worktree. Pathspecs must be workspace-relative and must not contain absolute
paths or `..` components.

`git.history` accepts `root`, an optional full `reference`, and `limit` (the
core clamps it to `1...5000`). It remains the compatibility command that
combines `git.references` with the first `git.historyPage`. New clients use
`git.references` with `{ "root": string }` and request commits separately with
`git.historyPage` using `root`, optional full `reference`, nullable opaque
`cursor`, and `limit`. The first request omits `cursor`; each later request
returns the prior page's `nextCursor`. Core keeps one bounded, backpressured
`git log` stream behind that cursor and clamps the stream to the first 5,000
commits, so later pages continue traversal instead of replaying earlier commits.
A history page returns `commits`, nullable `nextCursor`, and `hasMore`. Clients
call `git.historyCursorClose` with `root` and `cursor` when abandoning an
unfinished stream, and discard and close a late page when its repository,
selected reference, or owning `operationId` is stale. Core also expires idle
cursors and caps the number of live streams. Commit parents are explicit so
clients can render merge topology without re-parsing Git output. The optional
effective `userName` and `userEmail` returned by `git.references` let clients
implement a stable `me` filter without guessing from recent commits. Each
reference includes `peelsToCommit`; hosts use it to disable commit-only
actions for legal tree/blob tags before the user reaches a failing mutation.
Each local
reference with an upstream also returns numeric `ahead` and `behind` counts
against that fetched remote-tracking reference. References without an upstream,
remote references, and tags return zero for both fields. Portable examples are
`shared/fixtures/git/references-response-v1.json` and
`shared/fixtures/git/history-page-response-v1.json`.

For compatibility, a request that explicitly contains the deprecated numeric
`offset` field still uses the bounded offset implementation and returns
`nextOffset`. New clients must omit `offset`; repository size does not select
between the two protocols.

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

The `debug.*` commands are the shared Debug Adapter Protocol boundary. Rust
owns DAP framing, request sequences, response correlation, initialization and
execution state, deterministic breakpoint sets, and normalized thread, stack,
scope, variable, evaluation, output, stop, continue, and termination events.
Platforms own adapter discovery, JDT LS activation, sockets or process pipes,
native process termination, persistence, and UI rendering.

`debug.createSession` accepts `{ sessionId, adapterId, rootPath,
supportsRunInTerminalRequest }`. It does not
open a socket or launch a process. It returns a session update in
`initializing` state with an ordered `outboundFrames` array. Each frame is a
complete Content-Length-framed byte sequence encoded as base64. Every Debug
command returns the same update shape: `{ sessionId, state, outboundFrames,
events }`. The platform writes frames in array order and feeds received chunks
back through `debug.receive` as `{ sessionId, dataBase64 }`; partial and
consecutive messages are buffered and reduced in Rust.

When `supportsRunInTerminalRequest` is true, the initialize frame advertises
the native host's terminal capability. An adapter `runInTerminal` reverse
request becomes a deterministic `runInTerminalRequested` event containing a
Core-generated `requestId`, terminal kind, title, working directory, ordered
argument vector, sorted environment changes, and shell-interpretation flag.
The platform launches the process through its PTY/ConPTY adapter and calls
`debug.runInTerminalResponse` with `{ sessionId, requestId, success, processId?,
shellProcessId?, message? }`. Core validates process identifiers, emits the DAP
response, ignores duplicate or expired completions, and fails pending terminal
requests when the session disconnects. The shared compatibility cases are in
`shared/fixtures/debug/run-in-terminal-v1.json`.

`debug.launch` accepts an `operationId` and a language-neutral configuration
containing `name`, request kind (`launch` or `attach`), provider arguments, and
optional portable `steppingFilters`.
`debug.javaTestLaunch` accepts JDT LS-owned working directory, main class,
project, classpath, module path, VM arguments, program arguments, Java test
framework, and a platform-owned loopback result port. JUnit placeholder ports
are replaced deterministically. TestNG appends the packaged runner once and
uses its selected method names. Core serializes JDT's VM and program argument
arrays into the string fields required by Java Debug Server's DAP launch model.
JDT LS remains responsible for resolving file,
class, and method selections to this metadata; Core does not parse Java source
or infer a test framework in this command. The command creates no process,
socket, timer, or persistent session; compatibility cases live in
`shared/fixtures/debug/java-test-launch-v1.json`.
Launch submitted during initialization is retained until the initialize
response. For Java, Core projects those filters into the adapter's `stepFilters`
launch object unless the provider arguments already contain an explicit value.
`debug.steppingFilters` accepts `{ adapterId, filters? }`; omission of `filters`
returns deterministic adapter defaults, while a supplied value is trimmed,
sorted, de-duplicated, and validated before persistence or launch. Omitted
fields inside a supplied value are empty or false, so future adapters never
inherit Java policy accidentally. Java class
patterns support `$JDK`, `$Libraries`, and adapter-compatible wildcards. Other
adapters default to an unfiltered policy until their integration defines one.
Java defaults include both `$JDK` and `$Libraries`, matching the IDE convention
of collapsing platform and dependency frames while retaining project frames.
The portable cases are in
`shared/fixtures/debug/stepping-filters-v1.json`.

Normalized stack frames include `isFiltered`. Core derives it from the active
class filters using the DAP frame name, source path, presentation hint, and
session root. This classification is presentation metadata only: Core returns
the complete ordered stack, while native UIs may collapse consecutive matching
frames and must allow users to expand them. `debug.setBreakpoints` accepts
one-based line and optional column,
enabled state, condition, hit condition, and log message values. Rust sorts and
de-duplicates the complete source set, retains disabled entries without sending
them to the adapter, waits for the DAP `initialized` event, then sends all
sources in deterministic path order followed by `configurationDone` when the
adapter supports it. This allows native products to mute or restore breakpoints
without maintaining a second protocol representation.

`debug.setExceptionBreakpoints` accepts adapter-defined filter identifiers,
enabled state, and an optional condition. Rust trims, sorts, and de-duplicates
the complete selection, retains disabled filters without sending them, and uses
DAP `filterOptions` only when the adapter negotiated that capability. Before a
native client has configured a selection, Rust adopts the adapter's declared
defaults so the first `initialized` flow sends exception filters before source
breakpoints and `configurationDone`.

`debug.setFunctionBreakpoints` accepts a method or function name, enabled
state, condition, and hit condition. Rust retains the complete sorted set,
omits disabled entries, and sends DAP `setFunctionBreakpoints` before source
breakpoints only when the adapter negotiated function-breakpoint support.

Data breakpoints use DAP's required two-step flow. The native client first calls
`debug.dataBreakpointInfo` with the selected variable name plus its parent
`variablesReference` and current frame. Rust Core correlates the response by
`operationId` and returns the adapter-owned `dataId`, display description,
allowed access modes, and `canPersist`. The client then calls
`debug.setDataBreakpoints`; Core keeps the complete deterministic set, omits
disabled entries, and sends access type, condition, and hit count only when the
adapter negotiated data-breakpoint support. Native clients must discard IDs
whose `canPersist` is false when the debug session ends.

`debug.setVariable` accepts the selected variable's parent `variablesReference`,
name, and replacement text. Core permits mutation only while paused and after
the adapter advertises `supportsSetVariable`, then returns the adapter's
normalized replacement value and optional type through the caller's
`operationId`.

`debug.execute` covers continue, pause, step over, step in, step out, step back,
restart, terminate, and capability-gated single-thread execution. Rust Core rejects stepping unless the session is paused
and a thread is selected, and gates step back, restart, and terminate against
the adapter capabilities negotiated during initialization. Restart and
terminate are session-level requests and never receive a stale `threadId`.
Single-thread pause, continue, and stepping preserve the paused session when
the adapter reports that other threads remain stopped.

`debug.cancelOperation` removes the matching pending request before emitting a
terminal failure, so a late adapter response cannot mutate current UI state. If
the adapter advertises `supportsCancelRequest`, Core also sends DAP `cancel`
with the original request sequence. Native hosts own monotonic deadlines and
invoke this command with `cancelled` or `timedOut`; the macOS reference product
uses a bounded 10-second deadline for interactive inspections and mutations.

Smart step into and run to cursor keep DAP's target lookup explicit. Clients
use `debug.inspect` with `stepInTargets` and a frame, or `gotoTargets` with a
source path and one-based cursor coordinates. Core normalizes the returned
targets and correlates them to the caller's operation. The selected target is
then passed as `targetId` to `debug.execute` using `stepIn` or `goto`; both
flows are rejected unless the adapter advertised the matching capability.

The successful DAP initialize response emits a normalized `capabilities` event.
It includes conditional, hit-count, log, function, data, and exception
breakpoint support; variable mutation; restart and terminate requests; step
back; exception information; request cancellation; single-thread execution;
step-in targets; goto targets; and ordered exception filters. Native UIs
must treat capability state as unknown until this event arrives and hide or
disable unsupported actions after negotiation.

`debug.execute` correlates continue, pause, next, step-in, and step-out to the
caller's `operationId`. `debug.inspect` supports `threads`, `stackTrace`,
`scopes`, `variables`, `evaluate`, and capability-gated `exceptionInfo`;
required thread, frame, variable reference, and expression fields are validated
before a request is emitted. A `variables` inspection may additionally carry
`variableFilter` (`named` or `indexed`), zero-based `start`, and positive
`count`; Core maps them to DAP `filter`, `start`, and `count` and rejects those
fields for every other inspection kind. Normalized scopes, variables,
evaluations, and variable-mutation results include non-negative
`namedVariables` and `indexedVariables` counts, using zero when the adapter
omits or reports an invalid negative value. The compatibility cases are in
`shared/fixtures/debug/variable-paging-v1.json`.

Exception information is available only while
paused and normalizes the exception type, description, break mode, optional
stack trace, evaluation name, and nested exception details. The Java adapter
currently supplies the type, description, and break mode but no expandable
exception object reference, so native clients continue to inspect ordinary
frame scopes for local state.
Terminal operation events are exactly one of `operationCompleted` with a typed
result or `operationFailed` with the adapter command and safe message. Other
ordered events are `stateChanged`, `initialized`, `output`, `stopped`,
`continued`, `terminated`, and `breakpoint`. Source coordinates are one-based.
The compatibility flow is captured in
`shared/fixtures/debug/dap-session-v1.json`; exception normalization cases are
captured in `shared/fixtures/debug/exception-info-v1.json`.

`debug.disconnect` emits the protocol handshake and enters `terminating`.
Core derives DAP `terminateDebuggee` from the session's request kind: `launch`
uses `true`, while `attach` and a session stopped before either request use
`false`. This prevents a remote detach from killing a JVM the IDE does not own.
The compatibility cases are in
`shared/fixtures/debug/disconnect-policy-v1.json`. The platform keeps the
socket or process alive long enough to flush the frame, then closes it and
calls `debug.destroySession`. A session allocates no process, socket, timer, or
background task, and no session exists until Debug is used.

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
directory, initialization options, optional runtime executable,
`jdtlsLaunchResources`, cache directory, and `workspaceFingerprint`, plus
initialize, post-initialize readiness, request, and shutdown deadlines.
Java callers may also provide the versioned `mavenContext` accepted by
`maven.launchPlan`. Core validates its reactor and recursively declared modules,
publishes `settingsPath` through
`java.configuration.maven.userSettings`, and, after `ServiceReady`, sends one
`java.project.updateSettings` command per Maven project with
`org.eclipse.m2e.core.selectedProfiles`. Maven Java, test, and generated source
roots are normalized to workspace-relative `java.project.sourcePaths` during
the same configuration flow, so JDT LS receives the selected reactor's source
model without platform-specific POM parsing. The session becomes `ready` only after
every command succeeds; a command error or timeout terminates the session with
`mavenContextFailed` or `mavenContextTimeout` at the `serviceReady` stage.
`initializeTimeoutMilliseconds` bounds only the standard LSP handshake. For a
provider such as JDT LS that has a later readiness signal,
`serviceReadyIdleTimeoutMilliseconds` bounds time without changed work-done
progress and `serviceReadyAbsoluteTimeoutMilliseconds` is the final safety cap.
The defaults are 45 seconds idle and 10 minutes absolute; duplicate progress
does not refresh the idle deadline. `jdtlsLaunchResources`, when present,
contains `launcherJarPath`, `configurationDirectory`, `lombokAgentPath`, the
legacy optional `javaDebugBundlePath`, and ordered
`javaExtensionBundlePaths`. It is valid only for the Java provider and requires
`runtimeExecutablePath`. Rust loads the legacy Debug bundle first when present,
then appends the extension bundle paths with stable de-duplication. Rust
then uses `runtimeExecutablePath` as the process executable and constructs the
complete deterministic JDT LS JVM argument list. When the structured object is
absent, the selected `executablePath` and legacy wrapper arguments remain the
compatibility path. Rust owns the returned
session's child process, stdin/stdout/stderr, framing buffer, JSON-RPC request
IDs, document versions, pending deadlines, capabilities, diagnostics, and
graceful/forced termination.

JDT LS remains `initializing` until `language/status: ServiceReady`. During this
phase Rust reduces changed `$/progress` notifications into throttled JSON log
details containing the current phase, percentage, project, observed project
count, artifact name, repository host, downloaded/total bytes, calculated
throughput, elapsed/idle durations, and cache disposition. Progress parsing is
observability-only and never substitutes for `ServiceReady`. Idle and absolute
failures use `serviceReadyTimeout` at stage `serviceReady` and retain the final
diagnostic snapshot in `underlyingMessage`.

Platform adapters own filesystem discovery and validate that packaged JDT LS
contains the Equinox launcher, platform configuration directory, Lombok agent,
Java Debug Server, and bundled Java. Java Test-capable hosts additionally
validate their extension bundles and runner. They do not construct JVM commands.
Packaged macOS and Windows plans always use structured direct launch, so runtime
startup has no shell, PowerShell, or user-`PATH` dependency. Wrapper launch
remains optional only for external or older plans.

For JDT LS, platform adapters observe root Maven/Gradle descriptor timestamps
and sizes, names of direct Maven module directories, and the selected JDT LS
version. They submit those raw observations to `java.jdtWorkspaceFingerprint`;
Rust Core validates, sorts, de-duplicates, and constructs the sole portable
fingerprint representation. Core then hashes the normalized workspace identity
followed by a null separator and that opaque fingerprint to select
`cacheDirectory/jdtls/<workspaceKey>`.
Omitting the fingerprint preserves the legacy path-only key for older clients.
Changing structure selects a new directory without deleting the old one, so a
later switch back can reuse it.

`java.jdtWorkspaceFingerprint` accepts
`{ buildFiles, directMavenModules, jdtlsVersion }`. Each build-file observation
contains a workspace-relative `path`, `modifiedUnixMilliseconds`, and
`sizeBytes`. It returns `{ workspaceFingerprint }`; platforms must not recreate
or parse this opaque string. Compatibility cases are in
`shared/fixtures/lsp/jdt-workspace-fingerprint-v1.json`.

`lsp.jdtWorkspaceKey` accepts `{ workspaceRoot, workspaceFingerprint? }` and
returns `{ workspaceKey }` through the same normalization and SHA-256 algorithm
used by `lsp.startServer`. Platform cache-maintenance actions use it to remove
only the current workspace/fingerprint directory; they do not clear sibling
workspaces or older structural states.

`java.workspacePolicy` accepts `workspacePaths` and `changedPaths` as
workspace-relative paths. It starts Java tooling when any non-ignored `.java`
source exists, regardless of Maven or Gradle metadata, chooses one deterministic
representative source, and classifies changes as `ignored`, `source`,
`buildConfiguration`, or `other`. The compatibility examples are in
`shared/fixtures/lsp/java-workspace-policy-v1.json`.

`java.jdtCacheRetention` accepts platform-observed cache directory metadata as
`{ nowUnixSeconds, activeWorkspaceKey?, entries }`. Each entry contains a
lowercase 64-character SHA-256 `workspaceKey` and
`lastModifiedUnixSeconds`. Core ignores invalid candidate names, de-duplicates
observations using the newest timestamp, never selects the active key, and
returns deterministically sorted `expiredWorkspaceKeys` older than the fixed
30-day retention period. Platform adapters own the last-used marker, directory
enumeration, revalidation, deletion, and error logging; Core performs no cache
filesystem I/O. See `shared/fixtures/lsp/jdt-cache-retention-v1.json`.

`lsp.syncDocument` accepts `{ sessionId, uri, languageId, text?, contentChanges? }`.
The first sync emits `didOpen` at version 1. Later syncs emit `didChange` with
increasing versions. When the server advertised incremental `textDocumentSync`
and `contentChanges` includes LSP ranges, the notification carries those
range-based edits and does not require a full document `text` field. Otherwise
the change is a full-text replacement. The response is
`{ documentVersion, changed }`; submitting identical full text returns
`changed: false`, preserves the version, and emits no LSP notification.

`lsp.workspaceFilesChanged` accepts a session ID and ordered file URI changes
whose `kind` is `created`, `changed`, or `deleted`. It emits one
`workspace/didChangeWatchedFiles` notification. Open documents remain owned by
versioned `lsp.syncDocument`; adapters must not duplicate those edits as watcher
events.

`java.navigationMarkers` accepts
`{ sessionId, operationId?, uri, documentVersion? }` and completes with
`{ documentVersion, markers }`. Rust combines JDT LS implementation CodeLens,
`textDocument/implementation`, and `java/findLinks` results with parser-selected
Java declaration candidates. Work is capped at 64 semantic tasks, individual
task failures preserve other verified markers, stale document versions cancel
the batch, and the latest completed version is cached per URI. Markers are
sorted by line, UTF-16 column, and relation. A marker contains `direction`
(`up` or `down`) and `relation` (`interface` or `inheritance`); zero-target
declarations are omitted. The cross-platform examples are in
`shared/fixtures/lsp/java-navigation-v1.json`.

`java.resolveNavigation` accepts the marker position, direction, relation, and
document version. Downward markers use `textDocument/implementation`; upward
markers use JDT LS `java/findLinks` with `superImplementation`. Its terminal
result is `{ documentVersion, locations }`, using the same normalized physical
and virtual-location representation as ordinary navigation.

`lsp.request` accepts a semantic `operation` plus
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
and `hasWrapper`. The root project and every recursive module also contain a
`sourceRoots` list. Each entry has a module-relative `/`-normalized `path` and
a `kind` of `mainJava`, `mainResources`, `testJava`, `testResources`,
`generatedMain`, or `generatedTest`. Standard Maven roots are returned before
their directories exist; explicit `<build>` source/resource directories and
`maven-compiler-plugin` generated-source directories or
`build-helper-maven-plugin` source lists replace the corresponding defaults,
whether configured directly on the plugin or within an execution.
`${project.build.directory}` resolves from `<build><directory>` and defaults to
`target` only when that element is absent; unresolved or invalid explicit
values do not silently fall back.
Absolute, unresolved-property, and parent-traversal paths are omitted so one
module cannot claim another module's source root. Entries are de-duplicated and
ordered by the documented kind order, then path. Aggregator-only `pom` modules
have no default roots. Module paths are relative to the selected Maven root and
use `/` separators. Malformed XML returns `parse_failed`. Source-root examples
are in `shared/fixtures/maven/source-roots-v1.json`.

`maven.launchPlan` accepts a workspace `root`, a versioned `context`, an
optional reactor-relative `module`, and an ordered `goals` array whose first
entry is a lifecycle or custom goal. Later entries may be ordinary Maven CLI
arguments such as `-Dname=value` or `-q`. They remain separate process arguments
and are never interpreted by a shell. Context version 1 contains the
workspace-relative `reactorPath`,
selected `profiles`, optional platform-local `settingsPath`, `skipTests`, and
optional Maven/JDK paths used only for the configuration fingerprint. The
response contains the `project-maven` toolchain reference, an argument array,
the workspace-relative reactor working directory, and a deterministic SHA-256
configuration fingerprint. Profiles are sorted and de-duplicated. Module plans
from `maven.launchPlan` use `-pl <module> -am`; Run and Debug plans use
`-pl <module>` without `-am`. Settings use `-s`; skipped tests use
`-DskipTests`. Explicit Run `cwd`, Profiles, and `extensions.maven.skipTests`
values override the project context, including `skipTests: false`.
The core never reads `settings.xml` and never copies its path into a portable
project document. Maven itself continues to read `.mvn/maven.config`; the plan
does not expand or duplicate that file's arguments. Fixtures are in
`shared/fixtures/maven/launch-plan-v1.json`.

`maven.diagnostics` accepts `{ "root": string, "output": string }` and returns
`{ "issues": [] }`. Diagnostic paths may be absolute or workspace-relative;
the response preserves the path text, uses one-based line and column values,
and normalizes severity to `error` or `warning`. Duplicate issue lines are
removed deterministically.

`java.runConfigurations` accepts `{ "root": string, "paths": string[],
"modulePaths": string[] }`. Java and module paths are workspace-relative. The response
contains detected `mainClasses` and deterministic `configurations`. Each
configuration carries the exact workspace-relative `sourcePath` that produced
it and a `sourceSet` of `main`, `test`, or `other`; consumers must not recover a
source by matching the qualified class name. Process launching remains a
platform adapter responsibility.

The `runConfig.*` commands implement the versioned project protocol described
by the JSON Schemas in this directory. `runConfig.inspect` accepts `root` and
never writes files. `runConfig.generate` accepts `root`, relative Java `paths`,
and relative `modulePaths`; it returns generated configuration and toolchain
requirement documents for the platform adapter to write atomically. Maven root
discovery checks `pom.xml` along each supplied path's ancestor chain, so a
reactor nested below the opened workspace does not depend on the platform
including build descriptors in `paths`. Maven ownership is resolved per Java
entry: standalone sources keep the JDK launch path, while entries from
independent nested reactors retain their own reactor working directory and
module selector. Generated fingerprints include both project inputs and the
detector revision; either changing marks persisted output stale and requires
regeneration.

`runConfig.resolve` accepts `root`, optional local `toolchainCandidates`, and
optional `localDocument`. When `localDocument` is present, Core uses that JSON
object as the local layer instead of reading `.lithe/run/local.json`. It merges
configurations by stable ID using this precedence:
`local.json > configurations.json > generated.json`. Scalars and arrays are
replaced by the higher layer, while toolchain maps merge by key. It returns
effective configurations, their source, the team default, structured
diagnostics for stale, orphaned, missing, disabled, and toolchain mismatch
states, the effective global `toolchain`, and the machine-local
`localToolchains` document. Toolchain diagnostics carry the affected run
configuration ID when a requirement is consumed by one or more configurations;
requirements with no configuration consumer do not emit a blocking diagnostic.
A process detector declares a runtime binding only when that command genuinely
consumes the runtime. npm, pnpm, and Yarn scripts consume `project-node`; Bun
scripts keep their independent `bun` command and do not acquire a Node
requirement. Go, Python, Cargo, and Gradle remain command-based until every host
provides the corresponding configurable runtime registry, so their PATH-based
launch behavior is not blocked by an unavailable platform selector.
During resolution, Core also reconciles npm, pnpm, and Yarn commands from older
v2 generated documents with the same `project-node` binding. This compatibility
normalization is based on the effective command, does not mutate the stored
document, and keeps legacy hybrid projects scoped without requiring regeneration.
A document-level `toolchain`
object in the local layer (e.g.
`{ "java": { "homePath": ... }, "maven": { "executablePath": ..., "javaHomePath": ... } }`)
provides defaults for every configuration's `extensions.java.*`. A non-empty
per-configuration toolchain path overrides the corresponding project default.

`runConfig.updateOptions` and `runConfig.createUserConfiguration` are pure
document transformations. They validate scope, paths, supported types, stable
IDs, main classes, modules, and argument parsing, then return UTF-8 JSON in the
`document` field. The platform adapter selects the target project or local
file and performs the atomic write. These commands never write files. An empty
`workingDirectory` removes the layer's `cwd` override. Optional
`mavenSkipTests` writes `extensions.maven.skipTests`; omission removes the
override so the project Maven context is inherited, while explicit `false`
continues to run tests even when the project default skips them.
For project-scoped option updates, selected toolchain paths must resolve inside
`root` and are persisted with `/`-separated project-relative paths. Local-scoped
updates may carry host absolute paths. `runConfig.updateOptions` and
`runConfig.inspect` accept the same optional `localDocument` override.
When `updateOptions` carries a `toolchain` object (`javaHomePath`,
`mavenExecutablePath`, `mavenJavaHomePath`), it writes the document-level
global toolchain into the local layer instead of patching a configuration;
project scope rejects this payload because toolchain paths are machine-local.

`runConfig.saveEditorChanges` accepts the normal option-edit payload plus the
required `toolchain` object. In addition to Java and Maven paths, that object
may contain `runtimeExecutablePaths`, keyed by stable generic toolchain ID. It
applies the global toolchain and configuration override edits together,
returning `localDocument`, either a `projectDocument` string or `null`, and
either a `toolchainDocument` string or `null`. The latter updates
`.lithe/toolchains/local.json`, preserves unrelated toolchain IDs, and removes
an entry when its supplied executable path is empty. Local scope combines the
run-option edits in the local run document. Project scope returns the local
defaults and team options as separate fully prepared documents; the platform
adapter writes all returned documents as one transaction with rollback. Empty
per-configuration toolchain paths remove the
corresponding override keys while preserving unrelated extension fields.
Platform clients report the editor save as successful only after the written
documents resolve again. Failures identify whether preparation, document
writing, or post-save reload failed; a reload failure keeps the last usable UI
snapshot and states that the documents were already saved.

Automatic runtime discovery produces an effective executable path for the
current session. Platforms use that same path both to construct
`toolchainCandidates` and to resolve the launch command. An automatic path is
not a persisted user selection and is written to `.lithe/toolchains/local.json`
only after an explicit editor save.
On Windows, Node-backed commands resolve their package-manager shim from the
selected Node installation. They do not fall back to a PATH shim from another
installation, and Windows executable extensions take precedence over extensionless
shell scripts.

`runConfig.createLaunchPlan` accepts `root`, `configurationId`, optional
`currentFile` and `classPath`, optional `debugPort`, and optional
`localDocument`. Maven-backed Run and Debug callers may also supply the same
versioned `mavenContext` accepted by `maven.launchPlan`. Explicit profiles in
the resolved Run Configuration replace the context profiles; otherwise the
project profiles are inherited. Explicit `extensions.maven.skipTests` and
`cwd` values also replace the context values. Core applies the shared settings,
module, Skip Tests, and reactor-working-directory rules to the generated
framework or Java-main arguments without adding tool-window-only `-am`. It
returns a toolchain
reference, argument array, project-relative working directory, and structured
environment references. It does not return a shell command or platform
executable path. All project paths use `/`, reject absolute paths and `..`
traversal, and remain relative to `root`. A `java.main` configuration without a
Maven toolchain launches through `project-jdk` and the configuration's Java
source path only when that source has no Maven ancestor. An older configuration
that omitted the Maven binding is rejected with an instruction to regenerate.

`java.codeVision` accepts a workspace root, a target Java path, and Java source
paths. It returns declaration locations and usage counts; Git blame attribution
is joined by the UI from the shared Git result. `java.className` accepts Java
source text and a file simple name and returns the fully qualified runtime class
name.

`java.sourceDefinition` accepts `source`, `declarationName`, and an optional
`memberName`, returning zero-based `line` and UTF-16 `utf16Column` or `null`
when no declaration is found.

`java.structure` accepts Java `source` and optional `declarationSources`. It
returns `foldRegions`, `inlayHints`, and
`syntaxHighlights`. Line numbers are zero-based because these values are editor
offsets; UTF-16 columns and hidden ranges match the native text editor coordinate
system. Syntax highlights contain document-relative `utf16Start`,
`utf16Length`, and a role from the shared editor syntax-theme contract. They
are sorted and non-overlapping, so native renderers can apply semantic colors
without maintaining another Java parser. The parser is platform-independent
and does not start a Java process or contact JDT.

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
