# Native interactive rebase sessions

Rust Core owns range validation, the reviewed snapshot, safe todo/message
preparation, recovery references, and Git sequencer execution. Native products
own plan editing, progress, conflict presentation, and explicit user controls.
The shared example is `shared/fixtures/git/rebase-session-v1.json`.

## Preview and plan

`git.rebasePreview` accepts `{ "root": string, "revision": string }`. The
revision is the **unchanged, excluded base** selected by “Rebase from Here”.
Core resolves the first-parent commits strictly after that base through HEAD,
independently of the platform's loaded log page. The base may be a root commit
or already published. At most 1000 affected commits are supported; affected
history must be linear, local, UTF-8, and unsigned. HEAD must be on a local
branch, with no active Git operation, conflicts, staged/unstaged/untracked
changes, or hidden assume-unchanged/skip-worktree index entries. Git 2.38 or
newer is required.

The response is `{ allowed, blockers, branch, head, base, commits,
expectedState }`. `blockers` use `{ code, message }`; nullable `branch`, `head`,
and `base` contain full identities. `commits` are oldest first with complete
`{ hash, parents, message }`. Only an allowed preview has `expectedState`, using
the existing history expectation shape with `operation: "interactiveRebase"`.
Its `revisions` internally identify the first affected commit. Clients return
the expectation unchanged; they must not reinterpret it as the excluded base.
Remote eligibility uses fetched remote-tracking refs and does not query a server.

`git.rebaseStart` accepts `{ root, expectedState, steps }`. Each step has
`{ hash, action, message? }`; the complete preview range must appear exactly
once, in the desired replay order. The allowed actions are `pick`, `reword`,
`edit`, `squash`, `fixup`, and `drop`. Reword requires a nonempty complete
replacement message. Squash optionally accepts a complete combined message;
otherwise Core joins the preceding surviving message and this commit's full
message. Fixup preserves that combined message, including earlier reword and
squash edits. The other actions reject `message`. Squash/fixup require an
earlier surviving commit. Core never accepts arbitrary exec or todo text.
Prepared message files have an aggregate 8 MiB limit.

## Durable session and controls

`git.rebaseSession` accepts `{ root }` and returns the last owned session or
`null`. A session contains:

| Field | Meaning |
| --- | --- |
| `sessionId` | Opaque identifier required by controls |
| `status` | `starting`, `conflict`, `edit`, `paused`, `completed`, `aborted`, `failed`, or `interrupted` |
| `branch`, `originalHead` | Full original branch and pre-rebase commit |
| `head` | Nullable currently observed HEAD |
| `recoveryReference` | Durable original-history ref in the existing bounded recovery namespace |
| `steps` | The complete accepted plan |
| `completedSteps` | Native done entries; its last entry may still be paused/conflicted |
| `currentCommit` | Nullable current original commit from native done metadata |
| `currentMessage` | Complete current HEAD message at an edit pause; otherwise null |
| `conflictedPaths` | Current native conflict paths |
| `canContinue`, `canSkip`, `canAbort` | Controls verified against matching native session state |

`git.rebaseControl` accepts `{ root, sessionId, action, amendMessage?, expectedHead? }`, where
action is `continue`, `skip`, or `abort`. Only an edit pause accepts
`amendMessage`, and only together with continue. This is an explicit amendment
of HEAD using all currently staged content and the complete supplied message,
followed by native continuation. Amend requests must include the `expectedHead`
shown by the editor; Core rejects missing or changed HEAD before amending.
Clients reload untouched drafts when HEAD changes and preserve edited drafts
with a stale warning until the user explicitly reloads. A plain continue preserves the user's current
commit, including amendments already made outside the dialog. Plain
continuation with staged changes at an edit pause requires an explicit
amendment first; Core prevents Git from silently consuming them. At either kind
of edit continuation, Core rereads the actual HEAD message and regenerates
following squash/fixup message files up to the next pick/reword/edit. An explicit
later squash message continues to take precedence.
Skip is available only for a conflicted step. A successful edit pause has
already created its commit, so native Skip would not omit that commit.
Skipping also refreshes later default squash/fixup messages from the actual
surviving HEAD, excluding the skipped commit's message.

Start and control return `{ command: GitCommandResponse, session }` after Git
execution, including conflicts, process interruption, and partial outcomes.
Pre-execution invalid/stale/unsupported requests use the standard error envelope.
`command.historyRewrite` is absent: session carries the native rebase outcome.
An edit pause often has exit code zero; clients must use session status instead
of treating that exit status as completion. Warnings preserve recovery/session
identity when a follow-up persistence or inspection fails. An unknown final
state is `interrupted`, with controls disabled until a refreshed query can
verify it. Request cancellation terminates the process; it does not invoke
Abort. A transport failure must be followed by session inspection before retry.

Existing `git.write` operationContinue/operationSkip/operationAbort controls
recognize an owned session and restore its editor environment, preserving
compatibility with the existing operation banner. External Git operations use
their existing generic control path.

## Execution and recovery invariants

Core acquires the existing repository common-directory write lease, rechecks the
reviewed HEAD/branch/refs/index/working-file snapshot, and persists a recovery
ref plus session manifest and message files before starting rebase. The
manifest lives under this worktree's Git directory, so linked worktrees have
distinct session identity. Core fixes the exact base with `--onto`, disables
autostash, update-refs, autosquash, fork-point, and rebase-merges, reapplies
cherry-picks, and preserves both originally empty and newly empty commits.
An explicit edit amendment also permits an empty commit. Hooks and signing
configuration retain native Git behavior; failure leaves native recovery state.

Git's editor protocol uses fixed shell templates supported by POSIX Git and
Git for Windows. Paths and reviewed identities travel in environment variables;
messages travel only in UTF-8 files. Windows paths passed to the shell use `/`.
No caller-supplied message, subject, path, or arbitrary command is interpolated
into shell program text. The sequence editor verifies Git's just-created
orig-head, head-name, and onto against the reviewed identities before installing
the plan. This closes the gap between the final Core snapshot and Git capturing
its starting state. The editor then writes an owned-session marker inside
`rebase-merge`; controls require that marker and all three native identities to
match. A previous Lithe session cannot adopt an unrelated external rebase.

Native done/todo entries must still match the accepted action/full-OID sequence
before continue or skip. If another tool edits the todo, Core disables those
controls and permits explicit abort of the matching session. Original history
remains reachable through the recovery ref and its attributable reflog. The
latest session files remain available across application restart and are
replaced only when another reviewed session starts in that checkout.

An `interrupted` record with no available controls is diagnostic history, not
proof of an active native operation. When a user requests a new plan, clients
may obtain a fresh Core preview; Core still rejects any actual active operation.
Keep the previous recovery reference available when showing its diagnostic
record, without forcing new plan requests back into that record.

The persisted session JSON is bounded to 9 MiB, independently of the 8 MiB
raw plan-message limit. Core validates encoded size (including JSON escaping
and space for later status changes) before replacing the stored session or
starting the native sequencer. Oversized plans return `invalid_request` and
require shorter messages; the current branch, index and worktree stay intact.
