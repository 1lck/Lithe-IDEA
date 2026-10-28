//! Which executable runs a build system, and whether a probed version is
//! new enough.
//!
//! Core orders and filters the candidates; the host checks which exists,
//! resolves bare commands through its tool discovery, and runs the probes.
//! A project-file candidate (a wrapper script) always counts as running
//! project code, so a host can ask for workspace trust before using it.

use super::decode::{self, join_relative};
use super::manifest::{
    BuildSystemDeclaration, ExecutableCandidate, ExecutableSource, Platform, RuntimeDependency,
    VersionProbe,
};
use crate::plugins::declarative::{
    reported_version, validate_minimum_version, version_components, DeclarativePluginManifest,
    PluginRejection, Validation,
};
use crate::plugins::executables::ordered_indices;
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::BTreeMap;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct InvocationRequest {
    /// Instance root, workspace-relative.
    pub(crate) root: String,
    pub(crate) platform: Platform,
    /// Global plugin settings. Project files cannot select a local executable.
    #[serde(default)]
    pub(crate) settings: BTreeMap<String, Value>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct VersionCheckRequest {
    /// A declared runtime dependency; the build tool itself when absent.
    #[serde(default)]
    pub(crate) runtime: Option<String>,
    /// Combined stdout and stderr of the probe.
    pub(crate) output: String,
}

fn candidates(
    candidates: &[ExecutableCandidate],
    root: &str,
    platform: Platform,
    manifest: &DeclarativePluginManifest,
    settings: &BTreeMap<String, Value>,
) -> Validation<Vec<Value>> {
    ordered_indices(candidates, "executables")?.into_iter()
        .filter(|&index| candidates[index].platforms.is_empty() || candidates[index].platforms.contains(&platform))
        .map(|index| {
            let candidate = &candidates[index];
            Ok(match &candidate.source {
                ExecutableSource::ProjectFile { path, requires } => json!({
                    "kind": "projectFile", "path": join_relative(root, path),
                    "requires": requires.iter().map(|file| join_relative(root, file)).collect::<Vec<_>>(), "executesProjectCode": true,
                }),
                ExecutableSource::Environment { variable, path } => json!({ "kind": "environment", "variable": variable, "path": path }),
                ExecutableSource::Command { command } => json!({ "kind": "command", "command": command }),
                ExecutableSource::Runtime { runtime } => json!({ "kind": "runtime", "runtime": runtime }),
                ExecutableSource::Toolchain { toolchain_id } => json!({ "kind": "toolchain", "toolchainID": toolchain_id, "root": root }),
                ExecutableSource::Setting { setting_id } => json!({ "kind": "setting", "settingID": setting_id,
                    "path": manifest.executable_setting_value(setting_id, settings)? }),
            })
        }).collect()
}

/// Arguments that make a host-managed runtime print its version and exit.
/// Core owns them so hosts use the same probe, for build runtimes and for
/// plugin launch runtimes alike. Java needs `-version` for
/// Java 8 compatibility; its version is printed to stderr, which hosts must
/// capture together with stdout before checking the declared minimum.
pub(crate) fn host_runtime_version_arguments(id: &str) -> Option<&'static [&'static str]> {
    match id {
        "go" => Some(&["version"]),
        "java" => Some(&["-version"]),
        "node" => Some(&["--version"]),
        _ => None,
    }
}

fn runtime(
    runtime: &RuntimeDependency,
    root: &str,
    platform: Platform,
    manifest: &DeclarativePluginManifest,
    settings: &BTreeMap<String, Value>,
) -> Validation<Value> {
    let version = if runtime.is_host_managed() {
        host_runtime_version_arguments(&runtime.id)
            .map(|arguments| json!({ "arguments": arguments }))
    } else {
        runtime
            .version
            .as_ref()
            .map(|probe| json!({ "arguments": probe.arguments }))
    };
    Ok(json!({
        "id": runtime.id,
        "displayName": runtime.display_name,
        "hostManaged": runtime.is_host_managed(),
        "minimumVersion": runtime.minimum_version,
        "executables": candidates(&runtime.executables, root, platform, manifest, settings)?,
        "version": version,
    }))
}

/// `build.invocationPlan`: the candidates for this platform, in order, with
/// what the host must probe.
pub(crate) fn invocation_plan(
    build_system: &BuildSystemDeclaration,
    request: &InvocationRequest,
    manifest: &DeclarativePluginManifest,
) -> Validation<Value> {
    let root = decode::request_path(&request.root, "root")?;
    let invocation = &build_system.invocation;
    let mut executables = candidates(
        &invocation.executables,
        &root,
        request.platform,
        manifest,
        &request.settings,
    )?;
    // Published v2 preview manifests adapt into the same candidate path.
    if let Some(id) = &invocation.executable_setting {
        executables.insert(0, json!({ "kind": "setting", "settingID": id, "path": manifest.executable_setting_value(id, &request.settings)? }));
    }
    if executables.is_empty() {
        return Err(PluginRejection::new(
            "plugin.build.unavailable",
            format!(
                "{} declares no executable for this platform.",
                build_system.display_name
            ),
        ));
    }
    Ok(json!({
        "buildSystemID": build_system.id,
        "root": root,
        "executables": executables,
        "environmentInputs": invocation.environment_inputs,
        "runtimeDependencies": invocation
            .runtime_dependencies
            .iter()
            .map(|dependency| runtime(dependency, &root, request.platform, manifest, &request.settings))
            .collect::<Validation<Vec<_>>>()?,
        "version": invocation.version.as_ref().map(|probe| json!({ "arguments": probe.arguments })),
        "minimumVersion": invocation.minimum_version,
    }))
}

/// `build.checkToolVersion`: reads the probe output of the build tool or of
/// one of its runtimes and compares it with the declared minimum.
pub(crate) fn check_version(
    build_system: &BuildSystemDeclaration,
    request: &VersionCheckRequest,
) -> Validation<Value> {
    let (found, minimum) = match &request.runtime {
        None => {
            let probe = build_system.invocation.version.as_ref().ok_or_else(|| {
                PluginRejection::new(
                    "plugin.build.unavailable",
                    format!("{} declares no version probe.", build_system.display_name),
                )
            })?;
            (
                probe.version(&request.output),
                build_system.invocation.minimum_version.as_deref(),
            )
        }
        Some(id) => {
            let dependency = build_system
                .invocation
                .runtime_dependencies
                .iter()
                .find(|dependency| &dependency.id == id)
                .ok_or_else(|| {
                    PluginRejection::new(
                        "plugin.build.invalidSelection",
                        format!("{} declares no runtime {id}.", build_system.display_name),
                    )
                })?;
            let found = if dependency.is_host_managed() {
                reported_version(&dependency.id, &request.output)
            } else {
                dependency
                    .version
                    .as_ref()
                    .and_then(|probe: &VersionProbe| probe.version(&request.output))
            };
            (found, dependency.minimum_version.as_deref())
        }
    };
    let version = found.as_ref().map(|components| {
        components
            .iter()
            .map(u64::to_string)
            .collect::<Vec<_>>()
            .join(".")
    });
    let Some(minimum) = minimum else {
        return Ok(json!({ "satisfied": true, "version": version }));
    };
    validate_minimum_version(minimum, "minimumVersion")?;
    let minimum = version_components(minimum);
    let Some(found) = found else {
        return Ok(json!({ "satisfied": false }));
    };
    // Only the components the requirement names are compared, as for
    // language-server runtimes: `8.5` accepts every 8.5.x.
    let mut padded = found;
    padded.resize(minimum.len().max(padded.len()), 0);
    Ok(json!({
        "satisfied": padded[..minimum.len()] >= minimum[..],
        "version": version,
    }))
}
