# Git commit-message context

`git.commitMessageContext` collects evidence for AI commit generation without
modifying the real index. The behavioral fixture is
[`commit-message-context-v1.json`](../fixtures/git/commit-message-context-v1.json).
Hosts own the selected UI rows, provider credentials, network requests, and draft.

`capture` takes `mode` (`staged` or `worktree`), `repositories` with each
repository root and selected `files` (`path`, optional `originalPath`, and
`changeKind`), and `maximumDiffCharacters` (8,000–120,000 Unicode scalars).
macOS uses staged changes; Windows uses the complete working-tree state of its
selected paths. Both semantics must match the corresponding commit operation.

Core reads fresh Git state without the frontend diff cache, rejects missing or
ambiguous selections and sensitive source or destination paths, and preserves
all file identities. An untracked directory selection expands to its files;
the complete expansion is limited to 1,000 files. Binary contents are omitted
with an explicit marker; a binary-only selection has no textual evidence and
is rejected. Git patch exchange rejects a patch larger than 32 MiB
or invalid UTF-8; the total across repositories is also limited to 32 MiB.
These failures never return incomplete evidence.

The response includes bounded `files` (`path`, `changeKind`, `diff`,
`originalCharacters`, `truncated`) and an opaque `token`. `changeKind` comes from
the captured patch, so a working-tree deletion does not relabel a staged
modification. `ai` owns allocation
of the budget; both the typed and JSON AI planners validate original lengths and
include an explicit truncation warning. The token covers the selected identities,
branch and HEAD, semantic index entries and Git-visible assume-unchanged/skip-worktree flags, and the complete untruncated
patch. For worktree mode Core takes two uncached snapshots to detect edits while
reading. Multi-repository paths use deterministic `repository-N/` prefixes.

`check` accepts the same `mode` and `repositories` plus the captured `token` and
returns `isCurrent`. It reads the current state again; a missing selection,
read failure, or changed content returns false. Hosts must check workspace,
selection and draft lifetime as well, then apply the generated text only after
`isCurrent` is true. If replacement requires confirmation, they must recheck
immediately before replacing the draft and keep any text edited during that
check. Cancellation, stale state and failures never stage or commit files.

The token conservatively covers the whole repository index, so a change to an
unselected staged file also invalidates the draft. It is a digest, not a global
lock. External Git or filesystem writes can still occur after the final check;
hosts must not describe it as a transaction.
