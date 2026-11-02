//! Inert consumer-scoped tool choices and symbolic workspace inheritance.
//!
//! This module selects saved inputs, never installations or executable facts.
//! Native consumers still pass the chosen fixed value to the existing resolver
//! and revalidate the owning document after collecting native evidence.

use super::{fixed::FixedToolchainSelection, pins};
use crate::plugins::declarative::{PluginRejection, Validation};
use serde_json::{json, Map, Value};

const MAX_DOCUMENT_BYTES: usize = 2 * 1024 * 1024;
const MAX_DIRECTORIES: usize = 256;
const MAX_CONSUMERS: usize = 128;
const MAX_TOOLS: usize = 64;

/// Resolves an explicit Run choice, then consumer/directory preferences.
/// Inheritance stays symbolic: changing the workspace default affects the
/// next resolution without rewriting every consumer or directory.
pub(super) fn resolve(input: &Value) -> Validation<Value> {
    let request = object(
        input,
        "input",
        &["document", "directory", "consumer", "tool", "fixed"],
    )?;
    let document = request.get("document").ok_or_else(|| invalid("document"))?;
    validate(document)?;
    let directory = request
        .get("directory")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid("directory"))?;
    if directory.len() > 2048 || !pins::valid_directory(directory) {
        return Err(invalid("directory"));
    }
    let tool = request
        .get("tool")
        .and_then(Value::as_str)
        .ok_or_else(|| invalid("tool"))?;
    if !pins::valid_tool_id(tool) {
        return Err(invalid("tool"));
    }
    let consumer = request
        .get("consumer")
        .filter(|value| !value.is_null())
        .map(|value| {
            value
                .as_str()
                .filter(|id| valid_consumer(id))
                .ok_or_else(|| invalid("consumer"))
        })
        .transpose()?;
    if let Some(fixed) = request.get("fixed").filter(|value| !value.is_null()) {
        FixedToolchainSelection::parse(fixed)?;
        return Ok(json!({"fixed":fixed,"source":{"kind":"run"},"inheritance":[]}));
    }
    let workspace = &document["workspace"];
    let directories = document["directories"].as_object();
    let mut ancestors = Vec::new();
    let mut current = directory;
    while current != "." {
        ancestors.push(current);
        current = current.rsplit_once('/').map_or(".", |(parent, _)| parent);
    }
    // A consumer's own saved choice takes precedence over general defaults.
    // An absent entry inherits; an explicit reference can skip parent choices.
    if let Some(consumer) = consumer {
        for directory in &ancestors {
            if let Some(binding) = directories
                .and_then(|map| map.get(*directory))
                .and_then(|scope| scope["consumers"][consumer].get(tool))
            {
                return resolved(
                    binding,
                    "consumer",
                    directory,
                    Some(consumer),
                    workspace,
                    tool,
                );
            }
        }
        if let Some(binding) = workspace["consumers"][consumer].get(tool) {
            return resolved(binding, "consumer", ".", Some(consumer), workspace, tool);
        }
    }
    for directory in ancestors {
        if let Some(binding) = directories
            .and_then(|map| map.get(directory))
            .and_then(|scope| scope["tools"].get(tool))
        {
            return resolved(binding, "directory", directory, None, workspace, tool);
        }
    }
    match workspace["tools"].get(tool) {
        Some(binding) => resolved(binding, "workspace", ".", None, workspace, tool),
        None => Ok(automatic(Vec::new())),
    }
}

fn resolved(
    binding: &Value,
    kind: &str,
    directory: &str,
    consumer: Option<&str>,
    workspace: &Value,
    tool: &str,
) -> Validation<Value> {
    let source = json!({"kind":kind,"directory":directory,"consumer":consumer});
    let Some(inherit) = binding.get("inherit").and_then(Value::as_str) else {
        return Ok(json!({"fixed":binding,"source":source,"inheritance":[]}));
    };
    let mut inheritance = vec![source];
    if inherit == "consumer" {
        let consumer = consumer.ok_or_else(|| invalid("inherit"))?;
        if let Some(binding) = workspace["consumers"][consumer].get(tool) {
            // Workspace consumer references can only point at workspace tools;
            // they cannot point back into consumer or directory scopes.
            if binding.get("inherit").is_none() {
                return Ok(
                    json!({"fixed":binding,"source":{"kind":"consumer","directory":".","consumer":consumer},"inheritance":inheritance}),
                );
            }
            inheritance.push(json!({"kind":"consumer","directory":".","consumer":consumer}));
        }
    }
    match workspace["tools"].get(tool) {
        Some(binding) => Ok(
            json!({"fixed":binding,"source":{"kind":"workspace","directory":".","consumer":null},"inheritance":inheritance}),
        ),
        None => Ok(automatic(inheritance)),
    }
}

fn automatic(inheritance: Vec<Value>) -> Value {
    json!({"fixed":null,"source":{"kind":"automatic"},"inheritance":inheritance})
}

/// Validates dormant IDs as inert preferences without requiring installation
/// or package trust. Their presence never registers a tool or grants authority.
pub(crate) fn validate(document: &Value) -> Validation<()> {
    if document.to_string().len() > MAX_DOCUMENT_BYTES {
        return Err(limit("document"));
    }
    let root = object(
        document,
        "document",
        &["version", "workspace", "directories"],
    )?;
    if root.get("version").and_then(Value::as_u64) != Some(1) {
        return Err(invalid("document.version"));
    }
    if let Some(workspace) = root.get("workspace") {
        scope(workspace, "workspace", true)?;
    }
    if let Some(directories) = root.get("directories") {
        let directories = map(directories, "directories", MAX_DIRECTORIES)?;
        for (directory, value) in directories {
            if directory == "." || directory.len() > 2048 || !pins::valid_directory(directory) {
                return Err(invalid("directories"));
            }
            scope(value, "directories", false)?;
        }
    }
    Ok(())
}

fn scope(value: &Value, field: &str, workspace: bool) -> Validation<()> {
    let scope = object(value, field, &["tools", "consumers"])?;
    if let Some(tools) = scope.get("tools") {
        tools_map(tools, field, workspace, false)?;
    }
    if let Some(consumers) = scope.get("consumers") {
        for (consumer, tools) in map(consumers, field, MAX_CONSUMERS)? {
            if !valid_consumer(consumer) {
                return Err(invalid(field));
            }
            tools_map(tools, field, workspace, true)?;
        }
    }
    Ok(())
}

fn tools_map(value: &Value, field: &str, workspace: bool, consumer: bool) -> Validation<()> {
    for (tool, binding) in map(value, field, MAX_TOOLS)? {
        if !pins::valid_tool_id(tool) {
            return Err(invalid(field));
        }
        if binding.get("inherit").is_some() {
            let reference = object(binding, field, &["inherit"])?;
            match reference.get("inherit").and_then(Value::as_str) {
                Some("workspace") if !workspace || consumer => {}
                Some("consumer") if !workspace && consumer => {}
                _ => return Err(invalid(field)),
            }
        } else {
            FixedToolchainSelection::parse(binding)?;
        }
    }
    Ok(())
}

fn valid_consumer(value: &str) -> bool {
    value.len() <= 256
        && value.split_once('/').is_some_and(|(plugin, local)| {
            crate::plugins::declarative::is_plugin_id(plugin) && pins::valid_local_id(local)
        })
}

fn map<'a>(value: &'a Value, field: &str, max: usize) -> Validation<&'a Map<String, Value>> {
    let object = value.as_object().ok_or_else(|| invalid(field))?;
    if object.len() > max {
        return Err(limit(field));
    }
    Ok(object)
}

fn object<'a>(value: &'a Value, field: &str, keys: &[&str]) -> Validation<&'a Map<String, Value>> {
    let object = value.as_object().ok_or_else(|| invalid(field))?;
    if object.keys().any(|key| !keys.contains(&key.as_str())) {
        return Err(invalid(field));
    }
    Ok(object)
}

fn invalid(field: &str) -> PluginRejection {
    PluginRejection::at(
        "plugin.toolchain.invalidParams",
        field,
        "Invalid consumer tool preferences.",
    )
}

fn limit(field: &str) -> PluginRejection {
    PluginRejection::at(
        "plugin.toolchain.limitExceeded",
        field,
        "Consumer tool preferences exceed their budget.",
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn shared_preferences_fixture_resolves_without_native_or_domain_facts() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../../shared/fixtures/toolchains/consumer-preferences.json"
        ))
        .unwrap();
        for case in fixture["cases"].as_array().unwrap() {
            let input = json!({"document":fixture["document"],"tool":"dev.example.runtime:sdk",
                "directory":case["directory"],"consumer":case["consumer"]});
            let result = crate::toolchain::resolve_consumer_preferences_command(input).unwrap();
            assert_eq!(result["status"], "ok", "{result}");
            assert_eq!(result["preferences"]["fixed"], case["expected"]);
        }
    }

    #[test]
    fn consumer_preferences_json_dispatcher_preserves_the_value_boundary() {
        let payload = request(document());
        let response: Value = serde_json::from_str(&crate::execute_json(&json!({
            "id":"consumer-preferences","command":"toolchains.resolveConsumerPreferences","payload":payload
        }).to_string())).unwrap();
        assert_eq!(response["ok"], true, "{response}");
        assert_eq!(
            response["data"]["preferences"]["fixed"],
            json!({"home":"/fixture/sdk-one"})
        );
    }

    fn document() -> Value {
        json!({"version":1,"workspace":{"tools":{"dev.example.runtime:sdk":{"home":"/fixture/sdk-one"}},
            "consumers":{"dev.example.build/engine":{"dev.example.runtime:sdk":{"inherit":"workspace"}}}},
            "directories":{"nested":{"tools":{"dev.example.runtime:sdk":{"home":"/fixture/directory-sdk"}}}}})
    }
    fn request(document: Value) -> Value {
        json!({"document":document,"tool":"dev.example.runtime:sdk","directory":"nested/child","consumer":"dev.example.build/engine"})
    }

    #[test]
    fn symbolic_consumer_inheritance_follows_workspace_changes_without_freezing_paths() {
        let mut document = document();
        assert_eq!(
            resolve(&request(document.clone())).unwrap()["fixed"],
            json!({"home":"/fixture/sdk-one"})
        );
        document["workspace"]["tools"]["dev.example.runtime:sdk"] =
            json!({"home":"/fixture/sdk-two"});
        assert_eq!(
            resolve(&request(document.clone())).unwrap()["fixed"],
            json!({"home":"/fixture/sdk-two"})
        );
        document["workspace"]["tools"] = json!({});
        assert!(resolve(&request(document)).unwrap()["fixed"].is_null());
    }

    #[test]
    fn directory_reference_can_skip_parent_consumer_choices_without_copying_the_workspace_value() {
        let mut document = document();
        document["directories"]["nested"]["consumers"] = json!({"dev.example.build/engine":{"dev.example.runtime:sdk":{"home":"/fixture/parent-choice"}}});
        document["directories"]["nested/child"] = json!({"consumers":{"dev.example.build/engine":{"dev.example.runtime:sdk":{"inherit":"consumer"}}}});
        let value = resolve(&request(document.clone())).unwrap();
        assert_eq!(value["fixed"], json!({"home":"/fixture/sdk-one"}));
        assert_eq!(value["inheritance"].as_array().unwrap().len(), 2);
        document["workspace"]["consumers"]["dev.example.build/engine"]["dev.example.runtime:sdk"] =
            json!({"home":"/fixture/consumer-workspace"});
        assert_eq!(
            resolve(&request(document)).unwrap()["fixed"],
            json!({"home":"/fixture/consumer-workspace"})
        );
    }

    #[test]
    fn ordinary_directory_and_run_choices_remain_generic_and_nearest() {
        let mut input = request(document());
        input["consumer"] = Value::Null;
        assert_eq!(
            resolve(&input).unwrap()["fixed"],
            json!({"home":"/fixture/directory-sdk"})
        );
        input["fixed"] = json!({"executable":"C:/fixture/explicit.cmd"});
        assert_eq!(resolve(&input).unwrap()["source"]["kind"], "run");
        input["fixed"] = Value::Null;
        assert_eq!(resolve(&input).unwrap()["source"]["kind"], "directory");
        // A consumer identity follows the installed manifest's ID grammar,
        // even when that valid owner is not a dotted tool-definition namespace.
        input["consumer"] = json!("fixture-owner/engine");
        assert_eq!(resolve(&input).unwrap()["source"]["kind"], "directory");
    }

    #[test]
    fn preferences_reject_cycles_invalid_scopes_unknown_fields_and_relative_fixed_paths() {
        let base = document();
        for (pointer, value) in [
            (
                "/workspace/tools/dev.example.runtime:sdk",
                json!({"inherit":"workspace"}),
            ),
            (
                "/workspace/consumers/dev.example.build~1engine/dev.example.runtime:sdk",
                json!({"inherit":"consumer"}),
            ),
            (
                "/directories/nested/tools/dev.example.runtime:sdk",
                json!({"inherit":"consumer"}),
            ),
            (
                "/workspace/tools/dev.example.runtime:sdk",
                json!({"home":"relative"}),
            ),
            (
                "/workspace/tools/dev.example.runtime:sdk",
                json!({"home":"/fixture/sdk","inherit":"workspace"}),
            ),
        ] {
            let mut document = base.clone();
            *document.pointer_mut(pointer).unwrap() = value;
            assert!(validate(&document).is_err(), "{document}");
        }
        for directory in [
            ".",
            "../outside",
            "nested/../outside",
            "C:/outside",
            "nested\\child",
        ] {
            let mut document = base.clone();
            document["directories"] = json!({directory:{}});
            assert!(validate(&document).is_err());
        }
        let mut input = request(base);
        input["consumer"] = json!("unqualified");
        assert!(resolve(&input).is_err());
    }
}
