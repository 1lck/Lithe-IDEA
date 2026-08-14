//! Workspace traversal, file operations, search, and replacement previews.

use super::search_index::{self, UpdateOutcome, WorkspaceSearchIndex};
use crate::protocol::{invalid_relative_path, CoreError, ErrorCode};
use crate::protocol::{
    FileReadResponse, FileWriteResponse, ReplacementPreviewResponse, SearchMatch, SearchResponse,
    WorkspaceNode, WorkspaceSnapshotResponse,
};
use regex::{Regex, RegexBuilder};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};

const BUILT_IN_HIDDEN_DIRECTORIES: &[&str] = &[
    ".git",
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
];
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
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Bounded file, content, and symbol search options.
pub struct SearchRequest {
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
    search_index::invalidate_root(&root);
    let rules = VisibilityRules::new(request.hidden_directory_names, request.hidden_file_patterns);
    let mut files = Vec::new();
    let node = scan_node(&root, &root, &rules, &mut files)?;
    Ok(WorkspaceSnapshotResponse { root: node, files })
}

/// Searches visible file paths and current file contents using the shared index.
pub fn search(request: SearchRequest) -> Result<SearchResponse, CoreError> {
    let root = existing_root(&request.root)?;
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
    search_with_index(&root, &request, &query, &index)
}

fn search_with_index(
    root: &Path,
    request: &SearchRequest,
    query: &str,
    index: &WorkspaceSearchIndex,
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
        if !file_mask_allows(&masks, path) {
            continue;
        }
        if matcher.matches(path) {
            matches.push(SearchMatch {
                kind: "file".to_string(),
                path: path.clone(),
                line: None,
                preview: path.clone(),
                symbol_name: None,
            });
            file_matches += 1;
        }
    }

    let mut content_matches = 0;
    for id in index.candidate_ids(query, request.regular_expression) {
        crate::protocol::cancellation::check()?;
        if matches.len() >= limit || content_matches >= content_limit {
            break;
        }
        let Some(indexed_file) = index.file(id) else {
            continue;
        };
        let path = &indexed_file.path;
        if !file_mask_allows(&masks, path) {
            continue;
        }
        let file = root.join(path);
        let Some(text) = read_searchable_text(&file) else {
            continue;
        };
        for (index, line) in text.split('\n').enumerate() {
            crate::protocol::cancellation::check()?;
            if matcher.matches(line) {
                matches.push(SearchMatch {
                    kind: "content".to_string(),
                    path: path.clone(),
                    line: Some(index + 1),
                    preview: line.trim().to_string(),
                    symbol_name: None,
                });
                content_matches += 1;
                if matches.len() >= limit {
                    break;
                }
            }
        }
    }

    Ok(SearchResponse { matches })
}

/// Combines file, content, and Java-symbol results for Search Everywhere.
pub fn search_everywhere(request: SearchRequest) -> Result<SearchResponse, CoreError> {
    let root = existing_root(&request.root)?;
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
    let response = search_with_index(&root, &request, &query, &index)?;
    let matcher = Matcher::new(
        &query,
        request.case_sensitive,
        request.whole_words,
        request.regular_expression,
    )?;
    let symbol_limit = request.max_symbol_results.unwrap_or(50).min(50);
    let mut types = Vec::new();
    let mut symbols = Vec::new();
    for id in index.all_file_ids() {
        crate::protocol::cancellation::check()?;
        if types.len() >= symbol_limit && symbols.len() >= symbol_limit {
            break;
        }
        let Some(indexed_file) = index.file(id) else {
            continue;
        };
        for symbol in index.symbols(id) {
            crate::protocol::cancellation::check()?;
            if !matcher.matches(&symbol.name) {
                continue;
            }
            let result = search_index::make_symbol_match(symbol, indexed_file.path.clone());
            if result.kind == "type" {
                if types.len() < symbol_limit {
                    types.push(result);
                }
            } else if symbols.len() < symbol_limit {
                symbols.push(result);
            }
        }
    }

    let (file_matches, other_matches): (Vec<_>, Vec<_>) = response
        .matches
        .into_iter()
        .partition(|value| value.kind == "file");
    let mut matches = Vec::new();
    matches.extend(file_matches);
    matches.extend(types);
    matches.extend(symbols);
    matches.extend(other_matches);
    let total_limit = request.max_results.max(1).min(10_000);
    matches.truncate(total_limit);
    Ok(SearchResponse { matches })
}

/// Computes per-file replacements without writing any workspace content.
pub fn replace_preview(
    request: ReplacementPreviewRequest,
) -> Result<ReplacementPreviewResponse, CoreError> {
    let root = existing_root(&request.root)?;
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
    let outcome = search_index::update_paths(&root, &rules, &request.paths);
    let rebuilt = matches!(outcome, UpdateOutcome::RequiresRebuild);
    if rebuilt {
        search_index::invalidate_root(&root);
    }
    let index = search_index::get_or_build(&root, &rules)?;
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
    fn new(hidden_directories: Vec<String>, hidden_files: Vec<String>) -> Self {
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
        if is_directory {
            return false;
        }
        let last = components.last().copied().unwrap_or_default();
        self.hidden_file_patterns
            .iter()
            .any(|pattern| glob_matches(pattern, last) || glob_matches(pattern, path))
    }
}

fn scan_node(
    path: &Path,
    root: &Path,
    rules: &VisibilityRules,
    files: &mut Vec<String>,
) -> Result<WorkspaceNode, CoreError> {
    crate::protocol::cancellation::check()?;
    let metadata = fs::symlink_metadata(path)?;
    let relative = relative_path(path, root);
    let name = path
        .file_name()
        .and_then(|value| value.to_str())
        .unwrap_or("Workspace")
        .to_string();
    if !metadata.is_dir() {
        files.push(relative.clone());
        return Ok(WorkspaceNode {
            path: relative,
            name,
            is_directory: false,
            children: None,
        });
    }

    let mut children = fs::read_dir(path)
        .map_err(CoreError::from)?
        .filter_map(Result::ok)
        .filter_map(|entry| {
            let child_path = entry.path();
            let metadata = fs::symlink_metadata(&child_path).ok()?;
            if metadata.file_type().is_symlink() {
                return None;
            }
            let child_relative = relative_path(&child_path, root);
            if rules.is_hidden(&child_relative, metadata.is_dir()) {
                return None;
            }
            Some((child_path, metadata.is_dir()))
        })
        .collect::<Vec<_>>();
    children.sort_by(|left, right| {
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
    });

    let mut visible_children = Vec::new();
    for (child_path, _) in children {
        crate::protocol::cancellation::check()?;
        if let Ok(child) = scan_node(&child_path, root, rules, files) {
            visible_children.push(child);
        }
    }
    Ok(WorkspaceNode {
        path: relative,
        name,
        is_directory: true,
        children: Some(visible_children),
    })
}

fn existing_root(value: &str) -> Result<PathBuf, CoreError> {
    let path = PathBuf::from(value);
    let metadata = fs::metadata(&path)
        .map_err(|_| CoreError::new(ErrorCode::WorkspaceNotFound, "Workspace does not exist"))?;
    if !metadata.is_dir() {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Workspace root must be a directory",
        ));
    }
    path.canonicalize().map_err(CoreError::from)
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
    let canonical = path.canonicalize().map_err(CoreError::from)?;
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
        while !existing_parent.exists() {
            existing_parent = existing_parent.parent().ok_or_else(|| {
                CoreError::new(ErrorCode::PermissionDenied, "Path is outside the workspace")
            })?;
        }
        let canonical_parent = existing_parent.canonicalize().map_err(CoreError::from)?;
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
        let canonical = path.canonicalize().map_err(CoreError::from)?;
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
