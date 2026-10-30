//! Workspace traversal, file operations, search, and replacement previews.

use super::file_name_order::FileNameKey;
use super::search_index::{self, UpdateOutcome, WorkspaceSearchIndex};
use super::search_paging::SearchPage;
use crate::protocol::{invalid_relative_path, CoreError, ErrorCode};
use crate::protocol::{
    DirectoryListing, DirectoryListingResponse, FileReadResponse, FileWriteResponse,
    ReplacementPreviewResponse, SearchMatch, SearchResponse, WorkspaceNode,
    WorkspaceSnapshotResponse,
};
use crate::remote::workspace_io as fs;
use regex::{Regex, RegexBuilder};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};

/// Default workspace exclusions, also used by Git discovery for generated directories.
pub(crate) const BUILT_IN_HIDDEN_DIRECTORIES: &[&str] = &[
    ".git",
    ".svn",
    ".worktree",
    ".worktrees",
    ".build",
    ".swiftpm",
    "node_modules",
    "target",
    "build",
    "DerivedData",
    ".gradle",
    ".next",
    "dist",
    "coverage",
    "design-qa-artifacts",
    ".artifacts",
];
/// Whether an ordinary workspace event belongs to visible project inputs.
/// Callers first relativize to the most specific explicitly watched root; native
/// event-loss flags always bypass this filter and request recovery.
pub fn is_workspace_event_relevant(relative: &str) -> bool {
    !relative.split(['/', '\\']).any(|component| {
        BUILT_IN_HIDDEN_DIRECTORIES
            .iter()
            .any(|name| component.eq_ignore_ascii_case(name))
    })
}

/// File names omitted from workspace snapshots, search, and related scans.
const BUILT_IN_HIDDEN_FILE_PATTERNS: &[&str] = &[".DS_Store"];
const MAX_FILE_SIZE: u64 = 2 * 1024 * 1024;
const MAX_OPEN_FILE_SIZE: u64 = 32 * 1024 * 1024;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Workspace root and visibility overrides used to build a file-tree snapshot.
pub struct WorkspaceSnapshotRequest {
    pub root: String,
    #[serde(default)]
    pub hidden_directory_names: Vec<String>,
    #[serde(default)]
    pub hidden_file_patterns: Vec<String>,
    /// When false, the response keeps only the file list and returns `root`
    /// without children; hosts that load the tree per directory skip encoding
    /// and decoding a node for every path.
    #[serde(default = "default_include_tree")]
    pub include_tree: bool,
}

fn default_include_tree() -> bool {
    true
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Workspace-relative directories whose visible children a host is loading.
pub struct DirectoryListingRequest {
    pub root: String,
    /// Workspace-relative directories; an empty string is the root itself.
    #[serde(default)]
    pub paths: Vec<String>,
    #[serde(default)]
    pub hidden_directory_names: Vec<String>,
    #[serde(default)]
    pub hidden_file_patterns: Vec<String>,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
/// Bounded file, content, and symbol search options.
pub struct SearchRequest {
    /// Workspace-relative scopes, applied before result caps without changing policy ownership.
    #[serde(default)]
    pub scope_paths: Vec<String>,
    pub root: String,
    pub query: String,
    #[serde(default)]
    pub case_sensitive: bool,
    #[serde(default)]
    pub whole_words: bool,
    #[serde(default)]
    pub regular_expression: bool,
    #[serde(default = "default_max_results")]
    pub max_results: usize,
    #[serde(default)]
    pub max_file_results: Option<usize>,
    #[serde(default)]
    pub max_content_results: Option<usize>,
    #[serde(default)]
    pub max_symbol_results: Option<usize>,
    /// Search Everywhere may discover generated file names without indexing their contents.
    #[serde(default)]
    pub include_generated_file_names: bool,
    #[serde(default)]
    pub hidden_directory_names: Vec<String>,
    #[serde(default)]
    pub hidden_file_patterns: Vec<String>,
    /// Comma-separated file masks such as `*.java, *.kt`; empty means no filter.
    #[serde(default)]
    pub file_mask: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Workspace root and visibility rules used to warm or invalidate an index.
pub struct SearchIndexRequest {
    pub root: String,
    #[serde(default)]
    pub hidden_directory_names: Vec<String>,
    #[serde(default)]
    pub hidden_file_patterns: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Changed workspace-relative paths to apply to a cached search index.
pub struct SearchIndexUpdateRequest {
    pub root: String,
    #[serde(default)]
    pub paths: Vec<String>,
    #[serde(default)]
    pub hidden_directory_names: Vec<String>,
    #[serde(default)]
    pub hidden_file_patterns: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Search-index size and whether an incremental request required a rebuild.
pub struct SearchIndexStatusResponse {
    pub file_count: usize,
    pub symbol_count: usize,
    pub posting_count: usize,
    pub rebuilt: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Search and replacement options used to produce a non-mutating preview.
pub struct ReplacementPreviewRequest {
    pub root: String,
    pub query: String,
    pub replacement: String,
    #[serde(default)]
    pub case_sensitive: bool,
    #[serde(default)]
    pub whole_words: bool,
    #[serde(default)]
    pub regular_expression: bool,
    /// Preserve all-uppercase or initial-uppercase shape from literal matches.
    #[serde(default)]
    pub preserve_case: bool,
    #[serde(default)]
    pub file_mask: String,
    #[serde(default)]
    pub paths: Vec<String>,
    #[serde(default)]
    pub text_overrides: HashMap<String, String>,
    #[serde(default)]
    pub hidden_directory_names: Vec<String>,
    #[serde(default)]
    pub hidden_file_patterns: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Request to read one validated workspace-relative UTF-8 file.
pub struct FileReadRequest {
    pub root: String,
    pub path: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Request to replace one validated workspace-relative UTF-8 file.
pub struct FileWriteRequest {
    pub root: String,
    pub path: String,
    pub text: String,
}

fn default_max_results() -> usize {
    200
}

/// Scans visible workspace entries and invalidates any stale search index.
pub fn snapshot(request: WorkspaceSnapshotRequest) -> Result<WorkspaceSnapshotResponse, CoreError> {
    let root = existing_root(&request.root)?;
    let indexing_policy = super::indexing::context(&root);
    search_index::invalidate_root(&root);
    let rules = VisibilityRules::new(request.hidden_directory_names, request.hidden_file_patterns);
    let mut files = Vec::new();
    let mut nested_worktrees = Vec::new();
    let mut incomplete_directories = Vec::new();
    let node = if request.include_tree {
        scan_node(
            &root,
            &root,
            &rules,
            &mut files,
            &mut nested_worktrees,
            &mut incomplete_directories,
        )?
    } else {
        collect_snapshot_files(
            &root,
            &root,
            &rules,
            &mut files,
            &mut nested_worktrees,
            &mut incomplete_directories,
        )?;
        WorkspaceNode {
            path: String::new(),
            name: node_name(&root),
            is_directory: true,
            children: None,
        }
    };
    if let Some(policy) = indexing_policy {
        policy.check()?;
    }
    Ok(WorkspaceSnapshotResponse {
        root: node,
        files,
        nested_worktrees,
        incomplete_directories,
    })
}

/// Lists the visible children of each requested directory, one level deep.
///
/// The project tree loads directories as they are expanded, so a workspace
/// with many files no longer builds a node for each of them up front. Paths
/// that no longer exist, are hidden, or lie inside a nested linked worktree
/// are left out of the response instead of failing the whole request, because
/// a directory can disappear between the host's expand and this call.
pub fn list_directories(
    request: DirectoryListingRequest,
) -> Result<DirectoryListingResponse, CoreError> {
    let root = existing_root(&request.root)?;
    let rules = VisibilityRules::new(request.hidden_directory_names, request.hidden_file_patterns);
    let mut directories = Vec::new();
    for relative in request.paths {
        crate::protocol::cancellation::check()?;
        let Some(directory) = listable_directory(&root, &relative, &rules) else {
            continue;
        };
        let listing = match visible_children(&directory, &root, &rules, ChildOrder::Tree) {
            Ok(listing) => listing,
            Err(error)
                if matches!(
                    error.code,
                    ErrorCode::PermissionDenied | ErrorCode::WorkspaceNotFound
                ) =>
            {
                continue
            }
            Err(error) => return Err(error),
        };
        let children = listing
            .children
            .into_iter()
            .map(|(path, is_directory)| WorkspaceNode {
                path: relative_path(&path, &root),
                name: node_name(&path),
                is_directory,
                children: if is_directory
                    && !super::indexing::is_excluded(&root, &path, true).unwrap_or(true)
                    && directory_is_visibly_empty(&path, &root, &rules)
                {
                    Some(Vec::new())
                } else {
                    None
                },
            })
            .collect();
        directories.push(DirectoryListing {
            path: relative_path(&directory, &root),
            children,
            nested_worktrees: listing
                .nested_worktrees
                .iter()
                .map(|worktree| relative_path(worktree, &root))
                .collect(),
        });
    }
    Ok(DirectoryListingResponse { directories })
}

/// Resolves a requested directory without following symlinks, so a listing
/// never reaches outside the workspace or into a directory scans skip.
fn listable_directory(root: &Path, relative: &str, rules: &VisibilityRules) -> Option<PathBuf> {
    if relative.is_empty() {
        return Some(root.to_path_buf());
    }
    if Path::new(relative).is_absolute() || invalid_relative_path(relative) {
        return None;
    }
    let mut current = root.to_path_buf();
    for component in relative.split('/') {
        current.push(component);
        let metadata = fs::symlink_metadata(&current).ok()?;
        if !metadata.is_dir() || rules.is_hidden(&relative_path(&current, root), true) {
            return None;
        }
    }
    let nested =
        is_inside_nested_linked_worktree(root, relative) || is_nested_linked_worktree(&current);
    (!nested).then_some(current)
}

/// Searches visible file paths and current file contents using the shared index.
pub fn search(request: SearchRequest) -> Result<SearchResponse, CoreError> {
    let root = existing_root(&request.root)?;
    let indexing_policy = super::indexing::context(&root);
    let query = request.query.trim().to_string();
    if query.is_empty() {
        return Ok(SearchResponse {
            matches: Vec::new(),
        });
    }

    let rules = VisibilityRules::new(
        request.hidden_directory_names.clone(),
        request.hidden_file_patterns.clone(),
    );
    let index = search_index::get_or_build(&root, &rules)?;
    let index = index
        .read()
        .map_err(|_| CoreError::new(ErrorCode::Unknown, "Search index lock was poisoned"))?;
    let result = search_with_index(&root, &request, &query, &index, None)?;
    if let Some(policy) = &indexing_policy {
        policy.check()?;
    }
    Ok(result)
}

fn scope_allows(scopes: &[String], path: &str) -> bool {
    scopes.is_empty()
        || scopes.iter().any(|scope| {
            #[cfg(windows)]
            let (scope, path) = (scope.to_lowercase(), path.to_lowercase());
            scope.is_empty()
                || scope == "."
                || path == scope.as_str()
                || path
                    .strip_prefix(scope.as_str())
                    .is_some_and(|suffix| suffix.starts_with('/'))
        })
}

fn search_with_index(
    root: &Path,
    request: &SearchRequest,
    query: &str,
    index: &WorkspaceSearchIndex,
    page: Option<&SearchPage>,
) -> Result<SearchResponse, CoreError> {
    let matcher = Matcher::new(
        query,
        request.case_sensitive,
        request.whole_words,
        request.regular_expression,
    )?;
    let masks = parse_file_mask(&request.file_mask);
    let limit = request.max_results.max(1).min(10_000);
    let file_limit = request.max_file_results.unwrap_or(limit).min(limit);
    let content_limit = request.max_content_results.unwrap_or(limit).min(limit);
    let mut matches = Vec::new();
    let mut file_matches = 0;

    for id in index.all_file_ids() {
        crate::protocol::cancellation::check()?;
        if matches.len() >= limit || file_matches >= file_limit {
            break;
        }
        let Some(indexed_file) = index.file(id) else {
            continue;
        };
        let path = &indexed_file.path;
        if !scope_allows(&request.scope_paths, path) || !file_mask_allows(&masks, path) {
            continue;
        }
        if matcher.matches(path) {
            matches.push(SearchMatch {
                kind: "file".to_string(),
                path: path.clone(),
                line: None,
                preview: path.clone(),
                symbol_name: None,
                name_match_ranges: Vec::new(),
                matching_degree: None,
                is_ignored: None,
            });
            file_matches += 1;
        }
    }

    let mut content_matches = 0;
    let mut candidates = index.candidate_ids(query, request.regular_expression);
    if page.is_some() {
        candidates.sort_by_key(|id| index.file(*id).map(|file| file.path.as_str()));
    }
    for id in candidates {
        crate::protocol::cancellation::check()?;
        if matches.len() >= limit || content_matches >= content_limit {
            break;
        }
        let Some(indexed_file) = index.file(id) else {
            continue;
        };
        let path = &indexed_file.path;
        if page.is_some_and(|page| !page.accepts_path(path))
            || !scope_allows(&request.scope_paths, path)
            || !file_mask_allows(&masks, path) {
            continue;
        }
        let file = root.join(path);
        let Some(text) = read_searchable_text(&file) else {
            continue;
        };
        for (index, line) in text.split('\n').enumerate() {
            crate::protocol::cancellation::check()?;
            if matcher.matches(line) {
                let result = SearchMatch {
                    kind: "content".to_string(),
                    path: path.clone(),
                    line: Some(index + 1),
                    preview: line.trim().to_string(),
                    symbol_name: None,
                    name_match_ranges: Vec::new(),
                    matching_degree: None,
                    is_ignored: None,
                };
                if page.is_some_and(|page| !page.accepts(&result)) {
                    continue;
                }
                matches.push(result);
                content_matches += 1;
                if matches.len() >= limit || content_matches >= content_limit {
                    break;
                }
            }
        }
    }

    Ok(SearchResponse { matches })
}

/// Combines file, content, and Java-symbol results for Search Everywhere.
pub fn search_everywhere(request: SearchRequest) -> Result<SearchResponse, CoreError> {
    search_everywhere_with_page(request, None)
}

/// Searches one bounded page when a continuation state is supplied.
pub(crate) fn search_everywhere_with_page(
    request: SearchRequest,
    mut page: Option<&mut SearchPage>,
) -> Result<SearchResponse, CoreError> {
    let root = existing_root(&request.root)?;
    let indexing_policy = super::indexing::context(&root);
    let query = request.query.trim().to_string();
    if query.is_empty() {
        return Ok(SearchResponse {
            matches: Vec::new(),
        });
    }
    let rules = VisibilityRules::new(
        request.hidden_directory_names.clone(),
        request.hidden_file_patterns.clone(),
    );
    let matcher = Matcher::new(
        &query,
        request.case_sensitive,
        request.whole_words,
        request.regular_expression,
    )?;
    let masks = parse_file_mask(&request.file_mask);
    let limit = request.max_results.max(1).min(10_000);
    let file_limit = if page.as_ref().is_some_and(|page| page.exhausted("file")) {
        0
    } else {
        request.max_file_results.unwrap_or(limit).min(limit)
    };
    let symbol_limit = if page
        .as_ref()
        .is_some_and(|page| page.exhausted("type") && page.exhausted("symbol"))
    {
        0
    } else {
        request.max_symbol_results.unwrap_or(limit).min(limit)
    };
    let content_limit = if page.as_ref().is_some_and(|page| page.exhausted("content")) {
        0
    } else {
        request.max_content_results.unwrap_or(limit).min(limit)
    };
    let mut files = Vec::new();
    let mut types = Vec::new();
    let mut symbols = Vec::new();
    let mut last_flush = None;
    if file_limit > 0 {
        let name_rules = VisibilityRules {
            // Generated output is a file-name source, not a content/symbol index.
            hidden_directories: rules
                .hidden_directories
                .iter()
                .filter(|name| {
                    !request.include_generated_file_names
                        || !BUILT_IN_HIDDEN_DIRECTORIES.contains(&name.as_str())
                        || [".git", ".svn", ".worktree", ".worktrees"].contains(&name.as_str())
                })
                .cloned()
                .collect(),
            hidden_file_patterns: rules.hidden_file_patterns.clone(),
        };
        let names = search_index::get_names(&root, &name_rules)?;
        let names = names
            .read()
            .map_err(|_| CoreError::new(ErrorCode::Unknown, "Search index lock was poisoned"))?;
        for id in names.all_file_ids() {
            crate::protocol::cancellation::check()?;
            let Some(file) = names.file(id) else { continue };
            if !file_mask_allows(&masks, &file.path) {
                continue;
            }
            let name = file.path.rsplit('/').next().unwrap_or(&file.path);
            let mut result = SearchMatch {
                kind: "file".to_string(),
                path: file.path.clone(),
                line: None,
                preview: file.path.clone(),
                symbol_name: None,
                name_match_ranges: Vec::new(),
                matching_degree: None,
                is_ignored: None,
            };
            if match_everywhere_name(&request, &matcher, name, &mut result) {
                result.matching_degree.get_or_insert(0);
            } else if match_everywhere_name(&request, &matcher, &file.path, &mut result) {
                // Directory-only matches remain candidates (including Agent mentions), below every basename hit.
                result.matching_degree = Some(-1);
                result.name_match_ranges.clear();
            } else {
                continue;
            }
            if let Some(page) = page.as_ref() {
                page.push(&mut files, result, file_limit);
            } else {
                files.push(result);
            }
            emit_search_results(
                [
                    (&mut files, file_limit),
                    (&mut types, symbol_limit),
                    (&mut symbols, symbol_limit),
                ],
                limit,
                &mut last_flush,
                std::time::Instant::now(),
                false,
            );
        }
    }
    emit_search_results(
        [
            (&mut files, file_limit),
            (&mut types, symbol_limit),
            (&mut symbols, symbol_limit),
        ],
        limit,
        &mut last_flush,
        std::time::Instant::now(),
        true,
    );
    // Publish names before content parsing or symbol extraction starts.
    // Zero source caps are execution boundaries, not just post-scan truncation.
    let shared_index = if symbol_limit > 0 || content_limit > 0 {
        Some(search_index::get_or_build(&root, &rules)?)
    } else {
        None
    };
    let index = shared_index
        .as_ref()
        .map(|index| {
            index
                .read()
                .map_err(|_| CoreError::new(ErrorCode::Unknown, "Search index lock was poisoned"))
        })
        .transpose()?;
    if symbol_limit > 0 {
        let index = index
            .as_ref()
            .expect("symbol source requires content index");
        for id in index.all_file_ids() {
            crate::protocol::cancellation::check()?;
            let Some(file) = index.file(id) else { continue };
            if !file_mask_allows(&masks, &file.path) {
                continue;
            }
            for symbol in index.symbols(id) {
                let mut result = search_index::make_symbol_match(symbol, file.path.clone());
                if match_everywhere_name(&request, &matcher, &symbol.name, &mut result) {
                    if result.kind == "type" {
                        if let Some(page) = page.as_ref() {
                            page.push(&mut types, result, symbol_limit);
                        } else {
                            types.push(result);
                        }
                    } else {
                        if let Some(page) = page.as_ref() {
                            page.push(&mut symbols, result, symbol_limit);
                        } else {
                            symbols.push(result);
                        }
                    }
                    emit_search_results(
                        [
                            (&mut files, file_limit),
                            (&mut types, symbol_limit),
                            (&mut symbols, symbol_limit),
                        ],
                        limit,
                        &mut last_flush,
                        std::time::Instant::now(),
                        false,
                    );
                }
            }
        }
    }
    emit_search_results(
        [
            (&mut files, file_limit),
            (&mut types, symbol_limit),
            (&mut symbols, symbol_limit),
        ],
        limit,
        &mut last_flush,
        std::time::Instant::now(),
        true,
    );
    if let Some(page) = page.as_mut() {
        page.finish("file", &mut files, file_limit);
        page.finish("type", &mut types, symbol_limit);
        page.finish("symbol", &mut symbols, symbol_limit);
    } else {
        for (bucket, cap) in [
            (&mut files, file_limit),
            (&mut types, symbol_limit),
            (&mut symbols, symbol_limit),
        ] {
            rank_search_bucket(bucket, cap);
        }
    }
    let mut content_request = request.clone();
    content_request.max_file_results = Some(0);
    if page.is_some() {
        content_request.max_results = content_limit + 1;
        content_request.max_content_results = Some(content_limit + 1);
    }
    let mut content = if content_limit > 0 {
        search_with_index(
            &root,
            &content_request,
            &query,
            index
                .as_ref()
                .expect("content source requires content index"),
            page.as_deref(),
        )?
        .matches
    } else {
        Vec::new()
    };
    if let Some(page) = page.as_mut() {
        page.finish("content", &mut content, content_limit);
    }
    let mut matches = files;
    matches.extend(types);
    matches.extend(symbols);
    matches.extend(content);
    matches.truncate(limit);
    drop(index);
    // Ask Git once for the bounded result set, not once per row or indexed file.
    let paths: Vec<String> = matches.iter().map(|item| item.path.clone()).collect();
    if let Some(ignored) = crate::git::ignored_paths(&root, &paths)? {
        for item in &mut matches {
            item.is_ignored = Some(ignored.contains(&item.path));
        }
    }
    if let Some(policy) = &indexing_policy {
        policy.check()?;
    }
    Ok(SearchResponse { matches })
}

/// Stable total ordering shared by bounded collection and cursor continuation.
pub(crate) fn compare_search_matches(a: &SearchMatch, b: &SearchMatch) -> std::cmp::Ordering {
    b.matching_degree
        .cmp(&a.matching_degree)
        .then_with(|| a.path.cmp(&b.path))
        .then_with(|| a.line.cmp(&b.line))
        .then_with(|| a.symbol_name.cmp(&b.symbol_name))
}

fn rank_search_bucket(bucket: &mut Vec<SearchMatch>, cap: usize) {
    bucket.sort_by(compare_search_matches);
    bucket.truncate(cap);
}

// Replaceable snapshots let slow hosts keep only the newest batch. Ranking
// before each cap preserves the final top matches even when better hits arrive late.
fn emit_search_results(
    buckets: [(&mut Vec<SearchMatch>, usize); 3],
    limit: usize,
    last_flush: &mut Option<std::time::Instant>,
    now: std::time::Instant,
    force: bool,
) {
    if !crate::git::execution_events::has_sink()
        || buckets.iter().all(|(bucket, _)| bucket.is_empty())
        || (!force
            && last_flush.is_some_and(|last| {
                now.duration_since(last) < std::time::Duration::from_millis(100)
            }))
    {
        return;
    }
    let mut matches = Vec::new();
    for (bucket, cap) in buckets {
        rank_search_bucket(bucket, cap + 1);
        matches.extend(
            bucket
                .iter()
                .take(cap.min(limit.saturating_sub(matches.len())))
                .cloned(),
        );
    }
    *last_flush = Some(now);
    crate::git::execution_events::emit(serde_json::json!({
        "type": "searchResults", "results": SearchResponse { matches }
    }));
}

fn match_everywhere_name(
    request: &SearchRequest,
    literal: &Matcher,
    name: &str,
    result: &mut SearchMatch,
) -> bool {
    if request.regular_expression || request.whole_words || request.case_sensitive {
        return literal.matches(name);
    }
    let Some(hit) = super::name_matching::match_name(request.query.trim(), name) else {
        return false;
    };
    result.name_match_ranges = hit.ranges;
    result.matching_degree = Some(hit.degree);
    true
}

/// Computes per-file replacements without writing any workspace content.
pub fn replace_preview(
    request: ReplacementPreviewRequest,
) -> Result<ReplacementPreviewResponse, CoreError> {
    let root = existing_root(&request.root)?;
    let indexing_policy = super::indexing::context(&root);
    let query = request.query.trim().to_string();
    if query.is_empty() {
        return Ok(ReplacementPreviewResponse { files: Vec::new() });
    }
    let rules = VisibilityRules::new(
        request.hidden_directory_names.clone(),
        request.hidden_file_patterns.clone(),
    );
    let shared_index = search_index::get_or_build(&root, &rules)?;
    let index = shared_index
        .read()
        .map_err(|_| CoreError::new(ErrorCode::Unknown, "Search index lock was poisoned"))?;
    let matcher = Matcher::new(
        &query,
        request.case_sensitive,
        request.whole_words,
        request.regular_expression,
    )?;
    let candidate_ids = index.candidate_ids(&query, request.regular_expression);
    let candidate_set = candidate_ids.iter().copied().collect::<HashSet<_>>();
    let paths = if request.paths.is_empty() {
        candidate_ids
            .into_iter()
            .filter_map(|id| index.file(id).map(|file| file.path.clone()))
            .collect::<Vec<_>>()
    } else {
        let mut paths = Vec::new();
        for value in &request.paths {
            let relative = safe_relative_path_string(value)?;
            let include = request.text_overrides.contains_key(&relative)
                || index
                    .id_for_path(&relative)
                    .map(|id| candidate_set.contains(&id))
                    .unwrap_or(true);
            if include {
                paths.push(relative);
            }
        }
        paths
    };
    drop(index);
    let masks = parse_file_mask(&request.file_mask);
    let mut files = Vec::new();
    for path in paths {
        crate::protocol::cancellation::check()?;
        let relative = safe_relative_path_string(&path)?;
        if !file_mask_allows(&masks, &relative) {
            continue;
        }
        let file = root.join(&relative);
        if super::indexing::is_excluded(&root, &file, false)? {
            continue;
        }
        let text = request
            .text_overrides
            .get(&relative)
            .cloned()
            .or_else(|| read_searchable_text(&file));
        let Some(text) = text else { continue };
        let mut matches = Vec::new();
        let mut replaced_lines = Vec::new();
        for (index, line) in text.split('\n').enumerate() {
            crate::protocol::cancellation::check()?;
            let (after, occurrence_count) =
                matcher.replace_with_options(line, &request.replacement, request.preserve_case);
            replaced_lines.push(after.clone());
            if occurrence_count > 0 {
                matches.push(crate::protocol::ReplacementMatch {
                    line: index + 1,
                    before: line.to_string(),
                    after,
                    occurrence_count,
                });
            }
        }
        if !matches.is_empty() {
            files.push(crate::protocol::ReplacementFile {
                path: relative,
                matches,
                replacement_text: replaced_lines.join("\n"),
            });
        }
    }
    files.sort_by(|left, right| left.path.cmp(&right.path));
    if let Some(policy) = &indexing_policy {
        policy.check()?;
    }
    Ok(ReplacementPreviewResponse { files })
}

/// Builds or reuses the search index and reports its current size.
pub fn warm_search_index(
    request: SearchIndexRequest,
) -> Result<SearchIndexStatusResponse, CoreError> {
    let root = existing_root(&request.root)?;
    let rules = VisibilityRules::new(request.hidden_directory_names, request.hidden_file_patterns);
    let index = search_index::get_or_build(&root, &rules)?;
    let index = index
        .read()
        .map_err(|_| CoreError::new(ErrorCode::Unknown, "Search index lock was poisoned"))?;
    let stats = index.stats();
    Ok(SearchIndexStatusResponse {
        file_count: stats.file_count,
        symbol_count: stats.symbol_count,
        posting_count: stats.posting_count,
        rebuilt: false,
    })
}

/// Applies changed paths to a cached index, rebuilding when its rules changed.
pub fn update_search_index(
    request: SearchIndexUpdateRequest,
) -> Result<SearchIndexStatusResponse, CoreError> {
    let root = existing_root(&request.root)?;
    let rules = VisibilityRules::new(request.hidden_directory_names, request.hidden_file_patterns);
    if request.paths.iter().any(|path| {
        path.ends_with(".gitignore")
            || path.contains(".git/")
            || path.ends_with(".git")
            || root.join(path).is_dir()
    }) {
        super::indexing::refresh(&root)?;
    }
    let outcome = search_index::update_paths(&root, &rules, &request.paths);
    let rebuilt = matches!(outcome, UpdateOutcome::RequiresRebuild);
    if rebuilt {
        search_index::invalidate_root(&root);
    }
    let index = search_index::get_or_build(&root, &rules)?;
    // Refresh starts with no Git decisions. Publish only after traversal has
    // resolved them, otherwise providers briefly (or permanently) lose exclusions.
    super::super::lsp::indexing_changed(&root)?;
    let index = index
        .read()
        .map_err(|_| CoreError::new(ErrorCode::Unknown, "Search index lock was poisoned"))?;
    let stats = index.stats();
    Ok(SearchIndexStatusResponse {
        file_count: stats.file_count,
        symbol_count: stats.symbol_count,
        posting_count: stats.posting_count,
        rebuilt: rebuilt || matches!(outcome, UpdateOutcome::NotIndexed),
    })
}

/// Drops the cached index for one validated workspace root.
pub fn invalidate_search_index(request: SearchIndexRequest) -> Result<(), CoreError> {
    let requested_root = PathBuf::from(&request.root);
    let root = search_index::canonicalize_with_missing_components(&requested_root)
        .unwrap_or(requested_root);
    search_index::invalidate_root(&root);
    Ok(())
}

/// Reads one bounded, workspace-contained file as UTF-8 text.
pub fn read_file(request: FileReadRequest) -> Result<FileReadResponse, CoreError> {
    let root = existing_root(&request.root)?;
    let path = safe_relative_path(&root, &request.path)?;
    let metadata = fs::metadata(&path)?;
    if metadata.len() > MAX_OPEN_FILE_SIZE {
        return Err(
            CoreError::new(ErrorCode::ParseFailed, "File is too large to open")
                .with_details("The maximum supported file size is 32 MB"),
        );
    }
    let text = fs::read_to_string(&path).map_err(|error| {
        CoreError::new(ErrorCode::ParseFailed, "File is not valid UTF-8")
            .with_details(error.to_string())
    })?;
    if !is_plain_text(&text) {
        return Err(CoreError::new(
            ErrorCode::ParseFailed,
            "File is not plain text",
        ));
    }
    Ok(FileReadResponse {
        path: relative_path(&path, &root),
        text,
    })
}

/// Replaces one workspace-contained file and refreshes its cached search entry.
pub fn write_file(request: FileWriteRequest) -> Result<FileWriteResponse, CoreError> {
    let root = existing_root(&request.root)?;
    let path = writable_relative_path(&root, &request.path)?;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(&path, request.text.as_bytes()).map_err(|error| {
        CoreError::new(ErrorCode::PermissionDenied, "Could not write file")
            .with_details(error.to_string())
    })?;
    search_index::update_cached_file(&root, &path);
    Ok(FileWriteResponse {
        path: relative_path(&path, &root),
        bytes_written: request.text.len(),
    })
}

/// Effective built-in plus caller-supplied rules for excluding workspace paths.
pub(crate) struct VisibilityRules {
    pub(crate) hidden_directories: Vec<String>,
    pub(crate) hidden_file_patterns: Vec<String>,
}

impl VisibilityRules {
    pub(crate) fn new(hidden_directories: Vec<String>, hidden_files: Vec<String>) -> Self {
        let mut directories = BUILT_IN_HIDDEN_DIRECTORIES
            .iter()
            .map(|value| (*value).to_string())
            .collect::<Vec<_>>();
        directories.extend(hidden_directories);
        let mut files = BUILT_IN_HIDDEN_FILE_PATTERNS
            .iter()
            .map(|value| (*value).to_string())
            .collect::<Vec<_>>();
        files.extend(hidden_files);
        Self {
            hidden_directories: normalize(directories),
            hidden_file_patterns: normalize(files),
        }
    }

    pub(crate) fn is_hidden(&self, path: &str, is_directory: bool) -> bool {
        let components = path
            .split('/')
            .filter(|value| !value.is_empty())
            .collect::<Vec<_>>();
        if components.iter().any(|component| {
            self.hidden_directories
                .iter()
                .any(|hidden| hidden.eq_ignore_ascii_case(component))
        }) {
            return true;
        }
        let directory_count = components.len().saturating_sub(usize::from(!is_directory));
        let mut folder_globs = self
            .hidden_file_patterns
            .iter()
            .filter_map(|pattern| folder_glob(pattern))
            .peekable();
        if folder_globs.peek().is_some() {
            // Each ancestor prefix is joined once and shared by every folder
            // rule, instead of being rebuilt per rule.
            let prefixes = (1..=directory_count)
                .map(|count| components[..count].join("/"))
                .collect::<Vec<_>>();
            if folder_globs.any(|glob| {
                prefixes
                    .iter()
                    .any(|prefix| path_glob_matches(glob, prefix))
            }) {
                return true;
            }
        }
        if is_directory {
            return false;
        }
        let last = components.last().copied().unwrap_or_default();
        self.hidden_file_patterns
            .iter()
            .any(|pattern| path_glob_matches(pattern, last) || path_glob_matches(pattern, path))
    }
}

/// Matches a hidden-path glob, letting a leading `**/` stand for zero or more
/// folders, so `**/dist/` covers a root-level `dist` as well as `a/b/dist`.
///
/// `*` already spans `/`, which covers the non-root case; the root case needs
/// the second attempt because the glob would otherwise demand a literal `/`.
fn path_glob_matches(pattern: &str, value: &str) -> bool {
    glob_matches(pattern, value)
        || pattern
            .strip_prefix("**/")
            .is_some_and(|rest| glob_matches(rest, value))
}

/// The folder glob of a hidden-path entry that ends in `/`, `/*` or `/**`.
///
/// Such an entry names a folder from the project root (or at any depth when it
/// starts with `**/`), so the folder and everything below it is hidden instead
/// of leaving an empty folder behind. Other entries keep their file-only
/// meaning, as pinned by `shared/fixtures/search/exclusions.json`.
fn folder_glob(pattern: &str) -> Option<&str> {
    let glob = pattern
        .strip_suffix("/**")
        .or_else(|| pattern.strip_suffix("/*"))
        .or_else(|| pattern.strip_suffix('/'))?;
    (!glob.is_empty()).then_some(glob)
}

fn scan_node(
    path: &Path,
    root: &Path,
    rules: &VisibilityRules,
    files: &mut Vec<String>,
    nested_worktrees: &mut Vec<String>,
    incomplete_directories: &mut Vec<String>,
) -> Result<WorkspaceNode, CoreError> {
    crate::protocol::cancellation::check()?;
    let metadata = fs::symlink_metadata(path)?;
    let relative = relative_path(path, root);
    let name = path
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("Workspace")
        .to_string();
    if super::indexing::is_excluded(root, path, metadata.is_dir())? {
        return Ok(WorkspaceNode {
            path: relative,
            name,
            is_directory: metadata.is_dir(),
            children: None,
        });
    }
    if !metadata.is_dir() {
        files.push(relative.clone());
        return Ok(WorkspaceNode {
            path: relative,
            name,
            is_directory: false,
            children: None,
        });
    }

    let listing = visible_children(path, root, rules, ChildOrder::Traversal)?;
    nested_worktrees.extend(
        listing
            .nested_worktrees
            .iter()
            .map(|worktree| relative_path(worktree, root)),
    );
    let mut visible_children = Vec::new();
    for (child_path, _) in listing.children {
        crate::protocol::cancellation::check()?;
        match scan_node(
            &child_path,
            root,
            rules,
            files,
            nested_worktrees,
            incomplete_directories,
        ) {
            Ok(child) => visible_children.push(child),
            Err(error)
                if matches!(
                    error.code,
                    ErrorCode::PermissionDenied | ErrorCode::WorkspaceNotFound
                ) =>
            {
                incomplete_directories.push(relative_path(&child_path, root));
                eprintln!(
                    "Workspace skipped directory {:?}: {}",
                    relative_path(&child_path, root),
                    error.message
                );
            }
            Err(error) => return Err(error),
        }
    }
    Ok(WorkspaceNode {
        path: relative,
        name,
        is_directory: true,
        children: Some(visible_children),
    })
}

/// Collects the snapshot file list without building tree nodes.
fn collect_snapshot_files(
    path: &Path,
    root: &Path,
    rules: &VisibilityRules,
    files: &mut Vec<String>,
    nested_worktrees: &mut Vec<String>,
    incomplete_directories: &mut Vec<String>,
) -> Result<(), CoreError> {
    crate::protocol::cancellation::check()?;
    if super::indexing::is_excluded(root, path, true)? {
        return Ok(());
    }
    let listing = visible_children(path, root, rules, ChildOrder::Traversal)?;
    nested_worktrees.extend(
        listing
            .nested_worktrees
            .iter()
            .map(|worktree| relative_path(worktree, root)),
    );
    for (child_path, is_directory) in listing.children {
        if is_directory {
            // A directory that vanished mid-scan is skipped, as in `scan_node`.
            if let Err(error) = collect_snapshot_files(
                &child_path,
                root,
                rules,
                files,
                nested_worktrees,
                incomplete_directories,
            ) {
                if !matches!(
                    error.code,
                    ErrorCode::PermissionDenied | ErrorCode::WorkspaceNotFound
                ) {
                    return Err(error);
                }
                incomplete_directories.push(relative_path(&child_path, root));
                eprintln!(
                    "Workspace skipped directory {:?}: {}",
                    relative_path(&child_path, root),
                    error.message
                );
            }
        } else {
            if super::indexing::is_excluded(root, &child_path, false)? {
                continue;
            }
            files.push(relative_path(&child_path, root));
        }
    }
    Ok(())
}

fn node_name(path: &Path) -> String {
    path.file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("Workspace")
        .to_string()
}

/// How `visible_children` orders the siblings it returns. Directories always come first.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ChildOrder {
    /// The rows the project tree displays: IDEA's natural file-name order, where digit
    /// runs compare by value (see `file_name_order`).
    Tree,
    /// The sequence behind flat file lists and the search index: lowercased names in
    /// byte order. Consumers that keep only the first N entries of that sequence, such
    /// as Windows Quick Open (the first 100 matches of the snapshot list), depend on it,
    /// so a display-order change must not reorder it.
    Traversal,
}

/// Visible children of one directory in the requested order, plus the nested linked
/// worktrees that were left out of it.
pub(crate) struct VisibleDirectory {
    /// Child paths and whether each is a directory, sorted by the requested `ChildOrder`.
    pub(crate) children: Vec<(PathBuf, bool)>,
    pub(crate) nested_worktrees: Vec<PathBuf>,
}

#[cfg(test)]
thread_local! {
    /// Scoped enumeration trace for pruning regressions; absent in production builds.
    pub(crate) static DIRECTORY_VISITS: std::cell::RefCell<Option<Vec<PathBuf>>> = const { std::cell::RefCell::new(None) };
}

/// Lists the children that workspace scans descend into. Snapshot and search
/// share this so the tree, the file list, and the index always agree.
pub(crate) fn visible_children(
    path: &Path,
    root: &Path,
    rules: &VisibilityRules,
    order: ChildOrder,
) -> Result<VisibleDirectory, CoreError> {
    #[cfg(test)]
    DIRECTORY_VISITS.with_borrow_mut(|visits| {
        if let Some(visits) = visits {
            visits.push(path.to_path_buf());
        }
    });
    let mut nested_worktrees = Vec::new();
    let mut children = fs::read_dir(path)
        .map_err(CoreError::from)?
        .filter_map(Result::ok)
        .filter_map(|entry| visible_child(entry, root, rules, &mut nested_worktrees))
        .collect::<Vec<_>>();
    match order {
        // Siblings follow IDEA's Project view: directories first, then natural file-name
        // order, so `v0.1.4.md` precedes `v0.1.12.md`.
        ChildOrder::Tree => children.sort_by_cached_key(|(path, is_directory)| {
            (
                std::cmp::Reverse(*is_directory),
                FileNameKey::new(
                    path.file_name()
                        .and_then(|value| value.to_str())
                        .unwrap_or_default(),
                ),
            )
        }),
        ChildOrder::Traversal => children.sort_by(|left, right| {
            right.1.cmp(&left.1).then_with(|| {
                left.0
                    .file_name()
                    .and_then(|value| value.to_str())
                    .unwrap_or_default()
                    .to_lowercase()
                    .cmp(
                        &right
                            .0
                            .file_name()
                            .and_then(|value| value.to_str())
                            .unwrap_or_default()
                            .to_lowercase(),
                    )
            })
        }),
    }
    nested_worktrees.sort();
    Ok(VisibleDirectory {
        children,
        nested_worktrees,
    })
}

/// Checks only until the first visible entry; unreadable directories remain expandable.
fn directory_is_visibly_empty(path: &Path, root: &Path, rules: &VisibilityRules) -> bool {
    let Ok(mut entries) = fs::read_dir(path) else {
        return false;
    };
    !entries.any(|entry| match entry {
        Ok(entry) => visible_child(entry, root, rules, &mut Vec::new()).is_some(),
        Err(_) => true,
    })
}

/// Applies the same visibility boundary to full listings and leaf probes.
fn visible_child(
    entry: fs::DirEntry,
    root: &Path,
    rules: &VisibilityRules,
    nested_worktrees: &mut Vec<PathBuf>,
) -> Option<(PathBuf, bool)> {
    let child_path = entry.path();
    let metadata = fs::symlink_metadata(&child_path).ok()?;
    if metadata.file_type().is_symlink()
        || rules.is_hidden(&relative_path(&child_path, root), metadata.is_dir())
    {
        return None;
    }
    if metadata.is_dir() && is_nested_linked_worktree(&child_path) {
        nested_worktrees.push(child_path);
        return None;
    }
    Some((child_path, metadata.is_dir()))
}

/// A `.git` pointer file is a single `gitdir:` line; anything larger is not one.
const MAX_GIT_POINTER_FILE_SIZE: u64 = 4 * 1024;

/// Returns whether `directory` is a linked worktree checked out inside the main
/// worktree of the repository that owns it, such as `.claude/worktrees/<name>`.
///
/// Such a checkout repeats the project's own files, and agent tools can create
/// several of them, so scanning them multiplies the tree, index, and watcher
/// load. Git records a linked worktree as `<common>/.git/worktrees/<id>`;
/// submodules (`.git/modules/...`), bare repositories, and worktrees placed
/// outside their main checkout do not match and stay visible.
pub(crate) fn is_nested_linked_worktree(directory: &Path) -> bool {
    let marker = directory.join(".git");
    let Ok(metadata) = fs::symlink_metadata(&marker) else {
        return false;
    };
    if !metadata.is_file() || metadata.len() > MAX_GIT_POINTER_FILE_SIZE {
        return false;
    }
    let Ok(text) = fs::read_to_string(&marker) else {
        return false;
    };
    let Some(git_directory) = text
        .lines()
        .next()
        .and_then(|line| line.strip_prefix("gitdir:"))
        .map(str::trim)
        .filter(|value| !value.is_empty())
    else {
        return false;
    };
    let git_directory = directory.join(git_directory);
    let Some(worktrees) = git_directory.parent() else {
        return false;
    };
    if worktrees.file_name().and_then(|name| name.to_str()) != Some("worktrees") {
        return false;
    }
    let Some(common_directory) = worktrees.parent() else {
        return false;
    };
    if common_directory.file_name().and_then(|name| name.to_str()) != Some(".git") {
        return false;
    }
    let Some(main_worktree) = common_directory.parent() else {
        return false;
    };
    let (Ok(main_worktree), Ok(directory)) =
        (fs::canonicalize(main_worktree), fs::canonicalize(directory))
    else {
        return false;
    };
    directory != main_worktree && directory.starts_with(&main_worktree)
}

/// Returns whether a workspace-relative path lies below a nested linked
/// worktree. Used for watcher-reported paths that never went through a scan.
pub(crate) fn is_inside_nested_linked_worktree(root: &Path, relative: &str) -> bool {
    let components = relative
        .split('/')
        .filter(|value| !value.is_empty())
        .collect::<Vec<_>>();
    let mut directory = root.to_path_buf();
    for component in components.iter().take(components.len().saturating_sub(1)) {
        directory.push(component);
        if is_nested_linked_worktree(&directory) {
            return true;
        }
    }
    false
}

pub(crate) fn existing_root(value: &str) -> Result<PathBuf, CoreError> {
    let path = PathBuf::from(value);
    let metadata = fs::metadata(&path)
        .map_err(|_| CoreError::new(ErrorCode::WorkspaceNotFound, "Workspace does not exist"))?;
    if !metadata.is_dir() {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Workspace root must be a directory",
        ));
    }
    fs::canonicalize(path).map_err(CoreError::from)
}

fn safe_relative_path(root: &Path, value: &str) -> Result<PathBuf, CoreError> {
    let relative = Path::new(value);
    if relative.is_absolute() || invalid_relative_path(value) {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Path must be relative to the workspace",
        ));
    }
    let path = root.join(relative);
    let canonical = fs::canonicalize(path).map_err(CoreError::from)?;
    if !canonical.starts_with(root) {
        return Err(CoreError::new(
            ErrorCode::PermissionDenied,
            "Path is outside the workspace",
        ));
    }
    Ok(canonical)
}

fn writable_relative_path(root: &Path, value: &str) -> Result<PathBuf, CoreError> {
    let relative = Path::new(value);
    if relative.is_absolute() || invalid_relative_path(value) {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Path must be relative to the workspace",
        ));
    }
    let path = root.join(relative);
    if let Some(parent) = path.parent() {
        let mut existing_parent = parent;
        while !fs::try_exists(existing_parent)? {
            existing_parent = existing_parent.parent().ok_or_else(|| {
                CoreError::new(ErrorCode::PermissionDenied, "Path is outside the workspace")
            })?;
        }
        let canonical_parent = fs::canonicalize(existing_parent).map_err(CoreError::from)?;
        if !canonical_parent.starts_with(root) {
            return Err(CoreError::new(
                ErrorCode::PermissionDenied,
                "Path is outside the workspace",
            ));
        }
    }
    if let Ok(metadata) = fs::symlink_metadata(&path) {
        if metadata.file_type().is_symlink() {
            return Err(CoreError::new(
                ErrorCode::PermissionDenied,
                "Path is outside the workspace",
            ));
        }
        let canonical = fs::canonicalize(&path).map_err(CoreError::from)?;
        if !canonical.starts_with(root) {
            return Err(CoreError::new(
                ErrorCode::PermissionDenied,
                "Path is outside the workspace",
            ));
        }
    }
    Ok(path)
}

pub(crate) fn relative_path(path: &Path, root: &Path) -> String {
    path.strip_prefix(root)
        .unwrap_or(path)
        .to_string_lossy()
        .replace('\\', "/")
        .trim_matches('/')
        .to_string()
}

fn normalize(values: Vec<String>) -> Vec<String> {
    let mut result = Vec::new();
    for value in values {
        let normalized = value.trim().to_string();
        if normalized.is_empty()
            || result
                .iter()
                .any(|existing: &String| existing.eq_ignore_ascii_case(&normalized))
        {
            continue;
        }
        result.push(normalized);
    }
    result
}

/// Matches IDEA's Preserve Case behavior for literal replacement text.
///
/// All-uppercase matches uppercase the replacement, initial-uppercase matches
/// capitalize it, and camelCase or mixed-case matches leave it unchanged.
fn apply_case_pattern(matched: &str, replacement: &str) -> String {
    let letters = matched.chars().filter(|value| value.is_alphabetic());
    let mut has_lower = false;
    let mut has_upper = false;
    for letter in letters {
        if letter.is_lowercase() {
            has_lower = true;
        } else if letter.is_uppercase() {
            has_upper = true;
        }
    }
    // With no letters there is no case shape to preserve.
    if !has_lower && !has_upper {
        return replacement.to_string();
    }
    // Require multiple letters so a single `F` is not mistaken for SCREAMING_CASE.
    let letter_count = matched
        .chars()
        .filter(|value| value.is_alphabetic())
        .count();
    if has_upper && !has_lower && letter_count > 1 {
        return replacement.to_uppercase();
    }
    let first_is_upper = matched
        .chars()
        .find(|value| value.is_alphabetic())
        .is_some_and(char::is_uppercase);
    if first_is_upper {
        let mut characters = replacement.chars();
        return match characters.next() {
            Some(first) => first.to_uppercase().collect::<String>() + characters.as_str(),
            None => String::new(),
        };
    }
    replacement.to_string()
}

/// Splits a mask list such as `*.java, *.kt`; an empty list disables filtering.
fn parse_file_mask(mask: &str) -> Vec<String> {
    mask.split(',')
        .map(|part| part.trim())
        .filter(|part| !part.is_empty())
        .map(|part| part.to_string())
        .collect()
}

/// Matches masks against the file name only and accepts any matching pattern.
fn file_mask_allows(masks: &[String], path: &str) -> bool {
    if masks.is_empty() {
        return true;
    }
    let name = path.rsplit('/').next().unwrap_or(path);
    masks.iter().any(|mask| glob_matches(mask, name))
}

fn glob_matches(pattern: &str, value: &str) -> bool {
    let pattern = pattern.to_lowercase().chars().collect::<Vec<_>>();
    let value = value.to_lowercase().chars().collect::<Vec<_>>();
    let mut pattern_index = 0;
    let mut value_index = 0;
    let mut star_index = None;
    let mut star_match = 0;
    while value_index < value.len() {
        if pattern_index < pattern.len()
            && (pattern[pattern_index] == value[value_index] || pattern[pattern_index] == '?')
        {
            pattern_index += 1;
            value_index += 1;
        } else if pattern_index < pattern.len() && pattern[pattern_index] == '*' {
            star_index = Some(pattern_index);
            star_match = value_index;
            pattern_index += 1;
        } else if let Some(star) = star_index {
            pattern_index = star + 1;
            star_match += 1;
            value_index = star_match;
        } else {
            return false;
        }
    }
    while pattern_index < pattern.len() && pattern[pattern_index] == '*' {
        pattern_index += 1;
    }
    pattern_index == pattern.len()
}

/// Literal or regular-expression search semantics compiled for repeated matches.
struct Matcher {
    plain_query: String,
    regex: Option<Regex>,
    case_sensitive: bool,
    whole_words: bool,
}

impl Matcher {
    fn new(
        query: &str,
        case_sensitive: bool,
        whole_words: bool,
        regular_expression: bool,
    ) -> Result<Self, CoreError> {
        if regular_expression {
            let pattern = query.to_string();
            let regex = RegexBuilder::new(&pattern)
                .case_insensitive(!case_sensitive)
                .build()
                .map_err(|error| {
                    CoreError::new(ErrorCode::ParseFailed, "Invalid search expression")
                        .with_details(error.to_string())
                })?;
            Ok(Self {
                plain_query: query.to_string(),
                regex: Some(regex),
                case_sensitive,
                whole_words: false,
            })
        } else {
            Ok(Self {
                plain_query: query.to_string(),
                regex: None,
                case_sensitive,
                whole_words,
            })
        }
    }

    fn matches(&self, text: &str) -> bool {
        if let Some(regex) = &self.regex {
            return regex.is_match(text);
        }
        let (haystack, needle) = if self.case_sensitive {
            (text.to_string(), self.plain_query.clone())
        } else {
            (text.to_lowercase(), self.plain_query.to_lowercase())
        };
        if !self.whole_words {
            return haystack.contains(&needle);
        }
        haystack.match_indices(&needle).any(|(start, _)| {
            let end = start + needle.len();
            let before = haystack[..start].chars().next_back();
            let after = haystack[end..].chars().next();
            !before.is_some_and(is_word_character) && !after.is_some_and(is_word_character)
        })
    }

    /// Preserve Case applies only to literal replacements. Regex replacements
    /// can contain captures such as `$1`, whose meaning case rewriting breaks.
    fn replace_with_options(
        &self,
        text: &str,
        replacement: &str,
        preserve_case: bool,
    ) -> (String, usize) {
        if let Some(regex) = &self.regex {
            let count = regex.find_iter(text).count();
            return (regex.replace_all(text, replacement).into_owned(), count);
        }
        let haystack = if self.case_sensitive {
            text.to_string()
        } else {
            text.to_lowercase()
        };
        let needle = if self.case_sensitive {
            self.plain_query.clone()
        } else {
            self.plain_query.to_lowercase()
        };
        if needle.is_empty() {
            return (text.to_string(), 0);
        }
        let ranges = haystack
            .match_indices(&needle)
            .filter_map(|(start, matched)| {
                let end = start + matched.len();
                if self.whole_words {
                    let before = haystack[..start].chars().next_back();
                    let after = haystack[end..].chars().next();
                    if before.is_some_and(is_word_character) || after.is_some_and(is_word_character)
                    {
                        return None;
                    }
                }
                Some((start, end))
            })
            .collect::<Vec<_>>();
        if ranges.is_empty() {
            return (text.to_string(), 0);
        }
        let mut result = String::with_capacity(text.len());
        let mut cursor = 0;
        for (start, end) in &ranges {
            result.push_str(&text[cursor..*start]);
            if preserve_case {
                result.push_str(&apply_case_pattern(&text[*start..*end], replacement));
            } else {
                result.push_str(replacement);
            }
            cursor = *end;
        }
        result.push_str(&text[cursor..]);
        (result, ranges.len())
    }
}

pub(crate) struct JavaSymbol {
    pub(crate) name: String,
    pub(crate) kind: String,
    pub(crate) line: usize,
    pub(crate) signature: String,
}

pub(crate) fn java_symbols(path: &str, source: &str) -> Vec<JavaSymbol> {
    if !path.to_lowercase().ends_with(".java") {
        return Vec::new();
    }
    let type_pattern = Regex::new(
        r"(?m)^[ \t]*(?:(?:public|protected|private|abstract|final|static|sealed|non-sealed)\s+)*(class|interface|enum|record)\s+([A-Za-z_$][A-Za-z0-9_$]*)",
    );
    let method_pattern = Regex::new(
        r"(?m)^[ \t]*(?:(?:public|protected|private|static|final|abstract|synchronized|native|default|strictfp)\s+)*(?:<[^>\n]+>\s+)?(?:[A-Za-z_$][A-Za-z0-9_$<>,.?\[\]]*\s+)+([A-Za-z_$][A-Za-z0-9_$]*)\s*\([^;\n{}]*\)",
    );
    let mut symbols = Vec::new();
    if let Ok(expression) = type_pattern {
        for captures in expression.captures_iter(source) {
            let Some(name) = captures.get(2) else {
                continue;
            };
            let start = captures
                .get(0)
                .map(|value| value.start())
                .unwrap_or(name.start());
            symbols.push(JavaSymbol {
                name: name.as_str().to_string(),
                kind: "type".to_string(),
                line: line_number(source, start),
                signature: line_signature(source, start),
            });
        }
    }
    if let Ok(expression) = method_pattern {
        for captures in expression.captures_iter(source) {
            let Some(name) = captures.get(1) else {
                continue;
            };
            let start = captures
                .get(0)
                .map(|value| value.start())
                .unwrap_or(name.start());
            symbols.push(JavaSymbol {
                name: name.as_str().to_string(),
                kind: "symbol".to_string(),
                line: line_number(source, start),
                signature: line_signature(source, start),
            });
        }
    }
    symbols.sort_by(|left, right| {
        left.line
            .cmp(&right.line)
            .then_with(|| left.name.cmp(&right.name))
    });
    symbols
}

fn line_number(source: &str, byte_offset: usize) -> usize {
    source[..byte_offset.min(source.len())]
        .bytes()
        .filter(|byte| *byte == b'\n')
        .count()
        + 1
}

fn line_signature(source: &str, byte_offset: usize) -> String {
    let start = source[..byte_offset.min(source.len())]
        .rfind('\n')
        .map(|index| index + 1)
        .unwrap_or(0);
    let end = source[byte_offset.min(source.len())..]
        .find('\n')
        .map(|index| byte_offset.min(source.len()) + index)
        .unwrap_or(source.len());
    source[start..end].trim().to_string()
}

fn safe_relative_path_string(value: &str) -> Result<String, CoreError> {
    let path = Path::new(value);
    if path.is_absolute() || invalid_relative_path(value) {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Path must be relative to the workspace",
        ));
    }
    Ok(value.replace('\\', "/").trim_matches('/').to_string())
}

pub(crate) fn read_searchable_text(path: &Path) -> Option<String> {
    let metadata = fs::metadata(path).ok()?;
    if !metadata.is_file() || metadata.len() > MAX_FILE_SIZE {
        return None;
    }
    let text = fs::read_to_string(path).ok()?;
    is_plain_text(&text).then_some(text)
}

pub(crate) fn is_plain_text(text: &str) -> bool {
    text.chars().all(|character| {
        let value = character as u32;
        value != 0 && !(value < 0x09 || (value > 0x0D && value < 0x20) || value == 0x7F)
    })
}

fn is_word_character(character: char) -> bool {
    character.is_ascii_alphanumeric() || character == '_' || character == '$'
}

#[cfg(test)]
mod event_filter_tests {
    use super::*;

    #[test]
    fn search_snapshots_merge_at_100ms_and_keep_the_best_bounded_candidates() {
        use std::sync::{Arc, Mutex};
        use std::time::{Duration, Instant};
        let events = Arc::new(Mutex::new(Vec::<serde_json::Value>::new()));
        let received = events.clone();
        crate::git::execution_events::with_sink(
            Arc::new(move |raw| {
                received
                    .lock()
                    .unwrap()
                    .push(serde_json::from_str(raw).unwrap());
            }),
            || {
                let make_match = |name: &str, degree| SearchMatch {
                    kind: "file".into(),
                    path: name.into(),
                    line: None,
                    preview: name.into(),
                    symbol_name: None,
                    name_match_ranges: vec![],
                    matching_degree: Some(degree),
                    is_ignored: None,
                };
                let mut files = vec![make_match("First", 1)];
                let (mut types, mut symbols, mut last) = (vec![], vec![], None);
                let now = Instant::now();
                let mut flush = |files: &mut Vec<SearchMatch>, milliseconds, force| {
                    emit_search_results(
                        [(files, 1), (&mut types, 1), (&mut symbols, 1)],
                        1,
                        &mut last,
                        now + Duration::from_millis(milliseconds),
                        force,
                    );
                };
                flush(&mut files, 0, false);
                files.push(make_match("Better", 10));
                flush(&mut files, 99, false);
                assert_eq!(events.lock().unwrap().len(), 1);
                flush(&mut files, 100, false);
                files.push(make_match("Best", 20));
                flush(&mut files, 101, true);
            },
        );
        let events = events.lock().unwrap();
        assert_eq!(events.len(), 3);
        for (event, path) in events.iter().zip(["First", "Better", "Best"]) {
            assert_eq!(event["type"], "searchResults");
            assert_eq!(event["results"]["matches"].as_array().unwrap().len(), 1);
            assert_eq!(event["results"]["matches"][0]["path"], path);
        }
    }

    #[test]
    fn shared_workspace_change_fixture() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../../shared/fixtures/workspace/change-filter-v1.json"
        ))
        .unwrap();
        let paths: Vec<String> = serde_json::from_value(fixture["paths"].clone()).unwrap();
        let retained: Vec<_> = paths
            .iter()
            .filter(|path| is_workspace_event_relevant(path))
            .collect();
        assert_eq!(serde_json::to_value(retained).unwrap(), fixture["expected"]);
        let response: serde_json::Value = serde_json::from_str(&crate::execute_json(
            &serde_json::json!({
                "id": "filter", "command": "workspace.filterChanges", "payload": paths
            })
            .to_string(),
        ))
        .unwrap();
        assert_eq!(response["ok"], true, "{response}");
        assert_eq!(response["data"], fixture["expected"]);
    }
}
