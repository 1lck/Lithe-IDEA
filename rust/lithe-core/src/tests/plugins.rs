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
    assert_eq!(language_server.tool_id, "intelephense");
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
fn language_server_manifest_rejects_each_invalid_source_and_path_independently() {
    // One invalid field at a time: a version error must not hide a broken path
    // check, and v1 must not accept launch options the runtime never consumes.
    for (field, value) in [
        ("version", json!("01.15.1")),
        ("archiveURL", json!("http://example.com/server.tgz")),
        (
            "archiveURL",
            json!("https://user:secret@example.com/server.tgz"),
        ),
        ("archiveSHA256", json!("not-a-digest")),
        ("archiveFormat", json!("unknown")),
        ("archiveRoot", json!("../package")),
        ("entrypoint", json!("lib/../intelephense.js")),
        ("entrypoint", json!("C:/server.js")),
        ("entrypoint", json!("lib\\server.js")),
        ("license", json!("/LICENSE")),
        ("launcherRelativePath", json!("bin/server")),
        ("arguments", json!(["--stdio"])),
        ("pluginID", json!("dev.example.other")),
    ] {
        let mut manifest: Value = serde_json::from_str(PHP_LANGUAGE_SERVER_MANIFEST).unwrap();
        manifest[field] = value.clone();
        assert!(
            matches!(
                validate_language_server_manifest_json(
                    &manifest.to_string(),
                    "dev.lithe.plugin.php-support"
                ),
                Err(PluginValidationError::InvalidLanguageServerManifest { .. })
            ),
            "accepted invalid {field}: {value}"
        );
    }
}

#[test]
fn plugin_manifest_rejects_unowned_language_modules_and_raw_unsorted_recognition() {
    for (field, value) in [
        ("languageServerModuleID", json!("dev.other.language.server")),
        ("fileExtensions", json!(["phtml", "php"])),
    ] {
        let mut manifest: Value = serde_json::from_str(PHP_PLUGIN_MANIFEST).unwrap();
        manifest["languageSupports"][0][field] = value;
        assert!(matches!(
            validate_plugin_manifest_json(
                &manifest.to_string(),
                PluginVersion {
                    major: 0,
                    minor: 3,
                    patch: 0
                }
            ),
            Err(PluginValidationError::InvalidLanguageSupport { .. })
        ));
    }
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
    lifecycle
        .apply(PluginLifecycleAction::Disable, "disable-1")
        .unwrap();
    assert!(lifecycle.bind_resource("late-run").is_err());
    let error = lifecycle
        .apply(PluginLifecycleAction::CompleteDisable, "disable-1")
        .unwrap_err();
    assert_eq!(
        error,
        PluginValidationError::ActiveResources {
            plugin: "dev.lithe.plugin.php-support".into(),
            resources: vec!["lsp-session-1".into()]
        }
    );
    lifecycle.unbind_resource("lsp-session-1");
    let event = lifecycle
        .apply(PluginLifecycleAction::CompleteDisable, "disable-1")
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
    assert_eq!(response["data"]["toolID"], "intelephense");

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

#[test]
fn plugin_session_disable_cancels_enable_without_losing_pending_resources() {
    use crate::plugins::session::PluginSessionRegistry;
    let mut registry = PluginSessionRegistry::default();
    let mut request = |action: &str, fields: Value| {
        let mut value = json!({"ownerId":"host", "pluginId":"go", "action":action});
        value
            .as_object_mut()
            .unwrap()
            .extend(fields.as_object().unwrap().clone());
        registry.execute(serde_json::from_value(value).unwrap())
    };
    request("restore", json!({"installed":true})).unwrap();
    request(
        "transition",
        json!({"transition":"enable","operationId":"start"}),
    )
    .unwrap();
    request("bindResource", json!({"resourceId":"pending-lsp"})).unwrap();
    request(
        "transition",
        json!({"transition":"disable","operationId":"stop"}),
    )
    .unwrap();
    for fields in [
        json!({"transition":"completeEnable","operationId":"start"}),
        json!({"transition":"completeDisable","operationId":"stop"}),
        json!({"transition":"fail","operationId":"start"}),
        json!({"transition":"uninstall","operationId":"remove"}),
    ] {
        assert!(request("transition", fields).is_err());
    }
    assert!(request("bindResource", json!({"resourceId":"late-run"})).is_err());
    // Reload/bootstrap must not replace the closed gate or outstanding handle.
    let state = request("restore", json!({"installed":true,"enabled":true})).unwrap();
    assert_eq!(state.lifecycle.state, PluginLifecycleState::Disabling);
    assert_eq!(
        state.lifecycle.resources.into_iter().collect::<Vec<_>>(),
        ["pending-lsp"]
    );
    request("releaseResource", json!({"resourceId":"pending-lsp"})).unwrap();
    request(
        "transition",
        json!({"transition":"completeDisable","operationId":"stop"}),
    )
    .unwrap();
    request(
        "transition",
        json!({"transition":"uninstall","operationId":"remove"}),
    )
    .unwrap();
    let state = request(
        "transition",
        json!({"transition":"completeUninstall","operationId":"remove"}),
    )
    .unwrap();
    assert!(!state.installed);
    assert!(request(
        "transition",
        json!({"transition":"enable","operationId":"bad"})
    )
    .is_err());
    request(
        "transition",
        json!({"transition":"beginInstall","operationId":"reinstall"}),
    )
    .unwrap();
    assert!(request(
        "transition",
        json!({"transition":"completeInstall","operationId":"old"})
    )
    .is_err());
    assert!(
        request(
            "transition",
            json!({"transition":"completeInstall","operationId":"reinstall"})
        )
        .unwrap()
        .installed
    );
}

#[test]
fn plugin_session_hosts_and_packages_are_isolated_and_idle_sessions_can_close() {
    use crate::plugins::session::PluginSessionRegistry;
    let mut registry = PluginSessionRegistry::default();
    for (owner, plugin) in [("one", "php"), ("one", "go"), ("two", "php")] {
        let input = json!({"ownerId":owner,"pluginId":plugin,"action":"restore","installed":true,"enabled":true});
        registry
            .execute(serde_json::from_value(input).unwrap())
            .unwrap();
    }
    let mut input =
        json!({"ownerId":"one","pluginId":"php","action":"bindResource","resourceId":"worker"});
    registry
        .execute(serde_json::from_value(input.clone()).unwrap())
        .unwrap();
    assert!(registry
        .execute(serde_json::from_value(input.clone()).unwrap())
        .is_err());
    input["action"] = json!("close");
    assert!(registry
        .execute(serde_json::from_value(input.clone()).unwrap())
        .is_err());
    input["pluginId"] = json!("go");
    registry
        .execute(serde_json::from_value(input.clone()).unwrap())
        .unwrap();
    input["action"] = json!("snapshot");
    assert!(registry
        .execute(serde_json::from_value(input.clone()).unwrap())
        .is_err());
    input["ownerId"] = json!("two");
    input["pluginId"] = json!("php");
    assert!(registry
        .execute(serde_json::from_value(input).unwrap())
        .unwrap()
        .lifecycle
        .resources
        .is_empty());
}

#[test]
fn staged_native_code_cannot_activate_until_a_new_host_restores_it() {
    let mut lifecycle = PluginLifecycle::new("php");
    for action in [
        PluginLifecycleAction::BeginInstall,
        PluginLifecycleAction::CompleteInstall,
        PluginLifecycleAction::RequireRestart,
    ] {
        lifecycle.apply(action, "install").unwrap();
    }
    assert_eq!(lifecycle.state, PluginLifecycleState::AwaitingRestart);
    assert!(lifecycle
        .apply(PluginLifecycleAction::Enable, "enable")
        .is_err());
    assert!(lifecycle.bind_resource("old-module").is_err());
}

#[test]
fn worker_packages_normalize_permissions_and_preserve_legacy_php() {
    let manifest: Value = serde_json::from_str(include_str!(
        "../../../../shared/fixtures/plugins/windows-php-legacy-v1.json"
    ))
    .unwrap();
    let mut package = json!({"format":"lithe-worker-plugin","version":1,"manifest":manifest,"source":"export function activate() {}"});
    package["manifest"]["permissions"] = json!({"secrets":true});
    let normalized = crate::plugins::worker::validate_package(&package.to_string()).unwrap();
    assert!(normalized["manifest"].get("permissions").is_none());
    assert_eq!(normalized["manifest"]["lsp"]["runtime"], "bun");
    for path in ["../secret", "C:/secret", "file/secret", "/secret"] {
        package["manifest"]["runActions"]["manifestFiles"] = json!([path]);
        assert!(crate::plugins::worker::validate_package(&package.to_string()).is_err());
    }
}

fn signed_worker_fixture(runtime: &str) -> (Value, Vec<u8>) {
    use base64::Engine;
    use ring::signature::KeyPair;
    use sha2::{Digest, Sha256};
    let key = ring::signature::Ed25519KeyPair::from_seed_unchecked(&[7; 32]).unwrap();
    let mut manifest: Value = serde_json::from_str(include_str!(
        "../../../../Plugins/win/Official/GoSupport/plugin.json"
    ))
    .unwrap();
    manifest["nativeTarget"] = json!("windows-x86_64");
    manifest["lsp"]["runtime"] = json!(runtime);
    let content = [
        ("plugin.json", manifest.to_string()),
        ("plugin.js", "export function activate() {}".into()),
        (
            "resources/go/bin/gopls.exe",
            "test-only native resource".into(),
        ),
    ];
    let files = content
        .iter()
        .map(|(path, bytes)| {
            (
                (*path).to_owned(),
                format!("{:x}", Sha256::digest(bytes.as_bytes())),
            )
        })
        .collect();
    let mut document = crate::plugins::bundle::PackageSignature {
        schema_version: 1,
        algorithm: "ed25519".into(),
        key_id: "lithe-official-plugins-v1".into(),
        plugin_id: "lithe.go".into(),
        plugin_version: "1.0.0".into(),
        files,
        signature: String::new(),
    };
    document.signature = base64::engine::general_purpose::STANDARD.encode(
        key.sign(&crate::plugins::bundle::canonical_signature_payload(
            &document,
        ))
        .as_ref(),
    );
    let encoded: serde_json::Map<String, Value> = content
        .iter()
        .map(|(path, bytes)| {
            (
                (*path).to_owned(),
                json!(base64::engine::general_purpose::STANDARD.encode(bytes)),
            )
        })
        .collect();
    (
        json!({"format":"lithe-native-worker-plugin","version":1,"signature":document,"files":encoded}),
        key.public_key().as_ref().to_vec(),
    )
}

#[test]
fn signed_worker_resources_require_publisher_identity_and_complete_unchanged_inventory() {
    let (package, public_key) = signed_worker_fixture("package");
    let verified =
        crate::plugins::bundle::verify_bundle_with_key(&package.to_string(), &public_key).unwrap();
    assert_eq!(verified.package["manifest"]["lsp"]["runtime"], "package");
    assert_eq!(
        verified.package["manifest"]["lsp"]["server"]["default"],
        "resources/go/bin/gopls.exe"
    );
    assert_eq!(verified.files.len(), 3);
    // A test signature is never accepted by the production publisher policy.
    assert!(crate::plugins::bundle::verify_bundle(&package.to_string()).is_err());
    let mut missing = package.clone();
    missing["files"]
        .as_object_mut()
        .unwrap()
        .remove("plugin.js");
    assert!(
        crate::plugins::bundle::verify_bundle_with_key(&missing.to_string(), &public_key).is_err()
    );
    let mut tampered = package.clone();
    tampered["files"]["resources/go/bin/gopls.exe"] = json!("dGFtcGVyZWQ=");
    assert!(
        crate::plugins::bundle::verify_bundle_with_key(&tampered.to_string(), &public_key).is_err()
    );
    let mut extra = package;
    extra["files"]["unexpected.exe"] = json!("dGFtcGVyZWQ=");
    assert!(
        crate::plugins::bundle::verify_bundle_with_key(&extra.to_string(), &public_key).is_err()
    );
}

#[test]
fn signed_native_resources_cannot_redirect_launch_to_a_host_runtime() {
    for runtime in ["bun", "node", "system"] {
        let (package, public_key) = signed_worker_fixture(runtime);
        assert!(
            crate::plugins::bundle::verify_bundle_with_key(&package.to_string(), &public_key)
                .is_err()
        );
    }
}

#[test]
fn worker_resource_paths_are_portable_and_cannot_escape_or_alias_windows_devices() {
    for path in [
        "../escape",
        "C:/escape",
        "file:stream",
        "a\\b",
        "a/CON.txt",
        "a/lpt1",
        "a/trailing.",
        "a/trailing ",
        "a//b",
        "/absolute",
    ] {
        assert!(
            !crate::plugins::bundle::safe_resource_path(path),
            "accepted {path}"
        );
    }
    assert!(crate::plugins::bundle::safe_resource_path(
        "resources/go/bin/gopls.exe"
    ));
}

#[test]
fn native_launch_requires_a_signed_receipt_and_cannot_be_claimed_by_a_legacy_worker() {
    let manifest: Value = serde_json::from_str(include_str!(
        "../../../../Plugins/win/Official/GoSupport/plugin.json"
    ))
    .unwrap();
    let package = json!({"format":"lithe-worker-plugin","version":1,"manifest":manifest,"source":"export function activate() {}"});
    assert!(crate::plugins::worker::validate_package(&package.to_string()).is_err());
}

#[test]
fn shared_plugin_session_fixture_rejects_stale_commits_and_live_resource_removal() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../shared/fixtures/plugins/session-v1.json"
    ))
    .unwrap();
    let mut registry = crate::plugins::session::PluginSessionRegistry::default();
    for step in fixture["steps"].as_array().unwrap() {
        let mut request = step["request"].clone();
        request["ownerId"] = json!("fixture");
        request["pluginId"] = fixture["pluginId"].clone();
        let outcome = registry.execute(serde_json::from_value(request).unwrap());
        if step["error"] == true {
            assert!(outcome.is_err());
            continue;
        }
        let outcome = serde_json::to_value(outcome.unwrap()).unwrap();
        assert_eq!(outcome["lifecycle"]["state"], step["state"]);
        assert_eq!(outcome["lifecycle"]["resources"], step["resources"]);
        assert_eq!(outcome["installed"], step["installed"]);
    }
}
