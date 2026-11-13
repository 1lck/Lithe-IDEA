//! Shared policy for the user-selected Java import deadline. Hosts store the
//! optional minute value; Core owns its default, bounds and unit conversion.

use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// The unchanged post-initialize readiness default, in milliseconds.
pub(super) const DEFAULT_TIMEOUT_MS: u64 = 10 * 60_000;

/// Raw application preference; null or omission inherits the Core default.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ReadinessTimeoutRequest {
    /// Whole minutes from 1 through 120. Kept raw so malformed stored values
    /// are rejected before a server process is started.
    pub minutes: Option<Value>,
}

/// The effective deadline and input bounds used by settings and server start.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ReadinessTimeoutPolicy {
    /// Effective value in whole minutes.
    pub minutes: u64,
    /// Value for `lsp.startServer.serviceReadyAbsoluteTimeoutMilliseconds`.
    pub milliseconds: u64,
    /// Inclusive settings bounds, in minutes.
    pub minimum_minutes: u64,
    /// Inclusive upper bound, in minutes.
    pub maximum_minutes: u64,
}

/// Resolves a preference without reading or writing platform storage.
pub fn resolve_readiness_timeout(
    request: ReadinessTimeoutRequest,
) -> Result<ReadinessTimeoutPolicy, CoreError> {
    let minutes = match request.minutes {
        None | Some(Value::Null) => DEFAULT_TIMEOUT_MS / 60_000,
        Some(value) => value
            .as_u64()
            .filter(|value| (1..=120).contains(value))
            .ok_or_else(|| {
                CoreError::new(
                    ErrorCode::InvalidRequest,
                    "Import timeout must be a whole number from 1 through 120 minutes.",
                )
            })?,
    };
    Ok(ReadinessTimeoutPolicy {
        minutes,
        milliseconds: minutes * 60_000,
        minimum_minutes: 1,
        maximum_minutes: 120,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn shared_fixture_matches_the_wire_policy() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../../../shared/fixtures/lsp/readiness-timeout-policy-v1.json"
        ))
        .unwrap();
        for case in fixture["cases"].as_array().unwrap() {
            let request = serde_json::from_value(case["request"].clone()).unwrap();
            let result = resolve_readiness_timeout(request).unwrap();
            assert_eq!(json!(result.milliseconds), case["milliseconds"]);
        }
        for minutes in fixture["invalidMinutes"].as_array().unwrap() {
            assert!(resolve_readiness_timeout(ReadinessTimeoutRequest {
                minutes: Some(minutes.clone())
            })
            .is_err());
        }
    }

    #[test]
    fn resolves_default_sixty_minutes_and_boundaries() {
        for (value, expected) in [
            (Value::Null, 600_000),
            (json!(1), 60_000),
            (json!(60), 3_600_000),
            (json!(120), 7_200_000),
        ] {
            let result = resolve_readiness_timeout(ReadinessTimeoutRequest {
                minutes: Some(value),
            })
            .unwrap();
            assert_eq!(result.milliseconds, expected);
        }
        assert_eq!(
            resolve_readiness_timeout(ReadinessTimeoutRequest { minutes: None })
                .unwrap()
                .milliseconds,
            DEFAULT_TIMEOUT_MS
        );
    }

    #[test]
    fn rejects_invalid_preferences_instead_of_disabling_the_deadline() {
        for value in [
            json!(0),
            json!(-1),
            json!(121),
            json!(1.5),
            json!("60"),
            json!(true),
            json!({}),
            json!(u64::MAX),
        ] {
            assert!(resolve_readiness_timeout(ReadinessTimeoutRequest {
                minutes: Some(value)
            })
            .is_err());
        }
    }
}
