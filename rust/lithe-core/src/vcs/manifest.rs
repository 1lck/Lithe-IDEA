//! `vcsProviders[]` of an API level 3 plugin manifest: what a host must know
//! about a VCS before starting any process for it.
//!
//! A declaration names the VCS, the static markers that identify its roots,
//! the metadata the host watches to refresh status, the client tool the
//! provider drives, and the provider process with the launch fields every
//! plugin server process shares. Capabilities are not declared here: they
//! belong to the running provider and are negotiated in `initialize`.

use super::model::is_vcs_id;
use crate::plugins::declarative::{
    invalid, is_bare_command, is_safe_relative_path, sorted_unique, PluginRejection, ServerProcess,
    ServerRole, Validation,
};
use crate::plugins::settings::DeclaredSettings;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeSet;

/// The built-in VCS ID. Git is not part of the unified layer yet, but Core
/// recognizes its roots so a nested working copy is assigned correctly, and
/// no plugin may claim the ID.
pub(crate) const BUILT_IN_GIT: &str = "git";

/// Most providers one plugin may declare.
const MAX_PROVIDERS: usize = 8;
/// Most markers one provider may declare.
const MAX_MARKERS: usize = 8;
/// Most metadata paths one provider may ask the host to watch.
const MAX_METADATA_PATHS: usize = 16;
/// Most tool command names one provider may list.
const MAX_TOOL_COMMANDS: usize = 8;
/// Longest display name, in characters.
const MAX_DISPLAY_NAME: usize = 64;

/// One VCS a plugin implements.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct VcsProviderDeclaration {
    /// Stable lowercase VCS ID (`svn`, `hg`); the provider must answer the
    /// same ID in `initialize`.
    pub(crate) id: String,
    pub(crate) display_name: String,
    pub(crate) detection: VcsDetection,
    /// Root-relative files or directories whose change means the status may
    /// be stale, such as `.svn/wc.db`. Sorted and unique once validated.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub(crate) metadata_paths: Vec<String>,
    /// The VCS client the provider runs, which the host resolves and passes
    /// with every request. Absent for a provider that needs no client.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) tool: Option<VcsTool>,
    #[serde(flatten)]
    pub(crate) process: ServerProcess,
    /// Whether operations may contact a server; shown in the install review.
    pub(crate) may_use_network: bool,
}

/// Static markers of a root. Detection never starts a process.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct VcsDetection {
    pub(crate) markers: Vec<VcsMarker>,
}

/// An entry directly inside a root that marks it, such as the `.svn`
/// directory. The kind matters: a Git worktree has a `.git` file.
#[derive(Debug, Clone, PartialEq, Eq, PartialOrd, Ord, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct VcsMarker {
    pub(crate) name: String,
    #[serde(rename = "type")]
    pub(crate) kind: MarkerKind,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum MarkerKind {
    Directory,
    File,
}

/// A client executable the host discovers like a `systemCommand` launch.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct VcsTool {
    /// Bare command names, tried in order.
    pub(crate) commands: Vec<String>,
    /// Arguments of a probe that must exit successfully before the host
    /// trusts a candidate; empty means no probe.
    #[serde(default)]
    pub(crate) validation_arguments: Vec<String>,
}

/// The markers Core uses for the built-in Git support: a `.git` directory,
/// or the `.git` file of a linked worktree or submodule.
pub(crate) fn built_in_git_markers() -> Vec<VcsMarker> {
    vec![
        VcsMarker {
            name: ".git".to_string(),
            kind: MarkerKind::Directory,
        },
        VcsMarker {
            name: ".git".to_string(),
            kind: MarkerKind::File,
        },
    ]
}

fn is_marker_name(value: &str) -> bool {
    !value.is_empty()
        && value != "."
        && value != ".."
        && value.len() <= 255
        && !value.contains(['/', '\\', '\0'])
}

/// What the declaration context needs from the manifest.
pub(crate) struct DeclarationContext<'a> {
    pub(crate) plugin_api_version: u32,
    pub(crate) declared_settings: &'a DeclaredSettings,
}

/// Validates every declaration and sorts them by ID.
pub(crate) fn validate_declarations(
    providers: &mut [VcsProviderDeclaration],
    context: &DeclarationContext<'_>,
) -> Validation<()> {
    if providers.is_empty() {
        return Ok(());
    }
    if context.plugin_api_version < 3 {
        return Err(invalid(
            "vcsProviders",
            "VCS providers require plugin API level 3.",
        ));
    }
    if providers.len() > MAX_PROVIDERS {
        return Err(invalid(
            "vcsProviders",
            format!("A plugin declares at most {MAX_PROVIDERS} VCS providers."),
        ));
    }
    let mut ids = BTreeSet::new();
    for (index, provider) in providers.iter_mut().enumerate() {
        let field = format!("vcsProviders[{index}]");
        provider.validate(&field, context)?;
        if !ids.insert(provider.id.clone()) {
            return Err(invalid(
                format!("{field}.id"),
                "A VCS is declared more than once.",
            ));
        }
    }
    providers.sort_by(|left, right| left.id.cmp(&right.id));
    Ok(())
}

impl VcsProviderDeclaration {
    fn validate(&mut self, field: &str, context: &DeclarationContext<'_>) -> Validation<()> {
        if !is_vcs_id(&self.id) {
            return Err(invalid(
                format!("{field}.id"),
                "A VCS ID is a lowercase letter followed by up to 31 lowercase letters, digits, or hyphens.",
            ));
        }
        if self.id == BUILT_IN_GIT {
            return Err(PluginRejection::at(
                "plugin.vcs.reserved",
                format!("{field}.id"),
                "Git is built into Lithe and cannot be provided by a plugin yet.",
            ));
        }
        let display_name = self.display_name.trim();
        if display_name.is_empty()
            || display_name.chars().count() > MAX_DISPLAY_NAME
            || display_name.chars().any(char::is_control)
        {
            return Err(invalid(
                format!("{field}.displayName"),
                "The display name is one line of 1-64 characters.",
            ));
        }

        let markers = &mut self.detection.markers;
        if markers.is_empty() || markers.len() > MAX_MARKERS {
            return Err(invalid(
                format!("{field}.detection.markers"),
                format!("Detection needs 1-{MAX_MARKERS} markers."),
            ));
        }
        if let Some(index) = markers
            .iter()
            .position(|marker| !is_marker_name(&marker.name))
        {
            return Err(invalid(
                format!("{field}.detection.markers[{index}].name"),
                "A marker is a name directly inside the root.",
            ));
        }
        markers.sort();
        markers.dedup();

        if self.metadata_paths.len() > MAX_METADATA_PATHS {
            return Err(invalid(
                format!("{field}.metadataPaths"),
                format!("At most {MAX_METADATA_PATHS} metadata paths are watched."),
            ));
        }
        if let Some(index) = self.metadata_paths.iter().position(|path| {
            !is_safe_relative_path(path) || path.split('/').any(|s| s.is_empty() || s == ".")
        }) {
            return Err(invalid(
                format!("{field}.metadataPaths[{index}]"),
                "A metadata path must stay inside the root.",
            ));
        }
        self.metadata_paths = sorted_unique(std::mem::take(&mut self.metadata_paths));

        if let Some(tool) = &self.tool {
            if tool.commands.is_empty()
                || tool.commands.len() > MAX_TOOL_COMMANDS
                || tool
                    .commands
                    .iter()
                    .any(|command| !is_bare_command(command))
            {
                return Err(invalid(
                    format!("{field}.tool.commands"),
                    format!("A tool names 1-{MAX_TOOL_COMMANDS} bare executable names."),
                ));
            }
            if tool
                .validation_arguments
                .iter()
                .any(|argument| argument.contains('\0'))
            {
                return Err(invalid(
                    format!("{field}.tool.validationArguments"),
                    "Tool arguments must not contain NUL.",
                ));
            }
        }

        self.process.validate(
            field,
            context.plugin_api_version,
            context.declared_settings,
            ServerRole::VcsProvider,
        )
    }

    /// Display data and requirements a host keeps for a provider; the
    /// process launch is planned separately.
    pub(crate) fn descriptor(&self, plugin_id: &str) -> Value {
        json!({
            "vcs": self.id,
            "displayName": self.display_name,
            "origin": { "kind": "plugin", "pluginID": plugin_id },
            "markers": self.detection.markers,
            "metadataPaths": self.metadata_paths,
            "tool": self.tool,
            "mayUseNetwork": self.may_use_network,
        })
    }
}

/// Activation event the host raises before starting a VCS provider, once a
/// root of its VCS was detected.
pub(crate) fn activation_event(provider: &VcsProviderDeclaration) -> String {
    format!("onVcsRoot:{}", provider.id)
}

/// Install-review entries: the provider process with the runtimes it needs.
/// The tool is part of the provider entry, so pointing it at another client
/// is a new program the user must approve.
pub(crate) fn programs(provider: &VcsProviderDeclaration) -> Vec<Value> {
    let mut program = provider.process.program(ServerRole::VcsProvider);
    program["vcs"] = json!(provider.id);
    // `tool` already names a runtime launch's runtime.
    program["vcsTool"] = json!(provider.tool);
    program["mayUseNetwork"] = json!(provider.may_use_network);
    let mut programs = vec![program];
    programs.extend(provider.process.runtime_programs());
    programs
}
