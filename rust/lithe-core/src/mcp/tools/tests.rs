//! Per-tool policy and command projections protect native ownership boundaries.
use super::*;

fn request(source: &str, content: &str) -> Value {
    json!({"source":source,"content":content,"server":"docs","tools":["read","write"],"owned":[]})
}

#[test]
fn quoted_command_line_preserves_every_argument_without_shell_execution() {
    let args = vec![
        "",
        "a b",
        "it's quoted",
        "line\nnext",
        "$(touch forbidden)",
        "a;rm -f file",
        "é",
    ];
    let formatted =
        command_line(json!({"action":"format","command":"/fake tools/server","args":args}))
            .unwrap();
    let parsed = command_line(json!({"action":"parse","line":formatted["line"]})).unwrap();
    assert_eq!(parsed["command"], "/fake tools/server");
    assert_eq!(parsed["args"], json!(args));
    assert!(command_line(json!({"action":"parse","line":"npx 'unterminated"})).is_err());
}

#[test]
fn codex_only_removes_own_deny_and_retains_unknown_settings() {
    let content = "# user formatting\n[mcp_servers.docs]\ncommand = 'node'\nargs = ['server']\ncustom = 9\ndisabled_tools = ['write']\n";
    let mut r = request("codex", content);
    let read = tool_policy(r.clone()).unwrap();
    assert_eq!(
        read["tools"][1],
        json!({"name":"write","enabled":false,"editable":false})
    );
    r["tool"] = json!("write");
    r["enabled"] = json!(true);
    assert!(tool_policy(r.clone()).is_err());
    r["tool"] = json!("read");
    r["enabled"] = json!(false);
    let off = tool_policy(r.clone()).unwrap();
    assert!(off["content"].as_str().unwrap().contains("custom = 9"));
    assert!(off["content"]
        .as_str()
        .unwrap()
        .starts_with("# user formatting\n"));
    r["content"] = off["content"].clone();
    r["owned"] = off["owned"].clone();
    r["enabled"] = json!(true);
    let on = tool_policy(r).unwrap();
    let doc: toml::Value = toml::from_str(on["content"].as_str().unwrap()).unwrap();
    assert_eq!(
        doc["mcp_servers"]["docs"]["disabled_tools"]
            .as_array()
            .unwrap()[0]
            .as_str(),
        Some("write")
    );
    assert_eq!(on["tools"][0]["enabled"], true);
}

#[test]
fn claude_exact_and_wildcard_denies_are_not_relaxed() {
    let content = "{\n  \"user\": {\"keep\": [1, 2]},\n  \"permissions\": {\"deny\": [\"Bash(rm *)\", \"mcp__docs__write\"],\"allow\": [\"Read\"]}\n}";
    let mut r = request("claude", content);
    r["tool"] = json!("read");
    r["enabled"] = json!(false);
    let off = tool_policy(r.clone()).unwrap();
    assert!(off["content"]
        .as_str()
        .unwrap()
        .contains("\"user\": {\"keep\": [1, 2]}"));
    r["content"] = off["content"].clone();
    r["owned"] = off["owned"].clone();
    r["enabled"] = json!(true);
    let on = tool_policy(r).unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(on["content"].as_str().unwrap()).unwrap()["permissions"]
            ["deny"],
        json!(["Bash(rm *)", "mcp__docs__write"])
    );
    let mut broad = request(
        "claude",
        r#"{"permissions":{"deny":["mcp__d*__*write", "mcp__docs__read"]}}"#,
    );
    broad["owned"] = json!(["write"]);
    let state = tool_policy(broad).unwrap();
    assert_eq!(state["tools"][1]["editable"], false);
    assert_eq!(state["tools"][1]["enabled"], false);
}

#[test]
fn allow_lists_ambiguous_names_and_malformed_policy_fail_closed() {
    let r = request(
        "codex",
        "[mcp_servers.docs]\ncommand='node'\nenabled_tools=['write']\n",
    );
    assert_eq!(tool_policy(r).unwrap()["tools"][0]["editable"], false);
    let mut r = request("claude", "{}");
    r["tools"] = json!(["read.one", "read_one"]);
    assert!(tool_policy(r).unwrap()["tools"]
        .as_array()
        .unwrap()
        .iter()
        .all(|t| t["editable"] == false));
    for content in [r#"{"permissions":[]}"#, r#"{"permissions":{"deny":[1]}}"#] {
        assert!(tool_policy(request("claude", content)).is_err());
    }
    let mut r = request("claude", "{}");
    r["tool"] = json!("*");
    r["enabled"] = json!(false);
    assert!(tool_policy(r).is_err());
}
