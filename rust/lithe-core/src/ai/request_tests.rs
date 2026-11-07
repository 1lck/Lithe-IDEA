//! Shared-fixture tests for pull request descriptions and inline edits.

use super::{
    decode_pull_request, plan_pull_request, Provider, PullRequestComparison, PullRequestOptions,
};
use crate::execute_json;
use serde_json::{json, Value};

fn pull_request_fixture() -> Value {
    serde_json::from_str(include_str!(
        "../../../../shared/fixtures/ai/pull-request-description-v1.json"
    ))
    .unwrap()
}

fn inline_edit_fixture() -> Value {
    serde_json::from_str(include_str!(
        "../../../../shared/fixtures/ai/inline-edit-v1.json"
    ))
    .unwrap()
}

fn typed(fixture: &Value) -> (Provider, PullRequestOptions, PullRequestComparison) {
    (
        serde_json::from_value(fixture["provider"].clone()).unwrap(),
        serde_json::from_value(fixture["options"].clone()).unwrap(),
        serde_json::from_value(fixture["comparison"].clone()).unwrap(),
    )
}

fn prompts(protocol: &str, body: &Value) -> (String, String) {
    match protocol {
        "responses" => (
            body["input"][0]["content"].as_str().unwrap().into(),
            body["input"][1]["content"].as_str().unwrap().into(),
        ),
        "chatCompletions" => (
            body["messages"][0]["content"].as_str().unwrap().into(),
            body["messages"][1]["content"].as_str().unwrap().into(),
        ),
        _ => (
            body["system"].as_str().unwrap().into(),
            body["messages"][0]["content"].as_str().unwrap().into(),
        ),
    }
}

#[test]
fn pull_request_plans_and_decodes_every_protocol_from_the_shared_fixture() {
    let fixture = pull_request_fixture();
    let (mut provider, options, comparison) = typed(&fixture);
    let expected = &fixture["expectedPrompt"];
    for case in fixture["responses"].as_array().unwrap() {
        let protocol = case["protocol"].as_str().unwrap();
        provider.api_protocol = protocol.into();
        let plan = plan_pull_request(&provider, &options, &comparison).unwrap();
        assert_eq!(
            plan.body[case["tokenField"].as_str().unwrap()],
            expected["outputTokens"]
        );
        let (system, user) = prompts(protocol, &plan.body);
        for text in expected["systemContains"].as_array().unwrap() {
            assert!(
                system.contains(text.as_str().unwrap()),
                "{protocol}: {text}"
            );
        }
        for text in expected["userContains"].as_array().unwrap() {
            assert!(user.contains(text.as_str().unwrap()), "{protocol}: {text}");
        }
        for text in expected["userExcludes"].as_array().unwrap() {
            assert!(!user.contains(text.as_str().unwrap()), "{protocol}: {text}");
        }
        let decoded = decode_pull_request(protocol, &case["body"]).unwrap();
        assert_eq!(
            serde_json::to_value(decoded).unwrap(),
            fixture["expectedDescription"]
        );
    }
}

#[test]
fn pull_request_rejections_match_the_shared_fixture() {
    let fixture = pull_request_fixture();
    let (provider, options, mut comparison) = typed(&fixture);
    for case in fixture["planRejections"].as_array().unwrap() {
        comparison.files = serde_json::from_value(case["files"].clone()).unwrap();
        assert_eq!(
            plan_pull_request(&provider, &options, &comparison).err(),
            case["code"].as_str(),
            "{}",
            case["case"]
        );
    }
    for case in fixture["decodeRejections"].as_array().unwrap() {
        assert_eq!(
            decode_pull_request(case["protocol"].as_str().unwrap(), &case["body"]).err(),
            case["code"].as_str(),
            "{}",
            case["case"]
        );
    }
}

#[test]
fn pull_request_evidence_is_budgeted_and_commit_context_is_bounded() {
    let fixture = pull_request_fixture();
    let (provider, mut options, mut comparison) = typed(&fixture);
    options.maximum_diff_characters = 8_000;
    options.format = "custom".into();
    options.custom_template = "  ".into();
    comparison.files[0].diff = "界".repeat(20_000);
    comparison.files[1].diff = "+second".into();
    comparison.commit_messages = (0..300).map(|index| format!("commit {index}")).collect();
    let plan = plan_pull_request(&provider, &options, &comparison).unwrap();
    let (system, user) = prompts("chatCompletions", &plan.body);
    // A blank custom template falls back to the standard sections.
    assert!(system.contains("Summary, Changes, and Testing"));
    assert!(user.contains("[Diff truncated; do not infer omitted changes.]"));
    assert!(user.contains("+second"));
    assert!(user.chars().filter(|c| *c == '界').count() <= 8_000);
    assert!(user.contains("250. commit 249"));
    assert!(!user.contains("251. "));
    assert!(user.contains("[More commit messages omitted.]"));

    comparison.files = (0..1_001)
        .map(|index| super::CommitFile {
            path: format!("f{index}"),
            change_kind: "modified".into(),
            diff: "+x".into(),
            original_characters: None,
        })
        .collect();
    assert_eq!(
        plan_pull_request(&provider, &options, &comparison).err(),
        Some("AI_COMMIT_TOO_MANY_FILES")
    );
}

#[test]
fn pull_request_json_commands_never_echo_evidence() {
    let fixture = pull_request_fixture();
    let response: Value = serde_json::from_str(&execute_json(
        &json!({"id":"plan","command":"ai.pullRequest.plan","payload":{
            "provider": fixture["provider"], "options": fixture["options"], "comparison": fixture["comparison"]
        }})
        .to_string(),
    ))
    .unwrap();
    assert_eq!(response["ok"], true, "{response}");
    assert_eq!(
        response["data"]["url"],
        "https://api.example.com/v1/chat/completions"
    );
    let decoded: Value = serde_json::from_str(&execute_json(
        &json!({"id":"decode","command":"ai.pullRequest.decode","payload":{
            "protocol": "chatCompletions", "response": fixture["responses"][1]["body"]
        }})
        .to_string(),
    ))
    .unwrap();
    assert_eq!(decoded["data"], fixture["expectedDescription"]);
    let rejected = execute_json(
        &json!({"id":"bad","command":"ai.pullRequest.decode","payload":{
            "protocol":"chatCompletions","response":{"choices":[{"message":{"content":"private-evidence"}}]}
        }})
        .to_string(),
    );
    assert!(rejected.contains("AI_PULL_REQUEST_INVALID_RESPONSE"));
    assert!(!rejected.contains("private-evidence"));
}

fn run(command: &str, payload: Value) -> Value {
    serde_json::from_str(&execute_json(
        &json!({"id":"inline","command":command,"payload":payload}).to_string(),
    ))
    .unwrap()
}

fn user_prompt(protocol: &str, body: &Value) -> String {
    match protocol {
        "geminiGenerateContent" => body["contents"][0]["parts"][0]["text"]
            .as_str()
            .unwrap()
            .into(),
        "anthropicMessages" => body["messages"][0]["content"].as_str().unwrap().into(),
        _ => body["messages"][1]["content"].as_str().unwrap().into(),
    }
}

#[test]
fn inline_edit_plans_match_the_shared_fixture() {
    let fixture = inline_edit_fixture();
    for case in fixture["plans"].as_array().unwrap() {
        let response = run(
            "ai.inlineEdit.plan",
            json!({"provider": case["provider"], "model": case["model"], "edit": fixture["edit"]}),
        );
        assert_eq!(response["ok"], true, "{}: {response}", case["case"]);
        let plan = &response["data"];
        let expected = &case["expected"];
        let protocol = case["provider"]["wireProtocol"].as_str().unwrap();
        assert_eq!(plan["url"], expected["url"], "{}", case["case"]);
        assert_eq!(
            plan["credential"], expected["credential"],
            "{}",
            case["case"]
        );
        let token = expected["tokenField"]
            .as_str()
            .unwrap()
            .split('.')
            .fold(&plan["body"], |value, key| &value[key]);
        assert_eq!(token, &expected["outputTokens"], "{}", case["case"]);
        let temperature = if protocol == "geminiGenerateContent" {
            &plan["body"]["generationConfig"]["temperature"]
        } else {
            &plan["body"]["temperature"]
        };
        assert_eq!(temperature, &expected["temperature"], "{}", case["case"]);
        assert!(plan["body"].get("stream").is_none());
        assert_eq!(
            user_prompt(protocol, &plan["body"]),
            fixture["expectedUserPrompt"]
        );
        assert!(!plan.to_string().contains("fixture-secret"));
    }
}

#[test]
fn inline_edit_rejections_and_decodes_match_the_shared_fixture() {
    let fixture = inline_edit_fixture();
    for case in fixture["planRejections"].as_array().unwrap() {
        let response = run(
            "ai.inlineEdit.plan",
            json!({"provider": case["provider"], "model": case["model"], "edit": fixture["edit"]}),
        );
        assert_eq!(
            response["error"]["message"], case["code"],
            "{}",
            case["case"]
        );
    }
    for case in fixture["decodes"].as_array().unwrap() {
        let response = run(
            "ai.inlineEdit.decode",
            json!({"wireProtocol": case["wireProtocol"], "response": case["response"]}),
        );
        match case.get("code") {
            Some(code) => assert_eq!(response["error"]["message"], *code, "{}", case["case"]),
            None => assert_eq!(
                response["data"]["editedText"], case["editedText"],
                "{}",
                case["case"]
            ),
        }
    }
}

#[test]
fn inline_edit_context_keeps_the_nearest_characters_by_unicode_scalar() {
    let fixture = inline_edit_fixture();
    let case = &fixture["plans"][0];
    let response = run(
        "ai.inlineEdit.plan",
        json!({"provider": case["provider"], "model": case["model"], "edit": {
            "beforeSelection": format!("{}{}", "Ω".repeat(10), "界".repeat(12_000)),
            "selectedText": "x",
            "afterSelection": format!("{}{}", "😀".repeat(12_000), "¶"),
        }}),
    );
    let user = user_prompt("chatCompletions", &response["data"]["body"]);
    assert!(!user.contains('Ω'));
    assert_eq!(user.chars().filter(|c| *c == '界').count(), 12_000);
    assert_eq!(user.chars().filter(|c| *c == '😀').count(), 12_000);
    assert!(!user.contains('¶'));
    // Optional file context is omitted rather than rendered as empty labels.
    assert!(user.starts_with("Instruction:\n"));
}
