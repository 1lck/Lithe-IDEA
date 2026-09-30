use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// A single line from a global content search result.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SearchResult {
    /// Absolute path to the file containing the match.
    pub path: PathBuf,
    /// 1-based line number within the file.
    pub line_number: usize,
    /// Full text of the matching line.
    pub content: String,
}

/// Information about a Git signature (author or committer).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Signature {
    pub name: String,
    pub email: String,
}

/// A reference label attached to a commit.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RefLabel {
    Head,
    LocalBranch(String),
    RemoteBranch(String),
    Tag(String),
}

impl RefLabel {
    pub fn display_name(&self) -> &str {
        match self {
            RefLabel::Head => "HEAD",
            RefLabel::LocalBranch(name) => name,
            RefLabel::RemoteBranch(name) => name,
            RefLabel::Tag(name) => name,
        }
    }
}

/// A ref label prepared for compact UI display. A local branch absorbs matching
/// remote-tracking refs so `topic` and `origin/topic` can be shown as one chip.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CompactRefLabel {
    pub label: RefLabel,
    pub remotes: Vec<String>,
}

/// Combine a local branch with remote-tracking refs that point at the same
/// commit and have the same branch path after the remote name.
pub fn compact_ref_labels(refs: &[RefLabel]) -> Vec<CompactRefLabel> {
    let local_names: std::collections::HashSet<&str> = refs
        .iter()
        .filter_map(|label| match label {
            RefLabel::LocalBranch(name) => Some(name.as_str()),
            _ => None,
        })
        .collect();
    let mut remotes_by_local: std::collections::HashMap<&str, Vec<String>> =
        std::collections::HashMap::new();

    for label in refs {
        let RefLabel::RemoteBranch(name) = label else {
            continue;
        };
        let Some((remote, branch_path)) = name.split_once('/') else {
            continue;
        };
        if local_names.contains(branch_path) {
            remotes_by_local
                .entry(branch_path)
                .or_default()
                .push(remote.to_string());
        }
    }

    refs.iter()
        .filter_map(|label| match label {
            RefLabel::RemoteBranch(name) => {
                let paired = name
                    .split_once('/')
                    .is_some_and(|(_, branch_path)| local_names.contains(branch_path));
                (!paired).then(|| CompactRefLabel {
                    label: label.clone(),
                    remotes: Vec::new(),
                })
            }
            RefLabel::LocalBranch(name) => Some(CompactRefLabel {
                label: label.clone(),
                remotes: remotes_by_local.remove(name.as_str()).unwrap_or_default(),
            }),
            _ => Some(CompactRefLabel {
                label: label.clone(),
                remotes: Vec::new(),
            }),
        })
        .collect()
}

/// What checking out a commit from the graph should do.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CommitCheckout {
    /// The checked-out branch already points at the commit.
    AlreadyCheckedOut(String),
    /// A local branch points at the commit; checking it out keeps HEAD on a
    /// branch.
    Branch(String),
    /// No local branch points at the commit, so HEAD detaches there.
    Detached,
}

/// Decides what activating a commit with `refs` checks out while `head_branch`
/// is checked out (`None` when HEAD is detached).
///
/// Detaching at a commit a branch already names only strands the user off that
/// branch, so a local branch is preferred, and the one already checked out
/// before any other. Tags and remote-tracking branches still detach, as they do
/// in git.
pub fn commit_checkout(refs: &[RefLabel], head_branch: Option<&str>) -> CommitCheckout {
    let local_branches = || {
        refs.iter().filter_map(|label| match label {
            RefLabel::LocalBranch(name) => Some(name.as_str()),
            _ => None,
        })
    };
    if let Some(current) = local_branches().find(|name| Some(*name) == head_branch) {
        return CommitCheckout::AlreadyCheckedOut(current.to_owned());
    }
    local_branches()
        .next()
        .map_or(CommitCheckout::Detached, |branch| {
            CommitCheckout::Branch(branch.to_owned())
        })
}

/// Information about a single commit.
#[derive(Debug, Clone)]
pub struct CommitInfo {
    pub oid: git2::Oid,
    pub short_id: String,
    pub summary: String,
    pub message: String,
    pub author: Signature,
    pub committer: Signature,
    pub co_authors: Vec<Signature>,
    pub time: DateTime<Utc>,
    pub parent_oids: Vec<git2::Oid>,
    pub refs: Vec<RefLabel>,
    /// Whether this commit has a GPG signature (gpgsig header present).
    pub is_signed: bool,
}

/// Information about a branch.
#[derive(Debug, Clone, PartialEq)]
pub struct BranchInfo {
    pub name: String,
    pub is_head: bool,
    pub is_remote: bool,
    pub upstream: Option<String>,
    /// Commits this branch has that its upstream does not. `None` until the
    /// walk that computes it has run — which is a different thing from `Some(0)`,
    /// "level with upstream", and conflating the two is how a pushed branch
    /// keeps reporting the count it had before the push.
    pub ahead: Option<usize>,
    /// Commits the upstream has that this branch does not. See [`BranchInfo::ahead`].
    pub behind: Option<usize>,
    pub tip_oid: Option<git2::Oid>,
    /// Author email of the tip commit — used to filter "My Branches".
    pub author_email: Option<String>,
    /// Unix timestamp of the tip commit, if available.
    pub last_commit_time: Option<i64>,
    /// Whether this branch is merged into the default branch (main/master).
    /// None = not yet computed, Some(false) = checked and not merged, Some(true) = merged.
    pub is_merged_into_main: Option<bool>,
    /// Whether this local branch is merged into the currently checked-out branch.
    pub is_merged_into_head: Option<bool>,
}

impl BranchInfo {
    /// Commits ahead of upstream, treating "not computed yet" as none.
    ///
    /// For display only. Anything deciding whether the value is *known* — a
    /// cache carrying state forward, a filter asserting divergence — must look
    /// at the [`Option`] itself, or it will read a pending walk as a result.
    pub fn ahead_count(&self) -> usize {
        self.ahead.unwrap_or(0)
    }

    /// Commits behind upstream. See [`BranchInfo::ahead_count`].
    pub fn behind_count(&self) -> usize {
        self.behind.unwrap_or(0)
    }

    /// Whether the ahead/behind walk has produced an answer for this branch.
    pub fn has_ahead_behind(&self) -> bool {
        self.ahead.is_some() || self.behind.is_some()
    }
}

/// Information about a tag.
#[derive(Debug, Clone, PartialEq)]
pub struct TagInfo {
    pub name: String,
    pub oid: git2::Oid,
    pub message: Option<String>,
}

/// Information about a remote.
#[derive(Debug, Clone, PartialEq)]
pub struct RemoteInfo {
    pub name: String,
    pub url: Option<String>,
    pub push_url: Option<String>,
}

/// Information about a worktree attached to this repository.
#[derive(Debug, Clone, PartialEq)]
pub struct WorktreeInfo {
    /// The worktree name (directory name or custom name).
    pub name: String,
    /// Absolute path to the worktree working directory.
    pub path: PathBuf,
    /// Whether the worktree is locked (e.g. by a running operation).
    pub is_locked: bool,
    /// Whether this is the worktree the open `Repository` handle points at —
    /// i.e. the one rgitui was launched on. That is the main checkout only when
    /// rgitui was opened on the main repository; opening a linked worktree
    /// directly makes *it* the current one.
    pub is_current: bool,
    /// The branch currently checked out in this worktree. `None` when HEAD is
    /// detached — git2's `shorthand()` reports a short OID in that case, which
    /// must not be rendered as a branch name.
    pub branch: Option<String>,
    /// Whether this worktree's HEAD is detached.
    pub head_detached: bool,
    /// OID of the HEAD commit in this worktree.
    pub head_oid: Option<git2::Oid>,
    /// Cached pending-change status for this worktree, if available.
    pub status: Option<WorkingTreeStatus>,
    /// Whether this checkout is mid-merge, mid-rebase, mid-cherry-pick and so
    /// on. Each worktree keeps its own — `MERGE_HEAD` for a linked worktree
    /// lives under `.git/worktrees/<name>/`, so asking the main repository
    /// about it always answers `Clean`.
    pub state: RepoState,
}

/// Information about a stash entry.
#[derive(Debug, Clone, PartialEq)]
pub struct StashEntry {
    pub index: usize,
    pub message: String,
    pub oid: git2::Oid,
}

/// Status of a file in the working tree.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum FileChangeKind {
    Added,
    Modified,
    Deleted,
    Renamed,
    Copied,
    TypeChange,
    Untracked,
    Conflicted,
}

impl FileChangeKind {
    pub fn short_code(&self) -> &'static str {
        match self {
            FileChangeKind::Added => "A",
            FileChangeKind::Modified => "M",
            FileChangeKind::Deleted => "D",
            FileChangeKind::Renamed => "R",
            FileChangeKind::Copied => "C",
            FileChangeKind::TypeChange => "T",
            FileChangeKind::Untracked => "?",
            FileChangeKind::Conflicted => "!",
        }
    }
}

/// A file change in the working tree or staging area.
#[derive(Debug, Clone, PartialEq)]
pub struct FileStatus {
    pub path: PathBuf,
    pub kind: FileChangeKind,
    pub old_path: Option<PathBuf>,
    /// Number of lines added in this file change.
    pub additions: usize,
    /// Number of lines deleted in this file change.
    pub deletions: usize,
}

/// Summary of all working tree changes.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct WorkingTreeStatus {
    pub staged: Vec<FileStatus>,
    pub unstaged: Vec<FileStatus>,
}

/// A hunk in a diff.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiffHunk {
    pub old_start: u32,
    pub old_lines: u32,
    pub new_start: u32,
    pub new_lines: u32,
    pub header: String,
    pub lines: Vec<DiffLine>,
}

/// A single line in a diff hunk.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DiffLine {
    Context(String),
    Addition(String),
    Deletion(String),
}

/// A complete file diff.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FileDiff {
    pub path: PathBuf,
    pub hunks: Vec<DiffHunk>,
    pub additions: usize,
    pub deletions: usize,
    pub kind: FileChangeKind,
}

/// A complete commit diff (all files).
#[derive(Debug, Clone)]
pub struct CommitDiff {
    pub files: Vec<FileDiff>,
    pub total_additions: usize,
    pub total_deletions: usize,
}

/// One lossless section of Git's three-way merge result.
///
/// Bytes are retained rather than converted to lines here so CRLF, invalid
/// UTF-8 and a missing final newline survive a round-trip through the conflict
/// resolver. Text conversion is a presentation concern in `rgitui_diff`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MergeSection {
    /// Content Git merged without user input.
    Resolved(Vec<u8>),
    /// A section for which Git needs an explicit result.
    Conflict {
        ancestor: Vec<u8>,
        ours: Vec<u8>,
        theirs: Vec<u8>,
    },
}

/// The kind, bytes and Git-relevant permissions of a conflicted worktree path.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConflictWorktreeSnapshot {
    Missing,
    Regular {
        bytes: Vec<u8>,
        executable: Option<bool>,
        readonly: bool,
    },
    Symlink {
        target: Vec<u8>,
    },
    Other,
}

impl ConflictWorktreeSnapshot {
    pub fn bytes(&self) -> Option<&[u8]> {
        match self {
            Self::Regular { bytes, .. } => Some(bytes),
            Self::Symlink { target } => Some(target),
            Self::Missing | Self::Other => None,
        }
    }
}

/// The index and working-tree state the resolver was built from.
///
/// Resolution compares this snapshot with the repository again immediately
/// before writing. That prevents an old view from overwriting edits or a newer
/// merge state that appeared while it was open.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ConflictSnapshot {
    pub ancestor_oid: Option<git2::Oid>,
    pub ancestor_mode: Option<u32>,
    pub ours_oid: Option<git2::Oid>,
    pub ours_mode: Option<u32>,
    pub theirs_oid: Option<git2::Oid>,
    pub theirs_mode: Option<u32>,
    pub worktree: ConflictWorktreeSnapshot,
}

/// A merge-aware conflict model for one unmerged index entry.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ThreeWayFileDiff {
    pub path: PathBuf,
    pub sections: Vec<MergeSection>,
    pub snapshot: ConflictSnapshot,
    pub ancestor_exists: bool,
    pub ours_exists: bool,
    pub theirs_exists: bool,
    /// True when at least one side cannot be represented safely as UTF-8 text.
    pub is_binary: bool,
    /// True for symlinks, submodules and other entries that cannot use the text
    /// result composer. Whole-side resolution remains available for them.
    pub is_special_file: bool,
    /// File mode selected by libgit2 for an assembled text result.
    pub result_mode: u32,
}

impl ThreeWayFileDiff {
    pub fn conflict_count(&self) -> usize {
        self.sections
            .iter()
            .filter(|section| matches!(section, MergeSection::Conflict { .. }))
            .count()
    }

    pub fn supports_text_resolution(&self) -> bool {
        !self.is_binary && !self.is_special_file && self.ours_exists && self.theirs_exists
    }
}

/// The current state of the repository (normal, mid-merge, mid-rebase, etc).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RepoState {
    Clean,
    Merge,
    Revert,
    RevertSequence,
    CherryPick,
    CherryPickSequence,
    Bisect,
    Rebase,
    RebaseInteractive,
    RebaseMerge,
    ApplyMailbox,
    ApplyMailboxOrRebase,
}

impl RepoState {
    /// Convert from git2::RepositoryState.
    pub fn from_git2(state: git2::RepositoryState) -> Self {
        match state {
            git2::RepositoryState::Clean => RepoState::Clean,
            git2::RepositoryState::Merge => RepoState::Merge,
            git2::RepositoryState::Revert => RepoState::Revert,
            git2::RepositoryState::RevertSequence => RepoState::RevertSequence,
            git2::RepositoryState::CherryPick => RepoState::CherryPick,
            git2::RepositoryState::CherryPickSequence => RepoState::CherryPickSequence,
            git2::RepositoryState::Bisect => RepoState::Bisect,
            git2::RepositoryState::Rebase => RepoState::Rebase,
            git2::RepositoryState::RebaseInteractive => RepoState::RebaseInteractive,
            git2::RepositoryState::RebaseMerge => RepoState::RebaseMerge,
            git2::RepositoryState::ApplyMailbox => RepoState::ApplyMailbox,
            git2::RepositoryState::ApplyMailboxOrRebase => RepoState::ApplyMailboxOrRebase,
        }
    }

    pub fn is_clean(&self) -> bool {
        matches!(self, RepoState::Clean)
    }

    /// The `git` subcommand whose `--continue` carries this state forward, or
    /// `None` for the states that have no continuation. A clean repository has
    /// nothing to continue, and a bisect advances by marking the checked-out
    /// commit good or bad rather than by continuing.
    pub fn continue_subcommand(&self) -> Option<&'static str> {
        match self {
            RepoState::Merge => Some("merge"),
            RepoState::Revert | RepoState::RevertSequence => Some("revert"),
            RepoState::CherryPick | RepoState::CherryPickSequence => Some("cherry-pick"),
            RepoState::Rebase | RepoState::RebaseInteractive | RepoState::RebaseMerge => {
                Some("rebase")
            }
            RepoState::ApplyMailbox | RepoState::ApplyMailboxOrRebase => Some("am"),
            RepoState::Clean | RepoState::Bisect => None,
        }
    }

    /// The operation kind this state belongs to, so continuing or aborting it
    /// is reported under the same kind that started it.
    pub fn operation_kind(&self) -> GitOperationKind {
        match self {
            RepoState::Revert | RepoState::RevertSequence => GitOperationKind::Revert,
            RepoState::CherryPick | RepoState::CherryPickSequence => GitOperationKind::CherryPick,
            RepoState::Rebase | RepoState::RebaseInteractive | RepoState::RebaseMerge => {
                GitOperationKind::Rebase
            }
            RepoState::Bisect => GitOperationKind::Bisect,
            RepoState::Clean
            | RepoState::Merge
            | RepoState::ApplyMailbox
            | RepoState::ApplyMailboxOrRebase => GitOperationKind::Merge,
        }
    }

    /// Human-readable label for the repo state.
    pub fn label(&self) -> &'static str {
        match self {
            RepoState::Clean => "Clean",
            RepoState::Merge => "Merging",
            RepoState::Revert => "Reverting",
            RepoState::RevertSequence => "Reverting",
            RepoState::CherryPick => "Cherry-picking",
            RepoState::CherryPickSequence => "Cherry-picking",
            RepoState::Bisect => "Bisecting",
            RepoState::Rebase => "Rebasing",
            RepoState::RebaseInteractive => "Rebasing (interactive)",
            RepoState::RebaseMerge => "Rebasing",
            RepoState::ApplyMailbox => "Applying patches",
            RepoState::ApplyMailboxOrRebase => "Applying patches",
        }
    }
}

/// The action to perform on a commit during interactive rebase.
#[derive(Debug, Clone)]
pub enum RebaseEntryAction {
    Pick,
    Reword(String),
    Squash,
    Fixup,
    Drop,
}

/// A single entry in an interactive rebase plan.
#[derive(Debug, Clone)]
pub struct RebasePlanEntry {
    pub oid: String,
    pub message: String,
    pub action: RebaseEntryAction,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GitOperationKind {
    Fetch,
    Pull,
    Push,
    Checkout,
    Merge,
    CherryPick,
    Revert,
    Reset,
    RemoveRemote,
    Commit,
    Stage,
    Unstage,
    Stash,
    Branch,
    Tag,
    Discard,
    Rebase,
    Bisect,
    Worktree,
    ResolveConflict,
    Clean,
    Clone,
    /// Writing diff content from another revision into the working tree.
    ApplyToWorktree,
    /// Removing diff content from another revision out of the working tree.
    RevertInWorktree,
}

impl GitOperationKind {
    pub fn display_name(&self) -> &'static str {
        match self {
            GitOperationKind::Fetch => "Fetch",
            GitOperationKind::Pull => "Pull",
            GitOperationKind::Push => "Push",
            GitOperationKind::Checkout => "Checkout",
            GitOperationKind::Merge => "Merge",
            GitOperationKind::CherryPick => "Cherry-pick",
            GitOperationKind::Revert => "Revert",
            GitOperationKind::Reset => "Reset",
            GitOperationKind::RemoveRemote => "Remove remote",
            GitOperationKind::Commit => "Commit",
            GitOperationKind::Stage => "Stage",
            GitOperationKind::Unstage => "Unstage",
            GitOperationKind::Stash => "Stash",
            GitOperationKind::Branch => "Branch",
            GitOperationKind::Tag => "Tag",
            GitOperationKind::Discard => "Discard",
            GitOperationKind::Rebase => "Rebase",
            GitOperationKind::Bisect => "Bisect",
            GitOperationKind::Worktree => "Worktree",
            GitOperationKind::ResolveConflict => "Resolve conflict",
            GitOperationKind::Clean => "Clean",
            GitOperationKind::Clone => "Clone",
            GitOperationKind::ApplyToWorktree => "Apply to working tree",
            GitOperationKind::RevertInWorktree => "Revert in working tree",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum GitOperationState {
    Running,
    Succeeded,
    Failed,
}

#[derive(Debug, Clone)]
pub struct GitOperationUpdate {
    pub id: u64,
    pub kind: GitOperationKind,
    pub state: GitOperationState,
    pub summary: String,
    pub details: Option<String>,
    pub remote_name: Option<String>,
    pub branch_name: Option<String>,
    /// The checkout the operation ran in, for the operations that record one.
    ///
    /// Retrying has to go back to where it failed. Resolving that at retry time
    /// from whatever is being inspected then is wrong as soon as the failure
    /// arrives after the user has moved on — which for a network operation,
    /// where the failure is a timeout or a rejected push, is the normal case.
    pub worktree_path: Option<std::path::PathBuf>,
    pub retryable: bool,
}

#[cfg(test)]
mod tests {
    #[test]
    fn every_in_progress_state_but_bisect_has_a_continue_subcommand() {
        for state in [
            RepoState::Merge,
            RepoState::Revert,
            RepoState::RevertSequence,
            RepoState::CherryPick,
            RepoState::CherryPickSequence,
            RepoState::Rebase,
            RepoState::RebaseInteractive,
            RepoState::RebaseMerge,
            RepoState::ApplyMailbox,
            RepoState::ApplyMailboxOrRebase,
        ] {
            assert!(
                state.continue_subcommand().is_some(),
                "{:?} is shown in the conflict banner and must be continuable",
                state
            );
        }

        // A clean repo has nothing to continue, and a bisect advances by judging
        // the checked-out commit rather than by continuing.
        assert_eq!(RepoState::Clean.continue_subcommand(), None);
        assert_eq!(RepoState::Bisect.continue_subcommand(), None);
    }

    #[test]
    fn continue_subcommand_names_the_operation_that_stopped() {
        assert_eq!(RepoState::Merge.continue_subcommand(), Some("merge"));
        assert_eq!(
            RepoState::CherryPickSequence.continue_subcommand(),
            Some("cherry-pick")
        );
        assert_eq!(
            RepoState::RevertSequence.continue_subcommand(),
            Some("revert")
        );
        assert_eq!(RepoState::RebaseMerge.continue_subcommand(), Some("rebase"));
        assert_eq!(
            RepoState::ApplyMailboxOrRebase.continue_subcommand(),
            Some("am")
        );
    }

    #[test]
    fn operation_kind_follows_the_state_that_stopped() {
        assert_eq!(RepoState::Merge.operation_kind(), GitOperationKind::Merge);
        assert_eq!(
            RepoState::CherryPickSequence.operation_kind(),
            GitOperationKind::CherryPick
        );
        assert_eq!(RepoState::Revert.operation_kind(), GitOperationKind::Revert);
        assert_eq!(
            RepoState::RebaseInteractive.operation_kind(),
            GitOperationKind::Rebase
        );
        assert_eq!(RepoState::Bisect.operation_kind(), GitOperationKind::Bisect);
    }

    use super::*;

    #[test]
    fn ref_label_display_name() {
        assert_eq!(RefLabel::Head.display_name(), "HEAD");
        assert_eq!(RefLabel::LocalBranch("main".into()).display_name(), "main");
        assert_eq!(
            RefLabel::RemoteBranch("origin/main".into()).display_name(),
            "origin/main"
        );
        assert_eq!(RefLabel::Tag("v1.0.0".into()).display_name(), "v1.0.0");
    }

    #[test]
    fn compact_refs_merge_matching_local_and_remote_branches() {
        let refs = vec![
            RefLabel::Head,
            RefLabel::LocalBranch("codex/topic".into()),
            RefLabel::RemoteBranch("origin/codex/topic".into()),
            RefLabel::RemoteBranch("upstream/other".into()),
        ];

        assert_eq!(
            compact_ref_labels(&refs),
            vec![
                CompactRefLabel {
                    label: RefLabel::Head,
                    remotes: vec![],
                },
                CompactRefLabel {
                    label: RefLabel::LocalBranch("codex/topic".into()),
                    remotes: vec!["origin".into()],
                },
                CompactRefLabel {
                    label: RefLabel::RemoteBranch("upstream/other".into()),
                    remotes: vec![],
                },
            ]
        );
    }

    #[test]
    fn a_commit_with_no_local_branch_detaches() {
        assert_eq!(commit_checkout(&[], Some("main")), CommitCheckout::Detached);
        let refs = [
            RefLabel::Tag("v1.0.0".into()),
            RefLabel::RemoteBranch("origin/main".into()),
        ];
        assert_eq!(commit_checkout(&refs, None), CommitCheckout::Detached);
    }

    #[test]
    fn a_commit_a_local_branch_names_checks_that_branch_out() {
        let refs = [
            RefLabel::LocalBranch("main".into()),
            RefLabel::RemoteBranch("origin/main".into()),
        ];
        assert_eq!(
            commit_checkout(&refs, Some("feature")),
            CommitCheckout::Branch("main".into())
        );
        // Detached at this very commit: back onto its branch.
        let refs = [RefLabel::Head, RefLabel::LocalBranch("main".into())];
        assert_eq!(
            commit_checkout(&refs, None),
            CommitCheckout::Branch("main".into())
        );
    }

    #[test]
    fn the_branch_already_checked_out_wins_over_its_neighbours() {
        let refs = [
            RefLabel::Head,
            RefLabel::LocalBranch("feature".into()),
            RefLabel::LocalBranch("main".into()),
        ];
        assert_eq!(
            commit_checkout(&refs, Some("main")),
            CommitCheckout::AlreadyCheckedOut("main".into())
        );
        assert_eq!(
            commit_checkout(&refs, Some("other")),
            CommitCheckout::Branch("feature".into())
        );
    }

    #[test]
    fn file_change_kind_short_code() {
        assert_eq!(FileChangeKind::Added.short_code(), "A");
        assert_eq!(FileChangeKind::Modified.short_code(), "M");
        assert_eq!(FileChangeKind::Deleted.short_code(), "D");
        assert_eq!(FileChangeKind::Renamed.short_code(), "R");
        assert_eq!(FileChangeKind::Copied.short_code(), "C");
        assert_eq!(FileChangeKind::TypeChange.short_code(), "T");
        assert_eq!(FileChangeKind::Untracked.short_code(), "?");
        assert_eq!(FileChangeKind::Conflicted.short_code(), "!");
    }

    #[test]
    fn repo_state_from_git2() {
        assert_eq!(
            RepoState::from_git2(git2::RepositoryState::Clean),
            RepoState::Clean
        );
        assert_eq!(
            RepoState::from_git2(git2::RepositoryState::Merge),
            RepoState::Merge
        );
        assert_eq!(
            RepoState::from_git2(git2::RepositoryState::Revert),
            RepoState::Revert
        );
        assert_eq!(
            RepoState::from_git2(git2::RepositoryState::RevertSequence),
            RepoState::RevertSequence
        );
        assert_eq!(
            RepoState::from_git2(git2::RepositoryState::CherryPick),
            RepoState::CherryPick
        );
        assert_eq!(
            RepoState::from_git2(git2::RepositoryState::CherryPickSequence),
            RepoState::CherryPickSequence
        );
        assert_eq!(
            RepoState::from_git2(git2::RepositoryState::Bisect),
            RepoState::Bisect
        );
        assert_eq!(
            RepoState::from_git2(git2::RepositoryState::Rebase),
            RepoState::Rebase
        );
        assert_eq!(
            RepoState::from_git2(git2::RepositoryState::RebaseInteractive),
            RepoState::RebaseInteractive
        );
        assert_eq!(
            RepoState::from_git2(git2::RepositoryState::RebaseMerge),
            RepoState::RebaseMerge
        );
        assert_eq!(
            RepoState::from_git2(git2::RepositoryState::ApplyMailbox),
            RepoState::ApplyMailbox
        );
        assert_eq!(
            RepoState::from_git2(git2::RepositoryState::ApplyMailboxOrRebase),
            RepoState::ApplyMailboxOrRebase
        );
    }

    #[test]
    fn repo_state_is_clean() {
        assert!(RepoState::Clean.is_clean());
        assert!(!RepoState::Merge.is_clean());
        assert!(!RepoState::Rebase.is_clean());
        assert!(!RepoState::RebaseInteractive.is_clean());
        assert!(!RepoState::CherryPick.is_clean());
        assert!(!RepoState::Bisect.is_clean());
        assert!(!RepoState::ApplyMailbox.is_clean());
    }

    #[test]
    fn repo_state_label() {
        assert_eq!(RepoState::Clean.label(), "Clean");
        assert_eq!(RepoState::Merge.label(), "Merging");
        assert_eq!(RepoState::Revert.label(), "Reverting");
        assert_eq!(RepoState::RevertSequence.label(), "Reverting");
        assert_eq!(RepoState::CherryPick.label(), "Cherry-picking");
        assert_eq!(RepoState::CherryPickSequence.label(), "Cherry-picking");
        assert_eq!(RepoState::Bisect.label(), "Bisecting");
        assert_eq!(RepoState::Rebase.label(), "Rebasing");
        assert_eq!(
            RepoState::RebaseInteractive.label(),
            "Rebasing (interactive)"
        );
        assert_eq!(RepoState::RebaseMerge.label(), "Rebasing");
        assert_eq!(RepoState::ApplyMailbox.label(), "Applying patches");
        assert_eq!(RepoState::ApplyMailboxOrRebase.label(), "Applying patches");
    }

    #[test]
    fn git_operation_kind_display_name() {
        assert_eq!(GitOperationKind::Fetch.display_name(), "Fetch");
        assert_eq!(GitOperationKind::Pull.display_name(), "Pull");
        assert_eq!(GitOperationKind::Push.display_name(), "Push");
        assert_eq!(GitOperationKind::Checkout.display_name(), "Checkout");
        assert_eq!(GitOperationKind::Merge.display_name(), "Merge");
        assert_eq!(GitOperationKind::CherryPick.display_name(), "Cherry-pick");
        assert_eq!(GitOperationKind::Revert.display_name(), "Revert");
        assert_eq!(GitOperationKind::Reset.display_name(), "Reset");
        assert_eq!(
            GitOperationKind::RemoveRemote.display_name(),
            "Remove remote"
        );
        assert_eq!(GitOperationKind::Commit.display_name(), "Commit");
        assert_eq!(GitOperationKind::Stage.display_name(), "Stage");
        assert_eq!(GitOperationKind::Unstage.display_name(), "Unstage");
        assert_eq!(GitOperationKind::Stash.display_name(), "Stash");
        assert_eq!(GitOperationKind::Branch.display_name(), "Branch");
        assert_eq!(GitOperationKind::Tag.display_name(), "Tag");
        assert_eq!(GitOperationKind::Discard.display_name(), "Discard");
        assert_eq!(GitOperationKind::Rebase.display_name(), "Rebase");
        assert_eq!(GitOperationKind::Bisect.display_name(), "Bisect");
    }
}
