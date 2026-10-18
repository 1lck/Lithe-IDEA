//! Plans one MCP configuration write and enforces the host's ownership ledger.
//!
//! Automatic changes require the ledger to match the complete current entry.
//! Explicit edits can instead present the source hash of the displayed original;
//! that precondition is checked before no-op or ownership decisions.

use super::json_edit::JsonDocument;
use super::parse::{
    find_server, parse_claude_servers, parse_codex_servers, MAX_CONFIGURATION_BYTES,
};
use super::toml_edit;
use super::{McpKeyValue, McpServer};
use crate::protocol::{CoreError, ErrorCode};
use serde::Deserialize;
use serde_json::{json, Map, Value};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct OwnedEntry {
    /// Entry name recorded when Lithe wrote it.
    name: String,
    /// Grouping definition hash recorded at write time.
    definition_hash: String,
    /// Complete entry hash recorded at write time; legacy records omit it.
    #[serde(default)]
    source_hash: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct WriteRequest {
    /// Configuration owner: `codex` or `claude`.
    source: String,
    /// `global` or `project`.
    scope: String,
    #[serde(default)]
    project_path: Option<String>,
    /// Current file text; `null` means the file does not exist yet.
    #[serde(default)]
    content: Option<String>,
    /// `set` or `remove`.
    operation: String,
    #[serde(default)]
    server: Option<McpServer>,
    #[serde(default)]
    name: Option<String>,
    /// Existing name this set renames from. The old entry is used as the base
    /// for the new one so settings Lithe does not model survive the rename.
    #[serde(default)]
    previous_name: Option<String>,
    /// Complete source hash of the displayed original entry. On rename this
    /// refers to `previousName`, and never authorizes the destination entry.
    #[serde(default)]
    expected_hash: Option<String>,
    /// Entries the host recorded as written by Lithe.
    #[serde(default)]
    owned: Vec<OwnedEntry>,
}

fn invalid_request() -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, "Invalid MCP write request")
}

/// Computes the next configuration text for one set or remove operation.
///
/// The response is `{ content, changed, action, conflict }`. `conflict` is
/// `ownedByUser` when the entry was never written by Lithe and
/// `externallyModified` when the on-disk definition no longer matches the
/// ledger or the explicit `expectedHash`; in both cases `content` is unchanged.
/// Successful set plans also return the actual entry's grouping and source hashes.
pub fn plan_write(payload: Value) -> Result<Value, CoreError> {
    let request: WriteRequest = serde_json::from_value(payload).map_err(|_| invalid_request())?;
    let content = request.content.clone().unwrap_or_default();
    if content.len() > MAX_CONFIGURATION_BYTES {
        return Err(invalid_request());
    }
    let project_path = request.project_path.as_deref();
    let valid_scope = matches!(request.scope.as_str(), "global" | "project")
        && (request.scope != "project" || project_path.is_some());
    if !valid_scope {
        return Err(invalid_request());
    }
    match request.operation.as_str() {
        "set" => {
            let mut server = request.server.clone().ok_or_else(invalid_request)?;
            // The client may send a stale hash from an edited draft; identity is
            // always derived from the definition actually being written.
            server.refresh_hash();
            plan_set(&request, &server, &content, project_path)
        }
        "remove" => {
            let name = request.name.as_deref().ok_or_else(invalid_request)?;
            plan_remove(&request, name, &content, project_path)
        }
        _ => Err(invalid_request()),
    }
}

fn plan_set(
    request: &WriteRequest,
    server: &McpServer,
    content: &str,
    project_path: Option<&str>,
) -> Result<Value, CoreError> {
    // Configuration maps and tables can hold only one value per key, while the
    // host sends entries as a list. Reject duplicates instead of hashing one
    // shape and writing another, which would lose ownership after a refresh.
    // Only the active transport's entries are written, so only they can collide.
    let entries = match server.transport {
        super::McpTransport::Stdio => &server.env,
        super::McpTransport::Http | super::McpTransport::Sse => &server.headers,
    };
    if has_duplicate_keys(entries) {
        return Err(invalid_request());
    }
    let existing = existing_servers(request, content, project_path)?;
    let previous = request
        .previous_name
        .as_deref()
        .filter(|name| *name != server.name);
    let original = find_server(&existing, previous.unwrap_or(&server.name));
    if expected_hash_conflicts(request, original) {
        return Ok(unchanged(content, "conflict", Some("externallyModified")));
    }
    let explicitly_authorized = request.expected_hash.is_some();
    for name in [previous, Some(server.name.as_str())].into_iter().flatten() {
        if find_server(&existing, name).is_none()
            && entry_exists(request, content, project_path, name)?
        {
            // Incomplete entries have no parsed ownership proof but still hold
            // user data, including when the original lost its command or URL.
            return Ok(unchanged(
                content,
                "conflict",
                Some(unparsed_entry_conflict(&request.owned, name)),
            ));
        }
    }
    if let Some(current) = find_server(&existing, &server.name) {
        // An original-entry precondition must not authorize replacing a different
        // destination, even when its modeled definition already matches.
        // A no-op set returns hashes the host records, so it needs ownership
        // too; otherwise registration would silently adopt external changes.
        let requires_ownership = previous.is_some() || !explicitly_authorized;
        if requires_ownership {
            if let Some(conflict) = ownership_conflict(&request.owned, current) {
                return Ok(unchanged(content, "conflict", Some(conflict)));
            }
        }
        if previous.is_none() && current.definition_hash == server.definition_hash {
            return Ok(with_hashes(unchanged(content, "unchanged", None), current));
        }
    }
    if let Some(current) = previous.and_then(|name| find_server(&existing, name)) {
        if !explicitly_authorized {
            if let Some(conflict) = ownership_conflict(&request.owned, current) {
                return Ok(unchanged(content, "conflict", Some(conflict)));
            }
        }
    }
    let action = if find_server(&existing, &server.name).is_some()
        || previous.is_some_and(|name| find_server(&existing, name).is_some())
    {
        "updated"
    } else {
        "inserted"
    };
    let next = match request.source.as_str() {
        "claude" => write_claude(content, project_path, &server.name, server, previous)?,
        "codex" => write_codex(content, server, previous)?,
        _ => return Err(invalid_request()),
    };
    // Unknown fields survive edits, so hash the actual output rather than the
    // normalized draft supplied by the host.
    let written = existing_servers(request, &next, project_path)?;
    let written = find_server(&written, &server.name).ok_or_else(invalid_request)?;
    Ok(with_hashes(
        json!({
            "content": next,
            "changed": next != content,
            "action": action,
            "conflict": Value::Null,
        }),
        written,
    ))
}

fn plan_remove(
    request: &WriteRequest,
    name: &str,
    content: &str,
    project_path: Option<&str>,
) -> Result<Value, CoreError> {
    let existing = existing_servers(request, content, project_path)?;
    let current = find_server(&existing, name);
    if expected_hash_conflicts(request, current) {
        return Ok(unchanged(content, "conflict", Some("externallyModified")));
    }
    let Some(current) = current else {
        if entry_exists(request, content, project_path, name)? {
            return Ok(unchanged(
                content,
                "conflict",
                Some(unparsed_entry_conflict(&request.owned, name)),
            ));
        }
        return Ok(json!({
            "content": content,
            "changed": false,
            "action": "absent",
            "conflict": Value::Null,
        }));
    };
    if request.expected_hash.is_none() {
        if let Some(conflict) = ownership_conflict(&request.owned, current) {
            return Ok(unchanged(content, "conflict", Some(conflict)));
        }
    }
    let next = match request.source.as_str() {
        "claude" => remove_claude(content, project_path, name)?,
        "codex" => remove_codex(content, name)?,
        _ => return Err(invalid_request()),
    };
    // The parsed entry must also be removable from the document text. An
    // inline-table root or an unsupported layout can parse but not delete;
    // reporting `removed` while returning identical content would make the
    // ledger forget an entry that still exists.
    if next == content {
        return Ok(with_hashes(unchanged(content, "absent", None), current));
    }
    Ok(json!({
        "content": next,
        "changed": true,
        "action": "removed",
        "conflict": Value::Null,
    }))
}

fn existing_servers(
    request: &WriteRequest,
    content: &str,
    project_path: Option<&str>,
) -> Result<Vec<McpServer>, CoreError> {
    match request.source.as_str() {
        "claude" => parse_claude_servers(content, project_path),
        "codex" => parse_codex_servers(content),
        _ => Err(invalid_request()),
    }
}

/// An existing raw entry omitted from discovery cannot prove ownership.
fn unparsed_entry_conflict(owned: &[OwnedEntry], name: &str) -> &'static str {
    if owned.iter().any(|entry| entry.name == name) {
        "externallyModified"
    } else {
        "ownedByUser"
    }
}

/// Discovery omits entries without a usable transport, but they still occupy
/// their source key and cannot be overwritten by an unrelated rename.
fn entry_exists(
    request: &WriteRequest,
    content: &str,
    project_path: Option<&str>,
    name: &str,
) -> Result<bool, CoreError> {
    // Missing and whitespace-only files contain no entry; the writer creates
    // their first container rather than parsing them as existing JSON.
    if content.trim().is_empty() {
        return Ok(false);
    }
    match request.source.as_str() {
        "claude" => {
            let document = JsonDocument::parse(content)?;
            let path: Vec<&str> = match project_path {
                Some(project) => vec!["projects", project, "mcpServers"],
                None => vec!["mcpServers"],
            };
            let Some(object) = document.object_at(&path)? else {
                return Ok(false);
            };
            Ok(document.member_value(object, name)?.is_some())
        }
        "codex" => {
            let document: toml::Value = toml::from_str(content).map_err(|_| invalid_request())?;
            Ok(document
                .get("mcp_servers")
                .and_then(|entries| entries.get(name))
                .is_some())
        }
        _ => Err(invalid_request()),
    }
}

/// A supplied precondition is mandatory even when a newer ledger owns the entry.
fn expected_hash_conflicts(request: &WriteRequest, current: Option<&McpServer>) -> bool {
    request.expected_hash.as_deref().is_some_and(|expected| {
        current.and_then(|server| server.source_hash.as_deref()) != Some(expected)
    })
}

fn is_owned(owned: &[OwnedEntry], current: &McpServer) -> bool {
    owned.iter().any(|entry| {
        entry.name == current.name
            && entry.definition_hash == current.definition_hash
            && entry.source_hash.is_some()
            && entry.source_hash == current.source_hash
    })
}

fn with_hashes(mut response: Value, current: &McpServer) -> Value {
    response["definitionHash"] = json!(current.definition_hash);
    response["sourceHash"] = json!(current.source_hash);
    response
}

/// Entries become a JSON object or TOML table, which cannot repeat a key.
fn has_duplicate_keys(entries: &[McpKeyValue]) -> bool {
    let mut keys: Vec<&str> = entries.iter().map(|entry| entry.key.as_str()).collect();
    keys.sort_unstable();
    keys.windows(2).any(|pair| pair[0] == pair[1])
}

/// Returns why `current` cannot be replaced, or `None` when Lithe owns it.
fn ownership_conflict(owned: &[OwnedEntry], current: &McpServer) -> Option<&'static str> {
    if is_owned(owned, current) {
        return None;
    }
    // A ledger entry with this name but a different hash means Lithe wrote an
    // older definition that changed outside Lithe, which is a different
    // situation from an entry Lithe never wrote.
    if owned.iter().any(|entry| entry.name == current.name) {
        Some("externallyModified")
    } else {
        Some("ownedByUser")
    }
}

fn unchanged(content: &str, action: &str, conflict: Option<&str>) -> Value {
    json!({
        "content": content,
        "changed": false,
        "action": action,
        "conflict": conflict,
    })
}

fn write_claude(
    content: &str,
    project_path: Option<&str>,
    name: &str,
    server: &McpServer,
    previous: Option<&str>,
) -> Result<String, CoreError> {
    let base = if content.trim().is_empty() {
        "{}"
    } else {
        content
    };
    let mut document = JsonDocument::parse(base)?;
    let path: Vec<&str> = match project_path {
        Some(project) => vec!["projects", project, "mcpServers"],
        None => vec!["mcpServers"],
    };
    let object = document.ensure_object(&path)?;
    // A rename starts from the existing entry so Claude-specific fields Lithe
    // does not model move with the server; modeled keys are overwritten. If a
    // target with the new name already exists, its own fields take precedence,
    // matching the Codex path.
    let base = match document.member_value(object, name)? {
        Some(target) => Some(target),
        None => match previous {
            Some(previous) => document.member_value(object, previous)?,
            None => None,
        },
    };
    let value = match base {
        Some(existing) => merge_claude_value(&existing, server)?,
        None => server_value(server),
    };
    let value = serde_json::to_string(&value).map_err(|_| invalid_request())?;
    document.set_member(object, name, &value)?;
    document.into_string()
}

fn remove_claude(
    content: &str,
    project_path: Option<&str>,
    name: &str,
) -> Result<String, CoreError> {
    let mut document = JsonDocument::parse(content)?;
    let path: Vec<&str> = match project_path {
        Some(project) => vec!["projects", project, "mcpServers"],
        None => vec!["mcpServers"],
    };
    // Removal never creates missing containers; the caller already established
    // that the entry exists in this exact path.
    let Some(object) = document.object_at(&path)? else {
        return Ok(content.to_string());
    };
    document.remove_member(object, name)?;
    document.into_string()
}

fn write_codex(
    content: &str,
    server: &McpServer,
    previous: Option<&str>,
) -> Result<String, CoreError> {
    let mut document = toml_edit::document(content)?;
    toml_edit::set_server(&mut document, server, previous)?;
    Ok(document.to_string())
}

fn remove_codex(content: &str, name: &str) -> Result<String, CoreError> {
    let mut document = toml_edit::document(content)?;
    toml_edit::remove_server(&mut document, name);
    Ok(document.to_string())
}

/// Converts a normalized definition into the JSON entry Claude Code reads.
/// Hashes are Lithe bookkeeping values and are never written.
fn server_value(server: &McpServer) -> Value {
    let mut object = Map::new();
    apply_claude_value(&mut object, server);
    Value::Object(object)
}

/// Copies modeled fields onto an existing entry, keeping keys Lithe does not
/// understand so a rename does not erase Claude-specific options.
fn merge_claude_value(existing: &str, server: &McpServer) -> Result<Value, CoreError> {
    let mut object = serde_json::from_str::<Value>(existing)
        .map_err(|_| invalid_request())?
        .as_object()
        .cloned()
        .ok_or_else(invalid_request)?;
    apply_claude_value(&mut object, server);
    Ok(Value::Object(object))
}

fn apply_claude_value(object: &mut Map<String, Value>, server: &McpServer) {
    match server.transport {
        super::McpTransport::Stdio => {
            object.remove("url");
            object.remove("headers");
            object.remove("type");
            match &server.command {
                Some(command) => {
                    object.insert("command".into(), Value::String(command.clone()));
                }
                None => {
                    object.remove("command");
                }
            }
            if server.args.is_empty() {
                object.remove("args");
            } else {
                object.insert("args".into(), json!(server.args));
            }
            apply_entries_value(object, "env", &server.env);
        }
        super::McpTransport::Http | super::McpTransport::Sse => {
            object.remove("command");
            object.remove("args");
            object.remove("env");
            object.insert(
                "type".into(),
                Value::String(server.transport.as_str().into()),
            );
            match &server.url {
                Some(url) => {
                    object.insert("url".into(), Value::String(url.clone()));
                }
                None => {
                    object.remove("url");
                }
            }
            apply_entries_value(object, "headers", &server.headers);
        }
    }
}

/// Applies modeled env or header entries while keeping values Lithe could not
/// represent. Parsing filters non-string values out of the library model, so
/// replacing the whole object would delete configuration the user never saw.
fn apply_entries_value(object: &mut Map<String, Value>, key: &str, entries: &[McpKeyValue]) {
    match object.get(key).and_then(Value::as_object).cloned() {
        Some(mut existing) => {
            existing.retain(|name, value| {
                !value.is_string() || entries.iter().any(|entry| entry.key == *name)
            });
            for entry in entries {
                existing.insert(entry.key.clone(), Value::String(entry.value.clone()));
            }
            if existing.is_empty() {
                object.remove(key);
            } else {
                object.insert(key.to_string(), Value::Object(existing));
            }
        }
        None => {
            if !entries.is_empty() {
                object.insert(key.to_string(), entries_value(entries));
            }
        }
    }
}

fn entries_value(entries: &[super::McpKeyValue]) -> Value {
    let mut object = Map::new();
    for entry in entries {
        object.insert(entry.key.clone(), Value::String(entry.value.clone()));
    }
    Value::Object(object)
}
