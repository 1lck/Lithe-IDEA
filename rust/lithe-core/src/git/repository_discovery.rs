//! Workspace-scoped Git discovery with native ignore rules and explicit root ownership.

use super::{
    canonicalize_simplified, capture_git_process_streaming, discover_containing_repository,
    git_entry_opens_as_repository, ignored_paths_checked, is_safe_pathspec, path_sort_key,
    repository_scan_error, sort_workspace_repository_paths, untracked_directory_candidates_checked,
    validate_root, WorkspaceRepositoriesRequest,
};
use crate::project::files::VisibilityRules;
use crate::protocol::{
    CoreError, ErrorCode, WorkspaceRepositoriesResponse, WorkspaceRepositoryResponse,
};
use crate::remote::workspace_io as fs;
use std::collections::{HashSet, VecDeque};
use std::path::{Path, PathBuf};

/// Discovers eligible automatic roots plus openable, index-declared submodule dependencies.
/// Exclusions are request-local and never filter files reported by an existing repository.
pub fn workspace_repositories(
    request: WorkspaceRepositoriesRequest,
) -> Result<WorkspaceRepositoriesResponse, CoreError> {
    let workspace = PathBuf::from(validate_root(&request.root)?);
    let excluded = manual_exclusions(&workspace, &request.manual_excluded_directories)?;
    let boundaries = VisibilityRules::new(Vec::new(), Vec::new())
        .with_workspace_roots(&workspace, &request.workspace_roots);
    let containing = discover_containing_repository(&workspace)?;
    let mut repositories = HashSet::new();
    if let Some(root) = &containing {
        repositories.insert(root.clone());
    }
    let mut queue = VecDeque::from([(workspace.clone(), 0usize, containing.clone())]);
    let mut visited = HashSet::new();
    let mut inspected_dependencies = HashSet::new();

    while let Some((directory, depth, mut owner)) = queue.pop_front() {
        crate::protocol::cancellation::check()?;
        if visited.len() >= request.max_directories {
            break;
        }
        let directory = match canonicalize_simplified(&directory) {
            Ok(path) => path,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(error) => return Err(repository_scan_error(error)),
        };
        if !directory.starts_with(&workspace)
            || boundaries.is_delegated(&directory)
            || !visited.insert(directory.clone())
        {
            continue;
        }

        let mut children = Vec::new();
        for entry in fs::read_dir(&directory).map_err(repository_scan_error)? {
            crate::protocol::cancellation::check()?;
            let entry = entry.map_err(repository_scan_error)?;
            let name = entry.file_name().to_string_lossy().to_string();
            if name == ".git" {
                if git_entry_opens_as_repository(&entry.path()) {
                    repositories.insert(directory.clone());
                    owner = Some(directory.clone());
                }
            } else if directory_is_visible(&name)
                && entry.file_type().map_err(repository_scan_error)?.is_dir()
                && !boundaries.is_delegated(&entry.path())
                && !excluded.iter().any(|path| entry.path().starts_with(path))
            {
                children.push(name);
            }
        }

        // A real gitlink remains a dependency even when its containing directory
        // is excluded. Never infer this exception from a nested .git marker.
        if let Some(root) = owner
            .as_ref()
            .filter(|root| inspected_dependencies.insert((*root).clone()))
        {
            for path in submodule_paths(root)? {
                let candidate = root.join(path);
                if !candidate.starts_with(&workspace) || boundaries.is_delegated(&candidate) {
                    continue;
                }
                let relative = candidate.strip_prefix(&workspace).unwrap();
                let dependency_depth = relative.components().count();
                if dependency_depth <= request.max_depth
                    && !has_symlink_component(&workspace, relative)?
                    && git_entry_opens_as_repository(&candidate.join(".git"))
                {
                    queue.push_back((candidate, dependency_depth, Some(root.clone())));
                }
            }
        }
        if depth >= request.max_depth {
            continue;
        }
        children.sort_by(|left, right| {
            path_sort_key(Path::new(left))
                .cmp(&path_sort_key(Path::new(right)))
                .then_with(|| left.cmp(right))
        });
        let ignored = if owner.is_some() {
            ignored_directories(&directory, &children)?
        } else {
            HashSet::new()
        };
        for child in children.into_iter().filter(|name| !ignored.contains(name)) {
            queue.push_back((directory.join(child), depth + 1, owner.clone()));
        }
    }

    let mut repositories = repositories.into_iter().collect::<Vec<_>>();
    sort_workspace_repository_paths(&mut repositories, &workspace);
    if let Some(root) = containing {
        repositories.retain(|path| path != &root);
        repositories.insert(0, root);
    }
    Ok(WorkspaceRepositoriesResponse {
        repositories: repositories
            .into_iter()
            .map(|path| WorkspaceRepositoryResponse {
                path: path.to_string_lossy().replace('\\', "/"),
            })
            .collect(),
    })
}

fn manual_exclusions(root: &Path, paths: &[String]) -> Result<Vec<PathBuf>, CoreError> {
    paths
        .iter()
        .map(|value| {
            let value = value.trim_end_matches('/');
            if value != "."
                && (!is_safe_pathspec(value)
                    || value.contains(['\\', '\0', ':'])
                    || value.split('/').any(|part| part.is_empty() || part == "."))
            {
                return Err(CoreError::new(
                    ErrorCode::InvalidRequest,
                    "Invalid repository exclusion directory",
                ));
            }
            Ok(if value == "." {
                root.to_path_buf()
            } else {
                root.join(value)
            })
        })
        .collect()
}

fn directory_is_visible(name: &str) -> bool {
    if name.eq_ignore_ascii_case(".worktree") || name.eq_ignore_ascii_case(".worktrees") {
        return true;
    }
    !name.starts_with('.')
        && !crate::project::BUILT_IN_HIDDEN_DIRECTORIES
            .iter()
            .any(|hidden| name.eq_ignore_ascii_case(hidden))
}

fn ignored_directories(directory: &Path, paths: &[String]) -> Result<HashSet<String>, CoreError> {
    let ignored = ignored_paths_checked(directory, paths)?
        .into_iter()
        .collect::<Vec<_>>();
    if ignored.is_empty() {
        return Ok(HashSet::new());
    }
    // Tracked descendants and gitlinks keep their ancestor traversable. Status
    // remains Git-owned; manual exclusions only control automatic root discovery.
    untracked_directory_candidates_checked(directory, &ignored)
}

fn submodule_paths(root: &Path) -> Result<Vec<String>, CoreError> {
    // Git 2.31 has no mode-only ls-files query. Stream NUL records through the
    // existing native/remote process owners instead of capturing the whole index.
    let mut record = Vec::new();
    let mut paths = Vec::new();
    let mut consume = |bytes: &[u8]| {
        for part in bytes.split_inclusive(|byte| *byte == 0) {
            if record.len() + part.len() > 1024 * 1024 {
                return Err(CoreError::new(
                    ErrorCode::ProcessFailed,
                    "Git index record exceeded the capture limit",
                ));
            }
            record.extend_from_slice(part);
            if record.last() != Some(&0) {
                continue;
            }
            if let Some(separator) = record.iter().position(|byte| *byte == b'\t') {
                let header = String::from_utf8_lossy(&record[..separator]);
                let mut fields = header.split_whitespace();
                if fields.next() == Some("160000") && fields.nth(1) == Some("0") {
                    let path = String::from_utf8_lossy(&record[separator + 1..record.len() - 1]);
                    if !path.is_empty()
                        && Path::new(path.as_ref())
                            .components()
                            .all(|component| matches!(component, std::path::Component::Normal(_)))
                    {
                        paths.push(path.into_owned());
                    }
                }
            }
            record.clear();
        }
        Ok(())
    };
    let arguments =
        super::execution_policy::arguments(&["ls-files".into(), "--stage".into(), "-z".into()]);
    let response = capture_git_process_streaming(
        &root.to_string_lossy(),
        &arguments,
        None,
        true,
        &[],
        false,
        Some(&mut consume),
    )?;
    if response.exit_code != 0 {
        return Err(CoreError::new(
            ErrorCode::ProcessFailed,
            "Could not inspect repository dependencies",
        )
        .with_details(String::from_utf8_lossy(&response.stderr)));
    }
    if !record.is_empty() {
        return Err(CoreError::new(
            ErrorCode::ParseFailed,
            "Incomplete Git index record",
        ));
    }
    Ok(paths)
}

fn has_symlink_component(root: &Path, relative: &Path) -> Result<bool, CoreError> {
    let mut path = root.to_path_buf();
    for component in relative.components() {
        path.push(component);
        match fs::symlink_metadata(&path) {
            Ok(metadata) if metadata.file_type().is_symlink() => return Ok(true),
            Ok(_) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(true),
            Err(error) => return Err(repository_scan_error(error)),
        }
    }
    Ok(false)
}
