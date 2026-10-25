//! Native Agent skill discovery and explicit user-owned skill installation.
//!
//! Codex owns discovery through skills/list. Claude's directory inventory is
//! deliberately not advertised as a complete or enabled session capability list.
//! Explicit toggles use native settings; discovery never changes configuration.

mod files;
mod settings;
#[cfg(test)]
mod tests;

use crate::{codex_history::CodexHistory, environment};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

/// Explicit settings action. Reading a list never installs or enables a skill.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Request {
    pub action: Action,
    pub agent_id: String,
    /// Current opened project, or None for user-only settings.
    pub workspace: Option<PathBuf>,
    pub scope: Option<String>,
    pub name: Option<String>,
    pub description: Option<String>,
    pub instructions: Option<String>,
    /// User-selected SKILL.md or a directory containing it; never an archive or URL.
    pub source: Option<PathBuf>,
    /// Desired native visibility; required only for setEnabled.
    pub enabled: Option<bool>,
    /// Selected Codex account directory (`CODEX_HOME`); None uses the default account.
    pub codex_home: Option<PathBuf>,
    /// Selected Claude account directory (`CLAUDE_CONFIG_DIR`); None uses the environment or default.
    pub claude_config_dir: Option<PathBuf>,
}

/// Mutations require an explicit settings action, never a discovery request.
#[derive(Debug, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum Action {
    List,
    Directories,
    Read,
    Create,
    Import,
    SetEnabled,
}

/// A native path is transient platform metadata, not a persistent shared identifier.
#[derive(Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
struct Skill {
    name: String,
    description: String,
    path: PathBuf,
    scope: String,
    /// Native Codex state, or Claude's configured visibility in this scope.
    /// None means configuration could not be read, never an inferred default.
    enabled: Option<bool>,
    plugin_id: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct Listing {
    skills: Vec<Skill>,
    /// "agent" means native discovery; "directory" means an explicitly partial inventory.
    source: &'static str,
    issues: Vec<String>,
    directories: std::collections::BTreeMap<String, PathBuf>,
}

/// Failures retain a stable category without returning raw subprocess output.
#[derive(Debug)]
pub enum Error {
    Invalid(String),
    Failed(String),
    MissingCLI,
    Cancelled,
}

impl Error {
    pub fn message(&self) -> &str {
        match self {
            Self::Invalid(message) | Self::Failed(message) => message,
            Self::MissingCLI => "Install Codex CLI to discover its skills.",
            Self::Cancelled => "Skill operation was cancelled.",
        }
    }
}

/// Run on a platform worker. The caller owns cancellation and the current workspace.
pub fn execute(request: Request, cancelled: &dyn Fn() -> bool) -> Result<Value, Error> {
    let home = std::env::var_os(if cfg!(windows) { "USERPROFILE" } else { "HOME" })
        .map(PathBuf::from)
        .filter(|p| p.is_absolute())
        .ok_or_else(|| Error::Failed("The user home directory is unavailable.".into()))?;
    let claude = request
        .claude_config_dir
        .clone()
        .or_else(|| std::env::var_os("CLAUDE_CONFIG_DIR").map(PathBuf::from))
        .unwrap_or_else(|| home.join(".claude"));
    execute_at(request, &home, &claude, cancelled)
}

fn execute_at(
    request: Request,
    home: &Path,
    claude: &Path,
    cancelled: &dyn Fn() -> bool,
) -> Result<Value, Error> {
    check(cancelled)?;
    if !matches!(request.agent_id.as_str(), "codex-acp" | "claude-acp") {
        return Err(Error::Invalid(
            "Skill management is available for Codex and Claude.".into(),
        ));
    }
    if request
        .workspace
        .as_ref()
        .is_some_and(|p| !p.is_absolute() || !p.is_dir())
        || !claude.is_absolute()
        || request.codex_home.as_ref().is_some_and(|p| !p.is_absolute())
    {
        return Err(Error::Invalid(
            "The skill workspace and configuration directory must be absolute directories.".into(),
        ));
    }
    if request.action == Action::Directories {
        return Ok(json!({"directories": files::directories(&request, home, claude)}));
    }
    if request.action == Action::Read {
        let path = request
            .source
            .as_deref()
            .filter(|p| p.is_absolute())
            .ok_or_else(|| Error::Invalid("Choose a skill document.".into()))?;
        return files::read_document(path).map(|content| json!({"content": content}));
    }
    if request.action == Action::SetEnabled {
        return settings::set_enabled(&request, home, claude, cancelled);
    }
    if request.action != Action::List {
        return files::install(&request, home, claude, cancelled).map(|path| json!({"path": path}));
    }
    let mut listing = if request.agent_id == "codex-acp" {
        let cli = environment::detect_tool("codex", cancelled).ok_or(Error::MissingCLI)?;
        check(cancelled)?;
        let cwd = request.workspace.as_deref().unwrap_or(home);
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .map_err(|_| Error::Failed("Skill discovery could not start.".into()))?;
        let result = runtime.block_on(CodexHistory::skills(cli.path, cwd.to_path_buf(), request.codex_home.clone(), cancelled));
        check(cancelled)?;
        let value = result.map_err(|_| {
            Error::Failed("Codex skill discovery failed. Check the CLI and retry.".into())
        })?;
        parse_codex(&value, cwd)?
    } else {
        files::claude_inventory(request.workspace.as_deref(), claude, cancelled)?
    };
    if request.agent_id == "claude-acp" {
        settings::annotate(&mut listing, request.workspace.as_deref(), claude);
    }
    check(cancelled)?;
    listing_value(listing, &request, home, claude)
}

fn listing_value(
    mut listing: Listing,
    request: &Request,
    home: &Path,
    claude: &Path,
) -> Result<Value, Error> {
    listing.directories = files::directories(request, home, claude);
    listing.skills.sort_by(|a, b| {
        a.name
            .to_lowercase()
            .cmp(&b.name.to_lowercase())
            .then(a.path.cmp(&b.path))
    });
    serde_json::to_value(listing)
        .map_err(|_| Error::Failed("Skill metadata could not be returned.".into()))
}

fn check(cancelled: &dyn Fn() -> bool) -> Result<(), Error> {
    if cancelled() {
        Err(Error::Cancelled)
    } else {
        Ok(())
    }
}

fn parse_codex(value: &Value, cwd: &Path) -> Result<Listing, Error> {
    let entries = value["data"]
        .as_array()
        .ok_or_else(|| Error::Failed("Codex returned invalid skill metadata.".into()))?;
    let entry = entries
        .iter()
        .find(|entry| {
            entry["cwd"].as_str().is_some_and(|path| {
                Path::new(path) == cwd
                    || std::fs::canonicalize(path)
                        .ok()
                        .zip(std::fs::canonicalize(cwd).ok())
                        .is_some_and(|(a, b)| a == b)
            })
        })
        .ok_or_else(|| {
            Error::Failed("Codex did not report skills for the selected project.".into())
        })?;
    let rows = entry["skills"]
        .as_array()
        .ok_or_else(|| Error::Failed("Codex returned invalid skill metadata.".into()))?;
    if rows.len() > files::MAX_ENTRIES {
        return Err(Error::Failed("Too many skills to display.".into()));
    }
    let mut listing = Listing {
        skills: vec![],
        source: "agent",
        issues: vec![],
        directories: Default::default(),
    };
    for row in rows {
        let path = row["path"].as_str().map(PathBuf::from);
        match (row["name"].as_str(), row["description"].as_str(), path) {
            (Some(name), Some(description), Some(path))
                if path.is_absolute() && !name.is_empty() =>
            {
                if !matches!(
                    row["scope"].as_str(),
                    Some("user" | "repo" | "system" | "admin")
                ) {
                    listing
                        .issues
                        .push("A skill has an unknown scope and cannot be classified.".into());
                    continue;
                }
                if listing.skills.iter().any(|skill| skill.path == path) {
                    continue;
                }
                listing.skills.push(Skill {
                    name: name.into(),
                    description: description.into(),
                    path,
                    scope: row["scope"].as_str().unwrap_or("unknown").into(),
                    enabled: row["enabled"].as_bool(),
                    plugin_id: row["pluginId"].as_str().map(str::to_owned),
                });
            }
            _ => listing
                .issues
                .push("A skill was omitted because its native metadata is incomplete.".into()),
        }
    }
    if entry["errors"]
        .as_array()
        .is_some_and(|errors| !errors.is_empty())
    {
        listing.issues.push(
            "Codex reported skill discovery errors. Check the affected SKILL.md files and refresh."
                .into(),
        );
    }
    Ok(listing)
}

/// Restrict config writes to a path that this workspace's native discovery reports.
pub(crate) fn codex_skill_path(value: &Value, cwd: &Path, path: &Path) -> Option<PathBuf> {
    parse_codex(value, cwd).ok().and_then(|listing| {
        listing
            .skills
            .into_iter()
            .find(|skill| same_path(&skill.path, path) && skill.enabled.is_some())
            .map(|skill| skill.path)
    })
}

fn same_path(left: &Path, right: &Path) -> bool {
    left == right
        || std::fs::canonicalize(left)
            .ok()
            .zip(std::fs::canonicalize(right).ok())
            .is_some_and(|(left, right)| left == right)
}
