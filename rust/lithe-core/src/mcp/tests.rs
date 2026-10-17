//! Regression tests for MCP parsing, format preservation and ownership rules.

use super::{parse_configuration, plan_write};
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
    let hash = server_hash(&parsed, "a");
    let result = plan(json!({
        "source": "claude",
        "scope": "global",
        "content": content,
        "operation": "remove",
        "name": "a",
        "owned": [{"name": "a", "definitionHash": hash}]
    }));
    let next = result["content"].as_str().unwrap();
    let parsed: Value = serde_json::from_str(next).unwrap();
    assert!(parsed["mcpServers"].get("a").is_none());
    assert_eq!(parsed["mcpServers"]["b"]["command"], "b");
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
    let hash = server_hash(&parsed, "server");
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
        "owned": [{"name": "server", "definitionHash": hash}]
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
    let hash = server_hash(&parsed, "lithe");
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
        "owned": [{"name": "lithe", "definitionHash": hash}]
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
    let hash = server_hash(&parsed, "lithe");
    let result = plan(json!({
        "source": "claude",
        "scope": "global",
        "content": content,
        "operation": "set",
        "server": parsed["servers"][0],
        "owned": [{"name": "lithe", "definitionHash": hash}]
    }));
    assert_eq!(result["action"], "unchanged");
    assert_eq!(result["changed"], false);
}
