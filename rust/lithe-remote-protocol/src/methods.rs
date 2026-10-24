//! Method names, event names and their typed parameters.
//!
//! Paths in this protocol are absolute paths on the remote host, using the
//! host's own spelling. This is deliberate: the protocol is a filesystem and
//! process adapter, and toolchains, terminals and debuggers need real host
//! paths. Workspace-relative identifiers are built above this layer.

use base64::Engine;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

pub const SERVER_HELLO: &str = "server.hello";
pub const SERVER_SHUTDOWN: &str = "server.shutdown";
pub const FS_STAT: &str = "fs.stat";
pub const FS_READ_DIR: &str = "fs.readDir";
pub const FS_READ_FILE: &str = "fs.readFile";
pub const FS_WRITE_FILE: &str = "fs.writeFile";
pub const FS_CREATE_DIR: &str = "fs.createDir";
pub const FS_REMOVE: &str = "fs.remove";
pub const FS_RENAME: &str = "fs.rename";
pub const FS_VOLUME_INFO: &str = "fs.volumeInfo";
pub const PROCESS_SPAWN: &str = "process.spawn";
pub const PROCESS_WRITE_STDIN: &str = "process.writeStdin";
pub const PROCESS_CLOSE_STDIN: &str = "process.closeStdin";
pub const PROCESS_KILL: &str = "process.kill";

pub const EVENT_PROCESS_OUTPUT: &str = "process.output";
pub const EVENT_PROCESS_EXIT: &str = "process.exit";

/// Largest byte count one `fs.readFile` or `fs.writeFile` call may move.
/// Base64 inflates it by a third, which keeps the frame under
/// [`crate::MAX_FRAME_BYTES`].
pub const MAX_TRANSFER_BYTES: u64 = 8 * 1024 * 1024;

/// Encodes bytes for a JSON `data` field.
pub fn encode_bytes(bytes: &[u8]) -> String {
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

/// Decodes a JSON `data` field.
pub fn decode_bytes(data: &str) -> Result<Vec<u8>, base64::DecodeError> {
    base64::engine::general_purpose::STANDARD.decode(data)
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HelloParams {
    pub protocol_version: u32,
    /// Free-form client identification for server diagnostics.
    pub client_name: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HelloResult {
    pub protocol_version: u32,
    pub server_version: String,
    pub host: HostCapabilities,
}

/// Facts about the remote host that clients must use instead of assuming a
/// platform. A client never branches on "is this macOS"; it reads the
/// capability that the behavior actually depends on.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HostCapabilities {
    pub os: OperatingSystem,
    /// Normalized CPU architecture of the running server: `x86_64` or
    /// `aarch64`.
    pub arch: String,
    pub host_name: String,
    pub user_name: Option<String>,
    pub home_directory: Option<String>,
    /// Login shell of the remote user, used for terminals and for resolving
    /// the user's environment.
    pub default_shell: Option<String>,
    /// Separator used by host paths. Always `/` for current hosts; carried so
    /// that clients do not hard-code it.
    pub path_separator: String,
    pub process: ProcessCapabilities,
    /// Optional method groups this server implements, sorted.
    pub features: Vec<Feature>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum OperatingSystem {
    Linux,
    Macos,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProcessCapabilities {
    pub orphan_protection: OrphanProtection,
}

/// What stops spawned processes from outliving the server.
#[derive(Clone, Copy, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum OrphanProtection {
    /// The kernel kills each process group leader when the server dies, even
    /// if the server is killed without a chance to clean up (Linux).
    ParentDeathSignal,
    /// Process groups are terminated when the server shuts down or loses its
    /// client. A server killed with `SIGKILL` can leave them running (macOS).
    ServerShutdown,
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Feature {
    /// `fs.*` methods.
    Filesystem,
    /// `process.*` methods and events.
    Process,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PathParams {
    pub path: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum FileKind {
    File,
    Directory,
    Symlink,
    /// Sockets, devices and FIFOs.
    Other,
}

/// Metadata of the path itself; symbolic links are not followed.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileMetadata {
    pub kind: FileKind,
    pub size: u64,
    /// Modification time in milliseconds since the Unix epoch. Milliseconds
    /// stay exact in JavaScript numbers, which a future TypeScript client
    /// relies on.
    pub modified_ms: Option<i64>,
    pub readonly: bool,
    /// Link target as stored in the link, when it is valid UTF-8.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub symlink_target: Option<String>,
    /// Kind of the resolved target; `None` for a dangling link.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub symlink_target_kind: Option<FileKind>,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DirectoryEntry {
    pub name: String,
    pub metadata: FileMetadata,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReadDirResult {
    /// Sorted by the byte order of `name`.
    pub entries: Vec<DirectoryEntry>,
    /// Entries whose names are not valid UTF-8. They cannot be addressed
    /// through this protocol version, so they are counted rather than
    /// silently dropped.
    pub skipped_non_utf8: u32,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReadFileParams {
    pub path: String,
    #[serde(default)]
    pub offset: u64,
    /// Requested byte count; at most [`MAX_TRANSFER_BYTES`].
    pub length: u64,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReadFileResult {
    /// Base64 bytes starting at the requested offset.
    pub data: String,
    /// Whether the read reached the end of the file.
    pub eof: bool,
    pub metadata: FileMetadata,
}

/// Identity of the content a client last read, used to reject a write that
/// would overwrite someone else's change.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileVersion {
    pub size: u64,
    pub modified_ms: Option<i64>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WriteFileParams {
    pub path: String,
    /// Base64 content that replaces the whole file.
    pub data: String,
    /// When present, the write fails with `CONFLICT` unless the current file
    /// matches it. When absent, the file must not exist yet unless
    /// `overwrite` is set.
    #[serde(default)]
    pub expected: Option<FileVersion>,
    #[serde(default)]
    pub overwrite: bool,
    #[serde(default)]
    pub create_parents: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CreateDirParams {
    pub path: String,
    #[serde(default)]
    pub recursive: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RemoveParams {
    pub path: String,
    #[serde(default)]
    pub recursive: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RenameParams {
    pub from: String,
    pub to: String,
    #[serde(default)]
    pub overwrite: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct VolumeInfo {
    /// Whether names on the volume containing the path are case-sensitive.
    /// APFS is usually not; most Linux filesystems are. `None` when the
    /// server could not determine it.
    pub case_sensitive: Option<bool>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SpawnParams {
    /// Program and arguments. The program is resolved through the server's
    /// `PATH` when it contains no `/`.
    pub argv: Vec<String>,
    #[serde(default)]
    pub cwd: Option<String>,
    /// Variables added to, or replacing, the server's environment.
    #[serde(default)]
    pub env: BTreeMap<String, String>,
    /// Keep standard input open for `process.writeStdin`. Otherwise the
    /// process reads end-of-file immediately.
    #[serde(default)]
    pub pipe_stdin: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SpawnResult {
    /// Server-assigned id used by every later process call and event.
    pub process_id: u64,
    /// Operating-system pid, for diagnostics only.
    pub pid: u32,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WriteStdinParams {
    pub process_id: u64,
    pub data: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProcessParams {
    pub process_id: u64,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct KillParams {
    pub process_id: u64,
    /// `SIGKILL` instead of `SIGTERM`. Either signal goes to the whole
    /// process group, so build tools do not leave workers behind.
    #[serde(default)]
    pub force: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum OutputStream {
    Stdout,
    Stderr,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProcessOutputEvent {
    pub process_id: u64,
    pub stream: OutputStream,
    pub data: String,
}

/// Sent once per process, after all of its output events.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProcessExitEvent {
    pub process_id: u64,
    pub exit_code: Option<i32>,
    /// Terminating signal number when the process did not exit normally.
    pub signal: Option<i32>,
}

/// Output of `lithe-remote-server --identity`, used by the bootstrapper to
/// decide whether an installed binary can be reused.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ServerIdentity {
    pub server_version: String,
    pub protocol_version: u32,
    /// Lower-case hex SHA-256 of the executable file itself.
    pub sha256: String,
}
