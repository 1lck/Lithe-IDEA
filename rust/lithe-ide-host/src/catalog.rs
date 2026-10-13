//! One capability catalog and validation boundary for plugins and MCP clients.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};

/// Authorization is granted by the IDE settings UI, never by tool arguments.
#[derive(Clone, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Permissions {
    #[serde(default)]
    pub configure: bool,
    #[serde(default)]
    pub execute: bool,
}

/// A stable application failure, also returned as an MCP tool error.
pub fn failure(code: &str, message: &str) -> Value {
    json!({"ok": false, "error": {"code": code, "message": message}})
}

fn string() -> Value {
    json!({"type":"string", "maxLength":4096})
}
fn schema(properties: Value, required: &[&str]) -> Value {
    json!({"type":"object", "properties":properties, "required":required, "additionalProperties":false})
}

/// Public tools deliberately expose product workflows rather than shell/file primitives.
pub fn tools() -> Vec<Value> {
    let definitions = vec![
        ("lithe_project_inspect", "Inspect the connected IDE project, readiness and available permissions.", "read", schema(json!({}), &[])),
        ("lithe_environment_inspect", "Discover Java and Maven installations and inspect saved and effective project environment settings. Does not install tools.", "read", schema(json!({}), &[])),
        ("lithe_environment_configure", "Update selected project-local Java/Maven defaults using the IDE settings workflow. Empty paths restore automatic selection. Other settings are preserved. Requires configure permission.", "configure", schema(json!({"javaHomePath":string(),"mavenExecutablePath":string(),"mavenJavaHomePath":string(),"settingsPath":string(),"localRepositoryPath":string()}), &[])),
        ("lithe_maven_inspect", "Read Maven modules, available/selected profiles, skip-tests setting and reload state.", "read", schema(json!({}), &[])),
        ("lithe_maven_configure", "Save Maven profiles and skip-tests settings through the existing IDE workflow. Requires configure permission.", "configure", schema(json!({"profiles":{"type":"array","items":string(),"maxItems":64},"skipTests":{"type":"boolean"}}), &[])),
        ("lithe_maven_reload", "Reload the Maven project and synchronize the existing Java language service. May resolve dependencies and execute project tooling. Requires execute permission.", "execute", schema(json!({}), &[])),
        ("lithe_maven_execute", "Execute Maven goals through the IDE, using saved profiles and toolchains. Returns operationID for output/status/stop. May execute project code and access the network. Requires execute permission.", "execute", schema(json!({"goals":{"type":"array","items":string(),"minItems":1,"maxItems":32},"modulePath":string()}), &["goals"])),
        ("lithe_run_list", "List saved runnable configurations and readiness. Environment variable values and launch arguments are not disclosed.", "read", schema(json!({}), &[])),
        ("lithe_run_start", "Start an existing IDE run configuration through the normal preparation/build workflow. Returns operationID; pending UI decisions remain in the IDE. Requires execute permission.", "execute", schema(json!({"configurationID":string()}), &["configurationID"])),
        ("lithe_run_restart", "Restart the exact named operation using its existing run configuration. An expired or replaced operation is rejected. Requires execute permission.", "execute", schema(json!({"operationID":string()}), &["operationID"])),
        ("lithe_operations_list", "List retained IDE executions with their operationID, state and exit code.", "read", schema(json!({}), &[])),
        ("lithe_operation_output", "Read bounded output and state for one exact execution. Pass nextCursor to read incrementally. reset=true means output was cleared or truncated; never treats another execution as the same operation.", "read", schema(json!({"operationID":string(),"cursor":string()}), &["operationID"])),
        ("lithe_operation_stop", "Stop one exact execution. Never stops a newer execution occupying the same UI output slot. Requires execute permission.", "execute", schema(json!({"operationID":string()}), &["operationID"])),
    ];
    definitions.into_iter().map(|(name, description, permission, input)| json!({
        "name":name,"description":description,"inputSchema":input,
        "annotations":{"readOnlyHint":permission == "read", "destructiveHint":permission != "read", "openWorldHint":permission != "read"},
        "_meta":{"lithe/permission":permission}
    })).collect()
}

/// Validates even calls made by in-process plugins; MCP schemas are not authorization.
pub fn validate(name: &str, args: &Value, permissions: &Permissions) -> Result<(), Value> {
    let tool = tools()
        .into_iter()
        .find(|v| v["name"] == name)
        .ok_or_else(|| failure("NOT_SUPPORTED", "Unknown IDE capability"))?;
    let permission = tool["_meta"]["lithe/permission"].as_str().unwrap_or("read");
    if (permission == "configure" && !permissions.configure)
        || (permission == "execute" && !permissions.execute)
    {
        return Err(failure(
            "PERMISSION_DENIED",
            "Enable this permission in the project's MCP settings",
        ));
    }
    let invalid = || {
        failure(
            "INVALID_ARGUMENTS",
            "Arguments do not match the IDE capability schema",
        )
    };
    let values = args.as_object().ok_or_else(invalid)?;
    let properties = tool["inputSchema"]["properties"].as_object().unwrap();
    for required in tool["inputSchema"]["required"].as_array().unwrap() {
        if !values.contains_key(required.as_str().unwrap()) {
            return Err(invalid());
        }
    }
    for (key, value) in values {
        let spec = properties.get(key).ok_or_else(invalid)?;
        let valid = match spec["type"].as_str() {
            Some("string") => value
                .as_str()
                .is_some_and(|s| s.len() <= 4096 && !s.contains('\0')),
            Some("boolean") => value.is_boolean(),
            Some("array") => value.as_array().is_some_and(|a| {
                a.len() <= spec["maxItems"].as_u64().unwrap_or(64) as usize
                    && a.len() >= spec["minItems"].as_u64().unwrap_or(0) as usize
                    && a.iter().all(|v| {
                        v.as_str().is_some_and(|s| {
                            !s.is_empty() && s.len() <= 4096 && !s.chars().any(char::is_control)
                        })
                    })
            }),
            _ => false,
        };
        if !valid {
            return Err(invalid());
        }
    }
    if let Some(profiles) = args.get("profiles").and_then(Value::as_array) {
        if profiles.iter().any(|p| {
            p.as_str()
                .is_none_or(|s| s.trim().is_empty() || s.trim() != s || s.contains(','))
        }) {
            return Err(invalid());
        }
    }
    if let Some(module) = args.get("modulePath").and_then(Value::as_str) {
        if module.starts_with('/')
            || module.contains(['\\', ':'])
            || module.split('/').any(|s| s == "..")
        {
            return Err(invalid());
        }
    }
    // A goal is one Maven token. Shell strings, flags and implicit filesystem overrides
    // belong to the IDE's settings/configuration workflow, not this execution surface.
    if let Some(goals) = args.get("goals").and_then(Value::as_array) {
        if goals.iter().any(|g| {
            g.as_str().is_none_or(|s| {
                s.starts_with('-')
                    || !s
                        .chars()
                        .all(|c| c.is_ascii_alphanumeric() || ":._-".contains(c))
            })
        }) {
            return Err(failure(
                "INVALID_ARGUMENTS",
                "Use Maven goal names; configure profiles and paths through the settings tools",
            ));
        }
    }
    Ok(())
}

/// Pages UTF-8 output with a prefix fingerprint so a trimmed/replaced buffer resets explicitly.
pub fn output_page(mut snapshot: Value, cursor: Option<&str>) -> Value {
    let output = snapshot["output"].as_str().unwrap_or("").to_owned();
    let parsed = cursor
        .and_then(|s| s.split_once(':'))
        .and_then(|(offset, hash)| offset.parse::<usize>().ok().map(|o| (o, hash)));
    let valid = parsed.filter(|(o, h)| {
        *o <= output.len()
            && output.is_char_boundary(*o)
            && format!("{:x}", Sha256::digest(&output.as_bytes()[..*o])) == *h
    });
    let mut start = valid.map(|(o, _)| o).unwrap_or(0);
    let reset = cursor.is_some() && valid.is_none();
    let mut end = (start + 32_768).min(output.len());
    while !output.is_char_boundary(end) {
        end -= 1;
    }
    if start > end {
        start = end;
    }
    snapshot["output"] = json!(&output[start..end]);
    snapshot["nextCursor"] = json!(format!(
        "{}:{:x}",
        end,
        Sha256::digest(&output.as_bytes()[..end])
    ));
    snapshot["reset"] = json!(reset);
    snapshot["hasMore"] = json!(end < output.len());
    snapshot
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn shared_fixture_protects_the_plugin_and_mcp_contract() {
        let fixture: Value =
            serde_json::from_str(include_str!("../../../shared/fixtures/ide-api/calls.json"))
                .unwrap();
        let permissions = Permissions {
            configure: true,
            execute: true,
        };
        for call in fixture["accepted"].as_array().unwrap() {
            assert!(
                validate(
                    call["name"].as_str().unwrap(),
                    &call["arguments"],
                    &permissions
                )
                .is_ok(),
                "{call}"
            );
        }
        for call in fixture["rejected"].as_array().unwrap() {
            assert!(
                validate(
                    call["name"].as_str().unwrap(),
                    &call["arguments"],
                    &permissions
                )
                .is_err(),
                "{call}"
            );
        }
    }
    #[test]
    fn authorization_and_argument_validation_cannot_be_bypassed() {
        assert!(validate(
            "lithe_maven_execute",
            &json!({"goals":["verify"]}),
            &Permissions::default()
        )
        .is_err());
        let permissions = Permissions {
            execute: true,
            configure: true,
        };
        for args in [
            json!({"goals":["verify"],"modulePath":"../other"}),
            json!({"goals":["verify;curl"]}),
            json!({"goals":["-f"]}),
            json!({"goals":["verify"],"confirmed":true}),
        ] {
            assert!(validate("lithe_maven_execute", &args, &permissions).is_err());
        }
        assert!(validate(
            "lithe_maven_execute",
            &json!({"goals":["clean","verify"],"modulePath":"module"}),
            &permissions
        )
        .is_ok());
    }
    #[test]
    fn output_cursor_detects_clear_and_truncation_and_preserves_unicode() {
        let first = output_page(json!({"output":"你好\n"}), None);
        let cursor = first["nextCursor"].as_str().unwrap();
        assert_eq!(
            output_page(json!({"output":"你好\nnext"}), Some(cursor))["output"],
            "next"
        );
        let reset = output_page(json!({"output":"replacement"}), Some(cursor));
        assert_eq!(reset["reset"], true);
        assert_eq!(reset["output"], "replacement");
        let page = output_page(json!({"output":"你".repeat(20_000)}), None);
        assert!(page["output"].as_str().unwrap().len() <= 32_768);
        assert_eq!(page["hasMore"], true);
    }
}
