# Git Patch Exchange

The `git.patchExport`, `git.patchPreview`, and `git.patchApply` commands provide
the same external patch semantics to both products. Native file selection,
strict UTF-8 decoding/encoding, atomic file saves, and window presentation stay
in platform adapters. The representative wire shapes are in
[`patch-exchange-v1.json`](../fixtures/git/patch-exchange-v1.json).

## Export

`git.patchExport` accepts `root`, `source`, optional `paths` (empty means all
working files), and optional `baseRevision` / `targetRevision`. Paths are literal,
repository-relative identities. Sources are:

- `workingTree`: the final selected files relative to HEAD, including selected
  untracked files. Core prepares an isolated index; the real index and working
  files are unchanged. Same-path staged and unstaged changes become one net diff.
- `staged`: the current index relative to HEAD.
- `unstaged`: tracked working files relative to the current index.
- `commits`: the resolved `baseRevision` tree to the resolved `targetRevision`
  tree. Both revisions are required; they need not be adjacent or on one branch.

For file selection, pass `metadataOnly: true` to enumerate the same source's
sorted counts and rename paths using Git's NUL-delimited statistics. The result
has `patch: ""` and `byteLength: 0`; its files remain available even if an actual
export would exceed 32 MiB or contain non-UTF-8 text. Hosts discover files first,
then request patch contents only for the selected paths. Export failures must
leave the selection editable. Omission or false preserves normal export behavior.

The response contains exact `patch` text, sorted `files`, and UTF-8 `byteLength`.
Each file has `path`, nullable `originalPath`, and nullable `additions` /
`deletions` (null for binary line counts). An empty export returns an empty patch
and file list. The host explains that there are no changes instead of silently
saving an empty patch.

Core pins binary encoding, disables external diff/textconv/color, and emits
standard `a/` and `b/` prefixes independently of the user's display settings.
Binary files use Git binary patch encoding. Plain-text patches containing
non-UTF-8 bytes are explicitly rejected: hosts must never replace invalid bytes
with Unicode replacement characters. The maximum exchanged patch is 32 MiB.

## Preview and Apply

`git.patchPreview` accepts `root`, `patch`, and `target` (`worktree` or
`indexAndWorktree`). It reads Git's file summary and runs a **forward** `git apply
--check`, returning `applicable`, sorted `files`, `diagnostic`, UTF-8 `byteLength`,
and nullable `expectedState`. No files are modified. Malformed or unsafe paths,
empty patches, and active merge/rebase/cherry-pick/revert operations are rejected.
An applicability failure returns `applicable: false` and no execution token.

`git.patchApply` accepts those same inputs plus the exact `expectedState` from
the preview. Core binds the token to patch content, destination mode, repository,
HEAD/branch, raw index bytes (including entry flags), and working-file content.
The exact patch destinations are read even when `assume-unchanged`,
`skip-worktree`, or ignore rules hide changes from Git's normal diff. Paths may
not traverse symbolic-link directories; unsupported directory/gitlink targets
are reported rather than silently omitted. Changes since preview require a
new preview. The final Git invocation checks applicability again and does not use
`--reject`, automatic whitespace repair, `--3way`, or `--unsafe-paths`.

The command returns the existing `GitCommandResponse`, retaining forward-check
and apply invocations, stderr, exit status, and structured errors. Hosts refresh
repository state after any execution attempt and report actual errors; they must
not equate successful process launch with successful patch application.

`worktree` leaves staging unchanged; `indexAndWorktree` requires Git's normal
index/working-copy consistency and applies to both. Neither mode creates a
commit. Normal patches do not encode the exporter's former staged/unstaged split.
Filesystem I/O failure or external concurrent processes remain possible; do not
advertise a global transaction or automatic rollback of unrelated edits.

The older `git.apply` Shelf modes retain their existing behavior. In particular,
`worktreeCheck` and `restoreIndexCheck` remain reverse checks for Shelf retry
detection and are not aliases for the new forward preview.
