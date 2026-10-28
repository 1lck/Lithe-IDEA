//! Optional read-only model inputs between already enabled workspace providers.
//! Sharing grants no installation, process, resource or private-function authority.

use super::{
    decode,
    manifest::{is_entry_identifier, BuildSystemDeclaration},
    model::{ModelContentRoot, ModelProject, ModelTarget},
    options, plans,
};
use crate::plugins::declarative::{is_plugin_id, validate_manifest_value, Validation};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};

const MAX_INPUTS: usize = 8;
const MAX_INSTANCES: usize = 64;
const MAX_BYTES: usize = 8 * 1024 * 1024;

/// Producer opt-in; only these ordinary build options leave their owner.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ModelSharing {
    #[serde(default)]
    pub(crate) options: Vec<String>,
}

/// Exact optional producer identity; package versions and permissions are not inherited.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ModelInput {
    #[serde(rename = "pluginID")]
    pub(crate) plugin_id: String,
    #[serde(rename = "buildSystemID")]
    pub(crate) build_system_id: String,
}

/// Enforces explicit publication/consumption and independent wire admission.
pub(crate) fn validate_declaration(
    build: &mut BuildSystemDeclaration,
    version: u32,
    provider_version: u32,
) -> Validation<()> {
    let invalid = || {
        plans::invalid_selection("Model sharing requires buildModelInputs 1; consumers need a provider and buildProviders 6, exact unique producers, and declared shared option IDs; producers cannot also consume inputs.")
    };
    if build.model_sharing.is_none() && build.model_inputs.is_empty() {
        return Ok(());
    }
    if version != 1
        || (build.model_sharing.is_some() && !build.model_inputs.is_empty())
        || build.model.is_none()
        || build.model_inputs.len() > MAX_INPUTS
    {
        return Err(invalid());
    }
    if !build.model_inputs.is_empty() && (build.provider.is_none() || provider_version < 6) {
        return Err(invalid());
    }
    let mut seen = BTreeSet::new();
    for input in &build.model_inputs {
        if !is_plugin_id(&input.plugin_id)
            || !is_entry_identifier(&input.build_system_id)
            || !seen.insert(input.clone())
        {
            return Err(invalid());
        }
    }
    build.model_inputs.sort();
    if let Some(sharing) = &mut build.model_sharing {
        if sharing.options.len() > 32
            || sharing
                .options
                .iter()
                .any(|id| !build.options.iter().any(|option| option.id == *id))
        {
            return Err(invalid());
        }
        let unique: BTreeSet<_> = sharing.options.iter().collect();
        if unique.len() != sharing.options.len() {
            return Err(invalid());
        }
        sharing.options.sort();
    }
    Ok(())
}

/// Installed/enabled source facts supplied by the native host, not by another backend.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Source {
    pub(crate) manifest: Value,
    pub(crate) instances: Vec<Instance>,
}

/// Host model state; old or incomplete models never accompany an unavailable state.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct Instance {
    #[serde(rename = "buildSystemID")]
    pub(crate) build_system_id: String,
    pub(crate) root: String,
    pub(crate) state: State,
    #[serde(default)]
    pub(crate) model: Option<Value>,
    #[serde(default)]
    pub(crate) options: BTreeMap<String, Value>,
}

#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub(crate) enum State {
    Ready,
    Loading,
    Stale,
    Failed,
}

/// A bounded snapshot revision belongs to this workspace activation only.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ResolveRequest {
    pub(crate) revision: u64,
    pub(crate) sources: Vec<Source>,
}

fn invalid() -> crate::plugins::declarative::PluginRejection {
    plans::invalid_selection("Invalid or oversized shared build model input.")
}

/// Selects exact public producers and strips tasks, run plans, settings and unshared options.
pub(crate) fn resolve(
    consumer: &BuildSystemDeclaration,
    request: &ResolveRequest,
) -> Validation<Value> {
    if consumer.model_inputs.is_empty()
        || request.sources.len() > MAX_INPUTS
        || request.revision > 9_007_199_254_740_991
    {
        return Err(invalid());
    }
    let mut sources = BTreeMap::new();
    for source in &request.sources {
        let manifest = validate_manifest_value(source.manifest.clone())?;
        if source.instances.len() > MAX_INSTANCES
            || sources
                .insert(manifest.id().to_string(), (manifest, source))
                .is_some()
        {
            return Err(invalid());
        }
    }
    let mut inputs = Vec::new();
    for input in &consumer.model_inputs {
        let mut value = json!({"pluginID":input.plugin_id,"buildSystemID":input.build_system_id,"state":"unavailable","instances":[]});
        if let Some((manifest, source)) = sources.get(&input.plugin_id) {
            if let Some(producer) = manifest
                .build_systems()
                .iter()
                .find(|build| build.id == input.build_system_id && build.model_sharing.is_some())
            {
                let mut instances = BTreeMap::new();
                for instance in source
                    .instances
                    .iter()
                    .filter(|instance| instance.build_system_id == producer.id)
                {
                    let root = decode::request_path(&instance.root, "root")?;
                    let mut shared = json!({"root":root,"state":instance.state});
                    if instance.state == State::Ready {
                        let model = instance.model.as_ref().ok_or_else(invalid)?;
                        let truncated = match model.get("truncated") {
                            Some(value) => value.as_bool().ok_or_else(invalid)?,
                            None => false,
                        };
                        if truncated {
                            shared["state"] = json!("stale");
                        } else {
                            shared["model"] = public_model(model, &root)?;
                            let values: BTreeMap<String, Vec<String>> = serde_json::from_value(
                                model
                                    .get("optionValues")
                                    .cloned()
                                    .unwrap_or_else(|| json!({})),
                            )
                            .map_err(|_| invalid())?;
                            let resolved =
                                options::resolve(producer, &instance.options, Some(&values));
                            shared["configurationFingerprint"] =
                                json!(options::fingerprint(producer, &resolved));
                            let shared_values: BTreeMap<_, _> = producer
                                .model_sharing
                                .as_ref()
                                .expect("selected public model")
                                .options
                                .iter()
                                .filter_map(|id| resolved.values.get(id).map(|value| (id, value)))
                                .collect();
                            shared["options"] = json!(shared_values);
                        }
                    }
                    if instances.insert(root, shared).is_some() {
                        return Err(invalid());
                    }
                }
                value["state"] = json!("available");
                value["instances"] = json!(instances.into_values().collect::<Vec<_>>());
            }
        }
        inputs.push(value);
    }
    let value = json!({"version":1,"revision":request.revision,"inputs":inputs});
    if serde_json::to_vec(&value).map_or(usize::MAX, |bytes| bytes.len()) > MAX_BYTES {
        return Err(invalid());
    }
    check_snapshot(consumer, &value)?;
    Ok(value)
}

/// Public normalized facts only; executable tasks and run plans are never decoded here.
#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct PublicModel {
    projects: Vec<ModelProject>,
    targets: Vec<ModelTarget>,
    content_roots: Vec<ModelContentRoot>,
}

fn text(value: &str, limit: usize) -> bool {
    !value.is_empty() && value.len() <= limit && !value.chars().any(char::is_control)
}

fn properties(values: &BTreeMap<String, String>) -> bool {
    values.len() <= 256
        && values.iter().all(|(key, value)| {
            text(key, 256) && value.len() <= 1024 && !value.chars().any(char::is_control)
        })
}

/// Rechecks IDs/ownership and lexical containment without inventing project facts.
fn public_model(model: &Value, root: &str) -> Validation<Value> {
    let mut model: PublicModel = serde_json::from_value(model.clone()).map_err(|_| invalid())?;
    if model.projects.len() > 2000
        || model.targets.len() > 10000
        || model.content_roots.len() > 10000
    {
        return Err(invalid());
    }
    let projects: BTreeMap<_, _> = model
        .projects
        .iter()
        .map(|project| (project.id.as_str(), project))
        .collect();
    if projects.len() != model.projects.len() {
        return Err(invalid());
    }
    for project in &model.projects {
        if !text(&project.id, 2048)
            || !text(&project.name, 256)
            || project
                .display_name
                .as_ref()
                .is_some_and(|name| !text(name, 256))
            || !properties(&project.properties)
            || decode::request_path(&project.path, "path")? != project.path
            || !decode::contains(root, &project.path)
        {
            return Err(invalid());
        }
        let mut parents = BTreeSet::from([project.id.as_str()]);
        let mut parent = project.parent_id.as_deref();
        while let Some(id) = parent {
            if !parents.insert(id) {
                return Err(invalid());
            }
            let ancestor = projects.get(id).ok_or_else(invalid)?;
            if !decode::contains(&ancestor.path, &project.path) {
                return Err(invalid());
            }
            parent = ancestor.parent_id.as_deref();
        }
    }
    let mut targets = BTreeSet::new();
    for target in &model.targets {
        let project = projects
            .get(target.project_id.as_str())
            .ok_or_else(invalid)?;
        if !text(&target.id, 2048)
            || !targets.insert(&target.id)
            || !text(&target.name, 256)
            || !properties(&target.properties)
            || target.tags.len() > 32
            || target.tags.iter().any(|tag| !text(tag, 256))
            || decode::request_path(&target.path, "path")? != target.path
            || !decode::contains(&project.path, &target.path)
        {
            return Err(invalid());
        }
    }
    let mut roots = BTreeSet::new();
    for content in &model.content_roots {
        let project = projects
            .get(content.project_id.as_str())
            .ok_or_else(invalid)?;
        if !roots.insert(content)
            || decode::request_path(&content.path, "path")? != content.path
            || !decode::contains(&project.path, &content.path)
        {
            return Err(invalid());
        }
    }
    model.projects.sort_by(|a, b| a.id.cmp(&b.id));
    model.targets.sort_by(|a, b| a.id.cmp(&b.id));
    model.content_roots.sort();
    serde_json::to_value(model).map_err(|_| invalid())
}

/// Revalidates the resolved snapshot instead of accepting arbitrary opaque backend context.
pub(crate) fn check_snapshot(consumer: &BuildSystemDeclaration, value: &Value) -> Validation<()> {
    fn keys(value: &Value, allowed: &[&str]) -> bool {
        value
            .as_object()
            .is_some_and(|object| object.keys().all(|key| allowed.contains(&key.as_str())))
    }
    if !keys(value, &["version", "revision", "inputs"])
        || value["version"] != 1
        || value["revision"]
            .as_u64()
            .is_none_or(|revision| revision > 9_007_199_254_740_991)
        || serde_json::to_vec(value).map_or(usize::MAX, |bytes| bytes.len()) > MAX_BYTES
    {
        return Err(invalid());
    }
    let inputs = value["inputs"].as_array().ok_or_else(invalid)?;
    if inputs.len() != consumer.model_inputs.len() {
        return Err(invalid());
    }
    for (value, slot) in inputs.iter().zip(&consumer.model_inputs) {
        if !keys(value, &["pluginID", "buildSystemID", "state", "instances"])
            || value["pluginID"] != slot.plugin_id
            || value["buildSystemID"] != slot.build_system_id
        {
            return Err(invalid());
        }
        let instances = value["instances"].as_array().ok_or_else(invalid)?;
        if instances.len() > MAX_INSTANCES
            || !matches!(value["state"].as_str(), Some("available" | "unavailable"))
            || value["state"] == "unavailable" && !instances.is_empty()
        {
            return Err(invalid());
        }
        let mut roots = BTreeSet::new();
        for instance in instances {
            let root =
                decode::request_path(instance["root"].as_str().ok_or_else(invalid)?, "root")?;
            if instance["root"] != root || !roots.insert(root.clone()) {
                return Err(invalid());
            }
            if instance["state"] == "ready" {
                if !keys(
                    instance,
                    &[
                        "root",
                        "state",
                        "model",
                        "configurationFingerprint",
                        "options",
                    ],
                ) || public_model(&instance["model"], &root)? != instance["model"]
                    || !instance["configurationFingerprint"]
                        .as_str()
                        .is_some_and(|value| {
                            value.len() == 64 && value.bytes().all(|byte| byte.is_ascii_hexdigit())
                        })
                    || !instance["options"].as_object().is_some_and(|options| {
                        options.len() <= 32
                            && options.values().all(|value| {
                                value.is_boolean()
                                    || value.is_string()
                                    || value
                                        .as_array()
                                        .is_some_and(|items| items.iter().all(Value::is_string))
                            })
                    })
                {
                    return Err(invalid());
                }
            } else if !keys(instance, &["root", "state"])
                || !matches!(
                    instance["state"].as_str(),
                    Some("loading" | "stale" | "failed")
                )
            {
                return Err(invalid());
            }
        }
    }
    Ok(())
}
