//! Regression tests for MCP parsing, format preservation and ownership rules.

use super::{parse_configuration, plan_write};
use crate::protocol::ErrorCode;
use serde_json::{json, Value};

fn parse(source: &str, scope: &str, content: &str, project: Option<&str>) -> Value {
    let mut request = json!({
        "source": source,
        "scope": scope,
        "content": content,
    });
    if let Some(project) = project {
        request["projectPath"] = json!(project);
    }
    parse_configuration(request).expect("configuration should parse")
}

fn server_hash(parsed: &Value, name: &str) -> String {
    parsed["servers"]
        .as_array()
        .expect("servers array")
        .iter()
        .find(|server| server["name"] == name)
        .and_then(|server| server["definitionHash"].as_str())
        .expect("definition hash")
        .to_string()
}

fn source_hash(parsed: &Value, name: &str) -> String {
    parsed["servers"]
        .as_array()
        .expect("servers array")
        .iter()
        .find(|server| server["name"] == name)
        .and_then(|server| server["sourceHash"].as_str())
        .expect("source hash")
        .to_string()
}

fn owned_entry(parsed: &Value, name: &str) -> Value {
    json!({
        "name": name,
        "definitionHash": server_hash(parsed, name),
        "sourceHash": source_hash(parsed, name),
    })
}

fn plan(request: Value) -> Value {
    plan_write(request).expect("write plan should succeed")
}

#[test]
fn parses_claude_stdio_and_http_servers() {
    let content = r#"{
      "mcpServers": {
        "dbx": {
          "command": "/Users/test/.dbx/bin/dbx-mcp",
          "args": ["--stdio"],
          "env": {"DBX_TOKEN": "secret"}
        },
        "notion": {
          "type": "http",
          "url": "https://example.test/mcp",
          "headers": {"Authorization": "Bearer secret"}
        }
      }
    }"#;
    let parsed = parse("claude", "global", content, None);
    let servers = parsed["servers"].as_array().unwrap();
    assert_eq!(servers.len(), 2);
    let dbx = servers
        .iter()
        .find(|server| server["name"] == "dbx")
        .unwrap();
    assert_eq!(dbx["transport"], "stdio");
    assert_eq!(dbx["env"][0]["key"], "DBX_TOKEN");
    let notion = servers
        .iter()
        .find(|server| server["name"] == "notion")
        .unwrap();
    assert_eq!(notion["transport"], "http");
    assert_eq!(notion["headers"][0]["key"], "Authorization");
}

#[test]
fn parses_only_the_requested_claude_project() {
    let content = r#"{
      "mcpServers": {"global": {"command": "global-cmd"}},
      "projects": {
        "/work/a": {"mcpServers": {"a-server": {"command": "a-cmd"}}},
        "/work/b": {"mcpServers": {"b-server": {"command": "b-cmd"}}}
      }
    }"#;
    let parsed = parse("claude", "project", content, Some("/work/a"));
    let servers = parsed["servers"].as_array().unwrap();
    assert_eq!(servers.len(), 1);
    assert_eq!(servers[0]["name"], "a-server");
}

#[test]
fn parses_codex_tables_and_ignores_unrelated_keys() {
    let content = r#"
model = "gpt"
[model_providers.custom]
base_url = "https://example.test"

[mcp_servers.node_repl]
command = "npx"
args = ["-y", "node-repl"]
startup_timeout_sec = 20

[mcp_servers.node_repl.env]
NODE_OPTIONS = "--max-old-space-size=512"

[mcp_servers.remote]
url = "https://example.test/mcp"
bearer_token_env_var = "REMOTE_TOKEN"
http_headers = { X-Client = "lithe" }
"#;
    let parsed = parse("codex", "global", content, None);
    let servers = parsed["servers"].as_array().unwrap();
    assert_eq!(servers.len(), 2);
    let remote = servers
        .iter()
        .find(|server| server["name"] == "remote")
        .unwrap();
    assert_eq!(remote["transport"], "http");
    assert_eq!(remote["headers"][0]["key"], "X-Client");
}

#[test]
fn rejects_invalid_configuration_without_echoing_content() {
    let error = parse_configuration(json!({
        "source": "claude",
        "scope": "global",
        "content": "{\"mcpServers\": {broken",
    }))
    .unwrap_err();
    assert!(!error.message.contains("broken"));
}

#[test]
fn inserts_json_entry_and_preserves_unrelated_formatting() {
    let content = "{\n  \"theme\": \"dark\",\n  \"mcpServers\": {\n    \"dbx\": {\n      \"command\": \"dbx-mcp\"\n    }\n  }\n}\n";
    let server = json!({
        "name": "lithe",
        "transport": "stdio",
        "command": "/Applications/Lithe.app/Contents/Helpers/lithe-mcp",
        "args": ["--connection", "/tmp/connection.json"],
        "env": [],
        "headers": []
    });
    let result = plan(json!({
        "source": "claude",
        "scope": "global",
        "content": content,
        "operation": "set",
        "server": server,
        "owned": []
    }));
    let next = result["content"].as_str().unwrap();
    assert_eq!(result["action"], "inserted");
    assert!(next.contains("\"theme\": \"dark\""));
    assert!(next.contains("\"dbx\""));
    let parsed: Value = serde_json::from_str(next).unwrap();
    assert_eq!(
        parsed["mcpServers"]["lithe"]["command"],
        "/Applications/Lithe.app/Contents/Helpers/lithe-mcp"
    );
}

#[test]
fn creates_claude_project_container_when_missing() {
    let result = plan(json!({
        "source": "claude",
        "scope": "project",
        "projectPath": "/work/a",
        "content": "{\n  \"theme\": \"dark\"\n}",
        "operation": "set",
        "server": {
            "name": "lithe",
            "transport": "stdio",
            "command": "lithe-mcp",
            "args": [],
            "env": [],
            "headers": []
        },
        "owned": []
    }));
    let next = result["content"].as_str().unwrap();
    let parsed: Value = serde_json::from_str(next).unwrap();
    assert_eq!(parsed["theme"], "dark");
    assert_eq!(
        parsed["projects"]["/work/a"]["mcpServers"]["lithe"]["command"],
        "lithe-mcp"
    );
}

#[test]
fn removes_only_the_requested_json_entry() {
    let content = "{\n  \"mcpServers\": {\n    \"a\": {\"command\": \"a\"},\n    \"b\": {\"command\": \"b\"}\n  }\n}";
    let parsed = parse("claude", "global", content, None);
    let result = plan(json!({
        "source": "claude",
        "scope": "global",
        "content": content,
        "operation": "remove",
        "name": "a",
        "owned": [owned_entry(&parsed, "a")]
    }));
    let next = result["content"].as_str().unwrap();
    let parsed: Value = serde_json::from_str(next).unwrap();
    assert!(parsed["mcpServers"].get("a").is_none());
    assert_eq!(parsed["mcpServers"]["b"]["command"], "b");
}

fn remove_entry(content: &str, name: &str) -> String {
    let parsed = parse("claude", "global", content, None);
    let result = plan(json!({
        "source": "claude",
        "scope": "global",
        "content": content,
        "operation": "remove",
        "name": name,
        "owned": [owned_entry(&parsed, &name)]
    }));
    let next = result["content"].as_str().unwrap().to_string();
    // Every plan must stay valid for Claude Code to read.
    serde_json::from_str::<Value>(&next).expect("removal must keep valid JSON");
    next
}

#[test]
fn removing_the_last_json_entry_also_removes_its_comma() {
    let content = "{\n  \"mcpServers\": {\n    \"a\": {\"command\": \"a\"},\n    \"b\": {\"command\": \"b\"}\n  }\n}";
    let next = remove_entry(content, "b");
    let parsed: Value = serde_json::from_str(&next).unwrap();
    assert_eq!(parsed["mcpServers"]["a"]["command"], "a");
    assert!(parsed["mcpServers"].get("b").is_none());
    assert!(!next.contains(",\n  }"));
}

#[test]
fn removing_a_middle_json_entry_keeps_neighbours_valid() {
    let content = "{\n  \"mcpServers\": {\n    \"a\": {\"command\": \"a\"},\n    \"b\": {\"command\": \"b\"},\n    \"c\": {\"command\": \"c\"}\n  }\n}";
    let next = remove_entry(content, "b");
    let parsed: Value = serde_json::from_str(&next).unwrap();
    assert_eq!(parsed["mcpServers"]["a"]["command"], "a");
    assert_eq!(parsed["mcpServers"]["c"]["command"], "c");
    assert!(parsed["mcpServers"].get("b").is_none());
}

#[test]
fn removing_a_shared_line_entry_keeps_the_previous_entry() {
    // `a` and `b` share a line while `c` starts the next one. Deleting from
    // the line start would silently drop `a`, which is still valid JSON and
    // therefore invisible to output validation.
    let content = "{\n  \"mcpServers\": {\n    \"a\": {\"command\": \"a\"}, \"b\": {\"command\": \"b\"},\n    \"c\": {\"command\": \"c\"}\n  }\n}";
    let next = remove_entry(content, "b");
    let parsed: Value = serde_json::from_str(&next).unwrap();
    assert_eq!(parsed["mcpServers"]["a"]["command"], "a");
    assert_eq!(parsed["mcpServers"]["c"]["command"], "c");
    assert!(parsed["mcpServers"].get("b").is_none());
    assert_eq!(parsed["mcpServers"].as_object().unwrap().len(), 2);
}

#[test]
fn removing_entries_handles_single_line_and_mixed_layouts() {
    let single_line =
        "{\"mcpServers\": {\"a\": {\"command\": \"a\"}, \"b\": {\"command\": \"b\"}}}";
    let parsed: Value = serde_json::from_str(&remove_entry(single_line, "b")).unwrap();
    assert_eq!(parsed["mcpServers"]["a"]["command"], "a");
    assert!(parsed["mcpServers"].get("b").is_none());

    let mixed = "{\n  \"mcpServers\": {\n    \"a\": {\"command\": \"a\"}, \"b\": {\"command\": \"b\"}\n  }\n}";
    let parsed: Value = serde_json::from_str(&remove_entry(mixed, "b")).unwrap();
    assert_eq!(parsed["mcpServers"]["a"]["command"], "a");
    assert!(parsed["mcpServers"].get("b").is_none());

    let multiline_value = "{\n  \"mcpServers\": {\n    \"a\": {\"command\": \"a\"},\n    \"b\": {\n      \"command\": \"b\"\n    }\n  }\n}";
    let parsed: Value = serde_json::from_str(&remove_entry(multiline_value, "b")).unwrap();
    assert_eq!(parsed["mcpServers"]["a"]["command"], "a");
    assert!(parsed["mcpServers"].get("b").is_none());
}

#[test]
fn removing_a_multiline_entry_keeps_the_next_entry_on_its_closing_line() {
    // `b` spans several lines and `c` starts right after b's closing brace on
    // the same line. Trimming to a line boundary would cut into `c`.
    let content = "{\n  \"mcpServers\": {\n    \"a\": {\"command\": \"a\"},\n    \"b\": {\n      \"command\": \"b\"\n    }, \"c\": {\"command\": \"c\"}\n  }\n}";
    let next = remove_entry(content, "b");
    let parsed: Value = serde_json::from_str(&next).unwrap();
    assert_eq!(parsed["mcpServers"]["a"]["command"], "a");
    assert_eq!(parsed["mcpServers"]["c"]["command"], "c");
    assert!(parsed["mcpServers"].get("b").is_none());
    assert_eq!(parsed["mcpServers"].as_object().unwrap().len(), 2);
}

#[test]
fn toml_edits_preserve_comments_and_unrelated_tables() {
    let content =
        "# keep this comment\nmodel = \"gpt\"\n\n[mcp_servers.dbx]\ncommand = \"dbx-mcp\"\n";
    let result = plan(json!({
        "source": "codex",
        "scope": "global",
        "content": content,
        "operation": "set",
        "server": {
            "name": "lithe",
            "transport": "stdio",
            "command": "/Applications/Lithe.app/Contents/Helpers/lithe-mcp",
            "args": ["--connection", "/tmp/connection.json"],
            "env": [],
            "headers": []
        },
        "owned": []
    }));
    let next = result["content"].as_str().unwrap();
    assert!(next.contains("# keep this comment"));
    assert!(next.contains("[mcp_servers.dbx]"));
    assert!(next.contains("[mcp_servers.lithe]"));
    let parsed: toml::Value = toml::from_str(next).unwrap();
    assert_eq!(
        parsed["mcp_servers"]["lithe"]["command"].as_str(),
        Some("/Applications/Lithe.app/Contents/Helpers/lithe-mcp")
    );
}

/// Plans an update of an existing Codex entry, using the ledger hash of the
/// complete parsed entry as the host would.
fn update_codex(content: &str, server: Value) -> String {
    let name = server["name"].as_str().expect("server name").to_string();
    let parsed = parse("codex", "global", content, None);
    let result = plan(json!({
        "source": "codex",
        "scope": "global",
        "content": content,
        "operation": "set",
        "server": server,
        "owned": [owned_entry(&parsed, &name)]
    }));
    result["content"].as_str().unwrap().to_string()
}

#[test]
fn toml_http_updates_keep_codex_specific_fields() {
    let content = r#"
[mcp_servers.remote]
url = "https://old.example/mcp"
bearer_token_env_var = "REMOTE_TOKEN"
startup_timeout_sec = 20
http_headers = { X-Client = "lithe" }
"#;
    let next = update_codex(
        content,
        json!({
            "name": "remote",
            "transport": "http",
            "args": [],
            "env": [],
            "url": "https://new.example/mcp",
            "headers": [{"key": "X-Client", "value": "lithe"}]
        }),
    );
    assert!(next.contains("bearer_token_env_var = \"REMOTE_TOKEN\""));
    assert!(next.contains("startup_timeout_sec = 20"));
    assert!(next.contains("https://new.example/mcp"));
    let parsed: toml::Value = toml::from_str(&next).unwrap();
    assert_eq!(
        parsed["mcp_servers"]["remote"]["bearer_token_env_var"].as_str(),
        Some("REMOTE_TOKEN")
    );
}

#[test]
fn toml_stdio_updates_keep_unknown_keys_comments_and_unmodelled_entries() {
    let content = r#"
[mcp_servers.local]
command = "old"
# Codex throttles startup with this.
startup_timeout_sec = 30
API_ENV = "LOCAL_TOKEN"

[mcp_servers.local.env]
TOKEN = "old"
COUNT = 3
"#;
    let next = update_codex(
        content,
        json!({
            "name": "local",
            "transport": "stdio",
            "command": "new",
            "args": ["--flag"],
            "env": [{"key": "TOKEN", "value": "new"}],
            "headers": []
        }),
    );
    assert!(next.contains("command = \"new\""));
    assert!(next.contains("# Codex throttles startup with this."));
    assert!(next.contains("API_ENV = \"LOCAL_TOKEN\""));
    let parsed: toml::Value = toml::from_str(&next).unwrap();
    let table = &parsed["mcp_servers"]["local"];
    assert_eq!(table["startup_timeout_sec"].as_integer(), Some(30));
    assert_eq!(table["env"]["TOKEN"].as_str(), Some("new"));
    // Non-string entries are not part of the normalized model and survive.
    assert_eq!(table["env"]["COUNT"].as_integer(), Some(3));
}

#[test]
fn toml_clearing_modeled_entries_keeps_non_string_env_values() {
    let content = r#"
[mcp_servers.local]
command = "old"

[mcp_servers.local.env]
TOKEN = "x"
COUNT = 3
"#;
    let next = update_codex(
        content,
        json!({
            "name": "local",
            "transport": "stdio",
            "command": "new",
            "args": [],
            "env": [],
            "headers": []
        }),
    );
    let parsed: toml::Value = toml::from_str(&next).unwrap();
    let env = parsed["mcp_servers"]["local"]["env"].as_table().unwrap();
    // The string entry the UI showed is removed; the value Lithe cannot
    // represent is not silently deleted along with it.
    assert!(!env.contains_key("TOKEN"));
    assert_eq!(env["COUNT"].as_integer(), Some(3));
}

#[test]
fn toml_clearing_modeled_entries_keeps_non_string_inline_env_values() {
    let content = r#"
[mcp_servers.local]
command = "old"
env = { TOKEN = "x", COUNT = 3 }
"#;
    let next = update_codex(
        content,
        json!({
            "name": "local",
            "transport": "stdio",
            "command": "new",
            "args": [],
            "env": [],
            "headers": []
        }),
    );
    let parsed: toml::Value = toml::from_str(&next).unwrap();
    let env = parsed["mcp_servers"]["local"]["env"].as_table().unwrap();
    assert!(!env.contains_key("TOKEN"));
    assert_eq!(env["COUNT"].as_integer(), Some(3));
}

#[test]
fn toml_updates_keep_comments_on_modeled_keys_and_values() {
    let content = r#"
[mcp_servers.local]
# Starts the local helper.
command = "old" # trailing command note
args = ["--old"] # args note

[mcp_servers.local.env]
# Token note
TOKEN = "old" # value note
"#;
    let next = update_codex(
        content,
        json!({
            "name": "local",
            "transport": "stdio",
            "command": "new",
            "args": ["--new"],
            "env": [{"key": "TOKEN", "value": "new"}],
            "headers": []
        }),
    );
    for comment in [
        "# Starts the local helper.",
        "# trailing command note",
        "# args note",
        "# Token note",
        "# value note",
    ] {
        assert!(next.contains(comment), "missing {comment} in {next}");
    }
    let parsed: toml::Value = toml::from_str(&next).unwrap();
    let table = &parsed["mcp_servers"]["local"];
    assert_eq!(table["command"].as_str(), Some("new"));
    assert_eq!(table["env"]["TOKEN"].as_str(), Some("new"));
}

#[test]
fn transport_identity_ignores_entries_the_transport_does_not_write() {
    let http_with_env = parse(
        "claude",
        "global",
        r#"{"mcpServers": {"remote": {"type": "http", "url": "https://example.test/mcp", "env": {"STRAY": "1"}}}}"#,
        None,
    );
    let http_plain = parse(
        "claude",
        "global",
        r#"{"mcpServers": {"remote": {"type": "http", "url": "https://example.test/mcp"}}}"#,
        None,
    );
    assert_eq!(
        server_hash(&http_with_env, "remote"),
        server_hash(&http_plain, "remote")
    );

    let stdio_with_headers = parse(
        "claude",
        "global",
        r#"{"mcpServers": {"local": {"command": "/bin/echo", "headers": {"STRAY": "1"}}}}"#,
        None,
    );
    let stdio_plain = parse(
        "claude",
        "global",
        r#"{"mcpServers": {"local": {"command": "/bin/echo"}}}"#,
        None,
    );
    assert_eq!(
        server_hash(&stdio_with_headers, "local"),
        server_hash(&stdio_plain, "local")
    );

    let http_with_command = parse(
        "claude",
        "global",
        r#"{"mcpServers": {"remote": {"type": "http", "url": "https://example.test/mcp", "command": "/bin/echo", "args": ["--stray"]}}}"#,
        None,
    );
    assert_eq!(
        server_hash(&http_with_command, "remote"),
        server_hash(&http_plain, "remote")
    );

    let stdio_with_url = parse(
        "claude",
        "global",
        r#"{"mcpServers": {"local": {"type": "stdio", "command": "/bin/echo", "url": "https://example.test/stray"}}}"#,
        None,
    );
    assert_eq!(
        server_hash(&stdio_with_url, "local"),
        server_hash(&stdio_plain, "local")
    );

    // The write path drops env, command and args from an HTTP entry, so the
    // planned hash must equal the hash of the file it writes.
    let result = plan(json!({
        "source": "codex",
        "scope": "global",
        "content": "",
        "operation": "set",
        "server": {
            "name": "remote",
            "transport": "http",
            "command": "stray",
            "args": ["--stray"],
            "env": [{"key": "STRAY", "value": "1"}],
            "url": "https://example.test/mcp",
            "headers": []
        },
        "owned": []
    }));
    let written = parse("codex", "global", result["content"].as_str().unwrap(), None);
    assert_eq!(
        result["definitionHash"].as_str().unwrap(),
        server_hash(&written, "remote")
    );
}

#[test]
fn refuses_to_edit_a_json_object_with_duplicate_keys() {
    // serde_json keeps the last duplicate while the offset editor finds the
    // first; accepting the edit would update a definition the Agent ignores.
    let content = r#"{"mcpServers": {"a": {"command": "first"}, "a": {"command": "second"}}}"#;
    let parsed = parse("claude", "global", content, None);
    let error = plan_write(json!({
        "source": "claude",
        "scope": "global",
        "content": content,
        "operation": "remove",
        "name": "a",
        "owned": [owned_entry(&parsed, "a")]
    }))
    .unwrap_err();
    assert!(matches!(error.code, ErrorCode::InvalidRequest));
    assert!(error.message.contains("duplicate"));
}

#[test]
fn codex_updates_entries_in_an_inline_mcp_servers_table() {
    let content = r#"mcp_servers = { local = { command = "old" } }"#;
    let parsed = parse("codex", "global", content, None);
    let result = plan(json!({
        "source": "codex",
        "scope": "global",
        "content": content,
        "operation": "set",
        "server": {
            "name": "local",
            "transport": "stdio",
            "command": "new",
            "args": [],
            "env": [],
            "headers": []
        },
        "owned": [owned_entry(&parsed, "local")]
    }));
    assert_eq!(result["action"], "updated");
    let next = result["content"].as_str().unwrap();
    let parsed: toml::Value = toml::from_str(next).unwrap();
    assert_eq!(
        parsed["mcp_servers"]["local"]["command"].as_str(),
        Some("new")
    );
}

#[test]
fn toml_updates_leave_an_unchanged_args_array_untouched() {
    let content = r#"
[mcp_servers.local]
command = "old"
args = [
  # connection file
  "--connection",
  "/tmp/c.json",
]
"#;
    let next = update_codex(
        content,
        json!({
            "name": "local",
            "transport": "stdio",
            "command": "new",
            "args": ["--connection", "/tmp/c.json"],
            "env": [],
            "headers": []
        }),
    );
    assert!(next.contains("command = \"new\""));
    // Editing another field must not rebuild an identical array, which would
    // drop comments between its elements.
    assert!(next.contains("# connection file"));
}

#[test]
fn codex_removes_entries_from_an_inline_mcp_servers_table() {
    let content = r#"mcp_servers = { lithe = { command = "old" }, other = { command = "keep" } }"#;
    let parsed = parse("codex", "global", content, None);
    let result = plan(json!({
        "source": "codex",
        "scope": "global",
        "content": content,
        "operation": "remove",
        "name": "lithe",
        "owned": [owned_entry(&parsed, "lithe")]
    }));
    assert_eq!(result["action"], "removed");
    assert_eq!(result["changed"], true);
    let next = result["content"].as_str().unwrap();
    let parsed: toml::Value = toml::from_str(next).unwrap();
    assert!(parsed["mcp_servers"].get("lithe").is_none());
    assert_eq!(
        parsed["mcp_servers"]["other"]["command"].as_str(),
        Some("keep")
    );
}

#[test]
fn rejects_duplicate_entry_names_that_a_map_cannot_hold() {
    let error = plan_write(json!({
        "source": "claude",
        "scope": "global",
        "content": "{\"mcpServers\": {}}",
        "operation": "set",
        "server": {
            "name": "duplicates",
            "transport": "stdio",
            "command": "/bin/echo",
            "args": [],
            "env": [
                {"key": "TOKEN", "value": "first"},
                {"key": "TOKEN", "value": "second"}
            ],
            "headers": []
        },
        "owned": []
    }))
    .unwrap_err();
    assert!(matches!(error.code, ErrorCode::InvalidRequest));
}

#[test]
fn toml_transport_change_removes_only_the_keys_lithe_models() {
    let content = r#"
[mcp_servers.switch]
command = "old"
args = ["--stdio"]
env = { TOKEN = "x" }
startup_timeout_sec = 5
"#;
    let next = update_codex(
        content,
        json!({
            "name": "switch",
            "transport": "http",
            "args": [],
            "env": [],
            "url": "https://example.test/mcp",
            "headers": []
        }),
    );
    let parsed: toml::Value = toml::from_str(&next).unwrap();
    let table = parsed["mcp_servers"]["switch"].as_table().unwrap();
    assert!(!table.contains_key("command"));
    assert!(!table.contains_key("args"));
    assert!(!table.contains_key("env"));
    assert_eq!(table["startup_timeout_sec"].as_integer(), Some(5));
    assert_eq!(table["url"].as_str(), Some("https://example.test/mcp"));
}

#[test]
fn codex_rename_preserves_unmodelled_fields() {
    let content = r#"
# Remote MCP server.
[mcp_servers.remote]
url = "https://example.test/mcp"
bearer_token_env_var = "REMOTE_TOKEN"
startup_timeout_sec = 20
"#;
    let parsed = parse("codex", "global", content, None);
    let result = plan(json!({
        "source": "codex",
        "scope": "global",
        "content": content,
        "operation": "set",
        "previousName": "remote",
        "server": {
            "name": "renamed",
            "transport": "http",
            "args": [],
            "env": [],
            "url": "https://example.test/mcp",
            "headers": []
        },
        "owned": [owned_entry(&parsed, "remote")]
    }));
    let next = result["content"].as_str().unwrap();
    let parsed: toml::Value = toml::from_str(next).unwrap();
    // The Codex edit moves the table to its new key, carrying unknown fields
    // and comments with it.
    assert!(parsed["mcp_servers"].get("remote").is_none());
    assert!(next.contains("# Remote MCP server."));
    assert_eq!(
        parsed["mcp_servers"]["renamed"]["bearer_token_env_var"].as_str(),
        Some("REMOTE_TOKEN")
    );
    assert_eq!(
        parsed["mcp_servers"]["renamed"]["startup_timeout_sec"].as_integer(),
        Some(20)
    );
}

#[test]
fn claude_rename_preserves_unmodelled_fields() {
    let content = r#"{"mcpServers": {"remote": {"type": "http", "url": "https://example.test/mcp", "headers": {"X-Client": "lithe"}, "alwaysAllow": ["search"]}}}"#;
    let parsed = parse("claude", "global", content, None);
    let result = plan(json!({
        "source": "claude",
        "scope": "global",
        "content": content,
        "operation": "set",
        "previousName": "remote",
        "server": {
            "name": "renamed",
            "transport": "http",
            "args": [],
            "env": [],
            "url": "https://example.test/mcp",
            "headers": [{"key": "X-Client", "value": "lithe"}]
        },
        "owned": [owned_entry(&parsed, "remote")]
    }));
    let next = result["content"].as_str().unwrap();
    let parsed: Value = serde_json::from_str(next).unwrap();
    assert_eq!(parsed["mcpServers"]["renamed"]["alwaysAllow"][0], "search");
    assert_eq!(
        parsed["mcpServers"]["renamed"]["headers"]["X-Client"],
        "lithe"
    );
    // Claude's edit leaves the old name in place; the host removes it next.
    assert!(parsed["mcpServers"].get("remote").is_some());
}

#[test]
fn claude_clearing_modeled_entries_keeps_non_string_env_values() {
    let content =
        r#"{"mcpServers": {"local": {"command": "old", "env": {"TOKEN": "x", "COUNT": 3}}}}"#;
    let parsed = parse("claude", "global", content, None);
    let result = plan(json!({
        "source": "claude",
        "scope": "global",
        "content": content,
        "operation": "set",
        "server": {
            "name": "local",
            "transport": "stdio",
            "command": "new",
            "args": [],
            "env": [],
            "headers": []
        },
        "owned": [owned_entry(&parsed, "local")]
    }));
    let next = result["content"].as_str().unwrap();
    let parsed: Value = serde_json::from_str(next).unwrap();
    let env = &parsed["mcpServers"]["local"]["env"];
    assert!(env.get("TOKEN").is_none());
    assert_eq!(env["COUNT"], 3);
}

#[test]
fn write_hash_matches_the_reparsed_definition_for_unsorted_entries() {
    let result = plan(json!({
        "source": "claude",
        "scope": "global",
        "content": "{\"mcpServers\": {}}",
        "operation": "set",
        "server": {
            "name": "ordered",
            "transport": "stdio",
            "command": "/bin/echo",
            "args": [],
            "env": [
                {"key": "TOKEN2", "value": "b"},
                {"key": "TOKEN10", "value": "a"}
            ],
            "headers": []
        },
        "owned": []
    }));
    let hash = result["definitionHash"].as_str().unwrap();
    let reparsed = parse(
        "claude",
        "global",
        result["content"].as_str().unwrap(),
        None,
    );
    // The host stores this hash in the ledger; discovery parses the written
    // file and sorts entries, so both paths must agree.
    assert_eq!(server_hash(&reparsed, "ordered"), hash);
    assert_eq!(source_hash(&reparsed, "ordered"), result["sourceHash"]);
}

#[test]
fn refuses_to_overwrite_a_user_owned_entry() {
    let content = "{\"mcpServers\": {\"lithe\": {\"command\": \"user-command\"}}}";
    let result = plan(json!({
        "source": "claude",
        "scope": "global",
        "content": content,
        "operation": "set",
        "server": {
            "name": "lithe",
            "transport": "stdio",
            "command": "lithe-mcp",
            "args": [],
            "env": [],
            "headers": []
        },
        "owned": []
    }));
    assert_eq!(result["conflict"], "ownedByUser");
    assert_eq!(result["changed"], false);
    assert_eq!(result["content"], content);
}

#[test]
fn explicit_expected_hash_allows_replacing_an_unowned_entry() {
    let content = "{\"mcpServers\": {\"server\": {\"command\": \"user-command\"}}}";
    let parsed = parse("claude", "global", content, None);
    let result = plan(json!({
        "source": "claude",
        "scope": "global",
        "content": content,
        "operation": "set",
        "server": {
            "name": "server",
            "transport": "stdio",
            "command": "edited-by-user-in-lithe",
            "args": [],
            "env": [],
            "headers": []
        },
        "expectedHash": source_hash(&parsed, "server"),
        "owned": []
    }));
    assert_eq!(result["action"], "updated");
    assert_eq!(result["conflict"], Value::Null);
    assert!(result["content"]
        .as_str()
        .unwrap()
        .contains("edited-by-user-in-lithe"));
}

#[test]
fn set_detects_external_edits_when_the_ledger_hash_is_stale() {
    let content = "{\"mcpServers\": {\"lithe\": {\"command\": \"edited-outside\"}}}";
    let result = plan(json!({
        "source": "claude",
        "scope": "global",
        "content": content,
        "operation": "set",
        "server": {
            "name": "lithe",
            "transport": "stdio",
            "command": "lithe-mcp",
            "args": [],
            "env": [],
            "headers": []
        },
        "owned": [{"name": "lithe", "definitionHash": "stale-hash"}]
    }));
    assert_eq!(result["conflict"], "externallyModified");
    assert_eq!(result["changed"], false);
}

#[test]
fn updates_an_entry_lithe_wrote() {
    let content = "{\"mcpServers\": {\"lithe\": {\"command\": \"old-command\"}}}";
    let parsed = parse("claude", "global", content, None);
    let result = plan(json!({
        "source": "claude",
        "scope": "global",
        "content": content,
        "operation": "set",
        "server": {
            "name": "lithe",
            "transport": "stdio",
            "command": "new-command",
            "args": [],
            "env": [],
            "headers": []
        },
        "owned": [owned_entry(&parsed, "lithe")]
    }));
    assert_eq!(result["action"], "updated");
    assert!(result["content"].as_str().unwrap().contains("new-command"));
}

#[test]
fn removal_detects_external_edits() {
    let content = "{\"mcpServers\": {\"lithe\": {\"command\": \"edited-by-user\"}}}";
    let result = plan(json!({
        "source": "claude",
        "scope": "global",
        "content": content,
        "operation": "remove",
        "name": "lithe",
        "owned": [{"name": "lithe", "definitionHash": "stale-hash"}]
    }));
    assert_eq!(result["conflict"], "externallyModified");
    assert_eq!(result["changed"], false);
}

#[test]
fn identical_definition_is_a_no_op() {
    let content = "{\"mcpServers\": {\"lithe\": {\"command\": \"lithe-mcp\"}}}";
    let parsed = parse("claude", "global", content, None);
    let result = plan(json!({
        "source": "claude",
        "scope": "global",
        "content": content,
        "operation": "set",
        "server": parsed["servers"][0],
        "owned": [owned_entry(&parsed, "lithe")]
    }));
    assert_eq!(result["action"], "unchanged");
    assert_eq!(result["changed"], false);
}

/// Unknown authentication, timeout and non-string values must all remain part
/// of the deletion/edit guard, even though the library cannot edit them.
fn full_entry_content(source: &str, scope: &str) -> String {
    match source {
        "claude" => {
            let entry = json!({
                "command": "old",
                "bearer_token_env_var": "TOKEN_A",
                "tool_timeout_sec": 20,
                "auth": {"enabled": true, "providers": ["one", "two"]},
                "env": {"COUNT": 3},
            });
            if scope == "project" {
                json!({"projects": {"/work/project": {"mcpServers": {"lithe": entry}}}}).to_string()
            } else {
                json!({"mcpServers": {"lithe": entry}}).to_string()
            }
        }
        "codex" => concat!(
            "[mcp_servers.lithe]\ncommand = \"old\"\n",
            "bearer_token_env_var = \"TOKEN_A\"\ntool_timeout_sec = 20\n",
            "auth = { enabled = true, providers = [\"one\", \"two\"] }\n",
            "env = { COUNT = 3 }\n",
        )
        .to_string(),
        _ => unreachable!(),
    }
}

#[test]
fn unknown_entry_mutations_block_automatic_edit_delete_and_project_cleanup() {
    for source in ["claude", "codex"] {
        for scope in ["global", "project"] {
            let content = full_entry_content(source, scope);
            let original = parse(source, scope, &content, Some("/work/project"));
            let owned = owned_entry(&original, "lithe");
            for (before, after) in [
                ("TOKEN_A", "TOKEN_B"),
                ("20", "21"),
                ("true", "false"),
                ("two", "three"),
                ("3", "4"),
            ] {
                let changed = content.replace(before, after);
                let current = parse(source, scope, &changed, Some("/work/project"));
                assert_eq!(
                    server_hash(&original, "lithe"),
                    server_hash(&current, "lithe")
                );
                assert_ne!(
                    source_hash(&original, "lithe"),
                    source_hash(&current, "lithe")
                );
                for operation in ["set", "remove"] {
                    let mut desired = original["servers"][0].clone();
                    desired["command"] = json!("updated");
                    let result = plan(json!({
                        "source": source,
                        "scope": scope,
                        "projectPath": if scope == "project" { json!("/work/project") } else { Value::Null },
                        "content": changed,
                        "operation": operation,
                        "name": "lithe",
                        "server": desired,
                        "owned": [owned],
                    }));
                    assert_eq!(
                        result["conflict"], "externallyModified",
                        "{source} {scope} {operation} {before}"
                    );
                    assert_eq!(result["content"], changed);
                    assert_eq!(result["changed"], false);
                }
            }
        }
    }
}

#[test]
fn source_hash_ignores_formatting_comments_and_object_key_order() {
    for (source, first, second) in [
        (
            "claude",
            r#"{"mcpServers":{"lithe":{"command":"old","auth":{"a":1,"b":[true,"x"]}}}}"#,
            r#"{ "mcpServers": { "lithe": { "auth": { "b": [true, "x"], "a": 1 }, "command": "old" } } }"#,
        ),
        (
            "codex",
            "[mcp_servers.lithe]\ncommand = 'old'\nauth = { a = 1, b = [true, 'x'] }\n",
            "# comment\n[mcp_servers.lithe]\nauth = { b = [true, \"x\"], a = 1 } # inline\ncommand = \"old\"\n",
        ),
    ] {
        let first = parse(source, "global", first, None);
        let second = parse(source, "global", second, None);
        assert_eq!(source_hash(&first, "lithe"), source_hash(&second, "lithe"));
        assert_eq!(server_hash(&first, "lithe"), server_hash(&second, "lithe"));
    }
}

#[test]
fn source_hash_distinguishes_unknown_toml_value_types() {
    let hash = |value: &str| {
        let content = format!("[mcp_servers.lithe]\ncommand = 'old'\nunknown = {value}\n");
        source_hash(&parse("codex", "global", &content, None), "lithe")
    };
    assert_ne!(hash("1"), hash("1.0"));
    assert_ne!(hash("1979-05-27"), hash("'1979-05-27'"));
    assert_ne!(hash("true"), hash("'true'"));
}

#[test]
fn legacy_ownership_without_source_hash_refuses_automatic_replace_and_remove() {
    for source in ["claude", "codex"] {
        let content = full_entry_content(source, "global");
        let parsed = parse(source, "global", &content, None);
        let mut desired = parsed["servers"][0].clone();
        desired["command"] = json!("updated");
        for operation in ["set", "remove"] {
            let result = plan(json!({
                "source": source,
                "scope": "global",
                "content": content,
                "operation": operation,
                "name": "lithe",
                "server": desired,
                "owned": [{"name": "lithe", "definitionHash": server_hash(&parsed, "lithe")}],
            }));
            assert_eq!(result["conflict"], "externallyModified");
            assert_eq!(result["content"], content);
        }
    }
}

#[test]
fn stale_expected_hash_refuses_latest_ledger_and_unchanged_desired_definition() {
    for source in ["claude", "codex"] {
        let displayed = full_entry_content(source, "global");
        let original = parse(source, "global", &displayed, None);
        let changed = displayed.replace("TOKEN_A", "TOKEN_B");
        let latest = parse(source, "global", &changed, None);
        for operation in ["set", "remove"] {
            for desired_command in ["old", "updated"] {
                let mut desired = latest["servers"][0].clone();
                desired["command"] = json!(desired_command);
                let result = plan(json!({
                    "source": source,
                    "scope": "global",
                    "content": changed,
                    "operation": operation,
                    "name": "lithe",
                    "server": desired,
                    "expectedHash": source_hash(&original, "lithe"),
                    "owned": [owned_entry(&latest, "lithe")],
                }));
                assert_eq!(result["conflict"], "externallyModified");
                assert_eq!(result["action"], "conflict");
                assert_eq!(result["content"], changed);
            }
        }
    }
}

#[test]
fn expected_hash_requires_the_original_entry_to_still_exist() {
    for source in ["claude", "codex"] {
        let content = full_entry_content(source, "global");
        let parsed = parse(source, "global", &content, None);
        for operation in ["set", "remove"] {
            for previous in [Value::Null, json!("lithe")] {
                let mut desired = parsed["servers"][0].clone();
                if !previous.is_null() {
                    desired["name"] = json!("renamed");
                }
                let result = plan(json!({
                    "source": source,
                    "scope": "global",
                    "content": "",
                    "operation": operation,
                    "previousName": previous,
                    "name": "lithe",
                    "server": desired,
                    "expectedHash": source_hash(&parsed, "lithe"),
                    "owned": [owned_entry(&parsed, "lithe")],
                }));
                assert_eq!(result["conflict"], "externallyModified");
                assert_eq!(result["content"], "");
            }
        }
    }
}

#[test]
fn exact_expected_source_hash_authorizes_unowned_edit_and_remove() {
    for source in ["claude", "codex"] {
        let content = full_entry_content(source, "global");
        let parsed = parse(source, "global", &content, None);
        for operation in ["set", "remove"] {
            let mut desired = parsed["servers"][0].clone();
            desired["command"] = json!("updated");
            let result = plan(json!({
                "source": source,
                "scope": "global",
                "content": content,
                "operation": operation,
                "name": "lithe",
                "server": desired,
                "expectedHash": source_hash(&parsed, "lithe"),
                "owned": [],
            }));
            assert_eq!(result["conflict"], Value::Null);
            assert_eq!(result["changed"], true);
            let written = parse(source, "global", result["content"].as_str().unwrap(), None);
            if operation == "set" {
                assert_eq!(result["sourceHash"], source_hash(&written, "lithe"));
                assert_eq!(result["definitionHash"], server_hash(&written, "lithe"));
                assert!(result["content"].as_str().unwrap().contains("TOKEN_A"));
                // The next automatic cleanup must accept the actual output hash,
                // including the unknown fields preserved from the original.
                let removed = plan(json!({
                    "source": source,
                    "scope": "global",
                    "content": result["content"],
                    "operation": "remove",
                    "name": "lithe",
                    "owned": [{"name": "lithe", "definitionHash": result["definitionHash"], "sourceHash": result["sourceHash"]}],
                }));
                assert_eq!(removed["action"], "removed");
            } else {
                assert!(written["servers"].as_array().unwrap().is_empty());
            }
        }
    }
}

#[test]
fn expected_hash_authorizes_only_the_original_of_a_rename() {
    for source in ["claude", "codex"] {
        let content = full_entry_content(source, "global");
        let original = parse(source, "global", &content, None);
        let mut desired = original["servers"][0].clone();
        desired["name"] = json!("renamed");
        let renamed = plan(json!({
            "source": source,
            "scope": "global",
            "content": content,
            "operation": "set",
            "previousName": "lithe",
            "server": desired,
            "expectedHash": source_hash(&original, "lithe"),
            "owned": [],
        }));
        assert_eq!(renamed["action"], "updated");
        assert_eq!(renamed["conflict"], Value::Null);
        let written = parse(source, "global", renamed["content"].as_str().unwrap(), None);
        assert_eq!(renamed["sourceHash"], source_hash(&written, "renamed"));
        // Add an unrelated destination whose modeled definition already equals
        // the rename draft. It must still require its own ownership proof.
        let with_target = if source == "claude" {
            let mut root: Value = serde_json::from_str(&content).unwrap();
            root["mcpServers"]["renamed"] = json!({"command": "old"});
            root.to_string()
        } else {
            format!("{content}\n[mcp_servers.renamed]\ncommand = 'old'\n")
        };
        let target_parsed = parse(source, "global", &with_target, None);
        for owned in [
            json!([]),
            json!([{
                "name": "renamed",
                "definitionHash": server_hash(&target_parsed, "renamed"),
            }]),
        ] {
            let result = plan(json!({
                "source": source,
                "scope": "global",
                "content": with_target,
                "operation": "set",
                "previousName": "lithe",
                "server": desired,
                "expectedHash": source_hash(&original, "lithe"),
                "owned": owned,
            }));
            assert_eq!(result["action"], "conflict");
            assert_eq!(
                result["conflict"],
                if owned.as_array().unwrap().is_empty() {
                    "ownedByUser"
                } else {
                    "externallyModified"
                }
            );
            assert_eq!(result["content"], with_target);
        }
    }
}

#[test]
fn unchanged_set_returns_hashes_of_the_actual_complete_entry() {
    for source in ["claude", "codex"] {
        let content = full_entry_content(source, "global");
        let parsed = parse(source, "global", &content, None);
        let mut desired = parsed["servers"][0].clone();
        desired["sourceHash"] = json!("untrusted-draft-hash");
        let result = plan(json!({
            "source": source,
            "scope": "global",
            "content": content,
            "operation": "set",
            "server": desired,
            "expectedHash": source_hash(&parsed, "lithe"),
            "owned": [],
        }));
        assert_eq!(result["action"], "unchanged");
        assert_eq!(result["content"], content);
        assert_eq!(result["sourceHash"], source_hash(&parsed, "lithe"));
        assert_eq!(result["definitionHash"], server_hash(&parsed, "lithe"));
    }
}

#[test]
fn empty_configurations_still_allow_first_insert_and_absent_removal() {
    for source in ["claude", "codex"] {
        for scope in ["global", "project"] {
            let project = (scope == "project").then_some("/work/project");
            for content in [None, Some(""), Some("\n \t")] {
                let request = json!({
                    "source": source, "scope": scope, "projectPath": project,
                    "content": content, "operation": "set",
                    "server": { "name": "alpha", "transport": "stdio", "command": "mcp" },
                    "owned": [],
                });
                let inserted = plan(request.clone());
                assert_eq!(
                    inserted["action"], "inserted",
                    "{source} {scope} {content:?}"
                );
                let parsed = parse(
                    source,
                    scope,
                    inserted["content"].as_str().unwrap(),
                    project,
                );
                assert_eq!(inserted["sourceHash"], source_hash(&parsed, "alpha"));

                let mut removal = request.clone();
                removal["operation"] = json!("remove");
                removal["name"] = json!("alpha");
                let absent = plan(removal);
                assert_eq!(absent["action"], "absent");
                assert_eq!(absent["content"], content.unwrap_or(""));

                let mut stale = request;
                stale["expectedHash"] = json!("previous-entry-version");
                let conflict = plan(stale);
                assert_eq!(conflict["conflict"], "externallyModified");
                assert_eq!(conflict["content"], content.unwrap_or(""));
            }
        }
    }
}

#[test]
fn automatic_unchanged_set_cannot_adopt_external_or_legacy_entries() {
    for source in ["claude", "codex"] {
        for scope in ["global", "project"] {
            let original_content = full_entry_content(source, scope);
            let original = parse(source, scope, &original_content, Some("/work/project"));
            let content = original_content.replace("20", "21");
            for owned in [
                json!([]),
                json!([owned_entry(&original, "lithe")]),
                json!([{"name": "lithe", "definitionHash": server_hash(&original, "lithe")}]),
            ] {
                let result = plan(json!({
                    "source": source, "scope": scope,
                    "projectPath": if scope == "project" { Some("/work/project") } else { None },
                    "content": content, "operation": "set",
                    "server": original["servers"][0], "owned": owned,
                }));
                assert_eq!(result["action"], "conflict");
                assert_eq!(result["content"], content);
                assert_eq!(result["changed"], false);
                assert_eq!(
                    result["conflict"],
                    if owned.as_array().unwrap().is_empty() {
                        "ownedByUser"
                    } else {
                        "externallyModified"
                    }
                );
            }
        }
    }
}

#[test]
fn externally_removed_transport_fields_cannot_bypass_ownership() {
    for source in ["claude", "codex"] {
        let original_content = full_entry_content(source, "global");
        let original = parse(source, "global", &original_content, None);
        let content = if source == "claude" {
            let mut root: Value = serde_json::from_str(&original_content).unwrap();
            root["mcpServers"]["lithe"]
                .as_object_mut()
                .unwrap()
                .remove("command");
            root.to_string()
        } else {
            original_content.replace("command = \"old\"\n", "")
        };
        assert_eq!(
            parse(source, "global", &content, None)["servers"],
            json!([])
        );
        for operation in ["set", "remove", "rename"] {
            let mut desired = original["servers"][0].clone();
            if operation == "rename" {
                desired["name"] = json!("renamed");
            }
            for owned in [json!([]), json!([owned_entry(&original, "lithe")])] {
                let result = plan(json!({
                    "source": source, "scope": "global", "content": content,
                    "operation": if operation == "remove" { "remove" } else { "set" },
                    "name": "lithe", "server": desired, "owned": owned,
                    "previousName": if operation == "rename" { Some("lithe") } else { None },
                }));
                assert_eq!(result["action"], "conflict");
                assert_eq!(result["content"], content);
                assert_eq!(result["changed"], false);
            }
        }
    }
}

#[test]
fn expected_hash_does_not_authorize_an_incomplete_rename_destination() {
    for source in ["claude", "codex"] {
        let content = full_entry_content(source, "global");
        let original = parse(source, "global", &content, None);
        let mut desired = original["servers"][0].clone();
        desired["name"] = json!("renamed");
        let content = if source == "claude" {
            let mut root: Value = serde_json::from_str(&content).unwrap();
            root["mcpServers"]["renamed"] = json!({"auth": {"enabled": true}});
            root.to_string()
        } else {
            format!("{content}\n[mcp_servers.renamed]\nauth = {{ enabled = true }}\n")
        };
        assert_eq!(
            parse(source, "global", &content, None)["servers"]
                .as_array()
                .unwrap()
                .len(),
            1
        );
        for owned in [
            json!([]),
            json!([{
                "name": "renamed", "definitionHash": "older-definition", "sourceHash": "older-source",
            }]),
        ] {
            let result = plan(json!({
                "source": source,
                "scope": "global",
                "content": content,
                "operation": "set",
                "previousName": "lithe",
                "server": desired,
                "expectedHash": source_hash(&original, "lithe"),
                "owned": owned,
            }));
            assert_eq!(result["action"], "conflict");
            assert_eq!(
                result["conflict"],
                if owned.as_array().unwrap().is_empty() {
                    "ownedByUser"
                } else {
                    "externallyModified"
                }
            );
            assert_eq!(result["content"], content);
        }
    }
}
