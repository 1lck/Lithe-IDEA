//! Shared run-discovery traversal and incomplete-snapshot diagnostics.
//!
//! Automatic discovery is best effort below the required workspace root. Declared
//! build-system modules remain owned by their provider and bypass these defaults.

use crate::protocol::CoreError;
use std::collections::BTreeSet;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

/// Heuristic discovery budget; full fingerprint scans retain cancellation checks.
const MAX_HEURISTIC_DIRECTORIES: usize = 4000;

const EXCLUDED_DIRECTORIES: &[&str] = &[
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

/// Default pruning for automatic run discovery, fingerprints and host Java lists.
/// Hidden source directories are allowed unless explicitly named here.
pub fn is_run_scan_excluded_directory(name: &str) -> bool {
    EXCLUDED_DIRECTORIES
        .iter()
        .any(|excluded| excluded.eq_ignore_ascii_case(name))
}

/// One directory's files, without following directory symlinks.
pub(crate) struct ScannedDirectory {
    pub path: PathBuf,
    pub files: BTreeSet<String>,
}

/// A partial scan must never be used as evidence of deletion or freshness.
pub(crate) struct WorkspaceScan {
    pub directories: Vec<ScannedDirectory>,
    pub unreadable_paths: BTreeSet<String>,
}

/// Traverses automatic discovery inputs. A depth limit belongs only to heuristic
/// service detection; fingerprints and explicit host file lists use no depth limit.
pub(crate) fn scan_run_workspace(
    root: &Path,
    max_depth: Option<usize>,
) -> Result<WorkspaceScan, CoreError> {
    scan_with_reader(root, max_depth, &|path| {
        fs::read_dir(path)?
            .map(|entry| {
                let entry = entry?;
                Ok((
                    entry.path(),
                    entry.file_type()?.is_dir(),
                    entry.file_type()?.is_symlink(),
                ))
            })
            .collect()
    })
}

fn scan_with_reader(
    root: &Path,
    max_depth: Option<usize>,
    read: &impl Fn(&Path) -> io::Result<Vec<(PathBuf, bool, bool)>>,
) -> Result<WorkspaceScan, CoreError> {
    let mut result = WorkspaceScan {
        directories: Vec::new(),
        unreadable_paths: BTreeSet::new(),
    };
    let mut pending = vec![(root.to_owned(), 0)];
    while let Some((path, depth)) = pending.pop() {
        crate::protocol::cancellation::check()?;
        if max_depth.is_some() && result.directories.len() >= MAX_HEURISTIC_DIRECTORIES {
            result.unreadable_paths.insert(relative(root, &path));
            result
                .unreadable_paths
                .extend(pending.iter().map(|(path, _)| relative(root, path)));
            break;
        }
        let entries = match read(&path) {
            Ok(entries) => entries,
            Err(error) if path == root => return Err(CoreError::from(error)),
            Err(_) => {
                result.unreadable_paths.insert(relative(root, &path));
                continue;
            }
        };
        let mut files = BTreeSet::new();
        let mut children = Vec::new();
        for (child, directory, symlink) in entries {
            crate::protocol::cancellation::check()?;
            let Some(name) = child.file_name().and_then(|name| name.to_str()) else {
                result.unreadable_paths.insert(relative(root, &child));
                continue;
            };
            if symlink {
                continue;
            }
            if directory {
                if !is_run_scan_excluded_directory(name)
                    && max_depth.is_none_or(|limit| depth < limit)
                {
                    children.push((child, depth + 1));
                }
            } else {
                files.insert(name.to_owned());
            }
        }
        children.sort_by(|left, right| right.0.cmp(&left.0));
        pending.extend(children);
        result.directories.push(ScannedDirectory { path, files });
    }
    result
        .directories
        .sort_by(|left, right| left.path.cmp(&right.path));
    Ok(result)
}

fn relative(root: &Path, path: &Path) -> String {
    path.strip_prefix(root)
        .unwrap_or(path)
        .to_string_lossy()
        .replace('\\', "/")
}

/// Returns Java paths using the same scan policy as run generation. Failure below
/// the root is tolerated; the subsequent Core fingerprint supplies diagnostics.
pub fn list_run_java_sources(root: &Path, limit: usize) -> Result<Vec<String>, CoreError> {
    let scan = scan_run_workspace(root, None)?;
    let mut paths = scan
        .directories
        .into_iter()
        .flat_map(|directory| {
            directory
                .files
                .into_iter()
                .filter(|name| name.to_ascii_lowercase().ends_with(".java"))
                .map(move |name| relative(root, &directory.path.join(name)))
        })
        .collect::<Vec<_>>();
    paths.sort();
    paths.truncate(limit);
    Ok(paths)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unreadable_child_preserves_siblings_but_root_is_required() {
        let root = Path::new("fixture");
        let read = |path: &Path| {
            if path == root {
                Ok(vec![
                    (root.join("blocked"), true, false),
                    (root.join(".sources"), true, false),
                    (root.join(".pytest_cache"), true, false),
                ])
            } else if path.ends_with(".sources") {
                Ok(vec![(path.join("Main.java"), false, false)])
            } else {
                Err(io::Error::from(io::ErrorKind::PermissionDenied))
            }
        };
        let result = scan_with_reader(root, None, &read).unwrap();
        assert_eq!(result.unreadable_paths, BTreeSet::from(["blocked".into()]));
        assert!(result
            .directories
            .iter()
            .any(|dir| dir.files.contains("Main.java")));
        assert!(scan_with_reader(root, None, &|_| Err(io::Error::from(
            io::ErrorKind::PermissionDenied
        )))
        .is_err());
    }
    #[test]
    fn directory_links_do_not_escape_or_reenter_the_scan() {
        let root = Path::new("fixture");
        let result = scan_with_reader(root, None, &|path| {
            assert_eq!(path, root, "links must never be traversed");
            Ok(vec![
                (root.join("cycle"), true, true),
                (root.join("Main.java"), false, false),
            ])
        })
        .unwrap();
        assert_eq!(result.directories.len(), 1);
        assert_eq!(
            result.directories[0].files,
            BTreeSet::from(["Main.java".into()])
        );
    }
}
