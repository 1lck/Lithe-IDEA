//! Filesystem operations on the remote host.
//!
//! The server acts with the remote user's own permissions, exactly like the
//! shell the user could open over the same transport. It therefore does not
//! confine paths to the workspace; the client decides which paths it shows.

use crate::{parse, platform, to_value};
use lithe_remote_protocol::methods::{
    self, decode_bytes, encode_bytes, CreateDirParams, DirectoryEntry, FileKind, FileMetadata,
    PathParams, ReadDirResult, ReadFileParams, ReadFileResult, RemoveParams, RenameParams,
    VolumeInfo, WriteFileParams, MAX_TRANSFER_BYTES,
};
use lithe_remote_protocol::{ErrorCode, RemoteError};
use serde_json::{json, Value};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::UNIX_EPOCH;

static TEMPORARY_FILE_COUNTER: AtomicU64 = AtomicU64::new(0);

pub(crate) fn handle(method: &str, params: Value) -> Result<Value, RemoteError> {
    match method {
        methods::FS_STAT => {
            let params: PathParams = parse(params)?;
            to_value(stat(&host_path(&params.path)?, &params.path)?)
        }
        methods::FS_READ_DIR => to_value(read_dir(parse(params)?)?),
        methods::FS_READ_FILE => to_value(read_file(parse(params)?)?),
        methods::FS_WRITE_FILE => to_value(write_file(parse(params)?)?),
        methods::FS_CREATE_DIR => create_dir(parse(params)?).map(|()| Value::Null),
        methods::FS_REMOVE => remove(parse(params)?).map(|()| Value::Null),
        methods::FS_RENAME => rename(parse(params)?).map(|()| Value::Null),
        methods::FS_VOLUME_INFO => {
            let params: PathParams = parse(params)?;
            let path = host_path(&params.path)?;
            to_value(VolumeInfo {
                case_sensitive: platform::case_sensitive(&path),
            })
        }
        _ => Err(RemoteError::new(
            ErrorCode::UnknownMethod,
            format!("unknown method {method}"),
        )),
    }
}

/// Accepts only absolute paths. A relative path would resolve against the
/// server's working directory, which depends on how the transport started it.
fn host_path(path: &str) -> Result<PathBuf, RemoteError> {
    if !path.starts_with('/') || path.contains('\0') {
        return Err(
            RemoteError::new(ErrorCode::InvalidPath, "paths must be absolute host paths")
                .with_details(json!({ "path": path })),
        );
    }
    Ok(PathBuf::from(path))
}

fn stat(path: &Path, shown: &str) -> Result<FileMetadata, RemoteError> {
    let metadata = fs::symlink_metadata(path).map_err(|error| io_error(error, shown))?;
    Ok(describe(path, &metadata))
}

fn describe(path: &Path, metadata: &fs::Metadata) -> FileMetadata {
    let kind = kind_of(&metadata.file_type());
    let (symlink_target, symlink_target_kind) = if kind == FileKind::Symlink {
        (
            fs::read_link(path)
                .ok()
                .and_then(|target| target.into_os_string().into_string().ok()),
            fs::metadata(path)
                .ok()
                .map(|target| kind_of(&target.file_type())),
        )
    } else {
        (None, None)
    };
    FileMetadata {
        kind,
        size: metadata.len(),
        modified_ms: metadata
            .modified()
            .ok()
            .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
            .and_then(|duration| i64::try_from(duration.as_millis()).ok()),
        readonly: metadata.permissions().readonly(),
        symlink_target,
        symlink_target_kind,
    }
}

fn kind_of(file_type: &fs::FileType) -> FileKind {
    if file_type.is_symlink() {
        FileKind::Symlink
    } else if file_type.is_dir() {
        FileKind::Directory
    } else if file_type.is_file() {
        FileKind::File
    } else {
        FileKind::Other
    }
}

fn read_dir(params: PathParams) -> Result<ReadDirResult, RemoteError> {
    let path = host_path(&params.path)?;
    let listing = fs::read_dir(&path).map_err(|error| io_error(error, &params.path))?;
    let mut entries = Vec::new();
    let mut skipped_non_utf8 = 0;
    for entry in listing {
        let entry = entry.map_err(|error| io_error(error, &params.path))?;
        let Ok(name) = entry.file_name().into_string() else {
            skipped_non_utf8 += 1;
            continue;
        };
        // An entry deleted between listing and stat no longer exists, so it
        // is omitted like any other entry created or deleted after the call.
        let Ok(metadata) = fs::symlink_metadata(entry.path()) else {
            continue;
        };
        entries.push(DirectoryEntry {
            metadata: describe(&entry.path(), &metadata),
            name,
        });
    }
    entries.sort_by(|left, right| left.name.cmp(&right.name));
    Ok(ReadDirResult {
        entries,
        skipped_non_utf8,
    })
}

fn read_file(params: ReadFileParams) -> Result<ReadFileResult, RemoteError> {
    if params.length > MAX_TRANSFER_BYTES {
        return Err(too_large(params.length));
    }
    let path = host_path(&params.path)?;
    let mut file = File::open(&path).map_err(|error| io_error(error, &params.path))?;
    let metadata = file
        .metadata()
        .map_err(|error| io_error(error, &params.path))?;
    if metadata.is_dir() {
        return Err(RemoteError::new(
            ErrorCode::IsADirectory,
            "cannot read a directory",
        ));
    }
    file.seek(SeekFrom::Start(params.offset))
        .map_err(|error| io_error(error, &params.path))?;
    let mut data = Vec::new();
    file.take(params.length)
        .read_to_end(&mut data)
        .map_err(|error| io_error(error, &params.path))?;
    let eof = params.offset.saturating_add(data.len() as u64) >= metadata.len();
    Ok(ReadFileResult {
        data: encode_bytes(&data),
        eof,
        metadata: describe(&path, &metadata),
    })
}

/// Replaces a file atomically: the content goes to a temporary sibling that
/// is renamed over the target, so readers and crashes never observe a
/// partially written file. Symbolic links are written through, keeping the
/// link itself intact. The rename gives the file a new inode, which breaks
/// hard links, the same trade-off other editors' safe-write mode makes.
fn write_file(params: WriteFileParams) -> Result<FileMetadata, RemoteError> {
    let data = decode_bytes(&params.data)
        .map_err(|error| RemoteError::new(ErrorCode::InvalidRequest, error.to_string()))?;
    if data.len() as u64 > MAX_TRANSFER_BYTES {
        return Err(too_large(data.len() as u64));
    }
    let requested = host_path(&params.path)?;
    let target = match fs::symlink_metadata(&requested) {
        Ok(metadata) if metadata.file_type().is_symlink() => {
            fs::canonicalize(&requested).map_err(|error| io_error(error, &params.path))?
        }
        _ => requested,
    };
    let current = match fs::metadata(&target) {
        Ok(metadata) => Some(metadata),
        Err(error) if error.kind() == io::ErrorKind::NotFound => None,
        Err(error) => return Err(io_error(error, &params.path)),
    };
    if let Some(metadata) = &current {
        if metadata.is_dir() {
            return Err(RemoteError::new(
                ErrorCode::IsADirectory,
                "cannot replace a directory with a file",
            ));
        }
    }
    match (&params.expected, &current) {
        (Some(expected), Some(metadata)) => {
            let found = describe(&target, metadata);
            if found.size != expected.size || found.modified_ms != expected.modified_ms {
                return Err(RemoteError::new(
                    ErrorCode::Conflict,
                    "the file changed since it was read",
                )
                .with_details(json!({ "size": found.size, "modifiedMs": found.modified_ms })));
            }
        }
        (Some(_), None) => {
            return Err(RemoteError::new(
                ErrorCode::Conflict,
                "the file was deleted since it was read",
            ))
        }
        (None, Some(_)) if !params.overwrite => {
            return Err(RemoteError::new(
                ErrorCode::AlreadyExists,
                "the file already exists",
            ))
        }
        _ => {}
    }

    let parent = target
        .parent()
        .ok_or_else(|| RemoteError::new(ErrorCode::InvalidPath, "cannot write the root"))?;
    if params.create_parents {
        fs::create_dir_all(parent).map_err(|error| io_error(error, &params.path))?;
    }
    let name = target
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_default();
    let temporary = parent.join(format!(
        ".{name}.lithe-{}-{}.tmp",
        std::process::id(),
        TEMPORARY_FILE_COUNTER.fetch_add(1, Ordering::Relaxed)
    ));
    let written = write_temporary(&temporary, &data, current.as_ref())
        .and_then(|()| fs::rename(&temporary, &target));
    if let Err(error) = written {
        let _ = fs::remove_file(&temporary);
        return Err(io_error(error, &params.path));
    }
    stat(&target, &params.path)
}

fn write_temporary(path: &Path, data: &[u8], replaced: Option<&fs::Metadata>) -> io::Result<()> {
    let mut file = OpenOptions::new().write(true).create_new(true).open(path)?;
    file.write_all(data)?;
    if let Some(metadata) = replaced {
        file.set_permissions(metadata.permissions())?;
    }
    file.sync_all()
}

fn create_dir(params: CreateDirParams) -> Result<(), RemoteError> {
    let path = host_path(&params.path)?;
    let created = if params.recursive {
        fs::create_dir_all(&path)
    } else {
        fs::create_dir(&path)
    };
    created.map_err(|error| io_error(error, &params.path))
}

fn remove(params: RemoveParams) -> Result<(), RemoteError> {
    let path = host_path(&params.path)?;
    let metadata = fs::symlink_metadata(&path).map_err(|error| io_error(error, &params.path))?;
    // `symlink_metadata` keeps a link to a directory classified as a link, so
    // removal deletes the link and never the directory it points to.
    let removed = if metadata.is_dir() {
        if params.recursive {
            fs::remove_dir_all(&path)
        } else {
            fs::remove_dir(&path)
        }
    } else {
        fs::remove_file(&path)
    };
    removed.map_err(|error| io_error(error, &params.path))
}

fn rename(params: RenameParams) -> Result<(), RemoteError> {
    let from = host_path(&params.from)?;
    let to = host_path(&params.to)?;
    let renamed = if params.overwrite {
        fs::rename(&from, &to)
    } else {
        platform::rename_no_replace(&from, &to)
    };
    renamed.map_err(|error| io_error(error, &params.from))
}

fn too_large(length: u64) -> RemoteError {
    RemoteError::new(
        ErrorCode::TooLarge,
        format!("{length} bytes exceed the {MAX_TRANSFER_BYTES}-byte transfer limit"),
    )
}

pub(crate) fn io_error(error: io::Error, path: &str) -> RemoteError {
    let code = match error.kind() {
        io::ErrorKind::NotFound => ErrorCode::NotFound,
        io::ErrorKind::PermissionDenied => ErrorCode::PermissionDenied,
        io::ErrorKind::AlreadyExists => ErrorCode::AlreadyExists,
        io::ErrorKind::NotADirectory => ErrorCode::NotADirectory,
        io::ErrorKind::IsADirectory => ErrorCode::IsADirectory,
        io::ErrorKind::DirectoryNotEmpty => ErrorCode::DirectoryNotEmpty,
        _ => ErrorCode::Io,
    };
    RemoteError::new(code, error.to_string())
        .with_details(json!({ "path": path, "osError": error.raw_os_error() }))
}
