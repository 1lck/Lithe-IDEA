use crate::plugins::{
    validate_language_server_manifest_json, validate_plugin_catalog_json,
    validate_plugin_manifest_json, PluginLifecycle, PluginLifecycleAction, PluginLifecycleState,
    PluginValidationError, PluginVersion,
};
use serde_json::{json, Value};
const OFFICIAL_PLUGINS: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../shared/fixtures/plugins/official-v1.json"
));
const LANGUAGE_SUPPORT_FIXTURE: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../shared/fixtures/plugins/language-support-v1.json"
));
const PHP_PLUGIN_MANIFEST: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../Plugins/mac/Official/PhpSupport/plugin.json"
));
const PHP_LANGUAGE_SERVER_MANIFEST: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../Plugins/mac/Official/PhpSupport/language-server.json"
));
const LIFECYCLE_FIXTURE: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../shared/fixtures/plugins/lifecycle-v1.json"
));
#[test]
fn official_plugin_catalog_is_valid_and_contains_only_released_downloads() {
    let owners = validate_plugin_catalog_json(
        OFFICIAL_PLUGINS,
        PluginVersion {
            major: 0,
            minor: 3,
            patch: 0,
        },
    )
    .expect("official plugin fixture should validate");
    assert!(owners.is_empty());
}

#[test]
fn language_support_catalog_allows_execution_and_testing_to_share_a_module() {
    let owners = validate_plugin_catalog_json(
        LANGUAGE_SUPPORT_FIXTURE,
        PluginVersion {
            major: 0,
            minor: 3,
            patch: 0,
        },
    )
    .expect("language support fixture should validate");
    assert_eq!(owners.len(), 2);
    assert_eq!(
        owners.get("dev.lithe.fixture.go.language-server"),
        Some(&"dev.lithe.fixture.go-support".to_string())
    );
    assert_eq!(
        owners.get("dev.lithe.fixture.go.execution"),
        Some(&"dev.lithe.fixture.go-support".to_string())
    );
}

#[test]
fn incompatible_host_is_rejected_deterministically() {
    let error = validate_plugin_catalog_json(
        OFFICIAL_PLUGINS,
        PluginVersion {
            major: 0,
            minor: 4,
            patch: 0,
        },
    )
    .unwrap_err();
    assert_eq!(
        error,
        PluginValidationError::IncompatibleHost {
            plugin: "catalog".into()
        }
    );
}

#[test]
fn php_plugin_manifests_are_validated_by_rust_core() {
    let host = PluginVersion {
        major: 0,
        minor: 3,
        patch: 0,
    };
    let manifest = validate_plugin_manifest_json(PHP_PLUGIN_MANIFEST, host)
        .expect("PHP plugin.json should use the Core contract");
    assert_eq!(manifest.id, "dev.lithe.plugin.php-support");
    assert_eq!(manifest.module_ids().len(), 2);
    assert_eq!(manifest.modules[0].metadata["displayName"], "PHP Execution");
    let language_server =
        validate_language_server_manifest_json(PHP_LANGUAGE_SERVER_MANIFEST, &manifest.id)
            .expect("PHP language-server.json should use the Core contract");
    assert_eq!(language_server.language_id, "php");
    assert_eq!(language_server.arguments, ["--stdio"]);
}

#[test]
fn plugin_manifest_rejects_conflicting_compact_and_full_module_declarations() {
    let mut value: Value = serde_json::from_str(PHP_PLUGIN_MANIFEST).unwrap();
    value["moduleIDs"] = json!(["dev.lithe.language.php.other"]);
    let error = validate_plugin_manifest_json(
        &value.to_string(),
        PluginVersion {
            major: 0,
            minor: 3,
            patch: 0,
        },
    )
    .unwrap_err();
    assert_eq!(
        error,
        PluginValidationError::InvalidModuleDeclaration {
            plugin: "dev.lithe.plugin.php-support".into(),
            detail: "moduleIDs and modules disagree".into(),
        }
    );
}

#[test]
fn language_server_manifest_rejects_noncanonical_versions_and_paths() {
    let mut value: Value = serde_json::from_str(PHP_LANGUAGE_SERVER_MANIFEST).unwrap();
    value["version"] = json!("01.15.1");
    value["launcherRelativePath"] = json!("bin/../intelephense");
    let error =
        validate_language_server_manifest_json(&value.to_string(), "dev.lithe.plugin.php-support")
            .unwrap_err();
    assert!(matches!(
        error,
        PluginValidationError::InvalidLanguageServerManifest { .. }
    ));
}

#[test]
fn plugin_lifecycle_requires_resources_to_stop_before_disable_or_uninstall() {
    let mut lifecycle = PluginLifecycle::new("dev.lithe.plugin.php-support");
    lifecycle
        .apply(PluginLifecycleAction::BeginInstall, "install-1")
        .unwrap();
    lifecycle
        .apply(PluginLifecycleAction::CompleteInstall, "install-1")
        .unwrap();
    lifecycle
        .apply(PluginLifecycleAction::Enable, "enable-1")
        .unwrap();
    lifecycle
        .apply(PluginLifecycleAction::CompleteEnable, "enable-1")
        .unwrap();
    lifecycle.bind_resource("lsp-session-1").unwrap();
    let error = lifecycle
        .apply(PluginLifecycleAction::Disable, "disable-1")
        .unwrap_err();
    assert_eq!(
        error,
        PluginValidationError::ActiveResources {
            plugin: "dev.lithe.plugin.php-support".into(),
            resources: vec!["lsp-session-1".into()]
        }
    );
    lifecycle.unbind_resource("lsp-session-1");
    lifecycle
        .apply(PluginLifecycleAction::Disable, "disable-2")
        .unwrap();
    let event = lifecycle
        .apply(PluginLifecycleAction::CompleteDisable, "disable-2")
        .unwrap();
    assert_eq!(event.state, PluginLifecycleState::Disabled);
    assert_eq!(event.generation, 6);
}

#[test]
fn plugin_lifecycle_cannot_hide_active_resources_in_failure_or_reset() {
    let mut lifecycle = PluginLifecycle::new("dev.lithe.plugin.php-support");
    for action in [
        PluginLifecycleAction::BeginInstall,
        PluginLifecycleAction::CompleteInstall,
        PluginLifecycleAction::Enable,
        PluginLifecycleAction::CompleteEnable,
    ] {
        lifecycle.apply(action, "operation").unwrap();
    }
    lifecycle.bind_resource("lsp-session-1").unwrap();
    for action in [PluginLifecycleAction::Fail, PluginLifecycleAction::Reset] {
        assert!(matches!(
            lifecycle.apply(action, "operation"),
            Err(PluginValidationError::ActiveResources { .. })
        ));
    }
}

#[test]
fn plugin_lifecycle_generation_overflow_does_not_partially_apply_state() {
    let mut lifecycle = PluginLifecycle {
        plugin_id: "dev.lithe.plugin.php-support".into(),
        state: PluginLifecycleState::Installed,
        generation: u64::MAX,
        resources: Default::default(),
    };

    assert!(matches!(
        lifecycle.apply(PluginLifecycleAction::Enable, "enable-overflow"),
        Err(PluginValidationError::GenerationOverflow { .. })
    ));
    assert_eq!(lifecycle.state, PluginLifecycleState::Installed);
    assert_eq!(lifecycle.generation, u64::MAX);
}

#[test]
fn uninstalled_plugin_can_begin_a_fresh_install() {
    let mut lifecycle = PluginLifecycle::new("dev.lithe.plugin.php-support");
    for action in [
        PluginLifecycleAction::BeginInstall,
        PluginLifecycleAction::CompleteInstall,
        PluginLifecycleAction::Uninstall,
        PluginLifecycleAction::CompleteUninstall,
    ] {
        lifecycle.apply(action, "operation").unwrap();
    }

    let event = lifecycle
        .apply(PluginLifecycleAction::BeginInstall, "reinstall")
        .unwrap();
    assert_eq!(event.previous_state, PluginLifecycleState::Uninstalled);
    assert_eq!(event.state, PluginLifecycleState::Installing);
}

#[test]
fn plugin_lifecycle_wire_fixture_is_deterministic() {
    #[derive(serde::Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Case {
        lifecycle: PluginLifecycle,
        action: PluginLifecycleAction,
        operation_id: String,
        bind_resource: Option<String>,
        expected_state: PluginLifecycleState,
        expected_generation: u64,
        #[serde(default)]
        expected_resources: Vec<String>,
    }

    for case in serde_json::from_str::<Vec<Case>>(LIFECYCLE_FIXTURE).unwrap() {
        let mut lifecycle = case.lifecycle;
        if let Some(resource) = case.bind_resource {
            lifecycle.bind_resource(resource).unwrap();
        }
        let event = lifecycle.apply(case.action, case.operation_id).unwrap();
        assert_eq!(event.state, case.expected_state);
        assert_eq!(event.generation, case.expected_generation);
        assert_eq!(event.resources, case.expected_resources);
    }
}

#[test]
fn plugin_contract_commands_are_executable_through_the_shared_dispatcher() {
    let manifest: Value = serde_json::from_str(PHP_PLUGIN_MANIFEST).unwrap();
    let response: Value = serde_json::from_str(&crate::execute_json(
        &json!({
            "id": "manifest-1",
            "command": "plugin.validateManifest",
            "payload": {
                "hostVersion": "0.3.0",
                "manifest": manifest
            }
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(response["ok"], true);
    assert_eq!(response["data"]["id"], "dev.lithe.plugin.php-support");

    let language_server: Value = serde_json::from_str(PHP_LANGUAGE_SERVER_MANIFEST).unwrap();
    let response: Value = serde_json::from_str(&crate::execute_json(
        &json!({
            "id": "language-server-1",
            "command": "plugin.validateLanguageServer",
            "payload": {
                "pluginID": "dev.lithe.plugin.php-support",
                "manifest": language_server
            }
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(response["ok"], true);
    assert_eq!(response["data"]["languageID"], "php");

    let response: Value = serde_json::from_str(&crate::execute_json(
        &json!({
            "id": "lifecycle-1",
            "command": "plugin.lifecycle",
            "payload": {
                "lifecycle": {
                    "pluginId": "dev.lithe.plugin.php-support",
                    "state": "discovered",
                    "generation": 0,
                    "resources": []
                },
                "action": "beginInstall",
                "operationId": "install-1"
            }
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(response["ok"], true);
    assert_eq!(response["data"]["lifecycle"]["state"], "installing");
    assert_eq!(response["data"]["event"]["operationId"], "install-1");
}
