//! `pluginFunctions` of a plugin manifest: the functions a plugin exports to
//! other plugins and the exported functions it calls.
//!
//! A plugin function is private to the plugin that registered it. Calling one
//! from another plugin is therefore an explicit contract with two sides. The
//! receiving plugin lists `exports`: each entry names one function ID, the
//! version of the input/result contract that function exchanges, and the one
//! calling context it accepts. The calling plugin lists `calls`: the function
//! IDs and contract versions it will call, never the receiving plugin's ID,
//! because the host discovers the providers. Without both declarations, and
//! the receiver registering the function at runtime, no call is routed.
//!
//! Trust never follows the call. The receiving function runs with the
//! receiving plugin's own permissions and the caller gains none of them.
//! `context` is a closed set; version 1 of the capability has one value,
//! `workspace`: a local trusted workspace scheduled by the host. An export
//! without a context the host knows is rejected, so a function that nobody
//! described the acceptable context of is never callable across plugins.
//!
//! The relay itself lives in `crate::lsp::interface::function_relay`.
//!
//! Note: the decision is recorded in .agents/notes/implemented/architecture/2026-10-20-plugin-function-contract.md
//! and .agents/notes/proposed/architecture/2026-10-25-plugin-dependencies-and-exports.md

use super::declarative::{invalid, Validation};
use crate::lsp::interface::plugin_function::is_function_id;
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;

/// Most functions one plugin may export, and most it may declare calling.
pub(crate) const MAX_ENTRIES: usize = 32;

/// Largest export or call contract version. A version names an incompatible
/// contract, so a plugin does not need many.
pub(crate) const MAX_CONTRACT_VERSION: u32 = 1000;

/// The calling context of a function that runs inside the local trusted
/// workspace, scheduled by the host.
pub(crate) const CONTEXT_WORKSPACE: &str = "workspace";

/// Every calling context this Core build knows.
pub(crate) const KNOWN_CONTEXTS: &[&str] = &[CONTEXT_WORKSPACE];

/// A function this plugin offers to other plugins.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ExportDeclaration {
    pub(crate) id: String,
    /// Version of the input and result contract. An incompatible change uses
    /// a new version, and callers declare the version they were written for.
    pub(crate) version: u32,
    /// The only calling context the function accepts. Kept optional while
    /// decoding so a missing or unknown value is a precise manifest error.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) context: Option<String>,
}

/// An exported function this plugin calls.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct CallDeclaration {
    pub(crate) id: String,
    pub(crate) version: u32,
}

/// The `pluginFunctions` section.
#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct PluginFunctionsDeclaration {
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub(crate) exports: Vec<ExportDeclaration>,
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub(crate) calls: Vec<CallDeclaration>,
}

impl PluginFunctionsDeclaration {
    /// Whether the plugin exports at least one function, which lets the host
    /// start its backend when another plugin calls it.
    pub(crate) fn exports_any(&self) -> bool {
        !self.exports.is_empty()
    }

    /// Whether the plugin may call exported functions of other plugins.
    pub(crate) fn calls_any(&self) -> bool {
        !self.calls.is_empty()
    }
}

/// Checks a section and sorts both lists by function ID, so the same
/// declaration always plans the same way. `backend_version` is the plugin's
/// `requires.backend`, 0 without a backend: only a backend 2 process can
/// register functions for the protocol that carries relayed calls.
pub(crate) fn validate(
    section: &mut PluginFunctionsDeclaration,
    backend_version: u32,
) -> Validation<()> {
    if section.exports.is_empty() && section.calls.is_empty() {
        return Err(invalid(
            "pluginFunctions",
            "pluginFunctions declares no exports and no calls.",
        ));
    }
    if backend_version < super::backend::WORKSPACE_CONTEXT_VERSION {
        return Err(invalid(
            "requires.backend",
            "Exported and called plugin functions require backend 2.",
        ));
    }
    if section.exports.len() > MAX_ENTRIES {
        return Err(invalid(
            "pluginFunctions.exports",
            "The plugin exports too many functions.",
        ));
    }
    if section.calls.len() > MAX_ENTRIES {
        return Err(invalid(
            "pluginFunctions.calls",
            "The plugin declares too many called functions.",
        ));
    }
    let mut exported = BTreeSet::new();
    for (index, export) in section.exports.iter().enumerate() {
        let field = format!("pluginFunctions.exports[{index}]");
        if !is_function_id(&export.id) {
            return Err(invalid(
                format!("{field}.id"),
                "An exported function ID is dot-separated lowerCamelCase segments.",
            ));
        }
        if !exported.insert(export.id.as_str()) {
            return Err(invalid(
                format!("{field}.id"),
                "A function is exported more than once.",
            ));
        }
        check_version(export.version, &field)?;
        match export.context.as_deref() {
            Some(context) if KNOWN_CONTEXTS.contains(&context) => {}
            Some(_) => {
                return Err(invalid(
                    format!("{field}.context"),
                    "This version of Lithe does not know the export's calling context.",
                ))
            }
            None => {
                return Err(invalid(
                    format!("{field}.context"),
                    "An exported function states the calling context it accepts.",
                ))
            }
        }
    }
    let mut called = BTreeSet::new();
    for (index, call) in section.calls.iter().enumerate() {
        let field = format!("pluginFunctions.calls[{index}]");
        if !is_function_id(&call.id) {
            return Err(invalid(
                format!("{field}.id"),
                "A called function ID is dot-separated lowerCamelCase segments.",
            ));
        }
        if !called.insert(call.id.as_str()) {
            return Err(invalid(
                format!("{field}.id"),
                "A function is declared as called more than once.",
            ));
        }
        check_version(call.version, &field)?;
    }
    section
        .exports
        .sort_by(|left, right| left.id.cmp(&right.id));
    section.calls.sort_by(|left, right| left.id.cmp(&right.id));
    Ok(())
}

fn check_version(version: u32, field: &str) -> Validation<()> {
    if version == 0 || version > MAX_CONTRACT_VERSION {
        return Err(invalid(
            format!("{field}.version"),
            "A function contract version is a positive integer within the supported range.",
        ));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn export(id: &str, version: u32, context: Option<&str>) -> ExportDeclaration {
        ExportDeclaration {
            id: id.to_string(),
            version,
            context: context.map(str::to_string),
        }
    }

    fn section() -> PluginFunctionsDeclaration {
        PluginFunctionsDeclaration {
            exports: vec![export("project.describe", 1, Some("workspace"))],
            calls: vec![CallDeclaration {
                id: "tool.resolve".to_string(),
                version: 2,
            }],
        }
    }

    #[test]
    fn a_valid_section_is_sorted_by_function_id() {
        let mut section = section();
        section
            .exports
            .insert(0, export("zeta.run", 1, Some("workspace")));
        validate(&mut section, 2).expect("section is valid");
        assert_eq!(section.exports[0].id, "project.describe");
        assert_eq!(section.exports[1].id, "zeta.run");
    }

    #[test]
    fn an_export_must_name_a_known_context() {
        for context in [None, Some("remote"), Some(""), Some("Workspace")] {
            let mut section = section();
            section.exports[0].context = context.map(str::to_string);
            let rejection = validate(&mut section, 2).expect_err("context is rejected");
            assert_eq!(rejection.code, "plugin.manifest.invalid");
            assert_eq!(
                rejection.field.as_deref(),
                Some("pluginFunctions.exports[0].context")
            );
        }
    }

    #[test]
    fn ids_versions_and_counts_are_bounded() {
        let mut bad_id = section();
        bad_id.exports[0].id = "Project.Describe".to_string();
        assert!(validate(&mut bad_id, 2).is_err());

        let mut zero = section();
        zero.calls[0].version = 0;
        assert!(validate(&mut zero, 2).is_err());

        let mut huge = section();
        huge.exports[0].version = MAX_CONTRACT_VERSION + 1;
        assert!(validate(&mut huge, 2).is_err());

        let mut duplicate = section();
        duplicate
            .exports
            .push(export("project.describe", 2, Some("workspace")));
        assert!(validate(&mut duplicate, 2).is_err());

        let mut many = section();
        many.calls = (0..=MAX_ENTRIES)
            .map(|index| CallDeclaration {
                id: format!("tool.run{index}"),
                version: 1,
            })
            .collect();
        assert!(validate(&mut many, 2).is_err());
    }

    #[test]
    fn the_section_needs_backend_two_and_some_entry() {
        assert!(validate(&mut section(), 1).is_err());
        assert!(validate(&mut section(), 0).is_err());
        assert!(validate(&mut PluginFunctionsDeclaration::default(), 2).is_err());
    }
}
