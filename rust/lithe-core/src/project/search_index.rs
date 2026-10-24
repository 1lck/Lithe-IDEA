//! Incremental workspace search indexing with exact final-content matching.

use crate::project::files::{
    is_inside_nested_linked_worktree, java_symbols, read_searchable_text, relative_path,
    visible_children, ChildOrder, VisibilityRules,
};
use crate::protocol::{CoreError, ErrorCode, SearchMatch};
use std::collections::{HashMap, HashSet};
use std::ffi::OsString;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock, RwLock};

/// A workspace-local search index shared by file search, Search Everywhere and
/// Replace in Files. The postings are file-level on purpose: the final matcher
/// still reads the current file, so regex, whole-word and unsaved-buffer
/// semantics remain exact.
pub(crate) struct WorkspaceSearchIndex {
    files: Vec<Option<IndexedFile>>,
    free_ids: Vec<u32>,
    path_to_id: HashMap<String, u32>,
    postings: HashMap<u32, Vec<u32>>,
    names_only: bool,
}

/// Searchable file contents and symbols stored under a stable numeric ID.
pub(crate) struct IndexedFile {
    pub(crate) path: String,
    trigrams: Vec<u32>,
    pub(crate) symbols: Vec<IndexedSymbol>,
}

#[derive(Clone)]
/// Normalized Java symbol retained for Search Everywhere results.
pub(crate) struct IndexedSymbol {
    pub(crate) name: String,
    pub(crate) kind: String,
    pub(crate) line: usize,
    pub(crate) signature: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
/// Result of attempting to apply watcher paths to an existing index.
pub(crate) enum UpdateOutcome {
    /// No compatible cached index existed, so there was nothing to update.
    NotIndexed,
    /// Every changed file was applied to the existing index in place.
    Updated,
    /// A directory or visibility change invalidated the index's global file set.
    RequiresRebuild,
}

#[derive(Debug, Clone, Copy)]
/// Counts surfaced after building or updating a workspace index.
pub(crate) struct SearchIndexStats {
    pub(crate) file_count: usize,
    pub(crate) symbol_count: usize,
    pub(crate) posting_count: usize,
}

#[derive(Clone, Hash, PartialEq, Eq)]
struct IndexKey {
    root: PathBuf,
    hidden_directories: Vec<String>,
    hidden_file_patterns: Vec<String>,
    names_only: bool,
}

type SharedIndex = Arc<RwLock<WorkspaceSearchIndex>>;

static INDEX_CACHE: OnceLock<std::sync::Mutex<HashMap<IndexKey, SharedIndex>>> = OnceLock::new();

fn cache() -> &'static std::sync::Mutex<HashMap<IndexKey, SharedIndex>> {
    INDEX_CACHE.get_or_init(|| std::sync::Mutex::new(HashMap::new()))
}

fn key(root: &Path, rules: &VisibilityRules) -> IndexKey {
    IndexKey {
        root: root.to_path_buf(),
        hidden_directories: rules.hidden_directories.clone(),
        hidden_file_patterns: rules.hidden_file_patterns.clone(),
        names_only: false,
    }
}

pub(crate) fn get_or_build(root: &Path, rules: &VisibilityRules) -> Result<SharedIndex, CoreError> {
    // Hold the cache lock during the first build. This prevents a rapid sequence
    // of keystrokes from constructing several copies of a large index at once.
    let mut indexes = cache()
        .lock()
        .map_err(|_| CoreError::new(ErrorCode::Unknown, "Search index lock was poisoned"))?;
    let cache_key = key(root, rules);
    if let Some(index) = indexes.get(&cache_key) {
        return Ok(Arc::clone(index));
    }
    let index = Arc::new(RwLock::new(WorkspaceSearchIndex::build(
        root, rules, false,
    )?));
    // ponytail: one rule variant per root/kind bounds memory; alternating clients rebuild.
    // Upgrade to a measured, bounded multi-client cache only if that rebuild cost matters.
    indexes
        .retain(|existing, _| existing.root != root || existing.names_only != cache_key.names_only);
    indexes.insert(cache_key, Arc::clone(&index));
    Ok(index)
}

/// Caches names without reading generated files, binaries, or dependency source contents.
pub(crate) fn get_names(root: &Path, rules: &VisibilityRules) -> Result<SharedIndex, CoreError> {
    let mut indexes = cache()
        .lock()
        .map_err(|_| CoreError::new(ErrorCode::Unknown, "Search index lock was poisoned"))?;
    let mut cache_key = key(root, rules);
    cache_key.names_only = true;
    if let Some(index) = indexes.get(&cache_key) {
        return Ok(Arc::clone(index));
    }
    let index = Arc::new(RwLock::new(WorkspaceSearchIndex::build(root, rules, true)?));
    // ponytail: one rule variant per root/kind bounds memory; alternating clients rebuild.
    // Upgrade to a measured, bounded multi-client cache only if that rebuild cost matters.
    indexes
        .retain(|existing, _| existing.root != root || existing.names_only != cache_key.names_only);
    indexes.insert(cache_key, Arc::clone(&index));
    Ok(index)
}

pub(crate) fn invalidate_root(root: &Path) {
    let Ok(mut indexes) = cache().lock() else {
        return;
    };
    indexes.retain(|key, _| key.root != root);
}

pub(crate) fn update_cached_file(root: &Path, path: &Path) {
    let entries = {
        let Ok(indexes) = cache().lock() else {
            return;
        };
        indexes
            .iter()
            .filter(|(key, _)| key.root == root)
            .map(|(key, index)| (key.clone(), Arc::clone(index)))
            .collect::<Vec<_>>()
    };
    if entries.is_empty() {
        return;
    }
    let Some(absolute) = normalized_update_path(root, &path.to_string_lossy()) else {
        return;
    };
    let relative = relative_path(&absolute, root);
    if is_inside_nested_linked_worktree(root, &relative) {
        return;
    }
    let metadata = fs::symlink_metadata(&absolute).ok();
    for (cache_key, index) in entries {
        let rules = VisibilityRules {
            hidden_directories: cache_key.hidden_directories,
            hidden_file_patterns: cache_key.hidden_file_patterns,
        };
        if let Ok(mut index) = index.write() {
            index.update_file(&absolute, &relative, metadata.as_ref(), &rules);
        }
    }
}

/// Updates existing files in-place when a watcher reports file-only changes.
/// Directory events deliberately request a full rebuild because they can add or
/// remove an arbitrary number of descendants.
pub(crate) fn update_paths(
    root: &Path,
    _rules: &VisibilityRules,
    paths: &[String],
) -> UpdateOutcome {
    let entries = {
        let Ok(indexes) = cache().lock() else {
            return UpdateOutcome::NotIndexed;
        };
        indexes
            .iter()
            // Search-only exclusions create rule variants; keep all warm variants current.
            .filter(|(cache_key, _)| cache_key.root == root)
            .map(|(key, index)| (key.clone(), Arc::clone(index)))
            .collect::<Vec<_>>()
    };
    if entries.is_empty() {
        return UpdateOutcome::NotIndexed;
    }
    for (cache_key, shared) in entries {
        let Ok(mut index) = shared.write() else {
            return UpdateOutcome::RequiresRebuild;
        };
        let effective_rules = VisibilityRules {
            hidden_directories: cache_key.hidden_directories,
            hidden_file_patterns: cache_key.hidden_file_patterns,
        };
        for value in paths {
            let Some(absolute) = normalized_update_path(root, value) else {
                continue;
            };
            let relative = relative_path(&absolute, root);
            // Both name and content indexes exclude nested linked worktrees.
            if is_inside_nested_linked_worktree(root, &relative) {
                continue;
            }
            let metadata = fs::symlink_metadata(&absolute).ok();
            if metadata.as_ref().is_some_and(|value| value.is_dir())
                || (metadata.is_none() && index.has_descendant(&relative))
            {
                return UpdateOutcome::RequiresRebuild;
            }
            index.update_file(&absolute, &relative, metadata.as_ref(), &effective_rules);
        }
    }
    UpdateOutcome::Updated
}

impl WorkspaceSearchIndex {
    fn build(root: &Path, rules: &VisibilityRules, names_only: bool) -> Result<Self, CoreError> {
        let mut paths = Vec::new();
        collect_files(root, root, rules, &mut paths)?;
        let mut index = Self {
            files: Vec::new(),
            free_ids: Vec::new(),
            path_to_id: HashMap::with_capacity(paths.len()),
            postings: HashMap::new(),
            names_only,
        };
        for path in paths {
            crate::protocol::cancellation::check()?;
            let relative = relative_path(&path, root);
            index.add_file(&path, relative);
        }
        Ok(index)
    }

    fn add_file(&mut self, path: &Path, relative: String) {
        if let Some(existing) = self.path_to_id.get(&relative).copied() {
            self.remove_id(existing);
        }
        let (trigrams, symbols) = if self.names_only {
            (Vec::new(), Vec::new())
        } else {
            read_search_data(path, &relative)
        };
        let id = self
            .free_ids
            .pop()
            .unwrap_or_else(|| u32::try_from(self.files.len()).expect("search index is too large"));
        for trigram in &trigrams {
            let posting = self.postings.entry(*trigram).or_default();
            if let Err(position) = posting.binary_search(&id) {
                posting.insert(position, id);
            }
        }
        let file = Some(IndexedFile {
            path: relative.clone(),
            trigrams,
            symbols,
        });
        let id_index = id as usize;
        if id_index == self.files.len() {
            self.files.push(file);
        } else {
            self.files[id_index] = file;
        }
        self.path_to_id.insert(relative, id);
    }

    fn update_file(
        &mut self,
        absolute: &Path,
        relative: &str,
        metadata: Option<&fs::Metadata>,
        rules: &VisibilityRules,
    ) {
        self.remove_file(relative);
        if metadata.is_some_and(|metadata| {
            metadata.is_file()
                && !metadata.file_type().is_symlink()
                && !rules.is_hidden(relative, false)
        }) {
            self.add_file(absolute, relative.to_string());
        }
    }

    fn remove_file(&mut self, relative: &str) {
        if let Some(id) = self.path_to_id.remove(relative) {
            self.remove_id(id);
        }
    }

    fn remove_id(&mut self, id: u32) {
        let Some(file) = self.files.get_mut(id as usize).and_then(Option::take) else {
            return;
        };
        for trigram in file.trigrams {
            if let Some(posting) = self.postings.get_mut(&trigram) {
                posting.retain(|value| *value != id);
                if posting.is_empty() {
                    self.postings.remove(&trigram);
                }
            }
        }
        self.free_ids.push(id);
    }

    fn has_descendant(&self, relative: &str) -> bool {
        let prefix = if relative.is_empty() {
            String::new()
        } else {
            format!("{relative}/")
        };
        self.path_to_id.keys().any(|path| path.starts_with(&prefix))
    }

    pub(crate) fn all_file_ids(&self) -> Vec<u32> {
        self.files
            .iter()
            .enumerate()
            .filter_map(|(id, file)| file.as_ref().map(|_| id as u32))
            .collect()
    }

    pub(crate) fn file(&self, id: u32) -> Option<&IndexedFile> {
        self.files.get(id as usize).and_then(Option::as_ref)
    }

    pub(crate) fn id_for_path(&self, path: &str) -> Option<u32> {
        self.path_to_id.get(path).copied()
    }

    pub(crate) fn candidate_ids(&self, query: &str, regular_expression: bool) -> Vec<u32> {
        let Some(anchor) = search_anchor(query, regular_expression) else {
            return self.all_file_ids();
        };
        let trigrams = unique_trigrams(&anchor);
        if trigrams.is_empty() {
            return self.all_file_ids();
        }
        let mut postings = Vec::with_capacity(trigrams.len());
        for trigram in trigrams {
            let Some(posting) = self.postings.get(&trigram) else {
                return Vec::new();
            };
            postings.push(posting);
        }
        postings.sort_by_key(|posting| posting.len());
        let mut candidates = postings[0]
            .iter()
            .copied()
            .filter(|id| self.file(*id).is_some())
            .collect::<Vec<_>>();
        candidates.retain(|id| {
            postings[1..]
                .iter()
                .all(|posting| posting.binary_search(id).is_ok())
        });
        candidates.sort_unstable();
        candidates
    }

    pub(crate) fn symbols(&self, id: u32) -> &[IndexedSymbol] {
        self.file(id)
            .map(|file| file.symbols.as_slice())
            .unwrap_or(&[])
    }

    pub(crate) fn stats(&self) -> SearchIndexStats {
        SearchIndexStats {
            file_count: self.files.iter().filter(|file| file.is_some()).count(),
            symbol_count: self
                .files
                .iter()
                .filter_map(Option::as_ref)
                .map(|file| file.symbols.len())
                .sum(),
            posting_count: self.postings.values().map(Vec::len).sum(),
        }
    }
}

fn normalized_update_path(root: &Path, value: &str) -> Option<PathBuf> {
    let path = PathBuf::from(value);
    let absolute = if path.is_absolute() {
        path
    } else {
        root.join(path)
    };
    let normalized = canonicalize_with_missing_components(&absolute)?;
    normalized.starts_with(root).then_some(normalized)
}

pub(crate) fn canonicalize_with_missing_components(path: &Path) -> Option<PathBuf> {
    if let Ok(canonical) = path.canonicalize() {
        return Some(canonical);
    }
    // Deleted paths cannot be canonicalized directly. Canonicalize their
    // nearest surviving ancestor, then append the missing path components.
    let mut ancestor = path;
    let mut suffix = Vec::<OsString>::new();
    while !ancestor.exists() {
        suffix.push(ancestor.file_name()?.to_os_string());
        ancestor = ancestor.parent()?;
    }
    let mut normalized = ancestor.canonicalize().ok()?;
    for component in suffix.iter().rev() {
        normalized.push(component);
    }
    Some(normalized)
}

fn collect_files(
    root: &Path,
    path: &Path,
    rules: &VisibilityRules,
    files: &mut Vec<PathBuf>,
) -> Result<(), CoreError> {
    crate::protocol::cancellation::check()?;
    let children = match visible_children(path, root, rules, ChildOrder::Traversal) {
        Ok(listing) => listing.children,
        Err(error)
            if path != root
                && matches!(
                    error.code,
                    ErrorCode::PermissionDenied | ErrorCode::WorkspaceNotFound
                ) =>
        {
            // A transient/inaccessible descendant must not hide unrelated workspace results.
            // Log only a workspace-relative path; root errors and cancellation still propagate.
            eprintln!(
                "Search index skipped directory {:?}: {}",
                relative_path(path, root),
                error.message
            );
            return Ok(());
        }
        Err(error) => return Err(error),
    };
    for (child, is_directory) in children {
        if is_directory {
            collect_files(root, &child, rules, files)?;
        } else {
            files.push(child);
        }
    }
    Ok(())
}

fn read_search_data(path: &Path, relative: &str) -> (Vec<u32>, Vec<IndexedSymbol>) {
    let Some(text) = read_searchable_text(path) else {
        return (Vec::new(), Vec::new());
    };
    let trigrams = unique_trigrams(&text);
    let symbols = java_symbols(relative, &text)
        .into_iter()
        .map(|symbol| IndexedSymbol {
            name: symbol.name,
            kind: symbol.kind,
            line: symbol.line,
            signature: symbol.signature,
        })
        .collect();
    (trigrams, symbols)
}

fn unique_trigrams(value: &str) -> Vec<u32> {
    let normalized = value.to_lowercase();
    let bytes = normalized.as_bytes();
    let mut unique = HashSet::new();
    for window in bytes.windows(3) {
        unique.insert(encode_trigram(window));
    }
    let mut result = unique.into_iter().collect::<Vec<_>>();
    result.sort_unstable();
    result
}

fn encode_trigram(window: &[u8]) -> u32 {
    (u32::from(window[0]) << 16) | (u32::from(window[1]) << 8) | u32::from(window[2])
}

fn search_anchor(query: &str, regular_expression: bool) -> Option<String> {
    if regular_expression {
        return None;
    }
    let anchor = query.to_string();
    if anchor.is_ascii() && anchor.len() >= 3 {
        Some(anchor)
    } else {
        None
    }
}

pub(crate) fn make_symbol_match(indexed: &IndexedSymbol, path: String) -> SearchMatch {
    SearchMatch {
        kind: indexed.kind.clone(),
        path,
        line: Some(indexed.line),
        preview: indexed.signature.clone(),
        symbol_name: Some(indexed.name.clone()),
        name_match_ranges: Vec::new(),
        matching_degree: None,
        is_ignored: None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn source_caps_build_only_required_cold_indexes_and_skip_generated_text_enumeration() {
        let root = crate::tests::support::temporary_root("search-source-caps");
        fs::create_dir_all(root.join("src")).unwrap();
        let root = root.canonicalize().unwrap();
        struct Cleanup(PathBuf);
        impl Drop for Cleanup {
            fn drop(&mut self) {
                invalidate_root(&self.0);
                super::super::files::DIRECTORY_VISITS.with_borrow_mut(|visits| *visits = None);
                let _ = fs::remove_dir_all(&self.0);
            }
        }
        let _cleanup = Cleanup(root.clone());
        fs::write(root.join("src/Name.java"), "class Name {}\n").unwrap();
        // This guards enumeration decisions, not filesystem throughput. Both generated
        // roots only need enough entries to exceed the result cap on every platform.
        let generated_files_per_directory = 16;
        for directory in [".build", "node_modules"] {
            fs::create_dir(root.join(directory)).unwrap();
            for number in 0..generated_files_per_directory {
                fs::write(root.join(directory).join(format!("Name{number}.bin")), "").unwrap();
            }
        }
        for (files, content, symbols, expected_indexes) in [
            (0, 0, 0, vec![]),
            (0, 1, 0, vec![false]),
            (1, 0, 0, vec![true]),
            (0, 0, 1, vec![false]),
            (1, 0, 1, vec![false, true]),
        ] {
            invalidate_root(&root);
            super::super::files::DIRECTORY_VISITS
                .with_borrow_mut(|visits| *visits = Some(Vec::new()));
            let started = std::time::Instant::now();
            let response = super::super::files::search_everywhere(
                serde_json::from_value(serde_json::json!({
                    "root": root, "query": "Name", "includeGeneratedFileNames": true,
                    "maxResults": 10, "maxFileResults": files,
                    "maxContentResults": content, "maxSymbolResults": symbols
                }))
                .unwrap(),
            )
            .unwrap();
            let indexes = cache().lock().unwrap();
            let mut built: Vec<_> = indexes
                .keys()
                .filter(|key| key.root == root)
                .map(|key| key.names_only)
                .collect();
            built.sort();
            assert_eq!(built, expected_indexes);
            let resident_files: usize = indexes
                .iter()
                .filter(|(key, _)| key.root == root)
                .map(|(_, index)| index.read().unwrap().stats().file_count)
                .sum();
            assert_eq!(
                resident_files,
                usize::from(files > 0) * (2 * generated_files_per_directory + 1)
                    + usize::from(content > 0 || symbols > 0)
            );
            eprintln!("Cold source caps files={files} content={content} symbols={symbols}: {:?}, indexes={}, resident files={resident_files}, results={}",
                started.elapsed(), built.len(), response.matches.len());
            super::super::files::DIRECTORY_VISITS.with_borrow(|visits| {
                let visits = visits.as_ref().unwrap();
                if expected_indexes.is_empty() {
                    assert!(visits.is_empty());
                }
                if files == 0 {
                    assert!(!visits
                        .iter()
                        .any(|path| path.starts_with(root.join(".build"))
                            || path.starts_with(root.join("node_modules"))));
                }
            });
        }
    }

    #[test]
    fn missing_descendants_are_skipped_but_root_and_cancellation_errors_propagate() {
        let root = crate::tests::support::temporary_root("search-missing-descendant");
        let rules = VisibilityRules {
            hidden_directories: vec![],
            hidden_file_patterns: vec![],
        };
        let mut paths = Vec::new();
        assert!(collect_files(&root, &root.join("vanished"), &rules, &mut paths).is_ok());
        assert!(paths.is_empty());
        assert!(matches!(
            collect_files(&root, &root, &rules, &mut paths)
                .unwrap_err()
                .code,
            ErrorCode::WorkspaceNotFound
        ));
        let operation_id = root.to_string_lossy().into_owned();
        let _scope = crate::protocol::cancellation::Scope::begin(Some(operation_id.clone()), None);
        assert!(crate::protocol::cancellation::cancel(&operation_id));
        assert!(matches!(
            collect_files(&root, &root.join("vanished"), &rules, &mut paths)
                .unwrap_err()
                .code,
            ErrorCode::Cancelled
        ));
    }

    #[cfg(unix)]
    #[test]
    fn inaccessible_generated_subtree_preserves_source_and_text_results() {
        use std::os::unix::fs::PermissionsExt;
        let root = crate::tests::support::temporary_root("search-unreadable-generated");
        let blocked = root.join(".build/blocked");
        fs::create_dir_all(&blocked).unwrap();
        fs::create_dir_all(root.join("src")).unwrap();
        fs::write(
            root.join("src/Name.java"),
            "class Name {\n    void useName() {}\n}",
        )
        .unwrap();
        struct Cleanup(PathBuf);
        impl Drop for Cleanup {
            fn drop(&mut self) {
                let _ = fs::set_permissions(
                    self.0.join(".build/blocked"),
                    fs::Permissions::from_mode(0o755),
                );
                invalidate_root(&self.0);
                let _ = fs::remove_dir_all(&self.0);
            }
        }
        let _cleanup = Cleanup(root.clone());
        fs::set_permissions(&blocked, fs::Permissions::from_mode(0)).unwrap();
        if fs::read_dir(&blocked).is_ok() {
            // Privileged test runners bypass Unix mode bits; do not claim a permission regression ran.
            eprintln!("Skipping permission fixture: runner can enumerate mode-000 directories");
            return;
        }
        for text_only in [false, true] {
            invalidate_root(&root);
            let request = serde_json::from_value(serde_json::json!({
                "root": root, "query": "Name", "includeGeneratedFileNames": true,
                "maxResults": 100, "maxFileResults": if text_only { 0 } else { 100 },
                "maxSymbolResults": if text_only { 0 } else { 100 }
            }))
            .unwrap();
            let response = super::super::files::search_everywhere(request).unwrap();
            for kind in if text_only {
                vec!["content"]
            } else {
                vec!["file", "type", "symbol", "content"]
            } {
                assert!(
                    response
                        .matches
                        .iter()
                        .any(|item| item.path == "src/Name.java" && item.kind == kind),
                    "Missing {kind} result after encountering an inaccessible generated directory"
                );
            }
        }
        let rules = VisibilityRules {
            hidden_directories: vec![],
            hidden_file_patterns: vec![],
        };
        let mut paths = Vec::new();
        assert!(matches!(
            collect_files(&blocked, &blocked, &rules, &mut paths)
                .unwrap_err()
                .code,
            ErrorCode::PermissionDenied
        ));
    }

    #[test]
    fn directory_exclusions_prune_enumeration_and_incremental_updates() {
        let root = crate::tests::support::temporary_root("search-directory-pruning");
        fs::create_dir_all(&root).unwrap();
        let root = root.canonicalize().unwrap();
        struct Cleanup(PathBuf);
        impl Drop for Cleanup {
            fn drop(&mut self) {
                super::invalidate_root(&self.0);
                super::super::files::DIRECTORY_VISITS.with_borrow_mut(|visits| *visits = None);
                let _ = fs::remove_dir_all(&self.0);
            }
        }
        let _cleanup = Cleanup(root.clone());
        for path in [
            "cache/deep/Name.txt",
            ".cache/deep/Name.txt",
            "src/.cache/deep/Name.txt",
            "src/Name.log",
            "src/Name.txt",
        ] {
            let file = root.join(path);
            fs::create_dir_all(file.parent().unwrap()).unwrap();
            fs::write(file, "Name before").unwrap();
        }
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../../shared/fixtures/search/exclusions.json"
        ))
        .unwrap();
        // The patterns come from the shared fixture, so Rust and Swift always
        // judge the same list.
        let rules = VisibilityRules {
            hidden_directories: vec![],
            hidden_file_patterns: fixture["hiddenFilePatterns"]
                .as_array()
                .unwrap()
                .iter()
                .map(|pattern| pattern.as_str().unwrap().to_string())
                .collect(),
        };
        for case in fixture["cases"].as_array().unwrap() {
            assert_eq!(
                rules.is_hidden(
                    case["path"].as_str().unwrap(),
                    case["isDirectory"].as_bool().unwrap()
                ),
                case["hidden"].as_bool().unwrap(),
                "{case}"
            );
        }
        super::super::files::DIRECTORY_VISITS.with_borrow_mut(|visits| *visits = Some(Vec::new()));
        let content = get_or_build(&root, &rules).unwrap();
        let names = get_names(&root, &rules).unwrap();
        super::super::files::DIRECTORY_VISITS.with_borrow(|visits| {
            let visits = visits.as_ref().unwrap();
            assert!(visits.contains(&root));
            assert!(visits.contains(&root.join("src")));
            assert!(
                visits
                    .iter()
                    .all(|path| !path.starts_with(root.join("cache"))
                        && !path.starts_with(root.join(".cache"))
                        && !path.starts_with(root.join("src/.cache"))),
                "{visits:?}"
            );
        });
        assert_eq!(content.read().unwrap().stats().file_count, 1);
        assert_eq!(names.read().unwrap().stats().file_count, 1);
        assert!(matches!(
            update_paths(
                &root,
                &rules,
                &[
                    "cache/deep/Name.txt".into(),
                    "src/.cache/deep/Name.txt".into()
                ]
            ),
            UpdateOutcome::Updated
        ));
        assert_eq!(content.read().unwrap().stats().file_count, 1);
        assert_eq!(names.read().unwrap().stats().file_count, 1);
    }

    #[test]
    fn changing_exclusions_releases_old_indexes_and_bounds_resident_variants() {
        let root = crate::tests::support::temporary_root("search-cache-exclusions");
        fs::create_dir_all(&root).unwrap();
        let root = root.canonicalize().unwrap();
        struct Cleanup(PathBuf);
        impl Drop for Cleanup {
            fn drop(&mut self) {
                super::invalidate_root(&self.0);
                let _ = fs::remove_dir_all(&self.0);
            }
        }
        let _cleanup = Cleanup(root.clone());
        fs::create_dir_all(&root).unwrap();
        fs::write(root.join("Name.txt"), "before").unwrap();
        let mut old = Vec::new();
        for index in 0..32 {
            let rules = VisibilityRules {
                hidden_directories: vec![],
                hidden_file_patterns: vec![format!("exclude-{index}/")],
            };
            let content = get_or_build(&root, &rules).unwrap();
            let names = get_names(&root, &rules).unwrap();
            assert!(
                old.iter()
                    .all(|weak: &std::sync::Weak<RwLock<WorkspaceSearchIndex>>| weak
                        .upgrade()
                        .is_none()),
                "old index allocations remain resident"
            );
            assert_eq!(
                cache()
                    .lock()
                    .unwrap()
                    .keys()
                    .filter(|key| key.root == root)
                    .count(),
                2
            );
            fs::write(root.join("Name.txt"), format!("after-{index}")).unwrap();
            assert!(matches!(
                update_paths(&root, &rules, &["Name.txt".into()]),
                UpdateOutcome::Updated
            ));
            for current in [&content, &names] {
                assert_eq!(current.read().unwrap().stats().file_count, 1);
            }
            let updated = content.read().unwrap();
            assert_eq!(
                updated
                    .candidate_ids(&format!("after-{index}"), false)
                    .len(),
                1
            );
            assert!(updated.candidate_ids("before", false).is_empty());
            drop(updated);
            old = vec![Arc::downgrade(&content), Arc::downgrade(&names)];
            // The same command the settings observer uses must remove both kinds.
            if index % 2 == 0 {
                invalidate_root(&root);
                assert_eq!(
                    cache()
                        .lock()
                        .unwrap()
                        .keys()
                        .filter(|key| key.root == root)
                        .count(),
                    0
                );
            }
        }
        invalidate_root(&root);
        assert!(old.iter().all(|weak| weak.upgrade().is_none()));
    }
}
