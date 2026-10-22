//! Bounded projection of wholly untracked directories for change lists.
//!
//! `git status --untracked-files=all` reports one record per file below an
//! unignored build or cache directory, so a single `target/` can flood a
//! change list with thousands of entries. Status consumers that opt in receive
//! Git's collapsed `normal` view instead: an untracked directory larger than
//! [`UNTRACKED_DIRECTORY_SUMMARY_THRESHOLD`] becomes one summary entry, and its
//! contents are listed one level at a time through [`untracked_directory`].
//!
//! A summary is only emitted for a directory without nested repositories, so
//! staging or cleaning its path acts on exactly the files it counts and never
//! turns an independent checkout into a gitlink.

use super::{
    canonicalize_or_original, canonicalize_simplified, git_path_error, is_safe_pathspec,
    pathspec_batches, run_git, LS_FILES_PATHSPEC_BUDGET,
};
use crate::protocol::{CoreError, ErrorCode, GitChange, GitUntrackedDirectoryResponse};
use serde::Deserialize;
use std::collections::HashMap;
use std::path::{Path, PathBuf};

/// Wholly untracked directories holding more files than this are summarized.
///
/// Smaller directories keep one entry per file so a new source folder still
/// shows its files directly, matching `--untracked-files=all`.
pub(crate) const UNTRACKED_DIRECTORY_SUMMARY_THRESHOLD: usize = 100;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Request for the immediate contents of one summarized untracked directory.
pub struct GitUntrackedDirectoryRequest {
    /// Any path inside the repository that owns `directory`.
    pub root: String,
    /// Repository-relative directory with a trailing `/`, as reported by status.
    pub directory: String,
    /// Discovered native root bindings used to exclude independently owned paths.
    #[serde(default)]
    pub repository_roots: Vec<String>,
}

/// One untracked record produced while projecting a directory.
#[derive(Debug, Clone, PartialEq, Eq)]
enum UntrackedEntry {
    File(String),
    /// A nested repository, reported by Git as its directory with a trailing `/`.
    NestedRepository(String),
    /// A directory without nested repositories and the number of files below it.
    Directory {
        path: String,
        file_count: usize,
    },
}

impl UntrackedEntry {
    fn into_change(self) -> GitChange {
        let (path, untracked_file_count) = match self {
            Self::File(path) | Self::NestedRepository(path) => (path, None),
            Self::Directory { path, file_count } => (path, Some(file_count)),
        };
        // Same projection `parse_status` gives a `?` record.
        GitChange {
            path,
            original_path: None,
            status: "??".to_string(),
            staged: false,
            worktree: false,
            untracked: true,
            submodule: None,
            can_toggle_staging: true,
            untracked_file_count,
        }
    }
}

/// Replaces the collapsed `dir/` records of a `--untracked-files=normal` status
/// with file entries, nested repositories, or summaries.
///
/// `changes` must come from a `normal` status of `repository_root`; its untracked
/// directories are disjoint, so each listed file belongs to exactly one of them.
pub(super) fn expand_collapsed_directories(
    repository_root: &Path,
    changes: Vec<GitChange>,
) -> Result<Vec<GitChange>, CoreError> {
    let directories = changes
        .iter()
        .filter(|change| change.untracked && change.path.ends_with('/'))
        .map(|change| change.path.clone())
        .collect::<Vec<_>>();
    if directories.is_empty() {
        return Ok(changes);
    }
    let indices = directories
        .iter()
        .enumerate()
        .map(|(index, directory)| (directory.as_str(), index))
        .collect::<HashMap<_, _>>();
    let mut contents = vec![Vec::new(); directories.len()];
    for path in list_untracked(repository_root, &directories)? {
        let owner = owning_directory(&path).find_map(|prefix| indices.get(prefix).copied());
        if let Some(owner) = owner {
            contents[owner].push(path);
        }
    }

    let mut expanded = changes
        .into_iter()
        .filter(|change| !(change.untracked && change.path.ends_with('/')))
        .collect::<Vec<_>>();
    for (directory, contents) in directories.iter().zip(&contents) {
        let mut entries = Vec::new();
        summarize(
            directory,
            contents,
            UNTRACKED_DIRECTORY_SUMMARY_THRESHOLD,
            &mut entries,
        );
        expanded.extend(entries.into_iter().map(UntrackedEntry::into_change));
    }
    expanded.sort_by(|left, right| left.path.cmp(&right.path));
    Ok(expanded)
}

/// Lists the immediate files and subdirectories of one summarized directory.
///
/// Every subdirectory is returned as a summary, so expanding a tree costs one
/// level per request regardless of how many files lie below it.
pub fn untracked_directory(
    request: GitUntrackedDirectoryRequest,
) -> Result<GitUntrackedDirectoryResponse, CoreError> {
    if !request.directory.ends_with('/') || !is_safe_pathspec(&request.directory) {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Untracked directory must be a repository-relative path ending with /",
        ));
    }
    let root = canonicalize_simplified(Path::new(&request.root)).map_err(git_path_error)?;
    let output = run_git(&root, &["rev-parse", "--show-toplevel"])?;
    if !output.status.success() {
        return Err(
            CoreError::new(ErrorCode::ProcessFailed, "Git repository lookup failed")
                .with_details(String::from_utf8_lossy(&output.stderr)),
        );
    }
    let repository_root = canonicalize_or_original(&PathBuf::from(
        String::from_utf8_lossy(&output.stdout).trim_end_matches(['\r', '\n']),
    ))
    .map_err(git_path_error)?;

    let entries = list_untracked(&repository_root, std::slice::from_ref(&request.directory))?;
    let mut children = Vec::new();
    for (child, group) in immediate_children(&request.directory, &entries) {
        match child {
            Child::File(path) => children.push(UntrackedEntry::File(path)),
            Child::NestedRepository(path) => children.push(UntrackedEntry::NestedRepository(path)),
            // A zero threshold summarizes every subdirectory that is safe to
            // collapse and splits one that contains a nested repository.
            Child::Directory(path) => summarize(&path, group, 0, &mut children),
        }
    }
    let mut changes = children
        .into_iter()
        .map(UntrackedEntry::into_change)
        .collect::<Vec<_>>();
    retain_outside_known_roots(&mut changes, &repository_root, &request.repository_roots)?;
    changes.sort_by(|left, right| left.path.cmp(&right.path));
    Ok(GitUntrackedDirectoryResponse { changes })
}

/// Removes untracked entries owned by another discovered repository.
///
/// An embedded independent repository must not become a gitlink through a
/// parent Stage All. Gitlinks already tracked by the parent remain visible.
pub(super) fn retain_outside_known_roots(
    changes: &mut Vec<GitChange>,
    repository_root: &Path,
    repository_roots: &[String],
) -> Result<(), CoreError> {
    // Native bindings may use macOS /var aliases or Windows short/verbatim
    // paths. Compare the same canonical identity as Git's reported root.
    let known_roots = repository_roots
        .iter()
        .map(|root| canonicalize_or_original(Path::new(root)).map_err(git_path_error))
        .collect::<Result<Vec<_>, _>>()?;
    changes.retain(|change| {
        !change.untracked
            || !known_roots.iter().any(|other| {
                other != repository_root
                    && other.starts_with(repository_root)
                    && repository_root.join(&change.path).starts_with(other)
            })
    });
    Ok(())
}

/// Returns every non-ignored untracked file below `directories`, plus nested
/// repositories as `path/` records, exactly as `--untracked-files=all` would.
fn list_untracked(
    repository_root: &Path,
    directories: &[String],
) -> Result<Vec<String>, CoreError> {
    let mut paths = Vec::new();
    for batch in pathspec_batches(directories, LS_FILES_PATHSPEC_BUDGET) {
        let mut arguments = vec![
            "--literal-pathspecs",
            "ls-files",
            "-z",
            "--others",
            "--exclude-standard",
            "--",
        ];
        arguments.extend(batch.iter().map(String::as_str));
        let output = run_git(repository_root, &arguments)?;
        if !output.status.success() {
            return Err(CoreError::new(
                ErrorCode::ProcessFailed,
                "Git untracked file listing failed",
            )
            .with_details(String::from_utf8_lossy(&output.stderr)));
        }
        paths.extend(
            output
                .stdout
                .split(|byte| *byte == 0)
                .filter(|record| !record.is_empty())
                .map(|record| String::from_utf8_lossy(record).into_owned()),
        );
    }
    paths.sort();
    Ok(paths)
}

/// Yields each directory prefix of `path` with a trailing `/`, outermost first.
/// A nested repository record `dir/` yields `dir/` itself last.
fn owning_directory(path: &str) -> impl Iterator<Item = &str> {
    path.match_indices('/')
        .map(move |(index, _)| &path[..=index])
}

/// Emits the entries for `directory`, whose contents are `entries`.
///
/// A directory without nested repositories becomes one summary when it holds
/// more than `threshold` files and stays file-level otherwise. A directory that
/// contains a nested repository is split one level further, because acting on
/// its path would also act on that repository.
fn summarize(
    directory: &str,
    entries: &[String],
    threshold: usize,
    output: &mut Vec<UntrackedEntry>,
) {
    if entries.is_empty() {
        return;
    }
    if !entries.iter().any(|entry| entry.ends_with('/')) {
        if entries.len() > threshold {
            output.push(UntrackedEntry::Directory {
                path: directory.to_string(),
                file_count: entries.len(),
            });
        } else {
            output.extend(entries.iter().cloned().map(UntrackedEntry::File));
        }
        return;
    }
    for (child, group) in immediate_children(directory, entries) {
        match child {
            Child::File(path) => output.push(UntrackedEntry::File(path)),
            Child::NestedRepository(path) => output.push(UntrackedEntry::NestedRepository(path)),
            Child::Directory(path) => summarize(&path, group, threshold, output),
        }
    }
}

/// One immediate child of a directory being projected.
enum Child {
    File(String),
    NestedRepository(String),
    Directory(String),
}

/// Groups sorted `entries` below `directory` by their immediate child.
///
/// A `Child::Directory` is paired with every entry below it; other children are
/// paired with an empty slice.
fn immediate_children<'a>(directory: &str, entries: &'a [String]) -> Vec<(Child, &'a [String])> {
    let mut children = Vec::new();
    let mut index = 0;
    while index < entries.len() {
        let entry = &entries[index];
        let remainder = entry.strip_prefix(directory).unwrap_or(entry);
        match remainder.find('/') {
            // `directory` itself is a nested repository.
            _ if remainder.is_empty() => {
                children.push((
                    Child::NestedRepository(entry.clone()),
                    &entries[index..index],
                ));
                index += 1;
            }
            None => {
                children.push((Child::File(entry.clone()), &entries[index..index]));
                index += 1;
            }
            Some(slash) if slash + 1 == remainder.len() => {
                children.push((
                    Child::NestedRepository(entry.clone()),
                    &entries[index..index],
                ));
                index += 1;
            }
            Some(slash) => {
                let child = format!("{directory}{}", &remainder[..=slash]);
                let end = index
                    + entries[index..]
                        .iter()
                        .take_while(|candidate| candidate.starts_with(&child))
                        .count();
                children.push((Child::Directory(child), &entries[index..end]));
                index = end;
            }
        }
    }
    children
}

#[cfg(test)]
mod tests {
    use super::{immediate_children, owning_directory, summarize, Child, UntrackedEntry};

    fn paths(values: &[&str]) -> Vec<String> {
        let mut values = values
            .iter()
            .map(|value| value.to_string())
            .collect::<Vec<_>>();
        values.sort();
        values
    }

    fn summarized(directory: &str, entries: &[&str], threshold: usize) -> Vec<UntrackedEntry> {
        let mut output = Vec::new();
        summarize(directory, &paths(entries), threshold, &mut output);
        output
    }

    #[test]
    fn large_directory_without_nested_repositories_becomes_one_summary() {
        assert_eq!(
            summarized(
                "target/",
                &["target/a", "target/debug/b", "target/debug/c"],
                2
            ),
            vec![UntrackedEntry::Directory {
                path: "target/".into(),
                file_count: 3
            }]
        );
    }

    #[test]
    fn directory_within_threshold_keeps_file_entries() {
        // A new source folder must still list its files like `-uall`.
        assert_eq!(
            summarized("src/feature/", &["src/feature/a.rs", "src/feature/b.rs"], 2),
            vec![
                UntrackedEntry::File("src/feature/a.rs".into()),
                UntrackedEntry::File("src/feature/b.rs".into()),
            ]
        );
    }

    #[test]
    fn directory_containing_a_nested_repository_is_never_summarized() {
        // Staging `.worktrees/` would record every linked worktree as a gitlink.
        assert_eq!(
            summarized(
                ".worktrees/",
                &[
                    ".worktrees/a/",
                    ".worktrees/b/",
                    ".worktrees/notes.txt",
                    ".worktrees/cache/x",
                    ".worktrees/cache/y",
                    ".worktrees/cache/z",
                ],
                2
            ),
            vec![
                UntrackedEntry::NestedRepository(".worktrees/a/".into()),
                UntrackedEntry::NestedRepository(".worktrees/b/".into()),
                UntrackedEntry::Directory {
                    path: ".worktrees/cache/".into(),
                    file_count: 3
                },
                UntrackedEntry::File(".worktrees/notes.txt".into()),
            ]
        );
    }

    #[test]
    fn nested_repository_deeper_in_the_tree_splits_only_its_ancestors() {
        assert_eq!(
            summarized(
                "mixed/",
                &["mixed/m.txt", "mixed/sub/q.txt", "mixed/sub/repo/"],
                0
            ),
            vec![
                UntrackedEntry::File("mixed/m.txt".into()),
                UntrackedEntry::File("mixed/sub/q.txt".into()),
                UntrackedEntry::NestedRepository("mixed/sub/repo/".into()),
            ]
        );
    }

    #[test]
    fn collapsed_record_that_is_itself_a_repository_stays_a_repository() {
        assert_eq!(
            summarized("inner/", &["inner/"], 0),
            vec![UntrackedEntry::NestedRepository("inner/".into())]
        );
    }

    #[test]
    fn immediate_children_group_descendants_under_their_first_component() {
        let entries = paths(&["d/a-b/x", "d/a/y", "d/a/z", "d/f", "d/r/"]);
        let children = immediate_children("d/", &entries)
            .into_iter()
            .map(|(child, group)| match child {
                Child::File(path) => format!("file {path}"),
                Child::NestedRepository(path) => format!("repo {path}"),
                Child::Directory(path) => format!("dir {path} {}", group.len()),
            })
            .collect::<Vec<_>>();
        assert_eq!(
            children,
            ["dir d/a-b/ 1", "dir d/a/ 2", "file d/f", "repo d/r/"]
        );
    }

    #[test]
    fn owning_directories_include_a_repository_record_itself() {
        assert_eq!(
            owning_directory("a/b/c").collect::<Vec<_>>(),
            ["a/", "a/b/"]
        );
        assert_eq!(owning_directory("a/r/").collect::<Vec<_>>(), ["a/", "a/r/"]);
    }
}
