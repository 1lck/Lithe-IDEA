//! Hidden-path rules: the one definition of which workspace paths are hidden.
//!
//! This module owns three things that used to exist once per host: the built-in default lists,
//! the glob matcher, and the way a directory differs from a file. `lithe-core` uses
//! [`VisibilityRules`] directly for snapshots, search and history scans. macOS and the Windows
//! frontend reach the same code through two commands, so no host keeps a list or a matcher:
//!
//! - `workspace.visibilityDefaults` returns the built-in lists for display.
//! - `workspace.classifyVisibility` classifies a whole batch of paths against one rule set. Hosts
//!   send every child of a directory in one call instead of one call per file.
//!
//! Two answers exist for every path. `hidden` means the tree, search and history all leave it out.
//! `watchedDespiteHiding` marks the project configuration folder: it is hidden from the tree, but
//! edits to its JSON files must still reach project services, so its events are not dropped.

use crate::{RuleError, RuleErrorCode};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Command name of the batch classifier in the Core command namespace.
pub const CLASSIFY_VISIBILITY: &str = "workspace.classifyVisibility";
/// Command name of the defaults query in the Core command namespace.
pub const VISIBILITY_DEFAULTS: &str = "workspace.visibilityDefaults";

/// Folder names hidden at any depth unless a `!` entry turns them off. Shared by the tree, search,
/// local history, watchers and Git discovery.
pub const BUILT_IN_HIDDEN_DIRECTORIES: &[&str] = &[
    ".git",
    ".svn",
    ".worktree",
    ".worktrees",
    ".build",
    ".swiftpm",
    "node_modules",
    // Python virtual environments and bytecode caches are dependency or generated
    // output like `node_modules`. They hold tens of thousands of files that no
    // snapshot consumer wants. Environments are matched by their conventional
    // names only, so a differently named one still has to be hidden by the user.
    ".venv",
    "venv",
    "__pycache__",
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

/// The project configuration folder is hidden like IDEA's `.idea`; its files are edited through
/// Settings and the run configuration editor.
pub const CONFIGURATION_PATTERN: &str = ".lithe/**";

/// The project configuration folder at the workspace root. Its events stay watched even though
/// the tree hides it, because edits to its JSON files reload project services.
pub const CONFIGURATION_DIRECTORY: &str = ".lithe";

/// File names and globs hidden everywhere unless a `!` entry turns them off.
pub const BUILT_IN_HIDDEN_FILE_PATTERNS: &[&str] = &[
    ".DS_Store",
    "*.pyc",
    CONFIGURATION_PATTERN,
    ".lithe/run/local.json",
];

/// The built-in rules written as Hidden paths patterns, for display. Folder names become
/// `**/name/`, the pattern that hides them at any depth.
pub fn built_in_patterns() -> Vec<String> {
    BUILT_IN_HIDDEN_DIRECTORIES
        .iter()
        .map(|name| format!("**/{name}/"))
        .chain(
            BUILT_IN_HIDDEN_FILE_PATTERNS
                .iter()
                .map(|p| (*p).to_string()),
        )
        .collect()
}

/// Effective built-in plus caller-supplied rules for excluding workspace paths.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct VisibilityRules {
    /// Folder names hidden at any depth, compared case-insensitively.
    pub hidden_directories: Vec<String>,
    /// Name globs, path globs and folder globs, matched case-insensitively.
    pub hidden_file_patterns: Vec<String>,
}

impl VisibilityRules {
    /// Adds the built-in rules except those turned off by a `!` entry.
    ///
    /// Callers may already send built-in names; a turned-off entry is dropped from their lists
    /// too, so the caller's copy cannot re-hide it. User entries keep their stored values; only
    /// the effective list is normalized.
    pub fn new(hidden_directories: Vec<String>, hidden_files: Vec<String>) -> Self {
        let disabled = disabled_built_ins(&hidden_files);
        let mut directories = BUILT_IN_HIDDEN_DIRECTORIES
            .iter()
            .map(|value| (*value).to_string())
            .collect::<Vec<_>>();
        directories.extend(hidden_directories);
        directories.retain(|name| !is_disabled_directory(name, &disabled));
        let mut files = BUILT_IN_HIDDEN_FILE_PATTERNS
            .iter()
            .map(|value| (*value).to_string())
            .collect::<Vec<_>>();
        files.extend(hidden_files);
        files.retain(|pattern| {
            let pattern = pattern.trim();
            !pattern.starts_with('!')
                && !disabled
                    .iter()
                    .any(|entry| entry.eq_ignore_ascii_case(pattern))
        });
        Self {
            hidden_directories: normalize(directories),
            hidden_file_patterns: normalize(files),
        }
    }

    /// Whether `name` is one of the effective hidden folder names.
    pub fn is_hidden_directory_name(&self, name: &str) -> bool {
        self.hidden_directories
            .iter()
            .any(|hidden| hidden.eq_ignore_ascii_case(name))
    }

    /// Whether a workspace-relative path is hidden. `path` uses `/` separators.
    pub fn is_hidden(&self, path: &str, is_directory: bool) -> bool {
        self.is_hidden_of_kind(path, Some(is_directory))
    }

    /// Like [`Self::is_hidden`] for a path whose kind is not known (`None`): every component is
    /// treated as a possible folder, and file globs still apply to the last component.
    pub fn is_hidden_of_kind(&self, path: &str, is_directory: Option<bool>) -> bool {
        is_path_hidden(
            &self.hidden_directories,
            &self.hidden_file_patterns,
            path,
            is_directory,
        )
    }

    /// Whether file events at `path` must still be delivered although the rules hide it. Only
    /// the project configuration folder qualifies, and only for files outside the built-in noise
    /// below it, such as `.lithe/run/local.json`.
    pub fn is_watched_despite_hiding(&self, path: &str) -> bool {
        let first = path.split('/').find(|value| !value.is_empty());
        if first != Some(CONFIGURATION_DIRECTORY) {
            return false;
        }
        let noise = Self::new(Vec::new(), vec![format!("!{CONFIGURATION_PATTERN}")]);
        !noise.is_hidden_of_kind(path, None)
    }
}

/// Matches one workspace-relative path against already effective rule lists (see
/// [`VisibilityRules::new`]). Borrowing the lists lets scans test every entry without copying.
pub fn is_path_hidden(
    hidden_directories: &[String],
    hidden_file_patterns: &[String],
    path: &str,
    is_directory: Option<bool>,
) -> bool {
    let components = path
        .split('/')
        .filter(|value| !value.is_empty())
        .collect::<Vec<_>>();
    let Some(last) = components.last().copied() else {
        return false;
    };
    // A folder name hides folders and everything below them. It also hides a file with that
    // exact name, because a linked worktree's `.git` is a plain file and must stay out too.
    let directory_count = components.len() - usize::from(is_directory == Some(false));
    if components.iter().any(|component| {
        hidden_directories
            .iter()
            .any(|hidden| hidden.eq_ignore_ascii_case(component))
    }) {
        return true;
    }
    let mut folder_globs = hidden_file_patterns
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
    if is_directory == Some(true) {
        return false;
    }
    hidden_file_patterns
        .iter()
        .any(|pattern| path_glob_matches(pattern, last) || path_glob_matches(pattern, path))
}

/// The entries after a leading `!`. Such an entry turns a built-in rule off instead of hiding
/// anything; it is never matched as a pattern itself.
pub fn disabled_built_ins(hidden_file_patterns: &[String]) -> Vec<String> {
    hidden_file_patterns
        .iter()
        .filter_map(|pattern| pattern.trim().strip_prefix('!'))
        .map(|pattern| pattern.trim().to_string())
        .collect()
}

/// A built-in folder is turned off by its displayed form `**/name/` or its bare name.
pub fn is_disabled_directory(name: &str, disabled: &[String]) -> bool {
    disabled.iter().any(|entry| {
        entry.eq_ignore_ascii_case(name)
            || entry
                .strip_prefix("**/")
                .and_then(|rest| rest.strip_suffix('/'))
                .is_some_and(|rest| rest.eq_ignore_ascii_case(name))
    })
}

/// Trims entries, drops empty ones and removes case-insensitive duplicates, keeping the first.
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

/// Case-insensitive glob where `*` spans any characters, including `/`, and `?` is one character.
pub fn glob_matches(pattern: &str, value: &str) -> bool {
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

/// One path to classify.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ClassifyEntry {
    /// Path relative to the workspace root, with `/` separators.
    path: String,
    /// `true` for a folder, `false` for a file, absent when the host does not know.
    #[serde(default)]
    is_directory: Option<bool>,
}

/// Payload of `workspace.classifyVisibility`. The rule lists are the user's own entries; the
/// built-in rules are added here.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ClassifyRequest {
    #[serde(default)]
    hidden_directory_names: Vec<String>,
    #[serde(default)]
    hidden_file_patterns: Vec<String>,
    entries: Vec<ClassifyEntry>,
}

/// Result of `workspace.classifyVisibility`; both vectors line up with the request entries.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ClassifyResponse {
    /// Whether the tree, search and history leave the entry out.
    hidden: Vec<bool>,
    /// Whether file events must still be delivered although the entry is hidden.
    watched_despite_hiding: Vec<bool>,
}

/// Result of `workspace.visibilityDefaults`.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct DefaultsResponse {
    hidden_directory_names: Vec<String>,
    hidden_file_patterns: Vec<String>,
    built_in_patterns: Vec<String>,
    configuration_directory: &'static str,
    configuration_pattern: &'static str,
}

fn invalid(error: serde_json::Error) -> RuleError {
    RuleError::new(RuleErrorCode::InvalidRequest, "Invalid visibility request")
        .with_details(error.to_string())
}

/// Classifies every entry of the batch against one rule set.
pub fn classify_visibility_json(payload: Value) -> Result<Value, RuleError> {
    let request: ClassifyRequest = serde_json::from_value(payload).map_err(invalid)?;
    let rules = VisibilityRules::new(request.hidden_directory_names, request.hidden_file_patterns);
    let hidden = request
        .entries
        .iter()
        .map(|entry| rules.is_hidden_of_kind(&entry.path, entry.is_directory))
        .collect::<Vec<_>>();
    let watched_despite_hiding = request
        .entries
        .iter()
        .zip(&hidden)
        .map(|(entry, hidden)| *hidden && rules.is_watched_despite_hiding(&entry.path))
        .collect::<Vec<_>>();
    serde_json::to_value(ClassifyResponse {
        hidden,
        watched_despite_hiding,
    })
    .map_err(invalid)
}

/// Returns the built-in lists so hosts can display them without keeping a copy.
pub fn visibility_defaults_json(_payload: Value) -> Result<Value, RuleError> {
    serde_json::to_value(DefaultsResponse {
        hidden_directory_names: BUILT_IN_HIDDEN_DIRECTORIES
            .iter()
            .map(|name| (*name).to_string())
            .collect(),
        hidden_file_patterns: BUILT_IN_HIDDEN_FILE_PATTERNS
            .iter()
            .map(|name| (*name).to_string())
            .collect(),
        built_in_patterns: built_in_patterns(),
        configuration_directory: CONFIGURATION_DIRECTORY,
        configuration_pattern: CONFIGURATION_PATTERN,
    })
    .map_err(invalid)
}
