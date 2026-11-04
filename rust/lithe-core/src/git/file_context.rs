//! Resolve a file to its actual Git checkout, independently of UI selection.

use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use std::path::{Component, Path, PathBuf};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Request {
    root: String,
    path: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Context {
    root: String,
    path: String,
    ownership: &'static str,
}

/// Resolve the parent, keeping a missing suffix for deleted files. The final
/// component is never canonicalized: a tracked symlink belongs to the checkout
/// containing the link, not to the repository containing its target.
fn resolved_parent(path: &Path) -> Result<PathBuf, CoreError> {
    let mut candidate = path;
    let mut missing = Vec::new();
    loop {
        match super::canonicalize_simplified(candidate) {
            Ok(mut existing) => {
                if !super::fs::is_dir(&existing).map_err(super::git_path_error)? {
                    return Err(CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Git file parent is not a directory",
                    ));
                }
                for name in missing.into_iter().rev() {
                    existing.push(name);
                }
                return Ok(existing);
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                let name = candidate
                    .file_name()
                    .ok_or_else(|| super::git_path_error(error))?;
                missing.push(name.to_os_string());
                candidate = candidate.parent().ok_or_else(|| {
                    CoreError::new(ErrorCode::InvalidRequest, "Invalid Git file path")
                })?;
            }
            Err(error) => return Err(super::git_path_error(error)),
        }
    }
}

/// Resolve the deepest actual Git checkout and the file's path inside it.
/// Missing directories use their nearest existing ancestor; discovery failures
/// never silently fall back to the currently selected repository.
pub(crate) fn resolve(request: Request) -> Result<Option<Context>, CoreError> {
    if request.path.is_empty() || request.path.contains('\0') {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Invalid Git file path",
        ));
    }
    let requested = Path::new(&request.path);
    let absolute = if requested.is_absolute() {
        requested.to_path_buf()
    } else {
        PathBuf::from(super::validate_root(&request.root)?).join(requested)
    };
    super::validate_windows_git_path(&absolute).map_err(super::git_path_error)?;
    // Ambiguous parent segments after a missing directory cannot be resolved
    // correctly against symbolic links; reject rather than guess ownership.
    if absolute
        .components()
        .any(|component| matches!(component, Component::ParentDir))
    {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Invalid Git file path",
        ));
    }
    let name = absolute
        .file_name()
        .ok_or_else(|| CoreError::new(ErrorCode::InvalidRequest, "Invalid Git file path"))?;
    let parent = absolute
        .parent()
        .ok_or_else(|| CoreError::new(ErrorCode::InvalidRequest, "Invalid Git file path"))?;
    let resolved = resolved_parent(parent)?.join(name);
    let mut existing = resolved.parent().expect("resolved file has a parent");
    loop {
        match super::fs::is_dir(existing) {
            Ok(true) => break,
            Ok(false) => {}
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => return Err(super::git_path_error(error)),
        }
        existing = existing.parent().ok_or_else(|| {
            CoreError::new(ErrorCode::WorkspaceNotFound, "Workspace does not exist")
        })?;
    }
    let Some(root) = super::discover_containing_repository(existing)? else {
        return Ok(None);
    };
    let relative = resolved.strip_prefix(&root).map_err(|_| {
        CoreError::new(
            ErrorCode::InvalidRequest,
            "File is outside its Git repository",
        )
    })?;
    let relative = relative
        .to_str()
        .ok_or_else(|| CoreError::new(ErrorCode::InvalidRequest, "Git file path is not UTF-8"))?;
    let relative = if cfg!(windows) {
        relative.replace('\\', "/")
    } else {
        relative.to_owned()
    };
    if relative.is_empty() {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Invalid Git file path",
        ));
    }
    let root = root.to_str().ok_or_else(|| {
        CoreError::new(
            ErrorCode::InvalidRequest,
            "Git repository path is not UTF-8",
        )
    })?;
    let root = if cfg!(windows) {
        root.replace('\\', "/")
    } else {
        root.to_owned()
    };
    Ok(Some(Context {
        root,
        path: relative,
        ownership: "git",
    }))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::process::Command;
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT: AtomicU64 = AtomicU64::new(0);

    struct Repositories(PathBuf);
    impl Repositories {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!(
                "lithe-file-context-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            fs::create_dir_all(&root).unwrap();
            for child in ["first", "second", "first/nested"] {
                let directory = root.join(child);
                fs::create_dir_all(&directory).unwrap();
                assert!(Command::new("git")
                    .args(["init", "-q"])
                    .current_dir(directory)
                    .status()
                    .unwrap()
                    .success());
            }
            Self(root)
        }
        fn root(&self, name: &str) -> String {
            super::super::canonicalize_simplified(&self.0.join(name))
                .unwrap()
                .to_string_lossy()
                .replace('\\', "/")
        }
        fn resolve(&self, root: &str, path: &str) -> Option<Context> {
            resolve(Request {
                root: root.into(),
                path: path.into(),
            })
            .unwrap()
        }
    }
    impl Drop for Repositories {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn discovers_sibling_nested_and_deleted_files() {
        let repos = Repositories::new();
        let first = repos.root("first");
        let second = repos.root("second");
        let nested = repos.root("first/nested");
        let context = repos
            .resolve(&first, &format!("{second}/deleted/deep/file.txt"))
            .unwrap();
        assert_eq!(
            (
                context.root.as_str(),
                context.path.as_str(),
                context.ownership
            ),
            (second.as_str(), "deleted/deep/file.txt", "git")
        );
        let context = repos.resolve(&first, "nested/missing/file.txt").unwrap();
        assert_eq!(
            (context.root.as_str(), context.path.as_str()),
            (nested.as_str(), "missing/file.txt")
        );
        assert!(repos
            .resolve(&first, &format!("{}/outside.txt", repos.0.display()))
            .is_none());
    }

    #[cfg(unix)]
    #[test]
    fn follows_parent_links_but_not_the_file_symlink() {
        use std::os::unix::fs::symlink;
        let repos = Repositories::new();
        let first = repos.root("first");
        let second = repos.root("second");
        symlink(&repos.0.join("second"), repos.0.join("first/linkdir")).unwrap();
        symlink(
            &repos.0.join("second/target"),
            repos.0.join("first/linkfile"),
        )
        .unwrap();
        let context = repos.resolve(&first, "linkdir/missing/file.txt").unwrap();
        assert_eq!(
            (context.root.as_str(), context.path.as_str()),
            (second.as_str(), "missing/file.txt")
        );
        let context = repos.resolve(&first, r"literal\name.txt").unwrap();
        assert_eq!(context.path, r"literal\name.txt");
        let context = repos.resolve(&first, "linkfile").unwrap();
        assert_eq!(
            (context.root.as_str(), context.path.as_str()),
            (first.as_str(), "linkfile")
        );
    }

    #[test]
    fn rejects_ambiguous_parent_segments_and_routes_json() {
        let repos = Repositories::new();
        let root = repos.root("first");
        assert!(resolve(Request {
            root: root.clone(),
            path: "missing/../file".into()
        })
        .is_err());
        let response: serde_json::Value = serde_json::from_str(&crate::execute_json(
            &serde_json::json!({
                "id":"resolve", "command":"git.resolveFileContext",
                "payload":{"root":root,"path":"nested/file.txt"}
            })
            .to_string(),
        ))
        .unwrap();
        assert_eq!(response["ok"], true, "{response}");
        assert_eq!(response["data"]["root"], repos.root("first/nested"));
        assert_eq!(response["data"]["path"], "file.txt");
        assert_eq!(response["data"]["ownership"], "git");
    }
}
