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
    /// Whether the owning package manager confirmed a newer CLI release.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub update_available: Option<bool>,
    /// Bounded read-only probe failure; absence of a protocol is not a failed probe.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub update_check_error: Option<String>,
    /// Target version returned by the same read-only package-manager query.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub available_version: Option<String>,
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
                update_check_error: None,
                available_version: None,
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
                update_check_error: None,
                available_version: None,
            },
            command: Some(UpdateCommand {
                program: program.into(),
                arguments,
                observes_npm,
            }),
        }
    }
}

/// A confirmed availability result and its package-manager target, when provided.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct UpdateCheck {
    pub available: bool,
    pub version: Option<String>,
}

/// Ask the verified owner whether it can actually upgrade this CLI. A failed
/// read-only check is unknown, never evidence of a newer release.
pub(crate) fn update_available(
    plan: &UpdatePlan,
    installed: &str,
    path: Option<&OsStr>,
    cancel: &dyn Fn() -> bool,
) -> Result<Option<UpdateCheck>, ManagementError> {
    let Some(command) = plan.command.as_ref() else {
        return Ok(None);
    };
    // Query the same package/channel the verified updater will use. New catalog
    // agents reuse this path without a command-name allowlist.
    let package = match plan.installation.source {
        CliSource::Npm => command
            .arguments
            .last()
            .map(String::as_str)
            .ok_or_else(|| ManagementError::Failed("Missing npm update target".into()))?,
        CliSource::Homebrew => command
            .arguments
            .get(2)
            .map(String::as_str)
            .ok_or_else(|| ManagementError::Failed("Missing Homebrew update target".into()))?,
        // Native installers have no shared read-only version protocol. Do not
        // run an updater as a probe or substitute another channel's version.
        _ => return Ok(None),
    };
    let args: Vec<&str> = match plan.installation.source {
        CliSource::Npm => vec![
            "view",
            package,
            "version",
            "--json",
            "--fetch-retries=0",
            "--fetch-timeout=2500",
        ],
        CliSource::Homebrew => vec![
            "outdated",
            command
                .arguments
                .get(1)
                .map(String::as_str)
                .ok_or_else(|| ManagementError::Failed("Missing Homebrew package kind".into()))?,
            "--json=v2",
            package,
        ],
        _ => return Ok(None),
    };
    let mut probe = Command::new(&command.program);
    probe.args(args);
    if let Some(path) = path {
        probe.env("PATH", path);
    }
    if plan.installation.source == CliSource::Homebrew {
        probe.env("HOMEBREW_NO_AUTO_UPDATE", "1");
    }
    let (success, output, diagnostics) =
        environment::run_bounded_status_separated(&mut probe, Duration::from_secs(5), cancel)
            .map_err(|error| match error {
                RunError::Cancelled => ManagementError::Cancelled,
                RunError::TimedOut => ManagementError::Failed("The update check timed out".into()),
                RunError::Start(message) => ManagementError::Failed(message),
            })?;
    let available = parse_update_available(&plan.installation.source, package, installed, &output);
    // Homebrew exits nonzero when a named package is outdated; require a valid positive result.
    if !success
        && !(plan.installation.source == CliSource::Homebrew
            && available.as_ref().is_some_and(|check| check.available))
    {
        let reason = if diagnostics.trim().is_empty() {
            output.trim()
        } else {
            diagnostics.trim()
        };
        let reason = if reason.is_empty() {
            "The package manager exited unsuccessfully without diagnostics."
        } else {
            reason
        };
        return Err(ManagementError::Failed(format!(
            "Update check failed: {reason}"
        )));
    }
    available.map(Some).ok_or_else(|| {
        ManagementError::Failed("The package manager returned an invalid version response".into())
    })
}

fn parse_update_available(
    source: &CliSource,
    package: &str,
    installed: &str,
    output: &str,
) -> Option<UpdateCheck> {
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
            Some(UpdateCheck {
                available: environment::newer_version_available(installed, latest)?,
                version: Some(latest.to_owned()),
            })
        }
        CliSource::Homebrew => {
            let value: serde_json::Value = serde_json::from_str(output).ok()?;
            let packages = value["casks"]
                .as_array()?
                .iter()
                .chain(value["formulae"].as_array()?);
            let mut target = None;
            for entry in packages {
                if entry["name"].as_str()? == package {
                    target = Some(entry);
                }
            }
            Some(UpdateCheck {
                available: target.is_some(),
                version: target
                    .and_then(|entry| entry["current_version"].as_str())
                    .filter(|v| !v.trim().is_empty())
                    .map(str::to_owned),
            })
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
mod update_tests {
    use super::*;

    #[test]
    fn update_targets_are_retained_for_every_package_and_manager() {
        for package in ["codex", "claude-code@latest", "future-agent"] {
            let npm =
                parse_update_available(&CliSource::Npm, package, "2.0.0", r#""3.0.0""#).unwrap();
            assert_eq!(
                npm,
                UpdateCheck {
                    available: true,
                    version: Some("3.0.0".into())
                }
            );
            let current =
                parse_update_available(&CliSource::Npm, package, "4.0.0", r#""3.0.0""#).unwrap();
            assert!(!current.available);
            assert_eq!(current.version.as_deref(), Some("3.0.0"));
            for kind in ["casks", "formulae"] {
                let mut output = serde_json::json!({"casks": [], "formulae": []});
                output[kind] = serde_json::json!([
                    {"name": "unrelated", "current_version": "99.0.0"},
                    {"name": package, "current_version": "3.0.0"}
                ]);
                let check = parse_update_available(
                    &CliSource::Homebrew,
                    package,
                    "2.0.0",
                    &output.to_string(),
                )
                .unwrap();
                assert_eq!(
                    check,
                    UpdateCheck {
                        available: true,
                        version: Some("3.0.0".into())
                    }
                );
                output[kind][1]
                    .as_object_mut()
                    .unwrap()
                    .remove("current_version");
                let unknown = parse_update_available(
                    &CliSource::Homebrew,
                    package,
                    "2.0.0",
                    &output.to_string(),
                )
                .unwrap();
                assert!(unknown.available);
                assert_eq!(unknown.version, None);
            }
        }
    }

    #[test]
    fn confirmed_updates_only_when_the_owner_reports_one() {
        for output in [r#""0.160.0""#, r#"["0.160.0"]"#] {
            assert_eq!(
                parse_update_available(&CliSource::Npm, "@openai/codex@latest", "0.159.3", output)
                    .map(|check| check.available),
                Some(true)
            );
        }
        for output in ["[]", r#"["0.159.3","0.160.0"]"#, "[42]", r#"["invalid"]"#] {
            assert_eq!(
                parse_update_available(&CliSource::Npm, "@openai/codex@latest", "0.159.3", output)
                    .map(|check| check.available),
                None
            );
        }
        assert_eq!(
            parse_update_available(
                &CliSource::Npm,
                "@openai/codex@latest",
                "0.159.3",
                "\"0.159.3\""
            )
            .map(|check| check.available),
            Some(false)
        );
        assert_eq!(
            parse_update_available(
                &CliSource::Npm,
                "@openai/codex@latest",
                "0.159.3",
                "\"0.160.0\""
            )
            .map(|check| check.available),
            Some(true)
        );
        assert_eq!(
            parse_update_available(
                &CliSource::Npm,
                "@openai/codex@latest",
                "0.159.3-beta.1",
                "\"0.159.3\""
            )
            .map(|check| check.available),
            Some(true)
        );
        assert_eq!(
            parse_update_available(
                &CliSource::Npm,
                "@openai/codex@latest",
                "0.159.3",
                "network error"
            )
            .map(|check| check.available),
            None
        );
        assert_eq!(
            parse_update_available(&CliSource::Npm, "@openai/codex@latest", "0.159.3", "\"\"")
                .map(|check| check.available),
            None
        );
        assert_eq!(
            parse_update_available(
                &CliSource::Homebrew,
                "codex",
                "0.159.3",
                r#"{"casks":[],"formulae":[]}"#
            )
            .map(|check| check.available),
            Some(false)
        );
        assert_eq!(
            parse_update_available(
                &CliSource::Homebrew,
                "codex",
                "0.159.3",
                r#"{"casks":[{"name":"codex"}],"formulae":[]}"#
            )
            .map(|check| check.available),
            Some(true)
        );
        assert_eq!(
            parse_update_available(
                &CliSource::Homebrew,
                "codex",
                "0.159.3",
                r#"{"casks":[],"formulae":[{"name":"codex"}]}"#
            )
            .map(|check| check.available),
            Some(true)
        );
        assert_eq!(
            parse_update_available(&CliSource::Homebrew, "codex", "0.159.3", "error")
                .map(|check| check.available),
            None
        );
    }
}
