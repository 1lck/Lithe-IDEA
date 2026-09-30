//! Git grep — global content search.

use anyhow::{Context as _, Result};
use gpui::{AsyncApp, Context, Task, WeakEntity};
use std::path::{Path, PathBuf};

use super::GitProject;
use crate::types::SearchResult;

impl GitProject {
    /// Run `git grep` synchronously.
    pub fn git_grep(&self, pattern: &str) -> Result<Vec<SearchResult>> {
        git_grep(self.repo_path(), pattern)
    }

    /// Run `git grep` asynchronously.
    pub fn git_grep_async(
        &self,
        pattern: String,
        cx: &mut Context<Self>,
    ) -> Task<Result<Vec<SearchResult>>> {
        let repo_path = self.repo_path().to_path_buf();
        cx.spawn(async move |_this: WeakEntity<Self>, cx: &mut AsyncApp| {
            cx.background_executor()
                .spawn(async move { git_grep(&repo_path, &pattern) })
                .await
        })
    }
}

/// Run `git grep` in the given repository.
pub fn git_grep(repo_path: &Path, pattern: &str) -> Result<Vec<SearchResult>> {
    let output = super::git_command()
        .current_dir(repo_path)
        // `-e` keeps a pattern starting with `-` from being parsed as an option
        // (searching for "-v" or "-f/etc/passwd" would otherwise change what the
        // command does); the trailing `--` closes the empty pathspec list.
        .args(["grep", "-n", "-e", pattern, "--"])
        .output()
        .context("Failed to execute git grep")?;

    if !output.status.success() {
        // Exit code 1 means "no matches" — not an error, return empty.
        if output.status.code() == Some(1) {
            return Ok(Vec::new());
        }
        let stderr = String::from_utf8_lossy(&output.stderr);
        anyhow::bail!("git grep failed: {}", stderr.trim());
    }

    let raw = String::from_utf8_lossy(&output.stdout);
    let results = parse_grep_output(&raw);
    Ok(results)
}

/// Parse git grep output in the format "path:lineno:content".
///
/// Path may contain colons (e.g. Windows paths like "C:/foo:bar/file.rs"), and
/// content may also contain colons (e.g. URLs). We scan colons from right to left:
///   - If the segment after a colon starts with a digit, it's the content start.
///     Skip it and keep looking.
///   - If the segment after a colon starts with a NON-digit character, that's the
///     content start. Then find the previous purely-digit segment before it to
///     get the line number.
///
/// This correctly handles:
///   - Standard: "src/main.rs:10:fn main() {" → path="src/main.rs", lineno=10, content="fn main() {"
///   - URLs: "file.rs:7:visit https://example.com" → path="file.rs", lineno=7
///   - Colons in path: "C:/foo:bar/file.rs:12:let x" → path="C:/foo:bar/file.rs", lineno=12
fn parse_grep_output(raw: &str) -> Vec<SearchResult> {
    let mut results = Vec::new();
    for line in raw.lines() {
        let bytes = line.as_bytes();

        // Find all colon byte positions.
        let colon_positions: Vec<usize> = (0..bytes.len()).filter(|&i| bytes[i] == b':').collect();

        if colon_positions.len() < 2 {
            // Malformed: need at least 2 colons (path:lineno:content).
            continue;
        }

        // Find the content start (first colon from the right where content doesn't
        // start with a purely-digit segment — this rules out URL ports, etc. in content).
        let content_colon_idx = 'search: {
            for &colon_pos in colon_positions.iter().rev() {
                let after = &line[colon_pos + 1..];
                let after_first = after.chars().next();

                if after.is_empty() {
                    // Empty after colon — this could be the lineno/content separator.
                    // But we still want content to be non-digit. Break only if non-digit.
                    break 'search colon_pos;
                }

                let after_starts_with_digit =
                    after_first.map(|c| c.is_ascii_digit()).unwrap_or(false);

                // Also detect URL patterns like "https:/" or "server.com:8080/".
                // If content starts with '/' and the segment before this colon is purely
                // digits, the '/' is a URL path separator — skip and keep looking left.
                let after_starts_with_slash = after_first == Some('/');
                // URL pattern detection: content starts with '/'.
                // Skip this colon (keep looking left) only if it's a URL component:
                // - "https:/" pattern: prev char is '/' and char-2-back is letter (scheme)
                // - "8080:/" pattern: prev char is digit (port number)
                // In all other cases (including '/'-prefixed content that's not a URL),
                // treat '/' as the content start and break.
                let is_url_pattern = after_starts_with_slash
                    && colon_pos >= 2
                    && (bytes.get(colon_pos - 1) == Some(&b'/')
                        || bytes
                            .get(colon_pos - 1)
                            .map(u8::is_ascii_digit)
                            .unwrap_or(false)
                        || bytes
                            .get(colon_pos - 2)
                            .map(u8::is_ascii_alphabetic)
                            .unwrap_or(false));

                if is_url_pattern {
                    // This colon is a URL component (e.g. "https:/" or ":8080/").
                    // The real content colon is to the left.
                    continue;
                }

                if !after_starts_with_digit {
                    // Non-digit after: check if the segment between the previous colon
                    // and this colon is purely digits.
                    if let Some(idx) = colon_positions.iter().position(|&p| p == colon_pos) {
                        if idx > 0 {
                            let prev_colon = colon_positions[idx - 1];
                            let between = &line[prev_colon + 1..colon_pos];
                            if between.chars().all(|c| c.is_ascii_digit()) {
                                // between is purely digits → this IS the lineno/content separator.
                                break 'search colon_pos;
                            }
                            // between has non-digits: not the lineno/content separator.
                            // Keep looking for a better colon to the left.
                            continue;
                        }
                        // idx == 0: first colon → this is the path/lineno boundary.
                        break 'search colon_pos;
                    }
                    // colon_positions position lookup failed — shouldn't happen.
                    continue;
                }

                // Content starts with a digit → might be part of lineno, keep looking left.
                if let Some(idx) = colon_positions.iter().position(|&p| p == colon_pos) {
                    if idx > 0 {
                        let prev_colon = colon_positions[idx - 1];
                        let between = &line[prev_colon + 1..colon_pos];
                        if between.chars().all(|c| c.is_ascii_digit()) {
                            // Previous segment is purely digits → this is part of the path
                            // or lineno, not the content. Skip and keep looking left.
                            continue;
                        }
                    }
                }
                // Content starts with digit but previous segment not purely digits →
                // this IS the lineno/content boundary.
                break 'search colon_pos;
            }
            unreachable!("colon_positions.len() >= 2: for loop always breaks via 'break search'")
        };

        // Fallback for malformed input: if rank==0 (no valid separator found),
        // fall back to the old simple split: first colon=path, second colon=lineno/content.
        if colon_positions.iter().position(|&p| p == content_colon_idx) == Some(0) {
            // No valid content separator found. Fall back to simple split.
            let Some((file_part, rest)) = line.split_once(':') else {
                continue;
            };
            let path = PathBuf::from(file_part);
            let Some((line_str, content)) = rest.split_once(':') else {
                // Malformed in fallback too — skip.
                continue;
            };
            let line_number = line_str.parse::<usize>().unwrap_or(1);
            results.push(SearchResult {
                path,
                line_number,
                content: content.to_string(),
            });
            continue;
        }

        // content_start is the character after content_colon_idx.
        let content_start = content_colon_idx + 1;

        let content_colon_rank = colon_positions
            .iter()
            .position(|&p| p == content_colon_idx)
            .expect("content_colon_idx is from colon_positions");

        if content_colon_rank == 0 {
            // No colon to the left of content colon — malformed, skip.
            continue;
        }

        // Lineno is always the segment directly before the content colon.
        // In git grep output "path:lineno:content", this is always the lineno.
        // We don't need to verify it's digits — git always emits digits here.
        let lineno_seg_start = colon_positions[content_colon_rank - 1] + 1;
        let lineno_seg_end = content_colon_idx;

        // Path ends at the colon before the lineno digits.
        let path_end = colon_positions[content_colon_rank - 1];

        let lineno_str = &line[lineno_seg_start..lineno_seg_end];
        let path = &line[..path_end];
        let content = &line[content_start..];
        let line_number = lineno_str.parse::<usize>().unwrap_or(1);

        results.push(SearchResult {
            path: PathBuf::from(path),
            line_number,
            content: content.to_string(),
        });
    }
    results
}

#[cfg(test)]
mod tests {
    use super::*;
    use rgitui_test_support::TempRepo;

    // Unit tests for parse_grep_output — no git repo required.
    #[test]
    fn parse_grep_output_normal() {
        let raw = "src/main.rs:10:fn main() {";
        let results = parse_grep_output(raw);
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].path, std::path::PathBuf::from("src/main.rs"));
        assert_eq!(results[0].line_number, 10);
        assert_eq!(results[0].content, "fn main() {");
    }

    #[test]
    fn parse_grep_output_path_with_single_colon() {
        // Filename contains a colon (valid on most filesystems).
        let raw = "src/foo:bar.rs:5:let x = 1;";
        let results = parse_grep_output(raw);
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].path, std::path::PathBuf::from("src/foo:bar.rs"));
        assert_eq!(results[0].line_number, 5);
        assert_eq!(results[0].content, "let x = 1;");
    }

    #[test]
    fn parse_grep_output_path_with_multiple_colons() {
        // Multiple path segments containing colons.
        let raw = "a:b:c:42:hello world";
        let results = parse_grep_output(raw);
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].path, std::path::PathBuf::from("a:b:c"));
        assert_eq!(results[0].line_number, 42);
        assert_eq!(results[0].content, "hello world");
    }

    #[test]
    fn parse_grep_output_content_with_colon() {
        // Content contains URLs with colons (e.g. https://).
        let raw = "file.rs:7:visit https://example.com for more";
        let results = parse_grep_output(raw);
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].path, std::path::PathBuf::from("file.rs"));
        assert_eq!(results[0].line_number, 7);
        assert_eq!(results[0].content, "visit https://example.com for more");
    }

    #[test]
    fn parse_grep_output_multiple_lines() {
        let raw = "a.rs:1:first\nb.rs:2:second\nc.rs:3:third";
        let results = parse_grep_output(raw);
        assert_eq!(results.len(), 3);
        assert_eq!(results[0].path, std::path::PathBuf::from("a.rs"));
        assert_eq!(results[0].line_number, 1);
        assert_eq!(results[0].content, "first");
        assert_eq!(results[1].path, std::path::PathBuf::from("b.rs"));
        assert_eq!(results[1].line_number, 2);
        assert_eq!(results[1].content, "second");
        assert_eq!(results[2].path, std::path::PathBuf::from("c.rs"));
        assert_eq!(results[2].line_number, 3);
        assert_eq!(results[2].content, "third");
    }

    #[test]
    fn parse_grep_output_empty_content() {
        let raw = "main.rs:5:";
        let results = parse_grep_output(raw);
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].line_number, 5);
        assert_eq!(results[0].content, "");
    }

    #[test]
    fn parse_grep_output_non_numeric_lineno_falls_back_to_one() {
        // "abc" is not a valid line number → fallback to 1.
        let raw = "main.rs:abc:content";
        let results = parse_grep_output(raw);
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].path, std::path::PathBuf::from("main.rs"));
        assert_eq!(results[0].line_number, 1);
        assert_eq!(results[0].content, "content");
    }

    #[test]
    fn parse_grep_output_no_colon_skipped() {
        // Line with fewer than 2 colons — malformed, skip.
        let raw = "main.rs no colon here";
        let results = parse_grep_output(raw);
        assert!(results.is_empty());
    }

    #[test]
    fn parse_grep_output_only_path_and_lineno() {
        // Path:lineno with empty content.
        let raw = "main.rs:5:";
        let results = parse_grep_output(raw);
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].path, std::path::PathBuf::from("main.rs"));
        assert_eq!(results[0].line_number, 5);
        assert_eq!(results[0].content, "");
    }

    #[test]
    fn parse_grep_output_windows_style_path() {
        // Windows path with drive letter and colon in a path segment.
        let raw = "C:/Users/foo:bar/src/main.rs:12:let x = 1;";
        let results = parse_grep_output(raw);
        assert_eq!(results.len(), 1);
        assert_eq!(
            results[0].path,
            std::path::PathBuf::from("C:/Users/foo:bar/src/main.rs")
        );
        assert_eq!(results[0].line_number, 12);
        assert_eq!(results[0].content, "let x = 1;");
    }

    #[test]
    fn parse_grep_output_content_with_multiple_colons() {
        // Multiple colons in content (struct literals, JSON, etc.).
        let raw = "config.rs:3:let cfg = Config { port: 8080, host: \"localhost\" };";
        let results = parse_grep_output(raw);
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].path, std::path::PathBuf::from("config.rs"));
        assert_eq!(results[0].line_number, 3);
        assert_eq!(
            results[0].content,
            "let cfg = Config { port: 8080, host: \"localhost\" };"
        );
    }

    #[test]
    fn parse_grep_output_malformed_fallback_simple_split() {
        // When every segment before the last looks non-numeric (no purely-digit
        // segment found), the content colon lands at position 0 in the main
        // loop. The fallback does a simple split: first ':' = path, second ':'
        // = lineno/content. For "foo:bar:baz": fallback splits "foo"/"bar:baz",
        // then "bar"/"baz" → path="foo", line=1 (non-numeric), content="baz".
        let raw = "foo:bar:baz";
        let results = parse_grep_output(raw);
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].path, std::path::PathBuf::from("foo"));
        assert_eq!(results[0].line_number, 1); // "bar" is not numeric → falls back to 1
        assert_eq!(results[0].content, "baz"); // second split gives "bar"/"baz"
    }

    #[test]
    fn parse_grep_output_ftp_url_in_content() {
        // FTP URLs also have colons in the scheme.
        let raw = "readme.txt:1:Download from ftp://server.com/file";
        let results = parse_grep_output(raw);
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].path, std::path::PathBuf::from("readme.txt"));
        assert_eq!(results[0].line_number, 1);
        assert_eq!(results[0].content, "Download from ftp://server.com/file");
    }

    fn make_test_repo() -> TempRepo {
        let repo = TempRepo::init();
        repo.write_file("hello.rs", "fn main() {\n    println!(\"hello\");\n}\n");
        repo.write_file("other.txt", "nothing here\n");
        repo.stage("hello.rs");
        repo.stage("other.txt");
        repo.commit("Initial commit\n");
        repo
    }

    #[test]
    fn git_grep_finds_match() {
        let repo = make_test_repo();
        let results = git_grep(repo.path(), "println").unwrap();
        assert_eq!(results.len(), 1, "expected 1 match, got {:?}", results);
        assert_eq!(
            results[0].line_number, 2,
            "expected line 2, got {}",
            results[0].line_number
        );
        assert!(
            results[0].content.contains("println"),
            "expected 'println' in content, got: {}",
            results[0].content
        );
    }

    #[test]
    fn git_grep_multiple_matches() {
        let repo = make_test_repo();
        let results = git_grep(repo.path(), "fn").unwrap();
        assert_eq!(results.len(), 1, "expected 1 match, got {:?}", results);
    }

    #[test]
    fn git_grep_no_matches() {
        let repo = make_test_repo();
        let results = git_grep(repo.path(), "xyzzy").unwrap();
        assert_eq!(results.len(), 0);
    }

    /// A pattern beginning with `-` must be searched for, not parsed as an
    /// option. Without `-e` these turned into git flags and failed the search.
    #[test]
    fn git_grep_treats_leading_dash_as_a_pattern() {
        let repo = TempRepo::init();
        repo.commit_file("flags.txt", "run with -v for verbose\n", "initial\n");

        let results = git_grep(repo.path(), "-v").unwrap();
        assert_eq!(results.len(), 1, "expected 1 match, got {:?}", results);
        assert!(results[0].content.contains("-v"));

        // An option-shaped pattern with no match is simply "no results", not an
        // error from git rejecting an unknown flag.
        assert_eq!(
            git_grep(repo.path(), "--upload-pack=echo").unwrap().len(),
            0
        );
        assert_eq!(git_grep(repo.path(), "-f/etc/passwd").unwrap().len(), 0);
    }
}
