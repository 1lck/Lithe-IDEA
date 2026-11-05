use super::*;

fn fixture() -> Value {
    serde_json::from_str(include_str!(
        "../../../../shared/fixtures/agent/edit-review-v1.json"
    ))
    .expect("edit review fixture is JSON")
}

/// Expands `{repeat, count, suffix?}` text generators used by the shared fixture.
fn expand(value: &Value) -> Value {
    match value {
        Value::Object(object) if object.contains_key("repeat") => {
            let unit = object["repeat"].as_str().expect("repeat text");
            let count = object["count"].as_u64().expect("repeat count") as usize;
            let suffix = object.get("suffix").and_then(Value::as_str).unwrap_or("");
            Value::String(unit.repeat(count) + suffix)
        }
        Value::Object(object) => Value::Object(
            object
                .iter()
                .map(|(key, value)| (key.clone(), expand(value)))
                .collect(),
        ),
        Value::Array(items) => Value::Array(items.iter().map(expand).collect()),
        other => other.clone(),
    }
}

#[test]
fn shared_evidence_fixture_matches_host_annotation() {
    let fixture = fixture();
    assert_eq!(fixture["textLimitScalars"], TEXT_LIMIT_SCALARS);
    assert_eq!(fixture["contentLimit"], CONTENT_LIMIT);
    for case in fixture["evidence"].as_array().expect("evidence cases") {
        let name = case["name"].as_str().unwrap_or_default();
        let mut update = expand(&case["update"]);
        let original = update.clone();
        annotate(&mut update);
        let expected = expand(&case["expected"]);
        if expected.is_null() {
            assert_eq!(update, original, "{name}: update must stay untouched");
        } else {
            assert_eq!(update["_meta"]["lithe"]["diffs"], expected, "{name}");
            // Annotation adds evidence without rewriting the raw ACP fields.
            assert_eq!(update["content"], original["content"], "{name}");
        }
    }
}

#[test]
fn shared_reverse_plan_fixture_matches_planner() {
    let fixture = fixture();
    for case in fixture["reversePlan"].as_array().expect("reverse plan cases") {
        let name = case["name"].as_str().unwrap_or_default();
        let request: ReverseRequest =
            serde_json::from_value(expand(&case["request"])).expect(name);
        let plan = serde_json::to_value(reverse_plan(&request)).expect(name);
        assert_eq!(plan, expand(&case["expected"]), "{name}");
    }
}

#[test]
fn content_beyond_the_entry_limit_marks_every_diff_incomplete() {
    let mut content = vec![json!({"type": "diff", "path": "a.txt", "oldText": "a", "newText": "b"})];
    content.extend((0..CONTENT_LIMIT).map(|_| json!({"type": "content", "content": {"type": "text", "text": "x"}})));
    let diffs = evidence(&json!({"sessionUpdate": "tool_call", "content": content})).expect("diffs");
    assert_eq!(diffs.len(), 1);
    assert!(diffs[0].truncated && !diffs[0].revertible);
}

#[test]
fn existing_lithe_metadata_is_preserved() {
    let mut update = json!({
        "sessionUpdate": "tool_call_update",
        "content": [{"type": "diff", "path": "a.txt", "oldText": "a", "newText": "b"}],
        "_meta": {"lithe": {"claudeDesktop": {"kind": "card"}}, "other": 1}
    });
    annotate(&mut update);
    assert_eq!(update["_meta"]["lithe"]["claudeDesktop"]["kind"], "card");
    assert_eq!(update["_meta"]["other"], 1);
    assert_eq!(update["_meta"]["lithe"]["diffs"][0]["newText"], "b");
}

#[test]
fn canonical_match_maps_multibyte_offsets_back_to_the_original() {
    // A lone CR and multibyte text before the match must not shift the span.
    let request = ReverseRequest {
        diffs: vec![ReverseDiff {
            old_text: Some("旧\n".into()),
            new_text: "新\n".into(),
            operation: None,
            tool_kind: None,
            truncated: false,
        }],
        pending: false,
        missing_evidence: false,
        disk: Some("😀\r前\r\n新\n后".into()),
    };
    assert_eq!(
        reverse_plan(&request),
        ReversePlan::Write { text: "😀\r前\r\n旧\r\n后".into() }
    );
}

#[test]
fn presented_acp_fixture_edits_carry_host_evidence() {
    // The platform event fixture shows presented updates; removing the Host
    // annotation and presenting again must reproduce them exactly.
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../shared/fixtures/agent/acp-events-v1.json"
    ))
    .expect("ACP event fixture is JSON");
    for name in ["fileEdit", "claudeFileCreated", "claudeFileWriteUpdated"] {
        let presented = &fixture["events"][name]["update"];
        let mut raw = presented.clone();
        let meta = raw["_meta"].as_object_mut().expect("annotated metadata");
        meta.remove("lithe");
        if meta.is_empty() {
            raw.as_object_mut().expect("update").remove("_meta");
        }
        annotate(&mut raw);
        assert_eq!(&raw, presented, "{name}");
    }
}
