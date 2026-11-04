//! Resolves launch environment precedence after platform-owned tool discovery.

use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::BTreeMap;

/// Platform-resolved homes and inherited environment for one launch step.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LaunchEnvironmentRequest {
    /// Toolchain of this step, not the later application process.
    pub toolchain: Option<String>,
    /// Resolved project JDK home.
    pub java_home: Option<String>,
    /// Resolved Maven JVM home, falling back to the project home when absent.
    pub maven_java_home: Option<String>,
    /// Native parent process environment; selected homes override it.
    #[serde(default)]
    pub inherited: BTreeMap<String, String>,
    /// Plan bindings followed by explicit user overrides, already merged by key.
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

/// Applies inherited < selected toolchain < explicit launch overrides.
/// Maven steps use their Maven JDK; direct Java steps retain the project JDK.
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
    let selected = if request.toolchain.as_deref() == Some("project-maven") {
        request
            .maven_java_home
            .as_ref()
            .or(request.java_home.as_ref())
    } else if request.toolchain.as_deref() == Some("project-jdk") {
        request.java_home.as_ref()
    } else {
        None
    };
    if let Some(home) = selected {
        insert("JAVA_HOME".into(), home.clone());
    }
    for (key, value) in request.overrides {
        let resolved = if let Some(text) = value.as_str() {
            Some(text.to_owned())
        } else if value.get("property").and_then(Value::as_str) == Some("home") {
            // A pre-launch Maven step may inherit its application's Java binding.
            // The executable's role owns JAVA_HOME; literal user overrides remain
            // authoritative. Other variables keep their explicit binding.
            if key.eq_ignore_ascii_case("JAVA_HOME") && selected.is_some() {
                selected.cloned()
            } else {
                match value.get("toolchain").and_then(Value::as_str) {
                    Some("project-jdk") => request.java_home.clone(),
                    Some("project-maven") => request
                        .maven_java_home
                        .clone()
                        .or(request.java_home.clone()),
                    _ => None,
                }
            }
        } else {
            None
        };
        if let Some(value) = resolved {
            insert(key, value);
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

    #[test]
    fn shared_launch_environment_fixtures() {
        let cases: Value = serde_json::from_str(include_str!(
            "../../../../shared/fixtures/execution/launch-environment-v1.json"
        ))
        .unwrap();
        for case in cases["cases"].as_array().unwrap() {
            let request = serde_json::from_value(case["request"].clone()).unwrap();
            assert_eq!(
                serde_json::to_value(resolve_launch_environment(request)).unwrap(),
                case["expected"],
                "{}",
                case["name"]
            );
        }
    }
}
