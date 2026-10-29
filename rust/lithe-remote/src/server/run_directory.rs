//! Session-owned private directories for deployed runtime inputs.
//! Persistent disconnects retain them; explicit release or session termination
//! removes them, even if the desktop vanished before receiving allocation.

use crate::protocol::methods::{self, RunDirectoryParams};
use crate::protocol::{ErrorCode, RemoteError};
use crate::server::connection::Context;
use crate::server::fs::io_error;
use crate::server::{lock, parse, platform};
use serde_json::{json, Value};
use std::collections::BTreeMap;
use std::fs;
use std::os::unix::fs::{DirBuilderExt, MetadataExt};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

const MAX_DIRECTORIES: usize = 256;

pub(crate) struct RunDirectories {
    home: Option<String>,
    entries: Mutex<BTreeMap<String, Arc<Directory>>>,
}

struct Directory {
    path: PathBuf,
    allocated: AtomicBool,
    removing: Mutex<()>,
}

impl Drop for Directory {
    fn drop(&mut self) {
        if let Err(error) = self.remove() {
            eprintln!("remote run directory cleanup failed: {:?}", error.kind());
        }
    }
}

impl Directory {
    fn remove(&self) -> std::io::Result<()> {
        if self.allocated.load(Ordering::Acquire) {
            match fs::remove_dir_all(&self.path) {
                Ok(()) => {}
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
                Err(error) => return Err(error),
            }
            self.allocated.store(false, Ordering::Release);
        }
        Ok(())
    }
}

pub(crate) fn validate(params: &RunDirectoryParams) -> Result<(), RemoteError> {
    if params.directory_id.is_empty()
        || params.directory_id.len() > 64
        || !params
            .directory_id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
    {
        return Err(RemoteError::new(
            ErrorCode::InvalidRequest,
            "invalid run directory identity",
        ));
    }
    Ok(())
}

impl RunDirectories {
    pub(crate) fn new(home: Option<String>) -> Self {
        Self {
            home,
            entries: Mutex::default(),
        }
    }

    pub(crate) fn handle(
        &self,
        context: &Context,
        method: &str,
        params: Value,
    ) -> Result<Value, RemoteError> {
        let params: RunDirectoryParams = parse(params)?;
        validate(&params)?;
        if method == methods::FS_RELEASE_RUN_DIRECTORY {
            // Keep failed cleanup registered for retry. Recursive deletion must
            // not hold the registry lock or report success on a failed removal.
            let directory = lock(&self.entries).get(&params.directory_id).cloned();
            let Some(directory) = directory else {
                return Ok(Value::Null);
            };
            let _removing = directory.removing.try_lock().map_err(|_| {
                RemoteError::new(ErrorCode::Busy, "run directory removal in progress")
            })?;
            directory
                .remove()
                .map_err(|error| io_error(error, "run directory"))?;
            self.forget(&params.directory_id, &directory);
            return Ok(Value::Null);
        }
        if context.session.is_ending()
            || (!context.session.persistent && context.closed.load(Ordering::Acquire))
        {
            return Err(RemoteError::new(ErrorCode::NotFound, "session ended"));
        }
        let home = self
            .home
            .as_deref()
            .ok_or_else(|| RemoteError::new(ErrorCode::Unsupported, "host home unavailable"))?;
        let home = crate::server::fs::host_path(home)?;
        let base = home.join(".lithe-server");
        private_directory(&base)?;
        let parent = base.join("plugin-runs");
        private_directory(&parent)?;
        let parent = fs::canonicalize(parent).map_err(|error| io_error(error, "run parent"))?;
        let directory = Arc::new(Directory {
            path: parent.join(&params.directory_id),
            allocated: AtomicBool::new(false),
            removing: Mutex::new(()),
        });
        {
            let mut entries = lock(&self.entries);
            if context.session.is_ending() {
                return Err(RemoteError::new(ErrorCode::NotFound, "session ended"));
            }
            if entries.contains_key(&params.directory_id) {
                return Err(RemoteError::new(
                    ErrorCode::ResourceIdInUse,
                    "run directory identity is active",
                ));
            }
            if entries.len() >= MAX_DIRECTORIES {
                return Err(RemoteError::new(
                    ErrorCode::Busy,
                    "too many run directories",
                ));
            }
            entries.insert(params.directory_id.clone(), Arc::clone(&directory));
        }
        // Never adopt a pre-existing path, including one from another session.
        // The worker's Arc owns late allocation if shutdown drains the registry.
        if let Err(error) = fs::DirBuilder::new().mode(0o700).create(&directory.path) {
            self.forget(&params.directory_id, &directory);
            return Err(io_error(error, "run directory"));
        }
        directory.allocated.store(true, Ordering::Release);
        Ok(json!({"path": directory.path}))
    }

    pub(crate) fn clear(&self) {
        let removed = std::mem::take(&mut *lock(&self.entries));
        drop(removed);
    }

    fn forget(&self, id: &str, directory: &Arc<Directory>) {
        let removed = {
            let mut entries = lock(&self.entries);
            if entries
                .get(id)
                .is_some_and(|entry| Arc::ptr_eq(entry, directory))
            {
                entries.remove(id)
            } else {
                None
            }
        };
        drop(removed);
    }
}

fn private_directory(path: &Path) -> Result<(), RemoteError> {
    match fs::DirBuilder::new().mode(0o700).create(path) {
        Ok(()) => {}
        Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
        Err(error) => return Err(io_error(error, "run parent")),
    }
    let metadata = fs::symlink_metadata(path).map_err(|error| io_error(error, "run parent"))?;
    if !metadata.is_dir()
        || metadata.uid() != platform::current_uid()
        || metadata.mode() & 0o077 != 0
    {
        return Err(RemoteError::new(
            ErrorCode::PermissionDenied,
            "run parent must be a private directory owned by the host user",
        ));
    }
    Ok(())
}
