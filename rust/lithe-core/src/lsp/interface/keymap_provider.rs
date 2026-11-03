//! Negotiation for the independent shortcut import provider protocol.

use serde_json::{json, Value};
use std::collections::BTreeSet;

const EXPERIMENTAL_KEY: &str = "litheKeymapImport";
/// Client event carrying the provider subset selected during initialization.
pub(crate) const NEGOTIATED_EVENT: &str = "keymapImportProvidersNegotiated";
/// Host-to-provider request for one explicitly selected source snapshot.
pub(crate) const IMPORT_METHOD: &str = "lithe/keymap/import";
/// Maximum encoded provider reply forwarded to the host for Core validation.
pub(crate) const MAX_REPLY_BYTES: usize = 1024 * 1024;

fn valid_offer(providers: &BTreeSet<String>) -> bool {
    !providers.is_empty()
        && providers.len() <= crate::plugins::keymap_import::MAX_PROVIDERS
        && providers
            .iter()
            .all(|id| crate::plugins::keymap_import::valid_provider_id(id))
}

/// Offers this protocol only for a bounded set of declared provider identities.
pub(crate) fn client_experimental_capabilities(
    providers: &BTreeSet<String>,
) -> Option<(&'static str, Value)> {
    valid_offer(providers).then(|| {
        (
            EXPERIMENTAL_KEY,
            json!({"versions": [1], "providers": providers}),
        )
    })
}

/// Rejects the entire answer if it selects an unsupported or undeclared provider.
pub(crate) fn negotiate(capabilities: &Value, offered: &BTreeSet<String>) -> Option<Vec<String>> {
    if !valid_offer(offered) {
        return None;
    }
    let answer = capabilities.pointer("/experimental/litheKeymapImport")?;
    if answer.get("version")?.as_u64()? != 1 {
        return None;
    }
    let mut selected = BTreeSet::new();
    for provider in answer.get("providers")?.as_array()? {
        let provider = provider.as_str()?;
        if !offered.contains(provider) || !selected.insert(provider.to_owned()) {
            return None;
        }
    }
    (!selected.is_empty()).then(|| selected.into_iter().collect())
}

#[cfg(test)]
mod tests {
    use super::{client_experimental_capabilities, negotiate, IMPORT_METHOD};
    use serde_json::{json, Value};
    use std::collections::BTreeSet;

    #[test]
    fn shortcut_providers_negotiate_only_an_offered_subset() {
        let fixtures: Value = serde_json::from_str(include_str!(
            "../../../../../shared/fixtures/keymap/provider-negotiation-v1.json"
        ))
        .unwrap();
        for case in fixtures["cases"].as_array().unwrap() {
            let offered: BTreeSet<String> = case["offered"]
                .as_array()
                .unwrap()
                .iter()
                .map(|id| id.as_str().unwrap().to_owned())
                .collect();
            let answer = json!({"experimental": {"litheKeymapImport": case["answer"]}});
            let actual = negotiate(&answer, &offered);
            let expected: Option<Vec<String>> =
                serde_json::from_value(case["expected"].clone()).unwrap();
            assert_eq!(actual, expected, "{}", case["name"]);
        }
        assert!(client_experimental_capabilities(&BTreeSet::new()).is_none());
        let offered = BTreeSet::from(["second".to_string(), "first".to_string()]);
        assert_eq!(
            client_experimental_capabilities(&offered).unwrap().1,
            json!({"versions": [1], "providers": ["first", "second"]})
        );
    }

    #[test]
    fn malformed_or_oversized_offers_negotiate_nothing() {
        let bad_id = BTreeSet::from(["../private".to_string()]);
        let many: BTreeSet<_> = (0..9).map(|index| format!("provider-{index}")).collect();
        for offered in [bad_id, many] {
            assert!(client_experimental_capabilities(&offered).is_none());
            let answer = json!({"experimental": {"litheKeymapImport": {
                "version": 1, "providers": [offered.iter().next().unwrap()]
            }}});
            assert!(negotiate(&answer, &offered).is_none());
        }
    }

    #[test]
    fn backend_cannot_recursively_invoke_an_import() {
        assert_eq!(
            super::super::plugin_function::refused_backend_request(IMPORT_METHOD),
            Some(super::super::plugin_function::codes::RECURSIVE_CALL)
        );
    }
}
