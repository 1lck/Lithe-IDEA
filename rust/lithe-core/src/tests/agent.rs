use crate::execute_json;
use serde_json::{json, Value};

fn run(command: &str, payload: Value) -> Value {
    let request = json!({ "id": "agent-test", "command": command, "payload": payload });
    serde_json::from_str(&execute_json(&request.to_string())).expect("core response JSON")
}

fn fixture() -> Value {
    serde_json::from_str(include_str!(
        "../../../../shared/fixtures/agent/agent-management-v1.json"
    ))
    .expect("agent management fixture")
}

#[test]
fn fixture_requests_are_accepted_by_the_dispatcher() {
    for name in ["status", "install", "uninstall", "installCli"] {
        let command = fixture()["requests"][name]["command"]
            .as_str()
            .unwrap()
            .to_owned();
        assert!(
            crate::protocol::CoreCommand::parse(&command).is_some(),
            "{command}"
        );
    }
}

#[test]
fn status_reports_every_catalog_agent_in_the_fixture_shape() {
    let data = std::env::temp_dir().join(format!("lithe-core-agent-{}", std::process::id()));
    let response = run("agent.status", json!({ "dataDirectory": data }));
    assert_eq!(response["ok"], true, "{response}");
    let expected = &fixture()["responses"]["status"];
    let agents = response["data"]["agents"].as_array().expect("agents");
    let ids: Vec<&str> = agents
        .iter()
        .filter_map(|agent| agent["id"].as_str())
        .collect();
    assert_eq!(ids, ["codex-acp", "claude-acp"]);
    // Detected values depend on the machine; the keys must match the contract.
    let keys = |value: &Value| {
        let mut keys: Vec<String> = value.as_object().unwrap().keys().cloned().collect();
        keys.sort();
        keys
    };
    assert_eq!(keys(&agents[0]), keys(&expected["agents"][0]));
    assert_eq!(
        keys(&response["data"]["environment"]),
        keys(&expected["environment"])
    );
    assert_eq!(agents[0]["installedVersion"], Value::Null);
}

#[test]
fn invalid_management_requests_fail_with_stable_codes() {
    let data = std::env::temp_dir();
    let unknown = run(
        "agent.install",
        json!({ "dataDirectory": data, "agentId": "unknown" }),
    );
    assert_eq!(unknown["error"]["code"], "invalid_request", "{unknown}");
    let relative = run("agent.status", json!({ "dataDirectory": "relative/path" }));
    assert_eq!(relative["error"]["code"], "invalid_request", "{relative}");
    let no_cli = run(
        "agent.installCli",
        json!({ "dataDirectory": data, "agentId": "unknown" }),
    );
    assert_eq!(no_cli["error"]["code"], "invalid_request", "{no_cli}");
    let missing = run("agent.uninstall", json!({ "dataDirectory": data }));
    assert_eq!(missing["error"]["code"], "invalid_request", "{missing}");
    let removed = run(
        "agent.uninstall",
        json!({ "dataDirectory": data.join("lithe-missing-agents"), "agentId": "codex-acp" }),
    );
    assert_eq!(
        removed["ok"], true,
        "removing a missing install succeeds: {removed}"
    );
}
