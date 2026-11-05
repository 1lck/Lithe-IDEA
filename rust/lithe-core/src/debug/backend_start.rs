//! `lithe/host/debug/start`: a plugin backend starts a debug session on an adapter it declares.
//!
//! The backend supplies the adapter's DAP launch or attach arguments. Core checks that the
//! adapter belongs to the plugin and serves the request, that the arguments fit the size
//! budget, and that they do not name keys the host owns. Starting the adapter, the transport
//! and the session are the generic debug engine's job; nothing here is specific to a language.

use super::adapters::DebugRequest;
use crate::plugins::declarative::{
    decode_payload, is_identifier, outcome, validate_manifest_value, DeclarativePluginManifest,
    PluginRejection, Validation,
};
use crate::protocol::CoreError;
use serde::Deserialize;
use serde_json::{json, Map, Value};

/// Serialized size of `configuration`, in bytes.
const MAX_CONFIGURATION_BYTES: usize = 256 * 1024;
const MAX_LABEL_CHARS: usize = 256;
const MAX_ADAPTER_ID_BYTES: usize = 64;
/// DAP launch argument the host sets from the session mode (Run versus Debug).
const NO_DEBUG_KEY: &str = "noDebug";
/// Keys with this prefix carry the host's own session bookkeeping across DAP.
const HOST_KEY_PREFIX: &str = "__";

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct DecodePayload {
    manifest: Value,
    params: Value,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StartParams {
    /// A reference the host resolved before the service saw the request.
    #[serde(default, rename = "context")]
    _context: Option<Value>,
    label: String,
    adapter: String,
    request: DebugRequest,
    configuration: Map<String, Value>,
}

fn invalid(field: &str, message: impl Into<String>) -> PluginRejection {
    PluginRejection::at("plugin.debug.invalidStart", field, message)
}

/// `debug.decodeBackendConfiguration`: the qualified adapter, request, label and checked
/// arguments of one backend-initiated debug start.
pub(crate) fn decode_backend_configuration_command(payload: Value) -> Result<Value, CoreError> {
    let payload: DecodePayload = decode_payload(payload, "debug.decodeBackendConfiguration")?;
    Ok(outcome(
        validate_manifest_value(payload.manifest)
            .and_then(|manifest| decode(&manifest, payload.params))
            .map(|start| ("start", start)),
    ))
}

fn decode(manifest: &DeclarativePluginManifest, params: Value) -> Validation<Value> {
    let params: StartParams = serde_json::from_value(params)
        .map_err(|_| invalid("params", "The debug start parameters are malformed."))?;
    let label = &params.label;
    if label.trim().is_empty()
        || label.chars().count() > MAX_LABEL_CHARS
        || label.chars().any(char::is_control)
    {
        return Err(invalid(
            "label",
            "A label is 1 to 256 characters without control characters.",
        ));
    }
    let local = own_adapter(manifest, &params.adapter)?;
    let adapter = manifest
        .debug_adapters()
        .iter()
        .find(|adapter| adapter.id == local)
        .ok_or_else(|| {
            PluginRejection::at(
                "plugin.debug.unknownAdapter",
                "adapter",
                "The plugin declares no such debug adapter.",
            )
        })?;
    if !adapter.requests.contains(&params.request) {
        return Err(invalid(
            "request",
            "The adapter does not serve this request.",
        ));
    }
    if serde_json::to_vec(&params.configuration).map_or(usize::MAX, |bytes| bytes.len())
        > MAX_CONFIGURATION_BYTES
    {
        return Err(PluginRejection::at(
            "plugin.debug.limitExceeded",
            "configuration",
            "The configuration is larger than 256 KiB.",
        ));
    }
    if let Some(key) = params
        .configuration
        .keys()
        .find(|key| key.as_str() == NO_DEBUG_KEY || key.starts_with(HOST_KEY_PREFIX))
    {
        return Err(invalid(
            &format!("configuration.{key}"),
            "The key belongs to the host and cannot be set by a plugin.",
        ));
    }
    Ok(json!({
        "adapterID": format!("{}/{}", manifest.id(), adapter.id),
        "request": params.request,
        "label": params.label,
        "configuration": params.configuration,
    }))
}

/// The plugin-local adapter ID of `adapter`, which is either local or qualified by this plugin.
fn own_adapter<'a>(manifest: &DeclarativePluginManifest, adapter: &'a str) -> Validation<&'a str> {
    let local = match adapter.split_once('/') {
        Some((plugin, _)) if plugin != manifest.id() => {
            return Err(PluginRejection::at(
                "plugin.debug.foreignAdapter",
                "adapter",
                "A plugin starts only the debug adapters it declares itself.",
            ));
        }
        Some((_, local)) => local,
        None => adapter,
    };
    if !is_identifier(local) || local.len() > MAX_ADAPTER_ID_BYTES {
        return Err(invalid("adapter", "The adapter ID is malformed."));
    }
    Ok(local)
}
