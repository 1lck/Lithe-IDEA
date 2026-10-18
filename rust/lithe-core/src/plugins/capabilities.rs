//! Capability versions of declarative plugin API level 3.
//!
//! Levels 1 and 2 version a manifest as one unit: a change to any section
//! raised the level of every plugin and hid plugins that never use that
//! section from older hosts. Level 3 versions each section on its own. A
//! manifest lists in `requires` exactly the capabilities it uses, each with
//! the version of that capability's contract it was written against, so a
//! plugin without build systems never depends on the build-system contract
//! and a new build-system version only affects plugins that opt into it.
//!
//! `requires` is checked before the sections are decoded, so a Core build
//! that does not know a capability reports which one is missing instead of
//! an unknown field. Hosts state the capability versions they implement in
//! `hostCapabilities`; validating a section is not the same as running it.
//!
//! Note: the decision is recorded in .agents/notes/implemented/architecture/2026-10-17-plugin-capability-versions.md

use super::declarative::{PluginRejection, Validation};
use serde_json::Value;
use std::collections::{BTreeMap, BTreeSet};

/// First plugin API level whose manifests declare capability versions.
pub(crate) const CAPABILITIES_API_VERSION: u32 = 3;

/// `languages[]`: file types and project markers.
pub(crate) const LANGUAGES: &str = "languages";
/// `languageServers[]` apart from their launch fields.
pub(crate) const LANGUAGE_SERVERS: &str = "languageServers";
/// The launch fields language servers and own build providers share.
pub(crate) const SERVER_PROCESS: &str = "serverProcess";
/// `executionProviders[]`: run and test templates.
pub(crate) const EXECUTION_PROVIDERS: &str = "executionProviders";
/// `settings[]`.
pub(crate) const SETTINGS: &str = "settings";
/// `ui`: tool windows and commands. Version 2 adds web content in a tool
/// window.
pub(crate) const UI: &str = "ui";
/// Declarative build detection, models, and command plans.
pub(crate) const BUILD_SYSTEMS: &str = "buildSystems";
/// `buildSystems[].provider`, whether it owns or shares a language server process.
pub(crate) const BUILD_PROVIDERS: &str = "buildProviders";

/// Capability versions this Core build validates and plans. Version 1 of a
/// capability keeps the meaning its section had at API level 2.
pub const SUPPORTED_CAPABILITIES: &[(&str, &[u32])] = &[
    (BUILD_PROVIDERS, &[1]),
    (BUILD_SYSTEMS, &[1]),
    (EXECUTION_PROVIDERS, &[1]),
    (LANGUAGE_SERVERS, &[1]),
    (LANGUAGES, &[1]),
    (SERVER_PROCESS, &[1]),
    (SETTINGS, &[1]),
    (UI, &[1, 2]),
];

/// Longest capability ID, so a hostile index cannot grow host state.
const MAX_CAPABILITY_ID: usize = 64;

/// Capability ID to the contract version a plugin was written against.
pub(crate) type Requires = BTreeMap<String, u32>;

/// Capability ID to the versions a host implements, as the host sends them.
pub(crate) type HostCapabilities = BTreeMap<String, Vec<u32>>;

/// Checks a raw manifest's `requires` before its sections are decoded. Only
/// level 3 manifests may, and must, declare it.
pub(crate) fn check_manifest_requires(manifest: &Value, api_version: u64) -> Validation<()> {
    let requires = manifest.get("requires");
    if api_version < u64::from(CAPABILITIES_API_VERSION) {
        return match requires {
            Some(_) => Err(PluginRejection::at(
                "plugin.manifest.invalid",
                "requires",
                "Capability versions require pluginAPIVersion 3.",
            )),
            None => Ok(()),
        };
    }
    let Some(requires) = requires else {
        return Err(PluginRejection::at(
            "plugin.manifest.invalid",
            "requires",
            "A pluginAPIVersion 3 manifest lists the capabilities it uses in requires.",
        ));
    };
    let requires = parse_requires(requires, "requires", "plugin.manifest.invalid")?;
    match requires
        .iter()
        .find(|(capability, version)| !core_supports(capability, **version))
    {
        Some((capability, version)) => Err(PluginRejection::at(
            "plugin.api.unsupported",
            format!("requires.{capability}"),
            format!("Plugin capability {capability} {version} is not supported by this version of Lithe."),
        )),
        None => Ok(()),
    }
}

/// Reads a `requires` object. IDs are checked for shape only, so an index
/// can list a plugin for a capability this Core build does not know yet.
pub(crate) fn parse_requires(
    value: &Value,
    field: &str,
    code: &'static str,
) -> Validation<Requires> {
    let Value::Object(entries) = value else {
        return Err(PluginRejection::at(
            code,
            field,
            "requires maps capability IDs to versions.",
        ));
    };
    if entries.is_empty() {
        return Err(PluginRejection::at(
            code,
            field,
            "requires lists no capabilities.",
        ));
    }
    let mut requires = Requires::new();
    for (capability, version) in entries {
        let entry = format!("{field}.{capability}");
        if !is_capability_id(capability) {
            return Err(PluginRejection::at(
                code,
                entry,
                "A capability ID is a lowerCamelCase identifier.",
            ));
        }
        let version = version
            .as_u64()
            .filter(|version| *version >= 1)
            .and_then(|version| u32::try_from(version).ok())
            .ok_or_else(|| {
                PluginRejection::at(code, entry, "A capability version is a positive integer.")
            })?;
        requires.insert(capability.clone(), version);
    }
    Ok(requires)
}

/// Checks that `requires` lists exactly the capabilities a decoded manifest
/// uses. A missing entry would let a host that lacks the capability accept
/// the plugin; an extra one would hide it from hosts it could run on.
pub(crate) fn check_used(requires: &Requires, used: &BTreeSet<&'static str>) -> Validation<()> {
    if let Some(missing) = used
        .iter()
        .find(|capability| !requires.contains_key(**capability))
    {
        return Err(PluginRejection::at(
            "plugin.manifest.invalid",
            "requires",
            format!("The manifest uses {missing}, which requires does not list."),
        ));
    }
    if let Some(unused) = requires
        .keys()
        .find(|capability| !used.contains(capability.as_str()))
    {
        return Err(PluginRejection::at(
            "plugin.manifest.invalid",
            format!("requires.{unused}"),
            format!("requires lists {unused}, which the manifest does not use."),
        ));
    }
    Ok(())
}

/// Whether a host can run every required capability. A host that sends no
/// capabilities runs no level 3 plugin, and a capability this Core build
/// cannot validate is never hosted, whatever the host claims.
pub(crate) fn hosts(requires: &Requires, host: Option<&HostCapabilities>) -> bool {
    first_unhosted(requires, host).is_none()
}

/// Rejects a manifest that requires a capability version the host lacks.
pub(crate) fn check_hosted(requires: &Requires, host: &HostCapabilities) -> Validation<()> {
    match first_unhosted(requires, Some(host)) {
        Some((capability, version)) => Err(PluginRejection::at(
            "plugin.api.unsupported",
            format!("requires.{capability}"),
            format!("This version of Lithe cannot run plugin capability {capability} {version}."),
        )),
        None => Ok(()),
    }
}

fn first_unhosted<'a>(
    requires: &'a Requires,
    host: Option<&HostCapabilities>,
) -> Option<(&'a str, u32)> {
    requires
        .iter()
        .find(|(capability, version)| {
            !core_supports(capability, **version)
                || !host
                    .and_then(|host| host.get(capability.as_str()))
                    .is_some_and(|versions| versions.contains(version))
        })
        .map(|(capability, version)| (capability.as_str(), *version))
}

fn core_supports(capability: &str, version: u32) -> bool {
    SUPPORTED_CAPABILITIES
        .iter()
        .any(|(id, versions)| *id == capability && versions.contains(&version))
}

fn is_capability_id(value: &str) -> bool {
    let mut chars = value.chars();
    value.len() <= MAX_CAPABILITY_ID
        && chars.next().is_some_and(|first| first.is_ascii_lowercase())
        && chars.all(|rest| rest.is_ascii_alphanumeric())
}
