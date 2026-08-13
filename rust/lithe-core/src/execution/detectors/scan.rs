use crate::protocol::{CoreError, ErrorCode};
use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

/// Detectors only care about manifests near the top of a project. Anything
/// deeper is vendored code or build output that slipped past the prune list.
const MAX_DEPTH: usize = 6;
/// A ceiling on how many directories one project may contribute. Without it a
/// pathological tree turns project open into an unbounded walk.
const MAX_DIRECTORIES: usize = 4000;

/// Directories that never contain a service worth offering, and whose contents
/// are large enough that descending into them would dominate the walk.
const PRUNED: &[&str] = &[
    ".git",
    ".worktree",
    ".worktrees",
    ".lithe",
    ".idea",
    ".vscode",
    ".gradle",
    ".venv",
    "venv",
    ".tox",
    ".mypy_cache",
    ".pytest_cache",
    "__pycache__",
    ".next",
    ".nuxt",
    ".svelte-kit",
    ".terraform",
    ".cargo",
    ".stack-work",
    ".bundle",
    ".dart_tool",
    ".build",
    ".swiftpm",
    "node_modules",
    "bower_components",
    "vendor",
    "target",
    "build",
    "dist",
    "out",
    "obj",
    "coverage",
    "DerivedData",
    "Pods",
];

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
    pub fn at(root: &Path, path: &Path) -> Result<Option<Self>, CoreError> {
        let Ok(entries) = fs::read_dir(path) else {
            return Ok(None);
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
    let mut results = Vec::new();
    let mut queue = vec![(root.to_path_buf(), 0usize)];
    while let Some((directory, depth)) = queue.pop() {
        if results.len() >= MAX_DIRECTORIES {
            break;
        }
        let Ok(entries) = fs::read_dir(&directory) else {
            continue;
        };
        let mut files = BTreeSet::new();
        let mut children = Vec::new();
        for entry in entries.flatten() {
            let Ok(kind) = entry.file_type() else {
                continue;
            };
            let Some(name) = entry.file_name().to_str().map(str::to_string) else {
                continue;
            };
            // `file_type` does not follow symlinks, so a link pointing at an
            // ancestor is recorded as a file and never re-entered. That is what
            // keeps this walk loop-free without tracking visited inodes.
            if kind.is_dir() {
                if depth < MAX_DEPTH && !pruned(&name) {
                    children.push(entry.path());
                }
            } else {
                files.insert(name);
            }
        }
        results.push(DirectoryContext {
            root: root.to_path_buf(),
            relative: relative_path(root, &directory)?,
            path: directory,
            files,
        });
        for child in children {
            queue.push((child, depth + 1));
        }
    }
    results.sort_by(|left, right| left.relative.cmp(&right.relative));
    Ok(results)
}

fn pruned(name: &str) -> bool {
    PRUNED.iter().any(|value| value.eq_ignore_ascii_case(name))
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
