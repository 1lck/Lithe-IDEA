//! Bounded workspace traversal shared by all run-configuration detectors.

use crate::protocol::{CoreError, ErrorCode};
use crate::remote::workspace_io as fs;
use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

/// Detectors only care about manifests near the top of a project. Anything
/// deeper is vendored code or build output that slipped past the prune list.
const MAX_DEPTH: usize = 6;
/// One directory plus the file names directly inside it.
///
/// Detectors read this instead of touching the filesystem, so checking "is there
/// a package.json here" is a set lookup rather than one stat per detector per
/// directory.
#[derive(Debug, Clone)]
pub struct DirectoryContext {
    pub root: PathBuf,
    pub path: PathBuf,
    /// Project-relative, forward-slashed, `.` for the project root.
    pub relative: String,
    files: BTreeSet<String>,
}

impl DirectoryContext {
    /// Captures the readable non-directory entries immediately below `path`.
    pub fn at(root: &Path, path: &Path) -> Result<Option<Self>, CoreError> {
        let entries = match fs::read_dir(path) {
            Ok(entries) => entries,
            // Detection skips a directory the host cannot list, as it does locally,
            // but a dropped link must not pass for a project without manifests.
            Err(error) if fs::is_transport_failure(&error) => return Err(error.into()),
            Err(_) => return Ok(None),
        };
        let files = entries
            .flatten()
            .filter_map(|entry| {
                let kind = entry.file_type().ok()?;
                (!kind.is_dir()).then(|| entry.file_name().to_str().map(str::to_string))?
            })
            .collect();
        Ok(Some(Self {
            root: root.to_path_buf(),
            path: path.to_path_buf(),
            relative: relative_path(root, path)?,
            files,
        }))
    }

    /// Reports whether the directory contains an entry with the exact name.
    pub fn has(&self, name: &str) -> bool {
        self.files.contains(name)
    }

    /// First existing name from `candidates`, for manifests with spelling
    /// variants (`justfile` / `Justfile`, `Makefile` / `makefile`).
    pub fn any_of(&self, candidates: &[&'static str]) -> Option<&'static str> {
        candidates
            .iter()
            .copied()
            .find(|name| self.files.contains(*name))
    }

    /// Reads a known entry as UTF-8, returning no content for unreadable files.
    pub fn read(&self, name: &str) -> Option<String> {
        if !self.has(name) {
            return None;
        }
        fs::read_to_string(self.path.join(name)).ok()
    }

    /// Turns a file name into a project-relative path for `source`.
    pub fn join_relative(&self, name: &str) -> String {
        if self.relative == "." {
            name.to_string()
        } else {
            format!("{}/{}", self.relative, name)
        }
    }

    /// Directory name, used as a fallback service label.
    pub fn label(&self) -> String {
        if self.relative == "." {
            self.path
                .file_name()
                .and_then(|value| value.to_str())
                .unwrap_or("project")
                .to_string()
        } else {
            self.relative
                .rsplit('/')
                .next()
                .unwrap_or(self.relative.as_str())
                .to_string()
        }
    }
}

/// Walks the project, pruning uninteresting subtrees *before* descending rather
/// than filtering afterwards, so a `node_modules` tree is never read at all.
pub fn scan(root: &Path) -> Result<Vec<DirectoryContext>, CoreError> {
    let snapshot = super::super::workspace_scan::scan_run_workspace(root, Some(MAX_DEPTH))?;
    snapshot
        .directories
        .into_iter()
        .map(|directory| {
            Ok(DirectoryContext {
                root: root.to_owned(),
                relative: relative_path(root, &directory.path)?,
                path: directory.path,
                files: directory.files,
            })
        })
        .collect()
}

fn relative_path(root: &Path, directory: &Path) -> Result<String, CoreError> {
    let relative = directory.strip_prefix(root).map_err(|_| {
        CoreError::new(
            ErrorCode::InvalidRequest,
            "Scanned directory escaped the project root",
        )
    })?;
    let value = relative.to_string_lossy().replace('\\', "/");
    Ok(if value.is_empty() {
        ".".to_string()
    } else {
        value
    })
}
