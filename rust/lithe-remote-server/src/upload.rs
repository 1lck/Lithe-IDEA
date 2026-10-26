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
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

const MAX_UPLOADS: usize = 4;
const LIFETIME: Duration = Duration::from_secs(5 * 60);
static SEQUENCE: AtomicU64 = AtomicU64::new(1);

#[derive(Default)]
pub(crate) struct UploadTable(Mutex<BTreeMap<u64, Upload>>);

/// Owns one private staging inode until publication or cleanup.
struct Upload {
    owner: u64,
    file: File,
    staging: PathBuf,
    target: PathBuf,
    size: u64,
    received: u64,
    expected: String,
    mode: u32,
    hash: Sha256,
    expires: Instant,
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
        let mut uploads = lock(&self.0);
        if context.closed.load(Ordering::Acquire) {
            return Err(RemoteError::new(
                ErrorCode::NotFound,
                "upload connection closed",
            ));
        }
        uploads.retain(|_, upload| upload.expires > Instant::now());
        if method == methods::FS_UPLOAD_START {
            let params: UploadStartParams = parse(params)?;
            if uploads.len() >= MAX_UPLOADS {
                return Err(RemoteError::new(ErrorCode::Busy, "too many staged uploads"));
            }
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
            let parent = target.parent().ok_or_else(|| {
                RemoteError::new(ErrorCode::InvalidPath, "cannot upload to the root")
            })?;
            let id = SEQUENCE.fetch_add(1, Ordering::Relaxed);
            let staging = parent.join(format!(".lithe-upload-{}-{id}", std::process::id()));
            let file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(&staging)
                .map_err(|error| io_error(error, &params.path))?;
            uploads.insert(
                id,
                Upload {
                    owner: context.connection,
                    file,
                    staging,
                    target,
                    size: params.size,
                    received: 0,
                    expected: params.sha256.to_ascii_lowercase(),
                    mode: params.mode,
                    hash: Sha256::new(),
                    expires: Instant::now() + LIFETIME,
                },
            );
            return Ok(json!({"uploadId": id}));
        }
        let id = params
            .get("uploadId")
            .and_then(Value::as_u64)
            .ok_or_else(|| RemoteError::new(ErrorCode::InvalidRequest, "missing uploadId"))?;
        if uploads
            .get(&id)
            .is_none_or(|upload| upload.owner != context.connection)
        {
            return Err(RemoteError::new(
                ErrorCode::NotFound,
                "staged upload not found",
            ));
        }
        match method {
            methods::FS_UPLOAD_CHUNK => {
                let params: UploadChunkParams = parse(params)?;
                let upload = uploads.get_mut(&id).unwrap();
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
                    uploads.remove(&id);
                    return Err(io_error(error, "staged upload"));
                }
                upload.hash.update(&bytes);
                upload.received += bytes.len() as u64;
                Ok(json!({"offset": upload.received}))
            }
            methods::FS_UPLOAD_ABORT => {
                let _: UploadParams = parse(params)?;
                uploads.remove(&id);
                Ok(Value::Null)
            }
            methods::FS_UPLOAD_COMMIT => {
                let _: UploadParams = parse(params)?;
                let upload = uploads.remove(&id).unwrap();
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
                    .and_then(|()| platform::rename_no_replace(&upload.staging, &upload.target))
                    .map_err(|error| io_error(error, "staged upload"))?;
                Ok(json!({"size": upload.size, "sha256": digest}))
            }
            _ => Err(RemoteError::new(
                ErrorCode::UnknownMethod,
                "unknown upload operation",
            )),
        }
    }

    pub(crate) fn release(&self, owner: u64) {
        lock(&self.0).retain(|_, upload| upload.owner != owner);
    }
    pub(crate) fn expire(&self) {
        lock(&self.0).retain(|_, upload| upload.expires > Instant::now());
    }
    pub(crate) fn clear(&self) {
        lock(&self.0).clear();
    }
}
