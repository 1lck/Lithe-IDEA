//! The toolchain-provider protocol a plugin backend speaks next to its functions.
//!
//! The manifest lists the providers; `initialize` offers them under
//! `capabilities.experimental.litheToolchains`, and the backend selects a version
//! and a subset of the offer. `toolchains/query` is written only to a session whose
//! answer passed [`negotiate`]. Replies stay untrusted here: Core transports them
//! unchanged, and `toolchains.decodeReply` validates them against native facts.
//! The rules live in `shared/contracts/plugins/v1/toolchains/README.md`.

use serde_json::{json, Value};
use std::collections::BTreeSet;

/// Key under `capabilities.experimental` on both sides of the exchange.
const EXPERIMENTAL_KEY: &str = "litheToolchains";

/// Toolchain-provider protocol versions this client speaks.
const SUPPORTED_VERSIONS: [u64; 1] = [1];

/// The only method this protocol writes.
pub(crate) const QUERY_METHOD: &str = "toolchains/query";

/// Client event that carries the negotiated providers to the engine.
pub(crate) const NEGOTIATED_EVENT: &str = "toolchainProvidersNegotiated";

/// The offer for a session launched with `providers`; `None` when it declares none.
pub(crate) fn client_experimental_capabilities(
    providers: &BTreeSet<String>,
) -> Option<(&'static str, Value)> {
    (!providers.is_empty()).then(|| {
        (
            EXPERIMENTAL_KEY,
            json!({ "versions": SUPPORTED_VERSIONS, "providers": providers }),
        )
    })
}

/// The providers a backend selected, or `None` unless it chose an offered version
/// and a non-empty, duplicate-free subset of `offered`. A partly valid answer
/// enables nothing, so no query reaches a provider the manifest did not declare.
pub(crate) fn negotiate(capabilities: &Value, offered: &BTreeSet<String>) -> Option<Vec<String>> {
    let answer = capabilities.pointer(&format!("/experimental/{EXPERIMENTAL_KEY}"))?;
    let version = answer.get("version").and_then(Value::as_u64)?;
    if !SUPPORTED_VERSIONS.contains(&version) {
        return None;
    }
    let mut selected = BTreeSet::new();
    for provider in answer.get("providers")?.as_array()? {
        let provider = provider.as_str()?;
        if !offered.contains(provider) || !selected.insert(provider.to_string()) {
            return None;
        }
    }
    (!selected.is_empty()).then(|| selected.into_iter().collect())
}

/// Wraps the complete JSON-RPC response for `toolchains.decodeReply`, which owns
/// every success and error rule, with the wire ID the request was written under.
pub(crate) fn reply_outcome(response: &Value) -> Value {
    json!({ "value": { "id": response.get("id"), "response": response } })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn offered() -> BTreeSet<String> {
        BTreeSet::from(["mise".to_string(), "asdf".to_string()])
    }

    fn answer(value: Value) -> Value {
        json!({ "experimental": { "litheToolchains": value } })
    }

    #[test]
    fn only_a_session_with_declared_providers_is_offered_the_protocol() {
        assert_eq!(client_experimental_capabilities(&BTreeSet::new()), None);
        let (key, offer) = client_experimental_capabilities(&offered()).expect("offered");
        assert_eq!(key, "litheToolchains");
        assert_eq!(
            offer,
            json!({ "versions": [1], "providers": ["asdf", "mise"] })
        );
    }

    #[test]
    fn negotiation_accepts_only_a_complete_subset_of_the_offer() {
        assert_eq!(
            negotiate(
                &answer(json!({ "version": 1, "providers": ["mise"], "future": true })),
                &offered()
            ),
            Some(vec!["mise".to_string()])
        );
        for rejected in [
            json!({ "version": 2, "providers": ["mise"] }),
            json!({ "version": 1 }),
            json!({ "version": 1, "providers": [] }),
            json!({ "version": 1, "providers": "mise" }),
            json!({ "version": 1, "providers": ["mise", "mise"] }),
            json!({ "version": 1, "providers": ["mise", "undeclared"] }),
            json!({ "version": 1, "providers": ["mise", 7] }),
        ] {
            assert_eq!(
                negotiate(&answer(rejected.clone()), &offered()),
                None,
                "{rejected}"
            );
        }
        assert_eq!(negotiate(&json!({}), &offered()), None);
    }

    #[test]
    fn replies_keep_the_whole_response_and_its_wire_id() {
        let response = json!({ "jsonrpc": "2.0", "id": 7, "error": { "code": -32073 } });
        assert_eq!(
            reply_outcome(&response),
            json!({ "value": { "id": 7, "response": response } })
        );
    }
}
