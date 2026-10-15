//! Identify the installation owning the active CLI before selecting an updater.
//! Package managers retain their fetching, validation, cache and release channels.

use std::ffi::OsStr;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::catalog::AgentCli;
use crate::environment::{self, RunError, RuntimeEnvironment};
use crate::install::ManagementError;

const PROBE_TIMEOUT: Duration = Duration::from_secs(3);
pub(crate) const MANUAL_HINT: &str =
    "Update this CLI using its original installer, then check again.";

/// Installation provenance of the executable selected by the launch PATH.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum CliSource {
    Npm,
    Homebrew,
    Native,
    Missing,
    Unknown,
}

/// Presentation facts; hosts must not execute the displayed update hint.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct CliInstallation {
    pub source: CliSource,
    pub can_update: bool,
    pub update_hint: String,
    /// Whether the owning package manager confirmed a newer Codex release.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub update_available: Option<bool>,
}

/// An owned executable and arguments, never an interpolated shell command.
#[derive(Debug)]
pub(crate) struct UpdateCommand {
    pub program: PathBuf,
    pub arguments: Vec<String>,
    pub observes_npm: bool,
}

/// Freshly resolved ownership evidence and the permitted updater, if any.
#[derive(Debug)]
pub(crate) struct UpdatePlan {
    pub installation: CliInstallation,
    pub command: Option<UpdateCommand>,
}

impl UpdatePlan {
    fn manual(source: CliSource, hint: &str) -> Self {
        Self {
            installation: CliInstallation {
                source,
                can_update: false,
                update_hint: hint.into(),
                update_available: None,
            },
            command: None,
        }
    }

    fn automatic(
        source: CliSource,
        hint: String,
        program: &Path,
        arguments: Vec<String>,
        observes_npm: bool,
    ) -> Self {
        Self {
            installation: CliInstallation {
                source,
                can_update: true,
                update_hint: hint,
                update_available: None,
            },
            command: Some(UpdateCommand {
                program: program.into(),
                arguments,
                observes_npm,
            }),
        }
    }
}

/// Ask the verified owner whether it can actually upgrade Codex. A failed
/// read-only check is unknown, never evidence of a newer release.
pub(crate) fn codex_update_available(
    plan: &UpdatePlan,
    installed: &str,
    path: Option<&OsStr>,
    cancel: &dyn Fn() -> bool,
) -> Option<bool> {
    let command = plan.command.as_ref()?;
    let args: &[&str] = match plan.installation.source {
        CliSource::Npm => &[
            "view",
            "@openai/codex",
            "version",
            "--json",
            "--fetch-retries=0",
            "--fetch-timeout=2500",
        ],
        CliSource::Homebrew => &[
            "outdated",
            command.arguments.get(1)?.as_str(),
            "--json=v2",
            "codex",
        ],
        _ => return None,
    };
    let mut probe = Command::new(&command.program);
    probe.args(args);
    if let Some(path) = path {
        probe.env("PATH", path);
    }
    if plan.installation.source == CliSource::Homebrew {
        probe.env("HOMEBREW_NO_AUTO_UPDATE", "1");
    }
    let (success, output, _diagnostics) =
        environment::run_bounded_status_separated(&mut probe, Duration::from_secs(5), cancel)
            .ok()?;
    let available = parse_codex_update_available(&plan.installation.source, installed, &output)?;
    // Homebrew exits nonzero when a named package is outdated. Only a valid
    // positive result explains that exit; other failures remain unknown.
    (success || (plan.installation.source == CliSource::Homebrew && available)).then_some(available)
}

fn parse_codex_update_available(source: &CliSource, installed: &str, output: &str) -> Option<bool> {
    match source {
        CliSource::Npm => {
            let value: serde_json::Value = serde_json::from_str(output.trim()).ok()?;
            let latest = match &value {
                serde_json::Value::String(version) => version.as_str(),
                serde_json::Value::Array(versions) if versions.len() == 1 => {
                    versions[0].as_str()?
                }
                _ => return None,
            };
            let components: Vec<_> = latest.split('.').collect();
            if components.len() != 3 || components.iter().any(|part| part.parse::<u64>().is_err()) {
                return None;
            }
            // The existing numeric comparison ignores pre-release suffixes;
            // an installed prerelease of the same numeric version is older.
            Some(
                !environment::version_at_least(installed, latest)
                    || (installed.contains('-')
                        && !latest.contains('-')
                        && environment::version_at_least(latest, installed)),
            )
        }
        CliSource::Homebrew => {
            let value: serde_json::Value = serde_json::from_str(output).ok()?;
            let names = value["casks"]
                .as_array()?
                .iter()
                .chain(value["formulae"].as_array()?)
                .map(|package| package["name"].as_str())
                .collect::<Option<Vec<_>>>()?;
            Some(names.contains(&"codex"))
        }
        _ => None,
    }
}

/// Resolve actual PATH ownership on every click; GUI status is never authority to mutate.
pub(crate) fn detect(
    cli: &AgentCli,
    runtime: &RuntimeEnvironment,
    cancel: &dyn Fn() -> bool,
) -> Result<UpdatePlan, ManagementError> {
    if cancel() {
        return Err(ManagementError::Cancelled);
    }
    let path = environment::search_path();
    let executable = environment::find_executable(cli.command, path.as_deref());
    // A broken symlink or non-executable command is still an existing installation.
    let existing = executable.or_else(|| {
        std::env::split_paths(path.as_deref().unwrap_or(OsStr::new("")))
            .map(|directory| directory.join(cli.command))
            .find(|candidate| std::fs::symlink_metadata(candidate).is_ok())
    });
    let brew = existing
        .as_ref()
        .and_then(|file| file.parent())
        .and_then(|directory| std::env::join_paths([directory]).ok())
        .and_then(|path| environment::find_executable("brew", Some(&path)))
        .or_else(|| environment::find_executable("brew", path.as_deref()));
    let home = std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from);
    resolve(
        cli,
        existing.as_deref(),
        runtime.npm.as_ref().map(|tool| tool.path.as_path()),
        brew.as_deref(),
        home.as_deref(),
        &|program, args| {
            let mut command = Command::new(program);
            command
                .args(args)
                .env("HOMEBREW_NO_AUTO_UPDATE", "1")
                .env("HOMEBREW_NO_ANALYTICS", "1");
            if let Some(path) = &path {
                command.env("PATH", path);
            }
            environment::run_bounded(command, PROBE_TIMEOUT, cancel)
        },
    )
}

fn query(
    probe: &dyn Fn(&Path, &[&str]) -> Result<String, RunError>,
    program: &Path,
    args: &[&str],
) -> Result<Option<String>, ManagementError> {
    match probe(program, args) {
        Ok(output) => Ok(Some(output.trim().into())),
        Err(RunError::Start(_)) => Ok(None),
        Err(RunError::Cancelled) => Err(ManagementError::Cancelled),
        Err(RunError::TimedOut) => Err(ManagementError::TimedOut),
    }
}

/// Filesystem identity and read-only manager probes are injected for deterministic tests.
fn resolve(
    cli: &AgentCli,
    executable: Option<&Path>,
    npm: Option<&Path>,
    brew: Option<&Path>,
    home: Option<&Path>,
    probe: &dyn Fn(&Path, &[&str]) -> Result<String, RunError>,
) -> Result<UpdatePlan, ManagementError> {
    let target = executable.and_then(|path| path.canonicalize().ok());
    if executable.is_some() && target.is_none() {
        return Ok(UpdatePlan::manual(CliSource::Unknown, MANUAL_HINT));
    }
    if let (Some(target), Some(brew)) = (&target, brew) {
        for (root_option, kind) in [("--caskroom", "--cask"), ("--cellar", "--formula")] {
            let Some(root) = query(probe, brew, &[root_option])?
                .and_then(|root| Path::new(&root).canonicalize().ok())
            else {
                continue;
            };
            let Some(package) = target
                .strip_prefix(&root)
                .ok()
                .and_then(|relative| relative.components().next())
                .and_then(|component| component.as_os_str().to_str())
            else {
                continue;
            };
            if !cli.brew_packages.contains(&package) {
                continue;
            }
            let installed = query(probe, brew, &["list", kind, "--versions", package])?;
            if installed.as_deref().is_some_and(|output| {
                output.lines().any(|line| {
                    let mut fields = line.split_whitespace();
                    fields.next() == Some(package) && fields.next().is_some()
                })
            }) {
                return Ok(UpdatePlan::automatic(
                    CliSource::Homebrew,
                    format!("brew upgrade {kind} {package}"),
                    brew,
                    vec!["upgrade".into(), kind.into(), package.into()],
                    false,
                ));
            }
            // A manager-owned path without its receipt must never fall back to npm.
            return Ok(UpdatePlan::manual(CliSource::Homebrew, MANUAL_HINT));
        }
    }
    if let (Some(executable), Some(target), Some(home)) = (executable, &target, home) {
        let launcher = home.join(".local/bin/claude");
        let versions = home
            .join(".local/share/claude/versions")
            .canonicalize()
            .ok();
        if cli.command == "claude"
            && executable == launcher
            && std::fs::read_link(executable).is_ok()
            && versions.is_some_and(|versions| target.parent() == Some(versions.as_path()))
        {
            return Ok(UpdatePlan::automatic(
                CliSource::Native,
                "claude update".into(),
                executable,
                vec!["update".into()],
                false,
            ));
        }
    }
    let npm_owned = target.as_ref().is_some_and(|target| {
        target.ancestors().any(|root| {
            root.file_name().is_some_and(|name| name == "node_modules")
                && owns_npm_bin(&root.join(cli.package), cli, target)
        })
    });
    let source = if executable.is_none() {
        CliSource::Missing
    } else if npm_owned {
        CliSource::Npm
    } else {
        CliSource::Unknown
    };
    if executable.is_some() && !npm_owned {
        return Ok(UpdatePlan::manual(source, MANUAL_HINT));
    }
    let Some(npm) = npm else {
        return Ok(UpdatePlan::manual(source, MANUAL_HINT));
    };
    let Some(prefix) = query(probe, npm, &["prefix", "--global"])? else {
        return Ok(UpdatePlan::manual(source, MANUAL_HINT));
    };
    let prefix = PathBuf::from(prefix);
    if !prefix.is_absolute() {
        return Ok(UpdatePlan::manual(source, MANUAL_HINT));
    }
    let bin = if cfg!(windows) {
        prefix.join(format!("{}.cmd", cli.command))
    } else {
        prefix.join("bin").join(cli.command)
    };
    if let Some(target) = &target {
        let Some(root) = query(probe, npm, &["root", "--global"])? else {
            return Ok(UpdatePlan::manual(source, MANUAL_HINT));
        };
        let Ok(root) = Path::new(&root).canonicalize() else {
            return Ok(UpdatePlan::manual(source, MANUAL_HINT));
        };
        let package = root.join(cli.package);
        if !package
            .canonicalize()
            .is_ok_and(|package| package.starts_with(&root))
            || !owns_npm_bin(&package, cli, target)
            || bin.canonicalize().ok().as_ref() != Some(target)
        {
            return Ok(UpdatePlan::manual(CliSource::Npm,
                "Switch to the Node.js/npm environment that installed this CLI, update it there, then check again."));
        }
    } else if std::fs::symlink_metadata(&bin).is_ok() {
        return Ok(UpdatePlan::manual(CliSource::Unknown, MANUAL_HINT));
    }
    Ok(UpdatePlan::automatic(
        source,
        cli.install_hint.into(),
        npm,
        vec![
            "install".into(),
            "-g".into(),
            "--no-audit".into(),
            "--no-fund".into(),
            "--loglevel=error".into(),
            format!("{}@latest", cli.package),
        ],
        true,
    ))
}

fn owns_npm_bin(package: &Path, cli: &AgentCli, target: &Path) -> bool {
    let manifest = (|| {
        let file = std::fs::File::open(package.join("package.json")).ok()?;
        let mut bytes = Vec::new();
        file.take(64 * 1024).read_to_end(&mut bytes).ok()?;
        serde_json::from_slice::<serde_json::Value>(&bytes).ok()
    })();
    let Some(manifest) = manifest else {
        return false;
    };
    if manifest["name"] != cli.package {
        return false;
    }
    let Some(bin) = manifest["bin"]
        .get(cli.command)
        .unwrap_or(&manifest["bin"])
        .as_str()
    else {
        return false;
    };
    let Ok(package_root) = package.canonicalize() else {
        return false;
    };
    package
        .join(bin)
        .canonicalize()
        .is_ok_and(|bin| bin.starts_with(package_root) && bin == target)
}

#[cfg(all(test, unix))]
mod tests;

#[cfg(test)]
mod codex_update_tests {
    use super::*;

    #[test]
    fn confirmed_codex_updates_only_when_the_owner_reports_one() {
        for output in [r#""0.160.0""#, r#"["0.160.0"]"#] {
            assert_eq!(
                parse_codex_update_available(&CliSource::Npm, "0.159.3", output),
                Some(true)
            );
        }
        for output in ["[]", r#"["0.159.3","0.160.0"]"#, "[42]", r#"["invalid"]"#] {
            assert_eq!(
                parse_codex_update_available(&CliSource::Npm, "0.159.3", output),
                None
            );
        }
        assert_eq!(
            parse_codex_update_available(&CliSource::Npm, "0.159.3", "\"0.159.3\""),
            Some(false)
        );
        assert_eq!(
            parse_codex_update_available(&CliSource::Npm, "0.159.3", "\"0.160.0\""),
            Some(true)
        );
        assert_eq!(
            parse_codex_update_available(&CliSource::Npm, "0.159.3-beta.1", "\"0.159.3\""),
            Some(true)
        );
        assert_eq!(
            parse_codex_update_available(&CliSource::Npm, "0.159.3", "network error"),
            None
        );
        assert_eq!(
            parse_codex_update_available(&CliSource::Npm, "0.159.3", "\"\""),
            None
        );
        assert_eq!(
            parse_codex_update_available(
                &CliSource::Homebrew,
                "0.159.3",
                r#"{"casks":[],"formulae":[]}"#
            ),
            Some(false)
        );
        assert_eq!(
            parse_codex_update_available(
                &CliSource::Homebrew,
                "0.159.3",
                r#"{"casks":[{"name":"codex"}],"formulae":[]}"#
            ),
            Some(true)
        );
        assert_eq!(
            parse_codex_update_available(
                &CliSource::Homebrew,
                "0.159.3",
                r#"{"casks":[],"formulae":[{"name":"codex"}]}"#
            ),
            Some(true)
        );
        assert_eq!(
            parse_codex_update_available(&CliSource::Homebrew, "0.159.3", "error"),
            None
        );
    }
}
