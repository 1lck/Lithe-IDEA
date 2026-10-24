//! User-owned Hook library and explicit synchronization into native Agent files.
//! Agent runtimes own execution, JSON stdin, timeouts and trust. This adapter
//! never executes commands or grants trust, and preserves native group positions.

mod storage;
#[cfg(test)]
mod tests;

use crate::instructions::{self, InstructionFile};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::Mutex;

const AGENTS: [&str; 2] = ["codex-acp", "claude-acp"];
static WRITE_LOCK: Mutex<()> = Mutex::new(());

/// Portable lifecycle events implemented by both supported native runtimes.
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "kebab-case")]
pub enum Event {
    TurnEnd,
    AfterTool,
    BeforeTool,
    Prompt,
    SessionStart,
}

impl Event {
    fn native(self) -> &'static str {
        match self {
            Self::TurnEnd => "Stop",
            Self::AfterTool => "PostToolUse",
            Self::BeforeTool => "PreToolUse",
            Self::Prompt => "UserPromptSubmit",
            Self::SessionStart => "SessionStart",
        }
    }
}

/// Portable tool families; upstream tool names remain provider-specific.
#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum Matcher {
    #[default]
    All,
    Shell,
    Edit,
}

/// One user-authored command. Names/descriptions stay in the library only.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Hook {
    pub id: String,
    pub name: String,
    pub description: String,
    pub event: Event,
    pub matcher: Matcher,
    pub command: String,
    /// None inherits the Agent's own timeout; supplied values are seconds.
    pub timeout_seconds: Option<u64>,
    pub agents: Vec<String>,
    pub enabled: bool,
    /// A failed native removal retains a visible, retryable library entry.
    #[serde(default)]
    pub pending_removal: bool,
}

/// Guard against external edits and changes to the native profile directory.
#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct FileGuard {
    pub agent_id: String,
    pub path: PathBuf,
    pub revision: String,
}

/// Native file metadata; configuration contents may contain secrets and stay private.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Target {
    pub agent_id: String,
    pub file: Option<FileGuard>,
    pub issue: Option<String>,
    pub disabled: bool,
}

/// Actual native placement is independent of the library's desired state.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HookView {
    #[serde(flatten)]
    pub hook: Hook,
    pub configured_agents: Vec<String>,
    pub needs_sync: bool,
}

/// Read-only snapshot used to guard the next explicit operation.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Library {
    pub revision: String,
    pub hooks: Vec<HookView>,
    pub targets: Vec<Target>,
}

/// Platform-owned writable directory and one explicit library operation.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Request {
    pub data_directory: PathBuf,
    #[serde(flatten)]
    pub action: Action,
}

/// Mutations always carry the source and native snapshots the user reviewed.
#[derive(Deserialize)]
#[serde(tag = "action", rename_all = "camelCase", deny_unknown_fields)]
pub enum Action {
    Read {},
    Save {
        hook: Hook,
        #[serde(rename = "expectedRevision")]
        expected_revision: String,
        files: Vec<FileGuard>,
    },
    Remove {
        id: String,
        #[serde(rename = "expectedRevision")]
        expected_revision: String,
        files: Vec<FileGuard>,
    },
    Sync {
        #[serde(rename = "expectedRevision")]
        expected_revision: String,
        files: Vec<FileGuard>,
    },
}

/// Stable reason and credential-free diagnostic for Core's shared error envelope.
#[derive(Debug)]
pub struct Error {
    pub reason: &'static str,
    pub message: &'static str,
}

fn error(reason: &'static str, message: &'static str) -> Error {
    Error { reason, message }
}

/// Execute without running any Hook command or modifying native trust settings.
pub fn execute(request: Request, cancelled: &impl Fn() -> bool) -> Result<Library, Error> {
    execute_in(request, &instructions::profile, cancelled, &WRITE_LOCK)
}

#[derive(Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Stored {
    hooks: Vec<Hook>,
    /// Includes planned placements until native replacement is confirmed. A
    /// crash between source/native commits therefore never loses write ownership.
    placements: Vec<Placement>,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Placement {
    id: String,
    agent_id: String,
    path: PathBuf,
    event: String,
    index: usize,
    entry: Value,
}

type Resolver<'a> = dyn Fn(&str) -> Result<PathBuf, instructions::InstructionError> + 'a;

fn execute_in(
    request: Request,
    resolve: &Resolver<'_>,
    cancelled: &impl Fn() -> bool,
    write_lock: &Mutex<()>,
) -> Result<Library, Error> {
    if !request.data_directory.is_absolute() {
        return Err(error(
            "invalid_request",
            "The Hook library directory must be absolute.",
        ));
    }
    check_cancelled(cancelled)?;
    let path = request.data_directory.join("hooks.json");
    if matches!(request.action, Action::Read {}) {
        return view(storage::read("library", path)?, resolve);
    }
    let _guard = write_lock
        .try_lock()
        .map_err(|_| error("busy", "Another Hook update is running. Try again."))?;
    let (expected_revision, guards) = match &request.action {
        Action::Save {
            hook,
            expected_revision,
            files,
        } => {
            validate(hook)?;
            if hook.pending_removal {
                return Err(error("invalid_request", "A removed Hook cannot be saved."));
            }
            (expected_revision, files)
        }
        Action::Remove {
            expected_revision,
            files,
            ..
        }
        | Action::Sync {
            expected_revision,
            files,
        } => (expected_revision, files),
        Action::Read {} => unreachable!(),
    };
    if guards.len() > AGENTS.len()
        || guards
            .iter()
            .any(|g| !AGENTS.contains(&g.agent_id.as_str()))
        || guards
            .iter()
            .enumerate()
            .any(|(i, g)| guards[..i].iter().any(|other| other.agent_id == g.agent_id))
    {
        return Err(error("invalid_request", "Invalid Hook file guards."));
    }
    let mut source = storage::read("library", path.clone())?;
    if &source.revision != expected_revision {
        return Err(storage::changed());
    }
    let mut stored = decode(&source)?;
    check_cancelled(cancelled)?;
    let _file_lock = storage::lock(&request.data_directory)?;
    if storage::read("library", path.clone())?.revision != source.revision {
        return Err(storage::changed());
    }
    match &request.action {
        Action::Save { hook, .. } => {
            let mut hook = hook.clone();
            if stored
                .hooks
                .iter()
                .any(|h| h.id != hook.id && h.name.eq_ignore_ascii_case(&hook.name))
            {
                return Err(error(
                    "invalid_request",
                    "A Hook with this name already exists.",
                ));
            }
            hook.agents.sort();
            if let Some(existing) = stored.hooks.iter_mut().find(|h| h.id == hook.id) {
                *existing = hook;
            } else {
                if stored.hooks.len() >= 200 {
                    return Err(error(
                        "limit",
                        "The Hook library can contain at most 200 Hooks.",
                    ));
                }
                stored.hooks.push(hook);
            }
        }
        Action::Remove { id, .. } => {
            let hook = stored
                .hooks
                .iter_mut()
                .find(|h| &h.id == id)
                .ok_or_else(|| {
                    error(
                        "invalid_request",
                        "This Hook no longer exists. Reload the library.",
                    )
                })?;
            hook.pending_removal = true;
        }
        _ => {}
    }
    // Commit desired state first; a failed target remains explicitly out of sync.
    source = storage::save(&source, &stored)?;
    let guards = match &request.action {
        Action::Save { files, .. } | Action::Remove { files, .. } | Action::Sync { files, .. } => {
            files
        }
        _ => unreachable!(),
    };
    let mut failures = Vec::new();
    for agent in AGENTS {
        let result = (|| {
            check_cancelled(cancelled)?;
            let native = native_file(agent, resolve)?;
            let (next, placements) = plan(&stored, &native)?;
            if next == native.content {
                stored.placements.retain(|p| p.agent_id != agent);
                stored.placements.extend(placements);
                source = storage::save(&source, &stored)?;
                return Ok(());
            }
            let guard = guards
                .iter()
                .find(|g| g.agent_id == agent)
                .ok_or_else(storage::changed)?;
            if guard.path != native.path || guard.revision != native.revision {
                return Err(storage::changed());
            }
            // Journal both versions BEFORE writing the target. On retry the
            // exact matching version is recognized; no entry is claimed by name.
            for placement in &placements {
                if !stored.placements.contains(placement) {
                    stored.placements.push(placement.clone());
                }
            }
            source = storage::save(&source, &stored)?;
            check_cancelled(cancelled)?;
            storage::write_native(&native, &next)?;
            stored.placements.retain(|p| p.agent_id != agent);
            stored.placements.extend(placements);
            source = storage::save(&source, &stored)?;
            Ok::<(), Error>(())
        })();
        if let Err(issue) = result {
            failures.push((agent, issue.message));
        }
    }
    stored
        .hooks
        .retain(|h| !h.pending_removal || stored.placements.iter().any(|p| p.id == h.id));
    source = storage::save(&source, &stored)?;
    let mut result = view(source, resolve)?;
    for (agent, issue) in failures {
        if let Some(target) = result.targets.iter_mut().find(|t| t.agent_id == agent) {
            target.issue = Some(issue.into());
        }
    }
    Ok(result)
}

fn check_cancelled(cancelled: &impl Fn() -> bool) -> Result<(), Error> {
    if cancelled() {
        Err(error("cancelled", "Hook synchronization was cancelled."))
    } else {
        Ok(())
    }
}

fn decode(source: &InstructionFile) -> Result<Stored, Error> {
    if !source.exists {
        return Ok(Stored::default());
    }
    let stored: Stored = serde_json::from_str(&source.content).map_err(|_| {
        error(
            "invalid_library",
            "The Hook library is invalid. Restore it before making changes.",
        )
    })?;
    if stored.hooks.len() > 200 || stored.placements.len() > 2000 {
        return Err(error("limit", "The Hook library exceeded its size limit."));
    }
    for hook in &stored.hooks {
        validate(hook)?;
    }
    if stored.hooks.iter().enumerate().any(|(i, h)| {
        stored.hooks[..i]
            .iter()
            .any(|other| other.id == h.id || other.name.eq_ignore_ascii_case(&h.name))
    }) {
        return Err(error(
            "invalid_library",
            "The Hook library contains duplicate Hooks.",
        ));
    }
    Ok(stored)
}

fn validate(hook: &Hook) -> Result<(), Error> {
    if uuid::Uuid::parse_str(&hook.id).is_err()
        || hook.name.is_empty()
        || hook.name.len() > 80
        || !hook
            .name
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
        || hook.description.chars().count() > 200
        || hook.command.trim().is_empty()
        || hook.command.len() > 32768
        || hook.command.contains('\0')
        || hook
            .timeout_seconds
            .is_some_and(|seconds| seconds == 0 || seconds > 86400)
        || hook.agents.is_empty()
        || hook.agents.len() > 2
        || hook.agents.iter().any(|a| !AGENTS.contains(&a.as_str()))
        || (hook.agents.len() == 2 && hook.agents[0] == hook.agents[1])
        || (!matches!(hook.event, Event::BeforeTool | Event::AfterTool)
            && hook.matcher != Matcher::All)
    {
        return Err(error(
            "invalid_request",
            "Check the Hook name, command, event, Agents and timeout (1–86400 seconds).",
        ));
    }
    Ok(())
}

fn native_file(agent: &str, resolve: &Resolver<'_>) -> Result<InstructionFile, Error> {
    let directory = resolve(agent).map_err(storage::file_error)?;
    storage::read(
        agent,
        directory.join(if agent == "codex-acp" {
            "hooks.json"
        } else {
            "settings.json"
        }),
    )
}

fn document(file: &InstructionFile) -> Result<Value, Error> {
    let value = if !file.exists {
        json!({})
    } else {
        storage::parse_json(&file.content).map_err(|_| {
            error(
                "invalid_json",
                "The native Hook configuration must be valid JSON. Existing contents were kept.",
            )
        })?
    };
    if !value.is_object() || value.get("hooks").is_some_and(|h| !h.is_object()) {
        return Err(error(
            "invalid_json",
            "The native hooks field must be a JSON object. Existing contents were kept.",
        ));
    }
    Ok(value)
}

fn entry(hook: &Hook, agent: &str) -> Value {
    let mut command = json!({"type": "command", "command": hook.command});
    if let Some(timeout) = hook.timeout_seconds {
        command["timeout"] = json!(timeout);
    }
    let mut value = json!({"hooks": [command]});
    let matcher = match hook.matcher {
        Matcher::All => None,
        Matcher::Shell => Some("Bash"),
        Matcher::Edit if agent == "codex-acp" => Some("apply_patch"),
        Matcher::Edit => Some("Edit|Write|MultiEdit"),
    };
    if let Some(matcher) = matcher {
        value["matcher"] = json!(matcher);
    }
    value
}

fn group<'a>(doc: &'a Value, placement: &Placement) -> Option<&'a Value> {
    doc.get("hooks")?
        .get(&placement.event)?
        .as_array()?
        .get(placement.index)
}

// Removing a group by compaction would move Codex's index-based trust to another
// command. Keep empty groups as tombstones and append new commands only.
fn plan(stored: &Stored, native: &InstructionFile) -> Result<(String, Vec<Placement>), Error> {
    let mut doc = document(native)?;
    let original = doc.clone();
    let mut kept = Vec::new();
    for placement in stored
        .placements
        .iter()
        .filter(|p| p.agent_id == native.agent_id)
    {
        if placement.path != native.path {
            return Err(error("profile_changed", "The Agent profile changed. Restore the previous profile before synchronizing its Hooks."));
        }
        let current = group(&doc, placement);
        let matches = current == Some(&placement.entry);
        let known_variant = stored.placements.iter().any(|p| {
            p.agent_id == placement.agent_id
                && p.path == placement.path
                && p.event == placement.event
                && p.index == placement.index
                && group(&doc, p) == Some(&p.entry)
        });
        if !matches {
            if current.is_some_and(|g| g != &json!({"hooks": []})) && !known_variant {
                return Err(error("ownership_changed", "A managed Hook was edited outside Lithe. Restore or remove that native entry before synchronizing."));
            }
            continue;
        }
        let wanted = stored.hooks.iter().find(|h| {
            h.id == placement.id
                && !h.pending_removal
                && h.enabled
                && h.agents.contains(&native.agent_id)
        });
        if wanted.is_some_and(|h| {
            h.event.native() == placement.event && entry(h, &native.agent_id) == placement.entry
        }) && !kept.iter().any(|p: &Placement| p.id == placement.id)
        {
            kept.push(placement.clone());
        } else {
            doc["hooks"][&placement.event][placement.index] = json!({"hooks": []});
        }
    }
    for hook in stored
        .hooks
        .iter()
        .filter(|h| !h.pending_removal && h.enabled && h.agents.contains(&native.agent_id))
    {
        if kept.iter().any(|p| p.id == hook.id) {
            continue;
        }
        let event = hook.event.native();
        if doc.get("hooks").is_none() {
            doc["hooks"] = json!({});
        }
        if doc["hooks"].get(event).is_none() {
            doc["hooks"][event] = json!([]);
        }
        let groups = doc["hooks"][event].as_array_mut().ok_or_else(|| {
            error(
                "invalid_json",
                "The native Hook event must contain an array. Existing contents were kept.",
            )
        })?;
        if groups.contains(&entry(hook, &native.agent_id)) {
            return Err(error(
                "duplicate_native",
                "An identical native Hook already exists. Lithe kept it unchanged.",
            ));
        }
        let placement = Placement {
            id: hook.id.clone(),
            agent_id: native.agent_id.clone(),
            path: native.path.clone(),
            event: event.into(),
            index: groups.len(),
            entry: entry(hook, &native.agent_id),
        };
        groups.push(placement.entry.clone());
        kept.push(placement);
    }
    let content = if doc == original {
        native.content.clone()
    } else {
        serde_json::to_string_pretty(&doc)
            .map_err(|_| error("invalid_json", "Cannot encode Hook configuration."))?
            + "\n"
    };
    Ok((content, kept))
}

fn view(source: InstructionFile, resolve: &Resolver<'_>) -> Result<Library, Error> {
    let stored = decode(&source)?;
    let mut targets = Vec::new();
    let mut native_docs = Vec::new();
    for agent in AGENTS {
        let result = native_file(agent, resolve).and_then(|file| {
            let doc = document(&file)?;
            Ok((file, doc))
        });
        match result {
            Ok((file, doc)) => {
                let issue = plan(&stored, &file).err().map(|e| e.message.into());
                targets.push(Target {
                    agent_id: agent.into(),
                    file: Some(FileGuard {
                        agent_id: agent.into(),
                        path: file.path.clone(),
                        revision: file.revision,
                    }),
                    issue,
                    disabled: doc.get("disableAllHooks").and_then(Value::as_bool) == Some(true),
                });
                native_docs.push((agent, file.path, doc));
            }
            Err(issue) => targets.push(Target {
                agent_id: agent.into(),
                file: None,
                issue: Some(issue.message.into()),
                disabled: false,
            }),
        }
    }
    let hooks = stored
        .hooks
        .iter()
        .map(|hook| {
            let mut configured_agents = Vec::new();
            let mut stale = false;
            for placement in stored.placements.iter().filter(|p| p.id == hook.id) {
                let current = native_docs
                    .iter()
                    .find(|(agent, path, _)| {
                        *agent == placement.agent_id && *path == placement.path
                    })
                    .and_then(|(_, _, doc)| group(doc, placement));
                if current == Some(&placement.entry) {
                    if hook.event.native() == placement.event
                        && entry(hook, &placement.agent_id) == placement.entry
                    {
                        if !configured_agents.contains(&placement.agent_id) {
                            configured_agents.push(placement.agent_id.clone());
                        }
                    } else {
                        stale = true;
                    }
                } else if current.is_some_and(|g| g != &json!({"hooks": []})) {
                    stale = true;
                }
            }
            configured_agents.sort();
            let mut wanted = if hook.enabled && !hook.pending_removal {
                hook.agents.clone()
            } else {
                Vec::new()
            };
            wanted.sort();
            HookView {
                hook: hook.clone(),
                needs_sync: stale || configured_agents != wanted,
                configured_agents,
            }
        })
        .collect();
    Ok(Library {
        revision: source.revision,
        hooks,
        targets,
    })
}
