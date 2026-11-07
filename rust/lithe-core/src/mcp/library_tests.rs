//! Shared-fixture regressions for MCP library merging, draft validation and
//! multi-file batch planning (`shared/fixtures/mcp/library-v1.json`).

use super::{batch_plan, library_snapshot, parse_configuration, validate_draft};
use serde_json::{json, Value};

fn fixture() -> Value {
    serde_json::from_str(include_str!(
        "../../../../shared/fixtures/mcp/library-v1.json"
    ))
    .expect("library fixture is JSON")
}

/// Resolves `{{sourceHash:<file>:<name>}}` and `{{definitionHash:...}}`
/// placeholders against what Core parses from the fixture files.
fn resolve(value: &Value, files: &Value) -> Value {
    match value {
        Value::String(text) if text.starts_with("{{") && text.ends_with("}}") => {
            let inner = &text[2..text.len() - 2];
            let (kind, rest) = inner.split_once(':').expect("placeholder kind");
            let (file_id, name) = rest.rsplit_once(':').expect("placeholder file and name");
            let file = files
                .as_object()
                .unwrap()
                .values()
                .find(|file| file["id"] == file_id && file["content"].is_string())
                .expect("placeholder file");
            let mut request = json!({
                "source": file["source"], "scope": file["scope"], "content": file["content"],
            });
            if let Some(path) = file.get("projectPath") {
                request["projectPath"] = path.clone();
            }
            let parsed = parse_configuration(request).expect("fixture file parses");
            parsed["servers"]
                .as_array()
                .unwrap()
                .iter()
                .find(|server| server["name"] == name)
                .and_then(|server| server[kind].as_str())
                .map(|hash| json!(hash))
                .expect("placeholder server")
        }
        Value::Array(items) => Value::Array(items.iter().map(|v| resolve(v, files)).collect()),
        Value::Object(map) => Value::Object(
            map.iter()
                .map(|(key, v)| (key.clone(), resolve(v, files)))
                .collect(),
        ),
        other => other.clone(),
    }
}

/// Builds the request `files` array: fixture files with their ledger slices.
fn library_files(fixture: &Value, keys: &Value, ledger: &Value) -> Value {
    let files = &fixture["files"];
    let ledger = resolve(ledger, files);
    Value::Array(
        keys.as_array()
            .unwrap()
            .iter()
            .map(|key| {
                let mut file = files[key.as_str().unwrap()].clone();
                let id = file["id"].as_str().unwrap().to_string();
                file["owned"] = ledger.get(&id).cloned().unwrap_or_else(|| json!([]));
                file
            })
            .collect(),
    )
}

#[test]
fn snapshot_merges_sources_flags_conflicts_and_orders_naturally() {
    let fixture = fixture();
    let case = &fixture["snapshot"];
    let files = library_files(&fixture, &case["files"], &case["ledger"]);
    let snapshot = library_snapshot(json!({ "files": files })).expect("snapshot");
    let rows = snapshot["rows"].as_array().unwrap();
    let expected = case["expectedRows"].as_array().unwrap();
    assert_eq!(rows.len(), expected.len(), "{snapshot:#}");
    for (row, expected) in rows.iter().zip(expected) {
        assert_eq!(row["definition"]["name"], expected["name"]);
        assert_eq!(
            row["hasDefinitionConflict"], expected["hasDefinitionConflict"],
            "{row:#}"
        );
        assert_eq!(row["projectOnly"], expected["projectOnly"]);
        assert_eq!(
            row["id"],
            json!(format!(
                "{}#{}",
                row["definition"]["name"].as_str().unwrap(),
                row["definition"]["definitionHash"].as_str().unwrap()
            ))
        );
        if let Some(files) = expected["files"].as_array() {
            let sources = row["sources"].as_array().unwrap();
            let ids: Vec<&Value> = sources.iter().map(|source| &source["file"]).collect();
            assert_eq!(ids, files.iter().collect::<Vec<_>>());
            let owned: Vec<&Value> = sources
                .iter()
                .map(|source| &source["ownedByLithe"])
                .collect();
            assert_eq!(
                owned,
                expected["owned"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .collect::<Vec<_>>()
            );
        }
    }
    assert_eq!(snapshot["failures"], json!([]));
}

#[test]
fn snapshot_reports_unparseable_files_without_echoing_content() {
    let fixture = fixture();
    let case = &fixture["snapshot"]["failureFiles"];
    let files = library_files(&fixture, &case["files"], &json!({}));
    let snapshot = library_snapshot(json!({ "files": files })).expect("snapshot");
    let failures = snapshot["failures"].as_array().unwrap();
    let expected = case["expectedFailures"].as_array().unwrap();
    assert_eq!(failures.len(), expected.len());
    for (failure, expected) in failures.iter().zip(expected) {
        assert_eq!(failure["file"], expected["file"]);
        assert_eq!(failure["code"], expected["code"]);
    }
    assert!(!snapshot
        .to_string()
        .contains("fixture-secret-should-not-echo"));
    assert_eq!(
        snapshot["rows"].as_array().unwrap().len(),
        case["expectedRowCount"].as_u64().unwrap() as usize
    );
}

#[test]
fn snapshot_rejects_duplicate_file_identities() {
    let fixture = fixture();
    let files = library_files(
        &fixture,
        &json!(["codexGlobal", "codexMissing"]),
        &json!({}),
    );
    assert!(library_snapshot(json!({ "files": files })).is_err());
}

#[test]
fn draft_validation_matches_fixture_issues() {
    let fixture = fixture();
    for case in fixture["validateDraft"].as_array().unwrap() {
        let result = validate_draft(json!({ "draft": case["draft"] })).expect("validate");
        assert_eq!(result["issues"], case["issues"], "{}", case["case"]);
        match case.get("definition") {
            Some(expected) => {
                let definition = &result["definition"];
                assert_eq!(definition["name"], expected["name"], "{}", case["case"]);
                assert_eq!(definition["command"], expected["command"]);
                assert_eq!(definition["args"], expected["args"]);
                let keys: Vec<&Value> = definition["env"]
                    .as_array()
                    .unwrap()
                    .iter()
                    .map(|entry| &entry["key"])
                    .collect();
                assert_eq!(
                    keys,
                    expected["envKeys"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .collect::<Vec<_>>()
                );
                assert_eq!(definition["url"], Value::Null);
                assert_eq!(definition["headers"], json!([]));
            }
            None if case["issues"] != json!([]) => {
                assert_eq!(result["definition"], Value::Null, "{}", case["case"]);
            }
            None => {}
        }
        // Issues are codes only: no draft value may leak into the response.
        if case["issues"] != json!([]) {
            assert!(
                !result.to_string().contains("placeholder"),
                "{}",
                case["case"]
            );
        }
    }
}

#[test]
fn batch_plans_match_fixture_outcomes() {
    let fixture = fixture();
    for case in fixture["batchPlan"].as_array().unwrap() {
        let name = case["case"].as_str().unwrap();
        let files = library_files(&fixture, &case["files"], &case["ledger"]);
        let intent = resolve(&case["intent"], &fixture["files"]);
        let result = batch_plan(json!({ "files": files, "intent": intent })).expect(name);
        let expect = &case["expect"];
        assert_eq!(result["status"], expect["status"], "{name}: {result:#}");
        match expect["status"].as_str().unwrap() {
            "rejected" => assert_eq!(result["rejection"], expect["rejection"], "{name}"),
            "invalid" => assert_eq!(result["issues"], expect["issues"], "{name}"),
            _ => {
                let changes = result["changes"].as_array().unwrap();
                let expected = expect["changes"].as_array().unwrap();
                assert_eq!(changes.len(), expected.len(), "{name}: {result:#}");
                for (change, expected) in changes.iter().zip(expected) {
                    assert_eq!(change["file"], expected["file"], "{name}");
                    assert_eq!(change["changed"], expected["changed"], "{name}");
                    let content = change["content"].as_str().unwrap_or("");
                    for needle in expected["contentContains"].as_array().into_iter().flatten() {
                        assert!(
                            content.contains(needle.as_str().unwrap()),
                            "{name}: {content}"
                        );
                    }
                    for needle in expected["contentExcludes"].as_array().into_iter().flatten() {
                        assert!(
                            !content.contains(needle.as_str().unwrap()),
                            "{name}: {content}"
                        );
                    }
                    if !expected["changed"].as_bool().unwrap() {
                        assert_eq!(change["content"], Value::Null, "{name}");
                    }
                    let owned: Vec<&Value> = change["owned"]
                        .as_array()
                        .unwrap()
                        .iter()
                        .map(|entry| &entry["name"])
                        .collect();
                    assert_eq!(
                        owned,
                        expected["ownedNames"]
                            .as_array()
                            .unwrap()
                            .iter()
                            .collect::<Vec<_>>(),
                        "{name}"
                    );
                    if let Some(renames) = expected.get("renames") {
                        assert_eq!(&change["renames"], renames, "{name}");
                    }
                }
            }
        }
    }
}

#[test]
fn batch_owned_entries_record_the_written_hashes() {
    // The ledger must describe the bytes that reached the file, so a refresh
    // after the write recognizes the entry as Lithe-owned.
    let fixture = fixture();
    let files = library_files(&fixture, &json!(["codexMissing"]), &json!({}));
    let result = batch_plan(json!({ "files": files, "intent": {
        "kind": "setAgent", "agent": "codex", "enabled": true,
        "definition": {"name": "fresh", "transport": "stdio", "command": "fresh-mcp",
            "args": [], "env": [], "url": null, "headers": [], "definitionHash": "stale"},
    }}))
    .expect("plan");
    let change = &result["changes"][0];
    let content = change["content"].as_str().unwrap();
    let mut file = fixture["files"]["codexMissing"].clone();
    file["content"] = json!(content);
    file["owned"] = change["owned"].clone();
    let snapshot = library_snapshot(json!({ "files": [file] })).expect("snapshot");
    assert_eq!(
        snapshot["rows"][0]["sources"][0]["ownedByLithe"],
        json!(true)
    );
    assert_ne!(change["owned"][0]["definitionHash"], json!("stale"));
}

#[test]
fn removal_retains_codex_tool_filters_without_ownership() {
    let content = "[mcp_servers.docs]\ncommand = \"npx\"\ndisabled_tools = [\"write\"]\n";
    let parsed = parse_configuration(json!({
        "source": "codex", "scope": "global", "content": content,
    }))
    .unwrap();
    let server = &parsed["servers"][0];
    let file = json!({
        "id": "codex|global|", "source": "codex", "scope": "global",
        "path": "/fixture/home/.codex/config.toml", "content": content,
        "owned": [{"name": "docs", "definitionHash": server["definitionHash"],
            "sourceHash": server["sourceHash"]}],
    });
    let result = batch_plan(json!({ "files": [file], "intent": {
        "kind": "delete", "name": "docs", "files": ["codex|global|"],
    }}))
    .unwrap();
    let owned = &result["changes"][0]["owned"];
    assert_eq!(
        owned,
        &json!([{"name": "docs", "definitionHash": server["definitionHash"],
            "toolFilters": {"/fixture/home/.codex/config.toml": {"disabledTools": ["write"]}}}])
    );
}
