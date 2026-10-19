//! Comment-preserving Codex TOML edits for `[mcp_servers.<name>]` tables.
//!
//! Codex keeps models, providers, profiles and project trust in the same file,
//! so edits must leave unrelated tables, comments and ordering untouched.
//! `toml_edit` owns the document model and formatting; this module only maps one
//! normalized server definition onto a table and back.
//!
//! Codex supports settings Lithe does not model (`bearer_token_env_var`,
//! `startup_timeout_sec`, `tool_timeout_sec`, ...). Replacing the table would
//! silently drop them, so updates edit only the keys Lithe owns and leave every
//! other key and comment in place.

use super::model::{McpKeyValue, McpServer, McpTransport};
use crate::protocol::{CoreError, ErrorCode};
use toml_edit::{value, Array, DocumentMut, InlineTable, Item, Key, Table, Value};

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

/// Sets or updates `[mcp_servers.<name>]` and returns the new file text.
///
/// `previous` is set when the host renames an entry: the old table is moved to
/// the new name before modeled keys are applied, so Codex-specific fields and
/// comments survive. The host still issues its remove step for the old name;
/// it becomes a no-op once the rename has moved the table.
pub(crate) fn set_server(
    document: &mut DocumentMut,
    server: &McpServer,
    previous: Option<&str>,
) -> Result<()> {
    if server.transport == McpTransport::Sse {
        // Codex has no server-sent-events transport; the host refuses to write
        // such servers instead of silently converting them to HTTP.
        return Err(edit_error());
    }
    let servers = document
        .entry("mcp_servers")
        .or_insert_with(|| Item::Table(Table::new()));
    match servers {
        Item::Table(servers) => set_table_server(servers, server, previous),
        Item::Value(Value::InlineTable(servers)) => set_inline_server(servers, server, previous),
        _ => Err(edit_error()),
    }
}

/// Applies a server to the usual `[mcp_servers.<name>]` table layout.
fn set_table_server(servers: &mut Table, server: &McpServer, previous: Option<&str>) -> Result<()> {
    // When a target with the new name already exists, keep that table: the
    // user is merging into it, and its own unmodeled fields take precedence.
    if let Some(previous) = previous.filter(|name| *name != server.name) {
        if servers.get(server.name.as_str()).is_none() {
            if let Some((key, item)) = servers.remove_entry(previous) {
                // Reuse the key decorations so comments attached to the old
                // header move with the table.
                let renamed = Key::new(server.name.as_str())
                    .with_leaf_decor(key.leaf_decor().clone())
                    .with_dotted_decor(key.dotted_decor().clone());
                servers.insert_formatted(&renamed, item);
            }
        }
    }
    let item = servers
        .entry(server.name.as_str())
        .or_insert_with(|| Item::Table(Table::new()));
    match item {
        Item::Table(table) => {
            apply_table(table, server);
            Ok(())
        }
        Item::Value(Value::InlineTable(table)) => {
            apply_inline_table(table, server);
            Ok(())
        }
        _ => Err(edit_error()),
    }
}

/// Applies a server when `mcp_servers` itself is an inline table.
///
/// Inline tables cannot hold comments, so a rename simply moves the existing
/// value to the new key before modeled fields are applied.
fn set_inline_server(
    servers: &mut InlineTable,
    server: &McpServer,
    previous: Option<&str>,
) -> Result<()> {
    if let Some(previous) = previous.filter(|name| *name != server.name) {
        if servers.get(server.name.as_str()).is_none() {
            if let Some(item) = servers.remove(previous) {
                servers.insert(server.name.as_str(), item);
            }
        }
    }
    if servers.get(server.name.as_str()).is_none() {
        servers.insert(server.name.as_str(), Value::InlineTable(InlineTable::new()));
    }
    match servers.get_mut(server.name.as_str()) {
        Some(Value::InlineTable(table)) => {
            apply_inline_table(table, server);
            Ok(())
        }
        _ => Err(edit_error()),
    }
}

/// Removes `[mcp_servers.<name>]`, returning whether it existed.
///
/// Codex accepts both a table section and an inline table for `mcp_servers`;
/// both parse into the library, so both must be removable.
pub(crate) fn remove_server(document: &mut DocumentMut, name: &str) -> bool {
    match document.get_mut("mcp_servers") {
        Some(Item::Table(servers)) => servers.remove(name).is_some(),
        Some(Item::Value(Value::InlineTable(servers))) => servers.remove(name).is_some(),
        _ => false,
    }
}

/// Updates only the keys Lithe models; Codex-specific settings survive.
fn apply_table(table: &mut Table, server: &McpServer) {
    match server.transport {
        McpTransport::Stdio => {
            table.remove("url");
            table.remove("http_headers");
            set_string(table, "command", server.command.as_deref());
            set_args(table, &server.args);
            set_entries(table, "env", &server.env);
        }
        McpTransport::Http => {
            table.remove("command");
            table.remove("args");
            table.remove("env");
            set_string(table, "url", server.url.as_deref());
            set_entries(table, "http_headers", &server.headers);
        }
        McpTransport::Sse => {}
    }
}

fn apply_inline_table(table: &mut InlineTable, server: &McpServer) {
    match server.transport {
        McpTransport::Stdio => {
            table.remove("url");
            table.remove("http_headers");
            set_inline_string(table, "command", server.command.as_deref());
            set_inline_args(table, &server.args);
            set_inline_entries(table, "env", &server.env);
        }
        McpTransport::Http => {
            table.remove("command");
            table.remove("args");
            table.remove("env");
            set_inline_string(table, "url", server.url.as_deref());
            set_inline_entries(table, "http_headers", &server.headers);
        }
        McpTransport::Sse => {}
    }
}

fn set_string(table: &mut Table, key: &str, text: Option<&str>) {
    match text {
        Some(text) => {
            set_table_value(table, key, Value::from(text.to_string()));
        }
        None => {
            table.remove(key);
        }
    }
}

fn set_args(table: &mut Table, args: &[String]) {
    // Rebuilding an identical array would discard comments between its
    // elements. When only another field changed, leave the array untouched.
    if array_matches(table.get("args").and_then(Item::as_value), args) {
        return;
    }
    if args.is_empty() {
        table.remove("args");
        return;
    }
    let mut array = Array::new();
    for argument in args {
        array.push(argument.as_str());
    }
    set_table_value(table, "args", Value::Array(array));
}

fn array_matches(existing: Option<&Value>, args: &[String]) -> bool {
    let Some(array) = existing.and_then(Value::as_array) else {
        return false;
    };
    array.len() == args.len()
        && array
            .iter()
            .zip(args)
            .all(|(value, argument)| value.as_str() == Some(argument.as_str()))
}

/// Replaces a value while keeping the decor attached to it.
///
/// Decor carries the comment before a key and the inline comment after a
/// value. Replacing the whole entry would drop both, so only the value itself
/// is swapped when the key already exists.
fn set_table_value(table: &mut Table, key: &str, new_value: Value) {
    match table.get_mut(key) {
        Some(item) => {
            let decor = item.as_value().map(|value| value.decor().clone());
            let mut new_value = new_value;
            if let Some(decor) = decor {
                *new_value.decor_mut() = decor;
            }
            *item = Item::Value(new_value);
        }
        None => {
            table.insert(key, Item::Value(new_value));
        }
    }
}

/// Writes `env` or `http_headers`, preserving entries Lithe cannot represent.
///
/// Keys Lithe parses and shows are replaced as a set, so removing an entry in
/// the UI removes it here. Non-string values are not part of the normalized
/// model and stay untouched instead of being silently deleted.
fn set_entries(table: &mut Table, key: &str, entries: &[McpKeyValue]) {
    match table.get_mut(key) {
        Some(Item::Table(child)) => {
            let removable: Vec<String> = child
                .iter()
                .filter(|(name, item)| {
                    item.as_value().is_some_and(Value::is_str)
                        && !entries.iter().any(|entry| entry.key == *name)
                })
                .map(|(name, _)| name.to_string())
                .collect();
            for stale in removable {
                child.remove(&stale);
            }
            for entry in entries {
                set_table_value(child, entry.key.as_str(), Value::from(entry.value.clone()));
            }
            if child.is_empty() {
                table.remove(key);
            }
        }
        Some(Item::Value(Value::InlineTable(child))) => {
            let removable: Vec<String> = child
                .iter()
                .filter(|(name, value)| {
                    value.is_str() && !entries.iter().any(|entry| entry.key == *name)
                })
                .map(|(name, _)| name.to_string())
                .collect();
            for stale in removable {
                child.remove(&stale);
            }
            for entry in entries {
                child.insert(entry.key.as_str(), Value::from(entry.value.clone()));
            }
            if child.is_empty() {
                table.remove(key);
            }
        }
        _ => {
            if !entries.is_empty() {
                table.insert(key, Item::Table(entries_table(entries)));
            }
        }
    }
}

fn entries_table(entries: &[McpKeyValue]) -> Table {
    let mut child = Table::new();
    for entry in entries {
        child[entry.key.as_str()] = value(entry.value.as_str());
    }
    child
}

fn set_inline_string(table: &mut InlineTable, key: &str, text: Option<&str>) {
    match text {
        Some(text) => {
            table.insert(key, Value::from(text.to_string()));
        }
        None => {
            table.remove(key);
        }
    }
}

fn set_inline_args(table: &mut InlineTable, args: &[String]) {
    if array_matches(table.get("args"), args) {
        return;
    }
    if args.is_empty() {
        table.remove("args");
        return;
    }
    let mut array = Array::new();
    for argument in args {
        array.push(argument.as_str());
    }
    table.insert("args", Value::Array(array));
}

/// Inline-table counterpart of [`set_entries`]. Inline tables cannot hold
/// comments, but they can still hold non-string values that Lithe does not
/// model, so those are preserved the same way.
fn set_inline_entries(table: &mut InlineTable, key: &str, entries: &[McpKeyValue]) {
    match table.get_mut(key) {
        Some(Value::InlineTable(child)) => {
            let removable: Vec<String> = child
                .iter()
                .filter(|(name, value)| {
                    value.is_str() && !entries.iter().any(|entry| entry.key == *name)
                })
                .map(|(name, _)| name.to_string())
                .collect();
            for stale in removable {
                child.remove(&stale);
            }
            for entry in entries {
                child.insert(entry.key.as_str(), Value::from(entry.value.clone()));
            }
            if child.is_empty() {
                table.remove(key);
            }
        }
        _ => {
            if !entries.is_empty() {
                let mut child = InlineTable::new();
                for entry in entries {
                    child.insert(entry.key.as_str(), Value::from(entry.value.clone()));
                }
                table.insert(key, Value::InlineTable(child));
            }
        }
    }
}
