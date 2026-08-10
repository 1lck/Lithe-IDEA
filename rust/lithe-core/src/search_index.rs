use crate::error::{CoreError, ErrorCode};
use crate::model::SearchMatch;
use crate::workspace::{java_symbols, read_searchable_text, relative_path, VisibilityRules};
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
}

pub(crate) struct IndexedFile {
    pub(crate) path: String,
    trigrams: Vec<u32>,
    pub(crate) symbols: Vec<IndexedSymbol>,
}

#[derive(Clone)]
pub(crate) struct IndexedSymbol {
    pub(crate) name: String,
    pub(crate) kind: String,
    pub(crate) line: usize,
    pub(crate) signature: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum UpdateOutcome {
    NotIndexed,
    Updated,
    RequiresRebuild,
}

#[derive(Debug, Clone, Copy)]
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
    let index = Arc::new(RwLock::new(WorkspaceSearchIndex::build(root, rules)?));
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
    rules: &VisibilityRules,
    paths: &[String],
) -> UpdateOutcome {
    let cache_key = key(root, rules);
    let index = {
        let Ok(indexes) = cache().lock() else {
            return UpdateOutcome::NotIndexed;
        };
        indexes.get(&cache_key).cloned()
    };
    let Some(index) = index else {
        return UpdateOutcome::NotIndexed;
    };
    let Ok(mut index) = index.write() else {
        return UpdateOutcome::RequiresRebuild;
    };

    for value in paths {
        let Some(absolute) = normalized_update_path(root, value) else {
            continue;
        };
        let relative = relative_path(&absolute, root);
        let metadata = fs::symlink_metadata(&absolute).ok();
        if metadata.as_ref().is_some_and(|value| value.is_dir()) {
            return UpdateOutcome::RequiresRebuild;
        }
        if metadata.is_none() && index.has_descendant(&relative) {
            return UpdateOutcome::RequiresRebuild;
        }
        index.update_file(&absolute, &relative, metadata.as_ref(), rules);
    }
    UpdateOutcome::Updated
}

impl WorkspaceSearchIndex {
    fn build(root: &Path, rules: &VisibilityRules) -> Result<Self, CoreError> {
        let mut paths = Vec::new();
        collect_files(root, root, rules, &mut paths)?;
        let mut index = Self {
            files: Vec::new(),
            free_ids: Vec::new(),
            path_to_id: HashMap::with_capacity(paths.len()),
            postings: HashMap::new(),
        };
        for path in paths {
            crate::cancellation::check()?;
            let relative = relative_path(&path, root);
            index.add_file(&path, relative);
        }
        Ok(index)
    }

    fn add_file(&mut self, path: &Path, relative: String) {
        if let Some(existing) = self.path_to_id.get(&relative).copied() {
            self.remove_id(existing);
        }
        let (trigrams, symbols) = read_search_data(path, &relative);
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
    crate::cancellation::check()?;
    let mut children = fs::read_dir(path)
        .map_err(CoreError::from)?
        .filter_map(Result::ok)
        .filter_map(|entry| {
            let child_path = entry.path();
            let metadata = fs::symlink_metadata(&child_path).ok()?;
            if metadata.file_type().is_symlink() {
                return None;
            }
            let relative = relative_path(&child_path, root);
            if rules.is_hidden(&relative, metadata.is_dir()) {
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
    }
}
