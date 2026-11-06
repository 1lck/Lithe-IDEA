//! Exposes the existing backend host-method rules to native dispatchers.
//!
//! Session ownership and context lifetime remain with the native host. The
//! method table and grant decisions stay with the same Core code that already
//! validates backend requests, so a new method cannot widen an old grant.

use crate::lsp::interface::plugin_function::{self, HOST_METHODS, HOST_SERVICE_FUNCTIONS};
use crate::protocol::{CoreError, ErrorCode};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::BTreeSet;

/// Describes host methods using the same catalog as backend request routing.
pub(crate) fn describe_command(payload: Value) -> Result<Value, CoreError> {
    if payload.as_object().is_none_or(|object| !object.is_empty()) {
        return Err(invalid());
    }
    // Include every method compiled into this Core, irrespective of which
    // protocol version a particular backend later negotiates.
    let implicit = plugin_function::capabilities_answer(u64::MAX, &BTreeSet::new());
    let methods: Vec<Value> = HOST_METHODS
        .iter()
        .map(|entry| {
            let is_implicit = implicit["services"][entry.service]["methods"]
                .as_array()
                .is_some_and(|methods| methods.iter().any(|method| method == entry.method));
            let grant = if is_implicit {
                None
            } else if entry.permission.is_some() {
                Some(entry.method)
            } else {
                Some(entry.service)
            };
            json!({"method":entry.method,"service":entry.service,"grant":grant,
                "coreServed":entry.service == HOST_SERVICE_FUNCTIONS})
        })
        .collect();
    Ok(json!({"methods":methods}))
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Authorization {
    method: String,
    service: String,
    grants: Vec<String>,
}

/// Reuses Core's capability decisions with the host's current session grants.
pub(crate) fn authorize_command(payload: Value) -> Result<Value, CoreError> {
    let input: Authorization = serde_json::from_value(payload).map_err(|_| invalid())?;
    if input.method.len() > 256
        || input.service.len() > 128
        || input.grants.len() > 512
        || input.grants.iter().any(|grant| grant.len() > 256)
    {
        return Err(invalid());
    }
    let matching = HOST_METHODS
        .iter()
        .any(|entry| entry.method == input.method && entry.service == input.service);
    if !matching {
        return Ok(json!({"allowed":false,"code":"plugin.host.unavailable"}));
    }
    let grants = input.grants.into_iter().collect();
    let capabilities = plugin_function::capabilities_answer(u64::MAX, &grants);
    let allowed = capabilities["services"][&input.service]["methods"]
        .as_array()
        .is_some_and(|methods| methods.iter().any(|method| method == &input.method));
    Ok(if allowed {
        json!({"allowed":true})
    } else {
        json!({"allowed":false,"code":"plugin.host.permissionDenied"})
    })
}

fn invalid() -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, "Invalid host API request.")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn catalog_preserves_legacy_and_individual_grants() {
        let catalog = describe_command(json!({})).unwrap();
        let entries = catalog["methods"].as_array().unwrap();
        let method = |name: &str| {
            entries
                .iter()
                .find(|entry| entry["method"] == name)
                .unwrap()
        };
        assert_eq!(
            method("lithe/host/workspace/listContexts")["grant"],
            "workspace"
        );
        assert_eq!(
            method("lithe/host/workspace/readFile")["grant"],
            "lithe/host/workspace/readFile"
        );
        assert!(method("lithe/host/subscriptions/dispose")["grant"].is_null());
        assert_eq!(method("lithe/host/functions/invoke")["coreServed"], true);
    }

    #[test]
    fn authorization_does_not_widen_metadata_grants_or_accept_spoofed_services() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../../shared/fixtures/plugins/host-api-v1.json"
        ))
        .unwrap();
        for case in fixture["authorization"].as_array().unwrap() {
            assert_eq!(
                authorize_command(case["input"].clone()).unwrap(),
                case["expected"],
                "{}",
                case["name"]
            );
        }
    }
}
