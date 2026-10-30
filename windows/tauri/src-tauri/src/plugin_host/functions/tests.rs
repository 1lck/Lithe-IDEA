use super::*;

fn manifest() -> Value {
    json!({"settingActions":[{"id":"refresh","title":"Refresh","function":"snapshot.refresh","confirm":true,"page":{"buildSystemID":"fixture"}}],
        "buildSystems":[{"id":"fixture","provider":{"launch":{"kind":"packaged","path":"bin/provider"}}},
            {"id":"another","provider":{"launch":{"kind":"packaged","path":"bin/another"}}}]})
}

#[test]
fn action_and_provider_are_selected_only_from_the_same_manifest() {
    let (action, system) = selection(&manifest(), "refresh").unwrap();
    assert_eq!(action["function"], "snapshot.refresh");
    assert_eq!(system, "fixture");
    assert!(action["confirm"].as_bool().unwrap());
    assert_eq!(
        selection(&manifest(), "another-plugin-action")
            .unwrap_err()
            .code,
        "plugin.function.unknownAction"
    );
}

#[test]
fn missing_ambiguous_and_editor_shared_sources_are_explicitly_unavailable() {
    let mut value = manifest();
    value["settingActions"][0]["page"] = json!({"buildSystemID":"missing"});
    assert_eq!(
        selection(&value, "refresh").unwrap_err().code,
        "plugin.function.providerUnavailable"
    );
    value["settingActions"][0]
        .as_object_mut()
        .unwrap()
        .remove("page");
    assert!(
        selection(&value, "refresh").is_err(),
        "cannot guess among two providers"
    );
    value["settingActions"][0]["page"] = json!({"languageID":"fixture-language"});
    value["buildSystems"][0]["provider"] = json!({"languageServer":"fixture-language"});
    assert!(
        selection(&value, "refresh").is_err(),
        "must not adopt or stop an editor's shared session"
    );
}

#[test]
fn shared_contract_scope_value_and_action_placement_stay_authoritative() {
    let value: Value = serde_json::from_str(include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../shared/contracts/plugins/v1/fixtures/settings-v2.plugin.json"
    )))
    .unwrap();
    let normalized = super::super::scan::validate_manifest_with(&value, None).unwrap();
    let setting = normalized["settings"]
        .as_array()
        .unwrap()
        .iter()
        .find(|setting| setting["id"] == "dialyzer")
        .unwrap();
    assert_eq!(setting["scope"], "project");
    assert_eq!(
        normalized["settingActions"][0]["function"],
        "dialyzer.rebuild"
    );
    assert!(
        selection(&normalized, "rebuildPlt").is_err(),
        "shared language provider remains unavailable for isolated actions"
    );
}

#[test]
fn core_error_codes_and_plugin_error_codes_are_preserved() {
    let error = Error::core(
        &json!({"code":"permission_denied","details":"plugin.function.wrongPlugin","message":"wrong plugin"}),
    );
    assert_eq!(error.code, "plugin.function.wrongPlugin");
    let error = Error::core(
        &json!({"code":"plugin.function.failed","message":"backend rejected","pluginErrorCode":"fixture.failed"}),
    );
    assert_eq!(error.plugin_error_code.as_deref(), Some("fixture.failed"));
    let error = Error::core(
        &json!({"code":"processFailed", "details":"private OS diagnostics", "message":"transport failed"}),
    );
    assert_eq!(error.code, "processFailed");
}

#[test]
fn retired_receipts_are_reclaimed_only_for_the_destroyed_native_window() {
    let state = FunctionsState::default();
    let mut first_window = tauri::ResourceTable::default();
    let first = table_window_owner(&mut first_window);
    assert_eq!(table_window_owner(&mut first_window).id, first.id);
    for index in 0..4096 {
        state.retired.lock().unwrap().insert(
            format!("operation-{index}"),
            ReceiptOwner {
                window: "main".into(),
                incarnation: first.id,
            },
        );
    }
    let mut replacement_window = tauri::ResourceTable::default();
    let replacement = table_window_owner(&mut replacement_window);
    assert_ne!(
        first.id, replacement.id,
        "reusing a label does not reuse native resources"
    );
    state.retired.lock().unwrap().insert(
        "new-owner-receipt".into(),
        ReceiptOwner {
            window: "main".into(),
            incarnation: replacement.id,
        },
    );
    state.retire_window(&first);
    assert!(!first.alive.load(Ordering::Acquire));
    assert!(replacement.alive.load(Ordering::Acquire));
    assert_eq!(state.retired.lock().unwrap().len(), 1);
    state.retire_window(&first);
    assert_eq!(
        state.retired.lock().unwrap()["new-owner-receipt"].incarnation,
        replacement.id
    );
}

#[test]
fn cleanup_retry_checks_the_real_native_incarnation_before_mutating_any_owner() {
    let mut original_window = tauri::ResourceTable::default();
    let original = table_window_owner(&mut original_window);
    let mut replacement_window = tauri::ResourceTable::default();
    let replacement = table_window_owner(&mut replacement_window);
    assert!(check_expected_owner(&original, Some(original.id)).is_ok());
    assert!(check_expected_owner(&replacement, Some(original.id)).is_err());
    assert!(check_expected_owner(&replacement, Some(replacement.id)).is_ok());
    original.alive.store(false, Ordering::Release);
    assert!(check_expected_owner(&original, Some(original.id)).is_err());
    assert!(replacement.alive.load(Ordering::Acquire));
}

#[test]
fn web_selection_uses_only_the_requested_dedicated_provider_and_allows_registry_discovery() {
    let (action, provider) = selection(&manifest(), "__web__:fixture:").unwrap();
    assert_eq!(provider, "fixture");
    assert_eq!(action["function"], "");
    let (action, provider) = selection(&manifest(), "__web__:fixture:snapshot.refresh").unwrap();
    assert_eq!(provider, "fixture");
    assert_eq!(action["function"], "snapshot.refresh");
    assert_eq!(
        selection(&manifest(), "__web__:missing:snapshot.refresh")
            .unwrap_err()
            .code,
        "plugin.function.providerUnavailable"
    );
}
