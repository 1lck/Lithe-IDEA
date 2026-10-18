//! Build options: the user's stored choices checked against the
//! declaration, their effective values, the arguments and environment they
//! contribute, and the fingerprint hosts use to notice a changed build
//! configuration.

use super::manifest::{BuildSystemDeclaration, OptionDeclaration, OptionKind};
use super::template::{self, Values};
use crate::plugins::declarative::Validation;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::BTreeMap;

const FINGERPRINT_DOMAIN: &str = "lithe.build.options/1";

/// Effective option values of one request, by option ID. Options with no
/// effective value contribute nothing and are absent.
#[derive(Debug, Clone, Default)]
pub(crate) struct ResolvedOptions {
    pub(crate) values: BTreeMap<String, Value>,
    /// Which values the user chose, as opposed to declaration defaults.
    pub(crate) chosen: Vec<String>,
    /// The accepted user values, including empty text and empty selections
    /// that contribute no argument. The host needs them to tell an explicit
    /// clear from "no stored value".
    pub(crate) chosen_values: BTreeMap<String, Value>,
    /// Options whose stored value the declaration refuses in whole or in
    /// part, so the host can store the effective value instead.
    pub(crate) dropped: Vec<String>,
}

/// Checks stored values against the declaration. `model_values` are the
/// model's `optionValues`, or `None` when no model is loaded yet.
pub(crate) fn resolve(
    build_system: &BuildSystemDeclaration,
    stored: &BTreeMap<String, Value>,
    model_values: Option<&BTreeMap<String, Vec<String>>>,
) -> ResolvedOptions {
    let mut resolved = ResolvedOptions::default();
    for (id, _) in stored.iter() {
        if build_system.option(id).is_none() {
            resolved.dropped.push(id.clone());
        }
    }
    for option in &build_system.options {
        let known =
            model_values.map(|values| values.get(&option.id).map(Vec::as_slice).unwrap_or(&[]));
        let user = stored
            .get(&option.id)
            .map(|value| accepted(option, value, known));
        let value = match user {
            Some(Some((value, discarded))) => {
                resolved.chosen.push(option.id.clone());
                resolved
                    .chosen_values
                    .insert(option.id.clone(), value.clone());
                if discarded {
                    resolved.dropped.push(option.id.clone());
                }
                Some(value)
            }
            Some(None) => {
                resolved.dropped.push(option.id.clone());
                default_value(option)
            }
            None => default_value(option),
        };
        if let Some(value) = value.filter(|value| contributes(option, value)) {
            resolved.values.insert(option.id.clone(), value);
        }
    }
    resolved.dropped.sort();
    resolved
}

fn default_value(option: &OptionDeclaration) -> Option<Value> {
    option.default.clone()
}

/// The normalized value and whether part of the stored value was
/// discarded, or `None` when the declaration refuses all of it. A
/// multi-select keeps the items it still accepts, so a feature removed from
/// the build file does not clear the rest of the selection; its values are
/// sorted so equal selections fingerprint equally.
fn accepted(
    option: &OptionDeclaration,
    value: &Value,
    known: Option<&[String]>,
) -> Option<(Value, bool)> {
    match (option.kind, value) {
        (OptionKind::Boolean, Value::Bool(_)) => Some((value.clone(), false)),
        (OptionKind::SingleSelect, Value::String(text)) => option
            .accepts_value(text, known)
            .then(|| (value.clone(), false)),
        (OptionKind::MultiSelect, Value::Array(items)) => {
            let mut values = Vec::new();
            let mut discarded = false;
            for item in items {
                let text = item.as_str()?;
                if option.accepts_value(text, known) {
                    values.push(text.to_string());
                } else {
                    discarded = true;
                }
            }
            if discarded && values.is_empty() {
                return None;
            }
            values.sort();
            values.dedup();
            Some((json!(values), discarded))
        }
        (OptionKind::Text | OptionKind::File | OptionKind::Directory, Value::String(text)) => {
            (text.is_empty() || super::manifest::is_option_value(text))
                .then(|| (value.clone(), false))
        }
        _ => None,
    }
}

/// False for values that mean "not set": `false`, `""`, and `[]`.
fn contributes(option: &OptionDeclaration, value: &Value) -> bool {
    match (option.kind, value) {
        (OptionKind::Boolean, Value::Bool(flag)) => *flag,
        (_, Value::String(text)) => !text.is_empty(),
        (_, Value::Array(items)) => !items.is_empty(),
        _ => false,
    }
}

/// Text substituted for `${value}`.
fn value_text(option: &OptionDeclaration, value: &Value) -> Option<String> {
    match value {
        Value::String(text) => Some(text.clone()),
        Value::Array(items) => Some(
            items
                .iter()
                .filter_map(Value::as_str)
                .collect::<Vec<_>>()
                .join(option.separator()),
        ),
        _ => None,
    }
}

/// Arguments and environment of every option with an effective value, in
/// declaration order.
pub(crate) struct OptionContribution {
    pub(crate) arguments: Vec<(String, Vec<String>)>,
    pub(crate) environment: BTreeMap<String, String>,
}

pub(crate) fn contribution(
    build_system: &BuildSystemDeclaration,
    resolved: &ResolvedOptions,
) -> Validation<OptionContribution> {
    let mut arguments = Vec::new();
    let mut environment = BTreeMap::new();
    for option in &build_system.options {
        let Some(value) = resolved.values.get(&option.id) else {
            continue;
        };
        let text = value_text(option, value);
        let values = Values {
            value: text.as_deref(),
            ..Values::default()
        };
        let expanded = option
            .arguments
            .iter()
            .map(|argument| template::expand_text(argument, &values))
            .collect::<Validation<Vec<_>>>()?;
        arguments.push((option.id.clone(), expanded));
        for (name, value) in &option.environment {
            environment.insert(name.clone(), template::expand_text(value, &values)?);
        }
    }
    Ok(OptionContribution {
        arguments,
        environment,
    })
}

/// Stable digest of the effective values; equal for equal configurations
/// whichever order the host stored them in.
pub(crate) fn fingerprint(
    build_system: &BuildSystemDeclaration,
    resolved: &ResolvedOptions,
) -> String {
    let mut hasher = Sha256::new();
    hasher.update(FINGERPRINT_DOMAIN.as_bytes());
    hasher.update([0]);
    hasher.update(build_system.id.as_bytes());
    for (id, value) in &resolved.values {
        hasher.update([0]);
        hasher.update(id.as_bytes());
        hasher.update([0]);
        // `serde_json` writes object keys in insertion order; option values
        // are scalars or arrays of strings, which have one encoding.
        hasher.update(value.to_string().as_bytes());
    }
    format!("{:x}", hasher.finalize())
}

/// The `build.resolveOptions` view: every option with its effective value,
/// where the value came from, and the choices the UI should offer.
pub(crate) fn describe(
    build_system: &BuildSystemDeclaration,
    resolved: &ResolvedOptions,
    model_values: Option<&BTreeMap<String, Vec<String>>>,
) -> Value {
    let options: Vec<Value> = build_system
        .options
        .iter()
        .map(|option| {
            let mut choices: Vec<Value> = option
                .choices
                .iter()
                .map(|choice| json!({ "value": choice.value, "title": choice.title }))
                .collect();
            if option.choices_from_model {
                let declared: Vec<&String> =
                    option.choices.iter().map(|choice| &choice.value).collect();
                for value in model_values
                    .and_then(|values| values.get(&option.id))
                    .into_iter()
                    .flatten()
                    .filter(|value| !declared.contains(value))
                {
                    choices.push(json!({ "value": value, "fromModel": true }));
                }
            }
            let source = if resolved.chosen.contains(&option.id) {
                "user"
            } else if option.default.is_some() {
                "default"
            } else {
                "unset"
            };
            let value = if resolved.chosen.contains(&option.id) {
                // An explicit empty value has no contribution but must not
                // be described as unset, or the host would drop it and a
                // non-empty default would come back.
                resolved
                    .chosen_values
                    .get(&option.id)
                    .cloned()
                    .unwrap_or(Value::Null)
            } else {
                resolved
                    .values
                    .get(&option.id)
                    .cloned()
                    .unwrap_or(match option.kind {
                        OptionKind::Boolean => json!(false),
                        OptionKind::MultiSelect => json!([]),
                        _ => Value::Null,
                    })
            };
            json!({
                "id": option.id,
                "displayName": option.display_name,
                "kind": option.kind,
                "value": value,
                "source": source,
                "choices": choices,
                "allowCustom": option.allow_custom,
            })
        })
        .collect();
    json!({
        "options": options,
        "dropped": resolved.dropped,
        "fingerprint": fingerprint(build_system, resolved),
    })
}
