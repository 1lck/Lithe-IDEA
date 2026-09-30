//! [`HeapSize`] for the snapshot types this crate hands to the UI.
//!
//! These are the populations the perf census reports on, because they are the
//! ones that scale with the repository rather than with the window: a
//! [`CommitInfo`] per commit in the loaded window, a [`FileDiff`] per file in a
//! commit, a [`GraphRow`] per row of the graph. Every one of them is retained
//! in at least one cache, so knowing their true cost is what tells you whether
//! a cache bound expressed in *entries* is bounding anything at all.

use rgitui_perf::{Census, HeapSize};

use crate::graph::{GraphEdge, GraphRow};
use crate::project::{
    BlameEntry, BlameLine, ReflogEntryInfo, WorktreeFileSnapshot, WorktreeFileState,
};
use crate::types::{
    BranchInfo, CommitDiff, CommitInfo, DiffHunk, DiffLine, FileChangeKind, FileDiff, FileStatus,
    RefLabel, RemoteInfo, SearchResult, Signature, StashEntry, TagInfo, WorkingTreeStatus,
    WorktreeInfo,
};

/// The change kind is a fieldless enum.
impl HeapSize for FileChangeKind {
    fn heap_size(&self, _census: &mut Census) -> usize {
        0
    }
}

impl HeapSize for Signature {
    fn heap_size(&self, census: &mut Census) -> usize {
        self.name.heap_size(census) + self.email.heap_size(census)
    }
}

impl HeapSize for RefLabel {
    fn heap_size(&self, census: &mut Census) -> usize {
        match self {
            RefLabel::Head => 0,
            RefLabel::LocalBranch(name) | RefLabel::RemoteBranch(name) | RefLabel::Tag(name) => {
                name.heap_size(census)
            }
        }
    }
}

/// A commit carries its subject line twice: once as `summary` and again as the
/// first line of `message`. Both are counted, because both are really there —
/// the census exists to surface duplication like this, not to launder it.
impl HeapSize for CommitInfo {
    fn heap_size(&self, census: &mut Census) -> usize {
        self.short_id.heap_size(census)
            + self.summary.heap_size(census)
            + self.message.heap_size(census)
            + self.author.heap_size(census)
            + self.committer.heap_size(census)
            + self.co_authors.heap_size(census)
            + self.parent_oids.heap_size(census)
            + self.refs.heap_size(census)
    }
}

impl HeapSize for BranchInfo {
    fn heap_size(&self, census: &mut Census) -> usize {
        self.name.heap_size(census)
            + self.upstream.heap_size(census)
            + self.author_email.heap_size(census)
    }
}

impl HeapSize for TagInfo {
    fn heap_size(&self, census: &mut Census) -> usize {
        self.name.heap_size(census) + self.message.heap_size(census)
    }
}

impl HeapSize for RemoteInfo {
    fn heap_size(&self, census: &mut Census) -> usize {
        self.name.heap_size(census) + self.url.heap_size(census) + self.push_url.heap_size(census)
    }
}

impl HeapSize for WorktreeInfo {
    fn heap_size(&self, census: &mut Census) -> usize {
        self.name.heap_size(census)
            + self.path.heap_size(census)
            + self.branch.heap_size(census)
            + self.status.heap_size(census)
    }
}

impl HeapSize for StashEntry {
    fn heap_size(&self, census: &mut Census) -> usize {
        self.message.heap_size(census)
    }
}

impl HeapSize for FileStatus {
    fn heap_size(&self, census: &mut Census) -> usize {
        self.path.heap_size(census) + self.old_path.heap_size(census)
    }
}

impl HeapSize for WorkingTreeStatus {
    fn heap_size(&self, census: &mut Census) -> usize {
        self.staged.heap_size(census) + self.unstaged.heap_size(census)
    }

    fn heap_count(&self) -> Option<usize> {
        Some(self.staged.len() + self.unstaged.len())
    }
}

/// Every variant owns one line of text, so the discriminant costs nothing extra.
impl HeapSize for DiffLine {
    fn heap_size(&self, census: &mut Census) -> usize {
        match self {
            DiffLine::Context(text) | DiffLine::Addition(text) | DiffLine::Deletion(text) => {
                text.heap_size(census)
            }
        }
    }
}

impl HeapSize for DiffHunk {
    fn heap_size(&self, census: &mut Census) -> usize {
        self.header.heap_size(census) + self.lines.heap_size(census)
    }

    fn heap_count(&self) -> Option<usize> {
        Some(self.lines.len())
    }
}

impl HeapSize for FileDiff {
    fn heap_size(&self, census: &mut Census) -> usize {
        self.path.heap_size(census) + self.hunks.heap_size(census)
    }

    /// Lines rather than hunks: a diff's cost tracks its line count, and a
    /// hunk count would make a single 50,000-line hunk look cheap.
    fn heap_count(&self) -> Option<usize> {
        Some(self.hunks.iter().map(|hunk| hunk.lines.len()).sum())
    }
}

impl HeapSize for CommitDiff {
    fn heap_size(&self, census: &mut Census) -> usize {
        self.files.heap_size(census)
    }

    fn heap_count(&self) -> Option<usize> {
        Some(self.files.len())
    }
}

impl HeapSize for SearchResult {
    fn heap_size(&self, census: &mut Census) -> usize {
        self.path.heap_size(census) + self.content.heap_size(census)
    }
}

impl HeapSize for BlameEntry {
    fn heap_size(&self, census: &mut Census) -> usize {
        self.short_id.heap_size(census)
            + self.author.heap_size(census)
            + self.email.heap_size(census)
    }
}

/// Blame holds the whole file: one entry per line, each with its own copy of
/// the author and short id even where consecutive lines share a commit.
impl HeapSize for BlameLine {
    fn heap_size(&self, census: &mut Census) -> usize {
        self.content.heap_size(census) + self.entry.heap_size(census)
    }
}

/// A reflog entry holds two short ids, a message and a committer name, all as
/// owned strings. The reflog of a long-lived checkout runs to thousands of
/// entries, and the view keeps every one of them.
impl HeapSize for ReflogEntryInfo {
    fn heap_size(&self, census: &mut Census) -> usize {
        self.new_short_id.heap_size(census)
            + self.old_short_id.heap_size(census)
            + self.message.heap_size(census)
            + self.committer.heap_size(census)
    }
}

/// A snapshotted working-tree file, held by the undo stack so an apply or
/// revert can be reversed byte for byte. Both halves are whole file contents,
/// which makes this the one snapshot type in the app whose size is set by the
/// files a user touched rather than by the repository.
impl HeapSize for WorktreeFileState {
    fn heap_size(&self, _census: &mut Census) -> usize {
        self.contents.capacity()
    }

    fn heap_count(&self) -> Option<usize> {
        Some(self.contents.len())
    }
}

impl HeapSize for WorktreeFileSnapshot {
    fn heap_size(&self, census: &mut Census) -> usize {
        self.path.heap_size(census)
            + self.before.heap_size(census)
            + self.expected_after.heap_size(census)
    }
}

impl HeapSize for GraphEdge {
    fn heap_size(&self, _census: &mut Census) -> usize {
        0
    }
}

/// A graph row's own fields are scalars, but its `edges` vector is a separate
/// allocation per row — so a 100,000-commit graph is 100,000 allocations before
/// a single edge is stored. That is the cost this impl exists to make visible.
impl HeapSize for GraphRow {
    fn heap_size(&self, census: &mut Census) -> usize {
        self.edges.heap_size(census)
    }

    fn heap_count(&self) -> Option<usize> {
        Some(self.edges.len())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_commit_is_charged_for_every_string_it_owns() {
        let mut census = Census::new();
        let commit = CommitInfo {
            oid: git2::Oid::zero(),
            short_id: "abc1234".to_string(),
            summary: "Fix the thing".to_string(),
            message: "Fix the thing\n\nWith detail.".to_string(),
            author: Signature {
                name: "A".to_string(),
                email: "a@example.com".to_string(),
            },
            committer: Signature {
                name: "B".to_string(),
                email: "b@example.com".to_string(),
            },
            co_authors: Vec::new(),
            time: chrono::Utc::now(),
            parent_oids: vec![git2::Oid::zero()],
            refs: vec![RefLabel::LocalBranch("main".to_string())],
            is_signed: false,
        };

        let bytes = commit.heap_size(&mut census);
        let strings = "abc1234".len()
            + "Fix the thing".len()
            + "Fix the thing\n\nWith detail.".len()
            + "A".len()
            + "a@example.com".len()
            + "B".len()
            + "b@example.com".len()
            + "main".len();
        let vectors = size_of::<git2::Oid>() + size_of::<RefLabel>();

        assert_eq!(bytes, strings + vectors);
    }

    #[test]
    fn a_graph_row_reports_its_own_edge_allocation() {
        let mut census = Census::new();
        let row = GraphRow {
            commit_index: 0,
            node_lane: 0,
            edges: vec![
                GraphEdge {
                    from_lane: 0,
                    to_lane: 0,
                    color_index: 0,
                    is_merge: false,
                };
                3
            ],
            lane_count: 1,
            node_color: 0,
            has_incoming: false,
            is_head: false,
            is_merge: false,
        };

        assert_eq!(row.heap_size(&mut census), 3 * size_of::<GraphEdge>());
        assert_eq!(row.heap_count(), Some(3));
    }

    #[test]
    fn a_file_diff_counts_lines_rather_than_hunks() {
        let mut census = Census::new();
        let diff = FileDiff {
            path: std::path::PathBuf::from("src/main.rs"),
            hunks: vec![DiffHunk {
                old_start: 1,
                old_lines: 2,
                new_start: 1,
                new_lines: 2,
                header: "@@ -1,2 +1,2 @@".to_string(),
                lines: vec![
                    DiffLine::Context("a".to_string()),
                    DiffLine::Addition("b".to_string()),
                ],
            }],
            additions: 1,
            deletions: 0,
            kind: FileChangeKind::Modified,
        };

        assert_eq!(diff.heap_count(), Some(2));
        assert!(diff.heap_size(&mut census) > 0);
    }
}
