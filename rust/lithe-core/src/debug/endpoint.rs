//! Validation for the IDE-to-adapter endpoint, separate from a debuggee target.

use serde::Deserialize;
use serde_json::{json, Value};

use crate::protocol::{CoreError, ErrorCode};

/// Checks a user-selected DAP endpoint without DNS, sockets or implied consent.
/// Unknown names are remote even if they later resolve to a loopback address.
pub(crate) fn validate_adapter_endpoint(payload: Value) -> Result<Value, CoreError> {
    #[derive(Deserialize)]
    #[serde(deny_unknown_fields)]
    struct Endpoint {
        host: String,
        port: u16,
    }
    let endpoint: Endpoint = serde_json::from_value(payload).map_err(|error| {
        CoreError::new(ErrorCode::InvalidRequest, "Invalid DAP endpoint.")
            .with_details(error.to_string())
    })?;
    if let Some(problem) = super::adapters::host_problem(&endpoint.host) {
        return Err(CoreError::new(ErrorCode::InvalidRequest, problem));
    }
    if endpoint.port == 0 {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "A port is 1-65535.",
        ));
    }
    Ok(json!({
        "host": endpoint.host,
        "port": endpoint.port,
        "remote": !super::adapters::is_loopback_host(&endpoint.host),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dap_endpoint_contract_fixtures_match_validation_and_consent_classification() {
        let fixture: Value = serde_json::from_str(include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../shared/fixtures/debug/adapter-endpoints-v1.json"
        )))
        .expect("endpoint fixture is JSON");
        for case in fixture["cases"].as_array().expect("fixture cases") {
            let result = validate_adapter_endpoint(case["input"].clone());
            if let Some(remote) = case.get("remote") {
                let endpoint = result.expect("valid endpoint");
                assert_eq!(endpoint["remote"], *remote, "{case}");
                assert_eq!(endpoint["host"], case["input"]["host"], "{case}");
                assert_eq!(endpoint["port"], case["input"]["port"], "{case}");
            } else {
                assert!(result.is_err(), "{case}");
            }
        }
    }
}
