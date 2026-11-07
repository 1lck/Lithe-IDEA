//! Answers the legacy Java command names with Core's request and response shape.
//!
//! The Windows frontend still sends `maven.*`, `java.*`, `spring.index` and
//! `mybatis.index` as ordinary Core requests. [`try_execute`] mirrors the part
//! of Core's dispatcher these commands go through, so the JSON a caller gets
//! back, including every error code and message, does not change.

use crate::java_run_markers::java_run_markers;
use crate::java_source_definition::source_definition;
use crate::java_workspace::{
    java_workspace_policy, jdt_cache_retention, jdt_workspace_fingerprint,
};
use crate::maven;
use crate::mybatis::mybatis_index;
use crate::spring::spring_index;
use lithe_core::{CancellationScope, CoreError, CoreRequest, CoreResponse, ErrorCode};
use serde::de::DeserializeOwned;
use serde::Serialize;

/// Runs `request` when it names a legacy Java command.
///
/// Returns `None` for anything else, including text that is not a request, so
/// the caller can pass the same text on to Core and get Core's own answer.
pub fn try_execute(request: &str) -> Option<String> {
    let parsed: CoreRequest = serde_json::from_str(request).ok()?;
    let command = parsed.command.clone();
    let response = match command.as_str() {
        "maven.scan" => respond(parsed, "Invalid Maven scan request", maven::scan),
        "maven.launchPlan" => respond(
            parsed,
            "Invalid Maven launch-plan request",
            maven::launch_plan,
        ),
        "maven.dependencyPlan" => respond(
            parsed,
            "Invalid Maven dependency-plan request",
            maven::dependency_plan,
        ),
        "maven.dependencies" => respond(
            parsed,
            "Invalid Maven dependencies request",
            maven::dependencies,
        ),
        "maven.diagnostics" => respond(
            parsed,
            "Invalid Maven diagnostics request",
            maven::diagnostics,
        ),
        "maven.testResults" => respond(
            parsed,
            "Invalid Maven test-results request",
            maven::test_results,
        ),
        "java.workspacePolicy" => respond(
            parsed,
            "Invalid Java workspace-policy request",
            java_workspace_policy,
        ),
        "java.jdtCacheRetention" => respond(
            parsed,
            "Invalid JDT LS cache-retention request",
            jdt_cache_retention,
        ),
        "java.jdtWorkspaceFingerprint" => respond(
            parsed,
            "Invalid JDT LS workspace-fingerprint request",
            jdt_workspace_fingerprint,
        ),
        "java.sourceDefinition" => respond(
            parsed,
            "Invalid Java source definition request",
            source_definition,
        ),
        "java.runMarkers" => respond(parsed, "Invalid Java Run-marker request", java_run_markers),
        "spring.index" => respond(parsed, "Invalid Spring index request", spring_index),
        "mybatis.index" => respond(parsed, "Invalid MyBatis index request", mybatis_index),
        _ => return None,
    };
    Some(response)
}

/// Runs one command inside the request's cancellation scope and encodes the
/// answer. Cancellation is checked before and after the work, as Core does, so a
/// cancelled or expired request never reports success.
fn respond<Request, Response>(
    parsed: CoreRequest,
    invalid_request: &str,
    run: impl FnOnce(Request) -> Result<Response, CoreError>,
) -> String
where
    Request: DeserializeOwned,
    Response: Serialize,
{
    let id = parsed.id.clone();
    let operation_id = parsed.operation_id.or_else(|| id.clone());
    let _scope = CancellationScope::begin(operation_id, parsed.timeout_milliseconds);
    let result = lithe_core::check_cancellation()
        .and_then(|()| execute(parsed.payload, invalid_request, run))
        .and_then(|data| lithe_core::check_cancellation().map(|()| data));
    let response = match result {
        Ok(data) => CoreResponse::success(id, data),
        Err(error) => CoreResponse::failure(id, error),
    };
    encode(&response)
}

fn execute<Request, Response>(
    payload: serde_json::Value,
    invalid_request: &str,
    run: impl FnOnce(Request) -> Result<Response, CoreError>,
) -> Result<serde_json::Value, CoreError>
where
    Request: DeserializeOwned,
    Response: Serialize,
{
    let request = serde_json::from_value::<Request>(payload).map_err(|error| {
        CoreError::new(ErrorCode::InvalidRequest, invalid_request).with_details(error.to_string())
    })?;
    let data = run(request)?;
    Ok(serde_json::to_value(data).expect("legacy Java response should encode"))
}

/// Serializes like Core's `execute_json`, including its fallback failure.
fn encode(response: &CoreResponse) -> String {
    serde_json::to_string(response).unwrap_or_else(|_| {
        serde_json::to_string(&CoreResponse::failure(
            None,
            CoreError::new(ErrorCode::Unknown, "Could not encode core response"),
        ))
        .expect("fallback response should encode")
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};

    fn run(request: Value) -> Option<Value> {
        try_execute(&request.to_string())
            .map(|response| serde_json::from_str(&response).expect("response should be JSON"))
    }

    #[test]
    fn other_commands_and_other_text_are_left_to_core() {
        assert!(run(json!({"id": "a", "command": "ping"})).is_none());
        assert!(run(json!({"id": "a", "command": "maven.unknown"})).is_none());
        assert!(try_execute("not json").is_none());
        assert!(try_execute(r#"{"id":"a"}"#).is_none());
    }

    #[test]
    fn an_invalid_payload_keeps_cores_error_shape() {
        let response = run(json!({
            "id": "scan-1",
            "command": "maven.scan",
            "payload": {"root": 7},
        }))
        .expect("maven.scan is a legacy command");

        assert_eq!(response["id"], "scan-1");
        assert_eq!(response["ok"], false);
        assert_eq!(response["error"]["code"], "invalid_request");
        assert_eq!(response["error"]["message"], "Invalid Maven scan request");
        assert!(response["error"]["details"].is_string());
        assert!(response.get("data").is_none());
    }

    #[test]
    fn a_successful_command_returns_its_data() {
        let response = run(json!({
            "id": "policy-1",
            "command": "java.workspacePolicy",
            "payload": {"workspacePaths": [], "changedPaths": []},
        }))
        .expect("java.workspacePolicy is a legacy command");

        assert_eq!(response["id"], "policy-1");
        assert_eq!(response["ok"], true, "{response}");
        assert!(response["data"].is_object());
    }

    /// Core turns a success into a failure when the request was cancelled while
    /// it ran, so a caller that gave up never receives stale data.
    #[test]
    fn a_cancellation_during_the_work_replaces_success_with_an_error() {
        let operation = "legacy-java-cancelled";
        let parsed: CoreRequest = serde_json::from_value(json!({
            "id": "cancelled",
            "operationId": operation,
            "command": "maven.scan",
        }))
        .expect("request envelope");

        let response = respond(parsed, "invalid", |_: Value| {
            assert!(lithe_core::cancel_operation(operation));
            Ok(json!({"done": true}))
        });

        let response: Value = serde_json::from_str(&response).expect("response should be JSON");
        assert_eq!(response["id"], "cancelled");
        assert_eq!(response["ok"], false);
        assert_eq!(response["error"]["code"], "cancelled");
    }

    #[test]
    fn requests_match_what_core_answers_for_the_shared_commands() {
        let request = json!({
            "id": "policy-2",
            "command": "java.workspacePolicy",
            "payload": {"workspacePaths": ["a/pom.xml"], "changedPaths": ["a/pom.xml"]},
        })
        .to_string();

        assert_eq!(
            try_execute(&request).expect("legacy command"),
            lithe_core::execute_json(&request)
        );
    }
}
