//! The build-provider protocol a plugin's LSP base-protocol process speaks
//! next to, or instead of, a language server.
//!
//! The manifest only says how to start the process; the protocol version is
//! negotiated in `initialize` under `capabilities.experimental.litheBuild`.
//! The host offers every version it speaks and the provider answers the one
//! it chose. Build requests are written only to a session that answered a
//! version the host offered, so a shared provider that does not speak the
//! protocol keeps serving its language. The rules live in the plugin contract
//! (`shared/contracts/plugins/v1/README.md`, "Build providers").

use serde_json::{json, Value};

/// Key under `capabilities.experimental` on both sides of the exchange.
const EXPERIMENTAL_KEY: &str = "litheBuild";

/// Build-provider protocol versions this client speaks, in preference order.
const SUPPORTED_VERSIONS: [u64; 10] = [10, 9, 8, 7, 6, 5, 4, 3, 2, 1];

/// Feature name recorded in the session's server capabilities once a
/// provider answered a supported version.
pub(crate) const BUILD_PROVIDER_FEATURE: &str = "litheBuild";

/// Version 2 uses the same workspace session and operation lifecycle.
pub(crate) const EXECUTE_METHOD: &str = "lithe/build/execute";
/// Version 4 prepares a bounded launch, while the host owns the application.
pub(crate) const PREPARE_RUN_METHOD: &str = "lithe/build/prepareRun";
/// The negotiated ability to accept host-resolved public model inputs.
pub(crate) const MODEL_INPUTS_FEATURE: &str = "litheBuildModelInputs";
/// Old backends cannot silently ignore cross-provider context.
pub(crate) fn model_inputs_negotiated(capabilities: &Value) -> bool {
    capabilities
        .pointer("/experimental/litheBuild/version")
        .and_then(Value::as_u64)
        .is_some_and(|version| matches!(version, 6 | 7 | 8 | 9 | 10))
}

/// Version 7 returns non-sensitive native settings and source/write metadata.
pub(crate) const CONFIGURATION_METHOD: &str = "lithe/build/configuration";
/// Admission feature keeps native source metadata away from older protocols.
pub(crate) const CONFIGURATION_FEATURE: &str = "litheBuildConfiguration";
/// Only version 7 can accept source-backed configuration reads.
pub(crate) fn configuration_negotiated(capabilities: &Value) -> bool {
    capabilities
        .pointer("/experimental/litheBuild/version")
        .and_then(Value::as_u64)
        .is_some_and(|version| matches!(version, 7 | 8 | 9 | 10))
}

/// Version 8 returns canonical reports with the completing test operation.
pub(crate) const TEST_REPORTS_FEATURE: &str = "litheBuildTestReports";
/// Older providers cannot silently fall back to host-owned report discovery.
pub(crate) fn test_reports_negotiated(capabilities: &Value) -> bool {
    capabilities
        .pointer("/experimental/litheBuild/version")
        .and_then(Value::as_u64)
        .is_some_and(|version| matches!(version, 8 | 9 | 10))
}

/// Version 9 passes public semantic selectors unchanged to the owning backend.
pub(crate) const TEST_SELECTORS_FEATURE: &str = "litheBuildTestSelectors";
/// An old backend must never widen a filtered request to all tests.
pub(crate) fn test_selectors_negotiated(capabilities: &Value) -> bool {
    capabilities
        .pointer("/experimental/litheBuild/version")
        .and_then(Value::as_u64)
        .is_some_and(|version| matches!(version, 9 | 10))
}

/// Admission feature for typed user options and host-owned service/task launches.
pub(crate) const RUN_OPTIONS_FEATURE: &str = "litheBuildRunOptions";
/// Older sessions cannot silently discard user arguments or launch ownership.
pub(crate) fn run_options_negotiated(capabilities: &Value) -> bool {
    capabilities
        .pointer("/experimental/litheBuild/version")
        .and_then(Value::as_u64)
        == Some(10)
}

/// Version 5 prepares a native debug target, never an adapter process.
pub(crate) const PREPARE_DEBUG_METHOD: &str = "lithe/build/prepareDebug";
/// Admission feature for native debug preparation.
pub(crate) const DEBUG_PREPARATION_FEATURE: &str = "litheDebugPreparation";
/// Debug preparation requires the explicit version 5 agreement.
pub(crate) fn debug_preparation_negotiated(capabilities: &Value) -> bool {
    capabilities
        .pointer("/experimental/litheBuild/version")
        .and_then(Value::as_u64)
        .is_some_and(|version| matches!(version, 5 | 6 | 7 | 8 | 9 | 10))
}

/// Admission feature for the version 4 method.
pub(crate) const RUN_PREPARATION_FEATURE: &str = "litheRunPreparation";
/// Version 3 adds tests while retaining the bounded execution lifecycle.
pub(crate) const TEST_METHOD: &str = "lithe/build/test";
/// Version 3 returns exact selectors; decoding remains a separate Core command.
pub(crate) const DISCOVER_TESTS_METHOD: &str = "lithe/build/discoverTests";
/// Feature required before writing a version 3 test request.
pub(crate) const TEST_EXECUTION_FEATURE: &str = "litheBuildTestExecution";
/// Progress never uses caller-chosen host operation IDs.
pub(crate) const PROGRESS_METHOD: &str = "lithe/build/progress";
/// Separate feature so version 1 cannot accidentally execute version 2 tasks.
pub(crate) const EXECUTION_FEATURE: &str = "litheBuildExecution";

const VERSION_1_METHODS: [&str; 2] = ["lithe/build/model", "lithe/build/dependencies"];

/// The client half of the negotiation, placed under `capabilities.experimental`.
pub(crate) fn client_experimental_capabilities() -> Value {
    json!({ EXPERIMENTAL_KEY: { "versions": SUPPORTED_VERSIONS } })
}

/// Whether the server's `initialize` capabilities chose a version this client
/// offered. Unknown fields in the answer are ignored, as the contract requires.
pub(crate) fn negotiated(capabilities: &Value) -> bool {
    capabilities
        .get("experimental")
        .and_then(|experimental| experimental.get(EXPERIMENTAL_KEY))
        .and_then(|answer| answer.get("version"))
        .and_then(Value::as_u64)
        .is_some_and(|version| SUPPORTED_VERSIONS.contains(&version))
}

/// Whether `method` is a request of the negotiated protocol.
pub(crate) fn is_build_method(method: &str) -> bool {
    VERSION_1_METHODS.contains(&method)
        || is_execution_method(method)
        || method == DISCOVER_TESTS_METHOD
        || method == PREPARE_RUN_METHOD
        || method == PREPARE_DEBUG_METHOD
        || method == CONFIGURATION_METHOD
}

/// Whether the method shares bounded output, progress, and final result handling.
pub(crate) fn is_execution_method(method: &str) -> bool {
    matches!(method, EXECUTE_METHOD | TEST_METHOD)
}

/// True only for the execution protocol, not merely any negotiated provider.
pub(crate) fn execution_negotiated(capabilities: &Value) -> bool {
    capabilities
        .pointer("/experimental/litheBuild/version")
        .and_then(Value::as_u64)
        .is_some_and(|version| matches!(version, 2 | 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10))
}

/// Tests require an explicit version 3 agreement, independent of task support.
pub(crate) fn tests_negotiated(capabilities: &Value) -> bool {
    capabilities
        .pointer("/experimental/litheBuild/version")
        .and_then(Value::as_u64)
        .is_some_and(|version| matches!(version, 3 | 4 | 5 | 6 | 7 | 8 | 9 | 10))
}

/// A preparation has progress and cancellation, but its reply is a launch plan.
pub(crate) fn is_progress_method(method: &str) -> bool {
    is_execution_method(method) || method == PREPARE_RUN_METHOD || method == PREPARE_DEBUG_METHOD
}

/// Run preparation requires an explicit version 4 agreement.
pub(crate) fn run_preparation_negotiated(capabilities: &Value) -> bool {
    capabilities
        .pointer("/experimental/litheBuild/version")
        .and_then(Value::as_u64)
        .is_some_and(|version| matches!(version, 4 | 5 | 6 | 7 | 8 | 9 | 10))
}

/// Normalizes bounded progress; the engine checks the pending request identity.
pub(crate) fn progress(params: Option<&Value>) -> Option<Value> {
    let params = params?.as_object()?;
    let id = params.get("operationID")?.as_str()?;
    let mut result = json!({ "operationID": id });
    for (field, limit) in [("message", 4096), ("output", 65536)] {
        if let Some(value) = params.get(field) {
            let text = value.as_str()?;
            if text.len() > limit {
                return None;
            }
            result[field] = json!(text);
        }
    }
    if let Some(value) = params.get("percentage") {
        result["percentage"] = json!(value.as_u64().filter(|value| *value <= 100)?);
    }
    Some(result)
}

/// Stable outcome for a provider-owned task. Tool failure is an exit code,
/// while malformed replies and JSON-RPC errors are protocol failures.
pub(crate) fn execution_outcome(
    reply: &Value,
    reports_negotiated: bool,
) -> Result<Value, (&'static str, String)> {
    if reply.get("error").is_some() {
        return Err((
            "plugin.build.failed",
            reply
                .pointer("/error/message")
                .and_then(Value::as_str)
                .unwrap_or("The build provider rejected the task.")
                .chars()
                .take(4096)
                .collect(),
        ));
    }
    let invalid = (
        "plugin.build.invalidResult",
        "The build provider returned an invalid task result.".to_string(),
    );
    let value = reply.get("result").ok_or_else(|| invalid.clone())?;
    let exit = value
        .get("exitCode")
        .and_then(Value::as_i64)
        .filter(|code| i32::try_from(*code).is_ok())
        .ok_or_else(|| invalid.clone())?;
    let output = value
        .get("output")
        .and_then(Value::as_str)
        .filter(|text| text.len() <= 32 * 1024 * 1024)
        .ok_or_else(|| invalid.clone())?;
    let mut result = json!({ "exitCode": exit, "output": output });
    if let Some(reports) = value.get("testResults") {
        if !reports_negotiated
            || !reports.is_object()
            || serde_json::to_vec(reports).map_or(usize::MAX, |value| value.len()) > 8 * 1024 * 1024
        {
            return Err(invalid);
        }
        result["testResults"] = reports.clone();
    }
    Ok(json!({ "value": result }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_an_offered_version_counts_as_negotiated() {
        assert!(negotiated(
            &json!({ "experimental": { "litheBuild": { "version": 1, "future": true } } })
        ));
        // No answer, a version the host never offered, or a malformed answer
        // must keep build requests off the session.
        assert!(!negotiated(&json!({})));
        assert!(!negotiated(
            &json!({ "experimental": { "litheBuild": {} } })
        ));
        assert!(!negotiated(
            &json!({ "experimental": { "litheBuild": { "version": 99 } } })
        ));
        assert!(!negotiated(
            &json!({ "experimental": { "litheBuild": { "version": "1" } } })
        ));
        assert!(!negotiated(
            &json!({ "experimental": { "litheBuild": { "versions": [1] } } })
        ));
    }

    #[test]
    fn only_typed_provider_requests_are_accepted() {
        assert!(is_build_method("lithe/build/model"));
        assert!(is_build_method("lithe/build/dependencies"));
        assert!(is_build_method("lithe/build/execute"));
        assert!(is_build_method("lithe/build/test"));
        assert!(!is_build_method("workspace/executeCommand"));
    }
    #[test]
    fn test_protocol_does_not_remove_task_support() {
        let capabilities = json!({"experimental":{"litheBuild":{"version":3}}});
        assert!(negotiated(&capabilities));
        assert!(execution_negotiated(&capabilities));
        assert!(tests_negotiated(&capabilities));
        assert!(!tests_negotiated(
            &json!({"experimental":{"litheBuild":{"version":2}}})
        ));
    }

    #[test]
    fn inline_reports_require_their_protocol_and_are_retained_without_host_parsing() {
        let result = json!({"result":{"exitCode":1,"output":"failed","testResults":{"format":"litheTestResults","version":1,"tests":[]}}});
        assert!(execution_outcome(&result, false).is_err());
        assert_eq!(
            execution_outcome(&result, true).unwrap()["value"],
            result["result"]
        );
        for invalid in [json!(null), json!([]), json!("x")] {
            let mut reply = result.clone();
            reply["result"]["testResults"] = invalid;
            assert!(execution_outcome(&reply, true).is_err());
        }
        assert!(!test_reports_negotiated(
            &json!({"experimental":{"litheBuild":{"version":7}}})
        ));
        assert!(test_reports_negotiated(
            &json!({"experimental":{"litheBuild":{"version":8}}})
        ));
    }

    #[test]
    fn execution_replies_and_progress_match_the_shared_contract() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../../../shared/contracts/plugins/v1/fixtures/build-execution-protocol.json"
        ))
        .unwrap();
        assert_eq!(
            execution_outcome(&json!({"result": fixture["result"]}), false).unwrap(),
            json!({"value": fixture["result"]})
        );
        for result in fixture["invalidResults"].as_array().unwrap() {
            assert_eq!(
                execution_outcome(&json!({"result": result}), false)
                    .unwrap_err()
                    .0,
                "plugin.build.invalidResult"
            );
        }
        assert_eq!(
            execution_outcome(&json!({"error": {"message": "private"}}), false)
                .unwrap_err()
                .0,
            "plugin.build.failed"
        );
        assert_eq!(
            progress(Some(&fixture["progress"])),
            Some(fixture["progress"].clone())
        );
        for invalid in fixture["invalidProgress"].as_array().unwrap() {
            assert!(progress(Some(invalid)).is_none());
        }
        assert!(progress(Some(&json!({"operationID":"1","output":"x".repeat(65537)}))).is_none());
        assert!(execution_outcome(
            &json!({"result": {"exitCode": 0,"output":"x".repeat(32*1024*1024+1)}}),
            false
        )
        .is_err());
    }
}

#[cfg(test)]
mod configuration_tests {
    use super::*;
    #[test]
    fn native_configuration_requires_its_own_wire_version_without_losing_old_methods() {
        let old = json!({"experimental":{"litheBuild":{"version":6}}});
        let current = json!({"experimental":{"litheBuild":{"version":7}}});
        assert!(!configuration_negotiated(&old));
        assert!(configuration_negotiated(&current));
        assert!(is_build_method(CONFIGURATION_METHOD));
        assert!(model_inputs_negotiated(&current));
        assert!(execution_negotiated(&current));
        assert!(tests_negotiated(&current));
        assert!(run_preparation_negotiated(&current));
        assert!(debug_preparation_negotiated(&current));
    }
}
