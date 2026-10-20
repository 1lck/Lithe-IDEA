//! Plugin functions: plugin-private actions a backend registers and the host
//! invokes on behalf of the same plugin, next to the typed domain protocols.
//!
//! The protocol is negotiated in `initialize` under
//! `capabilities.experimental.litheFunctions`, independently of `litheBuild`,
//! so a backend can speak either one. Functions never replace a domain
//! operation: a build model, dependency tree, or task still travels over its
//! typed `lithe/build/*` method and Core's plan and decode commands. This
//! module holds the deterministic rules (identifiers, registration, invocation
//! planning, outcome and progress normalization, and the refusal of requests a
//! backend may not make); the session engine applies them to live traffic.
//! The rules live in the plugin contract
//! (`shared/contracts/plugins/v1/README.md`, "Plugin functions").

use crate::protocol::{CoreError, ErrorCode};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::BTreeSet;

/// Key under `capabilities.experimental` on both sides of the exchange.
const EXPERIMENTAL_KEY: &str = "litheFunctions";

/// Plugin-function protocol versions this client speaks, in preference order.
const SUPPORTED_VERSIONS: [u64; 1] = [1];

/// Feature name recorded in the session's server capabilities once a backend
/// answered a supported version with a valid function list.
pub(crate) const FUNCTIONS_FEATURE: &str = "litheFunctions";

/// Host-to-backend request that runs one registered function.
pub(crate) const INVOKE_METHOD: &str = "lithe/function/invoke";
/// Backend-to-host request adding functions after `initialize`.
pub(crate) const REGISTER_METHOD: &str = "lithe/function/register";
/// Backend-to-host request withdrawing functions; running calls are revoked.
pub(crate) const UNREGISTER_METHOD: &str = "lithe/function/unregister";
/// Backend-to-host notification reporting progress of one running call.
pub(crate) const PROGRESS_METHOD: &str = "lithe/function/progress";

/// Upper bound of functions one session may have registered at a time.
const MAX_FUNCTIONS: usize = 256;
const MAX_FUNCTION_ID_BYTES: usize = 128;
const MAX_PLUGIN_ID_BYTES: usize = 128;
const MAX_PLUGIN_ERROR_CODE_BYTES: usize = 64;
/// Bound of a backend-supplied failure or progress message, in UTF-8 bytes.
const MAX_MESSAGE_BYTES: usize = 1024;
/// Bound of one serialized function result. Larger documents belong in a
/// domain protocol with its own decoder, not in a plugin-private reply.
const MAX_RESULT_BYTES: usize = 1 << 20;
/// Upper bound of one invocation's deadline, matching build-provider requests.
pub(crate) const MAX_FUNCTION_TIMEOUT_MS: u64 = 60 * 60_000;

/// Stable codes of the plugin-function contract. Synchronous refusals carry
/// them in `CoreError::details`; asynchronous outcomes in the runtime error's
/// `code`; refused backend requests in the JSON-RPC error's `data.code`.
pub(crate) mod codes {
    /// The session cannot serve plugin functions: it belongs to no plugin, or
    /// its backend did not negotiate the protocol.
    pub const UNAVAILABLE: &str = "plugin.function.unavailable";
    /// The function is not registered on the session.
    pub const UNKNOWN: &str = "plugin.function.unknown";
    /// The reference names another plugin than the one owning the session.
    pub const WRONG_PLUGIN: &str = "plugin.function.wrongPlugin";
    /// The plugin or function ID of the reference is malformed.
    pub const INVALID_REFERENCE: &str = "plugin.function.invalidReference";
    /// Invocation params are not a JSON object.
    pub const INVALID_PARAMS: &str = "plugin.function.invalidParams";
    /// A register or unregister request was refused as a whole.
    pub const INVALID_REGISTRATION: &str = "plugin.function.invalidRegistration";
    /// The backend answered the invocation with an error.
    pub const FAILED: &str = "plugin.function.failed";
    /// The backend's answer has no result or exceeds the result bound.
    pub const INVALID_RESULT: &str = "plugin.function.invalidResult";
    /// The function was unregistered while the call was running.
    pub const REVOKED: &str = "plugin.function.revoked";
    /// The backend asked the host to dispatch a domain operation or function,
    /// which could route back to the backend itself.
    pub const RECURSIVE_CALL: &str = "plugin.function.recursiveCall";
    /// The backend asked for a host capability this host does not offer.
    pub const HOST_UNAVAILABLE: &str = "plugin.host.unavailable";
}

#[derive(Debug, Clone, PartialEq, Eq, Deserialize)]
#[serde(deny_unknown_fields)]
/// Address of one plugin function: the owning plugin plus its function ID.
/// The host routes by plugin identity first, so a reference can never reach
/// a session of another plugin.
pub struct FunctionReference {
    #[serde(rename = "pluginID")]
    pub plugin_id: String,
    #[serde(rename = "functionID")]
    pub function_id: String,
}

/// What a session knows when an invocation is planned.
pub(crate) struct FunctionSession<'a> {
    /// Plugin that started the session; `None` for host-owned servers.
    pub plugin_id: Option<&'a str>,
    /// Whether the backend negotiated a supported protocol version.
    pub negotiated: bool,
    /// Currently registered function IDs.
    pub functions: &'a BTreeSet<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
/// Terminal failure of one invocation, before it becomes a runtime error.
pub(crate) struct FunctionFailure {
    pub code: &'static str,
    pub message: String,
    /// Plugin-defined code from `error.data.code`, for the plugin's own UI.
    /// Lithe never interprets it.
    pub plugin_error_code: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
/// One accepted progress report.
pub(crate) struct FunctionProgress {
    pub operation_id: String,
    pub message: Option<String>,
    /// Whole percent in `0..=100`.
    pub percentage: Option<u64>,
}

/// The client half of the negotiation, placed under `capabilities.experimental`.
pub(crate) fn client_experimental_capabilities() -> (&'static str, Value) {
    (EXPERIMENTAL_KEY, json!({ "versions": SUPPORTED_VERSIONS }))
}

/// Functions of a backend that answered a version this client offered, or
/// `None` when the protocol was not negotiated. A malformed function list
/// rejects the whole answer, so a session never starts with half a registry.
pub(crate) fn negotiate(capabilities: &Value) -> Option<BTreeSet<String>> {
    let answer = capabilities
        .get("experimental")
        .and_then(|experimental| experimental.get(EXPERIMENTAL_KEY))?;
    let version = answer.get("version").and_then(Value::as_u64)?;
    if !SUPPORTED_VERSIONS.contains(&version) {
        return None;
    }
    match answer.get("functions") {
        None => Some(BTreeSet::new()),
        Some(descriptors) => descriptor_ids(descriptors, &BTreeSet::new()).ok(),
    }
}

/// The registry after a `lithe/function/register` request. The request is
/// all or nothing: one malformed, duplicate, or already registered function,
/// or exceeding the session limit, refuses every function in it.
pub(crate) fn apply_registration(
    current: &BTreeSet<String>,
    params: Option<&Value>,
) -> Result<BTreeSet<String>, &'static str> {
    let descriptors = params
        .and_then(|params| params.get("functions"))
        .filter(|functions| functions.as_array().is_some_and(|items| !items.is_empty()))
        .ok_or("`functions` must be a nonempty array.")?;
    let added = descriptor_ids(descriptors, current)?;
    let mut registry = current.clone();
    registry.extend(added);
    Ok(registry)
}

/// The registry and the withdrawn IDs after a `lithe/function/unregister`
/// request, all or nothing like registration.
pub(crate) fn apply_unregistration(
    current: &BTreeSet<String>,
    params: Option<&Value>,
) -> Result<(BTreeSet<String>, Vec<String>), &'static str> {
    let ids = params
        .and_then(|params| params.get("ids"))
        .and_then(Value::as_array)
        .filter(|ids| !ids.is_empty())
        .ok_or("`ids` must be a nonempty array.")?;
    let mut removed = BTreeSet::new();
    for id in ids {
        let id = id.as_str().ok_or("Every ID must be a string.")?;
        if !current.contains(id) {
            return Err("Only registered functions can be unregistered.");
        }
        if !removed.insert(id.to_string()) {
            return Err("An ID is listed twice.");
        }
    }
    let registry = current.difference(&removed).cloned().collect();
    Ok((registry, removed.into_iter().collect()))
}

/// Params of the `lithe/function/invoke` request for `reference`, or the
/// refusal with its stable code in `details`. Checks run in a fixed order so
/// every host reports the same code for the same request.
pub(crate) fn plan_invocation(
    session: &FunctionSession<'_>,
    reference: &FunctionReference,
    operation_id: &str,
    params: &Value,
) -> Result<Value, CoreError> {
    if !is_plugin_id(&reference.plugin_id) || !is_function_id(&reference.function_id) {
        return Err(refusal(
            ErrorCode::InvalidRequest,
            "The function reference is malformed.",
            codes::INVALID_REFERENCE,
        ));
    }
    if !params.is_object() {
        return Err(refusal(
            ErrorCode::InvalidRequest,
            "Function params must be a JSON object.",
            codes::INVALID_PARAMS,
        ));
    }
    let Some(owner) = session.plugin_id else {
        return Err(refusal(
            ErrorCode::NotSupported,
            "This session does not belong to a plugin.",
            codes::UNAVAILABLE,
        ));
    };
    if owner != reference.plugin_id {
        return Err(refusal(
            ErrorCode::PermissionDenied,
            "The function belongs to another plugin.",
            codes::WRONG_PLUGIN,
        ));
    }
    if !session.negotiated {
        return Err(refusal(
            ErrorCode::NotSupported,
            "The plugin process did not agree on a plugin-function protocol version.",
            codes::UNAVAILABLE,
        ));
    }
    if !session.functions.contains(&reference.function_id) {
        return Err(refusal(
            ErrorCode::NotSupported,
            "The plugin has not registered this function.",
            codes::UNKNOWN,
        ));
    }
    Ok(json!({
        "functionID": reference.function_id,
        "operationID": operation_id,
        "params": params
    }))
}

/// Normalizes the backend's JSON-RPC response to an invocation. A success is
/// wrapped as `{ "value": result }` like build-provider replies, so `null` is
/// a valid result distinct from a missing one.
pub(crate) fn invocation_outcome(response: &Value) -> Result<Value, FunctionFailure> {
    if let Some(error) = response.get("error") {
        let message = error
            .get("message")
            .and_then(Value::as_str)
            .map(bounded_message)
            .filter(|message| !message.is_empty())
            .unwrap_or_else(|| "The plugin function failed.".to_string());
        let plugin_error_code = error
            .get("data")
            .and_then(|data| data.get("code"))
            .and_then(Value::as_str)
            .filter(|code| is_plugin_error_code(code))
            .map(ToString::to_string);
        return Err(FunctionFailure {
            code: codes::FAILED,
            message,
            plugin_error_code,
        });
    }
    let Some(result) = response.get("result") else {
        return Err(invalid_result("The plugin function returned no result."));
    };
    // Serialized length is what crosses the C ABI and the host bridge.
    if result.to_string().len() > MAX_RESULT_BYTES {
        return Err(invalid_result(
            "The plugin function returned more data than a function result may hold.",
        ));
    }
    Ok(json!({ "value": result }))
}

/// A progress report that is well formed, or `None` to ignore it. Whether the
/// operation is still running is the engine's check, not this function's.
pub(crate) fn parse_progress(params: Option<&Value>) -> Option<FunctionProgress> {
    let params = params?.as_object()?;
    let operation_id = params.get("operationID")?.as_str()?.to_string();
    let message = match params.get("message") {
        None => None,
        Some(message) => Some(bounded_message(message.as_str()?)),
    };
    let percentage = match params.get("percentage") {
        None => None,
        Some(percentage) => Some(percentage.as_u64().filter(|value| *value <= 100)?),
    };
    Some(FunctionProgress {
        operation_id,
        message,
        percentage,
    })
}

/// The stable code for a backend request the host refuses on principle, or
/// `None` for any other method. Domain dispatch can route back into the
/// requesting backend, whose handler would then wait on itself; host
/// capabilities are offered per protocol version, and version 1 offers none.
pub(crate) fn refused_backend_request(method: &str) -> Option<&'static str> {
    if method == INVOKE_METHOD || method.starts_with("lithe/build/") {
        Some(codes::RECURSIVE_CALL)
    } else if method.starts_with("lithe/host/") {
        Some(codes::HOST_UNAVAILABLE)
    } else {
        None
    }
}

/// IDs of a descriptor array, refusing malformed descriptors, duplicates,
/// IDs already in `existing`, and a registry beyond the session limit.
fn descriptor_ids(
    descriptors: &Value,
    existing: &BTreeSet<String>,
) -> Result<BTreeSet<String>, &'static str> {
    let descriptors = descriptors
        .as_array()
        .ok_or("`functions` must be an array.")?;
    let mut ids = BTreeSet::new();
    for descriptor in descriptors {
        // Unknown descriptor fields are ignored within a version, as for
        // every negotiated object, so a backend can add optional metadata.
        let id = descriptor
            .get("id")
            .and_then(Value::as_str)
            .filter(|id| is_function_id(id))
            .ok_or("Every function needs a valid `id`.")?;
        if existing.contains(id) || !ids.insert(id.to_string()) {
            return Err("A function ID is registered twice.");
        }
    }
    if existing.len() + ids.len() > MAX_FUNCTIONS {
        return Err("Too many functions are registered.");
    }
    Ok(ids)
}

/// Dot-separated lowerCamelCase segments, for example `snapshot.refresh`.
fn is_function_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= MAX_FUNCTION_ID_BYTES
        && value.split('.').all(|segment| {
            let mut characters = segment.chars();
            characters
                .next()
                .is_some_and(|first| first.is_ascii_lowercase())
                && characters.all(|character| character.is_ascii_alphanumeric())
        })
}

/// The manifest's plugin ID alphabet: lowercase letters, digits, `.` and `-`.
fn is_plugin_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= MAX_PLUGIN_ID_BYTES
        && value.chars().all(|character| {
            character.is_ascii_lowercase()
                || character.is_ascii_digit()
                || character == '.'
                || character == '-'
        })
}

fn is_plugin_error_code(value: &str) -> bool {
    let mut characters = value.chars();
    value.len() <= MAX_PLUGIN_ERROR_CODE_BYTES
        && characters
            .next()
            .is_some_and(|first| first.is_ascii_alphabetic())
        && characters.all(|character| {
            character.is_ascii_alphanumeric() || matches!(character, '.' | '_' | '-')
        })
}

/// Truncates at a character boundary so a hostile message cannot inflate
/// every event that carries it.
fn bounded_message(value: &str) -> String {
    if value.len() <= MAX_MESSAGE_BYTES {
        return value.to_string();
    }
    let mut end = MAX_MESSAGE_BYTES;
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    value[..end].to_string()
}

fn invalid_result(message: &str) -> FunctionFailure {
    FunctionFailure {
        code: codes::INVALID_RESULT,
        message: message.to_string(),
        plugin_error_code: None,
    }
}

fn refusal(category: ErrorCode, message: &str, code: &str) -> CoreError {
    CoreError::new(category, message).with_details(code)
}

#[cfg(test)]
mod tests {
    //! Golden cases from `shared/contracts/plugins/v1/fixtures/function-protocol.json`.
    //! Timing behavior (cancellation, deadlines, late replies, revocation of a
    //! running call) is covered against a scripted backend in the engine tests.

    use super::*;

    const FIXTURE: &str = include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../shared/contracts/plugins/v1/fixtures/function-protocol.json"
    ));

    fn fixture() -> Value {
        serde_json::from_str(FIXTURE).expect("the function-protocol fixture is JSON")
    }

    fn cases(section: &str) -> Vec<Value> {
        fixture()[section]
            .as_array()
            .unwrap_or_else(|| panic!("fixture section {section} is missing"))
            .clone()
    }

    fn id_set(value: &Value) -> BTreeSet<String> {
        value
            .as_array()
            .expect("an ID list")
            .iter()
            .map(|id| id.as_str().expect("a string ID").to_string())
            .collect()
    }

    fn name(case: &Value) -> &str {
        case["name"].as_str().expect("every case is named")
    }

    #[test]
    fn the_offer_matches_the_fixture() {
        let fixture = fixture();
        let (key, offer) = client_experimental_capabilities();
        assert_eq!(fixture["protocol"], key);
        assert_eq!(fixture["offer"], offer);
    }

    #[test]
    fn negotiation_follows_the_fixture() {
        for case in cases("negotiation") {
            let negotiated = negotiate(&case["capabilities"]);
            let expected = &case["expected"];
            match expected["functions"].as_array() {
                Some(_) => assert_eq!(
                    negotiated,
                    Some(id_set(&expected["functions"])),
                    "{}",
                    name(&case)
                ),
                None => assert_eq!(negotiated, None, "{}", name(&case)),
            }
        }
    }

    #[test]
    fn registration_follows_the_fixture() {
        for case in cases("registration") {
            let current = id_set(&case["registered"]);
            let params = case.get("params");
            let expected = &case["expected"];
            let outcome = match case["method"].as_str() {
                Some(REGISTER_METHOD) => {
                    apply_registration(&current, params).map(|registry| (registry, Vec::new()))
                }
                Some(UNREGISTER_METHOD) => apply_unregistration(&current, params),
                other => panic!("{}: unknown method {other:?}", name(&case)),
            };
            if expected["status"] == "accepted" {
                let (registry, removed) =
                    outcome.unwrap_or_else(|reason| panic!("{}: {reason}", name(&case)));
                assert_eq!(registry, id_set(&expected["functions"]), "{}", name(&case));
                let expected_removed: Vec<String> =
                    id_set(&expected["removed"]).into_iter().collect();
                assert_eq!(removed, expected_removed, "{}", name(&case));
            } else {
                assert_eq!(expected["code"], codes::INVALID_REGISTRATION);
                assert!(outcome.is_err(), "{} should be refused", name(&case));
            }
        }
    }

    #[test]
    fn invocation_planning_follows_the_fixture() {
        for case in cases("invocations") {
            let session = &case["session"];
            let functions = id_set(&session["functions"]);
            let reference: FunctionReference =
                serde_json::from_value(case["request"]["function"].clone())
                    .unwrap_or_else(|error| panic!("{}: {error}", name(&case)));
            let planned = plan_invocation(
                &FunctionSession {
                    plugin_id: session["pluginID"].as_str(),
                    negotiated: session["negotiated"].as_bool().unwrap_or(false),
                    functions: &functions,
                },
                &reference,
                "operation-1",
                &case["request"]["params"],
            );
            let expected = &case["expected"];
            if expected["status"] == "sent" {
                let params = planned.unwrap_or_else(|error| panic!("{}: {error:?}", name(&case)));
                assert_eq!(expected["method"], INVOKE_METHOD, "{}", name(&case));
                assert_eq!(params, expected["params"], "{}", name(&case));
            } else {
                let error = planned.expect_err(name(&case));
                assert_eq!(
                    error.details.as_deref(),
                    expected["code"].as_str(),
                    "{}",
                    name(&case)
                );
            }
        }
    }

    #[test]
    fn outcomes_follow_the_fixture() {
        for case in cases("outcomes") {
            let expected = &case["expected"];
            match invocation_outcome(&case["response"]) {
                Ok(result) => assert_eq!(result, expected["result"], "{}", name(&case)),
                Err(failure) => {
                    let error = &expected["error"];
                    assert_eq!(failure.code, error["code"], "{}", name(&case));
                    assert_eq!(failure.message, error["message"], "{}", name(&case));
                    assert_eq!(
                        failure.plugin_error_code.as_deref(),
                        error["pluginErrorCode"].as_str(),
                        "{}",
                        name(&case)
                    );
                }
            }
        }
    }

    #[test]
    fn progress_follows_the_fixture() {
        for case in cases("progress") {
            let parsed = parse_progress(case.get("params"));
            let expected = &case["expected"];
            if expected.is_null() {
                assert_eq!(parsed, None, "{}", name(&case));
            } else {
                assert_eq!(
                    parsed,
                    Some(FunctionProgress {
                        operation_id: expected["operationID"].as_str().unwrap().to_string(),
                        message: expected["message"].as_str().map(ToString::to_string),
                        percentage: expected["percentage"].as_u64(),
                    }),
                    "{}",
                    name(&case)
                );
            }
        }
    }

    #[test]
    fn backend_requests_follow_the_fixture() {
        for case in cases("backendRequests") {
            assert_eq!(
                refused_backend_request(case["method"].as_str().unwrap()),
                case["expected"]["code"].as_str(),
                "{}",
                name(&case)
            );
        }
    }

    /// A message over the bound is cut at a character boundary, never inside
    /// a multi-byte character.
    #[test]
    fn long_failure_messages_are_truncated_on_character_boundaries() {
        let message = format!("{}é", "a".repeat(MAX_MESSAGE_BYTES - 1));
        let failure = invocation_outcome(&json!({ "error": { "code": 1, "message": message } }))
            .expect_err("an error response fails");
        assert_eq!(failure.message, "a".repeat(MAX_MESSAGE_BYTES - 1));
    }

    #[test]
    fn oversized_results_are_invalid() {
        let result = "x".repeat(MAX_RESULT_BYTES);
        let failure = invocation_outcome(&json!({ "result": result }))
            .expect_err("a result over the bound is refused");
        assert_eq!(failure.code, codes::INVALID_RESULT);
    }

    #[test]
    fn the_registry_is_bounded() {
        let current: BTreeSet<String> = (0..MAX_FUNCTIONS)
            .map(|index| format!("f{index}"))
            .collect();
        let error =
            apply_registration(&current, Some(&json!({ "functions": [{ "id": "extra" }] })))
                .expect_err("the session limit holds");
        assert!(error.contains("Too many"));
    }
}
