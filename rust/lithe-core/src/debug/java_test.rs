//! Deterministic Java test launch configuration shared by native products.

use std::collections::HashSet;

use serde::Deserialize;
use serde_json::{Map, Value};

use crate::protocol::{CoreError, ErrorCode};

use super::{DebugLaunchConfiguration, DebugRequestKind};

#[derive(Debug, Clone, Copy, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Java test framework whose runner arguments must be projected into DAP.
pub enum JavaTestFramework {
    Junit,
    Testng,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
/// Platform-observed JDT LS launch metadata plus one loopback result port.
pub struct JavaTestLaunchRequest {
    pub name: String,
    pub framework: JavaTestFramework,
    pub working_directory: String,
    pub main_class: String,
    #[serde(default)]
    pub project_name: Option<String>,
    #[serde(default)]
    pub class_paths: Vec<String>,
    #[serde(default)]
    pub module_paths: Vec<String>,
    #[serde(default)]
    pub vm_arguments: Vec<String>,
    #[serde(default)]
    pub program_arguments: Vec<String>,
    pub result_port: u16,
    #[serde(default)]
    pub testng_runner_path: Option<String>,
    #[serde(default)]
    pub testng_test_names: Vec<String>,
}

/// Creates the provider arguments consumed by Java Debug Server.
pub fn java_test_launch(
    request: JavaTestLaunchRequest,
) -> Result<DebugLaunchConfiguration, CoreError> {
    let name = required(request.name, "Java test launch name is required.")?;
    let working_directory = required(
        request.working_directory,
        "Java test working directory is required.",
    )?;
    let main_class = required(request.main_class, "Java test main class is required.")?;
    if request.result_port == 0 {
        return Err(invalid_request(
            "Java test result port must be between 1 and 65535.",
        ));
    }

    let mut class_paths = non_empty_unique(request.class_paths);
    let module_paths = non_empty_unique(request.module_paths);
    let vm_arguments = non_empty(request.vm_arguments);
    let mut arguments = Map::new();
    arguments.insert("mainClass".to_string(), Value::String(main_class));
    arguments.insert("cwd".to_string(), Value::String(working_directory));
    arguments.insert(
        "console".to_string(),
        Value::String("integratedTerminal".to_string()),
    );
    if let Some(project_name) = optional_non_empty(request.project_name) {
        arguments.insert("projectName".to_string(), Value::String(project_name));
    }

    let program_arguments = match request.framework {
        JavaTestFramework::Junit => junit_arguments(request.program_arguments, request.result_port),
        JavaTestFramework::Testng => {
            let runner_path = required(
                request.testng_runner_path.unwrap_or_default(),
                "The Java TestNG runner is unavailable.",
            )?;
            if !class_paths.iter().any(|path| path == &runner_path) {
                class_paths.push(runner_path);
            }
            let test_names = non_empty_unique(request.testng_test_names);
            if test_names.is_empty() {
                return Err(invalid_request(
                    "At least one TestNG test method is required.",
                ));
            }
            std::iter::once(request.result_port.to_string())
                .chain(std::iter::once("testng".to_string()))
                .chain(test_names)
                .collect()
        }
    };

    insert_string_array(&mut arguments, "classPaths", class_paths);
    insert_string_array(&mut arguments, "modulePaths", module_paths);
    insert_java_debug_arguments(&mut arguments, "args", program_arguments);
    insert_java_debug_arguments(&mut arguments, "vmArgs", vm_arguments);

    Ok(DebugLaunchConfiguration {
        name,
        request: DebugRequestKind::Launch,
        arguments,
        stepping_filters: None,
    })
}

fn junit_arguments(arguments: Vec<String>, result_port: u16) -> Vec<String> {
    let mut arguments = arguments;
    let port = result_port.to_string();
    if let Some(index) = arguments.iter().rposition(|value| value == "-port") {
        if index + 1 < arguments.len() {
            arguments[index + 1] = port;
            return arguments;
        }
    }
    arguments.push("-port".to_string());
    arguments.push(port);
    arguments
}

fn required(value: String, message: &str) -> Result<String, CoreError> {
    let value = value.trim().to_string();
    if value.is_empty() {
        Err(invalid_request(message))
    } else {
        Ok(value)
    }
}

fn optional_non_empty(value: Option<String>) -> Option<String> {
    value.and_then(|value| {
        let value = value.trim().to_string();
        (!value.is_empty()).then_some(value)
    })
}

fn non_empty(values: Vec<String>) -> Vec<String> {
    values
        .into_iter()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .collect()
}

fn non_empty_unique(values: Vec<String>) -> Vec<String> {
    let mut seen = HashSet::new();
    non_empty(values)
        .into_iter()
        .filter(|value| seen.insert(value.clone()))
        .collect()
}

fn insert_string_array(arguments: &mut Map<String, Value>, key: &str, values: Vec<String>) {
    if values.is_empty() {
        return;
    }
    arguments.insert(
        key.to_string(),
        Value::Array(values.into_iter().map(Value::String).collect()),
    );
}

fn insert_java_debug_arguments(arguments: &mut Map<String, Value>, key: &str, values: Vec<String>) {
    let value = java_debug_argument_string(values);
    if !value.is_empty() {
        arguments.insert(key.to_string(), Value::String(value));
    }
}

fn java_debug_argument_string(values: Vec<String>) -> String {
    // Java Test exposes arrays to VS Code, but Java Debug Server's DAP model
    // accepts one command-line string. Mirror the upstream extension's
    // serialization so the adapter can reconstruct spaces, quotes, and paths.
    non_empty(values)
        .into_iter()
        .map(|value| {
            if value
                .chars()
                .any(|character| character == '"' || character.is_whitespace())
            {
                let escaped = value.chars().fold(String::new(), |mut result, character| {
                    if matches!(character, '"' | '\\') {
                        result.push('\\');
                    }
                    result.push(character);
                    result
                });
                format!("\"{escaped}\"")
            } else {
                value
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn invalid_request(message: &str) -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, message)
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;

    #[test]
    fn junit_launch_replaces_the_server_placeholder_port() {
        let configuration = java_test_launch(JavaTestLaunchRequest {
            name: "UserServiceTest".to_string(),
            framework: JavaTestFramework::Junit,
            working_directory: "/workspace".to_string(),
            main_class: "org.eclipse.jdt.internal.junit.runner.RemoteTestRunner".to_string(),
            project_name: Some("service".to_string()),
            class_paths: vec!["/workspace/classes".to_string()],
            module_paths: Vec::new(),
            vm_arguments: vec!["--enable-preview".to_string()],
            program_arguments: vec![
                "-version".to_string(),
                "3".to_string(),
                "-port".to_string(),
                "-1".to_string(),
            ],
            result_port: 43127,
            testng_runner_path: None,
            testng_test_names: Vec::new(),
        })
        .expect("JUnit launch should resolve");

        assert_eq!(
            configuration.arguments["args"],
            json!("-version 3 -port 43127")
        );
        assert_eq!(
            configuration.arguments["classPaths"],
            json!(["/workspace/classes"])
        );
        assert_eq!(configuration.arguments["vmArgs"], json!("--enable-preview"));
    }

    #[test]
    fn testng_launch_appends_the_packaged_runner_once() {
        let configuration = java_test_launch(JavaTestLaunchRequest {
            name: "UserServiceTest".to_string(),
            framework: JavaTestFramework::Testng,
            working_directory: "/workspace".to_string(),
            main_class: "com.microsoft.java.test.runner.Launcher".to_string(),
            project_name: Some("service".to_string()),
            class_paths: vec![
                "/workspace/classes".to_string(),
                "/lithe/java-test-runner.jar".to_string(),
            ],
            module_paths: Vec::new(),
            vm_arguments: Vec::new(),
            program_arguments: Vec::new(),
            result_port: 43128,
            testng_runner_path: Some("/lithe/java-test-runner.jar".to_string()),
            testng_test_names: vec![
                "example.UserServiceTest#logsIn".to_string(),
                "example.UserServiceTest#logsIn".to_string(),
            ],
        })
        .expect("TestNG launch should resolve");

        assert_eq!(
            configuration.arguments["classPaths"],
            json!(["/workspace/classes", "/lithe/java-test-runner.jar"])
        );
        assert_eq!(
            configuration.arguments["args"],
            json!("43128 testng example.UserServiceTest#logsIn")
        );
    }

    #[test]
    fn java_debug_arguments_match_the_adapter_command_line_contract() {
        assert_eq!(
            java_debug_argument_string(vec![
                "-Dlabel=hello world".to_string(),
                "say\"hello".to_string(),
                r"C:\plain".to_string(),
                r"C:\Program Files\Java".to_string(),
            ]),
            r#""-Dlabel=hello world" "say\"hello" C:\plain "C:\\Program Files\\Java""#
        );
    }
}
