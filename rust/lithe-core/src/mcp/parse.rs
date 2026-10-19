//! Bounded parsing of Codex TOML and Claude JSON MCP registrations.
//!
//! Every failure is reported without echoing configuration content: entries can
//! carry API keys and headers, and those values must not reach logs or errors.

use super::model::{McpKeyValue, McpServer, McpTransport};
use super::source_hash::{claude_source_hash, codex_source_hash};
use crate::protocol::{CoreError, ErrorCode};
use serde::Deserialize;
use serde_json::Value;

/// Maximum configuration text accepted from a host, matching other bounded
/// configuration parsers in Core.
pub(crate) const MAX_CONFIGURATION_BYTES: usize = 1024 * 1024;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ParseRequest {
    /// Configuration owner: `codex` or `claude`.
    source: String,
    /// `global` or `project`.
    scope: String,
    /// Raw file text.
    #[serde(default)]
    content: String,
    /// Absolute project path for Claude project-scoped entries.
    #[serde(default)]
    project_path: Option<String>,
}

/// Parses one Agent configuration file and returns its normalized servers.
///
/// The response shape is `{ "servers": [...] }`; server order follows the
/// configuration text. Each entry carries a grouping definition hash and a
/// complete source hash the host can store in its ownership ledger.
pub fn parse_configuration(payload: Value) -> Result<Value, CoreError> {
    let request: ParseRequest = serde_json::from_value(payload).map_err(|_| invalid_request())?;
    if request.content.len() > MAX_CONFIGURATION_BYTES {
        return Err(invalid_request());
    }
    let servers = match (request.source.as_str(), request.scope.as_str()) {
        ("codex", "global" | "project") => parse_codex_servers(&request.content)?,
        ("claude", "global") => parse_claude_servers(&request.content, None)?,
        ("claude", "project") => {
            let path = request
                .project_path
                .as_deref()
                .ok_or_else(invalid_request)?;
            parse_claude_servers(&request.content, Some(path))?
        }
        _ => return Err(invalid_request()),
    };
    Ok(serde_json::json!({ "servers": servers }))
}

fn invalid_request() -> CoreError {
    CoreError::new(
        ErrorCode::InvalidRequest,
        "Invalid MCP configuration request",
    )
}

fn invalid_configuration() -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, "Invalid MCP configuration")
}

/// Reads Claude's `mcpServers` map, optionally inside `projects.<path>`.
pub(crate) fn parse_claude_servers(
    content: &str,
    project_path: Option<&str>,
) -> Result<Vec<McpServer>, CoreError> {
    if content.trim().is_empty() {
        return Ok(Vec::new());
    }
    let root: Value = serde_json::from_str(content).map_err(|_| invalid_configuration())?;
    let base = match project_path {
        Some(path) => root
            .get("projects")
            .and_then(|projects| projects.get(path))
            .unwrap_or(&Value::Null),
        None => &root,
    };
    let Some(entries) = base.get("mcpServers").and_then(Value::as_object) else {
        return Ok(Vec::new());
    };
    let mut servers = Vec::new();
    for (name, entry) in entries {
        let Some(object) = entry.as_object() else {
            continue;
        };
        let command = object.get("command").and_then(Value::as_str);
        let url = object.get("url").and_then(Value::as_str);
        let transport = object
            .get("type")
            .and_then(Value::as_str)
            .and_then(|value| match value {
                "http" => Some(McpTransport::Http),
                "sse" => Some(McpTransport::Sse),
                "stdio" => Some(McpTransport::Stdio),
                _ => None,
            })
            .unwrap_or(if url.is_some() {
                McpTransport::Http
            } else {
                McpTransport::Stdio
            });
        let Some(mut server) = build_server(
            name,
            transport,
            command,
            string_array(object.get("args")),
            key_values(object.get("env")),
            url,
            key_values(object.get("headers")),
        ) else {
            continue;
        };
        server.source_hash = Some(claude_source_hash(name, entry));
        servers.push(server);
    }
    Ok(servers)
}

/// Reads Codex's `[mcp_servers.<name>]` tables.
pub(crate) fn parse_codex_servers(content: &str) -> Result<Vec<McpServer>, CoreError> {
    if content.trim().is_empty() {
        return Ok(Vec::new());
    }
    let root: toml::Value = toml::from_str(content).map_err(|_| invalid_configuration())?;
    let Some(entries) = root.get("mcp_servers").and_then(toml::Value::as_table) else {
        return Ok(Vec::new());
    };
    let mut servers = Vec::new();
    for (name, entry) in entries {
        let Some(table) = entry.as_table() else {
            continue;
        };
        let command = table.get("command").and_then(toml::Value::as_str);
        let url = table.get("url").and_then(toml::Value::as_str);
        let transport = if url.is_some() {
            McpTransport::Http
        } else {
            McpTransport::Stdio
        };
        let Some(mut server) = build_server(
            name,
            transport,
            command,
            toml_string_array(table.get("args")),
            toml_key_values(table.get("env")),
            url,
            toml_key_values(table.get("http_headers")),
        ) else {
            continue;
        };
        server.source_hash = Some(codex_source_hash(name, entry));
        servers.push(server);
    }
    Ok(servers)
}

#[allow(clippy::too_many_arguments)]
fn build_server(
    name: &str,
    transport: McpTransport,
    command: Option<&str>,
    args: Vec<String>,
    env: Vec<McpKeyValue>,
    url: Option<&str>,
    headers: Vec<McpKeyValue>,
) -> Option<McpServer> {
    // An entry with neither a command nor a URL cannot be started or reached;
    // keep it out of the library rather than presenting a broken row.
    if command.is_none() && url.is_none() {
        return None;
    }
    Some(McpServer::new(
        name.to_string(),
        transport,
        command.map(str::to_string),
        args,
        env,
        url.map(str::to_string),
        headers,
    ))
}

fn string_array(value: Option<&Value>) -> Vec<String> {
    value
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default()
}

fn key_values(value: Option<&Value>) -> Vec<McpKeyValue> {
    value
        .and_then(Value::as_object)
        .map(|entries| {
            let mut values: Vec<McpKeyValue> = entries
                .iter()
                .filter_map(|(key, value)| {
                    value.as_str().map(|value| McpKeyValue {
                        key: key.clone(),
                        value: value.to_string(),
                    })
                })
                .collect();
            values.sort_by(|left, right| left.key.cmp(&right.key));
            values
        })
        .unwrap_or_default()
}

fn toml_string_array(value: Option<&toml::Value>) -> Vec<String> {
    value
        .and_then(toml::Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(toml::Value::as_str)
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default()
}

fn toml_key_values(value: Option<&toml::Value>) -> Vec<McpKeyValue> {
    value
        .and_then(toml::Value::as_table)
        .map(|entries| {
            let mut values: Vec<McpKeyValue> = entries
                .iter()
                .filter_map(|(key, value)| {
                    value.as_str().map(|value| McpKeyValue {
                        key: key.clone(),
                        value: value.to_string(),
                    })
                })
                .collect();
            values.sort_by(|left, right| left.key.cmp(&right.key));
            values
        })
        .unwrap_or_default()
}

/// Returns the first definition for `name`, if present.
pub(crate) fn find_server<'a>(servers: &'a [McpServer], name: &str) -> Option<&'a McpServer> {
    servers.iter().find(|server| server.name == name)
}
