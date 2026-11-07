//! Resolves launch environment precedence after platform-owned tool discovery.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

/// Inherited environment and explicit overrides for one launch step.
///
/// Toolchain-specific variables (a runtime home, a build tool's own home) are
/// owned by the plugin that defines the toolchain; it supplies them as literal
/// overrides, so Core never names a tool here.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LaunchEnvironmentRequest {
    /// Native parent process environment; explicit overrides replace it.
    #[serde(default)]
    pub inherited: BTreeMap<String, String>,
    /// Plan bindings followed by explicit user overrides, already merged by key.
    /// Only string values are applied: a structured binding the host could not
    /// resolve to text has no defined value and must not reach the process.
    #[serde(default)]
    pub overrides: BTreeMap<String, Value>,
    /// Windows environment keys are case-insensitive even in a Rust map.
    #[serde(default)]
    pub case_insensitive: bool,
}

/// Final values passed directly to the native process adapter.
#[derive(Debug, Serialize)]
pub struct LaunchEnvironmentResponse {
    /// Deterministically ordered final environment.
    pub environment: BTreeMap<String, String>,
}

/// Applies inherited < explicit launch overrides.
pub fn resolve_launch_environment(request: LaunchEnvironmentRequest) -> LaunchEnvironmentResponse {
    let mut environment = BTreeMap::new();
    let mut insert = |key: String, value: String| {
        let key = if request.case_insensitive {
            key.to_ascii_uppercase()
        } else {
            key
        };
        environment.insert(key, value);
    };
    for (key, value) in request.inherited {
        insert(key, value);
    }
    for (key, value) in request.overrides {
        if let Some(text) = value.as_str() {
            insert(key, text.to_owned());
        }
    }
    LaunchEnvironmentResponse { environment }
}

/// A platform-discovered directory, ordered by role and stable provider identity.
#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct SearchPathCandidate {
    /// Lower priority values precede higher values.
    pub priority: u32,
    /// Stable opaque identity used to order candidates of equal priority.
    pub id: String,
    /// Platform-supplied directory spelling; no filesystem access occurs in Core.
    pub path: String,
}

/// Already split inherited search path and discovered directories for one process.
#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SearchPathRequest {
    /// Existing or explicitly overridden directories, in precedence order.
    pub existing: Vec<String>,
    /// Platform-discovered directories to append after the existing entries.
    pub candidates: Vec<SearchPathCandidate>,
    /// Treat ASCII case differences as identical on case-insensitive platforms.
    pub case_insensitive: bool,
}

/// Preserves the existing search path, then appends deterministically ordered candidates.
pub fn resolve_search_path(mut request: SearchPathRequest) -> Vec<String> {
    request.candidates.sort_by(|left, right| {
        (&left.priority, &left.id, &left.path).cmp(&(&right.priority, &right.id, &right.path))
    });
    let mut seen = std::collections::HashSet::new();
    request
        .existing
        .into_iter()
        .chain(request.candidates.into_iter().map(|item| item.path))
        .filter(|path| !path.is_empty())
        .filter(|path| {
            seen.insert(if request.case_insensitive {
                path.to_ascii_lowercase()
            } else {
                path.clone()
            })
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn search_path_command_follows_the_shared_order_and_identity_fixture() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../../shared/fixtures/execution/search-path-v1.json"
        ))
        .unwrap();
        for case in fixture["cases"].as_array().unwrap() {
            let request = serde_json::json!({"id":"search-path", "command":"execution.resolveSearchPath", "payload":case["request"]});
            let response: Value =
                serde_json::from_str(&crate::execute_json(&request.to_string())).unwrap();
            assert_eq!(response["ok"], true, "{}: {response}", case["name"]);
            assert_eq!(response["data"], case["expected"], "{}", case["name"]);
        }
    }

    // A structured binding that reaches Core unresolved names no value, so it
    // must be dropped rather than leak an empty or stale variable.
    #[test]
    fn overrides_replace_inherited_values_and_drop_unresolved_bindings() {
        let request: LaunchEnvironmentRequest = serde_json::from_value(serde_json::json!({
            "inherited": { "Path": "bin", "TOOL_A_HOME": "inherited" },
            "overrides": {
                "TOOL_A_HOME": "selected",
                "TOOL_B_HOME": { "toolchain": "tool-b", "property": "home" }
            },
            "caseInsensitive": true
        }))
        .unwrap();
        assert_eq!(
            serde_json::to_value(resolve_launch_environment(request)).unwrap(),
            serde_json::json!({
                "environment": { "PATH": "bin", "TOOL_A_HOME": "selected" }
            })
        );
    }
}
