//! Serializable response models shared across every host boundary.

use crate::protocol::CoreError;
use serde::Serialize;
use serde_json::Value;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
/// Stable success-or-failure envelope returned across the JSON and C boundaries.
pub struct CoreResponse {
    /// Correlation identifier copied from the request, when supplied.
    pub id: Option<String>,
    /// Discriminator that determines whether `data` or `error` is present.
    pub ok: bool,
    /// Successful command payload. It is omitted for failures.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub data: Option<ResponseData>,
    /// Structured failure. It is omitted for successful responses.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<CoreError>,
}

#[derive(Debug, Serialize)]
#[serde(untagged)]
/// Payload wrapper that preserves each command's existing JSON shape.
pub enum ResponseData {
    /// A command-specific JSON value serialized without an additional tag.
    Json(Value),
}

impl CoreResponse {
    /// Reports whether the response carries successful data.
    pub fn is_success(&self) -> bool {
        self.ok
    }

    /// Builds a successful response while preserving the caller's identifier.
    pub fn success(id: Option<String>, data: impl Into<Value>) -> Self {
        Self {
            id,
            ok: true,
            data: Some(ResponseData::Json(data.into())),
            error: None,
        }
    }

    /// Builds a failed response with no partially successful data attached.
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
/// One file or directory in a deterministic workspace tree.
pub struct WorkspaceNode {
    pub path: String,
    pub name: String,
    pub is_directory: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub children: Option<Vec<WorkspaceNode>>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Complete visible workspace tree and its flattened file paths.
pub struct WorkspaceSnapshotResponse {
    pub root: WorkspaceNode,
    pub files: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// File, content, or symbol match with optional source location.
pub struct SearchMatch {
    /// Result category: file path, file content, or symbol.
    pub kind: String,
    pub path: String,
    pub line: Option<usize>,
    pub preview: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub symbol_name: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Bounded, deterministically ordered search matches.
pub struct SearchResponse {
    pub matches: Vec<SearchMatch>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Preview of replacements occurring on one source line.
pub struct ReplacementMatch {
    pub line: usize,
    pub before: String,
    pub after: String,
    pub occurrence_count: usize,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// All preview matches and resulting text for one file.
pub struct ReplacementFile {
    pub path: String,
    pub matches: Vec<ReplacementMatch>,
    pub replacement_text: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Non-mutating replacement preview grouped by workspace-relative path.
pub struct ReplacementPreviewResponse {
    pub files: Vec<ReplacementFile>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// UTF-8 contents read from one workspace-relative path.
pub struct FileReadResponse {
    pub path: String,
    pub text: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Path and byte count produced by a successful file write.
pub struct FileWriteResponse {
    pub path: String,
    pub bytes_written: usize,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Metadata for one retained local-history snapshot.
pub struct HistoryEntryResponse {
    pub id: String,
    pub timestamp: i64,
    pub relative_path: String,
    pub reason: String,
    pub content_path: String,
    pub byte_count: usize,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub label: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Local-history entries in deterministic newest-first order.
pub struct HistoryEntriesResponse {
    pub entries: Vec<HistoryEntryResponse>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Maven profile identity and its default activation state.
pub struct MavenProfileResponse {
    pub id: String,
    pub is_active_by_default: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// One module in the declared Maven reactor hierarchy.
pub struct MavenModuleResponse {
    pub relative_path: String,
    pub group_id: Option<String>,
    pub artifact_id: String,
    pub version: Option<String>,
    pub packaging: String,
    pub source_roots: Vec<MavenSourceRootResponse>,
    pub modules: Vec<MavenModuleResponse>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// One Maven source root relative to its owning module.
pub struct MavenSourceRootResponse {
    /// Module-relative path using `/` separators.
    pub path: String,
    /// Semantic source-set used by project and Java tooling views.
    pub kind: MavenSourceRootKind,
}

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "camelCase")]
/// Maven source-root categories kept distinct for main, test, and generated code.
pub enum MavenSourceRootKind {
    /// Production Java sources.
    MainJava,
    /// Production resource files.
    MainResources,
    /// Test Java sources.
    TestJava,
    /// Test resource files.
    TestResources,
    /// Generated production sources.
    GeneratedMain,
    /// Generated test sources.
    GeneratedTest,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Maven reactor identity, modules, profiles, and wrapper availability.
pub struct MavenScanResponse {
    pub relative_path: String,
    pub group_id: Option<String>,
    pub artifact_id: String,
    pub version: Option<String>,
    pub packaging: String,
    pub source_roots: Vec<MavenSourceRootResponse>,
    pub modules: Vec<MavenModuleResponse>,
    pub profiles: Vec<MavenProfileResponse>,
    pub has_wrapper: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Platform-neutral executable reference returned by Maven launch planning.
pub struct MavenLaunchExecutableResponse {
    pub toolchain: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Deterministic Maven invocation consumed by native process adapters.
pub struct MavenLaunchPlanResponse {
    pub version: u32,
    pub executable: MavenLaunchExecutableResponse,
    pub arguments: Vec<String>,
    pub working_directory: String,
    pub configuration_fingerprint: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// One normalized issue parsed from Maven process output.
pub struct MavenDiagnosticResponse {
    pub path: String,
    pub line: usize,
    pub column: Option<usize>,
    pub severity: String,
    pub message: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Maven diagnostics in stable source order.
pub struct MavenDiagnosticsResponse {
    pub issues: Vec<MavenDiagnosticResponse>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Java class containing a runnable main method.
pub struct JavaMainClassResponse {
    pub path: String,
    pub qualified_name: String,
    pub simple_name: String,
    pub is_spring_boot: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Source-set classification attached to one discovered Java run entry.
pub enum JavaSourceSetResponse {
    /// Production source compiled into the main project output.
    Main,
    /// Test source compiled into the test project output.
    Test,
    /// Java source outside the conventional Maven main and test layouts.
    Other,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// UI-facing Java or Spring Boot run entry.
pub struct JavaRunConfigurationResponse {
    pub id: String,
    pub name: String,
    /// UI category such as `javaMain`, `springBoot`, or `mavenModule`.
    pub kind: String,
    pub module_path: Option<String>,
    pub main_class: Option<String>,
    /// Workspace-relative source that produced this exact run entry.
    pub source_path: String,
    /// Build output that must be present on the Java launch classpath.
    pub source_set: JavaSourceSetResponse,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Discovered Java main classes and their stable run entries.
pub struct JavaRunConfigurationsResponse {
    pub main_classes: Vec<JavaMainClassResponse>,
    pub configurations: Vec<JavaRunConfigurationResponse>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Usage count rendered above one Java declaration.
pub struct JavaCodeVisionHintResponse {
    pub line: usize,
    pub utf16_column: usize,
    pub symbol: String,
    pub usage_count: usize,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Code Vision hints in source order.
pub struct JavaCodeVisionResponse {
    pub hints: Vec<JavaCodeVisionHintResponse>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Package-qualified Java class name.
pub struct JavaClassNameResponse {
    pub class_name: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Zero-based UTF-16 location of a Java declaration.
pub struct JavaSourceDefinitionResponse {
    pub line: usize,
    pub utf16_column: usize,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Server port declared by Spring configuration, when one is present.
pub struct JavaServerPortResponse {
    pub port: Option<usize>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Foldable Java source region and the text span hidden by folding.
pub struct JavaFoldRegionResponse {
    /// Fold category such as imports, declaration, or comment.
    pub kind: String,
    pub start_line: usize,
    pub end_line: usize,
    pub hidden_start: usize,
    pub hidden_length: usize,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Lightweight Java parameter-name inlay hint.
pub struct JavaInlayHintResponse {
    pub line: usize,
    pub utf16_column: usize,
    pub label: String,
}

#[derive(Debug, Clone, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
/// One non-overlapping Java token range with a portable editor-theme role.
pub struct JavaSyntaxHighlightResponse {
    /// Document-relative start measured in UTF-16 code units.
    pub utf16_start: usize,
    /// Token length measured in UTF-16 code units.
    pub utf16_length: usize,
    /// Semantic role defined by the shared editor syntax-theme contract.
    pub role: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Lightweight structural features derived from one Java source document.
pub struct JavaStructureResponse {
    pub fold_regions: Vec<JavaFoldRegionResponse>,
    pub inlay_hints: Vec<JavaInlayHintResponse>,
    pub syntax_highlights: Vec<JavaSyntaxHighlightResponse>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// One Java navigation gutter marker normalized from provider semantic data.
pub struct JavaNavigationMarkerResponse {
    pub line: usize,
    pub utf16_column: usize,
    pub implementation_count: usize,
    pub direction: String,
    pub relation: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// One normalized index or working-tree change.
pub struct GitChange {
    pub path: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub original_path: Option<String>,
    /// Normalized porcelain status code for the path.
    pub status: String,
    pub staged: bool,
    pub worktree: bool,
    pub untracked: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Repository identity, branch divergence, and normalized file changes.
pub struct GitStatusResponse {
    pub repository_root: Option<String>,
    pub branch: Option<String>,
    pub ahead: usize,
    pub behind: usize,
    pub changes: Vec<GitChange>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Worktree-aware Git paths that a platform watcher should observe.
pub struct GitWatchContextResponse {
    pub repository_root: String,
    pub git_directory: String,
    pub git_common_directory: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// One checkout registered in a repository's shared worktree metadata.
pub struct GitWorktreeResponse {
    /// Absolute checkout path reported by Git. Linked worktrees may live outside the opened workspace.
    pub path: String,
    /// Commit currently checked out by this worktree.
    pub head: String,
    /// Fully qualified local branch reference, absent for detached or bare worktrees.
    pub branch: Option<String>,
    /// Whether this is the worktree from which the request was made.
    pub is_current: bool,
    /// Whether this is the repository's primary worktree.
    pub is_primary: bool,
    pub is_bare: bool,
    pub is_detached: bool,
    pub is_locked: bool,
    /// Human-readable lock reason supplied to Git, when present.
    pub lock_reason: Option<String>,
    pub is_prunable: bool,
    /// Git's explanation for why the registration can be pruned.
    pub prune_reason: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Deterministically ordered worktrees registered for one repository.
pub struct GitWorktreesResponse {
    pub worktrees: Vec<GitWorktreeResponse>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Local or remote Git reference in display-ready form.
pub struct GitReferenceResponse {
    pub full_name: String,
    pub short_name: String,
    /// Reference category: local branch, remote branch, or tag.
    pub kind: String,
    /// Whether the reference resolves to a commit and therefore supports
    /// commit-only mutations such as restorable tag deletion.
    pub peels_to_commit: bool,
    pub is_current: bool,
    pub upstream_short_name: Option<String>,
    /// Commits present only on this local branch compared with its upstream.
    pub ahead: usize,
    /// Commits present only on this local branch's upstream.
    pub behind: usize,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Commit metadata parsed from a machine-stable field format.
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
/// References and a bounded page of commit history.
pub struct GitHistoryResponse {
    pub references: Vec<GitReferenceResponse>,
    /// Up to five local branches ordered from most to least recently checked out.
    pub recent_references: Vec<GitReferenceResponse>,
    pub commits: Vec<GitCommitResponse>,
    pub has_more: bool,
    pub user_name: Option<String>,
    pub user_email: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Resolved destination and bounded commits for one branch push.
pub struct GitPushPreviewResponse {
    /// Local branch that will be sent to the remote.
    pub local_branch: String,
    /// Commit at the local branch tip when this preview was resolved.
    pub local_head: String,
    /// Remote selected from the branch upstream or repository defaults.
    pub remote: String,
    /// Branch name created or updated on the remote.
    pub remote_branch: String,
    /// Locally observed destination OID, or `None` before first publication.
    pub remote_tracking_oid: Option<String>,
    /// Configured upstream short name, or `None` before first publication.
    pub upstream: Option<String>,
    /// Exact tag references and object IDs included in this reviewed push.
    pub tags: Vec<GitPushTagResponse>,
    /// Commits reachable from the local branch but not its resolved remote base.
    pub commits: Vec<GitCommitResponse>,
    /// Whether more commits exist beyond the bounded preview.
    pub has_more: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// One immutable tag snapshot included in a reviewed push.
pub struct GitPushTagResponse {
    /// Fully qualified tag reference under `refs/tags/`.
    pub full_name: String,
    /// Tag object ID observed while the preview was created.
    pub object_id: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Exact lookup result for one commit.
pub struct GitCommitLookupResponse {
    pub commit: GitCommitResponse,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Path and status changed by a commit or comparison.
pub struct GitFileResponse {
    /// Normalized name-status code such as `A`, `M`, `D`, or `R`.
    pub status: String,
    pub path: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Deterministically ordered changed paths.
pub struct GitFilesResponse {
    pub files: Vec<GitFileResponse>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Paths differing between a reference and the current checkout.
pub struct GitComparisonResponse {
    pub files: Vec<GitFileResponse>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// One stash entry with its stable reference and parsed metadata.
pub struct GitStashResponse {
    pub reference: String,
    pub message: String,
    pub branch: Option<String>,
    pub date: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Stash entries in Git's native newest-first order.
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
    /// Active operation name, or an empty string when no operation is in progress.
    pub kind: String,
    pub reference: Option<String>,
    pub step: Option<usize>,
    pub total: Option<usize>,
    pub conflicted_paths: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Line-level blame attribution normalized for editor gutters.
pub struct GitBlameLineResponse {
    pub line: usize,
    pub commit_hash: String,
    pub author_name: String,
    pub author_time: i64,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Blame attribution ordered by one-based source line.
pub struct GitBlameResponse {
    pub lines: Vec<GitBlameLineResponse>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// One aligned side-by-side diff row.
pub struct GitDiffRowResponse {
    pub old_line: Option<usize>,
    pub new_line: Option<usize>,
    pub left: Option<String>,
    /// Omitted for `context` and `information` rows, whose two sides always
    /// hold identical text; clients fall back to `left` in that case.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub right: Option<String>,
    /// Rendering category such as context, changed, insertion, deletion, or information.
    pub kind: String,
    pub hunk_id: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Independently applicable diff hunk and its original patch text.
pub struct GitDiffHunkResponse {
    pub id: String,
    pub header: String,
    pub patch: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Complete patch plus rendering rows and independently applicable hunks.
pub struct GitDiffResponse {
    pub patch: String,
    pub rows: Vec<GitDiffRowResponse>,
    pub hunks: Vec<GitDiffHunkResponse>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// One Spring configuration property and its optional Java declaration.
pub struct SpringPropertyResponse {
    pub name: String,
    pub type_name: Option<String>,
    pub description: Option<String>,
    pub default_value: Option<String>,
    pub source_path: Option<String>,
    pub source_line: Option<usize>,
    pub source_column: Option<usize>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// One key/value occurrence from a Spring application configuration document.
pub struct SpringConfigurationValueResponse {
    pub key: String,
    pub value: String,
    pub path: String,
    pub line: usize,
    pub column: usize,
    pub profile: Option<String>,
    pub overrides_base_value: bool,
    pub target_path: Option<String>,
    pub target_line: Option<usize>,
    pub target_column: Option<usize>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Java `@Value` reference to a Spring configuration property.
pub struct SpringPropertyReferenceResponse {
    pub key: String,
    pub path: String,
    pub line: usize,
    pub column: usize,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Spring configuration problem projected onto one source location.
pub struct SpringDiagnosticResponse {
    pub path: String,
    pub line: usize,
    pub column: usize,
    pub severity: String,
    pub message: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Component or `@Bean` declaration available for dependency injection.
pub struct SpringBeanResponse {
    pub id: String,
    pub name: String,
    pub type_name: String,
    pub path: String,
    pub line: usize,
    pub column: usize,
    pub kind: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Injection point and the bean declarations that satisfy it.
pub struct SpringInjectionResponse {
    pub path: String,
    pub line: usize,
    pub column: usize,
    pub type_name: String,
    pub qualifier: Option<String>,
    pub bean_ids: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// HTTP endpoint declared by a Spring MVC controller method.
pub struct SpringEndpointResponse {
    pub id: String,
    pub http_methods: Vec<String>,
    pub route: String,
    pub controller: String,
    pub method: String,
    pub path: String,
    pub line: usize,
    pub column: usize,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Complete deterministic Spring semantic index for one workspace snapshot.
pub struct SpringIndexResponse {
    pub properties: Vec<SpringPropertyResponse>,
    pub values: Vec<SpringConfigurationValueResponse>,
    pub property_references: Vec<SpringPropertyReferenceResponse>,
    pub diagnostics: Vec<SpringDiagnosticResponse>,
    pub beans: Vec<SpringBeanResponse>,
    pub injections: Vec<SpringInjectionResponse>,
    pub endpoints: Vec<SpringEndpointResponse>,
}
