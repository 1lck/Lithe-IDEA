//! Plans one MCP configuration write and enforces the host's ownership ledger.
//!
//! A server entry is only replaced or removed when the ledger says Lithe wrote
//! the definition that is currently on disk. Same-name entries created by the
//! user or edited outside Lithe are reported as conflicts instead of being
//! overwritten, because another tool is the source of truth for them.

use super::json_edit::JsonDocument;
use super::parse::{
    find_server, parse_claude_servers, parse_codex_servers, MAX_CONFIGURATION_BYTES,
};
use super::toml_edit;
use super::McpServer;
use crate::protocol::{CoreError, ErrorCode};
use serde::Deserialize;
use serde_json::{json, Map, Value};

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct OwnedEntry {
    /// Entry name recorded when Lithe wrote it.
    name: String,
    /// Definition hash recorded at write time.
    definition_hash: String,
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
/// ledger; in both cases `content` is the unchanged input.
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
    let existing = existing_servers(request, content, project_path)?;
    if let Some(current) = find_server(&existing, &server.name) {
        if current.definition_hash == server.definition_hash {
            return Ok(unchanged(content, "unchanged", None));
        }
        if !is_owned(&request.owned, current) {
            // A ledger entry with this name but a different hash means Lithe
            // wrote an older definition that changed outside Lithe, which is a
            // different situation from an entry Lithe never wrote.
            let conflict = if request.owned.iter().any(|entry| entry.name == current.name) {
                "externallyModified"
            } else {
                "ownedByUser"
            };
            return Ok(unchanged(content, "conflict", Some(conflict)));
        }
    }
    let action = if find_server(&existing, &server.name).is_some() {
        "updated"
    } else {
        "inserted"
    };
    let next = match request.source.as_str() {
        "claude" => write_claude(content, project_path, &server.name, &server_value(server))?,
        "codex" => write_codex(content, server)?,
        _ => return Err(invalid_request()),
    };
    Ok(json!({
        "content": next,
        "changed": next != content,
        "action": action,
        "conflict": Value::Null,
        "definitionHash": server.definition_hash,
    }))
}

fn plan_remove(
    request: &WriteRequest,
    name: &str,
    content: &str,
    project_path: Option<&str>,
) -> Result<Value, CoreError> {
    let existing = existing_servers(request, content, project_path)?;
    let Some(current) = find_server(&existing, name) else {
        return Ok(json!({
            "content": content,
            "changed": false,
            "action": "absent",
            "conflict": Value::Null,
        }));
    };
    let owned = request.owned.iter().any(|entry| entry.name == name);
    if !owned {
        return Ok(unchanged(content, "conflict", Some("ownedByUser")));
    }
    if !is_owned(&request.owned, current) {
        return Ok(unchanged(content, "conflict", Some("externallyModified")));
    }
    let next = match request.source.as_str() {
        "claude" => remove_claude(content, project_path, name)?,
        "codex" => remove_codex(content, name)?,
        _ => return Err(invalid_request()),
    };
    Ok(json!({
        "content": next,
        "changed": next != content,
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

fn is_owned(owned: &[OwnedEntry], current: &McpServer) -> bool {
    owned
        .iter()
        .any(|entry| entry.name == current.name && entry.definition_hash == current.definition_hash)
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
    value: &Value,
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
    let value = serde_json::to_string(value).map_err(|_| invalid_request())?;
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

fn write_codex(content: &str, server: &McpServer) -> Result<String, CoreError> {
    let mut document = toml_edit::document(content)?;
    toml_edit::set_server(&mut document, server)?;
    Ok(document.to_string())
}

fn remove_codex(content: &str, name: &str) -> Result<String, CoreError> {
    let mut document = toml_edit::document(content)?;
    toml_edit::remove_server(&mut document, name);
    Ok(document.to_string())
}

/// Converts a normalized definition into the JSON entry Claude Code reads.
/// `definitionHash` is a Lithe bookkeeping value and is never written.
fn server_value(server: &McpServer) -> Value {
    let mut object = Map::new();
    match server.transport {
        super::McpTransport::Stdio => {
            if let Some(command) = &server.command {
                object.insert("command".into(), Value::String(command.clone()));
            }
            if !server.args.is_empty() {
                object.insert("args".into(), json!(server.args));
            }
            if !server.env.is_empty() {
                object.insert("env".into(), entries_value(&server.env));
            }
        }
        super::McpTransport::Http | super::McpTransport::Sse => {
            object.insert(
                "type".into(),
                Value::String(server.transport.as_str().into()),
            );
            if let Some(url) = &server.url {
                object.insert("url".into(), Value::String(url.clone()));
            }
            if !server.headers.is_empty() {
                object.insert("headers".into(), entries_value(&server.headers));
            }
        }
    }
    Value::Object(object)
}

fn entries_value(entries: &[super::McpKeyValue]) -> Value {
    let mut object = Map::new();
    for entry in entries {
        object.insert(entry.key.clone(), Value::String(entry.value.clone()));
    }
    Value::Object(object)
}
