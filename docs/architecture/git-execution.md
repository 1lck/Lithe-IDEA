# Git execution layer

Issue: [#438](https://github.com/1lck/Lithe-IDEA/issues/438).

User-initiated Git operations report their actual command, working directory,
live output/progress, exit status, and duration through one request-scoped
execution channel. The same layer supplies temporary policy, executable selection, HTTP/SSH
authentication, configuration provenance and explicit scoped persistence. Fetch
has structured options, per-remote command previews and partial outcomes. Normal Fetch remains a
single action. The console is an in-memory diagnostic history.

## IntelliJ IDEA design baseline

The upstream comparison was reviewed on 2026-09-12. Source references are
pinned to IntelliJ Community revision
[`ef47a30d69be`](https://github.com/JetBrains/intellij-community/commit/ef47a30d69bea05b46a4d64c127ad0f97dd67434).
The comparison guides the execution, authentication, settings and result model.

| Concern | IDEA implementation | Consequence for Lithe |
| --- | --- | --- |
| Actual command visibility | [`GitImplBase`][idea-execution] attaches one console listener to the process. Start, output, and termination callbacks go to [`GitCommandOutputPrinter`][idea-printer]; the console implementation includes the working directory and command. | Generate records at the execution boundary for every user operation. Keep a planned command distinct from a started process. |
| Output and progress | [`GitLineHandler`][idea-lines] delivers stdout/stderr incrementally; [`BufferingTextSplitter`][idea-splitter] recognizes LF, CRLF, and CR across buffer boundaries. The result collector excludes recognized progress from error output. | Replace completion-only capture with incremental events. A progress line on stderr is not itself a failure. Preserve incomplete chunks correctly. |
| Policy composition | [`GitHandler`][idea-handler] adds temporary `core.quotepath=false` and `log.showSignature=false`, then requested configuration. [`GitImpl.fetch`][idea-fetch-command] adds Fetch arguments with Git-version checks. | Centralize output/parser invariants, while operation-specific policy chooses Fetch/Pull/Push arguments. A single arbitrary argument string is not the configuration model. |
| Persistent settings | [`GitVcsApplicationSettings`][idea-application-settings] owns application settings; [`GitVcsSettings`][idea-project-settings] uses workspace persistence. [`GitFetchSpec`][idea-fetch-spec] obtains the project tag policy and supplies invocation-specific repository, remote, refspec, and authentication mode. | Separate application settings, project/repository preferences, and options for one operation. Saving a Lithe preference must not implicitly edit Git configuration. |
| Authentication | [`GitHandlerAuthenticationManager`][idea-auth] installs HTTP/SSH AskPass integration. Resetting `credential.helper` depends on the helper preference, authentication mode, and Git capability; the execution layer supports authentication retries. | Keep helpers enabled by default. Install an owned AskPass session, support explicit retry, and reset the helper only when the user selects that behavior. |
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

## Policy, capabilities and configuration

Every captured Git invocation resolves the executable selected in application
settings, or Git on PATH. A bounded version probe requires Git 2.31 or newer for
`GIT_CONFIG_COUNT` and scope provenance. Its result is cached by path, size and
modification time, so replacing the executable invalidates it. Temporary policy
sets `color.ui=false`, `core.quotepath=false`, `log.showSignature=false`, `LC_ALL=C`,
`GIT_PAGER=cat`, and `GIT_TERMINAL_PROMPT=0`. Config commands are exempt from these
presentation overrides so inspection shows the user's actual sources. Existing
`GIT_CONFIG_COUNT` entries are preserved, with invalid/unbounded counts rejected.
Transfer commands request `--progress` unless the invocation explicitly selected
progress behavior. None of these defaults edits a config file.

The settings UI shows the resolved executable/version, temporary policy, effective
Fetch choices, and each relevant Git value's scope and origin. Git's include and
includeIf resolution is retained. Later scalar values override earlier values;
credential helpers form a chain, and an empty helper resets that chain. Unrelated
configuration and credential values are not dumped into diagnostics. Custom helper
scripts and SSH commands are represented by placeholders to avoid exposing
secrets embedded in script text.

Fetch precedence is explicit one-time options, repository `lithe.fetch.*` values,
then persistent application defaults. The remote target is never saved as an app
default. Repository overrides use `lithe.fetch.prune`, `lithe.fetch.submodules`,
and `lithe.fetch.tags`. Selecting `inherit` for tags or submodules emits no override,
leaving Git's system/global/local/remote configuration effective.

Only an explicit Save/Clear in the selected scope invokes `git config --local`
or `--global`. The editor permits named boolean/enumerated Fetch, Pull, Push and
credential path settings; it never accepts arbitrary arguments or helper scripts.
A save checks values observed in the selected file, acquires Lithe's repository
write lease, and executes one Git config transaction. A detected intervening edit
requires reload. This is an optimistic precheck, not an atomic compare-and-swap
against external Git writers. Clearing removes that file's override and reveals
inherited values; it does not erase included files or other scopes.

## Authentication ownership

Helpers remain enabled by default, so existing OS credential storage can answer
first. Interactive user operations install an ephemeral AskPass session owned by
the native process adapter. Both `GIT_ASKPASS` and `SSH_ASKPASS` point to the signed
application executable as a path, including spaces. A child-only mode marker
routes it to the early authentication entry before SwiftUI/Tauri initialization;
no second application window or single-instance forwarding is involved.

The helper exchanges one bounded frame over a random-token-authenticated loopback
socket. Only the prompt and an opaque request ID enter the event stream. The
answer returns through `git.authRespond`; it is neither recorded in the console
nor persisted by Lithe. Git's configured helper owns any credential persistence.
Each session has at most four peers, a 16 KiB frame limit, 8 KiB answer limit,
three prompts per identical challenge, and 16 distinct challenge texts. Initial
connections have ten seconds and answers have three minutes. Cancellation or
process completion closes the listener and removes pending replies.

A recognized authentication failure can request an explicit retry after the
failed child has been reaped. The retry bypasses the helper for that operation
only; it requires a user decision and is limited to three total attempts. Each
attempt retains its own actual command, output and exit status. Interactive
execution without an event receiver fails immediately rather than waiting for
an invisible prompt. Background readers do not install interactive sessions.

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

`git.fetchPlan` accepts `{ options?: GitFetchOptions, root?: string }`. Without
`root` it remains a pure legacy argument preview. With `root`, it resolves enabled
configured remotes and returns `commands`, a list of exact per-remote argument
vectors; no transfer or write occurs. A preview can become stale if an external
process changes remotes before execution. Actual start events remain authoritative.

`git.write` with `operation: "fetch"` accepts optional `fetchOptions`:

| Field | Meaning | Default |
| --- | --- | --- |
| `remote` | Configured remote name; null means all enabled remotes | null |
| `prune` | Prune stale remote-tracking references; false sends `--no-prune` | true |
| `submodules` | `inherit`, `no`, `onDemand`, or `yes` | `inherit` |
| `tags` | `inherit`, `all`, `none`, or `prune` | `inherit` |

Both applications opt into `detailedFetch`. Preview and execution share the remote
resolver and argument builder, respect `remote.<name>.skipFetchAll`, and run
selected remotes in sorted order. A failed remote does not erase another remote's
success. Each result contains updated/deleted reference names and total counts;
the lists contain at most 50 names each with explicit truncation. Failed reference
inspection is identified, rather than reported as zero changes. Legacy callers
without the opt-in retain their single `fetch --all` invocation.

Progress parsing identifies enumerating, counting, compressing, receiving,
resolving, writing and updating stages, with available percentages and counts.
The UI does not invent a combined percentage across unrelated remotes.

## Native presentation

macOS exposes **Fetch Options…** in the Git toolbar/action menu; Windows exposes
it in the Git tool window. The sheet applies
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

## Retention and validation

The console intentionally retains an in-memory, bounded operation history. The
issue does not define durable history storage or retention. Configuration and
application defaults persist; authentication answers and console output do not.

Shared fixtures cover arguments, event ordering, execution policy, progress,
authentication challenges and per-remote outcomes. Regression tests use the Rust
and macOS timing harnesses. `scripts/test-git-execution.py` additionally exercises
the C ABI against isolated repositories and a local HTTP authentication server:
configuration scope/precedence/stale saves, per-remote previews/partial successes,
pruned references, HTTP credentials/retry/cancellation, and SSH AskPass paths
containing spaces. The built macOS app is also checked in both early AskPass modes. Every helper
and server has bounded cleanup. The macOS Rust Core CI lane runs these cases and
retains the timing report. The script requires a
built Core dynamic library, Git and the macOS C compiler.

Relevant commands:

```sh
./.agents/skills/write-stable-tests/scripts/verify-test-stability.sh
node .agents/skills/write-stable-tests/scripts/run-rust-tests-with-timing.mjs --manifest rust/Cargo.toml --package lithe-core --report .artifacts/test-stability/issue438-rust-complete.json --keep-going
node .agents/skills/write-stable-tests/scripts/run-rust-tests-with-timing.mjs --manifest rust/Cargo.toml --package lithe-git-host --report .artifacts/test-stability/issue438-host-complete.json --keep-going
./.agents/skills/write-stable-tests/scripts/test-stability-macos.sh --suite-timeout-seconds 1200 --report .artifacts/test-stability/issue438-macos-complete.json -- --filter 'GitModuleTests|GitExecutionTests|AppLocalizationTests|AppSettingsTests'
cargo build --manifest-path rust/Cargo.toml -p lithe-core
python3 scripts/test-git-execution.py --application .build/debug/Lithe
./scripts/verify-rust-core.sh
./scripts/build-macos.sh
./scripts/verify-core.sh
./scripts/verify-service-boundaries.sh
./scripts/verify-shared-contracts.sh
git diff --check
```

Windows validation is delegated to CI at the user's request. macOS local tooling
is Swift 6.3.3; the project's reference toolchain remains Swift 6.2.
