//! Validates inert machine-local pins and resolves directory inheritance without I/O.

use crate::plugins::declarative::{PluginRejection, Validation};
use serde_json::{json, Map, Value};

const MAX_DIRECTORIES: usize = 1024;
const MAX_TOOLS_PER_DIRECTORY: usize = 64;
const MAX_DIRECTORY_BYTES: usize = 2048;
const MAX_PATH_BYTES: usize = 4096;

/// Resolves a stored pin without granting execution authority or modifying the document.
/// Callers must independently require an active definition and validate native files.
pub(crate) fn resolve(input: &Value) -> Validation<Value> {
    let request = object(input, "input", &["document", "directory", "tool"])?;
    let document = required(request, "document", "input")?;
    validate(document)?;
    let directory = text(
        required(request, "directory", "input")?,
        "directory",
        MAX_DIRECTORY_BYTES,
    )?;
    if !valid_directory(directory) {
        return Err(invalid(
            "directory",
            "Expected a normalized workspace-relative directory.",
        ));
    }
    let tool = text(required(request, "tool", "input")?, "tool", 192)?;
    if !valid_tool_id(tool) {
        return Err(invalid("tool", "Expected a valid tool identifier."));
    }
    let pins = document.get("pins").and_then(Value::as_object);
    let mut ancestor = directory;
    loop {
        if let Some(pin) = pins
            .and_then(|entries| entries.get(ancestor))
            .and_then(|tools| tools.get(tool))
        {
            return Ok(json!({"pin": pin, "sourceDirectory": ancestor}));
        }
        if ancestor == "." {
            return Ok(json!({"pin": null, "sourceDirectory": null}));
        }
        ancestor = ancestor.rsplit_once('/').map_or(".", |(parent, _)| parent);
    }
}

/// Checks the complete local document, retaining legacy entries and dormant tool IDs.
/// This validation is lexical only; paths are never probed, canonicalized, or launched.
pub(crate) fn validate(document: &Value) -> Validation<()> {
    let root = object(document, "document", &["version", "toolchains", "pins"])?;
    if required(root, "version", "document")?.as_u64() != Some(1) {
        return Err(invalid(
            "document.version",
            "Expected local toolchain document version 1.",
        ));
    }
    let legacy = object(
        required(root, "toolchains", "document")?,
        "document.toolchains",
        &[],
    )?;
    count(legacy.len(), MAX_DIRECTORIES, "document.toolchains")?;
    for (id, value) in legacy {
        text(&Value::String(id.clone()), "document.toolchains", 192)?;
        let field = format!("document.toolchains.{id}");
        let entry = object(value, &field, &["home", "executable", "javaHome"])?;
        // Legacy paths retain their original meaning; validation must not migrate them.
        for (property, value) in entry {
            text(value, &format!("{field}.{property}"), MAX_PATH_BYTES)?;
        }
    }
    let Some(pins) = root.get("pins") else {
        return Ok(());
    };
    let pins = object(pins, "document.pins", &[])?;
    count(pins.len(), MAX_DIRECTORIES, "document.pins")?;
    for (directory, tools) in pins {
        let field = format!("document.pins.{directory}");
        if directory.len() > MAX_DIRECTORY_BYTES {
            return Err(limit(&field));
        }
        if !valid_directory(directory) {
            return Err(invalid(
                &field,
                "Expected a normalized workspace-relative directory.",
            ));
        }
        let tools = object(tools, &field, &[])?;
        count(tools.len(), MAX_TOOLS_PER_DIRECTORY, &field)?;
        for (tool, pin) in tools {
            let field = format!("{field}.{tool}");
            if !valid_tool_id(tool) {
                return Err(invalid(&field, "Expected a valid tool identifier."));
            }
            validate_pin(pin, &field)?;
        }
    }
    Ok(())
}

/// Validates one inert stored installation reference without looking up its owner.
fn validate_pin(value: &Value, field: &str) -> Validation<()> {
    let pin = object(value, field, &["home", "version", "provider"])?;
    let home = text(
        required(pin, "home", field)?,
        &format!("{field}.home"),
        MAX_PATH_BYTES,
    )?;
    if !valid_native_path(home) {
        return Err(invalid(
            format!("{field}.home"),
            "Expected an absolute native installation path without traversal.",
        ));
    }
    text(
        required(pin, "version", field)?,
        &format!("{field}.version"),
        128,
    )?;
    let provider = text(
        required(pin, "provider", field)?,
        &format!("{field}.provider"),
        256,
    )?;
    let valid = provider.split_once(':').is_some_and(|(plugin, id)| {
        plugin.starts_with(|character: char| character.is_ascii_lowercase())
            && valid_namespace(plugin)
            && valid_local_id(id)
    });
    if !valid {
        return Err(invalid(
            format!("{field}.provider"),
            "Expected a qualified provider identifier.",
        ));
    }
    Ok(())
}

/// Accepts the root marker or normalized portable directory components.
fn valid_directory(value: &str) -> bool {
    value == "."
        || (!value.is_empty()
            && !value
                .chars()
                .any(|character| character.is_control() || matches!(character, '\\' | ':'))
            && value
                .split('/')
                .all(|part| !part.is_empty() && part != "." && part != ".."))
}

/// Checks both reserved short IDs and plugin-qualified IDs, not registry membership.
fn valid_tool_id(value: &str) -> bool {
    value.len() <= 192
        && match value.split_once(':') {
            Some((namespace, id)) => valid_namespace(namespace) && valid_local_id(id),
            None => valid_local_id(value),
        }
}

/// Checks the lowercase dotted/dashed namespace grammar used by tool IDs.
fn valid_namespace(value: &str) -> bool {
    !value.is_empty()
        && value.split(['.', '-']).all(|part| {
            !part.is_empty()
                && part
                    .bytes()
                    .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit())
        })
}

/// Checks the bounded local portion of a tool or provider ID.
fn valid_local_id(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value.as_bytes()[0].is_ascii_lowercase()
        && value
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
}

/// Recognizes POSIX, drive-rooted Windows, and UNC paths on either build platform.
fn valid_native_path(value: &str) -> bool {
    if value.chars().any(char::is_control) {
        return false;
    }
    if let Some(path) = value
        .strip_prefix("\\\\")
        .or_else(|| value.strip_prefix("//"))
    {
        let path = path.strip_suffix(['/', '\\']).unwrap_or(path);
        let parts: Vec<_> = path.split(['/', '\\']).collect();
        return parts.len() >= 2 && valid_native_components(&parts, true);
    }
    let bytes = value.as_bytes();
    if bytes.len() >= 3
        && bytes[0].is_ascii_alphabetic()
        && bytes[1] == b':'
        && matches!(bytes[2], b'/' | b'\\')
    {
        if value.len() == 3 {
            return true;
        }
        let path = value[3..].strip_suffix(['/', '\\']).unwrap_or(&value[3..]);
        return !path.is_empty()
            && valid_native_components(&path.split(['/', '\\']).collect::<Vec<_>>(), true);
    }
    let Some(path) = value.strip_prefix('/') else {
        return false;
    };
    if path.contains('\\') {
        return false;
    }
    if path.is_empty() {
        return true;
    }
    let path = path.strip_suffix('/').unwrap_or(path);
    !path.is_empty() && valid_native_components(&path.split('/').collect::<Vec<_>>(), false)
}

/// Rejects traversal and Windows device/stream spellings without touching disk.
fn valid_native_components(parts: &[&str], windows: bool) -> bool {
    parts.iter().all(|part| {
        !part.is_empty()
            && *part != "."
            && *part != ".."
            && (!windows
                || (!part.ends_with([' ', '.'])
                    && !part.chars().any(|character| {
                        matches!(character, ':' | '*' | '?' | '"' | '<' | '>' | '|')
                    })))
    })
}

/// Checks record fields while allowing callers to explicitly select keyed-map mode.
fn object<'a>(
    value: &'a Value,
    field: &str,
    allowed: &[&str],
) -> Validation<&'a Map<String, Value>> {
    let entries = value
        .as_object()
        .ok_or_else(|| invalid(field, "Expected an object."))?;
    // An empty allowlist denotes an explicitly keyed map, not an open record.
    if !allowed.is_empty() {
        if let Some(key) = entries.keys().find(|key| !allowed.contains(&key.as_str())) {
            return Err(invalid(format!("{field}.{key}"), "Unknown field."));
        }
    }
    Ok(entries)
}

/// Reports missing fields at their stable request path.
fn required<'a>(entries: &'a Map<String, Value>, key: &str, field: &str) -> Validation<&'a Value> {
    entries
        .get(key)
        .ok_or_else(|| invalid(format!("{field}.{key}"), "Required field is missing."))
}

/// Bounds stored text by UTF-8 bytes before any further lexical interpretation.
fn text<'a>(value: &'a Value, field: &str, max: usize) -> Validation<&'a str> {
    let text = value
        .as_str()
        .ok_or_else(|| invalid(field, "Expected a string."))?;
    if text.len() > max {
        return Err(limit(field));
    }
    if text.is_empty() || text.chars().any(char::is_control) {
        return Err(invalid(
            field,
            "Expected a nonempty string without control characters.",
        ));
    }
    Ok(text)
}

/// Applies collection budgets independently of whether a pin will be selected.
fn count(actual: usize, max: usize, field: &str) -> Validation<()> {
    if actual > max {
        Err(limit(field))
    } else {
        Ok(())
    }
}

/// Produces the common malformed-input error used by pure toolchain operations.
fn invalid(field: impl Into<String>, message: impl Into<String>) -> PluginRejection {
    PluginRejection::at("plugin.toolchain.invalidParams", field, message)
}

/// Keeps resource-limit failures distinct from malformed storage.
fn limit(field: impl Into<String>) -> PluginRejection {
    PluginRejection::at(
        "plugin.toolchain.limitExceeded",
        field,
        "Local toolchain storage exceeds its bounded limits.",
    )
}
