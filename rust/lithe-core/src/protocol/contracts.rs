use crate::protocol::CoreError;
use serde::Serialize;
use serde_json::Value;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CoreResponse {
    pub id: Option<String>,
    pub ok: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<ResponseData>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<CoreError>,
}

#[derive(Debug, Serialize)]
#[serde(untagged)]
pub enum ResponseData {
    Json(Value),
}

impl CoreResponse {
    pub fn is_success(&self) -> bool {
        self.ok
    }

    pub fn success(id: Option<String>, data: impl Into<Value>) -> Self {
        Self {
            id,
            ok: true,
            data: Some(ResponseData::Json(data.into())),
            error: None,
        }
    }

    pub fn failure(id: Option<String>, error: CoreError) -> Self {
        Self {
            id,
            ok: false,
            data: None,
            error: Some(error),
        }
    }
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceNode {
    pub path: String,
    pub name: String,
    pub is_directory: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub children: Option<Vec<WorkspaceNode>>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceSnapshotResponse {
    pub root: WorkspaceNode,
    pub files: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchMatch {
    pub kind: String,
    pub path: String,
    pub line: Option<usize>,
    pub preview: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub symbol_name: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchResponse {
    pub matches: Vec<SearchMatch>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReplacementMatch {
    pub line: usize,
    pub before: String,
    pub after: String,
    pub occurrence_count: usize,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReplacementFile {
    pub path: String,
    pub matches: Vec<ReplacementMatch>,
    pub replacement_text: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReplacementPreviewResponse {
    pub files: Vec<ReplacementFile>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileReadResponse {
    pub path: String,
    pub text: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileWriteResponse {
    pub path: String,
    pub bytes_written: usize,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryEntryResponse {
    pub id: String,
    pub timestamp: i64,
    pub relative_path: String,
    pub reason: String,
    pub content_path: String,
    pub byte_count: usize,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryEntriesResponse {
    pub entries: Vec<HistoryEntryResponse>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MavenProfileResponse {
    pub id: String,
    pub is_active_by_default: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MavenModuleResponse {
    pub relative_path: String,
    pub group_id: Option<String>,
    pub artifact_id: String,
    pub version: Option<String>,
    pub packaging: String,
    pub modules: Vec<MavenModuleResponse>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MavenScanResponse {
    pub group_id: Option<String>,
    pub artifact_id: String,
    pub version: Option<String>,
    pub packaging: String,
    pub modules: Vec<MavenModuleResponse>,
    pub profiles: Vec<MavenProfileResponse>,
    pub has_wrapper: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MavenDiagnosticResponse {
    pub path: String,
    pub line: usize,
    pub column: Option<usize>,
    pub severity: String,
    pub message: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MavenDiagnosticsResponse {
    pub issues: Vec<MavenDiagnosticResponse>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct JavaMainClassResponse {
    pub path: String,
    pub qualified_name: String,
    pub simple_name: String,
    pub is_spring_boot: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct JavaRunConfigurationResponse {
    pub id: String,
    pub name: String,
    pub kind: String,
    pub module_path: Option<String>,
    pub main_class: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct JavaRunConfigurationsResponse {
    pub main_classes: Vec<JavaMainClassResponse>,
    pub configurations: Vec<JavaRunConfigurationResponse>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct JavaCodeVisionHintResponse {
    pub line: usize,
    pub utf16_column: usize,
    pub symbol: String,
    pub usage_count: usize,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct JavaCodeVisionResponse {
    pub hints: Vec<JavaCodeVisionHintResponse>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct JavaClassNameResponse {
    pub class_name: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct JavaSourceDefinitionResponse {
    pub line: usize,
    pub utf16_column: usize,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct JavaServerPortResponse {
    pub port: Option<usize>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct JavaFoldRegionResponse {
    pub kind: String,
    pub start_line: usize,
    pub end_line: usize,
    pub hidden_start: usize,
    pub hidden_length: usize,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct JavaImplementationMarkerResponse {
    pub line: usize,
    pub utf16_column: usize,
    pub implementation_count: usize,
    pub direction: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct JavaInlayHintResponse {
    pub line: usize,
    pub utf16_column: usize,
    pub label: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct JavaStructureResponse {
    pub fold_regions: Vec<JavaFoldRegionResponse>,
    pub implementation_markers: Vec<JavaImplementationMarkerResponse>,
    pub inlay_hints: Vec<JavaInlayHintResponse>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitChange {
    pub path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub original_path: Option<String>,
    pub status: String,
    pub staged: bool,
    pub worktree: bool,
    pub untracked: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitStatusResponse {
    pub repository_root: Option<String>,
    pub branch: Option<String>,
    pub changes: Vec<GitChange>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitReferenceResponse {
    pub full_name: String,
    pub short_name: String,
    pub kind: String,
    pub is_current: bool,
    pub upstream_short_name: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitCommitResponse {
    pub hash: String,
    pub short_hash: String,
    pub parent_hashes: Vec<String>,
    pub author_name: String,
    pub author_email: String,
    pub date: String,
    pub subject: String,
    pub decorations: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitHistoryResponse {
    pub references: Vec<GitReferenceResponse>,
    pub commits: Vec<GitCommitResponse>,
    pub has_more: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitCommitLookupResponse {
    pub commit: GitCommitResponse,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitFileResponse {
    pub status: String,
    pub path: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitFilesResponse {
    pub files: Vec<GitFileResponse>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitComparisonResponse {
    pub files: Vec<GitFileResponse>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitStashResponse {
    pub reference: String,
    pub message: String,
    pub branch: Option<String>,
    pub date: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitStashesResponse {
    pub stashes: Vec<GitStashResponse>,
}

/// Result of checking whether a checkout can proceed without losing local edits.
///
/// `blocking_paths` holds files that are dirty in the working tree *and* differ
/// between HEAD and the target ref. Computing the intersection ourselves avoids
/// parsing Git's stderr, which is localized and therefore unreliable to match.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitCheckoutPreflightResponse {
    pub blocking_paths: Vec<String>,
}

/// Staged files still holding conflict markers, which must never be committed.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitConflictMarkerResponse {
    pub paths: Vec<String>,
}

/// Whether a merge or rebase can start, and what stands in the way.
///
/// The two operations differ, verified against Git rather than assumed: a merge
/// only refuses when a dirty file overlaps what it would write, while a rebase
/// refuses on any uncommitted change at all, related or not. So `blocking_paths`
/// is an overlap set for a merge and the full dirty set for a rebase.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitIntegrationPreflightResponse {
    pub blocking_paths: Vec<String>,
    pub blocks_entirely: bool,
}

/// Whether a pull can fast-forward, and how far the two sides have drifted.
///
/// `diverged` is the case the UI has to ask about: both sides have commits the
/// other lacks, so `--ff-only` refuses and the user must pick merge or rebase.
/// `upstream` is absent when the branch tracks nothing, which is itself a reason
/// to stop before running anything.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitPullPreflightResponse {
    pub upstream: Option<String>,
    pub ahead: usize,
    pub behind: usize,
    pub diverged: bool,
    pub has_local_changes: bool,
}

/// A sequential operation Git left half-finished, usually because of a conflict.
///
/// `kind` is empty when nothing is in progress. `step`/`total` are only populated
/// for a rebase, which is the one operation that reports its own progress.
/// `conflicted_paths` comes from porcelain status codes rather than stderr, so it
/// stays correct under a localized Git.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitOperationStateResponse {
    pub kind: String,
    pub reference: Option<String>,
    pub step: Option<usize>,
    pub total: Option<usize>,
    pub conflicted_paths: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitBlameLineResponse {
    pub line: usize,
    pub commit_hash: String,
    pub author_name: String,
    pub author_time: i64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitBlameResponse {
    pub lines: Vec<GitBlameLineResponse>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitDiffRowResponse {
    pub old_line: Option<usize>,
    pub new_line: Option<usize>,
    pub left: Option<String>,
    /// Omitted for `context` and `information` rows, whose two sides always
    /// hold identical text; clients fall back to `left` in that case.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub right: Option<String>,
    pub kind: String,
    pub hunk_id: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitDiffHunkResponse {
    pub id: String,
    pub header: String,
    pub patch: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GitDiffResponse {
    pub patch: String,
    pub rows: Vec<GitDiffRowResponse>,
    pub hunks: Vec<GitDiffHunkResponse>,
}
