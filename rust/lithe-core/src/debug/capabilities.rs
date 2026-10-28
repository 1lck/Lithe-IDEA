//! Capability snapshot and client-extension registry for one debug session.
//!
//! A capability is usable only when the adapter negotiated it, this build registered the
//! host extension that handles it, and the session is authorized to use it. Platforms
//! read the resulting snapshot instead of inspecting adapter or plugin names.

use super::projection_v2::{is_capability_name, CapabilityState};
use crate::protocol::CoreError;
use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, BTreeSet};

/// Adapter capabilities whose DAP requests this Core implements.
///
/// Adding a name here is how an extension is registered: it makes the capability's
/// `extension` state true and lets `supported` follow the adapter and authorization.
pub(crate) const REGISTERED_ADAPTER_CAPABILITIES: &[&str] = &[
    "supportsConfigurationDoneRequest",
    "supportsConditionalBreakpoints",
    "supportsHitConditionalBreakpoints",
    "supportsLogPoints",
    "supportsFunctionBreakpoints",
    "supportsDataBreakpoints",
    "supportsExceptionOptions",
    "supportsExceptionFilterOptions",
    "supportsSetVariable",
    "supportsCancelRequest",
    "supportsSingleThreadExecutionRequests",
    "supportsRestartRequest",
    "supportsTerminateRequest",
    "supportsStepBack",
    "supportsExceptionInfoRequest",
    "supportsStepInTargetsRequest",
    "supportsGotoTargetsRequest",
    "supportsCompletionsRequest",
    "supportsDisassembleRequest",
    "supportsSteppingGranularity",
    "supportsInstructionBreakpoints",
    "supportsReadMemoryRequest",
];

/// The session cannot reach `configurationDone` ordering without this capability.
const NON_DISABLEABLE: &[&str] = &["supportsConfigurationDoneRequest"];

/// Host features that gate a client capability advertised in `initialize`.
#[derive(Debug, Clone, Copy)]
pub(crate) struct HostFeatures {
    pub run_in_terminal: bool,
    pub start_debugging: bool,
}

/// Client capabilities for the DAP `initialize` request.
///
/// Only extensions registered in this build may be declared; everything else stays
/// `false` so adapters never send requests the Core cannot answer. Memory references are
/// declared because `readMemory` is registered (read-only: `writeMemory` has no extension);
/// progress reporting has no registered extension yet.
pub(crate) fn client_capabilities(host: HostFeatures) -> Value {
    json!({
        "supportsRunInTerminalRequest": host.run_in_terminal,
        "supportsStartDebuggingRequest": host.start_debugging,
        "supportsMemoryReferences": true,
        "supportsProgressReporting": false,
        "supportsInvalidatedEvent": false
    })
}

/// Rejects authorization overrides that name unknown or mandatory capabilities.
pub(crate) fn validate_disabled(disabled: &[String]) -> Result<BTreeSet<String>, CoreError> {
    let mut names = BTreeSet::new();
    for name in disabled {
        if !is_capability_name(name) || !REGISTERED_ADAPTER_CAPABILITIES.contains(&name.as_str()) {
            return Err(super::engine::invalid_request(
                "disabledCapabilities must name registered optional DAP capabilities.",
            ));
        }
        if NON_DISABLEABLE.contains(&name.as_str()) {
            return Err(super::engine::invalid_request(
                "disabledCapabilities cannot disable a capability the session lifecycle needs.",
            ));
        }
        names.insert(name.clone());
    }
    Ok(names)
}

/// Computes every capability the adapter reported plus every registered one.
pub(crate) fn capability_states(
    adapter: &Map<String, Value>,
    disabled: &BTreeSet<String>,
) -> BTreeMap<String, CapabilityState> {
    let reported = adapter
        .keys()
        .map(String::as_str)
        .filter(|name| is_capability_name(name));
    let names: BTreeSet<&str> = reported
        .chain(REGISTERED_ADAPTER_CAPABILITIES.iter().copied())
        .collect();
    names
        .into_iter()
        .map(|name| {
            let adapter_value = adapter.get(name).and_then(Value::as_bool).unwrap_or(false);
            let extension = REGISTERED_ADAPTER_CAPABILITIES.contains(&name);
            let authorized = !disabled.contains(name);
            let state = CapabilityState {
                adapter: adapter_value,
                extension,
                authorized,
                supported: adapter_value && extension && authorized,
            };
            (name.to_string(), state)
        })
        .collect()
}

/// The adapter body with every unsupported capability forced to `false`.
pub(crate) fn effective_body(
    adapter: &Map<String, Value>,
    states: &BTreeMap<String, CapabilityState>,
) -> Value {
    let mut body = adapter.clone();
    for (name, state) in states {
        if !state.supported {
            body.insert(name.clone(), Value::Bool(false));
        }
    }
    Value::Object(body)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn adapter(value: Value) -> Map<String, Value> {
        value.as_object().cloned().unwrap()
    }

    #[test]
    fn supported_requires_adapter_extension_and_authorization() {
        let adapter = adapter(json!({
            "supportsSetVariable": true,
            "supportsRestartRequest": true,
            "supportsWriteMemoryRequest": true,
            "supportsTerminateRequest": false
        }));
        let disabled = validate_disabled(&["supportsRestartRequest".to_string()]).unwrap();
        let states = capability_states(&adapter, &disabled);
        assert!(states["supportsSetVariable"].supported);
        // Adapter offers it but the plugin disabled it.
        assert!(states["supportsRestartRequest"].adapter);
        assert!(!states["supportsRestartRequest"].authorized);
        assert!(!states["supportsRestartRequest"].supported);
        // Adapter offers it but no extension is registered, so the UI never sees it.
        assert!(states["supportsWriteMemoryRequest"].adapter);
        assert!(!states["supportsWriteMemoryRequest"].extension);
        assert!(!states["supportsWriteMemoryRequest"].supported);
        // Registered but not negotiated.
        assert!(states["supportsTerminateRequest"].extension);
        assert!(!states["supportsTerminateRequest"].supported);
        // Absent registered capabilities are still listed so the UI has one source.
        assert!(!states["supportsStepBack"].adapter);
    }

    #[test]
    fn effective_body_clears_unsupported_flags_only() {
        let adapter = adapter(json!({
            "supportsSetVariable": true,
            "supportsWriteMemoryRequest": true,
            "exceptionBreakpointFilters": []
        }));
        let states = capability_states(&adapter, &BTreeSet::new());
        let body = effective_body(&adapter, &states);
        assert_eq!(body["supportsSetVariable"], true);
        assert_eq!(body["supportsWriteMemoryRequest"], false);
        assert!(body["exceptionBreakpointFilters"].is_array());
    }

    #[test]
    fn disabling_rejects_unknown_and_mandatory_capabilities() {
        assert!(validate_disabled(&["supportsWriteMemoryRequest".to_string()]).is_err());
        assert!(validate_disabled(&["notACapability".to_string()]).is_err());
        assert!(validate_disabled(&["supportsConfigurationDoneRequest".to_string()]).is_err());
    }

    #[test]
    fn initialize_declares_only_registered_client_capabilities() {
        let value = client_capabilities(HostFeatures {
            run_in_terminal: true,
            start_debugging: false,
        });
        assert_eq!(value["supportsRunInTerminalRequest"], true);
        assert_eq!(value["supportsStartDebuggingRequest"], false);
        assert_eq!(value["supportsMemoryReferences"], true);
    }
}
