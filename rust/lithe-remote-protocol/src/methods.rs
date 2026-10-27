//! Method names, event names and their typed parameters.
//!
//! Paths in this protocol are absolute paths on the remote host, using the
//! host's own spelling. This is deliberate: the protocol is a filesystem and
//! process adapter, and toolchains, terminals and debuggers need real host
//! paths. Workspace-relative identifiers are built above this layer.
//!
//! Long-lived resources (processes, terminals, watches, tunnels, walks) are
//! identified by ids the *client* chooses, unique per session. A client can
//! therefore subscribe to a resource's events before creating it, and keeps
//! the same ids after reconnecting. Every event is named `<family>.<name>` and
//! carries `<family>Id`, for example `terminal.output` with `terminalId`.

use base64::Engine;
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

pub const SERVER_HELLO: &str = "server.hello";
pub const SERVER_SHUTDOWN: &str = "server.shutdown";
pub const SERVER_PING: &str = "server.ping";
pub const SERVER_STATE: &str = "server.state";
pub const SERVER_RESUME: &str = "server.resume";
pub const SERVER_ACK: &str = "server.ack";

pub const FS_STAT: &str = "fs.stat";
pub const FS_READ_DIR: &str = "fs.readDir";
pub const FS_READ_FILE: &str = "fs.readFile";
pub const FS_WRITE_FILE: &str = "fs.writeFile";
pub const FS_CREATE_DIR: &str = "fs.createDir";
pub const FS_REMOVE: &str = "fs.remove";
pub const FS_RENAME: &str = "fs.rename";
pub const FS_COPY: &str = "fs.copy";
/// Moves an entry to the host account's recoverable system trash.
pub const FS_TRASH: &str = "fs.trash";
pub const FS_REAL_PATH: &str = "fs.realPath";
pub const FS_SET_PERMISSIONS: &str = "fs.setPermissions";
pub const FS_VOLUME_INFO: &str = "fs.volumeInfo";
pub const FS_TEMP_DIRECTORY: &str = "fs.tempDirectory";
/// Connection-owned staging for large files, with verified no-replace publication.
pub const FS_UPLOAD_START: &str = "fs.uploadStart";
pub const FS_UPLOAD_CHUNK: &str = "fs.uploadChunk";
pub const FS_UPLOAD_COMMIT: &str = "fs.uploadCommit";
pub const FS_UPLOAD_ABORT: &str = "fs.uploadAbort";
/// Private runtime snapshots owned by the session, not by a live connection.
pub const FS_CREATE_RUN_DIRECTORY: &str = "fs.createRunDirectory";
pub const FS_RELEASE_RUN_DIRECTORY: &str = "fs.releaseRunDirectory";

/// Caller-generated opaque identity, known before allocation can be cancelled.
#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RunDirectoryParams {
    pub directory_id: String,
}

/// Maximum decoded chunk, independent of the full file size.
pub const MAX_UPLOAD_CHUNK_BYTES: usize = 256 * 1024;
/// Maximum staged file, matching the expanded plugin importer budget.
pub const MAX_UPLOAD_BYTES: u64 = 2 * 1024 * 1024 * 1024;

/// A new upload's destination, expected bytes, integrity and final permissions.
#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct UploadStartParams {
    pub path: String,
    pub size: u64,
    pub sha256: String,
    pub mode: u32,
}

/// One strictly ordered chunk of an existing upload.
#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct UploadChunkParams {
    pub upload_id: u64,
    pub offset: u64,
    pub data: String,
}

/// Identifies the upload being committed or aborted.
#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct UploadParams {
    pub upload_id: u64,
}

pub const WALK_START: &str = "walk.start";
pub const WALK_CANCEL: &str = "walk.cancel";

pub const WATCH_START: &str = "watch.start";
pub const WATCH_STOP: &str = "watch.stop";

pub const PROCESS_SPAWN: &str = "process.spawn";
pub const PROCESS_WRITE_STDIN: &str = "process.writeStdin";
pub const PROCESS_CLOSE_STDIN: &str = "process.closeStdin";
pub const PROCESS_KILL: &str = "process.kill";

pub const TERMINAL_OPEN: &str = "terminal.open";
pub const TERMINAL_WRITE: &str = "terminal.write";
pub const TERMINAL_RESIZE: &str = "terminal.resize";
pub const TERMINAL_CLOSE: &str = "terminal.close";

pub const ENVIRONMENT_RESOLVE: &str = "environment.resolve";

pub const TUNNEL_OPEN: &str = "tunnel.open";
pub const TUNNEL_WRITE: &str = "tunnel.write";
pub const TUNNEL_SHUTDOWN_WRITE: &str = "tunnel.shutdownWrite";
pub const TUNNEL_CLOSE: &str = "tunnel.close";
pub const PORTS_LISTENING: &str = "ports.listening";

pub const EVENT_PROCESS_OUTPUT: &str = "process.output";
pub const EVENT_PROCESS_EXIT: &str = "process.exit";
pub const EVENT_TERMINAL_OUTPUT: &str = "terminal.output";
pub const EVENT_TERMINAL_EXIT: &str = "terminal.exit";
pub const EVENT_WATCH_CHANGED: &str = "watch.changed";
pub const EVENT_WATCH_ERROR: &str = "watch.error";
pub const EVENT_WALK_ENTRIES: &str = "walk.entries";
pub const EVENT_WALK_DONE: &str = "walk.done";
pub const EVENT_TUNNEL_DATA: &str = "tunnel.data";
pub const EVENT_TUNNEL_CLOSED: &str = "tunnel.closed";

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

// ---------------------------------------------------------------------------
// Server and session
// ---------------------------------------------------------------------------

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HelloParams {
    pub protocol_version: u32,
    /// Free-form client identification for server diagnostics.
    pub client_name: String,
    /// Seconds a persistent session keeps its processes and terminals while
    /// no client is attached. Ignored by `--stdio` servers, whose session ends
    /// with the connection. The server applies the latest value it received.
    #[serde(default)]
    pub idle_timeout_seconds: Option<u64>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HelloResult {
    pub protocol_version: u32,
    pub server_version: String,
    pub host: HostCapabilities,
    pub session: SessionInfo,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionInfo {
    /// Whether the session survives disconnection (`--connect` servers).
    pub persistent: bool,
    /// Whether a client was attached to this session before. Its unseen
    /// events are delivered after `server.resume`.
    pub resumed: bool,
    /// Smallest resource id not used yet in this session.
    pub next_resource_id: u64,
    /// Sequence number of the latest event the session produced, `0` before
    /// the first one.
    pub last_event_seq: u64,
}

/// Starts event delivery to this connection. Until it is called, events are
/// kept for the connection, so a client can subscribe to the resources it
/// knows before their missed events arrive.
#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResumeParams {
    /// Last event sequence number this client received, from an earlier
    /// connection to the same session. Kept events after it are sent first.
    /// `None` sends every event still kept.
    #[serde(default)]
    pub after_seq: Option<u64>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResumeResult {
    /// Events after `afterSeq` were dropped because the session's retention
    /// limit was reached. The client must re-read state, for example call
    /// `server.state` and rescan watched trees.
    pub truncated: bool,
}

/// Confirms that the client received every event up to `seq`, which the
/// session may then forget. Clients send it periodically; it has no result.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AckParams {
    pub seq: u64,
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
    pub watch: WatchCapabilities,
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
    /// Process groups are terminated when the server shuts down or its
    /// session expires. A server killed with `SIGKILL` can leave them running
    /// (macOS).
    ServerShutdown,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WatchCapabilities {
    pub backend: WatchBackend,
    /// Upper bound of watched directories imposed by the host, when the
    /// backend watches directories individually (inotify). Large trees beyond
    /// it degrade to partial watching and report `watch.error`.
    pub directory_limit: Option<u64>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum WatchBackend {
    Inotify,
    Fsevents,
}

#[derive(Clone, Copy, Debug, Eq, Ord, PartialEq, PartialOrd, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Feature {
    /// `fs.*` methods.
    Filesystem,
    /// Bounded staged uploads with SHA-256 and atomic no-replace publication.
    Upload,
    /// Session-owned private run directories reclaimed when the session ends.
    RunDirectories,
    /// `walk.*` methods and events.
    Walk,
    /// `watch.*` methods and events.
    Watch,
    /// `process.*` methods and events.
    Process,
    /// `terminal.*` methods and events.
    Terminal,
    /// `environment.resolve`.
    Environment,
    /// `tunnel.*` and `ports.listening`.
    Tunnel,
    /// The session survives disconnection when started with `--connect`.
    Persistence,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ServerState {
    pub processes: Vec<ProcessState>,
    pub terminals: Vec<TerminalState>,
    pub watches: Vec<WatchState>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProcessState {
    pub process_id: u64,
    pub pid: u32,
    pub argv: Vec<String>,
    /// The process itself exited, but members of its session still run;
    /// `process.kill` still reaches them.
    pub leader_exited: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalState {
    pub terminal_id: u64,
    pub pid: u32,
    pub columns: u16,
    pub rows: u16,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WatchState {
    pub watch_id: u64,
    pub root: String,
}

// ---------------------------------------------------------------------------
// Filesystem
// ---------------------------------------------------------------------------

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
    /// Permission bits (`0o755` style), for executable markers and
    /// `fs.setPermissions`.
    pub mode: u32,
    /// Link target as stored in the link, when it is valid UTF-8.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub symlink_target: Option<String>,
    /// Kind of the resolved target; `None` for a dangling link.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub symlink_target_kind: Option<FileKind>,
    /// Permissions of the resolved target, never the link's own mode.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub symlink_target_mode: Option<u32>,
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
    /// POSIX permissions applied during creation, before any content is written.
    #[serde(default)]
    pub mode: Option<u32>,
}

/// Creates a private disposable directory below the host's temporary root.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TempDirectoryParams {
    /// Diagnostic name, restricted to ASCII letters, digits, `_` and `-`.
    pub prefix: String,
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

/// Copies a file, or a directory tree when `recursive` is set. Symbolic
/// links are recreated as links, never followed, so a copy cannot escape the
/// copied tree.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CopyParams {
    pub from: String,
    pub to: String,
    #[serde(default)]
    pub recursive: bool,
    #[serde(default)]
    pub overwrite: bool,
}

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CopyResult {
    /// Sockets, FIFOs and device files inside a copied tree. They are not
    /// copied: reading a FIFO can block forever and devices are not content.
    pub skipped_special_files: u64,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SetPermissionsParams {
    pub path: String,
    /// Permission bits, for example `0o755`.
    pub mode: u32,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RealPathResult {
    pub path: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct VolumeInfo {
    /// Whether names on the volume containing the path are case-sensitive.
    /// APFS is usually not; most Linux filesystems are. `None` when the
    /// server could not determine it.
    pub case_sensitive: Option<bool>,
}

// ---------------------------------------------------------------------------
// Walk
// ---------------------------------------------------------------------------

/// Streams every entry below `root` in depth-first, name-sorted order. Used
/// for file indexes and "go to file"; symbolic links are reported but not
/// followed.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WalkStartParams {
    pub walk_id: u64,
    pub root: String,
    /// Entry names that are reported but not descended into, such as
    /// `node_modules` or `target`.
    #[serde(default)]
    pub exclude_names: Vec<String>,
    /// Stops the walk after this many entries and reports `truncated`.
    #[serde(default)]
    pub max_entries: Option<u64>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WalkParams {
    pub walk_id: u64,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WalkEntry {
    /// Path relative to the walk root with `/` separators.
    pub path: String,
    pub kind: FileKind,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WalkEntriesEvent {
    pub walk_id: u64,
    pub entries: Vec<WalkEntry>,
}

/// Last event of a walk.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WalkDoneEvent {
    pub walk_id: u64,
    pub total: u64,
    pub truncated: bool,
    pub cancelled: bool,
    pub skipped_non_utf8: u64,
    /// Directories that could not be read, usually for lack of permission.
    pub unreadable_directories: u64,
}

// ---------------------------------------------------------------------------
// Watch
// ---------------------------------------------------------------------------

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WatchStartParams {
    pub watch_id: u64,
    /// Directory watched recursively.
    pub root: String,
    /// Directory names whose contents are not watched, such as `.git/objects`
    /// style noise or build output. Matched against each path component.
    #[serde(default)]
    pub exclude_names: Vec<String>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WatchStartResult {
    /// Directories registered with a per-directory backend; `None` for
    /// backends that watch whole trees.
    pub watched_directories: Option<u64>,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WatchParams {
    pub watch_id: u64,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ChangeKind {
    Created,
    Modified,
    Deleted,
}

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct FileChange {
    /// Absolute host path.
    pub path: String,
    pub kind: ChangeKind,
}

/// Coalesced changes, sorted by path. With `overflow` some changes were lost
/// and the client must rescan the watched tree.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WatchChangedEvent {
    pub watch_id: u64,
    pub changes: Vec<FileChange>,
    pub overflow: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WatchErrorEvent {
    pub watch_id: u64,
    pub code: WatchErrorCode,
    pub message: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "SCREAMING_SNAKE_CASE")]
pub enum WatchErrorCode {
    /// The host's watch limit was reached; part of the tree is unwatched.
    LimitReached,
    /// The watched root was deleted or moved; the watch has ended.
    RootRemoved,
}

// ---------------------------------------------------------------------------
// Processes
// ---------------------------------------------------------------------------

/// Base environment of a spawned process or terminal.
#[derive(Clone, Copy, Debug, Default, Eq, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum EnvironmentSource {
    /// The server's own environment, as the transport started it. Over SSH
    /// this usually lacks what login profiles add to `PATH`.
    #[default]
    Server,
    /// The user's login environment from `environment.resolve`, so tools
    /// installed through nvm, SDKMAN or Homebrew are found.
    Login,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SpawnParams {
    pub process_id: u64,
    /// Program and arguments. The program is resolved through the base
    /// environment's `PATH` when it contains no `/`.
    pub argv: Vec<String>,
    #[serde(default)]
    pub cwd: Option<String>,
    #[serde(default)]
    pub environment: EnvironmentSource,
    /// Variables added to, or replacing, the base environment.
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
    /// `SIGKILL` instead of `SIGTERM`. Either signal goes to every process
    /// of the session the process leads, including job-control groups it
    /// created, so build tools do not leave workers behind.
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

// ---------------------------------------------------------------------------
// Terminals
// ---------------------------------------------------------------------------

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalOpenParams {
    pub terminal_id: u64,
    /// Program and arguments. Defaults to the user's login shell started as
    /// a login shell, which loads the same profile files as an SSH login.
    #[serde(default)]
    pub argv: Option<Vec<String>>,
    #[serde(default)]
    pub cwd: Option<String>,
    /// Variables added to the server environment. `TERM` defaults to
    /// `xterm-256color`.
    #[serde(default)]
    pub env: BTreeMap<String, String>,
    pub columns: u16,
    pub rows: u16,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalOpenResult {
    pub pid: u32,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalWriteParams {
    pub terminal_id: u64,
    pub data: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalResizeParams {
    pub terminal_id: u64,
    pub columns: u16,
    pub rows: u16,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalParams {
    pub terminal_id: u64,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalOutputEvent {
    pub terminal_id: u64,
    pub data: String,
}

/// Sent once per terminal, after all of its output.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TerminalExitEvent {
    pub terminal_id: u64,
    pub exit_code: Option<i32>,
    pub signal: Option<i32>,
}

// ---------------------------------------------------------------------------
// Environment
// ---------------------------------------------------------------------------

#[derive(Clone, Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EnvironmentResolveParams {
    /// Re-run the login shell instead of returning the cached result, for
    /// example after the user edited a profile file.
    #[serde(default)]
    pub refresh: bool,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct EnvironmentResolveResult {
    pub environment: BTreeMap<String, String>,
    pub source: ResolvedEnvironmentSource,
    /// Why a better source was not used, for example a profile that timed out.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub diagnostics: Option<String>,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum ResolvedEnvironmentSource {
    /// An interactive login shell, which also reads files such as `.zshrc`
    /// and `.bashrc` where version managers usually add themselves.
    InteractiveLoginShell,
    /// A non-interactive login shell; interactive start-up failed.
    LoginShell,
    /// The server environment; the shell could not be used.
    Server,
}

// ---------------------------------------------------------------------------
// Tunnels and ports
// ---------------------------------------------------------------------------

/// Where a tunnel connects on the remote side.
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum TunnelTarget {
    Tcp {
        host: String,
        port: u16,
    },
    /// A Unix domain socket, such as a Docker or database socket.
    Unix {
        path: String,
    },
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TunnelOpenParams {
    pub tunnel_id: u64,
    pub target: TunnelTarget,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TunnelWriteParams {
    pub tunnel_id: u64,
    pub data: String,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TunnelParams {
    pub tunnel_id: u64,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TunnelDataEvent {
    pub tunnel_id: u64,
    pub data: String,
}

/// Last event of a tunnel. `error` explains an abnormal end.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TunnelClosedEvent {
    pub tunnel_id: u64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Clone, Debug, Eq, Ord, PartialEq, PartialOrd, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ListeningPort {
    /// Bound address as reported by the host, such as `127.0.0.1`, `::` or
    /// `0.0.0.0`.
    pub address: String,
    pub port: u16,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ListeningPortsResult {
    /// Sorted and without duplicates.
    pub ports: Vec<ListeningPort>,
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

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn tunnel_targets_are_tagged_by_kind() {
        assert_eq!(
            serde_json::to_value(TunnelTarget::Tcp {
                host: "127.0.0.1".into(),
                port: 8080
            })
            .unwrap(),
            json!({"kind": "tcp", "host": "127.0.0.1", "port": 8080})
        );
        let unix: TunnelTarget =
            serde_json::from_value(json!({"kind": "unix", "path": "/var/run/docker.sock"}))
                .unwrap();
        assert_eq!(
            unix,
            TunnelTarget::Unix {
                path: "/var/run/docker.sock".into()
            }
        );
    }
}
