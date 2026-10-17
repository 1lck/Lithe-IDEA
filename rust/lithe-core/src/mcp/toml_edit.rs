//! Comment-preserving Codex TOML edits for `[mcp_servers.<name>]` tables.
//!
//! Codex keeps models, providers, profiles and project trust in the same file,
//! so edits must leave unrelated tables, comments and ordering untouched.
//! `toml_edit` owns the document model and formatting; this module only maps one
//! normalized server definition onto a table and back.

use super::model::{McpKeyValue, McpServer, McpTransport};
use crate::protocol::{CoreError, ErrorCode};
use toml_edit::{value, Array, DocumentMut, Item, Table};

type Result<T> = std::result::Result<T, CoreError>;

fn edit_error() -> CoreError {
    CoreError::new(
        ErrorCode::InvalidRequest,
        "MCP configuration is not editable TOML",
    )
}

/// Parses a Codex configuration document; empty input starts a new document.
pub(crate) fn document(content: &str) -> Result<DocumentMut> {
    if content.trim().is_empty() {
        return Ok(DocumentMut::new());
    }
    content.parse::<DocumentMut>().map_err(|_| edit_error())
}

/// Sets or replaces `[mcp_servers.<name>]` and returns the new file text.
pub(crate) fn set_server(document: &mut DocumentMut, server: &McpServer) -> Result<()> {
    let mut table = Table::new();
    match server.transport {
        McpTransport::Stdio => {
            if let Some(command) = &server.command {
                table["command"] = value(command.as_str());
            }
            if !server.args.is_empty() {
                let mut args = Array::new();
                for argument in &server.args {
                    args.push(argument.as_str());
                }
                table["args"] = value(args);
            }
            insert_entries(&mut table, "env", &server.env);
        }
        McpTransport::Http => {
            if let Some(url) = &server.url {
                table["url"] = value(url.as_str());
            }
            insert_entries(&mut table, "http_headers", &server.headers);
        }
        // Codex has no server-sent-events transport; the host refuses to write
        // such servers instead of silently converting them to HTTP.
        McpTransport::Sse => return Err(edit_error()),
    }
    let servers = document
        .entry("mcp_servers")
        .or_insert(Item::Table(Table::new()));
    let Some(servers) = servers.as_table_mut() else {
        return Err(edit_error());
    };
    servers[server.name.as_str()] = Item::Table(table);
    Ok(())
}

/// Removes `[mcp_servers.<name>]`, returning whether it existed.
pub(crate) fn remove_server(document: &mut DocumentMut, name: &str) -> bool {
    document
        .get_mut("mcp_servers")
        .and_then(Item::as_table_mut)
        .and_then(|servers| servers.remove(name))
        .is_some()
}

fn insert_entries(table: &mut Table, key: &str, entries: &[McpKeyValue]) {
    if entries.is_empty() {
        return;
    }
    let mut child = Table::new();
    for entry in entries {
        child[entry.key.as_str()] = value(entry.value.as_str());
    }
    table[key] = Item::Table(child);
}
