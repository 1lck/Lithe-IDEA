//! The VCS-provider protocol a plugin's LSP base-protocol process speaks.
//!
//! The manifest says how to start the process and which VCS it provides;
//! the protocol version, the VCS ID, and the provider's capabilities are
//! negotiated in `initialize` under `capabilities.experimental.litheVcs`.
//! Only plugin-owned sessions are offered the protocol, and requests are
//! written only to a session whose answer named a version this client
//! offered, a valid VCS ID, and every required capability. The rules live in
//! `shared/contracts/vcs-provider-v1.md`.

use crate::vcs::{negotiated_capabilities, Capabilities};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};

/// Key under `capabilities.experimental` on both sides of the exchange.
const EXPERIMENTAL_KEY: &str = "litheVcs";

/// VCS-provider protocol versions this client speaks, in preference order.
const SUPPORTED_VERSIONS: [u64; 1] = [1];

/// Feature name recorded in the session's server capabilities once a
/// provider answered a supported version.
pub(crate) const VCS_PROVIDER_FEATURE: &str = "litheVcs";

/// Client event that carries the negotiated provider to the engine.
pub(crate) const NEGOTIATED_EVENT: &str = "vcsProviderNegotiated";

/// Longest provider error message passed to the host, in UTF-8 bytes.
const MAX_MESSAGE_BYTES: usize = 4096;

/// Contract codes a provider may put in `error.data.code`. Any other code,
/// or none, becomes [`codes::FAILED`].
const PROVIDER_ERROR_CODES: &[&str] = &[
    "vcs.authentication.failed",
    "vcs.conflict",
    "vcs.outOfDate",
    "vcs.tool.unavailable",
    "vcs.workingCopy.locked",
    "vcs.workingCopy.unsupported",
];

/// Error codes Core assigns to a failed VCS request.
pub(crate) mod codes {
    /// The provider failed without one of the contract's specific codes.
    pub const FAILED: &str = "vcs.provider.failed";
    /// The reply is not a JSON-RPC result.
    pub const INVALID_OUTPUT: &str = "plugin.vcs.invalidOutput";
}

/// What a provider answered in `initialize`.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct VcsNegotiation {
    /// The VCS the process provides; the host checks it against the
    /// manifest entry it launched.
    pub vcs: String,
    /// Capabilities of protocol version 1 the provider supports.
    pub capabilities: Capabilities,
}

/// The client half of the negotiation, placed under `capabilities.experimental`.
pub(crate) fn client_experimental_capabilities() -> (&'static str, Value) {
    (EXPERIMENTAL_KEY, json!({ "versions": SUPPORTED_VERSIONS }))
}

/// The provider's answer, or `None` when it chose no offered version, named
/// no valid VCS ID, or lacks a required capability. Unknown fields and
/// capabilities are ignored, as the contract requires.
pub(crate) fn negotiate(capabilities: &Value) -> Option<VcsNegotiation> {
    let answer = capabilities
        .get("experimental")
        .and_then(|experimental| experimental.get(EXPERIMENTAL_KEY))?;
    let version = answer.get("version").and_then(Value::as_u64)?;
    if !SUPPORTED_VERSIONS.contains(&version) {
        return None;
    }
    let vcs = answer
        .get("vcs")
        .and_then(Value::as_str)
        .filter(|vcs| crate::vcs::is_vcs_id(vcs))?;
    Some(VcsNegotiation {
        vcs: vcs.to_string(),
        capabilities: negotiated_capabilities(answer.get("capabilities")?)?,
    })
}

/// A failed VCS request: a contract code and the provider's message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct VcsFailure {
    pub(crate) code: &'static str,
    pub(crate) message: String,
}

fn bounded_message(value: &str) -> String {
    let mut end = value.len().min(MAX_MESSAGE_BYTES);
    while !value.is_char_boundary(end) {
        end -= 1;
    }
    value[..end].to_string()
}

/// Normalizes the provider's JSON-RPC response. A success is wrapped as
/// `{ "value": result }` like build-provider replies, so the host passes
/// `value` to `vcs.decodeReply` unchanged.
pub(crate) fn reply_outcome(response: &Value) -> Result<Value, VcsFailure> {
    if let Some(error) = response.get("error") {
        let message = error
            .get("message")
            .and_then(Value::as_str)
            .map(bounded_message)
            .filter(|message| !message.trim().is_empty())
            .unwrap_or_else(|| "The VCS provider failed.".to_string());
        let code = error
            .get("data")
            .and_then(|data| data.get("code"))
            .and_then(Value::as_str)
            .and_then(|code| PROVIDER_ERROR_CODES.iter().find(|known| **known == code))
            .copied()
            .unwrap_or(codes::FAILED);
        return Err(VcsFailure { code, message });
    }
    match response.get("result") {
        Some(result) => Ok(json!({ "value": result })),
        None => Err(VcsFailure {
            code: codes::INVALID_OUTPUT,
            message: "The VCS provider returned no result.".to_string(),
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn answer(value: Value) -> Value {
        json!({ "experimental": { "litheVcs": value } })
    }

    const REQUIRED: &str = r#"{ "status": 1, "baseContent": 1, "checkin": 1, "rollback": 1 }"#;

    #[test]
    fn only_a_complete_answer_to_an_offered_version_counts() {
        let capabilities: Value = serde_json::from_str(REQUIRED).expect("JSON");
        let negotiation = negotiate(&answer(json!({
            "version": 1, "vcs": "svn", "capabilities": capabilities, "future": true
        })))
        .expect("negotiated");
        assert_eq!(negotiation.vcs, "svn");
        assert_eq!(negotiation.capabilities.len(), 4);
        // A version the host never offered, a malformed VCS ID, a missing
        // capability map, or a missing required capability must keep VCS
        // requests off the session.
        for rejected in [
            json!({ "version": 2, "vcs": "svn", "capabilities": capabilities }),
            json!({ "version": 1, "vcs": "SVN", "capabilities": capabilities }),
            json!({ "version": 1, "vcs": "svn" }),
            json!({ "version": 1, "vcs": "svn", "capabilities": { "status": 1 } }),
        ] {
            assert_eq!(negotiate(&answer(rejected.clone())), None, "{rejected}");
        }
        assert_eq!(negotiate(&json!({})), None);
    }

    #[test]
    fn provider_errors_keep_only_contract_codes() {
        let failure = reply_outcome(&json!({
            "error": { "code": -32000, "message": "Out of date", "data": { "code": "vcs.outOfDate" } }
        }))
        .expect_err("failed");
        assert_eq!(failure.code, "vcs.outOfDate");
        // A plugin cannot make its own code look like one of Lithe's.
        let failure = reply_outcome(&json!({
            "error": { "code": -32000, "message": "", "data": { "code": "plugin.vcs.invalidOutput" } }
        }))
        .expect_err("failed");
        assert_eq!(failure.code, codes::FAILED);
        assert_eq!(failure.message, "The VCS provider failed.");
        assert_eq!(
            reply_outcome(&json!({ "result": null })).expect("ok"),
            json!({ "value": null })
        );
    }
}
