//! Native global instruction files. The upstream Agent owns prompt loading;
//! this adapter only resolves, reads and atomically saves the user's file.

use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

pub mod shared;

const MAX_BYTES: usize = 1024 * 1024;
static SAVE_LOCK: Mutex<()> = Mutex::new(());

/// Native user file snapshot; paths are display/write guards, not arbitrary inputs.
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct InstructionFile {
    pub agent_id: String,
    pub path: PathBuf,
    pub content: String,
    pub exists: bool,
    /// Digest includes absence, so creating an empty file invalidates an old draft.
    pub revision: String,
}

/// A save must match both the selected native file and its previously read bytes.
#[derive(Clone, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct SaveRequest {
    pub agent_id: String,
    pub content: String,
    pub expected_path: PathBuf,
    pub expected_revision: String,
}

/// Stable instruction-specific reason, carried in the Core envelope's details.
#[derive(Debug)]
pub struct InstructionError {
    pub reason: &'static str,
    pub message: &'static str,
}

fn error(reason: &'static str, message: &'static str) -> InstructionError {
    InstructionError { reason, message }
}

fn io_error(_: std::io::Error) -> InstructionError {
    error(
        "file_access",
        "Cannot access the global instruction file. Check its permissions and try again.",
    )
}

/// Resolve the same environment-based profile inherited by native Agent launches.
pub fn read(agent_id: &str) -> Result<InstructionFile, InstructionError> {
    read_in(agent_id, &profile(agent_id)?)
}

/// Save user text without modifying repository instructions or Agent configuration.
pub fn save(request: SaveRequest) -> Result<InstructionFile, InstructionError> {
    let directory = profile(&request.agent_id)?;
    save_in(request, &directory)
}

// Resolution stays outside Core and never derives a destination from packaged resources.
fn profile(agent_id: &str) -> Result<PathBuf, InstructionError> {
    let (variable, fallback) = match agent_id {
        "codex-acp" => ("CODEX_HOME", ".codex"),
        "claude-acp" => ("CLAUDE_CONFIG_DIR", ".claude"),
        _ => {
            return Err(error(
                "unsupported_agent",
                "Global instructions are available for Codex and Claude Code.",
            ))
        }
    };
    resolve_profile(
        std::env::var_os(variable).map(PathBuf::from),
        user_home().map(|home| home.join(fallback)),
    )
}

fn user_home() -> Option<PathBuf> {
    let variable = if cfg!(windows) { "USERPROFILE" } else { "HOME" };
    std::env::var_os(variable)
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
}

fn resolve_profile(
    configured: Option<PathBuf>,
    fallback: Option<PathBuf>,
) -> Result<PathBuf, InstructionError> {
    let path = configured
        .filter(|path| !path.as_os_str().is_empty())
        .or(fallback)
        .ok_or_else(|| error("profile_missing", "Cannot locate the Agent user directory."))?;
    if !path.is_absolute() {
        return Err(error("profile_relative", "The Agent user directory must be an absolute path. Check CODEX_HOME or CLAUDE_CONFIG_DIR."));
    }
    Ok(path)
}

fn read_in(agent_id: &str, directory: &Path) -> Result<InstructionFile, InstructionError> {
    let filename = match agent_id {
        "codex-acp" => {
            let override_file = snapshot(agent_id, directory.join("AGENTS.override.md"))?;
            if !override_file.content.trim().is_empty() {
                return Ok(override_file);
            }
            "AGENTS.md"
        }
        "claude-acp" => "CLAUDE.md",
        _ => {
            return Err(error(
                "unsupported_agent",
                "Global instructions are available for Codex and Claude Code.",
            ))
        }
    };
    snapshot(agent_id, directory.join(filename))
}

fn snapshot(agent_id: &str, path: PathBuf) -> Result<InstructionFile, InstructionError> {
    let metadata = match fs::symlink_metadata(&path) {
        Ok(metadata) => Some(metadata),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
        Err(error) => return Err(io_error(error)),
    };
    if metadata
        .as_ref()
        .is_some_and(|metadata| !metadata.file_type().is_file())
    {
        return Err(error(
            "unsafe_file",
            "The instruction path must be a regular file, not a symbolic link or directory.",
        ));
    }
    let mut bytes = Vec::new();
    if metadata.is_some() {
        open_regular(&path)?
            .take(MAX_BYTES as u64 + 1)
            .read_to_end(&mut bytes)
            .map_err(io_error)?;
    }
    if bytes.len() > MAX_BYTES {
        return Err(error(
            "file_too_large",
            "Global instructions must be no larger than 1 MiB.",
        ));
    }
    let content = String::from_utf8(bytes).map_err(|_| {
        error(
            "invalid_utf8",
            "The global instruction file must use UTF-8 encoding.",
        )
    })?;
    let exists = metadata.is_some();
    let revision = format!(
        "{:x}",
        Sha256::digest([&[u8::from(exists)][..], content.as_bytes()].concat())
    );
    Ok(InstructionFile {
        agent_id: agent_id.into(),
        path,
        content,
        exists,
        revision,
    })
}

fn open_regular(path: &Path) -> Result<File, InstructionError> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        // Do not follow a replacement symlink or block on a replacement FIFO.
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.custom_flags(0x00200000); // FILE_FLAG_OPEN_REPARSE_POINT
    }
    let file = options.open(path).map_err(io_error)?;
    let kind = file.metadata().map_err(io_error)?.file_type();
    if !kind.is_file() || kind.is_symlink() {
        return Err(error(
            "unsafe_file",
            "The instruction path must be a regular file, not a symbolic link or directory.",
        ));
    }
    Ok(file)
}

fn save_in(request: SaveRequest, directory: &Path) -> Result<InstructionFile, InstructionError> {
    let _guard = SAVE_LOCK
        .try_lock()
        .map_err(|_| error("busy", "Another instruction save is running. Try again."))?;
    save_unlocked(request, directory)
}

fn save_unlocked(
    request: SaveRequest,
    directory: &Path,
) -> Result<InstructionFile, InstructionError> {
    if request.content.len() > MAX_BYTES {
        return Err(error(
            "file_too_large",
            "Global instructions must be no larger than 1 MiB.",
        ));
    }
    let previous = read_in(&request.agent_id, directory)?;
    check_revision(&previous, &request)?;
    write_snapshot(&previous, &request.content, || {
        read_in(&request.agent_id, directory)
    })?;
    // Clearing an override can make AGENTS.md effective again. Return that actual source.
    read_in(&request.agent_id, directory)
}

// Both the shared library and native files use the same guarded atomic replacement.
// The caller holds SAVE_LOCK; the recheck also protects native precedence changes.
fn write_snapshot(
    previous: &InstructionFile,
    content: &str,
    recheck: impl Fn() -> Result<InstructionFile, InstructionError>,
) -> Result<(), InstructionError> {
    if content.len() > MAX_BYTES {
        return Err(error(
            "file_too_large",
            "Global instructions must be no larger than 1 MiB.",
        ));
    }
    let directory = previous
        .path
        .parent()
        .ok_or_else(|| io_error(std::io::Error::other("missing parent")))?;
    let permissions = if previous.exists {
        let permissions = fs::metadata(&previous.path)
            .map_err(io_error)?
            .permissions();
        if permissions.readonly() {
            return Err(error(
                "file_access",
                "Cannot access the global instruction file. Check its permissions and try again.",
            ));
        }
        Some(permissions)
    } else {
        None
    };
    let mut directories = fs::DirBuilder::new();
    directories.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        directories.mode(0o700);
    }
    directories.create(directory).map_err(io_error)?;
    let parent = fs::canonicalize(directory).map_err(io_error)?;
    let stage_path = parent.join(format!(".lithe-instructions-{}.tmp", uuid::Uuid::new_v4()));
    let stage = StagedFile(stage_path.clone());
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(&stage_path).map_err(io_error)?;
    file.write_all(content.as_bytes()).map_err(io_error)?;
    if let Some(permissions) = permissions {
        file.set_permissions(permissions).map_err(io_error)?;
    }
    file.sync_all().map_err(io_error)?;
    drop(file);
    // Detect edits/profile precedence changes made while preparing the write.
    // Other applications do not share our lock, so this is an optimistic guard.
    check_revision(
        &recheck()?,
        &SaveRequest {
            agent_id: previous.agent_id.clone(),
            content: String::new(),
            expected_path: previous.path.clone(),
            expected_revision: previous.revision.clone(),
        },
    )?;
    if fs::canonicalize(directory).map_err(io_error)? != parent {
        return Err(error(
            "file_changed",
            "The instruction directory changed. Reload before saving.",
        ));
    }
    let target = parent.join(
        previous
            .path
            .file_name()
            .expect("native instruction filename"),
    );
    fs::rename(&stage.0, target).map_err(io_error)?;
    Ok(())
}

fn check_revision(file: &InstructionFile, request: &SaveRequest) -> Result<(), InstructionError> {
    if file.path != request.expected_path || file.revision != request.expected_revision {
        return Err(error("file_changed", "Global instructions changed outside this editor. Your draft is kept; reload before saving."));
    }
    Ok(())
}

struct StagedFile(PathBuf);
impl Drop for StagedFile {
    fn drop(&mut self) {
        let _ = fs::remove_file(&self.0);
    }
}

#[cfg(test)]
mod tests;
