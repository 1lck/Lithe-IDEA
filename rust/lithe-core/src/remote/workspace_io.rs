//! Filesystem adapter for workspace engines, with no local fallback on remote errors.

use super::workspace::{self, Host};
use lithe_remote::client::session::ClientError;
use lithe_remote::protocol::{methods, ErrorCode};
use serde::de::DeserializeOwned;
use serde_json::{json, Value};
use std::io::{self, Read};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

// Materialized workspace reads share the editor's 32 MiB budget. Streaming
// consumers (for example snapshot hashing) can still read larger files.
const MAX_READ_BYTES: u64 = 32 * 1024 * 1024;

fn rpc<T: DeserializeOwned>(host: &Host, method: &str, params: Value) -> io::Result<T> {
    crate::protocol::cancellation::check().map_err(|error| io::Error::other(error.message))?;
    let result = super::workspace_host::request_cancellable(
        &host.connection.session,
        method,
        params,
        Duration::from_secs(30),
    );
    crate::protocol::cancellation::check()
        .map_err(|error| io::Error::new(io::ErrorKind::Interrupted, error.message))?;
    let value = result.map_err(|error| {
        let kind = match &error {
            ClientError::Remote(error) => match error.code {
                ErrorCode::NotFound => io::ErrorKind::NotFound,
                ErrorCode::AlreadyExists => io::ErrorKind::AlreadyExists,
                ErrorCode::PermissionDenied => io::ErrorKind::PermissionDenied,
                ErrorCode::NotADirectory => io::ErrorKind::NotADirectory,
                ErrorCode::Conflict => io::ErrorKind::WouldBlock,
                _ => io::ErrorKind::Other,
            },
            ClientError::Timeout => io::ErrorKind::TimedOut,
            _ => io::ErrorKind::ConnectionAborted,
        };
        io::Error::new(kind, error)
    })?;
    serde_json::from_value(value).map_err(io::Error::other)
}

/// Whether a remote workspace operation failed because the link was cancelled,
/// timed out or dropped, rather than describing one path. Keep in step with the
/// kinds assigned in `rpc`. Callers that tolerate unreadable paths must still
/// stop on these, or a dead connection looks like a smaller project. Always
/// false for local workspaces, where such kinds describe the path itself.
pub(crate) fn is_transport_failure(error: &io::Error) -> bool {
    workspace::is_remote()
        && matches!(
            error.kind(),
            io::ErrorKind::Interrupted | io::ErrorKind::TimedOut | io::ErrorKind::ConnectionAborted
        )
}

fn path(host: &Host, path: &Path) -> io::Result<String> {
    host.remote_path(path)
        .to_str()
        .map(str::to_owned)
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "Remote paths must be UTF-8"))
}

/// Metadata retaining the host's file kind and permissions.
pub(crate) struct Metadata {
    kind: methods::FileKind,
    size: u64,
    mode: u32,
    modified: Option<SystemTime>,
}
impl Metadata {
    /// Size in bytes as reported by the owning filesystem.
    pub(crate) fn len(&self) -> u64 {
        self.size
    }
    /// Whether the entry itself is a regular file.
    pub(crate) fn is_file(&self) -> bool {
        self.kind == methods::FileKind::File
    }
    /// Whether the entry itself is a directory.
    pub(crate) fn is_dir(&self) -> bool {
        self.kind == methods::FileKind::Directory
    }
    /// Kind of the entry itself, without following symbolic links.
    pub(crate) fn file_type(&self) -> FileType {
        FileType(self.kind)
    }
    /// POSIX mode used by guarded Git snapshots.
    pub(crate) fn mode(&self) -> u32 {
        self.mode
    }
    /// Host modification time; absent timestamps are not treated as fresh output.
    pub(crate) fn modified(&self) -> io::Result<SystemTime> {
        self.modified.ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::Unsupported,
                "Modification time is unavailable",
            )
        })
    }
}

/// Filesystem entry kind independent of the client operating system.
pub(crate) struct FileType(methods::FileKind);
impl FileType {
    /// Whether the entry is a regular file, without following links.
    pub(crate) fn is_file(&self) -> bool {
        self.0 == methods::FileKind::File
    }
    /// Whether the entry is a directory, without following links.
    pub(crate) fn is_dir(&self) -> bool {
        self.0 == methods::FileKind::Directory
    }
    /// Whether the entry is a symbolic link.
    pub(crate) fn is_symlink(&self) -> bool {
        self.0 == methods::FileKind::Symlink
    }
}

fn native_metadata(metadata: std::fs::Metadata) -> Metadata {
    let kind = if metadata.is_dir() {
        methods::FileKind::Directory
    } else if metadata.is_file() {
        methods::FileKind::File
    } else if metadata.is_symlink() {
        methods::FileKind::Symlink
    } else {
        methods::FileKind::Other
    };
    #[cfg(unix)]
    let mode = {
        use std::os::unix::fs::PermissionsExt;
        metadata.permissions().mode()
    };
    #[cfg(not(unix))]
    let mode = 0;
    Metadata {
        kind,
        size: metadata.len(),
        mode,
        modified: metadata.modified().ok(),
    }
}

fn remote_metadata(metadata: methods::FileMetadata) -> Metadata {
    Metadata {
        kind: metadata.kind,
        size: metadata.size,
        mode: metadata.mode,
        modified: metadata.modified_ms.and_then(|millis| {
            let offset = Duration::from_millis(millis.unsigned_abs());
            if millis >= 0 {
                UNIX_EPOCH.checked_add(offset)
            } else {
                UNIX_EPOCH.checked_sub(offset)
            }
        }),
    }
}

/// Reads metadata of the entry itself on the workspace host.
pub(crate) fn symlink_metadata(path_value: impl AsRef<Path>) -> io::Result<Metadata> {
    let path_value = path_value.as_ref();
    match workspace::current() {
        Some(host) => rpc::<methods::FileMetadata>(
            &host,
            methods::FS_STAT,
            json!({"path": path(&host, path_value)?}),
        )
        .map(remote_metadata),
        None => std::fs::symlink_metadata(path_value).map(native_metadata),
    }
}

/// Reads target metadata, resolving symbolic links on the owning host.
pub(crate) fn metadata(path_value: impl AsRef<Path>) -> io::Result<Metadata> {
    if workspace::is_remote() {
        let value = symlink_metadata(path_value.as_ref())?;
        if value.file_type().is_symlink() {
            return symlink_metadata(canonicalize(path_value)?);
        }
        Ok(value)
    } else {
        std::fs::metadata(path_value).map(native_metadata)
    }
}

/// Tests existence without treating host failures as a missing path.
pub(crate) fn try_exists(path_value: impl AsRef<Path>) -> io::Result<bool> {
    match metadata(path_value) {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error),
    }
}
/// Tests whether a path is a directory without suppressing host failures.
pub(crate) fn is_dir(path_value: impl AsRef<Path>) -> io::Result<bool> {
    match metadata(path_value) {
        Ok(value) => Ok(value.is_dir()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error),
    }
}
/// Tests whether a path is a regular file on its owning filesystem.
pub(crate) fn is_file(path_value: impl AsRef<Path>) -> io::Result<bool> {
    match metadata(path_value) {
        Ok(value) => Ok(value.is_file()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error),
    }
}

/// Resolves links while preserving the native workspace URL identity.
pub(crate) fn canonicalize(path_value: impl AsRef<Path>) -> io::Result<PathBuf> {
    let path_value = path_value.as_ref();
    match workspace::current() {
        Some(host) => {
            let result: methods::RealPathResult = rpc(
                &host,
                methods::FS_REAL_PATH,
                json!({"path": path(&host, path_value)?}),
            )?;
            Ok(host.local_path(Path::new(&result.path)))
        }
        None => path_value.canonicalize(),
    }
}

/// Reads a link's stored target without resolving it.
pub(crate) fn read_link(path_value: impl AsRef<Path>) -> io::Result<PathBuf> {
    match workspace::current() {
        Some(host) => {
            let metadata: methods::FileMetadata = rpc(
                &host,
                methods::FS_STAT,
                json!({"path": path(&host, path_value.as_ref())?}),
            )?;
            metadata.symlink_target.map(PathBuf::from).ok_or_else(|| {
                io::Error::new(
                    io::ErrorKind::InvalidInput,
                    "Path is not a readable symbolic link",
                )
            })
        }
        None => std::fs::read_link(path_value),
    }
}

/// Streaming file reader; remote reads use bounded chunks rather than mirroring a file.
pub(crate) struct File(FileReader);
enum FileReader {
    Local(std::fs::File),
    Remote {
        host: Host,
        path: String,
        metadata: Metadata,
        offset: u64,
        /// Version captured by the first read, not a separate path stat.
        version: Option<methods::FileVersion>,
        eof: bool,
    },
}
impl File {
    /// Opens a regular file on its owning host.
    pub(crate) fn open(path_value: impl AsRef<Path>) -> io::Result<Self> {
        match workspace::current() {
            Some(host) => {
                let metadata = metadata(path_value.as_ref())?;
                if !metadata.is_file() {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidInput,
                        "Expected a regular file",
                    ));
                }
                let path = path(&host, path_value.as_ref())?;
                Ok(Self(FileReader::Remote {
                    host,
                    path,
                    metadata,
                    offset: 0,
                    version: None,
                    eof: false,
                }))
            }
            None => std::fs::File::open(path_value).map(|file| Self(FileReader::Local(file))),
        }
    }
    /// Metadata of this opened file, without a separate native filesystem lookup.
    pub(crate) fn metadata(&self) -> io::Result<Metadata> {
        match &self.0 {
            FileReader::Local(file) => file.metadata().map(native_metadata),
            FileReader::Remote { metadata, .. } => Ok(Metadata {
                kind: metadata.kind,
                size: metadata.size,
                mode: metadata.mode,
                modified: metadata.modified,
            }),
        }
    }
}
impl Read for File {
    fn read(&mut self, buffer: &mut [u8]) -> io::Result<usize> {
        match &mut self.0 {
            FileReader::Local(file) => file.read(buffer),
            FileReader::Remote {
                host,
                path,
                offset,
                version,
                eof,
                ..
            } => {
                if buffer.is_empty() || *eof {
                    return Ok(0);
                }
                let result: methods::ReadFileResult = rpc(
                    host,
                    methods::FS_READ_FILE,
                    json!({"path": path, "offset": offset, "length": buffer.len().min(1024 * 1024)}),
                )?;
                let observed = methods::FileVersion {
                    size: result.metadata.size,
                    modified_ms: result.metadata.modified_ms,
                };
                if version.as_ref().is_some_and(|first| *first != observed) {
                    return Err(io::Error::new(
                        io::ErrorKind::WouldBlock,
                        "Remote file changed while being read",
                    ));
                }
                let bytes = methods::decode_bytes(&result.data).map_err(io::Error::other)?;
                let next_offset = offset.checked_add(bytes.len() as u64).ok_or_else(|| {
                    io::Error::new(io::ErrorKind::InvalidData, "Invalid remote read offset")
                })?;
                if bytes.len() > buffer.len().min(1024 * 1024)
                    || next_offset > observed.size
                    || result.eof != (next_offset == observed.size)
                    || (bytes.is_empty() && !result.eof)
                {
                    return Err(io::Error::new(
                        io::ErrorKind::InvalidData,
                        "Invalid remote read size",
                    ));
                }
                *version = Some(observed);
                *eof = result.eof;
                buffer[..bytes.len()].copy_from_slice(&bytes);
                *offset = next_offset;
                Ok(bytes.len())
            }
        }
    }
}

/// Reads file bytes through the selected host adapter.
pub(crate) fn read(path_value: impl AsRef<Path>) -> io::Result<Vec<u8>> {
    let path_value = path_value.as_ref();
    if !workspace::is_remote() {
        return std::fs::read(path_value);
    }
    if metadata(path_value)?.len() > MAX_READ_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Remote file exceeds the 32 MiB read limit",
        ));
    }
    let mut bytes = Vec::new();
    // The second bound also covers growth after the metadata request.
    File::open(path_value)?
        .take(MAX_READ_BYTES + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() as u64 > MAX_READ_BYTES {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "Remote file exceeds the 32 MiB read limit",
        ));
    }
    Ok(bytes)
}
/// Reads UTF-8 text through the selected host adapter.
pub(crate) fn read_to_string(path_value: impl AsRef<Path>) -> io::Result<String> {
    String::from_utf8(read(path_value)?)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
}
/// Atomically replaces remote content; local behavior retains standard filesystem semantics.
pub(crate) fn write(path_value: impl AsRef<Path>, bytes: impl AsRef<[u8]>) -> io::Result<()> {
    match workspace::current() {
        Some(host) => {
            check_write_size(bytes.as_ref().len() as u64)?;
            rpc::<Value>(
                &host,
                methods::FS_WRITE_FILE,
                json!({"path": path(&host, path_value.as_ref())?,
            "data": methods::encode_bytes(bytes.as_ref()), "overwrite": true}),
            )
            .map(|_| ())
        }
        None => std::fs::write(path_value, bytes),
    }
}
/// Writes and synchronizes a session record before publishing its manifest.
pub(crate) fn write_synced(path_value: &Path, bytes: &[u8]) -> io::Result<()> {
    if workspace::is_remote() {
        return write(path_value, bytes);
    }
    use std::io::Write;
    let mut file = std::fs::OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .open(path_value)?;
    file.write_all(bytes)?;
    file.sync_all()
}
/// Appends ignore rules, rejecting remote changes since the read used for this append.
pub(crate) fn append(path_value: &Path, bytes: &[u8]) -> io::Result<()> {
    match workspace::current() {
        Some(host) => {
            let remote = path(&host, path_value)?;
            let previous: Option<methods::FileMetadata> =
                match rpc(&host, methods::FS_STAT, json!({"path": remote})) {
                    Ok(value) => Some(value),
                    Err(error) if error.kind() == io::ErrorKind::NotFound => None,
                    Err(error) => return Err(error),
                };
            let mut content = if let Some(previous) = &previous {
                check_write_size(previous.size.saturating_add(bytes.len() as u64))?;
                read(path_value)?
            } else {
                Vec::new()
            };
            content.extend_from_slice(bytes);
            check_write_size(content.len() as u64)?;
            rpc::<Value>(&host, methods::FS_WRITE_FILE, json!({"path": remote, "data": methods::encode_bytes(&content),
                "expected": previous.map(|value| methods::FileVersion { size: value.size, modified_ms: value.modified_ms })})).map(|_| ())
        }
        None => {
            use std::io::Write;
            std::fs::OpenOptions::new()
                .create(true)
                .append(true)
                .open(path_value)?
                .write_all(bytes)
        }
    }
}

fn check_write_size(length: u64) -> io::Result<()> {
    if length > methods::MAX_TRANSFER_BYTES {
        Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "Remote file exceeds the 8 MiB atomic write limit",
        ))
    } else {
        Ok(())
    }
}

/// Creates one directory with optional permissions applied at creation.
pub(crate) fn create_dir_mode(
    path_value: &Path,
    recursive: bool,
    mode: Option<u32>,
) -> io::Result<()> {
    match workspace::current() {
        Some(host) => rpc::<Value>(
            &host,
            methods::FS_CREATE_DIR,
            json!({"path": path(&host, path_value)?, "recursive": recursive, "mode": mode}),
        )
        .map(|_| ()),
        None => {
            let mut builder = std::fs::DirBuilder::new();
            builder.recursive(recursive);
            #[cfg(unix)]
            if let Some(mode) = mode {
                use std::os::unix::fs::DirBuilderExt;
                builder.mode(mode);
            }
            builder.create(path_value)
        }
    }
}
/// Creates a directory without recursively creating parents.
pub(crate) fn create_dir(path_value: impl AsRef<Path>) -> io::Result<()> {
    create_dir_mode(path_value.as_ref(), false, None)
}
/// Creates a directory and any missing parents.
pub(crate) fn create_dir_all(path_value: impl AsRef<Path>) -> io::Result<()> {
    create_dir_mode(path_value.as_ref(), true, None)
}
/// Removes a disposable directory tree from its owning host.
pub(crate) fn remove_dir_all(path_value: impl AsRef<Path>) -> io::Result<()> {
    match workspace::current() {
        Some(host) => rpc::<Value>(
            &host,
            methods::FS_REMOVE,
            json!({"path": path(&host, path_value.as_ref())?, "recursive": true}),
        )
        .map(|_| ()),
        None => std::fs::remove_dir_all(path_value),
    }
}

/// Deletes owned scratch state even after the user cancels its operation.
pub(crate) fn cleanup_directory(path_value: &Path) {
    let result = if let Some(host) = workspace::current() {
        path(&host, path_value).and_then(|path| {
            host.connection
                .session
                .request_value(
                    methods::FS_REMOVE,
                    json!({"path": path, "recursive": true}),
                    Duration::from_secs(2),
                )
                .map(|_| ())
                .map_err(|error| {
                    let kind = match &error {
                        ClientError::Remote(remote) if remote.code == ErrorCode::NotFound => {
                            io::ErrorKind::NotFound
                        }
                        _ => io::ErrorKind::Other,
                    };
                    io::Error::new(kind, error)
                })
        })
    } else {
        std::fs::remove_dir_all(path_value)
    };
    if let Err(error) = result {
        if error.kind() != io::ErrorKind::NotFound {
            // Scratch names can identify user paths; log only the error category.
            eprintln!(
                "Could not clean workspace scratch directory: {:?}",
                error.kind()
            );
        }
    }
}
/// Renames a file on its owning host, replacing an existing target.
pub(crate) fn rename(from: impl AsRef<Path>, to: impl AsRef<Path>) -> io::Result<()> {
    match workspace::current() {
        Some(host) => rpc::<Value>(&host, methods::FS_RENAME, json!({"from": path(&host, from.as_ref())?, "to": path(&host, to.as_ref())?, "overwrite": true})).map(|_| ()),
        None => std::fs::rename(from, to),
    }
}
/// Copies a file on the host without transferring its content through the client.
pub(crate) fn copy(from: impl AsRef<Path>, to: impl AsRef<Path>) -> io::Result<u64> {
    match workspace::current() {
        Some(host) => {
            rpc::<Value>(
                &host,
                methods::FS_COPY,
                json!({"from": path(&host, from.as_ref())?, "to": path(&host, to.as_ref())?, "overwrite": true}),
            )?;
            Ok(metadata(to)?.len())
        }
        None => std::fs::copy(from, to),
    }
}

/// Directory entry preserving the client's workspace path identity.
pub(crate) struct DirEntry {
    path: PathBuf,
    kind: methods::FileKind,
}
impl DirEntry {
    /// Name of this entry, without its parent path.
    pub(crate) fn file_name(&self) -> std::ffi::OsString {
        self.path.file_name().unwrap_or_default().to_owned()
    }
    /// Entry path in native workspace identity.
    pub(crate) fn path(&self) -> PathBuf {
        self.path.clone()
    }
    /// File type, without following symbolic links.
    pub(crate) fn file_type(&self) -> io::Result<FileType> {
        Ok(FileType(self.kind))
    }
}
/// Lists a directory through the selected workspace adapter.
pub(crate) fn read_dir(
    path_value: impl AsRef<Path>,
) -> io::Result<std::vec::IntoIter<io::Result<DirEntry>>> {
    let path_value = path_value.as_ref();
    match workspace::current() {
        Some(host) => {
            let result: methods::ReadDirResult = rpc(
                &host,
                methods::FS_READ_DIR,
                json!({"path": path(&host, path_value)?}),
            )?;
            if result.skipped_non_utf8 != 0 {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidData,
                    "Remote directory has unsupported non-UTF-8 names",
                ));
            }
            Ok(result
                .entries
                .into_iter()
                .map(|entry| {
                    Ok(DirEntry {
                        path: path_value.join(entry.name),
                        kind: entry.metadata.kind,
                    })
                })
                .collect::<Vec<_>>()
                .into_iter())
        }
        None => Ok(std::fs::read_dir(path_value)?
            .map(|entry| {
                let entry = entry?;
                let metadata = native_metadata(std::fs::symlink_metadata(entry.path())?);
                Ok(DirEntry {
                    path: entry.path(),
                    kind: metadata.kind,
                })
            })
            .collect::<Vec<_>>()
            .into_iter()),
    }
}

/// Allocates a private host scratch directory; its caller owns deletion.
pub(crate) fn remote_temp_directory(prefix: &str) -> io::Result<Option<PathBuf>> {
    workspace::current()
        .map(|host| {
            rpc::<methods::RealPathResult>(
                &host,
                methods::FS_TEMP_DIRECTORY,
                json!({"prefix": prefix}),
            )
            .map(|value| PathBuf::from(value.path))
        })
        .transpose()
}
