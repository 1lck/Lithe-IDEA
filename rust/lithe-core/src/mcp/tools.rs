//! Deterministic command-line editing and native per-tool exclusion planning.
//! Hosts own file snapshots and remember only the exact exclusions they added.

use super::{json_edit::JsonDocument, parse::MAX_CONFIGURATION_BYTES};
use crate::protocol::{CoreError, ErrorCode};
use serde::Deserialize;
use serde_json::{json, Value};

fn invalid() -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, "Invalid MCP tool configuration")
}

/// Parses or formats one terminal-like argv projection without invoking a shell.
pub fn command_line(payload: Value) -> Result<Value, CoreError> {
    let line = if payload["action"] == "format" {
        let command = payload["command"].as_str().ok_or_else(invalid)?;
        let args = strings(payload.get("args"))?;
        if command.is_empty() && args.is_empty() {
            return Ok(json!({"line":""}));
        }
        if command.len() + args.iter().map(String::len).sum::<usize>() > MAX_CONFIGURATION_BYTES {
            return Err(invalid());
        }
        let all = std::iter::once(command).chain(args.iter().map(String::as_str));
        return Ok(json!({"line": shell_words::join(all)}));
    } else if payload["action"] == "parse" {
        payload["line"].as_str().ok_or_else(invalid)?
    } else {
        return Err(invalid());
    };
    if line.len() > MAX_CONFIGURATION_BYTES {
        return Err(invalid());
    }
    let parts = shell_words::split(line).map_err(|_| invalid())?;
    Ok(
        json!({"command": parts.first().cloned().unwrap_or_default(), "args": parts.into_iter().skip(1).collect::<Vec<_>>() }),
    )
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PolicyRequest {
    /// Native owner, `codex` or `claude`.
    source: String,
    /// Current bounded UTF-8 text from the platform snapshot.
    content: String,
    /// Native MCP entry name.
    server: String,
    /// Names reported by this server, never a wildcard expression.
    tools: Vec<String>,
    /// Exclusions previously added by this Lithe library for this native path.
    #[serde(default)]
    owned: Vec<String>,
    /// Optional explicit one-tool mutation; absence reads policy only.
    tool: Option<String>,
    enabled: Option<bool>,
}

/// Returns effective local exclusions and an optional format-preserving edit.
/// External exact/wildcard denies and allow-lists are never relaxed here.
pub fn tool_policy(payload: Value) -> Result<Value, CoreError> {
    let r: PolicyRequest = serde_json::from_value(payload).map_err(|_| invalid())?;
    if r.content.len() > MAX_CONFIGURATION_BYTES
        || r.tools.len() > 1000
        || r.owned.len() > 1000
        || !valid_name(&r.server)
        || r.tools.iter().chain(&r.owned).any(|s| !valid_name(s))
        || r.tool.as_ref().is_some_and(|s| !r.tools.contains(s))
        || r.tool.is_some() != r.enabled.is_some()
    {
        return Err(invalid());
    }
    let (mut denied, allow) = match r.source.as_str() {
        "codex" => {
            let doc: toml::Value = toml::from_str(&r.content).map_err(|_| invalid())?;
            let entry = doc
                .get("mcp_servers")
                .and_then(|v| v.get(&r.server))
                .ok_or_else(invalid)?;
            let list = |key: &str| -> Result<Vec<String>, CoreError> {
                match entry.get(key) {
                    None => Ok(vec![]),
                    Some(v) => v
                        .as_array()
                        .ok_or_else(invalid)?
                        .iter()
                        .map(|s| s.as_str().map(str::to_owned).ok_or_else(invalid))
                        .collect(),
                }
            };
            (
                list("disabled_tools")?,
                if entry.get("enabled_tools").is_some() {
                    Some(list("enabled_tools")?)
                } else {
                    None
                },
            )
        }
        "claude" => {
            let doc: Value = serde_json::from_str(if r.content.is_empty() {
                "{}"
            } else {
                &r.content
            })
            .map_err(|_| invalid())?;
            if !doc.is_object() || doc.get("permissions").is_some_and(|v| !v.is_object()) {
                return Err(invalid());
            }
            (strings(doc.pointer("/permissions/deny"))?, None)
        }
        _ => return Err(invalid()),
    };
    let rule = |tool: &str| -> String {
        if r.source == "claude" {
            format!("mcp__{}__{}", normalize(&r.server), normalize(tool))
        } else {
            tool.to_owned()
        }
    };
    if r.source == "claude"
        && r.tool.as_ref().is_some_and(|tool| {
            r.tools
                .iter()
                .any(|other| other != tool && normalize(other) == normalize(tool))
        })
    {
        return Err(invalid());
    }
    let is_blocked = |tool: &str, list: &[String]| {
        if r.source == "codex" {
            list.iter().any(|s| s == tool)
        } else {
            let exact = rule(tool);
            list.iter()
                .any(|s| wildcard(s, &exact) || s == &format!("mcp__{}", normalize(&r.server)))
        }
    };
    let mut owned = r.owned.clone();
    let mut changed = false;
    if let (Some(tool), Some(enabled)) = (&r.tool, r.enabled) {
        let exact = rule(tool);
        if enabled {
            if allow.as_ref().is_some_and(|a| !a.contains(tool))
                || (is_blocked(tool, &denied) && !owned.contains(tool))
            {
                return Err(CoreError::new(ErrorCode::PermissionDenied, "This tool is restricted outside Lithe. Edit the native Agent policy to enable it."));
            }
            let length = denied.len();
            denied.retain(|s| s != &exact);
            changed = length != denied.len();
            owned.retain(|s| s != tool);
        } else if !is_blocked(tool, &denied) {
            denied.push(exact);
            if !owned.contains(tool) {
                owned.push(tool.clone());
            }
            changed = true;
        }
    }
    let content = if changed {
        if r.source == "codex" {
            let mut doc: toml_edit::DocumentMut = r.content.parse().map_err(|_| invalid())?;
            let entry = doc
                .get_mut("mcp_servers")
                .and_then(|v| v.get_mut(&r.server))
                .and_then(toml_edit::Item::as_table_like_mut)
                .ok_or_else(invalid)?;
            let mut array = toml_edit::Array::new();
            for name in &denied {
                array.push(name.as_str());
            }
            entry.insert("disabled_tools", toml_edit::value(array));
            doc.to_string()
        } else {
            let mut doc = JsonDocument::parse(if r.content.is_empty() {
                "{}"
            } else {
                &r.content
            })?;
            let object = doc.ensure_object(&["permissions"])?;
            doc.set_member(
                object,
                "deny",
                &serde_json::to_string(&denied).map_err(|_| invalid())?,
            )?;
            doc.into_string()?
        }
    } else {
        r.content.clone()
    };
    let tools: Vec<_> = r.tools.iter().map(|tool| {
        let blocked = is_blocked(tool, &denied);
        let outside_allow = allow.as_ref().is_some_and(|a| !a.contains(tool));
        // An owned exact rule does not authorize removing a broader user deny.
        let other_deny = denied.iter().any(|s| s != &rule(tool) && is_blocked(tool, std::slice::from_ref(s)));
        let ambiguous = r.source == "claude" && r.tools.iter().any(|other| other != tool && normalize(other) == normalize(tool));
        json!({"name":tool,"enabled":!blocked && !outside_allow,"editable":!ambiguous && !outside_allow && !other_deny && (!blocked || owned.contains(tool))})
    }).collect();
    let has_restrictions = if r.source == "claude" {
        denied
            .iter()
            .any(|s| s.starts_with("mcp") || s.starts_with('*'))
    } else {
        !denied.is_empty() || allow.is_some()
    };
    Ok(
        json!({"content":content,"changed":changed,"owned":owned,"tools":tools,"hasRestrictions":has_restrictions}),
    )
}

fn strings(value: Option<&Value>) -> Result<Vec<String>, CoreError> {
    match value {
        None => Ok(vec![]),
        Some(v) => v
            .as_array()
            .ok_or_else(invalid)?
            .iter()
            .map(|s| s.as_str().map(str::to_owned).ok_or_else(invalid))
            .collect(),
    }
}

fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 256
        && name
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || "_.-".contains(c))
}

fn normalize(name: &str) -> String {
    name.chars()
        .map(|c| {
            if c.is_ascii_alphanumeric() || "_-".contains(c) {
                c
            } else {
                '_'
            }
        })
        .collect()
}

fn wildcard(pattern: &str, value: &str) -> bool {
    let pattern = pattern
        .split('*')
        .map(regex::escape)
        .collect::<Vec<_>>()
        .join(".*");
    regex::Regex::new(&format!("^{pattern}$")).is_ok_and(|re| re.is_match(value))
}

#[cfg(test)]
mod tests;
