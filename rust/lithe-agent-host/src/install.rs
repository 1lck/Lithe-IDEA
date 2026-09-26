//! One-click installation of ACP adapters with the user's own npm.
//!
//! Each adapter lives in `<data>/agents/<id>` with a `lithe-agent.json` marker
//! naming the installed version. Installs run in a staging directory that
//! replaces the old one only after npm succeeded and the executable exists, so
//! a failed or cancelled install never breaks a working adapter.

use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::catalog::{AgentCli, CatalogAgent, ProviderProtocol, CATALOG};
use crate::environment::{self, DetectedTool, RunError, RuntimeEnvironment};

const INSTALL_TIMEOUT: Duration = Duration::from_secs(15 * 60);
const MARKER: &str = "lithe-agent.json";
/// Characters of npm output kept for a failure report.
const OUTPUT_TAIL: usize = 2000;

/// Why a management request failed; hosts map these to stable error codes.
#[derive(Debug, PartialEq, Eq)]
pub enum ManagementError {
    UnknownAgent(String),
    RuntimeMissing(String),
    Failed(String),
    Cancelled,
    TimedOut,
}

impl ManagementError {
    pub fn message(&self) -> String {
        match self {
            Self::UnknownAgent(id) => format!("Unknown agent `{id}`"),
            Self::RuntimeMissing(message) | Self::Failed(message) => message.clone(),
            Self::Cancelled => "The installation was cancelled".into(),
            Self::TimedOut => "The installation did not finish in time".into(),
        }
    }
}

#[derive(Debug, Deserialize, Serialize)]
struct Marker {
    id: String,
    version: String,
}

/// The user's own agent CLI that an adapter drives.
#[derive(Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct CliStatus {
    pub name: String,
    pub command: String,
    pub minimum_version: String,
    pub install_hint: String,
    /// npm package Lithe installs globally on request.
    pub package: String,
    pub detected: Option<DetectedTool>,
}

/// Status of one catalog agent on this machine.
#[derive(Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct AgentStatus {
    pub id: String,
    pub name: String,
    pub description: String,
    pub package: String,
    /// Version Lithe installs.
    pub version: String,
    pub installed_version: Option<String>,
    pub protocol: ProviderProtocol,
    pub minimum_node_major: u32,
    pub verified: bool,
    /// The user's CLI this adapter runs, when it does not bundle one.
    pub cli: Option<CliStatus>,
    /// User-facing reasons the agent cannot be installed or started now.
    pub issues: Vec<String>,
}

/// Runtime detection plus every catalog agent's status.
#[derive(Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct ManagementStatus {
    pub environment: RuntimeEnvironment,
    pub agents: Vec<AgentStatus>,
}

/// Detect the runtime and report each catalog agent's installation state.
pub fn status(data_directory: &Path, cancel: &dyn Fn() -> bool) -> ManagementStatus {
    let environment = environment::detect(cancel);
    status_with(data_directory, environment, &|command| {
        environment::detect_tool(command, cancel)
    })
}

/// Catalog statuses for an already detected runtime; `find_cli` looks up an
/// agent CLI on the search path.
pub(crate) fn status_with(
    data_directory: &Path,
    environment: RuntimeEnvironment,
    find_cli: &dyn Fn(&str) -> Option<DetectedTool>,
) -> ManagementStatus {
    let agents = CATALOG
        .iter()
        .map(|agent| {
            let cli = agent.cli.as_ref().map(|cli| CliStatus {
                name: cli.name.into(),
                command: cli.command.into(),
                minimum_version: cli.minimum_version.into(),
                install_hint: cli.install_hint.into(),
                package: cli.package.into(),
                detected: find_cli(cli.command),
            });
            let mut issues = runtime_issues(agent, &environment);
            if let (Some(cli), Some(status)) = (&agent.cli, &cli) {
                issues.extend(cli_issue(cli, status.detected.as_ref()));
            }
            AgentStatus {
                id: agent.id.into(),
                name: agent.name.into(),
                description: agent.description.into(),
                package: agent.package.into(),
                version: agent.version.into(),
                installed_version: installed_version(data_directory, agent),
                protocol: agent.protocol,
                minimum_node_major: agent.minimum_node_major,
                verified: agent.verified,
                cli,
                issues,
            }
        })
        .collect();
    ManagementStatus {
        environment,
        agents,
    }
}

/// Why the user's CLI cannot be used, if it is missing or too old.
pub(crate) fn cli_issue(cli: &AgentCli, detected: Option<&DetectedTool>) -> Option<String> {
    match detected {
        None => Some(format!(
            "{} was not found. Install it (for example `{}`), then check again.",
            cli.name, cli.install_hint
        )),
        Some(tool) if !environment::version_at_least(&tool.version, cli.minimum_version) => {
            Some(format!(
                "{} {} or later is required; found {}. Update it, then check again.",
                cli.name, cli.minimum_version, tool.version
            ))
        }
        Some(_) => None,
    }
}

fn runtime_issues(agent: &CatalogAgent, environment: &RuntimeEnvironment) -> Vec<String> {
    let mut issues = Vec::new();
    match environment.node_major() {
        None => issues.push(format!(
            "Node.js {} or later was not found. Install it, then check again.",
            agent.minimum_node_major
        )),
        Some(major) if major < agent.minimum_node_major => issues.push(format!(
            "{} needs Node.js {} or later; found {}.",
            agent.name,
            agent.minimum_node_major,
            environment
                .node
                .as_ref()
                .map_or("", |node| node.version.as_str())
        )),
        Some(_) => {}
    }
    if environment.npm.is_none() {
        issues.push("npm was not found. It is normally installed with Node.js.".into());
    }
    issues
}

/// Installed adapter directory for `agent`.
pub fn agent_directory(data_directory: &Path, agent: &CatalogAgent) -> PathBuf {
    data_directory.join("agents").join(agent.id)
}

/// Executable of an installed adapter.
pub fn installed_command(data_directory: &Path, agent: &CatalogAgent) -> PathBuf {
    bin_path(&agent_directory(data_directory, agent), agent)
}

fn bin_path(root: &Path, agent: &CatalogAgent) -> PathBuf {
    let name = if cfg!(windows) {
        format!("{}.cmd", agent.bin)
    } else {
        agent.bin.to_owned()
    };
    root.join("node_modules").join(".bin").join(name)
}

/// Version recorded by a complete install whose executable still exists.
pub fn installed_version(data_directory: &Path, agent: &CatalogAgent) -> Option<String> {
    let root = agent_directory(data_directory, agent);
    let marker: Marker = serde_json::from_slice(&std::fs::read(root.join(MARKER)).ok()?).ok()?;
    (marker.id == agent.id && bin_path(&root, agent).exists()).then_some(marker.version)
}

/// Install or replace `agent_id` with its pinned version using the user's npm.
pub fn install(
    data_directory: &Path,
    agent_id: &str,
    cancel: &dyn Fn() -> bool,
) -> Result<String, ManagementError> {
    let agent = crate::catalog::find(agent_id)
        .ok_or_else(|| ManagementError::UnknownAgent(agent_id.into()))?;
    let environment = environment::detect(cancel);
    if let Some(issue) = runtime_issues(agent, &environment).into_iter().next() {
        return Err(ManagementError::RuntimeMissing(issue));
    }
    let npm = environment
        .npm
        .as_ref()
        .map(|npm| npm.path.clone())
        .ok_or_else(|| ManagementError::RuntimeMissing("npm was not found".into()))?;
    let agents = data_directory.join("agents");
    let staging = agents.join(format!(".{}.installing", agent.id));
    let _ = std::fs::remove_dir_all(&staging);
    std::fs::create_dir_all(&staging).map_err(|error| {
        ManagementError::Failed(format!("Could not create {}: {error}", staging.display()))
    })?;
    let result = run_npm_install(&npm, &staging, agent, cancel).and_then(|()| {
        if !bin_path(&staging, agent).exists() {
            return Err(ManagementError::Failed(format!(
                "npm finished, but `{}` was not installed",
                agent.bin
            )));
        }
        let marker = serde_json::to_vec(&Marker {
            id: agent.id.into(),
            version: agent.version.into(),
        })
        .map_err(|error| ManagementError::Failed(error.to_string()))?;
        std::fs::write(staging.join(MARKER), marker)
            .map_err(|error| ManagementError::Failed(error.to_string()))?;
        replace_directory(&staging, &agent_directory(data_directory, agent))
    });
    if result.is_err() {
        let _ = std::fs::remove_dir_all(&staging);
    }
    result.map(|()| agent.version.to_owned())
}

/// Install or update the user's own CLI for `agent_id` with `npm install -g`
/// on the user's npm, then report the version now on the search path.
///
/// This is the one place Lithe touches a global npm install; it runs only on
/// an explicit click and uses the same npm the user would.
pub fn install_cli(agent_id: &str, cancel: &dyn Fn() -> bool) -> Result<String, ManagementError> {
    let agent = crate::catalog::find(agent_id)
        .ok_or_else(|| ManagementError::UnknownAgent(agent_id.into()))?;
    let cli = agent.cli.as_ref().ok_or_else(|| {
        ManagementError::Failed(format!("{} does not use a separate CLI", agent.name))
    })?;
    let environment = environment::detect(cancel);
    let npm = environment
        .npm
        .as_ref()
        .map(|npm| npm.path.clone())
        .ok_or_else(|| ManagementError::RuntimeMissing("npm was not found".into()))?;
    let mut command = Command::new(&npm);
    command
        .args([
            "install",
            "-g",
            "--no-audit",
            "--no-fund",
            "--loglevel=error",
        ])
        .arg(format!("{}@latest", cli.package));
    if let Some(path) = environment::search_path() {
        command.env("PATH", path);
    }
    match environment::run_bounded_status(&mut command, INSTALL_TIMEOUT, cancel) {
        Ok((true, _)) => {}
        Ok((false, output)) => {
            return Err(ManagementError::Failed(format!(
                "npm could not install {}:\n{}",
                cli.package,
                tail(&output)
            )))
        }
        Err(RunError::Cancelled) => return Err(ManagementError::Cancelled),
        Err(RunError::TimedOut) => return Err(ManagementError::TimedOut),
        Err(RunError::Start(message)) => {
            return Err(ManagementError::Failed(format!(
                "Could not run npm: {message}"
            )))
        }
    }
    environment::detect_tool(cli.command, cancel)
        .map(|tool| tool.version)
        .ok_or_else(|| {
            ManagementError::Failed(format!(
                "npm finished, but `{}` was not found on the search path",
                cli.command
            ))
        })
}

/// Remove an installed adapter. Removing a missing adapter succeeds.
pub fn uninstall(data_directory: &Path, agent_id: &str) -> Result<(), ManagementError> {
    let agent = crate::catalog::find(agent_id)
        .ok_or_else(|| ManagementError::UnknownAgent(agent_id.into()))?;
    match std::fs::remove_dir_all(agent_directory(data_directory, agent)) {
        Err(error) if error.kind() != std::io::ErrorKind::NotFound => Err(ManagementError::Failed(
            format!("Could not remove {}: {error}", agent.name),
        )),
        _ => Ok(()),
    }
}

fn run_npm_install(
    npm: &Path,
    prefix: &Path,
    agent: &CatalogAgent,
    cancel: &dyn Fn() -> bool,
) -> Result<(), ManagementError> {
    let mut command = Command::new(npm);
    command
        .arg("install")
        .arg("--prefix")
        .arg(prefix)
        .args(["--no-audit", "--no-fund", "--omit=dev", "--loglevel=error"])
        // Adapters that drive the user's CLI skip their bundled copy, which is
        // an optional dependency of several hundred megabytes.
        .args(agent.cli.as_ref().map(|_| "--omit=optional"))
        .arg(format!("{}@{}", agent.package, agent.version))
        .current_dir(prefix);
    if let Some(path) = environment::search_path() {
        command.env("PATH", path);
    }
    match environment::run_bounded_status(&mut command, INSTALL_TIMEOUT, cancel) {
        Ok((true, _)) => Ok(()),
        Ok((false, output)) => Err(ManagementError::Failed(format!(
            "npm could not install {}:\n{}",
            agent.package,
            tail(&output)
        ))),
        Err(RunError::Cancelled) => Err(ManagementError::Cancelled),
        Err(RunError::TimedOut) => Err(ManagementError::TimedOut),
        Err(RunError::Start(message)) => Err(ManagementError::Failed(format!(
            "Could not run npm: {message}"
        ))),
    }
}

/// Swap `staging` into `target`, keeping the old install until the swap succeeds.
fn replace_directory(staging: &Path, target: &Path) -> Result<(), ManagementError> {
    let previous = target.with_file_name(format!(
        ".{}.previous",
        target
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("agent")
    ));
    let _ = std::fs::remove_dir_all(&previous);
    let had_previous = target.exists();
    if had_previous {
        std::fs::rename(target, &previous).map_err(|error| {
            ManagementError::Failed(format!("Could not replace the old install: {error}"))
        })?;
    }
    if let Err(error) = std::fs::rename(staging, target) {
        if had_previous {
            let _ = std::fs::rename(&previous, target);
        }
        return Err(ManagementError::Failed(format!(
            "Could not finish the install: {error}"
        )));
    }
    let _ = std::fs::remove_dir_all(&previous);
    Ok(())
}

fn tail(output: &str) -> String {
    let trimmed = output.trim();
    let start = trimmed
        .char_indices()
        .rev()
        .nth(OUTPUT_TAIL)
        .map_or(0, |(index, _)| index);
    trimmed[start..].to_owned()
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use crate::environment::DetectedTool;
    use std::os::unix::fs::PermissionsExt;

    fn temp_directory(name: &str) -> PathBuf {
        let directory =
            std::env::temp_dir().join(format!("lithe-install-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&directory);
        std::fs::create_dir_all(&directory).unwrap();
        directory
    }

    /// Fake npm that creates the adapter executable, or fails when asked.
    fn fake_npm(directory: &Path, succeed: bool) -> PathBuf {
        let npm = directory.join("npm");
        let script = if succeed {
            "#!/bin/sh\nprefix=\"$3\"\nmkdir -p \"$prefix/node_modules/.bin\"\nprintf '#!/bin/sh\\n' > \"$prefix/node_modules/.bin/codex-acp\"\nchmod +x \"$prefix/node_modules/.bin/codex-acp\"\n"
        } else {
            "#!/bin/sh\necho 'npm ERR! 404 Not Found' >&2\nexit 1\n"
        };
        std::fs::write(&npm, script).unwrap();
        std::fs::set_permissions(&npm, std::fs::Permissions::from_mode(0o755)).unwrap();
        npm
    }

    fn codex() -> &'static CatalogAgent {
        crate::catalog::find("codex-acp").unwrap()
    }

    #[test]
    fn successful_install_replaces_the_previous_version_atomically() {
        let data = temp_directory("ok");
        let npm = fake_npm(&data, true);
        let old = agent_directory(&data, codex());
        std::fs::create_dir_all(&old).unwrap();
        std::fs::write(old.join("stale"), "old").unwrap();

        let staging = data.join("agents/.codex-acp.installing");
        std::fs::create_dir_all(&staging).unwrap();
        run_npm_install(&npm, &staging, codex(), &|| false).unwrap();
        std::fs::write(
            staging.join(MARKER),
            r#"{"id":"codex-acp","version":"1.13.1"}"#,
        )
        .unwrap();
        replace_directory(&staging, &old).unwrap();

        assert_eq!(installed_version(&data, codex()).as_deref(), Some("1.13.1"));
        assert!(!old.join("stale").exists());
        assert!(!staging.exists());
        assert!(installed_command(&data, codex()).exists());
        uninstall(&data, "codex-acp").unwrap();
        assert_eq!(installed_version(&data, codex()), None);
        uninstall(&data, "codex-acp").unwrap();
        let _ = std::fs::remove_dir_all(&data);
    }

    #[test]
    fn npm_failure_reports_its_output_and_keeps_the_old_install() {
        let data = temp_directory("fail");
        let npm = fake_npm(&data, false);
        let staging = data.join("staging");
        std::fs::create_dir_all(&staging).unwrap();
        match run_npm_install(&npm, &staging, codex(), &|| false) {
            Err(ManagementError::Failed(message)) => {
                assert!(message.contains("404 Not Found"), "{message}")
            }
            other => panic!("expected failure, got {other:?}"),
        }
        assert_eq!(
            run_npm_install(&npm, &staging, codex(), &|| true),
            Err(ManagementError::Cancelled)
        );
        let _ = std::fs::remove_dir_all(&data);
    }

    #[test]
    fn missing_or_old_node_is_reported_per_agent() {
        let tool = |version: &str| {
            Some(DetectedTool {
                version: version.into(),
                path: "/bin/tool".into(),
            })
        };
        let environment = |node: Option<DetectedTool>| RuntimeEnvironment {
            node,
            npm: tool("10.0.0"),
            used_login_shell: true,
        };
        assert!(runtime_issues(codex(), &environment(tool("22.1.0"))).is_empty());
        let claude = crate::catalog::find("claude-acp").unwrap();
        let old = runtime_issues(claude, &environment(tool("20.11.0")));
        assert_eq!(old.len(), 1);
        assert!(old[0].contains("Node.js 22"), "{}", old[0]);
        assert!(runtime_issues(codex(), &environment(None))[0].contains("was not found"));
        assert!(uninstall(Path::new("/tmp"), "unknown").is_err());
    }

    #[test]
    fn output_tail_keeps_the_end() {
        let long = format!("{}END", "x".repeat(OUTPUT_TAIL * 2));
        let tail = tail(&long);
        assert!(tail.ends_with("END"));
        assert!(tail.chars().count() <= OUTPUT_TAIL + 1);
    }
}
