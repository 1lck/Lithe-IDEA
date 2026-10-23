//! User-owned shared text and guarded, per-Agent synchronization of a marked block.
//! The platform supplies its writable application-support directory; opening the
//! page is read-only. No prompt injection, package writes or background sync occurs.

use super::*;
use fs2::FileExt;

const BEGIN: &str = "<!-- LITHE:SHARED-INSTRUCTIONS:BEGIN -->";
const END: &str = "<!-- LITHE:SHARED-INSTRUCTIONS:END -->";
const AGENTS: [&str; 2] = ["codex-acp", "claude-acp"];

/// Platform-selected storage plus an explicit read, text save or Agent switch.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Request {
    pub data_directory: PathBuf,
    #[serde(flatten)]
    pub action: Action,
}

/// Writes always name the source revision and the native snapshots being changed.
#[derive(Deserialize)]
#[serde(tag = "action", rename_all = "camelCase", deny_unknown_fields)]
pub enum Action {
    Read {},
    Save {
        content: String,
        #[serde(rename = "expectedRevision")]
        expected_revision: String,
        files: Vec<FileGuard>,
    },
    SetEnabled {
        #[serde(rename = "agentId")]
        agent_id: String,
        enabled: bool,
        #[serde(rename = "expectedRevision")]
        expected_revision: String,
        file: FileGuard,
    },
}

/// A native path is only a snapshot guard; destinations are resolved by the host.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct FileGuard {
    pub agent_id: String,
    pub path: PathBuf,
    pub revision: String,
}

/// Enabled state comes from actual file bytes, never from a persisted switch value.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentState {
    pub agent_id: String,
    pub file: Option<InstructionFile>,
    pub enabled: Option<bool>,
    pub needs_sync: bool,
    pub own_line_count: usize,
    pub issue: Option<String>,
}

/// A text save can succeed while one Agent fails; every failure stays visible.
#[derive(Serialize)]
pub struct Library {
    pub file: InstructionFile,
    pub agents: Vec<AgentState>,
}

/// Execute a bounded operation. Cancellation is observed between native writes;
/// completed file replacements remain committed and are reported by the next read.
pub fn execute(
    request: Request,
    cancelled: &impl Fn() -> bool,
) -> Result<Library, InstructionError> {
    if !request.data_directory.is_absolute() {
        return Err(error(
            "profile_relative",
            "The shared instruction directory must be absolute.",
        ));
    }
    execute_in(request, &profile, cancelled, &SAVE_LOCK)
}

fn execute_in(
    request: Request,
    resolve: &impl Fn(&str) -> Result<PathBuf, InstructionError>,
    cancelled: &impl Fn() -> bool,
    write_lock: &Mutex<()>,
) -> Result<Library, InstructionError> {
    let path = request.data_directory.join("Shared.md");
    if matches!(request.action, Action::Read {}) {
        return library(snapshot("shared", path)?, resolve);
    }
    let _guard = write_lock
        .try_lock()
        .map_err(|_| error("busy", "Another instruction save is running. Try again."))?;
    let before = snapshot("shared", path.clone())?;
    let expected = match &request.action {
        Action::Save {
            expected_revision, ..
        }
        | Action::SetEnabled {
            expected_revision, ..
        } => expected_revision,
        Action::Read {} => unreachable!(),
    };
    if &before.revision != expected {
        return Err(error(
            "file_changed",
            "Shared instructions changed outside this editor. Reload before saving.",
        ));
    }
    // One nonblocking OS lock protects separate Lithe processes sharing this library.
    // Its persistent empty file is user state, never a transferable build resource.
    match &request.action {
        Action::Save { content, files, .. } => {
            validate_text(content)?;
            let ids: std::collections::HashSet<_> =
                files.iter().map(|file| file.agent_id.as_str()).collect();
            if files.len() > AGENTS.len()
                || ids.len() != files.len()
                || ids.iter().any(|id| !AGENTS.contains(id))
            {
                return Err(error(
                    "invalid_request",
                    "Invalid shared instruction request.",
                ));
            }
        }
        Action::SetEnabled { agent_id, file, .. }
            if !AGENTS.contains(&agent_id.as_str()) || file.agent_id != *agent_id =>
        {
            return Err(error(
                "unsupported_agent",
                "Global instructions are available for Codex and Claude Code.",
            ));
        }
        _ => {}
    }
    if cancelled() {
        return Err(error(
            "cancelled",
            "Instruction synchronization was cancelled.",
        ));
    }
    let mut directories = fs::DirBuilder::new();
    directories.recursive(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::DirBuilderExt;
        directories.mode(0o700);
    }
    directories
        .create(&request.data_directory)
        .map_err(io_error)?;
    let lock_path = request.data_directory.join(".sync.lock");
    let mut options = OpenOptions::new();
    options.read(true).write(true).create(true).truncate(false);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.custom_flags(0x00200000); // FILE_FLAG_OPEN_REPARSE_POINT
    }
    let lock = options.open(lock_path).map_err(io_error)?;
    let kind = lock.metadata().map_err(io_error)?.file_type();
    if !kind.is_file() || kind.is_symlink() {
        return Err(error(
            "unsafe_file",
            "The instruction path must be a regular file, not a symbolic link or directory.",
        ));
    }
    lock.try_lock_exclusive()
        .map_err(|_| error("busy", "Another instruction save is running. Try again."))?;
    if snapshot("shared", path.clone())?.revision != before.revision {
        return Err(error(
            "file_changed",
            "Shared instructions changed outside this editor. Reload before saving.",
        ));
    }
    let mut failures = Vec::new();
    match request.action {
        Action::Save { content, files, .. } => {
            validate_text(&content)?;
            if files.len() > AGENTS.len() {
                return Err(error(
                    "invalid_request",
                    "Invalid shared instruction request.",
                ));
            }
            write_snapshot(&before, &content, || snapshot("shared", path.clone()))?;
            // Commit the source first. Failed targets retain their old block and
            // expose needsSync; retrying is explicit and does not lose user text.
            for agent in AGENTS {
                let result = (|| {
                    if cancelled() {
                        return Err(error(
                            "cancelled",
                            "Instruction synchronization was cancelled.",
                        ));
                    }
                    let directory = resolve(agent)?;
                    let current = read_in(agent, &directory)?;
                    if block(&current.content)?.is_none() {
                        return Ok(());
                    }
                    let guard = files
                        .iter()
                        .find(|file| file.agent_id == agent)
                        .ok_or_else(|| {
                            error(
                                "file_changed",
                                "Reload this Agent before synchronizing instructions.",
                            )
                        })?;
                    sync(&current, guard, Some(&content), &directory)
                })();
                if let Err(err) = result {
                    failures.push((agent.to_string(), err.message.to_string()));
                }
            }
        }
        Action::SetEnabled {
            agent_id,
            enabled,
            file,
            ..
        } => {
            if !AGENTS.contains(&agent_id.as_str()) || file.agent_id != agent_id {
                return Err(error(
                    "unsupported_agent",
                    "Global instructions are available for Codex and Claude Code.",
                ));
            }
            if cancelled() {
                return Err(error(
                    "cancelled",
                    "Instruction synchronization was cancelled.",
                ));
            }
            let directory = resolve(&agent_id)?;
            let current = read_in(&agent_id, &directory)?;
            sync(
                &current,
                &file,
                enabled.then_some(before.content.as_str()),
                &directory,
            )?;
        }
        Action::Read {} => unreachable!(),
    }
    let mut result = library(snapshot("shared", path)?, resolve)?;
    for (agent, message) in failures {
        if let Some(state) = result
            .agents
            .iter_mut()
            .find(|state| state.agent_id == agent)
        {
            state.issue = Some(message);
        }
    }
    Ok(result)
}

fn library(
    file: InstructionFile,
    resolve: &impl Fn(&str) -> Result<PathBuf, InstructionError>,
) -> Result<Library, InstructionError> {
    let agents = AGENTS
        .iter()
        .map(|agent| {
            let result = resolve(agent).and_then(|directory| read_in(agent, &directory));
            match result {
                Ok(native) => match block(&native.content) {
                    Ok(managed) => {
                        let own = without_block(&native.content, managed.as_ref());
                        AgentState {
                            agent_id: (*agent).into(),
                            enabled: Some(managed.is_some()),
                            needs_sync: managed
                                .as_ref()
                                .is_some_and(|block| block.text != file.content),
                            own_line_count: own
                                .lines()
                                .filter(|line| !line.trim().is_empty())
                                .count(),
                            file: Some(native),
                            issue: None,
                        }
                    }
                    Err(err) => AgentState {
                        agent_id: (*agent).into(),
                        file: Some(native),
                        enabled: None,
                        needs_sync: false,
                        own_line_count: 0,
                        issue: Some(err.message.into()),
                    },
                },
                Err(err) => AgentState {
                    agent_id: (*agent).into(),
                    file: None,
                    enabled: None,
                    needs_sync: false,
                    own_line_count: 0,
                    issue: Some(err.message.into()),
                },
            }
        })
        .collect();
    Ok(Library { file, agents })
}

fn sync(
    current: &InstructionFile,
    guard: &FileGuard,
    text: Option<&str>,
    directory: &Path,
) -> Result<(), InstructionError> {
    let request = SaveRequest {
        agent_id: current.agent_id.clone(),
        content: String::new(),
        expected_path: guard.path.clone(),
        expected_revision: guard.revision.clone(),
    };
    check_revision(current, &request)?;
    let managed = block(&current.content)?;
    if let Some(text) = text {
        validate_text(text)?;
    }
    let replacement = text
        .map(|text| format!("\n{BEGIN}\n{text}\n{END}\n"))
        .unwrap_or_default();
    let content = if let Some(managed) = managed {
        format!(
            "{}{}{}",
            &current.content[..managed.start],
            replacement,
            &current.content[managed.end..]
        )
    } else {
        format!("{}{}", current.content, replacement)
    };
    if content == current.content {
        return Ok(());
    }
    save_unlocked(SaveRequest { content, ..request }, directory)?;
    Ok(())
}

struct Block<'a> {
    start: usize,
    end: usize,
    text: &'a str,
}

fn block(content: &str) -> Result<Option<Block<'_>>, InstructionError> {
    let opens = content.matches(BEGIN).count();
    let closes = content.matches(END).count();
    if opens == 0 && closes == 0 {
        return Ok(None);
    }
    let invalid = || {
        error("invalid_markers", "The Lithe shared instruction markers were changed. Repair the native file before syncing.")
    };
    if opens != 1 || closes != 1 {
        return Err(invalid());
    }
    // Include our own leading/trailing newline in the range. Removing a block
    // restores the exact original bytes, even when the user file had no newline.
    let open = format!("\n{BEGIN}\n");
    let close = format!("\n{END}\n");
    let start = content.find(&open).ok_or_else(invalid)?;
    let text_start = start + open.len();
    let close_start = content[text_start..]
        .find(&close)
        .map(|index| text_start + index)
        .ok_or_else(invalid)?;
    Ok(Some(Block {
        start,
        end: close_start + close.len(),
        text: &content[text_start..close_start],
    }))
}

fn without_block(content: &str, managed: Option<&Block<'_>>) -> String {
    managed
        .map(|block| format!("{}{}", &content[..block.start], &content[block.end..]))
        .unwrap_or_else(|| content.into())
}

fn validate_text(content: &str) -> Result<(), InstructionError> {
    if content.len() > MAX_BYTES {
        return Err(error(
            "file_too_large",
            "Global instructions must be no larger than 1 MiB.",
        ));
    }
    if content.contains(BEGIN) || content.contains(END) {
        return Err(error(
            "invalid_markers",
            "Shared instructions cannot contain Lithe synchronization markers.",
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests;
