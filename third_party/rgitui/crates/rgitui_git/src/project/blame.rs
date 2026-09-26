use anyhow::Result;
use chrono::{DateTime, TimeZone, Utc};
use std::path::Path;

/// A single blame annotation for a line or range of lines.
#[derive(Debug, Clone)]
pub struct BlameEntry {
    pub oid: git2::Oid,
    pub short_id: String,
    pub author: String,
    pub email: String,
    pub time: DateTime<Utc>,
    pub start_line: usize,
    pub line_count: usize,
}

/// A single line with its blame annotation.
#[derive(Debug, Clone)]
pub struct BlameLine {
    pub line_no: usize,
    pub content: String,
    pub entry: BlameEntry,
}

/// Compute blame for a file at a given commit (or HEAD if None).
///
/// Uses `git blame --porcelain` which is significantly faster than
/// libgit2's blame implementation.
pub fn compute_blame(
    repo_path: &Path,
    file_path: &Path,
    commit_oid: Option<git2::Oid>,
) -> Result<Vec<BlameLine>> {
    let blame_timer = std::time::Instant::now();
    log::debug!("compute_blame: path={}", file_path.display());
    let file_str = file_path.to_string_lossy();
    let mut args = vec!["blame", "--porcelain"];
    let oid_str = commit_oid.map(|o| o.to_string());
    if let Some(ref s) = oid_str {
        args.push(s);
    }
    args.push("--");
    args.push(&file_str);

    let output = super::git_command()
        .args(&args)
        .current_dir(repo_path)
        .output()?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!("git blame failed: {}", stderr.trim());
    }

    let result = parse_porcelain_blame(&String::from_utf8_lossy(&output.stdout));
    if let Ok(ref lines) = result {
        log::debug!(
            "compute_blame complete in {:?}: {} lines",
            blame_timer.elapsed(),
            lines.len()
        );
    }
    result
}

/// Parse `git blame --porcelain` output into BlameLine entries.
fn parse_porcelain_blame(output: &str) -> Result<Vec<BlameLine>> {
    use std::collections::HashMap;

    // Cache commit metadata keyed by OID string.
    struct CommitMeta {
        author: String,
        email: String,
        time: DateTime<Utc>,
    }
    let mut meta_cache: HashMap<String, CommitMeta> = HashMap::new();

    let mut result = Vec::new();
    let mut lines = output.lines().peekable();

    while let Some(header) = lines.next() {
        // Header line: "<oid> <orig_line> <final_line> [<group_count>]"
        let parts: Vec<&str> = header.split_whitespace().collect();
        if parts.len() < 3 {
            continue;
        }
        let oid_str = parts[0];
        let final_line: usize = parts[2].parse().unwrap_or(1);

        // Read metadata lines until the content line (starts with \t).
        let mut author = String::new();
        let mut email = String::new();
        let mut timestamp: i64 = 0;
        let mut content_line = String::new();

        for line in lines.by_ref() {
            if let Some(stripped) = line.strip_prefix('\t') {
                content_line = stripped.to_string();
                break;
            }
            if let Some(val) = line.strip_prefix("author ") {
                author = val.to_string();
            } else if let Some(val) = line.strip_prefix("author-mail <") {
                email = val.trim_end_matches('>').to_string();
            } else if let Some(val) = line.strip_prefix("author-time ") {
                timestamp = val.parse().unwrap_or(0);
            }
        }

        // Use cached metadata for repeated OIDs (porcelain only emits
        // full metadata the first time an OID appears).
        if !author.is_empty() {
            meta_cache.insert(
                oid_str.to_string(),
                CommitMeta {
                    author: author.clone(),
                    email: email.clone(),
                    time: Utc.timestamp_opt(timestamp, 0).single().unwrap_or_default(),
                },
            );
        }

        let meta = meta_cache.get(oid_str);
        let (a, e, t) = match meta {
            Some(m) => (m.author.clone(), m.email.clone(), m.time),
            None => (String::new(), String::new(), Utc::now()),
        };

        let oid = git2::Oid::from_str(oid_str).unwrap_or(git2::Oid::zero());
        let short_id = oid_str[..7.min(oid_str.len())].to_string();

        result.push(BlameLine {
            line_no: final_line,
            content: content_line,
            entry: BlameEntry {
                oid,
                short_id,
                author: a,
                email: e,
                time: t,
                start_line: final_line,
                line_count: 1,
            },
        });
    }

    Ok(result)
}

use gpui::{AsyncApp, Context, Task, WeakEntity};

use super::GitProject;

impl GitProject {
    /// Compute blame for a file, optionally at a specific commit.
    pub fn blame_file(
        &self,
        file_path: &Path,
        commit_oid: Option<git2::Oid>,
    ) -> Result<Vec<BlameLine>> {
        compute_blame(self.repo_path(), file_path, commit_oid)
    }

    /// Compute blame asynchronously on a background thread.
    pub fn blame_file_async(
        &self,
        file_path: &Path,
        commit_oid: Option<git2::Oid>,
        cx: &mut Context<Self>,
    ) -> Task<Result<Vec<BlameLine>>> {
        let repo_path = self.repo_path().to_path_buf();
        let file_path = file_path.to_path_buf();
        cx.spawn(async move |_this: WeakEntity<Self>, cx: &mut AsyncApp| {
            cx.background_executor()
                .spawn(async move { compute_blame(&repo_path, &file_path, commit_oid) })
                .await
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use rgitui_test_support::TempRepo;
    use std::path::Path;

    /// A repo with two commits touching the same file, by different authors so
    /// blame has something to attribute:
    /// commit A (Alice): adds "line1\nline2\n"
    /// commit B (Bob):   appends "line3\n"
    fn make_blame_repo() -> (TempRepo, git2::Oid, git2::Oid) {
        let repo = TempRepo::init();
        let oid_a = repo.commit_file_as(
            "Alice",
            "alice@example.com",
            "code.txt",
            "line1\nline2\n",
            "initial commit",
        );
        let oid_b = repo.commit_file_as(
            "Bob",
            "bob@example.com",
            "code.txt",
            "line1\nline2\nline3\n",
            "add line3",
        );
        (repo, oid_a, oid_b)
    }

    #[test]
    fn blame_head_returns_all_lines() {
        let (repo, _a, _b) = make_blame_repo();
        let lines = compute_blame(repo.path(), Path::new("code.txt"), None).unwrap();
        assert_eq!(
            lines.len(),
            3,
            "expected 3 blame lines, got {}",
            lines.len()
        );
    }

    #[test]
    fn blame_line_numbers_are_one_indexed() {
        let (repo, _a, _b) = make_blame_repo();
        let lines = compute_blame(repo.path(), Path::new("code.txt"), None).unwrap();
        for (i, bl) in lines.iter().enumerate() {
            assert_eq!(bl.line_no, i + 1, "line_no should be {}", i + 1);
        }
    }

    #[test]
    fn blame_line_contents_match_file() {
        let (repo, _a, _b) = make_blame_repo();
        let lines = compute_blame(repo.path(), Path::new("code.txt"), None).unwrap();
        assert_eq!(lines[0].content, "line1");
        assert_eq!(lines[1].content, "line2");
        assert_eq!(lines[2].content, "line3");
    }

    #[test]
    fn blame_first_two_lines_authored_by_alice() {
        let (repo, _a, _b) = make_blame_repo();
        let lines = compute_blame(repo.path(), Path::new("code.txt"), None).unwrap();
        assert_eq!(lines[0].entry.author, "Alice");
        assert_eq!(lines[1].entry.author, "Alice");
    }

    #[test]
    fn blame_last_line_authored_by_bob() {
        let (repo, _a, _b) = make_blame_repo();
        let lines = compute_blame(repo.path(), Path::new("code.txt"), None).unwrap();
        assert_eq!(lines[2].entry.author, "Bob");
        assert_eq!(lines[2].entry.email, "bob@example.com");
    }

    #[test]
    fn blame_short_ids_are_seven_chars() {
        let (repo, _a, _b) = make_blame_repo();
        let lines = compute_blame(repo.path(), Path::new("code.txt"), None).unwrap();
        for bl in &lines {
            assert_eq!(
                bl.entry.short_id.len(),
                7,
                "short_id should be 7 chars, got {:?}",
                bl.entry.short_id
            );
        }
    }

    #[test]
    fn blame_at_commit_a_shows_only_two_lines() {
        let (repo, oid_a, _b) = make_blame_repo();
        let lines = compute_blame(repo.path(), Path::new("code.txt"), Some(oid_a)).unwrap();
        // At commit A the file only had 2 lines
        assert_eq!(lines.len(), 2, "commit A had 2 lines, got {}", lines.len());
    }

    #[test]
    fn blame_at_commit_a_all_lines_attributed_to_alice() {
        let (repo, oid_a, _b) = make_blame_repo();
        let lines = compute_blame(repo.path(), Path::new("code.txt"), Some(oid_a)).unwrap();
        for bl in &lines {
            assert_eq!(
                bl.entry.author, "Alice",
                "all lines at commit A should be Alice"
            );
        }
    }

    #[test]
    fn blame_oid_matches_commit() {
        let (repo, _a, oid_b) = make_blame_repo();
        let lines = compute_blame(repo.path(), Path::new("code.txt"), None).unwrap();
        // line3 was added in commit B
        assert_eq!(lines[2].entry.oid, oid_b);
    }

    #[test]
    fn blame_time_is_nonzero() {
        let (repo, _a, _b) = make_blame_repo();
        let lines = compute_blame(repo.path(), Path::new("code.txt"), None).unwrap();
        for bl in &lines {
            assert!(
                bl.entry.time.timestamp() > 0,
                "time should be nonzero for line {}",
                bl.line_no
            );
        }
    }

    #[test]
    fn blame_bad_repo_path_returns_error() {
        let result = compute_blame(Path::new("/nonexistent/path"), Path::new("code.txt"), None);
        assert!(result.is_err(), "expected error for bad repo path");
    }

    #[test]
    fn blame_missing_file_returns_error() {
        let (repo, _a, _b) = make_blame_repo();
        let result = compute_blame(repo.path(), Path::new("does_not_exist.txt"), None);
        assert!(result.is_err(), "expected error for nonexistent file");
    }
}
