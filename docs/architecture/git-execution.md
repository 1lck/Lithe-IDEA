# Git execution visibility

Issue: [#438](https://github.com/1lck/Lithe-IDEA/issues/438).

User-initiated Git operations report their actual command, working directory,
live output/progress, exit status, and duration through one request-scoped
execution channel. Fetch also has shared structured options, an optional
command preview, and persistent application defaults. Normal Fetch remains a
single action. The console is an in-memory diagnostic history.

## IntelliJ IDEA design baseline

The upstream comparison was reviewed on 2026-09-12. Source references are
pinned to IntelliJ Community revision
[`ef47a30d69be`](https://github.com/JetBrains/intellij-community/commit/ef47a30d69bea05b46a4d64c127ad0f97dd67434).
The comparison guides implementation; platform-specific authentication and
advanced result aggregation remain distinct from the shipped diagnostic channel.

| Concern | IDEA implementation | Consequence for Lithe |
| --- | --- | --- |
| Actual command visibility | [`GitImplBase`][idea-execution] attaches one console listener to the process. Start, output, and termination callbacks go to [`GitCommandOutputPrinter`][idea-printer]; the console implementation includes the working directory and command. | Generate records at the execution boundary for every user operation. Keep a planned command distinct from a started process. |
| Output and progress | [`GitLineHandler`][idea-lines] delivers stdout/stderr incrementally; [`BufferingTextSplitter`][idea-splitter] recognizes LF, CRLF, and CR across buffer boundaries. The result collector excludes recognized progress from error output. | Replace completion-only capture with incremental events. A progress line on stderr is not itself a failure. Preserve incomplete chunks correctly. |
| Policy composition | [`GitHandler`][idea-handler] adds temporary `core.quotepath=false` and `log.showSignature=false`, then requested configuration. [`GitImpl.fetch`][idea-fetch-command] adds Fetch arguments with Git-version checks. | Centralize output/parser invariants, while operation-specific policy chooses Fetch/Pull/Push arguments. A single arbitrary argument string is not the configuration model. |
| Persistent settings | [`GitVcsApplicationSettings`][idea-application-settings] owns application settings; [`GitVcsSettings`][idea-project-settings] uses workspace persistence. [`GitFetchSpec`][idea-fetch-spec] obtains the project tag policy and supplies invocation-specific repository, remote, refspec, and authentication mode. | Separate application settings, project/repository preferences, and options for one operation. Saving a Lithe preference must not implicitly edit Git configuration. |
| Authentication | [`GitHandlerAuthenticationManager`][idea-auth] installs HTTP/SSH AskPass integration. Resetting `credential.helper` depends on the helper preference, authentication mode, and Git capability; the execution layer supports authentication retries. | Preserve existing authentication until a native adapter implements the complete replacement path. Copying only `-c credential.helper=` would break that contract. |
| Scope and results | [`GitFetchSupportImpl`][idea-fetch-support] resolves default/all/selected remotes, coordinates per-remote Fetch tasks, and aggregates failures and pruned references by repository. | One user action may contain several Git invocations. Present the action's scope and partial outcomes alongside actual command details. |
| Cancellation and concurrency | [`GitTextHandler`][idea-text] checks cancellation, requests termination, waits for a bounded interval, then attempts stronger termination. [`GitRemoteOperationQueueImpl`][idea-remote-queue] serializes operations for a repository/remote pair. | Give native process adapters bounded cancellation and cleanup. Preserve Lithe's existing shared-repository/worktree write lease while evaluating any finer concurrency. |

IDEA's [Console documentation][idea-console-help] describes commands generated
from UI settings and their results. Its [Git settings][idea-settings-help]
expose named choices such as update method, credential helper, and tag policy.
This supports using a normal Git action, a shared console, and centralized
settings as Lithe's main interaction model. The optional Fetch preview remains
useful for inspecting choices, but is not the center of the execution layer.

The comparison also identifies limits that should not be attributed to IDEA:
the inspected console printer's termination callback does not render an exit
code, and the Fetch progress listener explicitly leaves aggregate percentage
analysis across multiple remotes as future work. Lithe's explicit exit status
and operation duration are deliberate additions. A durable operation history
would also need a separate product and retention contract.

## Implemented execution boundary

`lithe_core_execute_json_with_events` is an additive synchronous C ABI entry
point. The existing JSON response and string ownership remain compatible.
Rust hosts use `execute_json_with_events`. Every observer belongs to one call,
receives ordered callbacks, and is released before that call returns. Existing
callers without an observer continue to receive the normal final response.
The shared sample is `shared/fixtures/git/execution-events-v1.json`.

Events distinguish request registration, actual process start, output, process
completion, and request completion. Each request has an operation ID, and each
invocation has a sequence number within that request. A request may fail before
any child starts or after earlier subprocesses have completed. The final event
travels over the same ordered channel, including validation failures.

Git argument policy, decoding, redaction, and event shaping remain in Rust Core.
The extracted `rust/lithe-git-host` crate owns native process/pipes/input-file
lifecycle. Core calls this adapter through the existing compatibility boundary;
other legacy Git inspection helpers have not all been migrated. Views and
workflow services do not create native processes.

The adapter drains stdout and stderr independently without blocking a writer
on unread stdin. Input uses a private, owned temporary file. macOS uses a new
process group, termination with a short grace period, then forced group cleanup
if needed. The Windows implementation assigns the initially suspended process
to a job before resuming it, so helpers belong to the same cleanup boundary.
Windows runtime behavior is not locally verified; the user requested CI-based
verification instead. Cleanup and pipe-drain waits have two-second deadlines.
A cleanup failure is reported rather than presented as a normal cancellation.

Output is decoded across byte boundaries, including UTF-8 and CR/CRLF progress.
Credentials are redacted only after a complete line is available. Lines above
16 KiB are omitted in full. Per invocation, native diagnostics are limited to
512 KiB of input and 4,096 output events, with an explicit omission record;
completion events are retained. Raw parser capture has a separate 32 MiB limit
per stream and fails explicitly on overflow instead of parsing truncated data.

macOS copies the operation context only into mutation workers; ordinary
background reads do not inherit the console observer. Windows observes typed
mutations at its existing central dispatcher. Both interfaces publish output
in 100 ms batches and bound retained records to 200 and roughly 1 MiB of text.
Progress on stderr is displayed separately from errors. Clearing a console
suppresses later events from the cleared operation, and repository generations
prevent macOS events from appearing in a newly selected repository. Windows
records are filtered by repository. Cancellation retains output already shown.

## Defaults and scope

Application Git settings persist prune, submodule, and tag preferences. Normal
Fetch reads these defaults; the macOS Fetch options sheet starts from the same
values and applies its choices once. A selected remote is never persisted as an
application default. Saving preferences does not write `.git/config`, global
Git configuration, or credential storage.

The all-remotes case still runs `fetch --all`; IDEA's per-remote task/result
aggregation is a future refinement. Lithe preserves its previous inherited
submodule behavior, while IDEA's Fetch explicitly disables recursion. The new
tag policy supports inherited behavior, all tags, no tags, and synchronizing
with pruning. Synchronizing tags is labeled with its effect on local tags and
requires pruning; invalid combinations are rejected by shared policy.

[idea-handler]: https://github.com/JetBrains/intellij-community/blob/ef47a30d69bea05b46a4d64c127ad0f97dd67434/plugins/git4idea/backend/src/commands/GitHandler.java
[idea-execution]: https://github.com/JetBrains/intellij-community/blob/ef47a30d69bea05b46a4d64c127ad0f97dd67434/plugins/git4idea/backend/src/commands/GitImplBase.java
[idea-printer]: https://github.com/JetBrains/intellij-community/blob/ef47a30d69bea05b46a4d64c127ad0f97dd67434/plugins/git4idea/backend/src/commands/GitCommandOutputPrinter.kt
[idea-lines]: https://github.com/JetBrains/intellij-community/blob/ef47a30d69bea05b46a4d64c127ad0f97dd67434/plugins/git4idea/backend/src/commands/GitLineHandler.java
[idea-splitter]: https://github.com/JetBrains/intellij-community/blob/ef47a30d69bea05b46a4d64c127ad0f97dd67434/plugins/git4idea/backend/src/commands/BufferingTextSplitter.java
[idea-fetch-command]: https://github.com/JetBrains/intellij-community/blob/ef47a30d69bea05b46a4d64c127ad0f97dd67434/plugins/git4idea/backend/src/commands/GitImpl.java
[idea-auth]: https://github.com/JetBrains/intellij-community/blob/ef47a30d69bea05b46a4d64c127ad0f97dd67434/plugins/git4idea/backend/src/commands/GitHandlerAuthenticationManager.java
[idea-text]: https://github.com/JetBrains/intellij-community/blob/ef47a30d69bea05b46a4d64c127ad0f97dd67434/plugins/git4idea/backend/src/commands/GitTextHandler.java
[idea-fetch-support]: https://github.com/JetBrains/intellij-community/blob/ef47a30d69bea05b46a4d64c127ad0f97dd67434/plugins/git4idea/backend/src/fetch/GitFetchSupportImpl.kt
[idea-fetch-spec]: https://github.com/JetBrains/intellij-community/blob/ef47a30d69bea05b46a4d64c127ad0f97dd67434/plugins/git4idea/backend/src/fetch/GitFetchSpec.kt
[idea-remote-queue]: https://github.com/JetBrains/intellij-community/blob/ef47a30d69bea05b46a4d64c127ad0f97dd67434/plugins/git4idea/backend/src/fetch/GitRemoteOperationQueueImpl.kt
[idea-fetch-tags]: https://github.com/JetBrains/intellij-community/blob/ef47a30d69bea05b46a4d64c127ad0f97dd67434/plugins/git4idea/shared/src/git4idea/fetch/GitFetchTagsMode.kt
[idea-application-settings]: https://github.com/JetBrains/intellij-community/blob/ef47a30d69bea05b46a4d64c127ad0f97dd67434/plugins/git4idea/backend/src/config/GitVcsApplicationSettings.java
[idea-project-settings]: https://github.com/JetBrains/intellij-community/blob/ef47a30d69bea05b46a4d64c127ad0f97dd67434/plugins/git4idea/shared/src/git4idea/config/GitVcsSettings.java
[idea-console-help]: https://www.jetbrains.com/help/idea/version-control-tool-window-console-tab.html
[idea-settings-help]: https://www.jetbrains.com/help/idea/settings-version-control-git.html

## Shared Fetch policy

`git.fetchPlan` is a pure command. It accepts `{ options?: GitFetchOptions }`
and returns `{ options, arguments }`. It never discovers a repository, starts
Git, reads credentials, or writes configuration. Preview is a plan, not proof
of process startup or a snapshot of the remote repository.

`git.write` with `operation: "fetch"` accepts optional `fetchOptions`:

| Field | Meaning | Default |
| --- | --- | --- |
| `remote` | Configured remote name; null means all remotes | null |
| `prune` | Prune stale remote-tracking references; false sends `--no-prune` | true |
| `submodules` | `inherit`, `no`, `onDemand`, or `yes` | `inherit` |
| `tags` | `inherit`, `all`, `none`, or `prune` | `inherit` |

Preview and execution call the same Rust argument builder. Fetch gets
`--no-pager`, temporary `color.ui=false` and `core.quotepath=false`, and
`--progress`. The chosen remote is checked against repository configuration
at execution time. A URL or arbitrary argument string is not a remote name.
Fetch options on other mutations and unknown option fields are rejected.

Legacy `git.write`/Windows `git_fetch` callers retain all-remotes/prune and
inherited submodule behavior. Their returned arguments additionally expose the
temporary presentation settings and progress flag. Authentication, proxy,
signing, hooks, and Git configuration files are not overridden by this policy.
The shared fixture is `shared/fixtures/git/fetch-plan-v1.json`.

## macOS presentation

The Git toolbar and action menu expose **Fetch Options…**. The sheet applies
choices to one invocation and previews Rust's command, with credential-safe
formatting. Plain Fetch uses the established defaults. A repository switch
closes the options sheet. The sheet's preview is not a mandatory confirmation
step for ordinary Fetch.

The console distinguishes a pending planned command, a running process,
a completed invocation, and unconfirmed completion. If the bridge returns no
invocation trace, the UI does not assert that the planned command ran or that Git never started. The
actual Git exit code remains distinct from an operation-level failure.
Successful stderr output is displayed neutrally because progress is normal
stderr output. Copying a record includes its status and duration.

Live events and final results are bound to the repository generation. Clearing the console
removes the pending record, and a late response cannot recreate it. Duration
uses a monotonic clock; timestamps are only presentation metadata.

## Remaining product extensions

Authentication uses the user's existing Git helper, SSH, proxy, and signing
configuration. Lithe does not install its own AskPass GUI or clear credential
helpers. Native credential dialogs, executable selection, configuration-origin
inspection, repository-specific preference overrides, per-remote Fetch result
aggregation, and durable history are not implemented by this change. These
should extend the existing structured contract, with explicit ownership and
scope, rather than expose arbitrary global Git argument text.

## Validation

On 2026-09-12, shared Rust and focused macOS Git/settings/localization tests
passed through the timing harness: 483 Rust Core tests and 138 focused macOS
tests. The native Git adapter passed three cases and also has its own
integration cases using only the test executable, with output-driven
cancellation and bounded cleanup. Current reports are
`.artifacts/test-stability/issue438-{rust-events,macos-events,git-host}.{html,junit.xml,json}`.

Commands used:

```sh
./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh
node .agents/skills/write-stable-tests/scripts/run-rust-tests-with-timing.mjs --manifest rust/Cargo.toml --package lithe-core --report .artifacts/test-stability/issue438-rust-events.json --keep-going
node .agents/skills/write-stable-tests/scripts/run-rust-tests-with-timing.mjs --manifest rust/Cargo.toml --package lithe-git-host --report .artifacts/test-stability/issue438-git-host.json --keep-going
./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh --suite-timeout-seconds 1200 --report .artifacts/test-stability/issue438-macos-events.json -- --filter 'GitModuleTests|GitExecutionTests|AppLocalizationTests|AppSettingsTests'
./scripts/verify-rust-core.sh
./scripts/build-macos.sh
./scripts/verify-core.sh
./scripts/verify-service-boundaries.sh
./scripts/verify-shared-contracts.sh
git diff --check
```

A bounded local Git integration experiment also confirmed preview/execution
argument equality, selected-remote isolation (including punctuation in its
name), prune/no-prune behavior against inherited configuration, unchanged
config files, legacy all-remotes scope, rejection of an unconfigured remote,
and retained exit code/stderr on failure. Its report is
`.artifacts/issue438/fetch-integration.json`; all temporary repositories and
child processes were cleaned up.

A separate bounded C ABI experiment verified live callback ordering, retained
failure exit status, credential redaction, and cancellation of Git plus its
helper process. Results are `.artifacts/issue438/events-integration.json`.
Windows verification was stopped at the user's request before any guest build
or test run. The task-created guest checkout and shared transfer files were
removed, and the VM was returned to its previous stopped state.

This host has Swift 6.3.3 rather than the required Swift 6.2. These results do
not establish Swift 6.2 or native Windows compatibility. The new macOS sheet
was compiled; interactive UI verification has not been performed.
