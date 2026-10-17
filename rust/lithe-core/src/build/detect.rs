//! Which build systems a workspace uses, and where each instance is rooted.
//!
//! Detection is one bounded walk shared by every enabled plugin: a plugin
//! names marker files and a nesting rule, never code that walks the tree.
//! Instances whose model needs no process (a static file or a host
//! integration) come back with their model, so opening a workspace shows
//! projects without running a build tool.

use super::decode::Workspace;
use super::manifest::{BuildSystemDeclaration, ModelSource, Nesting};
use super::options;
use super::outputs::{model_value, read_model, source_marker};
use crate::plugins::declarative::{validate_manifest_value, PluginRejection, Validation};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct DetectRequest {
    /// Absolute workspace root.
    pub(crate) workspace_root: String,
    /// Manifests of the enabled plugins, in any order.
    pub(crate) plugins: Vec<DetectPlugin>,
    /// Stored option values by build-system ID, for run entries.
    #[serde(default)]
    pub(crate) options: BTreeMap<String, BTreeMap<String, Value>>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct DetectPlugin {
    pub(crate) manifest: Value,
}

/// The declaration that answers for one build-system ID.
struct Owner<'a> {
    plugin_id: &'a str,
    declaration: &'a BuildSystemDeclaration,
}

fn model_source_name(source: Option<&ModelSource>) -> Value {
    match source {
        None => Value::Null,
        Some(ModelSource::Static { .. }) => json!("static"),
        Some(ModelSource::Command { .. }) => json!("command"),
        Some(ModelSource::HostIntegration) => json!("hostIntegration"),
        Some(ModelSource::Provider) => json!("provider"),
    }
}

fn is_below(path: &str, ancestor: &str) -> bool {
    ancestor == "." && path != "." || path.starts_with(&format!("{ancestor}/"))
}

/// Candidate roots of one build system: directories holding any marker,
/// with nested ones removed when the build system nests its projects.
fn roots(
    declaration: &BuildSystemDeclaration,
    directories: &[crate::execution::DirectoryContext],
) -> Vec<(String, Vec<String>)> {
    let mut candidates: Vec<(String, Vec<String>)> = directories
        .iter()
        .filter_map(|directory| {
            let markers: Vec<String> = declaration
                .detection
                .markers
                .iter()
                .filter(|marker| directory.has(marker))
                .map(|marker| directory.join_relative(marker))
                .collect();
            (!markers.is_empty()).then(|| (directory.relative.clone(), markers))
        })
        .collect();
    candidates.sort_by(|left, right| left.0.cmp(&right.0));
    if declaration.detection.nesting == Nesting::Outermost {
        let all: Vec<String> = candidates.iter().map(|(root, _)| root.clone()).collect();
        candidates.retain(|(root, _)| !all.iter().any(|other| is_below(root, other)));
    }
    candidates
}

fn instance(
    owner: &Owner<'_>,
    workspace: &Workspace,
    root: &str,
    markers: Vec<String>,
    stored: &BTreeMap<String, Value>,
) -> Value {
    let declaration = owner.declaration;
    let mut instance = json!({
        "id": format!("{}:{root}", declaration.id),
        "pluginID": owner.plugin_id,
        "buildSystemID": declaration.id,
        "displayName": declaration.display_name,
        "root": root,
        "markers": markers,
        "modelSource": model_source_name(declaration.model.as_ref()),
    });
    let mut model_values = None;
    if matches!(
        declaration.model,
        Some(ModelSource::Static { .. } | ModelSource::HostIntegration)
    ) {
        let source = source_marker(declaration, workspace, root);
        match read_model(declaration, workspace, root, None, None, None).and_then(|model| {
            let value = model_value(declaration, &model, root, stored, source.as_deref())?;
            Ok((model.option_values, value))
        }) {
            Ok((values, value)) => {
                model_values = Some(values);
                instance["model"] = value;
            }
            Err(error) => {
                instance["modelError"] = json!({ "code": error.code, "message": error.message });
            }
        }
    }
    let resolved = options::resolve(declaration, stored, model_values.as_ref());
    instance["optionFingerprint"] = json!(options::fingerprint(declaration, &resolved));
    instance
}

/// `build.detect`: every instance of every build system the enabled plugins
/// declare. Invalid manifests are reported, not fatal; when two plugins
/// declare one build-system ID, the higher priority answers for it.
pub(crate) fn detect(request: DetectRequest) -> Validation<Value> {
    let workspace = Workspace::new(&request.workspace_root)?;
    let mut rejected = Vec::new();
    let mut manifests = Vec::new();
    for (index, plugin) in request.plugins.into_iter().enumerate() {
        match validate_manifest_value(plugin.manifest) {
            Ok(manifest) => manifests.push(manifest),
            Err(error) => rejected.push(json!({ "index": index, "error": error })),
        }
    }

    let mut owners: BTreeMap<&str, Owner<'_>> = BTreeMap::new();
    let mut shadowed = Vec::new();
    for manifest in &manifests {
        for declaration in manifest.build_systems() {
            let candidate = Owner {
                plugin_id: manifest.id(),
                declaration,
            };
            let Some(current) = owners.get(declaration.id.as_str()) else {
                owners.insert(&declaration.id, candidate);
                continue;
            };
            let wins = (
                std::cmp::Reverse(candidate.declaration.detection.priority),
                candidate.plugin_id,
            ) < (
                std::cmp::Reverse(current.declaration.detection.priority),
                current.plugin_id,
            );
            let (winner, loser) = if wins {
                (
                    candidate,
                    owners.remove(declaration.id.as_str()).expect("present"),
                )
            } else {
                (
                    owners.remove(declaration.id.as_str()).expect("present"),
                    candidate,
                )
            };
            shadowed.push(json!({
                "pluginID": loser.plugin_id,
                "buildSystemID": declaration.id,
                "by": winner.plugin_id,
            }));
            owners.insert(&declaration.id, winner);
        }
    }

    if owners.is_empty() {
        return Ok(json!({ "instances": [], "rejected": rejected, "shadowed": shadowed }));
    }
    let directories = crate::execution::scan(&workspace.path)
        .map_err(|error| PluginRejection::new("plugin.build.invalidSelection", error.message))?;
    let empty = BTreeMap::new();
    let mut seen = BTreeSet::new();
    let mut instances = Vec::new();
    for owner in owners.values() {
        let stored = request.options.get(&owner.declaration.id).unwrap_or(&empty);
        for (root, markers) in roots(owner.declaration, &directories) {
            if seen.insert((owner.declaration.id.clone(), root.clone())) {
                instances.push(instance(owner, &workspace, &root, markers, stored));
            }
        }
    }
    shadowed.sort_by_key(|entry| entry.to_string());
    Ok(json!({
        "instances": instances,
        "rejected": rejected,
        "shadowed": shadowed,
    }))
}
