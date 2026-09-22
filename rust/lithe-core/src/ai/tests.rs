//! Behavioral coverage for configuration import, secret boundaries and commit wire protocols.

use super::*;
use serde_json::{json, Value};
use std::collections::BTreeMap;

fn fixture() -> (Provider, CommitOptions, Vec<CommitFile>, Value) {
    let value: Value = serde_json::from_str(include_str!(
        "../../../../shared/fixtures/ai/commit-generation-v1.json"
    ))
    .unwrap();
    (
        serde_json::from_value(value["provider"].clone()).unwrap(),
        serde_json::from_value(value["options"].clone()).unwrap(),
        serde_json::from_value(value["files"].clone()).unwrap(),
        value,
    )
}

#[test]
fn protocols_match_shared_fixture_without_duplicate_url_suffixes() {
    let (mut provider, options, files, value) = fixture();
    for response in value["responses"].as_array().unwrap() {
        provider.api_protocol = response["protocol"].as_str().unwrap().into();
        provider.endpoint = "https://api.example.com/v1".into();
        let first = plan_commit(&provider, &options, &files).unwrap();
        provider.endpoint = first.url.clone();
        assert_eq!(
            plan_commit(&provider, &options, &files).unwrap().url,
            first.url
        );
        assert_eq!(
            decode_message(&provider.api_protocol, &response["body"], false).unwrap(),
            value["expectedMessage"]
        );
        assert!(first.body.to_string().contains("Simplified Chinese"));
        assert!(first.body.to_string().contains("src/editor.css"));
        if provider.api_protocol == "anthropicMessages" {
            assert!(first.body.get("reasoning_effort").is_none());
        }
    }
}

#[test]
fn custom_rules_budget_every_file_and_preserve_unicode() {
    let (provider, mut options, mut files, _) = fixture();
    options.format = "custom".into();
    options.custom_instructions = "Begin with PROJECT-42".into();
    options.maximum_diff_characters = 8_000;
    files[0].diff = "界".repeat(10_000);
    files[1].diff = "+second-file-change".into();
    let plan = plan_commit(&provider, &options, &files).unwrap();
    let system = plan.body["input"][0]["content"].as_str().unwrap();
    let input = plan.body["input"][1]["content"].as_str().unwrap();
    assert!(system.contains("PROJECT-42"));
    assert_eq!(input.matches('界').count(), 4_000);
    assert!(input.contains("second-file-change"));
    assert!(input.contains("truncated"));
}

#[test]
fn rejects_credentials_in_urls_insecure_http_and_sensitive_files() {
    let (mut provider, options, mut files, _) = fixture();
    for url in [
        "https://user:password@example.com/v1",
        "https://example.com/v1?api_key=example",
        "file:///tmp/api",
    ] {
        provider.endpoint = url.into();
        assert!(plan_commit(&provider, &options, &files).is_err());
    }
    provider.endpoint = "http://localhost:1234/v1".into();
    assert_eq!(
        plan_commit(&provider, &options, &files).err(),
        Some("AI_COMMIT_INSECURE_ENDPOINT")
    );
    provider.allows_insecure_http = true;
    assert!(plan_commit(&provider, &options, &files).is_ok());
    files[0].path = "config/.env.production".into();
    assert_eq!(
        plan_commit(&provider, &options, &files).err(),
        Some("AI_COMMIT_SENSITIVE_FILE")
    );
}

#[test]
fn codex_import_supports_profiles_env_keys_and_never_serializes_secrets() {
    let config = "model = 'default'\nprofile = 'work'\n[profiles.work]\nmodel = 'work-model'\nmodel_provider = 'custom'\n[model_providers.custom]\nbase_url = 'https://example.com/v1'\nwire_api = 'responses'\nenv_key = 'EXAMPLE_KEY'";
    let environment = BTreeMap::from([("EXAMPLE_KEY".into(), "fixture-only-secret".into())]);
    let imported = parse_codex(config, "{}", &environment).unwrap();
    assert_eq!(imported.provider.model, "work-model");
    assert!(imported.has_credential);
    assert_eq!(imported.credential.as_deref(), Some("fixture-only-secret"));
    assert!(!serde_json::to_string(&imported)
        .unwrap()
        .contains("fixture-only-secret"));
    assert!(parse_codex("not valid = [", "{}", &environment).is_err());
    let oauth = parse_codex(
        "model = 'example'",
        r#"{"tokens":{"access_token":"oauth-token"}}"#,
        &BTreeMap::new(),
    )
    .unwrap();
    assert!(!oauth.has_credential);
    let local = parse_codex("model = 'local'\nmodel_provider = 'local'\n[model_providers.local]\nbase_url = 'http://localhost:1234/v1'\nrequires_openai_auth = false", "", &BTreeMap::new()).unwrap();
    assert!(!local.provider.requires_api_key);
}

#[test]
fn codex_import_reads_provider_bearer_token_without_exposing_it() {
    let config = "model = 'example-model'\nmodel_provider = 'custom'\n[model_providers.custom]\nbase_url = 'https://example.com/v1'\nenv_key = 'EXAMPLE_KEY'\nexperimental_bearer_token = 'fixture-inline-token'";
    let imported = parse_codex(config, "{}", &BTreeMap::new()).unwrap();
    assert_eq!(imported.credential.as_deref(), Some("fixture-inline-token"));
    assert!(imported.has_credential);
    assert!(!serde_json::to_string(&imported)
        .unwrap()
        .contains("fixture-inline-token"));
    let environment = BTreeMap::from([("EXAMPLE_KEY".into(), "fixture-env-token".into())]);
    let imported = parse_codex(config, "{}", &environment).unwrap();
    assert_eq!(imported.credential.as_deref(), Some("fixture-env-token"));
}

#[test]
fn claude_import_resolves_aliases_and_distinguishes_auth_headers() {
    let settings = json!({"model":"sonnet","env":{"ANTHROPIC_BASE_URL":"https://example.com","ANTHROPIC_DEFAULT_SONNET_MODEL":"example-model","ANTHROPIC_AUTH_TOKEN":"fixture-token"}});
    let imported = parse_claude(&settings.to_string(), "", "", &BTreeMap::new()).unwrap();
    assert_eq!(imported.provider.model, "example-model");
    assert_eq!(imported.provider.authentication, "bearer");
    let imported = parse_claude(r#"{"apiKey":"example-key"}"#, "", "", &BTreeMap::new()).unwrap();
    assert_eq!(imported.provider.authentication, "apiKey");
    // Blank local fields must not hide an inherited credential or model alias.
    let environment = BTreeMap::from([
        ("ANTHROPIC_API_KEY".into(), "fixture-environment-key".into()),
        (
            "ANTHROPIC_DEFAULT_SONNET_MODEL_NAME".into(),
            "example-sonnet".into(),
        ),
    ]);
    let imported = parse_claude(
        r#"{"model":"Sonnet","apiKey":" ","env":{"ANTHROPIC_API_KEY":""}}"#,
        "",
        "",
        &environment,
    )
    .unwrap();
    assert_eq!(
        imported.credential.as_deref(),
        Some("fixture-environment-key")
    );
    assert_eq!(imported.provider.model, "example-sonnet");
    assert_eq!(imported.provider.authentication, "apiKey");
    assert!(parse_claude("broken", "", "", &BTreeMap::new()).is_err());
}

#[test]
fn empty_responses_are_errors_and_subject_mode_removes_body() {
    assert!(decode_message("responses", &json!({}), true).is_err());
    assert_eq!(
        decode_message(
            "responses",
            &json!({"output_text":"```text\nSubject\n\nBody\n```"}),
            false
        )
        .unwrap(),
        "Subject"
    );
    assert_eq!(
        decode_message("responses", &json!({"output_text":"Subject\n\nBody"}), true).unwrap(),
        "Subject\n\nBody"
    );
}

#[test]
fn subject_only_generation_budgets_reasoning_and_rejects_incomplete_messages() {
    let (mut provider, options, files, _) = fixture();
    for (protocol, token_field, response) in [
        (
            "responses",
            "max_output_tokens",
            json!({"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"},"output_text":"Partial"}),
        ),
        (
            "chatCompletions",
            "max_tokens",
            json!({"choices":[{"finish_reason":"length","message":{"content":"Partial"}}]}),
        ),
        (
            "anthropicMessages",
            "max_tokens",
            json!({"stop_reason":"max_tokens","content":[{"type":"thinking","thinking":"fixture reasoning"}]}),
        ),
    ] {
        provider.api_protocol = protocol.into();
        let plan = plan_commit(&provider, &options, &files).unwrap();
        // A 512-token cap reproduced a thinking-only response during native integration testing.
        assert!(plan.body[token_field].as_u64().unwrap() >= 4_096);
        assert_eq!(
            decode_message(protocol, &response, false),
            Err("AI_COMMIT_OUTPUT_LIMIT")
        );
    }
}
