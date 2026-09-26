use super::GitProject;
use anyhow::{Context as AnyhowContext, Result};
use gpui::{AsyncApp, Context, Task, WeakEntity};
use std::path::Path;

/// A single entry in the bisect log.
#[derive(Debug, Clone)]
pub struct BisectLogEntry {
    /// The decision type: good, bad, skip, or start.
    pub decision: BisectDecision,
    /// The commit SHA (short form).
    pub sha: String,
    /// The commit subject message (if available).
    pub subject: Option<String>,
}

/// The type of bisect decision.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BisectDecision {
    Start,
    Good,
    Bad,
    Skip,
}

/// Parse a single line from `git bisect log`.
/// Lines look like:
///   # bisect start
///   # good: abc1234 subject line
///   # bad: def5678 another subject
///   # skip: 9123456 skipped commit
fn parse_bisect_line(line: &str) -> Option<BisectLogEntry> {
    let line = line.trim();
    if !line.starts_with('#') {
        return None;
    }
    let rest = line.trim_start_matches('#').trim();

    if rest == "bisect start" {
        return Some(BisectLogEntry {
            decision: BisectDecision::Start,
            sha: String::new(),
            subject: None,
        });
    }

    let (decision_str, after_sha) = rest.split_once(':')?;
    let after_sha = after_sha.trim();

    let decision = match decision_str {
        "good" => BisectDecision::Good,
        "bad" => BisectDecision::Bad,
        "skip" => BisectDecision::Skip,
        _ => return None,
    };

    // Format: "<sha> <subject>" or just "<sha>"
    let parts: Vec<&str> = after_sha.splitn(2, ' ').collect();
    let sha = parts.first().unwrap_or(&"").to_string();
    let subject = parts.get(1).map(|s| s.to_string());

    Some(BisectLogEntry {
        decision,
        sha,
        subject,
    })
}

/// Compute bisect log entries from the repository.
pub fn compute_bisect_log(repo_path: &Path) -> Result<Vec<BisectLogEntry>> {
    let output = super::git_command()
        .current_dir(repo_path)
        .args(["bisect", "log"])
        .output()
        .context("Failed to execute git bisect log")?;

    if !output.status.success() {
        // If bisect isn't in progress, git bisect log may fail
        let stderr = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!("git bisect log failed: {}", stderr.trim());
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let entries: Vec<BisectLogEntry> = stdout.lines().filter_map(parse_bisect_line).collect();

    Ok(entries)
}

/// Check if bisect is currently in progress.
pub fn is_bisect_in_progress(repo_path: &Path) -> bool {
    let output = super::git_command()
        .current_dir(repo_path)
        .args(["bisect", "status"])
        .output();

    match output {
        Ok(o) if o.status.success() => {
            let stdout = String::from_utf8_lossy(&o.stdout);
            // status output contains "bisecting" when active
            stdout.contains("bisecting")
        }
        _ => false,
    }
}

impl GitProject {
    /// Get bisect log entries for the repository.
    pub fn bisect_log(&self) -> Result<Vec<BisectLogEntry>> {
        compute_bisect_log(self.repo_path())
    }

    /// Get bisect log entries asynchronously.
    pub fn bisect_log_async(&self, cx: &mut Context<Self>) -> Task<Result<Vec<BisectLogEntry>>> {
        let repo_path = self.repo_path().to_path_buf();
        cx.spawn(async move |_this: WeakEntity<Self>, cx: &mut AsyncApp| {
            cx.background_executor()
                .spawn(async move { compute_bisect_log(&repo_path) })
                .await
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_bisect_start() {
        let entry = parse_bisect_line("# bisect start").unwrap();
        assert_eq!(entry.decision, BisectDecision::Start);
        assert!(entry.sha.is_empty());
    }

    #[test]
    fn test_parse_good_entry() {
        let entry = parse_bisect_line("# good: abc1234 fix the bug").unwrap();
        assert_eq!(entry.decision, BisectDecision::Good);
        assert_eq!(entry.sha, "abc1234");
        assert_eq!(entry.subject, Some("fix the bug".to_string()));
    }

    #[test]
    fn test_parse_bad_entry() {
        let entry = parse_bisect_line("# bad: def5678 break everything").unwrap();
        assert_eq!(entry.decision, BisectDecision::Bad);
        assert_eq!(entry.sha, "def5678");
        assert_eq!(entry.subject, Some("break everything".to_string()));
    }

    #[test]
    fn test_parse_skip_entry() {
        let entry = parse_bisect_line("# skip: 9123456 skip this commit").unwrap();
        assert_eq!(entry.decision, BisectDecision::Skip);
        assert_eq!(entry.sha, "9123456");
    }

    #[test]
    fn test_ignore_non_decision_lines() {
        assert!(parse_bisect_line("not a comment").is_none());
        assert!(parse_bisect_line("# some other comment").is_none());
        assert!(parse_bisect_line("").is_none());
    }
}
