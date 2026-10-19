//! Bounded reading of tool output and workspace files: structured document
//! formats, report globs, and path normalization against the workspace.
//!
//! Everything a build tool prints is untrusted. Sizes are bounded before
//! parsing, and every path it reports is reduced to a workspace-relative
//! path or dropped, so a hostile tool cannot make the host open files
//! outside the workspace.

use crate::plugins::declarative::{PluginRejection, Validation};
use serde_json::Value;
use std::fs;
use std::path::{Component, Path, PathBuf};
use std::time::UNIX_EPOCH;

/// Largest output or file Core decodes.
pub(crate) const MAX_OUTPUT_BYTES: usize = 32 * 1024 * 1024;
/// Most files one report glob yields.
const MAX_GLOB_FILES: usize = 512;
/// Most directories one report glob visits.
const MAX_GLOB_DIRECTORIES: usize = 4000;
/// Deepest directory a `**` reaches below its base.
const MAX_GLOB_DEPTH: usize = 12;

/// Structured formats Core parses: the canonical documents (JSON), and the
/// formats a plugin's map reads.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Format {
    Json,
    JsonStream,
    Toml,
}

pub(crate) fn invalid_output(message: impl Into<String>) -> PluginRejection {
    PluginRejection::new("plugin.build.invalidOutput", message)
}

/// Parses one document. A JSON stream becomes an array of its values.
pub(crate) fn document(text: &str, format: Format) -> Validation<Value> {
    if text.len() > MAX_OUTPUT_BYTES {
        return Err(invalid_output("The build tool output is too large."));
    }
    let parsed = match format {
        Format::Json => serde_json::from_str(text).map_err(|error| error.to_string()),
        Format::JsonStream => serde_json::Deserializer::from_str(text)
            .into_iter::<Value>()
            .collect::<Result<Vec<_>, _>>()
            .map(Value::Array)
            .map_err(|error| error.to_string()),
        Format::Toml => toml::from_str::<Value>(text).map_err(|error| error.to_string()),
    };
    parsed.map_err(|error| {
        invalid_output(format!(
            "The build tool output is not valid {format:?}: {}",
            first_line(&error)
        ))
    })
}

fn first_line(text: &str) -> &str {
    text.lines().next().unwrap_or_default()
}

/// Reads a UTF-8 file up to the output bound.
pub(crate) fn read_bounded(path: &Path) -> Validation<String> {
    let metadata = fs::metadata(path)
        .map_err(|_| invalid_output("The build tool did not write its output file."))?;
    if !metadata.is_file() || metadata.len() > MAX_OUTPUT_BYTES as u64 {
        return Err(invalid_output(
            "The build tool output file is missing or too large.",
        ));
    }
    fs::read_to_string(path).map_err(|_| invalid_output("The build tool output is not UTF-8."))
}

/// Bytes of a file up to the output bound, or `None` when it is absent, not
/// a regular file, or too large.
pub(crate) fn read_bytes_bounded(path: &Path) -> Option<Vec<u8>> {
    let metadata = fs::metadata(path).ok()?;
    if !metadata.is_file() || metadata.len() > MAX_OUTPUT_BYTES as u64 {
        return None;
    }
    fs::read(path).ok()
}

/// Bounds a host-provided output text before it is parsed line by line.
pub(crate) fn bounded_text(text: &str) -> Validation<&str> {
    if text.len() > MAX_OUTPUT_BYTES {
        return Err(invalid_output("The build tool output is too large."));
    }
    Ok(text)
}

/// Absolute workspace root, canonical when it exists, so paths a tool
/// reports through symlinks (`/private/var` for `/var`) still match.
#[derive(Debug, Clone)]
pub(crate) struct Workspace {
    roots: Vec<String>,
    pub(crate) path: PathBuf,
}

impl Workspace {
    pub(crate) fn new(root: &str) -> Validation<Self> {
        let path = PathBuf::from(root);
        if !path.is_absolute() || root.contains('\0') {
            return Err(PluginRejection::new(
                "plugin.build.invalidSelection",
                "The workspace root must be an absolute path.",
            ));
        }
        let mut roots = vec![slashed(root)];
        if let Ok(canonical) = path.canonicalize() {
            roots.push(slashed(&canonical.to_string_lossy()));
        }
        let canonical = path.canonicalize().unwrap_or(path);
        Ok(Self {
            roots,
            path: canonical,
        })
    }

    /// Absolute path of a workspace-relative path.
    pub(crate) fn join(&self, relative: &str) -> PathBuf {
        if relative == "." {
            self.path.clone()
        } else {
            self.path.join(relative)
        }
    }

    /// Resolves an existing workspace path without following links outside it.
    pub(crate) fn read_path(&self, relative: &str) -> Option<PathBuf> {
        let path = self.join(relative).canonicalize().ok()?;
        path.starts_with(&self.path).then_some(path)
    }

    /// Workspace-relative form of a path a tool reported: absolute, or
    /// relative to `base` (itself workspace-relative). `None` when it leaves
    /// the workspace.
    pub(crate) fn relativize(&self, raw: &str, base: &str) -> Option<String> {
        let raw = slashed(raw.trim());
        if raw.is_empty() || raw.contains('\0') {
            return None;
        }
        if is_absolute(&raw) {
            return self.roots.iter().find_map(|root| {
                let rest = strip_root(&raw, root)?;
                normalize(rest)
            });
        }
        if base == "." {
            normalize(&raw)
        } else {
            normalize(&format!("{base}/{raw}"))
        }
    }

    /// Workspace-relative form of a path a tool reported for a file the host
    /// may open, like a diagnostic or a test case source. Links that stay
    /// inside the workspace are kept; one that resolves outside is dropped.
    /// A path that does not exist yet stays, because the host opens it only
    /// after checking existence and resolves links again before navigating.
    pub(crate) fn relativize_reported(&self, raw: &str, base: &str) -> Option<String> {
        let relative = self.relativize(raw, base)?;
        match self.join(&relative).canonicalize() {
            Ok(resolved) if !resolved.starts_with(&self.path) => None,
            _ => Some(relative),
        }
    }
}

fn slashed(value: &str) -> String {
    let value = value.replace('\\', "/");
    let trimmed = value.trim_end_matches('/');
    if trimmed.is_empty() {
        "/".to_string()
    } else {
        trimmed.to_string()
    }
}

fn is_absolute(value: &str) -> bool {
    value.starts_with('/')
        || value.as_bytes().get(1) == Some(&b':')
            && value
                .as_bytes()
                .first()
                .is_some_and(u8::is_ascii_alphabetic)
}

fn strip_root<'a>(raw: &'a str, root: &str) -> Option<&'a str> {
    // A different tool path can place this byte offset inside a UTF-8 character.
    let prefix = raw.get(..root.len())?;
    // Windows drive letters differ in case between tools.
    let matches = prefix == root || root.contains(':') && prefix.eq_ignore_ascii_case(root);
    if !matches {
        return None;
    }
    let rest = &raw[root.len()..];
    if rest.is_empty() {
        Some(".")
    } else {
        rest.strip_prefix('/')
    }
}

/// Lexically resolves `.` and `..`; `None` when the path climbs above its
/// start. The result is `.` or `/`-separated segments.
pub(crate) fn normalize(value: &str) -> Option<String> {
    let mut segments: Vec<&str> = Vec::new();
    for segment in value.split('/') {
        match segment {
            "" | "." => {}
            ".." => {
                segments.pop()?;
            }
            other => segments.push(other),
        }
    }
    Some(if segments.is_empty() {
        ".".to_string()
    } else {
        segments.join("/")
    })
}

/// Joins two workspace-relative paths.
pub(crate) fn join_relative(base: &str, path: &str) -> String {
    match (base, path) {
        (".", path) => path.to_string(),
        (base, ".") => base.to_string(),
        (base, path) => format!("{base}/{path}"),
    }
}

/// True when `path` is `ancestor` or below it.
pub(crate) fn contains(ancestor: &str, path: &str) -> bool {
    ancestor == "."
        || path == ancestor
        || path
            .strip_prefix(ancestor)
            .is_some_and(|rest| rest.starts_with('/'))
}

/// `path` relative to `ancestor`, which must contain it.
pub(crate) fn relative_to(ancestor: &str, path: &str) -> Option<String> {
    if !contains(ancestor, path) {
        return None;
    }
    Some(if ancestor == "." {
        path.to_string()
    } else if path == ancestor {
        ".".to_string()
    } else {
        path[ancestor.len() + 1..].to_string()
    })
}

/// A workspace-relative path from a request, checked to be inside the
/// workspace.
pub(crate) fn request_path(value: &str, what: &str) -> Validation<String> {
    let invalid = || {
        PluginRejection::new(
            "plugin.build.invalidSelection",
            format!("The {what} path must be relative to the workspace."),
        )
    };
    if value.contains('\0') || value.contains('\\') || is_absolute(value) {
        return Err(invalid());
    }
    let has_parent = Path::new(value)
        .components()
        .any(|component| matches!(component, Component::ParentDir));
    if has_parent {
        return Err(invalid());
    }
    normalize(value).ok_or_else(invalid)
}

/// Files below `base` matching a `/`-separated glob, sorted. `*` and `?`
/// match within one segment, `**` matches any number of directories.
/// Symbolic links to directories are not followed. Files modified before
/// `not_before_millis` belong to an earlier run and are skipped.
pub(crate) fn glob(base: &Path, pattern: &str, not_before_millis: Option<u64>) -> Vec<PathBuf> {
    let segments: Vec<&str> = pattern
        .split('/')
        .filter(|segment| !segment.is_empty())
        .collect();
    let mut found = Vec::new();
    let mut visited = 0;
    walk(base, &segments, 0, &mut found, &mut visited);
    found.retain(|path| is_current(path, not_before_millis));
    found.sort();
    found.dedup();
    found.truncate(MAX_GLOB_FILES);
    found
}

fn walk(
    directory: &Path,
    segments: &[&str],
    depth: usize,
    found: &mut Vec<PathBuf>,
    visited: &mut usize,
) {
    let Some((segment, rest)) = segments.split_first() else {
        return;
    };
    if *visited >= MAX_GLOB_DIRECTORIES || found.len() >= MAX_GLOB_FILES * 4 {
        return;
    }
    *visited += 1;
    if *segment == "**" {
        // Zero directories, then one more directory at a time.
        walk(directory, rest, depth, found, visited);
        if depth >= MAX_GLOB_DEPTH {
            return;
        }
        for (path, is_directory) in entries(directory) {
            if is_directory {
                walk(&path, segments, depth + 1, found, visited);
            }
        }
        return;
    }
    for (path, is_directory) in entries(directory) {
        let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
            continue;
        };
        if !wildcard(segment, name) {
            continue;
        }
        match (rest.is_empty(), is_directory) {
            (true, false) => found.push(path),
            (false, true) => walk(&path, rest, depth + 1, found, visited),
            _ => {}
        }
    }
}

fn entries(directory: &Path) -> Vec<(PathBuf, bool)> {
    let Ok(entries) = fs::read_dir(directory) else {
        return Vec::new();
    };
    let mut result: Vec<(PathBuf, bool)> = entries
        .flatten()
        .filter_map(|entry| {
            // `file_type` does not follow symlinks, so a link to a directory
            // is neither descended into nor read as a report.
            let kind = entry.file_type().ok()?;
            (kind.is_dir() || kind.is_file()).then(|| (entry.path(), kind.is_dir()))
        })
        .collect();
    result.sort();
    result
}

fn wildcard(pattern: &str, name: &str) -> bool {
    let pattern: Vec<char> = pattern.chars().collect();
    let name: Vec<char> = name.chars().collect();
    let (mut p, mut n) = (0, 0);
    let mut star: Option<(usize, usize)> = None;
    while n < name.len() {
        match pattern.get(p) {
            Some('*') => {
                star = Some((p, n));
                p += 1;
            }
            Some('?') => {
                p += 1;
                n += 1;
            }
            Some(character) if *character == name[n] => {
                p += 1;
                n += 1;
            }
            _ => match star {
                Some((star_p, star_n)) => {
                    p = star_p + 1;
                    n = star_n + 1;
                    star = Some((star_p, star_n + 1));
                }
                None => return false,
            },
        }
    }
    pattern[p..].iter().all(|character| *character == '*')
}

fn is_current(path: &Path, not_before_millis: Option<u64>) -> bool {
    let Ok(metadata) = fs::metadata(path) else {
        return false;
    };
    if !metadata.is_file() || metadata.len() > MAX_OUTPUT_BYTES as u64 {
        return false;
    }
    let Some(not_before) = not_before_millis else {
        return true;
    };
    metadata
        .modified()
        .ok()
        .and_then(|modified| modified.duration_since(UNIX_EPOCH).ok())
        .is_some_and(|modified| modified.as_millis() >= u128::from(not_before))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn wildcards_match_within_a_segment() {
        assert!(wildcard("TEST-*.xml", "TEST-demo.OrderTest.xml"));
        assert!(wildcard("*.json", "a.json"));
        assert!(!wildcard("*.json", "a.jsonl"));
        assert!(wildcard("a?c", "abc"));
    }

    #[test]
    fn absolute_tool_paths_preserve_unicode_and_require_a_root_boundary() {
        // The root length lands inside the emoji of the unrelated path.
        assert_eq!(strip_root("/a中文🙂/file", "/workspace"), None);
        assert_eq!(strip_root("/workspace-other/file", "/workspace"), None);
        assert_eq!(strip_root("/WORKSPACE/file", "/workspace"), None);
        assert_eq!(
            strip_root("/workspace/中文🙂/file", "/workspace"),
            Some("中文🙂/file")
        );
        assert_eq!(
            strip_root("C:/WORKSPACE/中文/file", "c:/workspace"),
            Some("中文/file")
        );
        assert_eq!(strip_root("/workspace", "/workspace"), Some("."));
    }

    #[test]
    fn normalization_rejects_paths_above_the_start() {
        assert_eq!(normalize("a/./b/../c"), Some("a/c".to_string()));
        assert_eq!(normalize("a/.."), Some(".".to_string()));
        assert_eq!(normalize("../a"), None);
    }
}
