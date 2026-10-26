//! Real Core fixture parity and bounded filesystem admission, without tools.
use super::*;
use std::sync::atomic::{AtomicU64, Ordering};

fn fixture(name: &str) -> Value {
    serde_json::from_str(
        &std::fs::read_to_string(
            Path::new(env!("CARGO_MANIFEST_DIR"))
                .join("../../../shared/contracts/plugins/v1/fixtures")
                .join(name),
        )
        .unwrap(),
    )
    .unwrap()
}

struct Workspace(std::path::PathBuf);
impl Workspace {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let path = std::env::temp_dir().join(format!(
            "lithe-execution-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&path).unwrap();
        Self(path)
    }
    fn write(&self, path: &str) {
        let path = self.0.join(path);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, "fixture").unwrap();
    }
}
impl Drop for Workspace {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn real_core_workspace_file_and_case_plans_keep_the_exact_selection() {
    let manifest = fixture("language-packaged-server.plugin.json");
    let files = vec!["composer.json".into(), "tests/ItemTest.php".into()];
    for (scope, arguments) in [
        (TestScope::Workspace {}, json!(["vendor/bin/phpunit"])),
        (
            TestScope::File {
                relative_file_path: "tests/ItemTest.php".into(),
            },
            json!(["vendor/bin/phpunit", "tests/ItemTest.php"]),
        ),
        (
            TestScope::TestCase {
                identifier: "Suite.test[one]".into(),
                relative_file_path: Some("tests/ItemTest.php".into()),
            },
            json!([
                "vendor/bin/phpunit",
                "--filter",
                "\\bSuite\\.test\\[one\\]\\b",
                "tests/ItemTest.php"
            ]),
        ),
    ] {
        let plan = expand_plan(
            &manifest,
            "fixture",
            "php",
            &ExecutionSelection::Test { scope },
            &files,
        )
        .unwrap();
        assert_eq!(json!(plan.arguments), arguments);
        assert_eq!(plan.framework_id.as_deref(), Some("phpunit"));
    }
    let mut api_three = manifest.clone();
    api_three["pluginAPIVersion"] = json!(3);
    api_three["requires"] =
        json!({ "languages":1, "languageServers":1, "serverProcess":1, "executionProviders":1 });
    let api_three_plan = expand_plan(
        &api_three,
        "fixture",
        "php",
        &ExecutionSelection::Test {
            scope: TestScope::File {
                relative_file_path: "tests/ItemTest.php".into(),
            },
        },
        &files,
    )
    .unwrap();
    assert_eq!(
        api_three_plan.arguments,
        ["vendor/bin/phpunit", "tests/ItemTest.php"]
    );
    let run = expand_plan(
        &manifest,
        "fixture",
        "php",
        &ExecutionSelection::Run {
            relative_file_path: "-file.php".into(),
            user_arguments: vec!["two words".into()],
        },
        &files,
    )
    .unwrap();
    assert_eq!(run.arguments, ["./-file.php", "two words"]);
}

#[test]
fn discovery_uses_core_items_from_nested_workspace_files_without_parsing_source() {
    let workspace = Workspace::new();
    workspace.write("nested/composer.json");
    workspace.write("nested/tests/ItemTest.php");
    workspace.write("nested/src/Item.php");
    workspace.write(".git/privateTest.php");
    let files = inventory(&workspace.0).unwrap();
    assert_eq!(
        files,
        [
            "nested/composer.json",
            "nested/src/Item.php",
            "nested/tests/ItemTest.php"
        ]
    );
    let response = core_execute(
        "plugins.declarative.discoverTests",
        json!({
            "manifest": fixture("language-packaged-server.plugin.json"), "languageID": "php",
            "request": { "relativeProjectFilePaths": files },
        }),
    )
    .unwrap();
    core_ok(&response).unwrap();
    assert_eq!(response["items"].as_array().unwrap().len(), 2);
    assert_eq!(
        response["items"][1]["relativeFilePath"],
        "nested/tests/ItemTest.php"
    );
}

#[test]
fn unsupported_suites_invalid_cases_and_missing_files_never_widen_the_run() {
    let manifest = fixture("language-packaged-server.plugin.json");
    let files = vec!["composer.json".into()];
    let suite = ExecutionSelection::Test {
        scope: TestScope::Suite {
            identifier: "Suite".into(),
        },
    };
    assert_eq!(
        expand_plan(&manifest, "fixture", "php", &suite, &files).unwrap_err(),
        "plugin.execution.unavailable"
    );
    let case = ExecutionSelection::Test {
        scope: TestScope::TestCase {
            identifier: "bad\ncase".into(),
            relative_file_path: None,
        },
    };
    assert_eq!(
        expand_plan(&manifest, "fixture", "php", &case, &files).unwrap_err(),
        "plugin.test.invalidIdentifier"
    );
    let file = ExecutionSelection::Test {
        scope: TestScope::File {
            relative_file_path: "missing.php".into(),
        },
    };
    assert_eq!(
        validate_selection(&file, &files, true).unwrap_err(),
        "plugin.path.invalid"
    );
    assert_eq!(
        expand_plan(
            &manifest,
            "fixture",
            "php",
            &ExecutionSelection::Test {
                scope: TestScope::Workspace {}
            },
            &[]
        )
        .unwrap_err(),
        "plugin.test.unsupportedProject"
    );
}

#[test]
fn unsafe_scope_fields_and_current_capability_gate_stay_closed() {
    assert!(serde_json::from_value::<TestScope>(
        json!({ "kind":"workspace", "identifier":"silently ignored" })
    )
    .is_err());
    assert!(serde_json::from_value::<ExecutionSelection>(
        json!({ "kind":"test", "scope":{"kind":"workspace"}, "suite":"ignored" })
    )
    .is_err());
    assert!(super::super::host_capabilities()["executionProviders"].is_null());
    let mut manifest = fixture("language-packaged-server.plugin.json");
    manifest["pluginAPIVersion"] = json!(3);
    manifest["requires"] =
        json!({ "languages":1, "languageServers":1, "serverProcess":1, "executionProviders":1 });
    let rejected = super::super::scan::validate_manifest_with(
        &manifest,
        Some(super::super::host_capabilities()),
    )
    .unwrap_err();
    assert_eq!(rejected.code, "plugin.api.unsupported");
}

#[test]
fn admission_rejects_old_revisions_old_documents_and_other_workspace_generations() {
    let context = ExecutionContext {
        client_id: "document-one".into(),
        workspace_id: "north".into(),
        workspace_path: "C:/fixture/north".into(),
        generation: "runtime-one".into(),
    };
    let mut epoch = ExecutionEpoch::default();
    epoch
        .update("document-one".into(), 1, Some(context.clone()))
        .unwrap();
    assert_eq!(epoch.context.as_ref(), Some(&context));
    epoch.update("document-one".into(), 3, None).unwrap();
    assert!(epoch
        .update("document-one".into(), 2, Some(context.clone()))
        .is_err());
    assert!(epoch.context.is_none());
    let reloaded = ExecutionContext {
        client_id: "document-two".into(),
        generation: "runtime-two".into(),
        ..context.clone()
    };
    epoch
        .update("document-two".into(), 1, Some(reloaded.clone()))
        .unwrap();
    assert!(epoch
        .update("document-one".into(), 100, Some(context))
        .is_err());
    assert_eq!(epoch.context.as_ref(), Some(&reloaded));
    let mut windows = HashMap::new();
    windows.insert("main", epoch);
    windows
        .entry("workspace-other")
        .or_insert_with(ExecutionEpoch::default)
        .update("other".into(), 1, None)
        .unwrap();
    assert_eq!(windows["main"].context.as_ref(), Some(&reloaded));
    assert!(windows["workspace-other"].context.is_none());
    windows.get_mut("main").unwrap().retire();
    assert!(windows
        .get_mut("main")
        .unwrap()
        .update("document-two".into(), 99, Some(reloaded))
        .is_err());
}

#[test]
fn selected_file_bytes_are_part_of_the_reviewed_plan_identity() {
    let workspace = Workspace::new();
    workspace.write("tests/ItemTest.php");
    let selection = ExecutionSelection::Test {
        scope: TestScope::File {
            relative_file_path: "tests/ItemTest.php".into(),
        },
    };
    let before = source_identity(&workspace.0, &selection).unwrap();
    let files = inventory(&workspace.0).unwrap();
    let workspace_before = inventory_identity(&workspace.0, &files).unwrap();
    std::fs::write(
        workspace.0.join("tests/ItemTest.php"),
        "changed after review",
    )
    .unwrap();
    assert_ne!(before, source_identity(&workspace.0, &selection).unwrap());
    assert_ne!(
        workspace_before,
        inventory_identity(&workspace.0, &files).unwrap()
    );
    let outside = ExecutionSelection::Run {
        relative_file_path: "../outside.php".into(),
        user_arguments: vec![],
    };
    assert!(source_identity(&workspace.0, &outside).is_err());
}

#[test]
fn legacy_test_markers_keep_their_root_only_api_one_and_two_behavior() {
    let workspace = Workspace::new();
    workspace.write("composer.json");
    workspace.write("nested/phpunit.xml");
    let manifest = fixture("language-packaged-server.plugin.json");
    assert_eq!(
        existing_root_markers(&manifest, "php", &workspace.0),
        ["composer.json"]
    );
    assert!(existing_root_markers(&manifest, "go", &workspace.0).is_empty());
}
