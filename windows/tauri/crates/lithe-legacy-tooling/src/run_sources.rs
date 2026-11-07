//! Java source listing that follows the run-discovery scan policy.
//!
//! Moved out of lithe-core's `execution/workspace_scan.rs`, where only the
//! Windows host called it. The skipped-directory list stays in Core and is
//! re-exported here, so run discovery and this listing never disagree about
//! which directories hold project sources.

use lithe_core::CoreError;
use std::collections::BTreeSet;
use std::io;
use std::path::{Path, PathBuf};

pub use lithe_core::execution::is_run_scan_excluded_directory;

/// One directory entry: its path, whether it is a directory, whether it is a link.
type Entry = (PathBuf, bool, bool);

/// Returns Java paths using the same scan policy as run generation. Failure below
/// the root is tolerated; the subsequent Core fingerprint supplies diagnostics.
/// Stops before opening another directory once the limit is reached, retaining
/// only Java paths from the deterministic traversal rather than a full snapshot.
pub fn list_run_java_sources(root: &Path, limit: usize) -> Result<Vec<String>, CoreError> {
    list_java_sources_with_reader(root, limit, &read_directory)
}

fn read_directory(path: &Path) -> io::Result<Vec<Entry>> {
    std::fs::read_dir(path)?
        .map(|entry| {
            let entry = entry?;
            let kind = entry.file_type()?;
            Ok((entry.path(), kind.is_dir(), kind.is_symlink()))
        })
        .collect()
}

fn list_java_sources_with_reader(
    root: &Path,
    limit: usize,
    read: &impl Fn(&Path) -> io::Result<Vec<Entry>>,
) -> Result<Vec<String>, CoreError> {
    let mut paths = Vec::new();
    if limit == 0 {
        return Ok(paths);
    }
    let mut pending = vec![root.to_owned()];
    'search: while let Some(directory) = pending.pop() {
        lithe_core::check_cancellation()?;
        let entries = match read(&directory) {
            Ok(entries) => entries,
            Err(error) if directory == root => return Err(CoreError::from(error)),
            // Below the root an unreadable directory only means fewer sources.
            Err(_) => continue,
        };
        let (files, children) = split_entries(entries)?;
        // Children are visited in ascending order: the stack pops the last one.
        pending.extend(children);
        for name in files {
            if name.to_ascii_lowercase().ends_with(".java") {
                paths.push(relative(root, &directory.join(name)));
                if paths.len() == limit {
                    break 'search;
                }
            }
        }
    }
    paths.sort();
    Ok(paths)
}

/// Separates a directory's file names from the child directories worth visiting.
/// Links are never followed, and names that are not valid UTF-8 are skipped.
fn split_entries(entries: Vec<Entry>) -> Result<(BTreeSet<String>, Vec<PathBuf>), CoreError> {
    let mut files = BTreeSet::new();
    let mut children = Vec::new();
    for (child, directory, symlink) in entries {
        lithe_core::check_cancellation()?;
        let Some(name) = child.file_name().and_then(|name| name.to_str()) else {
            continue;
        };
        if symlink {
            continue;
        }
        if directory {
            if !is_run_scan_excluded_directory(name) {
                children.push(child);
            }
        } else {
            files.insert(name.to_owned());
        }
    }
    children.sort_by(|left, right| right.cmp(left));
    Ok((files, children))
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
    fn java_source_limit_stops_directory_reads_and_keeps_deterministic_results() {
        let root = Path::new("fixture");
        for limit in [1, 8_000] {
            let visited = std::cell::RefCell::new(Vec::new());
            let paths = list_java_sources_with_reader(root, limit, &|path| {
                visited.borrow_mut().push(path.to_owned());
                if path == root {
                    Ok(vec![
                        (root.join("z-unvisited"), true, false),
                        (root.join("b-sources"), true, false),
                        (root.join("a-blocked"), true, false),
                        (root.join(".pytest_cache"), true, false),
                        (root.join("link"), true, true),
                    ])
                } else if path.ends_with("a-blocked") {
                    Err(io::Error::from(io::ErrorKind::PermissionDenied))
                } else if path.ends_with("b-sources") {
                    // More than the cap in one directory must neither exceed the
                    // result limit nor open a later directory. Reverse native
                    // enumeration order to protect deterministic selection.
                    Ok((0..=limit)
                        .rev()
                        .map(|index| (path.join(format!("Main{index:05}.java")), false, false))
                        .chain([(path.join("nested"), true, false)])
                        .collect())
                } else {
                    panic!("source budget must prevent reading {}", path.display());
                }
            })
            .unwrap();
            assert_eq!(
                paths,
                (0..limit)
                    .map(|index| format!("b-sources/Main{index:05}.java"))
                    .collect::<Vec<_>>()
            );
            assert_eq!(
                *visited.borrow(),
                [
                    root.to_owned(),
                    root.join("a-blocked"),
                    root.join("b-sources")
                ]
            );
        }
    }

    #[test]
    fn java_source_zero_limit_does_not_read_the_workspace() {
        let paths = list_java_sources_with_reader(Path::new("fixture"), 0, &|_| {
            panic!("zero budget must not read directories")
        })
        .unwrap();
        assert!(paths.is_empty());
    }

    #[test]
    fn unreadable_child_is_skipped_but_the_root_is_required() {
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
        assert_eq!(
            list_java_sources_with_reader(root, 10, &read).unwrap(),
            ["b-sources/Main.java", "z-later/Main.java"]
        );
        assert!(
            list_java_sources_with_reader(root, 10, &|_| Err(io::Error::from(
                io::ErrorKind::PermissionDenied
            )))
            .is_err()
        );
    }

    #[test]
    fn directory_links_do_not_escape_or_reenter_the_scan() {
        let root = Path::new("fixture");
        let paths = list_java_sources_with_reader(root, 10, &|path| {
            assert_eq!(path, root, "links must never be traversed");
            Ok(vec![
                (root.join("cycle"), true, true),
                (root.join("Main.java"), false, false),
            ])
        })
        .unwrap();
        assert_eq!(paths, ["Main.java"]);
    }
}
