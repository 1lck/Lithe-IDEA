//! Tests for the shared network proxy policy normalization.

use serde_json::{json, Value};

use crate::network::{proxy_policy, NetworkProxyPolicyRequest};

fn policy_for(request: Value) -> Value {
    let request: NetworkProxyPolicyRequest =
        serde_json::from_value(request).expect("policy request is valid");
    serde_json::to_value(proxy_policy(request)).expect("policy response encodes")
}

/// The fixture is the cross-platform contract: macOS consumes the policy
/// today and Windows is expected to adopt the same cases in a follow-up.
#[test]
fn fixture_cases_match_the_shared_contract() {
    let fixture: Value = serde_json::from_str(include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../shared/fixtures/network/proxy-policy-v1.json"
    )))
    .expect("proxy policy fixture is JSON");
    for case in fixture["cases"].as_array().expect("fixture cases") {
        let actual = policy_for(case["request"].clone());
        assert_eq!(actual, case["expected"], "case: {}", case["name"]);
    }
}

/// Stored credentials belong to the custom proxy only. After a mode switch
/// back to the system policy the plan must not carry them, so no network
/// stack can forward them to a different proxy during authentication.
#[test]
fn system_mode_never_carries_stale_custom_credentials() {
    let policy = policy_for(json!({
        "mode": "system",
        "proxyType": "http",
        "host": "proxy.example",
        "port": 3128,
        "username": "lithe",
        "password": "secret",
        "exclusions": ["127.0.0.1"]
    }));
    assert_eq!(policy["policy"], json!("system"));
    assert_eq!(policy["username"], json!(""));
    assert_eq!(policy["password"], json!(""));
    assert_eq!(policy["exclusions"], json!([]));
}

#[test]
fn passwords_keep_every_character_while_identifiers_are_trimmed() {
    let policy = policy_for(json!({
        "mode": "custom",
        "host": " proxy.example ",
        "port": 3128,
        "username": " lithe ",
        "password": " s p "
    }));
    assert_eq!(policy["host"], json!("proxy.example"));
    assert_eq!(policy["username"], json!("lithe"));
    assert_eq!(policy["password"], json!(" s p "));
}
