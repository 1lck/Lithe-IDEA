//! Streams a native source file to verified host staging without enlarging frames.
//! The caller owns package trust; this adapter owns transfer integrity and cleanup.

use super::sessions::{lookup, request_error};
use super::workspace_host::request_cancellable;
use crate::protocol::{cancellation, CoreError, ErrorCode};
use lithe_remote_protocol::methods;
use serde::Deserialize;
use serde_json::{json, Value};
use std::io::Read;
use std::path::Path;
use std::time::Duration;

const STEP: Duration = Duration::from_secs(30);

/// Native upload source and host destination, plus caller-verified expected hash.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Request {
    session_id: String,
    source_path: String,
    path: String,
    sha256: String,
    mode: u32,
}

/// Uses handshake facts without running another shell or using the local platform.
pub(crate) fn host_info(session_id: &str) -> Result<Value, CoreError> {
    let connection = lookup(session_id)?;
    serde_json::to_value(&connection.session.hello().host).map_err(|error| {
        CoreError::new(ErrorCode::ParseFailed, "Invalid host capabilities")
            .with_details(error.to_string())
    })
}

/// Uploads one bounded file; any failure aborts its connection-owned staging inode.
pub(crate) fn upload(request: Request) -> Result<Value, CoreError> {
    cancellation::check()?;
    if !Path::new(&request.source_path).is_absolute() {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Upload source must be absolute",
        ));
    }
    let mut source = std::fs::File::open(&request.source_path).map_err(source_error)?;
    let metadata = source.metadata().map_err(source_error)?;
    if !metadata.is_file() || metadata.len() > methods::MAX_UPLOAD_BYTES {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Upload source is not a bounded regular file",
        ));
    }
    let connection = lookup(&request.session_id)?;
    if !connection
        .session
        .hello()
        .host
        .features
        .contains(&methods::Feature::Upload)
    {
        return Err(CoreError::new(
            ErrorCode::NotSupported,
            "The host does not support staged uploads",
        ));
    }
    let call = |method: &str, params: Value| {
        cancellation::check()?;
        request_cancellable(&connection.session, method, params, STEP)
            .map_err(|error| request_error(&request.session_id, error))
    };
    let started = call(
        methods::FS_UPLOAD_START,
        json!({"path": request.path, "size": metadata.len(), "sha256": request.sha256, "mode": request.mode}),
    )?;
    let id = started["uploadId"]
        .as_u64()
        .ok_or_else(|| CoreError::new(ErrorCode::ParseFailed, "Missing upload identity"))?;
    let result = (|| {
        let mut buffer = vec![0; methods::MAX_UPLOAD_CHUNK_BYTES];
        let mut offset = 0;
        loop {
            cancellation::check()?;
            let count = source.read(&mut buffer).map_err(source_error)?;
            if count == 0 {
                break;
            }
            if offset + count as u64 > metadata.len() {
                return Err(CoreError::new(
                    ErrorCode::InvalidRequest,
                    "Upload source changed",
                ));
            }
            let received = call(
                methods::FS_UPLOAD_CHUNK,
                json!({"uploadId": id, "offset": offset, "data": methods::encode_bytes(&buffer[..count])}),
            )?;
            offset += count as u64;
            if received["offset"].as_u64() != Some(offset) {
                return Err(CoreError::new(
                    ErrorCode::ParseFailed,
                    "Unexpected upload acknowledgement",
                ));
            }
        }
        if offset != metadata.len() {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "Upload source changed",
            ));
        }
        let committed = call(methods::FS_UPLOAD_COMMIT, json!({"uploadId": id}))?;
        if committed["size"].as_u64() != Some(offset)
            || committed["sha256"].as_str() != Some(request.sha256.to_ascii_lowercase().as_str())
        {
            return Err(CoreError::new(
                ErrorCode::ParseFailed,
                "Invalid upload receipt",
            ));
        }
        Ok(committed)
    })();
    if result.is_err() {
        // Cleanup must run even when the parent Core operation is cancelled.
        if let Err(error) = connection.session.request_value(
            methods::FS_UPLOAD_ABORT,
            json!({"uploadId": id}),
            Duration::from_secs(2),
        ) {
            if !matches!(&error, lithe_remote_client::session::ClientError::Remote(remote)
                if remote.code == lithe_remote_protocol::ErrorCode::NotFound)
            {
                eprintln!("remote upload abort failed; connection staging will expire");
            }
        }
    }
    result
}

fn source_error(error: std::io::Error) -> CoreError {
    CoreError::new(ErrorCode::Unknown, "Could not read upload source")
        .with_details(error.kind().to_string())
}
