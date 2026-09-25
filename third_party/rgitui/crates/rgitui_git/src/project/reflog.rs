use anyhow::Result;
use chrono::{TimeZone, Utc};
use git2::Repository;
use std::path::Path;

/// A single reflog entry.
#[derive(Debug, Clone)]
pub struct ReflogEntryInfo {
    /// The new OID after the operation.
    pub new_oid: git2::Oid,
    /// The old OID before the operation (may be zero for initial entries).
    pub old_oid: git2::Oid,
    /// Short form of new OID.
    pub new_short_id: String,
    /// Short form of old OID (empty string if zero).
    pub old_short_id: String,
    /// Operation message (e.g., "commit: Add feature").
    pub message: Option<String>,
    /// Who performed the operation.
    pub committer: String,
    /// When the operation occurred.
    pub time: chrono::DateTime<Utc>,
}

/// Maximum number of reflog entries to return.
const MAX_REFLOG_ENTRIES: usize = 200;

/// Get reflog entries for a reference (typically "HEAD").
pub fn compute_reflog(repo_path: &Path, ref_name: &str) -> Result<Vec<ReflogEntryInfo>> {
    let repo = Repository::open(repo_path)?;
    let reflog = repo.reflog(ref_name)?;

    let mut entries = Vec::new();
    for entry in reflog.iter() {
        if entries.len() >= MAX_REFLOG_ENTRIES {
            break;
        }

        let new_oid = entry.id_new();
        let old_oid = entry.id_old();

        // Check for zero OID (initial entry or special cases)
        let zero_oid = git2::Oid::zero();
        let old_short_id = if old_oid == zero_oid {
            String::new()
        } else {
            format!("{:.7}", old_oid)
        };

        let committer_sig = entry.committer();
        let time = Utc
            .timestamp_opt(committer_sig.when().seconds(), 0)
            .single()
            .unwrap_or_else(Utc::now);

        entries.push(ReflogEntryInfo {
            new_oid,
            old_oid,
            new_short_id: format!("{:.7}", new_oid),
            old_short_id,
            message: entry.message().map(str::to_string),
            committer: committer_sig.name().unwrap_or("unknown").to_string(),
            time,
        });
    }

    // Reflog entries are returned newest-first, which is what we want
    Ok(entries)
}

use gpui::{AsyncApp, Context, Task, WeakEntity};

use super::GitProject;

impl GitProject {
    /// Get reflog entries for a reference.
    pub fn reflog(&self, ref_name: &str) -> Result<Vec<ReflogEntryInfo>> {
        compute_reflog(self.repo_path(), ref_name)
    }

    /// Get reflog entries asynchronously.
    pub fn reflog_async(
        &self,
        ref_name: String,
        cx: &mut Context<Self>,
    ) -> Task<Result<Vec<ReflogEntryInfo>>> {
        let repo_path = self.repo_path().to_path_buf();
        cx.spawn(async move |_this: WeakEntity<Self>, cx: &mut AsyncApp| {
            cx.background_executor()
                .spawn(async move { compute_reflog(&repo_path, &ref_name) })
                .await
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rgitui_test_support::TempRepo;
    use std::path::Path;

    #[test]
    fn reflog_returns_entries_for_head() {
        let repo = TempRepo::with_commits(3);
        let entries = compute_reflog(repo.path(), "HEAD").unwrap();
        // Each commit produces a reflog entry; 3 commits → at least 3 entries
        assert!(
            entries.len() >= 3,
            "expected ≥3 entries, got {}",
            entries.len()
        );
    }

    #[test]
    fn reflog_entries_have_short_ids() {
        let repo = TempRepo::with_commits(2);
        let entries = compute_reflog(repo.path(), "HEAD").unwrap();
        assert!(!entries.is_empty());
        let first = &entries[0];
        // new_short_id should be exactly 7 hex chars
        assert_eq!(first.new_short_id.len(), 7, "short id should be 7 chars");
    }

    #[test]
    fn reflog_initial_entry_has_empty_old_short_id() {
        let repo = TempRepo::with_commits(1);
        let entries = compute_reflog(repo.path(), "HEAD").unwrap();
        // The initial commit entry should have no old OID
        let last = entries.last().unwrap();
        assert_eq!(
            last.old_short_id, "",
            "initial reflog entry should have empty old_short_id"
        );
    }

    #[test]
    fn reflog_entries_newest_first() {
        let repo = TempRepo::with_commits(3);
        let entries = compute_reflog(repo.path(), "HEAD").unwrap();
        // The newest entry should point to the same OID as HEAD
        assert_eq!(
            entries[0].new_oid,
            repo.head_oid(),
            "first entry should be newest (HEAD)"
        );
    }

    #[test]
    fn reflog_entry_committer_name() {
        let repo = TempRepo::with_commits(1);
        let entries = compute_reflog(repo.path(), "HEAD").unwrap();
        assert!(!entries.is_empty());
        assert_eq!(entries[0].committer, TempRepo::AUTHOR_NAME);
    }

    #[test]
    fn reflog_entry_has_message() {
        let repo = TempRepo::with_commits(2);
        let entries = compute_reflog(repo.path(), "HEAD").unwrap();
        // Latest entry should have a message
        let first = &entries[0];
        assert!(
            first.message.is_some(),
            "reflog entry should have a message"
        );
        let msg = first.message.as_deref().unwrap_or("");
        assert!(
            msg.contains("commit"),
            "message should mention commit, got: {:?}",
            msg
        );
    }

    #[test]
    fn reflog_caps_at_max_entries() {
        // Verify the function doesn't panic and returns ≤ MAX_REFLOG_ENTRIES
        let repo = TempRepo::with_commits(5);
        let entries = compute_reflog(repo.path(), "HEAD").unwrap();
        assert!(entries.len() <= 200);
    }

    #[test]
    fn reflog_unknown_ref_returns_empty_or_err() {
        let repo = TempRepo::with_commits(1);
        // git2 may return Ok([]) or Err for unknown refs; both are acceptable
        if let Ok(entries) = compute_reflog(repo.path(), "refs/heads/nonexistent-branch-zz99") {
            assert!(entries.is_empty(), "unknown ref should yield no entries");
        }
    }

    #[test]
    fn reflog_err_on_bad_repo_path() {
        let result = compute_reflog(Path::new("/no/such/repo"), "HEAD");
        assert!(result.is_err());
    }
}
