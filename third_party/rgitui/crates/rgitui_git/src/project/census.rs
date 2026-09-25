//! Walking [`GitProject`]'s retained snapshot into the heap census.
//!
//! The project is the app's largest single holder of repository-shaped memory
//! and, until this walk existed, none of it was reported: the census reached
//! the commit list only because `GraphView` happens to hold a clone of the same
//! `Arc`, and everything else the project caches — the refs, the working-tree
//! status, the per-worktree status cache — was invisible.
//!
//! Two of these nodes routinely read zero, and that is the point. `commits` and
//! `status` are `Arc`s the views also hold, so whichever path the walk reaches
//! first is charged and the other reports the population with no bytes beside
//! it. A node saying "1,000 commits, counted elsewhere" is the report proving
//! it did not double count; a node missing altogether is the report saying
//! nothing at all.

use rgitui_perf::{Census, HeapSize};

use super::GitProject;

impl GitProject {
    /// Records the repository snapshot this project retains, returning the
    /// bytes attributed so an enclosing scope can roll them up.
    ///
    /// The label set deliberately mirrors the fields rather than grouping them:
    /// "the refs cost 4 MB" is not a decision anyone can act on, while "the
    /// tags cost 4 MB" points straight at a load that could be paged.
    pub fn census(&self, census: &mut Census) -> usize {
        let mut total = 0;

        total += census.enter("commits", &self.recent_commits);
        total += census.enter("status", &self.status);
        total += census.enter("branches", &self.branches);
        total += census.enter("tags", &self.tags);
        total += census.enter("remotes", &self.remotes);
        total += census.enter("stashes", &self.stashes);
        total += census.enter("worktrees", &self.worktrees);
        total += census.enter("status_cache", &StatusCache(self));
        total += census.enter("paths", &Paths(self));

        total
    }
}

/// The per-worktree status cache shared with the file watcher.
///
/// Measured through the mutex rather than around it because the payload is a
/// whole `WorkingTreeStatus` per worktree — every changed path in every
/// checkout — and a repository with several worktrees holds as many copies.
struct StatusCache<'a>(&'a GitProject);

impl HeapSize for StatusCache<'_> {
    fn heap_size(&self, census: &mut Census) -> usize {
        match self.0.worktree_status_cache.lock() {
            Ok(cache) => cache.heap_size(census),
            // A poisoned lock means a background refresh panicked. Reporting
            // zero would be a lie, but so would blocking a measurement on it;
            // the count below is what says the node was skipped rather than
            // empty.
            Err(_) => 0,
        }
    }

    fn heap_count(&self) -> Option<usize> {
        self.0
            .worktree_status_cache
            .lock()
            .ok()
            .map(|cache| cache.len())
    }
}

/// The small strings the project keeps for the life of the repository: its
/// path, the current and previous head, the default branch, the user's email
/// and any author filter. Individually trivial, grouped so the report can show
/// they are.
struct Paths<'a>(&'a GitProject);

impl HeapSize for Paths<'_> {
    fn heap_size(&self, census: &mut Census) -> usize {
        self.0.repo_path.heap_size(census)
            + self.0.head_branch.heap_size(census)
            + self.0.previous_branch.heap_size(census)
            + self.0.default_branch.heap_size(census)
            + self.0.current_user_email.heap_size(census)
            + self.0.commit_author_filter.heap_size(census)
    }
}

#[cfg(test)]
mod tests {
    use std::path::PathBuf;
    use std::sync::Arc;

    use super::*;
    use crate::types::{CommitInfo, Signature, TagInfo, WorkingTreeStatus};

    fn signature() -> Signature {
        Signature {
            name: String::new(),
            email: String::new(),
        }
    }

    /// Long enough that no small-string optimisation could hide it inline,
    /// so a test asserting the bytes were charged is asserting something.
    const LONG_NAME: &str = "release/2026-08-a-tag-name-far-too-long-to-live-inline";

    fn project() -> GitProject {
        GitProject::empty_at(PathBuf::from("/repos/rgitui"))
    }

    fn node<'a>(nodes: &'a [rgitui_perf::CensusNode], path: &str) -> &'a rgitui_perf::CensusNode {
        nodes
            .iter()
            .find(|node| node.path == path)
            .unwrap_or_else(|| panic!("{path} is missing from the census"))
    }

    #[test]
    fn the_project_census_emits_one_node_per_measured_field() {
        let mut census = Census::new();
        census.enter("project", &CensusOf(&project()));

        let mut paths: Vec<String> = census
            .into_nodes()
            .into_iter()
            .map(|node| node.path)
            .collect();
        paths.sort();

        assert_eq!(
            paths,
            [
                "project",
                "project/branches",
                "project/commits",
                "project/paths",
                "project/remotes",
                "project/stashes",
                "project/status",
                "project/status_cache",
                "project/tags",
                "project/worktrees",
            ]
        );
    }

    #[test]
    fn refs_the_project_holds_are_charged_for_the_strings_they_own() {
        let mut project = project();
        project.tags = vec![TagInfo {
            name: LONG_NAME.to_string(),
            oid: git2::Oid::zero(),
            message: None,
        }];

        let mut census = Census::new();
        census.enter("project", &CensusOf(&project));
        let nodes = census.into_nodes();

        assert_eq!(node(&nodes, "project/tags").count, Some(1));
        assert!(
            node(&nodes, "project/tags").bytes >= LONG_NAME.len(),
            "the tag name is a heap allocation and has to be charged"
        );
    }

    #[test]
    fn the_status_cache_reports_the_worktrees_it_holds_status_for() {
        let project = project();
        if let Ok(mut cache) = project.worktree_status_cache.lock() {
            cache.insert(
                PathBuf::from("/repos/rgitui/worktrees/feature"),
                (7, WorkingTreeStatus::default()),
            );
        }

        let mut census = Census::new();
        census.enter("project", &CensusOf(&project));
        let nodes = census.into_nodes();

        assert_eq!(node(&nodes, "project/status_cache").count, Some(1));
        assert!(node(&nodes, "project/status_cache").bytes > 0);
    }

    #[test]
    fn a_snapshot_reached_twice_is_charged_to_the_first_path_only() {
        let mut project = project();
        project.recent_commits = Arc::new(vec![CommitInfo {
            oid: git2::Oid::zero(),
            short_id: "abc1234".to_string(),
            summary: LONG_NAME.to_string(),
            message: LONG_NAME.to_string(),
            author: signature(),
            committer: signature(),
            co_authors: Vec::new(),
            time: chrono::Utc::now(),
            parent_oids: Vec::new(),
            refs: Vec::new(),
            is_signed: false,
        }]);
        let shared = Arc::clone(&project.recent_commits);

        let mut census = Census::new();
        let first = census.enter("elsewhere", &shared);
        census.enter("project", &CensusOf(&project));
        let nodes = census.into_nodes();

        assert!(first > 0);
        assert_eq!(
            node(&nodes, "project/commits").bytes,
            0,
            "the view reached the snapshot first and was charged for it"
        );
        assert_eq!(
            node(&nodes, "project/commits").count,
            Some(1),
            "the population is still named, so the report can say where it went"
        );
    }

    /// Adapter that lets a bare `GitProject` be entered as a census scope; the
    /// app reaches [`GitProject::census`] through the workspace walk instead.
    struct CensusOf<'a>(&'a GitProject);

    impl HeapSize for CensusOf<'_> {
        fn heap_size(&self, census: &mut Census) -> usize {
            self.0.census(census)
        }
    }
}
