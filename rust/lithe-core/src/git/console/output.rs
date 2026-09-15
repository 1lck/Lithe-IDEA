//! IDEA-style progress folding; ordinary command output remains continuous text.
use super::types::{OutputFragment, Record};
use regex::Regex;
use std::sync::OnceLock;

pub(super) fn project(record: &Record) -> Vec<OutputFragment> {
    let mut result = Vec::new();
    let mut start = 0;
    while start < record.lines.len() {
        let mut end = start + 1;
        if looks_like_progress(&record.lines[start].text) {
            while end < record.lines.len() && looks_like_progress(&record.lines[end].text) {
                end += 1;
            }
        }
        // A failed command keeps its progress and diagnostics expanded for inspection.
        let folded = end > start + 1 && !record.failed();
        result.push(OutputFragment {
            id: format!("output-{start}"),
            start,
            end,
            kind: if folded { "progress" } else { "text" }.into(),
            count: end - start,
            added: 0,
            updated: 0,
            deleted: 0,
            matches: 0,
        });
        start = end;
    }
    result
}

/// Matches IDEA's GitImplBase progress grammar, including remote-side phases.
fn looks_like_progress(line: &str) -> bool {
    static PERCENT: OnceLock<Regex> = OnceLock::new();
    let percent = PERCENT.get_or_init(|| {
        Regex::new(r":\s*\d{1,3}% \(\d+/\d+\)").expect("constant Git progress pattern")
    });
    if percent.is_match(line) {
        return true;
    }
    let line = line.strip_prefix("remote: ").unwrap_or(line);
    [
        "Counting objects: ",
        "Enumerating objects: ",
        "Compressing objects: ",
        "Writing objects: ",
        "Receiving objects: ",
        "Resolving deltas: ",
        "Finding sources: ",
        "Updating files: ",
        "Checking out files: ",
        "Expanding reachable commits in commit graph: ",
        "Delta compression using up to ",
    ]
    .iter()
    .any(|prefix| line.starts_with(prefix))
}
