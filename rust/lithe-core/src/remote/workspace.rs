//! Request-scoped host identity for existing workspace semantic engines.
//!
//! A remote request never falls back to the placeholder filesystem or local
//! executables. Git continues to own Git semantics; this boundary supplies IO.

use super::sessions::{lookup, Connection};
use crate::protocol::{CoreError, ErrorCode};
use serde::Deserialize;
use std::cell::RefCell;
use std::path::{Path, PathBuf};
use std::sync::Arc;

/// Host and path identity supplied by the native workspace registry.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Workspace {
    session_id: String,
    local_root: PathBuf,
    remote_root: PathBuf,
}

#[derive(Clone)]
pub(crate) struct Host {
    pub(crate) connection: Arc<Connection>,
    workspace: Workspace,
}

thread_local! { static HOST: RefCell<Option<Host>> = const { RefCell::new(None) }; }

/// Restores the caller's host for nested Core requests and error paths.
pub(crate) struct Scope(Option<Host>);

impl Scope {
    pub(crate) fn begin(workspace: Option<Workspace>, command: &str) -> Result<Self, CoreError> {
        let host = workspace
            .map(|workspace| {
                if !(command.starts_with("git.")
                    || command.starts_with("build.")
                    || matches!(
                        command,
                        "workspace.repositories"
                            | "workspace.snapshot"
                            | "workspace.listDirectories"
                            | "workspace.search"
                            | "workspace.searchEverywhere"
                            | "file.read"
                            | "file.write"
                            | "workspace.searchIndex.warm"
                            | "workspace.searchIndex.update"
                            | "workspace.searchIndex.invalidate"
                            | "workspace.replacePreview"
                            | "runConfig.selectJava"
                            | "lsp.startServer"
                    ))
                {
                    return Err(CoreError::new(
                        ErrorCode::NotSupported,
                        "This command has no remote workspace adapter",
                    ));
                }
                if !valid_root(&workspace.local_root)
                    || workspace.local_root.file_name().is_none()
                    || !valid_root(&workspace.remote_root)
                {
                    return Err(CoreError::new(
                        ErrorCode::InvalidRequest,
                        "Workspace roots must be absolute without parent components",
                    ));
                }
                Ok(Host {
                    connection: lookup(&workspace.session_id)?,
                    workspace,
                })
            })
            .transpose()?;
        Ok(Self(HOST.with(|current| current.replace(host))))
    }
}

/// Installs an already validated session owner on a backend worker.
pub(crate) fn enter(host: Option<Host>) -> Scope {
    Scope(HOST.with(|current| current.replace(host)))
}

fn valid_root(path: &Path) -> bool {
    path.is_absolute()
        && !path
            .components()
            .any(|component| matches!(component, std::path::Component::ParentDir))
}

impl Drop for Scope {
    fn drop(&mut self) {
        HOST.with(|current| current.replace(self.0.take()));
    }
}

pub(crate) fn current() -> Option<Host> {
    HOST.with(|host| host.borrow().clone())
}

/// Whether filesystem and tool operations belong to a connected workspace host.
pub(crate) fn is_remote() -> bool {
    current().is_some()
}

impl Host {
    /// Maps schema-owned file URIs while preserving host identity and escaping.
    pub(crate) fn map_uri(&self, value: &str, outbound: bool) -> Option<String> {
        let uri = url::Url::parse(value).ok()?;
        if uri.scheme() != "file"
            || uri
                .host_str()
                .is_some_and(|host| !host.is_empty() && host != "localhost")
        {
            return None;
        }
        let path = uri.to_file_path().ok()?;
        let mapped = if outbound {
            self.remote_path(&path)
        } else {
            self.local_path(&path)
        };
        if mapped == path {
            return None;
        }
        url::Url::from_file_path(mapped)
            .ok()
            .map(|uri| uri.to_string())
    }
    pub(crate) fn remote_path(&self, path: &Path) -> PathBuf {
        if let Ok(suffix) = path.strip_prefix(self.host_paths_root()) {
            return Path::new("/").join(suffix);
        }
        if path == self.workspace.local_root {
            return self.workspace.remote_root.clone();
        }
        path.strip_prefix(&self.workspace.local_root)
            .map(|suffix| self.workspace.remote_root.join(suffix))
            .unwrap_or_else(|_| path.to_owned())
    }

    pub(super) fn local_path(&self, path: &Path) -> PathBuf {
        if path == self.workspace.remote_root {
            return self.workspace.local_root.clone();
        }
        path.strip_prefix(&self.workspace.remote_root)
            .map(|suffix| self.workspace.local_root.join(suffix))
            .unwrap_or_else(|_| {
                path.strip_prefix("/")
                    .map(|suffix| self.host_paths_root().join(suffix))
                    .unwrap_or_else(|_| path.to_owned())
            })
    }

    fn host_paths_root(&self) -> PathBuf {
        // A sibling namespace cannot collide with files in the opened folder.
        // Keep this projection in sync with RemoteWorkspaceBinding on macOS.
        let mut name = self
            .workspace
            .local_root
            .file_name()
            .unwrap()
            .to_os_string();
        name.push(".lithe-remote-host");
        self.workspace.local_root.with_file_name(name)
    }

    pub(super) fn identity(&self) -> &str {
        &self.workspace.session_id
    }
}

/// Projects host paths back onto the native workspace's URL identity.
pub(crate) fn local_path(path: &Path) -> PathBuf {
    current()
        .map(|host| host.local_path(path))
        .unwrap_or_else(|| path.to_owned())
}

/// Translates a schema-owned path to its host; opaque argv and text stay untouched.
pub(crate) fn remote_path(path: &Path) -> PathBuf {
    current()
        .map(|host| host.remote_path(path))
        .unwrap_or_else(|| path.to_owned())
}

/// Includes host identity in process-local repository coordination keys.
pub(crate) fn identity_key(path: &Path) -> PathBuf {
    current()
        .map(|host| PathBuf::from(host.identity()).join(path.strip_prefix("/").unwrap_or(path)))
        .unwrap_or_else(|| path.to_owned())
}
