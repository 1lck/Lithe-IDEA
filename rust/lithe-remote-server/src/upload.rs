//! Connection-owned, bounded uploads with verified atomic publication.
//! Staging files disappear on abort, disconnect, expiry, or failed commit.

use crate::connection::Context;
use crate::fs::{host_path, io_error};
use crate::{lock, parse, platform};
use lithe_remote_protocol::methods::{self, UploadChunkParams, UploadParams, UploadStartParams};
use lithe_remote_protocol::{ErrorCode, RemoteError};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::io::Write;
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, TryLockError};
use std::time::{Duration, Instant};

const MAX_UPLOADS: usize = 4;
const LIFETIME: Duration = Duration::from_secs(5 * 60);
static SEQUENCE: AtomicU64 = AtomicU64::new(1);

#[derive(Default)]
pub(crate) struct UploadTable(Mutex<BTreeMap<u64, Arc<Slot>>>);

/// Registry operations never wait for file I/O. A removed slot is marked first;
/// its current worker keeps ownership until the staging inode can be removed.
struct Slot {
    owner: u64,
    expires: Instant,
    cancelled: AtomicBool,
    upload: Mutex<Option<Upload>>,
}

/// Owns one private staging inode until publication or cleanup.
struct Upload {
    file: File,
    staging: PathBuf,
    target: PathBuf,
    size: u64,
    received: u64,
    expected: String,
    mode: u32,
    hash: Sha256,
}

impl Drop for Upload {
    fn drop(&mut self) {
        if let Err(error) = fs::remove_file(&self.staging) {
            if error.kind() != std::io::ErrorKind::NotFound {
                eprintln!("remote upload cleanup failed: {:?}", error.kind());
            }
        }
    }
}

impl UploadTable {
    pub(crate) fn handle(
        &self,
        context: &Context,
        method: &str,
        params: Value,
    ) -> Result<Value, RemoteError> {
        self.expire();
        if context.closed.load(Ordering::Acquire) || context.session.is_ending() {
            return Err(not_found());
        }
        if method == methods::FS_UPLOAD_START {
            return self.start(context, parse(params)?);
        }
        let id = params
            .get("uploadId")
            .and_then(Value::as_u64)
            .ok_or_else(|| RemoteError::new(ErrorCode::InvalidRequest, "missing uploadId"))?;
        let slot = lock(&self.0)
            .get(&id)
            .cloned()
            .filter(|slot| slot.owner == context.connection)
            .ok_or_else(not_found)?;
        if method == methods::FS_UPLOAD_ABORT {
            let _: UploadParams = parse(params)?;
            self.remove(id, &slot);
            return Ok(Value::Null);
        }
        let mut state = match slot.upload.try_lock() {
            Ok(state) => state,
            Err(TryLockError::Poisoned(error)) => error.into_inner(),
            Err(TryLockError::WouldBlock) => {
                return Err(RemoteError::new(
                    ErrorCode::Busy,
                    "upload operation in progress",
                ))
            }
        };
        if slot.cancelled.load(Ordering::Acquire) {
            return Err(not_found());
        }
        let upload = state.as_mut().ok_or_else(not_found)?;
        match method {
            methods::FS_UPLOAD_CHUNK => {
                let params: UploadChunkParams = parse(params)?;
                if params.data.len() > methods::MAX_UPLOAD_CHUNK_BYTES.div_ceil(3) * 4 {
                    return Err(RemoteError::new(
                        ErrorCode::InvalidRequest,
                        "upload chunk too large",
                    ));
                }
                let bytes = methods::decode_bytes(&params.data).map_err(|_| {
                    RemoteError::new(ErrorCode::InvalidRequest, "invalid upload chunk")
                })?;
                if bytes.is_empty() || bytes.len() > methods::MAX_UPLOAD_CHUNK_BYTES {
                    return Err(RemoteError::new(
                        ErrorCode::InvalidRequest,
                        "upload chunk size is invalid",
                    ));
                }
                if params.offset != upload.received
                    || upload.received + bytes.len() as u64 > upload.size
                {
                    return Err(RemoteError::new(
                        ErrorCode::Conflict,
                        "upload offset or size mismatch",
                    ));
                }
                if let Err(error) = upload.file.write_all(&bytes) {
                    self.remove(id, &slot);
                    state.take();
                    return Err(io_error(error, "staged upload"));
                }
                upload.hash.update(&bytes);
                upload.received += bytes.len() as u64;
                Ok(json!({"offset": upload.received}))
            }
            methods::FS_UPLOAD_COMMIT => {
                let _: UploadParams = parse(params)?;
                let upload = state.take().unwrap();
                // Keep the slot discoverable during sync so disconnect/expiry
                // can mark it without waiting on the per-upload mutex.
                let result = (|| {
                    let digest = upload
                        .hash
                        .clone()
                        .finalize()
                        .iter()
                        .map(|byte| format!("{byte:02x}"))
                        .collect::<String>();
                    if upload.received != upload.size || digest != upload.expected {
                        return Err(RemoteError::new(
                            ErrorCode::Conflict,
                            "upload integrity check failed",
                        ));
                    }
                    upload
                        .file
                        .set_permissions(fs::Permissions::from_mode(upload.mode))
                        .and_then(|()| upload.file.sync_all())
                        .map_err(|error| io_error(error, "staged upload"))?;
                    if slot.cancelled.load(Ordering::Acquire)
                        || context.closed.load(Ordering::Acquire)
                        || context.session.is_ending()
                    {
                        return Err(not_found());
                    }
                    platform::rename_no_replace(&upload.staging, &upload.target)
                        .map_err(|error| io_error(error, "staged upload"))?;
                    Ok(json!({"size": upload.size, "sha256": digest}))
                })();
                self.remove(id, &slot);
                result
            }
            _ => Err(RemoteError::new(
                ErrorCode::UnknownMethod,
                "unknown upload operation",
            )),
        }
    }

    fn start(&self, context: &Context, params: UploadStartParams) -> Result<Value, RemoteError> {
        if params.size > methods::MAX_UPLOAD_BYTES
            || params.mode > 0o777
            || params.sha256.len() != 64
            || !params.sha256.bytes().all(|byte| byte.is_ascii_hexdigit())
        {
            return Err(RemoteError::new(
                ErrorCode::InvalidRequest,
                "invalid upload size, digest or mode",
            ));
        }
        let target = host_path(&params.path)?;
        let parent = target
            .parent()
            .ok_or_else(|| RemoteError::new(ErrorCode::InvalidPath, "cannot upload to the root"))?;
        let id = SEQUENCE.fetch_add(1, Ordering::Relaxed);
        let slot = Arc::new(Slot {
            owner: context.connection,
            expires: Instant::now() + LIFETIME,
            cancelled: AtomicBool::new(false),
            upload: Mutex::new(None),
        });
        {
            let mut entries = lock(&self.0);
            if context.closed.load(Ordering::Acquire) || context.session.is_ending() {
                return Err(not_found());
            }
            if entries.len() >= MAX_UPLOADS {
                return Err(RemoteError::new(ErrorCode::Busy, "too many staged uploads"));
            }
            entries.insert(id, Arc::clone(&slot));
        }
        let staging = parent.join(format!(".lithe-upload-{}-{id}", std::process::id()));
        let result = (|| {
            let file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&staging)
                .map_err(|error| io_error(error, &params.path))?;
            let upload = Upload {
                file,
                staging,
                target,
                size: params.size,
                received: 0,
                expected: params.sha256.to_ascii_lowercase(),
                mode: params.mode,
                hash: Sha256::new(),
            };
            if slot.cancelled.load(Ordering::Acquire)
                || context.closed.load(Ordering::Acquire)
                || context.session.is_ending()
            {
                return Err(not_found());
            }
            *lock(&slot.upload) = Some(upload);
            Ok(json!({"uploadId": id}))
        })();
        if result.is_err() {
            self.remove(id, &slot);
        }
        result
    }

    fn remove(&self, id: u64, slot: &Arc<Slot>) {
        slot.cancelled.store(true, Ordering::Release);
        let removed = lock(&self.0).remove(&id);
        drop(removed);
    }

    fn retain(&self, keep: impl Fn(&Slot) -> bool) {
        let removed = {
            let mut entries = lock(&self.0);
            let ids: Vec<_> = entries
                .iter()
                .filter(|(_, slot)| !keep(slot))
                .map(|(id, _)| *id)
                .collect();
            ids.into_iter()
                .filter_map(|id| {
                    let slot = entries.remove(&id)?;
                    slot.cancelled.store(true, Ordering::Release);
                    Some(slot)
                })
                .collect::<Vec<_>>()
        };
        // Closing files and removing staging names must not hold the table lock.
        drop(removed);
    }

    pub(crate) fn release(&self, owner: u64) {
        self.retain(|slot| slot.owner != owner);
    }
    pub(crate) fn expire(&self) {
        let now = Instant::now();
        self.retain(|slot| slot.expires > now);
    }
    pub(crate) fn clear(&self) {
        self.retain(|_| false);
    }
}

fn not_found() -> RemoteError {
    RemoteError::new(ErrorCode::NotFound, "staged upload not found")
}

#[cfg(test)]
mod tests;
