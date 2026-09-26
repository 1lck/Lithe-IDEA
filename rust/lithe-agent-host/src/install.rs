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
use crate::cli_update::{self, CliInstallation, CliSource};
use crate::environment::{self, DetectedTool, RunError, RuntimeEnvironment};

const INSTALL_TIMEOUT: Duration = Duration::from_secs(15 * 60);
const MARKER: &str = "lithe-agent.json";
/// Characters of npm output kept for a failure report.
const OUTPUT_TAIL: usize = 2000;

/// Verified CLI version, with bounded installer diagnostics when it reported failure.
#[derive(Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct CliUpdateResult {
    pub cli_version: String,
    /// A warning only after a newly installed or strictly newer usable CLI is verified.
    pub updater_warning: Option<String>,
}

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
    pub installation: Option<CliInstallation>,
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
    status_with(
        data_directory,
        environment.clone(),
        &|command| environment::detect_tool(command, cancel),
        &|cli| {
            Some(
                cli_update::detect(cli, &environment, cancel)
                    .map(|plan| plan.installation)
                    .unwrap_or_else(|_| CliInstallation {
                        source: CliSource::Unknown,
                        can_update: false,
                        update_hint: cli_update::MANUAL_HINT.into(),
                    }),
            )
        },
    )
}

/// Catalog statuses for an already detected runtime; `find_cli` looks up an
/// agent CLI on the search path and `find_installation` supplies ownership evidence.
pub(crate) fn status_with(
    data_directory: &Path,
    environment: RuntimeEnvironment,
    find_cli: &dyn Fn(&str) -> Option<DetectedTool>,
    find_installation: &dyn Fn(&AgentCli) -> Option<CliInstallation>,
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
                installation: find_installation(cli),
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

/// Live npm transfer counters. The package set and its total size are not known
/// in advance, so these counters intentionally do not claim an overall percentage.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct InstallProgress {
    pub stage: InstallStage,
    pub downloaded_bytes: u64,
    pub bytes_per_second: u64,
    pub elapsed_milliseconds: u64,
    /// Time since the last received package bytes; not an install timeout.
    pub idle_milliseconds: u64,
}

/// Observable npm stage, independent of whether the overall install succeeded.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum InstallStage {
    Preparing,
    Downloading,
    Installing,
    /// An external CLI updater owns its transfer and does not expose byte counters.
    Updating,
}

impl InstallProgress {
    fn preparing() -> Self {
        Self {
            stage: InstallStage::Preparing,
            downloaded_bytes: 0,
            bytes_per_second: 0,
            elapsed_milliseconds: 0,
            idle_milliseconds: 0,
        }
    }
}

/// Load a built-in, numbers-only observer in npm's Node process. A data URL
/// avoids writing executable helpers or a second download cache to disk.
fn observe_npm(command: &mut Command) {
    let original = std::env::var("NODE_OPTIONS").unwrap_or_default();
    let encoded = include_bytes!("npm-progress.mjs")
        .iter()
        .map(|byte| format!("%{byte:02X}"))
        .collect::<String>();
    command
        .env("LITHE_NPM_ORIGINAL_NODE_OPTIONS", &original)
        .env(
            "NODE_OPTIONS",
            format!("{original} --import=data:text/javascript,{encoded}"),
        );
}

fn run_observed_npm(
    command: &mut Command,
    cancel: &dyn Fn() -> bool,
    progress: &dyn Fn(InstallProgress),
) -> Result<(bool, String), environment::RunError> {
    observe_npm(command);
    environment::run_bounded_status_observed(command, INSTALL_TIMEOUT, cancel, &mut |line| {
        if let Some(json) = line.strip_prefix("LITHE_NPM_PROGRESS ") {
            if let Ok(event) = serde_json::from_str::<InstallProgress>(json.trim()) {
                progress(event);
            }
        }
    })
}

/// Install or replace `agent_id` with its pinned version using the user's npm.
pub fn install(
    data_directory: &Path,
    agent_id: &str,
    cancel: &dyn Fn() -> bool,
) -> Result<String, ManagementError> {
    install_with_progress(data_directory, agent_id, cancel, &|_| {})
}

/// Installs an adapter and publishes live npm counters on the calling thread.
pub fn install_with_progress(
    data_directory: &Path,
    agent_id: &str,
    cancel: &dyn Fn() -> bool,
    progress: &dyn Fn(InstallProgress),
) -> Result<String, ManagementError> {
    progress(InstallProgress::preparing());
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
    let result = run_npm_install_observed(&npm, &staging, agent, cancel, progress).and_then(|()| {
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

/// Install a missing CLI with npm or update it using its verified installation owner.
///
/// Runs only on an explicit click; unknown owners require manual updating.
pub fn install_cli(
    agent_id: &str,
    cancel: &dyn Fn() -> bool,
) -> Result<CliUpdateResult, ManagementError> {
    install_cli_with_progress(agent_id, cancel, &|_| {})
}

/// Updates through the verified installation owner, publishing only available progress.
pub fn install_cli_with_progress(
    agent_id: &str,
    cancel: &dyn Fn() -> bool,
    progress: &dyn Fn(InstallProgress),
) -> Result<CliUpdateResult, ManagementError> {
    progress(InstallProgress::preparing());
    let agent = crate::catalog::find(agent_id)
        .ok_or_else(|| ManagementError::UnknownAgent(agent_id.into()))?;
    let cli = agent.cli.as_ref().ok_or_else(|| {
        ManagementError::Failed(format!("{} does not use a separate CLI", agent.name))
    })?;
    let environment = environment::detect(cancel);
    let plan = cli_update::detect(cli, &environment, cancel)?;
    let was_missing = plan.installation.source == CliSource::Missing;
    let updater = plan.command.ok_or_else(|| {
        ManagementError::Failed(format!(
            "{} cannot be updated automatically. {}",
            cli.name, plan.installation.update_hint
        ))
    })?;
    let previous = environment::detect_tool(cli.command, cancel);
    let result = run_cli_updater(
        &updater,
        environment::search_path().as_deref(),
        cancel,
        progress,
    );
    finish_cli_update(cli, previous.as_ref(), was_missing, result, || {
        // Even a nonzero exit can follow an upstream download retry that succeeded.
        // Verify the CLI the Agent actually runs, without interpreting log wording.
        environment::detect(cancel);
        if cancel() {
            return Err(ManagementError::Cancelled);
        }
        let detected = environment::detect_tool(cli.command, cancel);
        if cancel() {
            return Err(ManagementError::Cancelled);
        }
        Ok(detected)
    })
}

fn finish_cli_update(
    cli: &AgentCli,
    previous: Option<&DetectedTool>,
    was_missing: bool,
    result: Result<(bool, String), RunError>,
    detect: impl FnOnce() -> Result<Option<DetectedTool>, ManagementError>,
) -> Result<CliUpdateResult, ManagementError> {
    let (success, output) = match result {
        Ok(completed) => completed,
        Err(RunError::Cancelled) => return Err(ManagementError::Cancelled),
        Err(RunError::TimedOut) => return Err(ManagementError::TimedOut),
        Err(RunError::Start(message)) => {
            return Err(ManagementError::Failed(format!(
                "Could not run the CLI updater: {message}"
            )))
        }
    };
    let detected = detect()?;
    let verified = verify_updated_cli(cli, detected);
    if !success {
        // An already usable CLI does not prove a failed update installed anything.
        let advanced = verified.as_ref().is_ok_and(|version| {
            previous.map_or(was_missing, |old| {
                !environment::version_at_least(&old.version, version)
            })
        });
        if !advanced {
            let verification = verified
                .err()
                .map(|error| format!("\n{}", error.message()))
                .unwrap_or_default();
            return Err(ManagementError::Failed(format!(
                "Could not update {} using its installation manager:\n{}{}",
                cli.name,
                tail(&output),
                verification
            )));
        }
    }
    Ok(CliUpdateResult {
        cli_version: verified?,
        updater_warning: (!success).then(|| tail(&output)),
    })
}

fn run_cli_updater(
    updater: &cli_update::UpdateCommand,
    path: Option<&std::ffi::OsStr>,
    cancel: &dyn Fn() -> bool,
    progress: &dyn Fn(InstallProgress),
) -> Result<(bool, String), RunError> {
    let mut command = Command::new(&updater.program);
    command.args(&updater.arguments);
    if let Some(path) = path {
        command.env("PATH", path);
    }
    if cancel() {
        return Err(RunError::Cancelled);
    }
    if updater.observes_npm {
        run_observed_npm(&mut command, cancel, progress)
    } else {
        progress(InstallProgress {
            stage: InstallStage::Updating,
            ..InstallProgress::preparing()
        });
        if cancel() {
            return Err(RunError::Cancelled);
        }
        command
            .env("HOMEBREW_NO_ASK", "1")
            .env("HOMEBREW_NO_ANALYTICS", "1");
        environment::run_bounded_status(&mut command, INSTALL_TIMEOUT, cancel)
    }
}

fn verify_updated_cli(
    cli: &AgentCli,
    detected: Option<DetectedTool>,
) -> Result<String, ManagementError> {
    let tool = detected.ok_or_else(|| ManagementError::Failed(format!(
        "The updater finished, but `{}` was not found on PATH. Check the CLI installation and PATH, then check again.", cli.command
    )))?;
    if !environment::version_at_least(&tool.version, cli.minimum_version) {
        return Err(ManagementError::Failed(format!(
            "The updater finished, but PATH still selects {} {} at {}. Version {} or later is required; check pinned versions and conflicting installations.",
            cli.name, tool.version, tool.path.display(), cli.minimum_version
        )));
    }
    Ok(tool.version)
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

#[cfg(test)]
fn run_npm_install(
    npm: &Path,
    prefix: &Path,
    agent: &CatalogAgent,
    cancel: &dyn Fn() -> bool,
) -> Result<(), ManagementError> {
    run_npm_install_observed(npm, prefix, agent, cancel, &|_| {})
}

fn run_npm_install_observed(
    npm: &Path,
    prefix: &Path,
    agent: &CatalogAgent,
    cancel: &dyn Fn() -> bool,
    progress: &dyn Fn(InstallProgress),
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
    match run_observed_npm(&mut command, cancel, progress) {
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
        .nth(OUTPUT_TAIL - 1)
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

    fn cli_tool(version: &str) -> DetectedTool {
        DetectedTool {
            version: version.into(),
            path: "/example/bin/codex".into(),
        }
    }

    #[test]
    fn cli_update_nonzero_exit_recovers_only_after_a_usable_version_advance() {
        let cli = codex().cli.as_ref().unwrap();
        let old = cli_tool("0.142.5");
        let log = "Download failed; retry completed";
        let result = finish_cli_update(cli, Some(&old), false, Ok((false, log.into())), || {
            Ok(Some(cli_tool("0.157.1")))
        })
        .unwrap();
        assert_eq!(result.cli_version, "0.157.1");
        assert_eq!(result.updater_warning.as_deref(), Some(log));
        let fresh = finish_cli_update(cli, None, true, Ok((false, log.into())), || {
            Ok(Some(cli_tool("0.157.1")))
        })
        .unwrap();
        assert_eq!(fresh.updater_warning.as_deref(), Some(log));
    }

    #[test]
    fn cli_update_nonzero_exit_preserves_failures_without_verified_progress() {
        let cli = codex().cli.as_ref().unwrap();
        // Already usable, numerically equivalent, older, absent, and still-too-old
        // versions must not turn an updater failure into success.
        for (before, after) in [
            ("0.157.1", Some("0.157.1")),
            ("0.157.1", Some("v0.157.1")),
            ("0.157.1", Some("0.156.1")),
            ("0.142.5", Some("0.150.0")),
            ("0.142.5", None),
        ] {
            let old = cli_tool(before);
            let result = finish_cli_update(
                cli,
                Some(&old),
                false,
                Ok((false, "installer failure".into())),
                || Ok(after.map(cli_tool)),
            );
            match result {
                Err(ManagementError::Failed(message)) => {
                    assert!(message.contains("installer failure"))
                }
                other => panic!("unverified update {before} -> {after:?}: {other:?}"),
            }
        }
    }

    #[test]
    fn cli_update_unknown_previous_version_cannot_prove_recovery() {
        let cli = codex().cli.as_ref().unwrap();
        // A failed version probe of an existing executable is not evidence it was absent.
        assert!(finish_cli_update(
            cli,
            None,
            false,
            Ok((false, "installer failure".into())),
            || Ok(Some(cli_tool("0.157.1")))
        )
        .is_err());
    }

    #[test]
    fn cli_update_clean_exit_still_verifies_path_without_a_warning() {
        let cli = codex().cli.as_ref().unwrap();
        let old = cli_tool("0.157.1");
        let result = finish_cli_update(
            cli,
            Some(&old),
            false,
            Ok((true, "already current".into())),
            || Ok(Some(cli_tool("0.157.1"))),
        )
        .unwrap();
        assert_eq!(result.updater_warning, None);
        for after in [None, Some("0.142.5")] {
            assert!(
                finish_cli_update(cli, Some(&old), false, Ok((true, String::new())), || Ok(
                    after.map(cli_tool)
                ))
                .is_err()
            );
        }
    }

    #[test]
    fn cli_update_cancel_timeout_and_start_failure_never_recover() {
        let cli = codex().cli.as_ref().unwrap();
        for (error, expected) in [
            (RunError::Cancelled, ManagementError::Cancelled),
            (RunError::TimedOut, ManagementError::TimedOut),
            (
                RunError::Start("not executable".into()),
                ManagementError::Failed("Could not run the CLI updater: not executable".into()),
            ),
        ] {
            assert_eq!(
                finish_cli_update(cli, None, true, Err(error), || panic!(
                    "must not probe after an incomplete update"
                )),
                Err(expected)
            );
        }
        assert_eq!(
            finish_cli_update(cli, None, true, Ok((false, String::new())), || Err(
                ManagementError::Cancelled
            )),
            Err(ManagementError::Cancelled)
        );
    }

    #[test]
    fn cli_update_recovery_keeps_only_the_bounded_log_tail() {
        let cli = codex().cli.as_ref().unwrap();
        let result = finish_cli_update(
            cli,
            None,
            true,
            Ok((false, "界".repeat(OUTPUT_TAIL + 100))),
            || Ok(Some(cli_tool("0.157.1"))),
        )
        .unwrap();
        assert_eq!(result.updater_warning.unwrap().chars().count(), OUTPUT_TAIL);
    }

    #[test]
    fn external_cli_update_runs_owned_arguments_and_checks_the_selected_version() {
        let root = temp_directory("external-updater");
        struct Cleanup(PathBuf);
        impl Drop for Cleanup {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
        let _cleanup = Cleanup(root.clone());
        let manager = fake_npm(&root, true);
        std::fs::write(&manager, "#!/bin/sh\nprintf '%s\\n' \"$@\"\n").unwrap();
        let updater = cli_update::UpdateCommand {
            program: manager,
            arguments: vec![
                "upgrade".into(),
                "--cask".into(),
                "codex; literal argument".into(),
            ],
            observes_npm: false,
        };
        let progress = std::cell::RefCell::new(Vec::new());
        let (success, output) = run_cli_updater(&updater, None, &|| false, &|p| {
            progress.borrow_mut().push(p)
        })
        .unwrap();
        assert!(success);
        assert_eq!(
            output.lines().collect::<Vec<_>>(),
            ["upgrade", "--cask", "codex; literal argument"]
        );
        assert_eq!(progress.borrow()[0].stage, InstallStage::Updating);
        assert_eq!(progress.borrow()[0].downloaded_bytes, 0);
        let cli = codex().cli.as_ref().unwrap();
        let detected = |version: &str| {
            Some(DetectedTool {
                version: version.into(),
                path: root.join("codex"),
            })
        };
        assert!(
            verify_updated_cli(cli, detected("0.142.5")).is_err(),
            "an old CLI earlier in PATH cannot become success"
        );
        assert_eq!(
            verify_updated_cli(cli, detected("0.156.1")).unwrap(),
            "0.156.1"
        );
        assert!(verify_updated_cli(cli, None).is_err());
        let cancelled = std::cell::Cell::new(false);
        let result = run_cli_updater(&updater, None, &|| cancelled.get(), &|_| {
            cancelled.set(true)
        });
        assert_eq!(result, Err(RunError::Cancelled));
    }

    #[test]
    fn live_npm_progress_arrives_before_cancel_and_preserves_cancellation() {
        use std::sync::atomic::{AtomicBool, Ordering};
        // A fake npm reports bytes, then stays alive until the observer cancels.
        // No network, installed npm, or sleep is needed to control this sequence.
        let root = temp_directory("progress-cancel");
        struct Cleanup(PathBuf);
        impl Drop for Cleanup {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
        let _cleanup = Cleanup(root.clone());
        let npm = fake_npm(&root, true);
        std::fs::write(&npm, r#"#!/bin/sh
printf '%s\n' 'LITHE_NPM_PROGRESS {"stage":"downloading","downloadedBytes":1234,"bytesPerSecond":123,"elapsedMilliseconds":1000,"idleMilliseconds":0}'
while :; do :; done
"#).unwrap();
        let cancelled = AtomicBool::new(false);
        let received = std::cell::RefCell::new(Vec::new());
        // If the observer regresses, stop the fake child locally rather than
        // leaving it running until the production install timeout.
        let deadline = std::time::Instant::now() + Duration::from_secs(3);
        let result = run_npm_install_observed(
            &npm,
            &root,
            codex(),
            &|| cancelled.load(Ordering::SeqCst) || std::time::Instant::now() >= deadline,
            &|event| {
                received.borrow_mut().push(event);
                cancelled.store(true, Ordering::SeqCst);
            },
        );
        assert!(matches!(result, Err(ManagementError::Cancelled)));
        assert_eq!(received.borrow().len(), 1);
        assert_eq!(received.borrow()[0].downloaded_bytes, 1234);
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
