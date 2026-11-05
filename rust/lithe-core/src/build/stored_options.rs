//! Pure team/local Build preference merging and declaration-checked edits.
//! Platforms own reads, conflict checks and atomic publication; no tool is run.

use super::manifest::{BuildSystemDeclaration, OptionKind, OptionScope};
use super::{options, project_options};
use crate::plugins::declarative::{decode_payload, outcome, PluginRejection, Validation};
use crate::protocol::CoreError;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};

type EmptySelections = BTreeMap<String, BTreeMap<String, BTreeSet<String>>>;

/// Machine-local overrides use the existing document syntax, plus explicit
/// per-instance empty workspace selections needed to preserve sibling values.
#[derive(Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Local {
    version: u32,
    document: Value,
    #[serde(default)]
    empty_selections: EmptySelections,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct ResolveRequest {
    document: Value,
    local: Value,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(super) struct EditRequest {
    document: Value,
    local: Value,
    root: String,
    #[serde(rename = "optionID")]
    option_id: String,
    value: Value,
    #[serde(default)]
    model_values: Option<BTreeMap<String, Vec<String>>>,
}

fn invalid() -> PluginRejection {
    PluginRejection::new(
        "plugin.build.invalidOptionsDocument",
        "Invalid Build preferences",
    )
}

fn validate_local(value: Value) -> Validation<Local> {
    let mut local: Local = serde_json::from_value(value).map_err(|_| invalid())?;
    if local.version != 1 || local.empty_selections.len() > 32 {
        return Err(invalid());
    }
    local.document = project_options::validate(local.document)?;
    for (system, roots) in &local.empty_selections {
        if !local.document["systems"]
            .get(system)
            .is_some_and(Value::is_object)
            || roots.len() > 256
            || roots.iter().any(|(root, ids)| {
                !project_options::root_valid(root)
                    || ids.len() > 256
                    || ids.iter().any(|id| {
                        id.is_empty()
                            || id.len() > 128
                            || !id
                                .bytes()
                                .all(|b| b.is_ascii_alphanumeric() || b"_.-".contains(&b))
                    })
            })
        {
            return Err(invalid());
        }
    }
    if serde_json::to_vec(&local).map_or(true, |bytes| bytes.len() > 2 * 1024 * 1024) {
        return Err(invalid());
    }
    Ok(local)
}

fn merge(team: &Value, local: &Local) -> Value {
    let mut document = team.clone();
    let systems = document["systems"]
        .as_object_mut()
        .expect("validated document");
    for (id, patch) in local.document["systems"]
        .as_object()
        .expect("validated local document")
    {
        let target = systems.entry(id.clone()).or_insert_with(|| {
            json!({
                "options":{},"instanceDefaults":{},"instances":{},"savedChoices":{}
            })
        });
        for key in ["options", "instanceDefaults", "savedChoices"] {
            target[key]
                .as_object_mut()
                .expect("normalized map")
                .extend(patch[key].as_object().expect("normalized map").clone());
        }
        for (root, values) in patch["instances"].as_object().expect("normalized roots") {
            let roots = target["instances"]
                .as_object_mut()
                .expect("normalized roots");
            roots
                .entry(root.clone())
                .or_insert_with(|| json!({}))
                .as_object_mut()
                .expect("normalized values")
                .extend(values.as_object().expect("normalized values").clone());
        }
    }
    document
}

fn effective(
    system: &BuildSystemDeclaration,
    document: &Value,
    local: &Local,
    root: &str,
) -> BTreeMap<String, Value> {
    let stored = &document["systems"][&system.id];
    system
        .options
        .iter()
        .filter_map(|option| {
            let value = if option.scope == OptionScope::Instance {
                stored["instances"][root]
                    .get(&option.id)
                    .or_else(|| stored["instanceDefaults"].get(&option.id))
            } else if option.kind == OptionKind::MultiSelect
                && local
                    .empty_selections
                    .get(&system.id)
                    .and_then(|roots| roots.get(root))
                    .is_some_and(|ids| ids.contains(&option.id))
            {
                return Some((option.id.clone(), json!([])));
            } else {
                stored["options"].get(&option.id)
            };
            value.map(|value| (option.id.clone(), value.clone()))
        })
        .collect()
}

/// Resolves storage only, retaining inactive systems and custom choices.
pub(crate) fn resolve_stored_options_command(payload: Value) -> Result<Value, CoreError> {
    let request: ResolveRequest = decode_payload(payload, "build.resolveStoredOptions")?;
    Ok(outcome((|| {
        let team = project_options::validate(request.document)?;
        let local = validate_local(request.local)?;
        Ok((
            "storage",
            json!({"document":merge(&team,&local),"local":local,"emptySelections":local.empty_selections}),
        ))
    })()))
}

/// Produces one local document; the supplied team document is never edited.
pub(super) fn edit(system: &BuildSystemDeclaration, request: &EditRequest) -> Validation<Value> {
    if !project_options::root_valid(&request.root) {
        return Err(invalid());
    }
    let team = project_options::validate(request.document.clone())?;
    let mut local = validate_local(request.local.clone())?;
    let option = system
        .options
        .iter()
        .find(|option| option.id == request.option_id)
        .ok_or_else(|| {
            PluginRejection::new("plugin.build.invalidOption", "Unknown declared option")
        })?;
    let before = merge(&team, &local);
    let current = effective(system, &before, &local, &request.root);
    let mut next = request.value.clone();
    if !next.is_null() {
        let resolved = options::resolve(
            system,
            &BTreeMap::from([(option.id.clone(), next)]),
            request.model_values.as_ref(),
        );
        next = resolved
            .chosen_values
            .get(&option.id)
            .filter(|_| resolved.dropped.is_empty())
            .cloned()
            .ok_or_else(|| {
                PluginRejection::new(
                    "plugin.build.invalidOption",
                    "The option value is not accepted by its declaration",
                )
            })?;
    }
    let systems = local.document["systems"]
        .as_object_mut()
        .expect("normalized systems");
    let target = systems.entry(system.id.clone()).or_insert_with(|| {
        json!({
            "options":{},"instanceDefaults":{},"instances":{},"savedChoices":{}
        })
    });
    let values = if option.scope == OptionScope::Instance {
        target["instances"]
            .as_object_mut()
            .expect("normalized roots")
            .entry(request.root.clone())
            .or_insert_with(|| json!({}))
            .as_object_mut()
            .expect("normalized values")
    } else {
        target["options"]
            .as_object_mut()
            .expect("normalized options")
    };
    if next.is_null() {
        values.remove(&option.id);
        if let Some(roots) = local.empty_selections.get_mut(&system.id) {
            for ids in roots.values_mut() {
                ids.remove(&option.id);
            }
        }
    } else {
        if option.scope == OptionScope::Workspace && option.kind == OptionKind::MultiSelect {
            let visible = options::resolve(system, &current, request.model_values.as_ref())
                .chosen_values
                .get(&option.id)
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            let raw = before["systems"][&system.id]["options"][&option.id]
                .as_array()
                .cloned()
                .unwrap_or_default();
            let mut merged = raw
                .into_iter()
                .filter(|value| !visible.contains(value))
                .collect::<Vec<_>>();
            for value in next.as_array().expect("checked multi-select") {
                if !merged.contains(value) {
                    merged.push(value.clone());
                }
            }
            let ids = local
                .empty_selections
                .entry(system.id.clone())
                .or_default()
                .entry(request.root.clone())
                .or_default();
            if next.as_array().is_some_and(Vec::is_empty) {
                ids.insert(option.id.clone());
            } else {
                ids.remove(&option.id);
            }
            next = json!(merged);
        }
        values.insert(option.id.clone(), next);
    }
    for roots in local.empty_selections.values_mut() {
        roots.retain(|_, ids| !ids.is_empty());
    }
    local.empty_selections.retain(|_, roots| !roots.is_empty());
    // A no-op reset must not materialize an empty machine override. Limit
    // pruning to the edited system/root; dormant user data stays untouched.
    let target = &mut local.document["systems"][&system.id];
    if target["instances"]
        .get(&request.root)
        .is_some_and(|values| values.as_object().is_some_and(serde_json::Map::is_empty))
    {
        target["instances"]
            .as_object_mut()
            .expect("normalized roots")
            .remove(&request.root);
    }
    if ["options", "instanceDefaults", "instances", "savedChoices"]
        .iter()
        .all(|key| {
            target[*key]
                .as_object()
                .is_some_and(serde_json::Map::is_empty)
        })
        && !local.empty_selections.contains_key(&system.id)
    {
        local.document["systems"]
            .as_object_mut()
            .expect("normalized systems")
            .remove(&system.id);
    }
    // Revalidate aggregate bounds after insertion, without pruning unrelated data.
    let local = validate_local(serde_json::to_value(local).map_err(|_| invalid())?)?;
    let document = merge(&team, &local);
    let stored = effective(system, &document, &local, &request.root);
    let resolved = options::resolve(system, &stored, request.model_values.as_ref());
    Ok(
        json!({"local":local,"options":options::describe(system,&resolved,request.model_values.as_ref())}),
    )
}
