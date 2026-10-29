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

#[cfg(test)]
mod tests {
    use super::*;

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
