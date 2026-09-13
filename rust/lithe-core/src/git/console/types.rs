//! Native console snapshots and deterministic, lossless disclosure ranges.
use serde::{Deserialize, Serialize};

/// Execution provenance is retained for diagnostics; display does not merge commands.
#[derive(Debug, Clone, Copy, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum Source {
    /// A user deliberately invoked the operation.
    User,
    /// An automatic refresh or watcher invoked the query.
    Background,
    /// Provenance was not supplied; preserve each execution independently.
    #[default]
    Unknown,
}

/// One retained line, in native event order. Stderr alone does not imply failure.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Line {
    pub stream: String,
    pub text: String,
}

/// Bounded native history; the presentation command performs no Git or filesystem work.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Request {
    pub records: Vec<Record>,
    #[serde(default)]
    pub search: String,
    /// Additional workspace roots disambiguate labels even before those repositories have output.
    #[serde(default)]
    pub repository_roots: Vec<String>,
}

/// Complete retained execution data; presentation never rewrites this input.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Record {
    pub id: String,
    pub root: String,
    pub arguments: Vec<String>,
    #[serde(default)]
    pub temporary_config: Vec<(String, String)>,
    #[serde(default)]
    pub lines: Vec<Line>,
    pub state: String,
    pub exit_code: Option<i32>,
    /// Only the executing workflow can accept a nonzero exit as a normal query result.
    #[serde(default)]
    pub expected_exit: bool,
    pub error: Option<String>,
    pub executable: Option<String>,
    pub progress: Option<String>,
    /// A transfer's measured result; absent counts must never imply no changes.
    pub remote_result: Option<RemoteResult>,
    #[serde(default)]
    pub truncated: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Only complete reference counts can justify a no-reference-changes notice.
pub struct RemoteResult {
    pub succeeded: bool,
    pub references_available: Option<bool>,
    pub updated_reference_count: Option<usize>,
    pub deleted_reference_count: Option<usize>,
}

#[derive(Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
/// Native hosts localize these status notices separately from raw Git output.
pub enum Notice {
    WaitingForOutput,
    CompletedWithoutOutput,
    FetchUnchanged,
}

impl Record {
    pub(super) fn failed(&self) -> bool {
        self.error.is_some()
            || self.state == "unconfirmed"
            || (self.state == "completed" && self.exit_code != Some(0) && !self.expected_exit)
    }

    pub(super) fn notice(&self) -> Option<Notice> {
        if !self.lines.is_empty()
            || self.progress.as_ref().is_some_and(|s| !s.is_empty())
            || self.truncated
            || self.failed()
        {
            return None;
        }
        if self.state == "running" {
            return Some(Notice::WaitingForOutput);
        }
        if self.state != "completed" || self.exit_code != Some(0) {
            return None;
        }
        let fetch = crate::git::execution_policy::command_index(&self.arguments)
            .is_some_and(|i| self.arguments[i] == "fetch");
        if fetch
            && self.remote_result.as_ref().is_some_and(|result| {
                result.succeeded
                    && result.references_available == Some(true)
                    && result.updated_reference_count == Some(0)
                    && result.deleted_reference_count == Some(0)
            })
        {
            Some(Notice::FetchUnchanged)
        } else {
            Some(Notice::CompletedWithoutOutput)
        }
    }
}

/// Stable fragment IDs let native views retain manual expansion across updates.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CommandFragment {
    pub id: String,
    /// text or configuration; configuration ranges fold in their original position.
    pub kind: String,
    /// Complete safely quoted text, including literal newlines inside quoted arguments.
    pub text: String,
    pub preview: String,
    pub count: usize,
    pub matches: usize,
}

/// Half-open indices into the original retained line array, not a second output buffer.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OutputFragment {
    pub id: String,
    pub start: usize,
    pub end: usize,
    /// text or progress; a folded progress range uses its last original line as its label.
    pub kind: String,
    /// Number of original lines in the range.
    pub count: usize,
    pub added: usize,
    pub updated: usize,
    pub deleted: usize,
    pub matches: usize,
}

/// One command remains addressable even when it belongs to a repeated-query group.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Entry {
    pub id: String,
    pub repository_label: String,
    pub command: Vec<CommandFragment>,
    pub output: Vec<OutputFragment>,
    pub failed: bool,
    pub notice: Option<Notice>,
}

/// Compatibility grouping envelope. IDEA-style display retains one command per group.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Group {
    /// Exact match count across every execution, independent of the search-location cap.
    pub matches: usize,
    pub id: String,
    pub record_ids: Vec<String>,
}

/// A search occurrence targets a retained command fragment or an original output line.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchHit {
    pub record_id: String,
    pub fragment_id: String,
    pub line_index: Option<usize>,
}

/// A compact display plan. Truncation of search results does not discard execution data.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Presentation {
    pub entries: Vec<Entry>,
    pub groups: Vec<Group>,
    pub matches: Vec<SearchHit>,
    pub total_matches: usize,
}
