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
const SUPPORTED_VERSIONS: [u64; 1] = [1];

/// Feature name recorded in the session's server capabilities once a
/// provider answered a supported version.
pub(crate) const BUILD_PROVIDER_FEATURE: &str = "litheBuild";

/// Requests of protocol version 1. Core plans both and decodes their results,
/// so the host can only forward what `build.modelPlan` and
/// `build.dependencyPlan` returned.
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
            &json!({ "experimental": { "litheBuild": { "version": 2 } } })
        ));
        assert!(!negotiated(
            &json!({ "experimental": { "litheBuild": { "version": "1" } } })
        ));
        assert!(!negotiated(
            &json!({ "experimental": { "litheBuild": { "versions": [1] } } })
        ));
    }

    #[test]
    fn version_one_accepts_only_its_two_requests() {
        assert!(is_build_method("lithe/build/model"));
        assert!(is_build_method("lithe/build/dependencies"));
        assert!(!is_build_method("lithe/build/execute"));
        assert!(!is_build_method("workspace/executeCommand"));
    }
}
