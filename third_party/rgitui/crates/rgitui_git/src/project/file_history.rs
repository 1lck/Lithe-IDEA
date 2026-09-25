use anyhow::Result;
use chrono::{TimeZone, Utc};
use git2::Repository;
use std::path::Path;

use crate::types::{CommitInfo, Signature};

use super::refresh::clean_co_author_lines;

/// Maximum number of commits to return for file history.
const MAX_FILE_HISTORY: usize = 100;

/// Get commit history for a specific file.
///
/// Uses `git log -- <path>` which leverages git's built-in pathspec
/// optimization (tree-diff pruning) and is orders of magnitude faster
/// than walking all commits and diffing each tree manually.
pub fn compute_file_history(
    repo_path: &Path,
    file_path: &Path,
    limit: usize,
) -> Result<Vec<CommitInfo>> {
    compute_file_history_at(repo_path, file_path, limit, None)
}

/// Get commit history for a file, optionally stopping at a selected commit.
///
/// Supplying a start commit keeps history consistent with a commit diff instead
/// of accidentally showing changes that happened later on the current branch.
pub fn compute_file_history_at(
    repo_path: &Path,
    file_path: &Path,
    limit: usize,
    start_oid: Option<git2::Oid>,
) -> Result<Vec<CommitInfo>> {
    let limit = limit.min(MAX_FILE_HISTORY);
    let file_str = file_path.to_string_lossy();

    let mut args = vec![
        "log".to_string(),
        "--format=%H".to_string(),
        format!("-{}", limit),
    ];
    if let Some(oid) = start_oid {
        args.push(oid.to_string());
    }
    args.push("--".to_string());
    args.push(file_str.into_owned());

    let output = super::git_command()
        .args(&args)
        .current_dir(repo_path)
        .output()?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!("git log failed: {}", stderr.trim());
    }

    let repo = Repository::open(repo_path)?;
    let stdout = String::from_utf8_lossy(&output.stdout);
    let mut commits = Vec::new();

    for line in stdout.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let oid = git2::Oid::from_str(line)?;
        let commit = repo.find_commit(oid)?;

        let author = commit.author();
        let committer = commit.committer();
        let time = Utc.timestamp_opt(commit.time().seconds(), 0).single();

        let raw_message = commit.message().unwrap_or("").to_string();
        let message = clean_co_author_lines(&raw_message);

        commits.push(CommitInfo {
            oid,
            short_id: format!("{:.7}", oid),
            summary: commit.summary().unwrap_or("").to_string(),
            message,
            author: Signature {
                name: author.name().unwrap_or("").to_string(),
                email: author.email().unwrap_or("").to_string(),
            },
            committer: Signature {
                name: committer.name().unwrap_or("").to_string(),
                email: committer.email().unwrap_or("").to_string(),
            },
            co_authors: Vec::new(),
            time: time.unwrap_or_else(Utc::now),
            parent_oids: commit.parent_ids().collect(),
            refs: Vec::new(),
            is_signed: false,
        });
    }

    Ok(commits)
}

use gpui::{AsyncApp, Context, Task, WeakEntity};

use super::GitProject;

impl GitProject {
    /// Get commit history for a specific file.
    pub fn file_history(&self, file_path: &Path, limit: usize) -> Result<Vec<CommitInfo>> {
        compute_file_history(self.repo_path(), file_path, limit)
    }

    /// Get commit history for a file asynchronously.
    pub fn file_history_async(
        &self,
        file_path: &Path,
        limit: usize,
        cx: &mut Context<Self>,
    ) -> Task<Result<Vec<CommitInfo>>> {
        let repo_path = self.repo_path().to_path_buf();
        let file_path = file_path.to_path_buf();
        cx.spawn(async move |_this: WeakEntity<Self>, cx: &mut AsyncApp| {
            cx.background_executor()
                .spawn(async move { compute_file_history(&repo_path, &file_path, limit) })
                .await
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rgitui_test_support::TempRepo;
    use std::path::Path;

    // Build a repo where:
    // - "tracked.txt" is created in commit 1, modified in commit 3
    // - "other.txt"   is created in commit 2
    fn make_multi_file_repo() -> TempRepo {
        let repo = TempRepo::init();
        repo.commit_file("tracked.txt", "hello\n", "add tracked.txt");
        repo.commit_file("other.txt", "world\n", "add other.txt");
        repo.commit_file("tracked.txt", "hello updated\n", "modify tracked.txt");
        repo
    }

    #[test]
    fn file_history_returns_only_touching_commits() {
        let repo = make_multi_file_repo();
        let entries = compute_file_history(repo.path(), Path::new("tracked.txt"), 100).unwrap();
        // commit 1 (add) + commit 3 (modify) touch tracked.txt; commit 2 does not
        assert_eq!(entries.len(), 2, "expected 2 commits for tracked.txt");
    }

    #[test]
    fn file_history_unrelated_file_excluded() {
        let repo = make_multi_file_repo();
        let entries = compute_file_history(repo.path(), Path::new("other.txt"), 100).unwrap();
        // Only commit 2 touches other.txt
        assert_eq!(entries.len(), 1, "expected 1 commit for other.txt");
    }

    #[test]
    fn file_history_latest_commit_first() {
        let repo = make_multi_file_repo();
        let entries = compute_file_history(repo.path(), Path::new("tracked.txt"), 100).unwrap();
        // The most recent touching commit is commit 3 ("modify tracked.txt")
        assert!(
            entries[0].summary.contains("modify"),
            "first entry should be the latest modification, got: {:?}",
            entries[0].summary
        );
    }

    #[test]
    fn file_history_at_commit_excludes_later_changes() {
        let repo = make_multi_file_repo();
        let before_latest = repo.repo().revparse_single("HEAD~1").unwrap().id();

        let entries = compute_file_history_at(
            repo.path(),
            Path::new("tracked.txt"),
            100,
            Some(before_latest),
        )
        .unwrap();

        assert_eq!(entries.len(), 1);
        assert!(entries[0].summary.contains("add tracked"));
    }

    #[test]
    fn file_history_limit_respected() {
        let repo = make_multi_file_repo();
        // tracked.txt has 2 touching commits; requesting limit=1 should return 1
        let entries = compute_file_history(repo.path(), Path::new("tracked.txt"), 1).unwrap();
        assert_eq!(entries.len(), 1);
    }

    #[test]
    fn file_history_author_populated() {
        let repo = make_multi_file_repo();
        let entries = compute_file_history(repo.path(), Path::new("tracked.txt"), 100).unwrap();
        assert!(!entries.is_empty());
        assert_eq!(entries[0].author.name, TempRepo::AUTHOR_NAME);
        assert_eq!(entries[0].author.email, TempRepo::AUTHOR_EMAIL);
    }

    #[test]
    fn file_history_short_id_is_seven_chars() {
        let repo = make_multi_file_repo();
        let entries = compute_file_history(repo.path(), Path::new("tracked.txt"), 100).unwrap();
        for entry in &entries {
            assert_eq!(
                entry.short_id.len(),
                7,
                "short_id should be 7 chars, got {:?}",
                entry.short_id
            );
        }
    }

    #[test]
    fn file_history_nonexistent_file_returns_empty() {
        let repo = make_multi_file_repo();
        let entries =
            compute_file_history(repo.path(), Path::new("does_not_exist.txt"), 100).unwrap();
        assert!(entries.is_empty(), "unknown file should yield 0 entries");
    }

    #[test]
    fn file_history_err_on_bad_repo() {
        let result = compute_file_history(Path::new("/no/such/repo"), Path::new("file.txt"), 10);
        assert!(result.is_err());
    }
}
