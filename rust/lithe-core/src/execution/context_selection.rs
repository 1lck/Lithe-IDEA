//! Chooses an existing configuration for a provider-supplied entry identity.

use serde::Deserialize;

/// One already-resolved configuration; Core performs no provider-specific discovery.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ContextCandidate {
    /// Stable configuration identity returned to the caller.
    id: String,
    /// Provider-supplied source identity, when this configuration has one.
    source_path: Option<String>,
    /// Provider-supplied entry symbol, when this configuration has one.
    symbol: Option<String>,
    /// Whether the configuration comes from generated detection.
    generated: bool,
    /// Disabled entries must never be selected for a launch.
    disabled: bool,
}

/// Identity and ordered candidates for a context launch or editor action.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ContextSelectionRequest {
    /// Source identity supplied by the platform's provider.
    source_path: String,
    /// Entry symbol supplied by the platform's provider.
    symbol: String,
    /// Current selection, if any; it wins over an otherwise equal match.
    preferred_id: Option<String>,
    /// Windows path identities compare case-insensitively with either separator.
    case_insensitive_paths: bool,
    /// Effective configurations in their existing display order.
    candidates: Vec<ContextCandidate>,
}

/// Returns the matching preferred or edited entry, preserving input order on ties.
pub(crate) fn select_context_configuration(request: ContextSelectionRequest) -> Option<String> {
    let path_key = |path: &str| {
        if request.case_insensitive_paths {
            path.replace('\\', "/").to_lowercase()
        } else {
            path.to_owned()
        }
    };
    let source_key = path_key(&request.source_path);
    request
        .candidates
        .iter()
        .filter(|candidate| {
            !candidate.disabled
                && candidate.symbol.as_deref() == Some(request.symbol.as_str())
                && candidate.source_path.as_deref().map(&path_key).as_deref()
                    == Some(source_key.as_str())
        })
        .min_by_key(|candidate| {
            let preferred = request.preferred_id.as_deref() == Some(candidate.id.as_str());
            (!preferred as u8 * 2) + candidate.generated as u8
        })
        .map(|candidate| candidate.id.clone())
}

#[cfg(test)]
mod tests {
    use serde_json::Value;

    #[test]
    fn context_selection_command_matches_shared_provider_neutral_cases() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../../shared/fixtures/run-configuration/context-selection.json"
        ))
        .unwrap();
        for case in fixture["cases"].as_array().unwrap() {
            let request = serde_json::json!({
                "id": "context-selection", "command": "runConfig.selectContextConfiguration",
                "payload": case["request"]
            });
            let response: Value =
                serde_json::from_str(&crate::execute_json(&request.to_string())).unwrap();
            assert_eq!(response["ok"], true, "{}: {response}", case["name"]);
            assert_eq!(
                response["data"]["configurationId"], case["expected"],
                "{}",
                case["name"]
            );
        }
    }
}
