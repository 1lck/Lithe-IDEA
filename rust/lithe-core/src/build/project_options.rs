//! Validates the existing team Build options document for native stores.
//! This is storage syntax only: declarations still own option types, scope,
//! defaults and contributions, and platforms own file access and publication.

use crate::plugins::declarative::{decode_payload, outcome, PluginRejection, Validation};
use crate::protocol::CoreError;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeMap;

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct Request {
    document: Value,
}

#[derive(Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
struct Document {
    // JSON Schema's numeric const 1 also accepts 1.0, as the existing native
    // document validator does. Booleans must never become the version number.
    version: f64,
    systems: BTreeMap<String, System>,
}

#[derive(Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct System {
    #[serde(default)]
    options: BTreeMap<String, StoredValue>,
    #[serde(default)]
    instance_defaults: BTreeMap<String, StoredValue>,
    #[serde(default)]
    instances: BTreeMap<String, BTreeMap<String, StoredValue>>,
    #[serde(default)]
    saved_choices: BTreeMap<String, Vec<String>>,
}

/// No null or numeric option is part of the persisted v1 document.
#[derive(Deserialize, Serialize)]
#[serde(untagged)]
enum StoredValue {
    Boolean(bool),
    Text(String),
    List(Vec<String>),
}

fn invalid() -> PluginRejection {
    PluginRejection::new(
        "plugin.build.invalidOptionsDocument",
        "The saved build options are invalid. The original configuration has been kept.",
    )
}

fn values_valid(values: &BTreeMap<String, StoredValue>) -> bool {
    values.len() <= 256
        && values.keys().all(|id| {
            !id.is_empty()
                && id.len() <= 128
                && id
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || b"_.-".contains(&byte))
        })
}

fn root_valid(root: &str) -> bool {
    root == "."
        || !root.is_empty()
            && root.chars().count() <= 1024
            && !root.contains(['\\', ':'])
            && !root.chars().any(char::is_control)
            && root
                .split('/')
                .all(|part| !part.is_empty() && part != "." && part != "..")
}

fn validate(value: Value) -> Validation<Value> {
    if serde_json::to_vec(&value).map_or(true, |bytes| bytes.len() > 2 * 1024 * 1024) {
        return Err(invalid());
    }
    let document: Document = serde_json::from_value(value).map_err(|_| invalid())?;
    if document.version != 1.0 || document.systems.len() > 32 {
        return Err(invalid());
    }
    for (id, system) in &document.systems {
        if id.is_empty()
            || id.len() > 64
            || !id
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
            || !values_valid(&system.options)
            || !values_valid(&system.instance_defaults)
            || system.instances.len() > 256
            || system
                .instances
                .iter()
                .any(|(root, values)| !root_valid(root) || !values_valid(values))
        {
            return Err(invalid());
        }
    }
    Ok(json!({"version":1,"systems":document.systems}))
}

/// Validates storage without dropping values belonging to inactive plugins or
/// treating malformed documents as empty defaults. Never reads or writes a file.
pub(crate) fn project_options_command(payload: Value) -> Result<Value, CoreError> {
    let request: Request = decode_payload(payload, "build.projectOptions")?;
    Ok(outcome(
        validate(request.document).map(|document| ("document", document)),
    ))
}
