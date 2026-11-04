//! Shared run-discovery traversal and incomplete-snapshot diagnostics.
//!
//! Automatic discovery is best effort below the required workspace root. Declared
//! build-system modules remain owned by their provider and bypass these defaults.

use crate::protocol::CoreError;
use crate::remote::workspace_io as fs;
use std::collections::BTreeSet;
use std::io;
use std::ops::ControlFlow;
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
    scan_with_reader(root, max_depth, &read_directory)
}

fn read_directory(path: &Path) -> io::Result<Vec<(PathBuf, bool, bool)>> {
    fs::read_dir(path)?
        .map(|entry| {
            let entry = entry?;
            let kind = entry.file_type()?;
            Ok((entry.path(), kind.is_dir(), kind.is_symlink()))
        })
        .collect()
}

// Crate-visible so remote integration tests can drop the link between reads.
pub(crate) fn scan_with_reader(
    root: &Path,
    max_depth: Option<usize>,
    read: &impl Fn(&Path) -> io::Result<Vec<(PathBuf, bool, bool)>>,
) -> Result<WorkspaceScan, CoreError> {
    let mut directories = Vec::new();
    let unreadable_paths = visit_with_reader(root, max_depth, read, |directory| {
        directories.push(directory);
        ControlFlow::Continue(())
    })?;
    directories.sort_by(|left, right| left.path.cmp(&right.path));
    Ok(WorkspaceScan {
        directories,
        unreadable_paths,
    })
}

// Consumers decide whether to retain each directory and when enough inputs have
// been found. Early stopping must not change full fingerprint scan semantics.
fn visit_with_reader(
    root: &Path,
    max_depth: Option<usize>,
    read: &impl Fn(&Path) -> io::Result<Vec<(PathBuf, bool, bool)>>,
    mut visit: impl FnMut(ScannedDirectory) -> ControlFlow<()>,
) -> Result<BTreeSet<String>, CoreError> {
    let mut unreadable_paths = BTreeSet::new();
    let mut directory_count = 0;
    let mut pending = vec![(root.to_owned(), 0)];
    while let Some((path, depth)) = pending.pop() {
        crate::protocol::cancellation::check()?;
        if max_depth.is_some() && directory_count >= MAX_HEURISTIC_DIRECTORIES {
            unreadable_paths.insert(relative(root, &path));
            unreadable_paths.extend(pending.iter().map(|(path, _)| relative(root, path)));
            break;
        }
        let entries = match read(&path) {
            Ok(entries) => entries,
            Err(error) if path == root => return Err(CoreError::from(error)),
            // A broken remote transport says nothing about this directory, and
            // continuing would publish a model built from a truncated tree.
            // Failures the host reports for one path stay explicit incomplete-scan
            // evidence, exactly as they do for a local workspace.
            Err(error) if fs::is_transport_failure(&error) => return Err(CoreError::from(error)),
            Err(_) => {
                unreadable_paths.insert(relative(root, &path));
                continue;
            }
        };
        let mut files = BTreeSet::new();
        let mut children = Vec::new();
        for (child, directory, symlink) in entries {
            crate::protocol::cancellation::check()?;
            let Some(name) = child.file_name().and_then(|name| name.to_str()) else {
                unreadable_paths.insert(relative(root, &child));
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
        directory_count += 1;
        if visit(ScannedDirectory { path, files }).is_break() {
            break;
        }
    }
    Ok(unreadable_paths)
}

fn relative(root: &Path, path: &Path) -> String {
    path.strip_prefix(root)
        .unwrap_or(path)
        .to_string_lossy()
        .replace('\\', "/")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn early_stop_retains_observed_unreadable_paths_without_affecting_full_scans() {
        let root = Path::new("fixture");
        let read = |path: &Path| {
            if path == root {
                Ok(vec![
                    (root.join("a-blocked"), true, false),
                    (root.join("b-sources"), true, false),
                    (root.join("z-later"), true, false),
                ])
            } else if path.ends_with("a-blocked") {
                Err(io::Error::from(io::ErrorKind::PermissionDenied))
            } else {
                Ok(vec![(path.join("Main.java"), false, false)])
            }
        };
        let unknown = visit_with_reader(root, None, &read, |directory| {
            if directory.files.contains("Main.java") {
                ControlFlow::Break(())
            } else {
                ControlFlow::Continue(())
            }
        })
        .unwrap();
        assert_eq!(unknown, BTreeSet::from(["a-blocked".into()]));
        let full = scan_with_reader(root, None, &read).unwrap();
        assert_eq!(full.unreadable_paths, unknown);
        assert!(full
            .directories
            .iter()
            .any(|dir| dir.path.ends_with("z-later")));
    }

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
