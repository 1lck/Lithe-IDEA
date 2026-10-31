//! Non-sensitive native configuration facts supplied by the owning build engine.
//! Core validates a bounded snapshot and user edits; platform adapters own source
//! access, confirmation, conditional publication, and read-back. No build-tool
//! precedence or native settings discovery is inferred here.

use super::manifest::BuildSystemDeclaration;
use super::plans::{self, OutputPlanRequest};
use crate::plugins::declarative::Validation;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, BTreeSet};

const MAX_SOURCES: usize = 8;
const MAX_FIELDS: usize = 64;
const MAX_TEXT: usize = 8192;

/// Opt-in declaration; older providers cannot silently ignore native settings.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct ConfigurationDeclaration {
    pub(crate) source: ConfigurationSource,
}

/// Configuration facts currently require the workspace's own provider process.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum ConfigurationSource {
    Provider,
}

/// A native source is addressed by an opaque provider ID, never by an edit's path.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ConfigurationSnapshot {
    pub(crate) format: String,
    pub(crate) version: u32,
    pub(crate) sources: Vec<NativeSource>,
}

/// Only allowlisted, non-sensitive fields cross the provider wire. Unrelated
/// native content, including credentials, stays in the file on the host.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct NativeSource {
    pub(crate) id: String,
    pub(crate) scope: SourceScope,
    /// Display and platform I/O metadata; not a workspace-relative model identity.
    pub(crate) uri: String,
    /// `missing`, or `sha256:` followed by the exact source bytes' digest.
    pub(crate) revision: String,
    pub(crate) writable: bool,
    pub(crate) fields: Vec<NativeField>,
}

/// User-visible scope; an installation is always read-only at runtime.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum SourceScope {
    Installation,
    User,
    Workspace,
}

/// A non-secret value and its upstream effective value are distinct. `null`
/// means no native override; rendering an inherited value must not save it.
#[derive(Debug, Clone, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct NativeField {
    pub(crate) id: String,
    pub(crate) kind: NativeFieldKind,
    pub(crate) value: Value,
    pub(crate) effective_value: Value,
    /// Technical origin identifier supplied by the engine, such as `commandLine`.
    pub(crate) effective_source: String,
}

/// Native UI controls; no secret/password control is part of this projection.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum NativeFieldKind {
    Text,
    File,
    Directory,
    Boolean,
    StringList,
}

/// A user-confirmed draft is bound to the exact source and snapshot revision.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct NativeEdits {
    #[serde(rename = "sourceID")]
    pub(crate) source_id: String,
    pub(crate) revision: String,
    pub(crate) values: BTreeMap<String, Value>,
}

/// Provider reply normalization; the host retains its operation/configuration
/// identity while decoding and rejects a late snapshot before presenting it.
#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
pub(crate) struct DecodeConfigurationRequest {
    pub(crate) result: Value,
}

/// Uses the same selected tool, options, environment, and workspace session as
/// the model and execution paths. Reading native facts never applies an edit.
pub(crate) fn plan(
    declaration: &BuildSystemDeclaration,
    request: &OutputPlanRequest,
) -> Validation<Value> {
    if declaration.configuration.is_none() {
        return Err(plans::unavailable(declaration, "native configuration"));
    }
    if request.output_file.is_some() || request.project.is_some() {
        return Err(plans::invalid_selection(
            "Native configuration uses an instance and no output file or model project.",
        ));
    }
    let context = plans::PlanContext::new(declaration, &request.base)?;
    let provider = declaration
        .provider
        .as_ref()
        .ok_or_else(|| plans::unavailable(declaration, "a provider"))?;
    Ok(context.provider_plan(
        provider,
        "lithe/build/configuration",
        "litheBuildConfiguration",
        plans::provider_hints(request)?,
    ))
}

/// Validates all fields before they become a settings form or write binding.
pub(crate) fn decode(
    declaration: &BuildSystemDeclaration,
    request: &DecodeConfigurationRequest,
) -> Validation<Value> {
    if declaration.configuration.is_none() {
        return Err(plans::unavailable(declaration, "native configuration"));
    }
    let snapshot: ConfigurationSnapshot = serde_json::from_value(request.result.clone())
        .map_err(|_| invalid("The provider returned an invalid configuration document."))?;
    validate(&snapshot)?;
    Ok(json!(snapshot))
}

fn invalid(message: &str) -> crate::plugins::declarative::PluginRejection {
    crate::plugins::declarative::PluginRejection::new("plugin.build.invalidConfiguration", message)
}

/// Shared by snapshot decoding and format-independent edit planning.
pub(crate) fn validate(snapshot: &ConfigurationSnapshot) -> Validation<()> {
    if snapshot.format != "litheBuildConfiguration"
        || snapshot.version != 1
        || snapshot.sources.len() > MAX_SOURCES
    {
        return Err(invalid("Unsupported or oversized native configuration."));
    }
    let mut sources = BTreeSet::new();
    let mut uris: BTreeMap<&str, &NativeSource> = BTreeMap::new();
    for source in &snapshot.sources {
        // Upstream may select one file in two scopes. Such an alias is only
        // presentable when both scopes are read-only and describe exact facts.
        let invalid_alias = uris.get(source.uri.as_str()).is_some_and(|previous| {
            previous.writable
                || source.writable
                || previous.revision != source.revision
                || previous.fields != source.fields
        });
        uris.insert(source.uri.as_str(), source);
        let uri = url::Url::parse(&source.uri)
            .map_err(|_| invalid("A native configuration source needs a file URI."))?;
        if !identifier(&source.id)
            || !sources.insert(&source.id)
            || invalid_alias
            || source.uri.len() > MAX_TEXT
            || uri.scheme() != "file"
            || !uri.username().is_empty()
            || uri.password().is_some()
            || uri.query().is_some()
            || uri.fragment().is_some()
            || uri.path().is_empty()
            || !revision(&source.revision)
            || source.scope == SourceScope::Installation && source.writable
            || source.fields.len() > MAX_FIELDS
        {
            return Err(invalid(
                "Invalid native configuration source or write scope.",
            ));
        }
        let mut ids = BTreeSet::new();
        for field in &source.fields {
            if !identifier(&field.id)
                || !ids.insert(&field.id)
                || !value_matches(field.kind, &field.value)
                || !value_matches(field.kind, &field.effective_value)
                || !identifier(&field.effective_source)
                || sensitive(&field.id)
            {
                return Err(invalid("Invalid, sensitive, or duplicate native field."));
            }
        }
    }
    Ok(())
}

/// Returns only fields the user actually changed. Unchanged inherited display
/// values never manufacture a native override.
pub(crate) fn changed_fields<'a>(
    snapshot: &'a ConfigurationSnapshot,
    edits: &NativeEdits,
) -> Validation<(&'a NativeSource, Vec<&'a NativeField>)> {
    // Callers retrieve validated draft values by the returned field IDs.
    validate(snapshot)?;
    let source = snapshot
        .sources
        .iter()
        .find(|source| source.id == edits.source_id)
        .ok_or_else(|| invalid("The edited native source is no longer available."))?;
    if !source.writable || source.revision != edits.revision || edits.values.len() > MAX_FIELDS {
        return Err(invalid(
            "The native source is read-only or its revision changed.",
        ));
    }
    let mut changed = Vec::new();
    for (id, value) in &edits.values {
        let field = source
            .fields
            .iter()
            .find(|field| field.id == *id)
            .ok_or_else(|| invalid("The native field is no longer available."))?;
        if !value_matches(field.kind, value) {
            return Err(invalid(
                "The native field value has an invalid type or size.",
            ));
        }
        if *value != field.value {
            changed.push(field);
        }
    }
    Ok((source, changed))
}

fn revision(value: &str) -> bool {
    value == "missing"
        || value.strip_prefix("sha256:").is_some_and(|hex| {
            hex.len() == 64
                && hex
                    .bytes()
                    .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
        })
}

fn field_name(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 128
        && value.bytes().enumerate().all(|(index, byte)| {
            byte.is_ascii_alphabetic()
                || byte == b'_'
                || index > 0 && (byte.is_ascii_digit() || byte == b'-' || byte == b'.')
        })
}

fn sensitive(value: &str) -> bool {
    let lower = value.to_ascii_lowercase();
    [
        "password",
        "passphrase",
        "token",
        "secret",
        "credential",
        "privatekey",
    ]
    .iter()
    .any(|word| lower.contains(word))
}

fn value_matches(kind: NativeFieldKind, value: &Value) -> bool {
    if value.is_null() {
        return true;
    }
    let text = |value: &Value| {
        value.as_str().is_some_and(|value| {
            value.len() <= MAX_TEXT
                && !value
                    .chars()
                    .any(|character| character == '\0' || character == '\r' || character == '\n')
        })
    };
    match kind {
        NativeFieldKind::Text | NativeFieldKind::File | NativeFieldKind::Directory => text(value),
        NativeFieldKind::Boolean => value.is_boolean(),
        NativeFieldKind::StringList => value
            .as_array()
            .is_some_and(|values| values.len() <= 64 && values.iter().all(text)),
    }
}

fn identifier(value: &str) -> bool {
    value.len() <= 64 && field_name(value)
}

/// A provider prepares replacement bytes in an already-existing host-owned file.
/// Neither the original document nor its replacement crosses the JSON boundary.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct EditPlanRequest {
    #[serde(flatten)]
    pub(crate) plan: OutputPlanRequest,
    pub(crate) snapshot: ConfigurationSnapshot,
    pub(crate) edits: NativeEdits,
}

/// The host allocates the output inside its isolated workspace state directory.
/// Providers open it without creation, so late cancelled work cannot recreate it.
pub(crate) fn edit_plan(
    declaration: &BuildSystemDeclaration,
    request: &EditPlanRequest,
) -> Validation<Value> {
    if declaration.configuration.is_none() || request.plan.project.is_some() {
        return Err(plans::unavailable(
            declaration,
            "native configuration editing",
        ));
    }
    changed_fields(&request.snapshot, &request.edits)?;
    let output = plans::output_file(
        request.plan.output_file.as_deref(),
        super::manifest::OutputChannel::OutputFile,
    )?
    .ok_or_else(|| invalid("A host-owned configuration output file is required."))?;
    let state = request
        .plan
        .base
        .workspace_state_directory
        .as_deref()
        .ok_or_else(|| invalid("Configuration editing requires isolated workspace state."))?;
    let output_path = std::path::Path::new(&output);
    let state_path = std::path::Path::new(state);
    if !state_path.is_absolute()
        || output_path == state_path
        || !output_path.starts_with(state_path)
        || output_path
            .components()
            .any(|part| matches!(part, std::path::Component::ParentDir))
        || request.snapshot.sources.iter().any(|source| {
            url::Url::parse(&source.uri)
                .ok()
                .and_then(|uri| uri.to_file_path().ok())
                .is_some_and(|path| path == output_path)
        })
    {
        return Err(invalid(
            "Configuration output must be a private host-owned staging file.",
        ));
    }
    let context = plans::PlanContext::new(declaration, &request.plan.base)?;
    let provider = declaration
        .provider
        .as_ref()
        .ok_or_else(|| plans::unavailable(declaration, "a provider"))?;
    let mut params = plans::provider_hints(&request.plan)?;
    params.insert("snapshot".into(), json!(request.snapshot));
    params.insert("edits".into(), json!({"sourceID":request.edits.source_id,"revision":request.edits.revision,"values":request.edits.values}));
    params.insert("outputFile".into(), json!(output));
    Ok(context.provider_plan(
        provider,
        "lithe/build/editConfiguration",
        "litheConfigurationEdit",
        params,
    ))
}

/// Bounded receipt only; private native document bytes stay in staging storage.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct EditReceipt {
    format: String,
    version: u32,
    #[serde(rename = "sourceID")]
    source_id: String,
    revision: String,
    changed: bool,
}

/// Receipt validation uses the same confirmed draft as planning.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct DecodeEditRequest {
    snapshot: ConfigurationSnapshot,
    edits: NativeEdits,
    result: Value,
}

/// Rejects unexpected result fields, source substitution and invalid revisions.
pub(crate) fn decode_edit(
    declaration: &BuildSystemDeclaration,
    request: &DecodeEditRequest,
) -> Validation<Value> {
    if declaration.configuration.is_none() {
        return Err(plans::unavailable(
            declaration,
            "native configuration editing",
        ));
    }
    let (source, changed) = changed_fields(&request.snapshot, &request.edits)?;
    let receipt: EditReceipt = serde_json::from_value(request.result.clone())
        .map_err(|_| invalid("Invalid configuration edit receipt."))?;
    if receipt.format != "litheConfigurationEdit"
        || receipt.version != 1
        || receipt.source_id != source.id
        || !revision(&receipt.revision)
        || receipt.changed && (receipt.revision == "missing" || changed.is_empty())
        || !receipt.changed && receipt.revision != source.revision
    {
        return Err(invalid("Invalid configuration edit receipt."));
    }
    Ok(json!({"sourceID":receipt.source_id,"revision":receipt.revision,"changed":receipt.changed}))
}
