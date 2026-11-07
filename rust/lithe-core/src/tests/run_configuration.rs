use super::support::{seed_generated, seed_requirements, temporary_root};
use crate::execute_json;
use serde_json::Value;
use std::fs;
use std::path::PathBuf;

#[test]
fn generic_preference_edits_preserve_run_metadata_without_creating_legacy_defaults_or_files() {
    let root = temporary_root("generic-preference-editor");
    fs::create_dir_all(&root).unwrap();
    struct Cleanup(PathBuf);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    let _cleanup = Cleanup(root.clone());
    let call = |command: &str, payload: Value| -> Value {
        serde_json::from_str(&execute_json(
            &serde_json::json!({
                "id":"generic-preference-editor", "command":command, "payload":payload
            })
            .to_string(),
        ))
        .unwrap()
    };
    let edited = call(
        "toolchains.editConsumerPreferences",
        serde_json::json!({
            "document":{"version":1}, "directory":"services/api", "consumer":"dev.example.build/compile",
            "tool":"dev.example.runtime:sdk", "value":{"inherit":"consumer"}
        }),
    );
    assert_eq!(edited["ok"], true, "{edited}");
    assert_eq!(
        edited["data"]["edit"]["preferences"]["stored"],
        serde_json::json!({"inherit":"consumer"})
    );
    for original in [
        serde_json::json!({"version":2,"configurations":[]}),
        serde_json::json!({"version":1,"configurations":[{"id":"user:legacy","type":"java.main","mainClass":"fixture.Main","workingDirectory":".","future":"preserve"}]}),
        serde_json::json!({"version":2,"configurations":[{"id":"user:task","env":{"TOKEN":"fixture-value"},"future":[1,2]}],
            "futureMetadata":{"keep":true},"toolchain":{"java":{"homePath":"/fixture/legacy-jdk"},"futureToolchain":{"keep":true}}}),
    ] {
        let result = call(
            "runConfig.updateToolPreferences",
            serde_json::json!({
                "localDocument":original,"preferences":edited["data"]["edit"]["document"]
            }),
        );
        assert_eq!(result["ok"], true, "{result}");
        let saved: Value =
            serde_json::from_str(result["data"]["document"].as_str().unwrap()).unwrap();
        assert_eq!(
            saved["toolchain"]["preferences"],
            edited["data"]["edit"]["document"]
        );
        let mut without_preferences = saved;
        without_preferences["toolchain"]
            .as_object_mut()
            .unwrap()
            .remove("preferences");
        if original.get("toolchain").is_none() {
            without_preferences
                .as_object_mut()
                .unwrap()
                .remove("toolchain");
        }
        assert_eq!(without_preferences, original);
    }
    assert!(!root.join(".lithe").exists());
}

#[test]
fn generic_preference_editor_rejects_invalid_documents_and_references_without_writing() {
    let root = temporary_root("invalid-generic-preference-editor");
    fs::create_dir_all(&root).unwrap();
    struct Cleanup(PathBuf);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    let _cleanup = Cleanup(root.clone());
    for (local, preferences) in [
        (
            serde_json::json!({"version":4294967298_u64,"configurations":[]}),
            serde_json::json!({"version":1}),
        ),
        (
            serde_json::json!({"version":999,"configurations":[]}),
            serde_json::json!({"version":1}),
        ),
        (
            serde_json::json!({"version":2,"configurations":{}}),
            serde_json::json!({"version":1}),
        ),
        (
            serde_json::json!({"version":2,"configurations":[],"toolchain":42}),
            serde_json::json!({"version":1}),
        ),
        (
            serde_json::json!({"version":2,"configurations":[]}),
            serde_json::json!({"version":1,"workspace":{"tools":{"java":{"inherit":"workspace"}}}}),
        ),
    ] {
        let result: Value = serde_json::from_str(&execute_json(
            &serde_json::json!({
                "id":"invalid-generic-preferences", "command":"runConfig.updateToolPreferences",
                "payload":{"localDocument":local,"preferences":preferences}
            })
            .to_string(),
        ))
        .unwrap();
        assert_eq!(result["ok"], false, "{result}");
        assert!(result["data"].is_null());
    }
    assert!(!root.join(".lithe").exists());
}

#[test]
fn project_tool_preferences_preserve_symbolic_choices_across_legacy_editor_saves_and_explicit_reset(
) {
    let root = temporary_root("project-tool-preferences");
    fs::create_dir_all(&root).unwrap();
    struct Cleanup(PathBuf);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    let _cleanup = Cleanup(root.clone());
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../shared/fixtures/toolchains/consumer-preferences.json"
    ))
    .unwrap();
    let call = |command: &str, payload: Value| -> Value {
        serde_json::from_str(&execute_json(
            &serde_json::json!({"id":"preferences-store","command":command,"payload":payload})
                .to_string(),
        ))
        .unwrap()
    };
    let document = serde_json::json!({"version":2,"configurations":[],"toolchain":{"preferences":fixture["document"]}});
    let changed = call(
        "runConfig.updateOptions",
        serde_json::json!({"root":root,"scope":"local","configurationId":"","localDocument":document,
        "toolchain":{"javaHomePath":"/fixture/changed-jdk"}}),
    );
    assert_eq!(changed["ok"], true, "{changed}");
    let saved: Value = serde_json::from_str(changed["data"]["document"].as_str().unwrap()).unwrap();
    assert_eq!(saved["toolchain"]["preferences"], fixture["document"]);
    let inspected = call(
        "runConfig.projectToolchain",
        serde_json::json!({"root":root,"path":".","localDocument":saved}),
    );
    assert_eq!(inspected["ok"], true, "{inspected}");
    assert_eq!(inspected["data"]["toolPreferences"], fixture["document"]);
    let reset = call(
        "runConfig.updateOptions",
        serde_json::json!({"root":root,"scope":"local","configurationId":"","localDocument":saved,
        "toolchain":{"preferences":{"version":1}}}),
    );
    assert_eq!(reset["ok"], true, "{reset}");
    let reset: Value = serde_json::from_str(reset["data"]["document"].as_str().unwrap()).unwrap();
    assert_eq!(
        reset["toolchain"]["preferences"],
        serde_json::json!({"version":1})
    );
    assert!(!root.join(".lithe/run/local.json").exists());
}

#[test]
fn project_tool_preferences_reject_invalid_references_in_reads_and_edits_without_clearing_sources()
{
    let root = temporary_root("invalid-tool-preferences");
    fs::create_dir_all(&root).unwrap();
    struct Cleanup(PathBuf);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    let _cleanup = Cleanup(root.clone());
    let invalid = serde_json::json!({"version":1,"workspace":{"tools":{"dev.example.runtime:sdk":{"inherit":"workspace"}}}});
    for (command, payload) in [
        (
            "runConfig.projectToolchain",
            serde_json::json!({"root":root,"path":".","localDocument":{"version":2,"configurations":[],"toolchain":{"preferences":invalid}}}),
        ),
        (
            "runConfig.updateOptions",
            serde_json::json!({"root":root,"scope":"local","configurationId":"","localDocument":{"version":2,"configurations":[]},"toolchain":{"preferences":invalid}}),
        ),
    ] {
        let reply: Value = serde_json::from_str(&execute_json(
            &serde_json::json!({"id":"invalid-preferences","command":command,"payload":payload})
                .to_string(),
        ))
        .unwrap();
        assert_eq!(reply["ok"], false, "{reply}");
        assert!(reply["data"].is_null());
    }
    assert!(!root.join(".lithe/run/local.json").exists());
}

/// Native editors format exact argv without shell expansion; an empty quoted
/// item must survive the common document mutation path on both platforms.
#[test]
fn argument_editor_text_roundtrips_the_shared_argv_fixture() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../shared/fixtures/run-configuration/argument-text.json"
    ))
    .unwrap();
    let root = temporary_root("run-argument-text");
    fs::create_dir_all(&root).unwrap();
    struct Cleanup(PathBuf);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    let _cleanup = Cleanup(root.clone());
    let document = serde_json::json!({"version":2,"configurations":[{"id":"user:arguments","name":"Arguments",
        "provider":"build.provider","execution":"task","extensions":{"build":{"pluginID":"dev.example.engine",
        "buildSystemID":"engine","root":".","run":"task","projectID":"project","targetID":"target","execution":"task"}}}]});
    for case in fixture["cases"].as_array().unwrap() {
        let reply: Value = serde_json::from_str(&execute_json(&serde_json::json!({"id":"argument-text","command":"runConfig.updateOptions",
            "payload":{"root":root,"scope":"local","configurationId":"user:arguments","localDocument":document,"arguments":case["text"]}}).to_string())).unwrap();
        assert_eq!(reply["ok"], true, "{reply}");
        let result: Value =
            serde_json::from_str(reply["data"]["document"].as_str().unwrap()).unwrap();
        assert_eq!(result["configurations"][0]["args"], case["values"]);
    }
    assert!(!root.join(".lithe/run/local.json").exists());
}

#[test]
fn resolve_prefers_a_host_provided_local_document() {
    let root = temporary_root("run-config-host-local");
    fs::create_dir_all(root.join(".lithe/run")).unwrap();
    seed_generated(
        &root,
        r#"{"version":2,"configurations":[{"id":"current-file","name":"Current File","provider":"java.current-file","execution":"application","toolchains":{"java":"project-jdk"}}]}"#,
    );
    fs::write(
        root.join(".lithe/run/local.json"),
        r#"{"version":2,"configurations":[{"id":"current-file","name":"Project Local","provider":"java.current-file","cwd":"."}]}"#,
    )
    .unwrap();

    let resolve: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "resolve-host-local",
            "command": "runConfig.resolve",
            "payload": {
                "root": root,
                "localDocument": {
                    "version": 2,
                    "configurations": [{
                        "id": "current-file",
                        "name": "This PC",
                        "provider": "java.current-file",
                        "cwd": "."
                    }]
                }
            }
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(resolve["ok"], true, "{resolve}");
    let current = resolve["data"]["configurations"]
        .as_array()
        .unwrap()
        .iter()
        .find(|value| value["id"] == "current-file")
        .unwrap();
    assert_eq!(current["name"], "This PC");

    // A legacy v1 local layer supplied by the host migrates like the on-disk
    // document, so an old `.lithe/run/local.json` read by the adapter still works.
    let legacy: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "resolve-host-local-v1",
            "command": "runConfig.resolve",
            "payload": {
                "root": root,
                "localDocument": {
                    "version": 1,
                    "configurations": [{
                        "id": "current-file",
                        "name": "Legacy This PC",
                        "type": "java.current-file",
                        "programArguments": ["--dev"]
                    }]
                }
            }
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(legacy["ok"], true, "{legacy}");
    let legacy_current = legacy["data"]["configurations"]
        .as_array()
        .unwrap()
        .iter()
        .find(|value| value["id"] == "current-file")
        .unwrap();
    assert_eq!(legacy_current["name"], "Legacy This PC");

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn editor_save_updates_generic_local_toolchains_without_dropping_other_entries() {
    let root = temporary_root("run-config-editor-runtime-toolchain");
    fs::create_dir_all(root.join(".lithe/run")).unwrap();
    fs::create_dir_all(root.join(".lithe/toolchains")).unwrap();
    fs::create_dir_all(root.join("web")).unwrap();
    seed_generated(
        &root,
        r#"{"version":2,"configurations":[{"id":"npm:dev","name":"dev","provider":"npm.script","execution":"service","command":"npm","args":["run","dev"],"cwd":"web","toolchains":{"runtime":"project-node"}}]}"#,
    );
    fs::write(
        root.join(".lithe/toolchains/local.json"),
        r#"{"version":1,"toolchains":{"project-go":{"executable":"C:/Go/bin/go.exe"}}}"#,
    )
    .unwrap();

    let save = |node_path: &str| -> Value {
        serde_json::from_str(&execute_json(
            &serde_json::json!({
                "id": "save-runtime-toolchain",
                "command": "runConfig.saveEditorChanges",
                "payload": {
                    "root": root,
                    "scope": "local",
                    "configurationId": "npm:dev",
                    "workingDirectory": "web",
                    "toolchain": {
                        "runtimeExecutablePaths": {"project-node": node_path}
                    }
                }
            })
            .to_string(),
        ))
        .unwrap()
    };

    let saved = save("C:/Program Files/nodejs/node.exe");
    assert_eq!(saved["ok"], true, "{saved}");
    let toolchains: Value =
        serde_json::from_str(saved["data"]["toolchainDocument"].as_str().unwrap()).unwrap();
    assert_eq!(
        toolchains["toolchains"]["project-node"]["executable"],
        "C:/Program Files/nodejs/node.exe"
    );
    assert_eq!(
        toolchains["toolchains"]["project-go"]["executable"],
        "C:/Go/bin/go.exe"
    );
    fs::write(
        root.join(".lithe/toolchains/local.json"),
        saved["data"]["toolchainDocument"].as_str().unwrap(),
    )
    .unwrap();

    let removed = save("");
    let removed_toolchains: Value =
        serde_json::from_str(removed["data"]["toolchainDocument"].as_str().unwrap()).unwrap();
    assert!(removed_toolchains["toolchains"]
        .get("project-node")
        .is_none());
    assert_eq!(
        removed_toolchains["toolchains"]["project-go"]["executable"],
        "C:/Go/bin/go.exe"
    );

    let inspected: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "inspect-runtime-toolchain",
            "command": "runConfig.inspect",
            "payload": {"root": root}
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(
        inspected["data"]["localToolchains"]["toolchains"]["project-node"]["executable"],
        "C:/Program Files/nodejs/node.exe"
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn run_configuration_inspect_reports_malformed_and_unsupported_documents() {
    let root = temporary_root("run-config-errors");
    fs::create_dir_all(root.join(".lithe/run")).unwrap();
    fs::write(root.join(".lithe/run/configurations.json"), "{").unwrap();

    let inspect = |id: &str| -> Value {
        serde_json::from_str(&execute_json(
            &serde_json::json!({
                "id": id,
                "command": "runConfig.inspect",
                "payload": {"root": root}
            })
            .to_string(),
        ))
        .unwrap()
    };
    let malformed = inspect("malformed");
    assert_eq!(malformed["ok"], false);
    assert_eq!(malformed["error"]["code"], "parse_failed");

    fs::write(
        root.join(".lithe/run/configurations.json"),
        r#"{"version":3,"configurations":[]}"#,
    )
    .unwrap();
    let unsupported = inspect("unsupported");
    assert_eq!(unsupported["ok"], false);
    assert_eq!(unsupported["error"]["code"], "not_supported");
    assert!(unsupported["error"]["details"]
        .as_str()
        .unwrap()
        .contains("found 3"));

    fs::write(
        root.join(".lithe/run/configurations.json"),
        r#"{"version":1,"configurations":[]}"#,
    )
    .unwrap();
    fs::create_dir_all(root.join(".lithe/toolchains")).unwrap();
    fs::write(root.join(".lithe/toolchains/local.json"), "{").unwrap();
    let malformed_toolchains = inspect("malformed-toolchains");
    assert_eq!(malformed_toolchains["ok"], false);
    assert_eq!(malformed_toolchains["error"]["code"], "parse_failed");
    assert!(malformed_toolchains["error"]["message"]
        .as_str()
        .unwrap()
        .contains(".lithe/toolchains/local.json"));

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn run_configuration_inspection_summarizes_changed_inputs() {
    let root = temporary_root("run-config-input-summary");
    fs::create_dir_all(root.join("src")).unwrap();
    fs::write(root.join("src/App.java"), "class App {}").unwrap();
    fs::write(root.join("package.json"), r#"{"name":"demo"}"#).unwrap();
    let generated = generate_run_configuration(&root, &["src/App.java"], None);
    let generated_again = generate_run_configuration(&root, &["src/App.java"], None);
    assert_eq!(generated, generated_again);
    write_generated_run_document(&root, &generated);
    fs::write(root.join("package.json"), r#"{"name":"renamed"}"#).unwrap();

    let inspected = inspect_run_configuration(&root, None);
    assert_eq!(
        inspected["diagnostics"][0]["message"],
        "Project inputs changed: 0 added, 0 removed, 1 modified"
    );

    fs::remove_dir_all(root).unwrap();
}

fn generate_run_configuration(
    root: &std::path::Path,
    paths: &[&str],
    java_entrypoints: Option<Value>,
) -> Value {
    let mut payload = serde_json::json!({ "root": root, "paths": paths, "modulePaths": [] });
    if let Some(entrypoints) = java_entrypoints {
        payload["javaEntrypoints"] = entrypoints;
    }
    let response: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({ "id": "generate", "command": "runConfig.generate", "payload": payload })
            .to_string(),
    ))
    .unwrap();
    assert_eq!(response["ok"], true, "{response}");
    response["data"]["generated"].clone()
}

fn write_generated_run_document(root: &std::path::Path, generated: &Value) {
    fs::create_dir_all(root.join(".lithe/run")).unwrap();
    seed_generated(&root, serde_json::to_string(generated).unwrap());
}

fn inspect_run_configuration(root: &std::path::Path, java_entrypoints: Option<Value>) -> Value {
    let mut payload = serde_json::json!({ "root": root });
    if let Some(entrypoints) = java_entrypoints {
        payload["javaEntrypoints"] = entrypoints;
    }
    let response: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({ "id": "inspect", "command": "runConfig.inspect", "payload": payload })
            .to_string(),
    ))
    .unwrap();
    assert_eq!(response["ok"], true, "{response}");
    response["data"].clone()
}

#[test]
fn run_configuration_resolve_matches_toolchains_and_rejects_unsafe_paths() {
    let root = temporary_root("run-config-toolchain-resolution");
    fs::create_dir_all(root.join(".lithe/run")).unwrap();
    fs::create_dir_all(root.join(".lithe/toolchains")).unwrap();
    seed_generated(
        &root,
        r#"{"version":1,"configurations":[{"id":"current-file","name":"Current File","type":"java.current-file","toolchains":{"java":"project-jdk"}}]}"#,
    );
    seed_requirements(
        &root,
        r#"{"version":1,"toolchains":{"project-jdk":{"type":"java","minimumVersion":"21","preferredVendor":"temurin"}}}"#,
    );

    let resolve = |version: &str, vendor: &str| -> Value {
        serde_json::from_str(&execute_json(
            &serde_json::json!({
                "id": "resolve-toolchains",
                "command": "runConfig.resolve",
                "payload": {
                    "root": root,
                    "toolchainCandidates": [{
                        "id": "project-jdk",
                        "type": "java",
                        "version": version,
                        "vendor": vendor
                    }]
                }
            })
            .to_string(),
        ))
        .unwrap()
    };
    let mismatch = resolve("17.0.12", "Zulu");
    assert!(mismatch["data"]["diagnostics"]
        .as_array()
        .unwrap()
        .iter()
        .any(|value| value["code"] == "toolchainVersionMismatch"));
    assert!(mismatch["data"]["diagnostics"]
        .as_array()
        .unwrap()
        .iter()
        .any(|value| value["code"] == "toolchainVendorMismatch"));

    let matching = resolve("21.0.5", "Eclipse Temurin");
    assert!(matching["data"]["diagnostics"]
        .as_array()
        .unwrap()
        .is_empty());

    fs::write(
        root.join(".lithe/run/local.json"),
        r#"{"version":1,"configurations":[{"id":"current-file","workingDirectory":"../outside"}]}"#,
    )
    .unwrap();
    let unsafe_path = resolve("21.0.5", "Eclipse Temurin");
    assert_eq!(unsafe_path["ok"], false);
    assert_eq!(unsafe_path["error"]["code"], "invalid_request");

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn legacy_v2_runtime_requirements_are_reconciled_without_regeneration() {
    let root = temporary_root("run-config-legacy-runtime-consumption");
    fs::create_dir_all(root.join(".lithe/run")).unwrap();
    fs::create_dir_all(root.join(".lithe/toolchains")).unwrap();
    fs::create_dir_all(root.join("web")).unwrap();
    fs::create_dir_all(root.join("bun-web")).unwrap();
    seed_generated(
        &root,
        r#"{"version":2,"configurations":[
            {"id":"spring","name":"backend","provider":"spring-boot.maven","execution":"service","cwd":".","toolchains":{"java":"project-jdk","maven":"project-maven"}},
            {"id":"npm","name":"web","provider":"npm.script","execution":"service","command":"npm","args":["run","dev"],"cwd":"web","toolchains":{}},
            {"id":"bun","name":"bun web","provider":"npm.script","execution":"service","command":"bun","args":["run","dev"],"cwd":"bun-web","toolchains":{"runtime":"project-node"}}
        ]}"#,
    );
    seed_requirements(
        &root,
        r#"{"version":1,"toolchains":{
            "project-jdk":{"type":"java"},
            "project-maven":{"type":"maven","java":"project-jdk"},
            "project-node":{"type":"node","minimumVersion":"22"}
        }}"#,
    );

    let resolved: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "resolve-legacy-runtime-consumption",
            "command": "runConfig.resolve",
            "payload": {
                "root": root,
                "toolchainCandidates": [
                    {"id":"project-jdk","type":"java","version":"21","vendor":"Temurin"},
                    {"id":"project-maven","type":"maven","version":"3.9.9","vendor":""}
                ]
            }
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(resolved["ok"], true, "{resolved}");
    let node_diagnostics = resolved["data"]["diagnostics"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|diagnostic| diagnostic["toolchain"] == "project-node")
        .collect::<Vec<_>>();
    assert_eq!(node_diagnostics.len(), 1, "{resolved}");
    assert_eq!(node_diagnostics[0]["id"], "npm");
    let configurations = resolved["data"]["configurations"].as_array().unwrap();
    assert_eq!(
        configurations
            .iter()
            .find(|configuration| configuration["id"] == "npm")
            .unwrap()["toolchains"]["runtime"],
        "project-node"
    );
    assert!(configurations
        .iter()
        .find(|configuration| configuration["id"] == "bun")
        .unwrap()["toolchains"]["runtime"]
        .is_null());

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn shared_run_configuration_fixtures_have_the_versioned_contract_shape() {
    let directory =
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../shared/fixtures/run-configuration");
    let mut fixture_count = 0;
    for entry in fs::read_dir(directory).unwrap() {
        let path = entry.unwrap().path();
        if path.extension().and_then(|value| value.to_str()) != Some("json") {
            continue;
        }
        fixture_count += 1;
        let value: Value = serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
        assert_eq!(value["version"], 1, "{}", path.display());
        assert!(value["expected"].is_object(), "{}", path.display());
        if let Some(generated) = value.get("generated") {
            assert!(generated["version"].is_number(), "{}", path.display());
            assert!(generated["configurations"].is_array(), "{}", path.display());
        }
    }
    assert!(fixture_count >= 6);
}

#[test]
fn shared_hybrid_fixture_executes_scoped_toolchain_expectations() {
    let fixture_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../shared/fixtures/run-configuration/hybrid-spring-vue.json");
    let fixture: Value = serde_json::from_str(&fs::read_to_string(fixture_path).unwrap()).unwrap();
    let root = temporary_root("run-config-hybrid-fixture");
    fs::create_dir_all(root.join(".lithe/run")).unwrap();
    fs::create_dir_all(root.join(".lithe/toolchains")).unwrap();
    seed_generated(&root, serde_json::to_string(&fixture["generated"]).unwrap());
    seed_requirements(
        &root,
        serde_json::to_string(&fixture["requirements"]).unwrap(),
    );

    let resolved: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "resolve-hybrid-fixture",
            "command": "runConfig.resolve",
            "payload": {
                "root": root,
                "toolchainCandidates": [
                    {"id":"project-jdk","type":"java","version":"21","vendor":"Temurin"},
                    {"id":"project-maven","type":"maven","version":"3.9.9","vendor":""}
                ]
            }
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(resolved["ok"], true, "{resolved}");
    let missing_node_ids = resolved["data"]["diagnostics"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|diagnostic| diagnostic["toolchain"] == "project-node")
        .filter_map(|diagnostic| diagnostic["id"].as_str())
        .collect::<Vec<_>>();
    assert_eq!(
        missing_node_ids,
        fixture["expected"]["missingNodeDiagnosticConfigurationIds"]
            .as_array()
            .unwrap()
            .iter()
            .filter_map(Value::as_str)
            .collect::<Vec<_>>()
    );
    for id in fixture["expected"]["unblockedConfigurationIds"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(Value::as_str)
    {
        assert!(resolved["data"]["diagnostics"]
            .as_array()
            .unwrap()
            .iter()
            .all(|diagnostic| diagnostic["id"] != id));
    }

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn shared_editor_save_fixture_executes_the_document_contract() {
    let fixture_path = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../../shared/fixtures/run-configuration/editor-save.json");
    let fixture: Value = serde_json::from_str(&fs::read_to_string(fixture_path).unwrap()).unwrap();
    let root = temporary_root("run-config-editor-fixture");
    fs::create_dir_all(root.join(".lithe/run")).unwrap();
    fs::create_dir_all(root.join("backend")).unwrap();
    seed_generated(
        &root,
        r#"{"version":2,"configurations":[{"id":"spring","name":"Spring","provider":"spring-boot.maven","execution":"service","toolchains":{"java":"project-jdk","maven":"project-maven"},"extensions":{"maven":{"module":"."}}}]}"#,
    );

    let mut request = fixture["request"].clone();
    request["payload"]["root"] = serde_json::json!(root);
    let response: Value = serde_json::from_str(&execute_json(&request.to_string())).unwrap();

    assert_eq!(response["ok"], true, "{response}");
    for (key, expected_type) in fixture["expected"].as_object().unwrap() {
        assert_eq!(
            expected_type, "string",
            "Unsupported fixture expectation for {key}"
        );
        assert!(response["data"][key].is_string(), "{key}: {response}");
    }
    fs::remove_dir_all(root).unwrap();
}

/// `project.json` and the toolchain files sit under `.lithe` and carry their
/// own `version: 1`, unrelated to the run-configuration schema. Migration
/// must not touch them, or resolve rejects a perfectly valid project.
#[test]
fn migration_leaves_sidecar_documents_at_their_own_version() {
    let root = temporary_root("run-config-sidecar");
    fs::create_dir_all(root.join(".lithe/run")).unwrap();
    fs::create_dir_all(root.join(".lithe/toolchains")).unwrap();
    seed_generated(
        &root,
        r#"{"version":1,"configurations":[{"id":"current-file","name":"Current File","type":"java.current-file"}]}"#,
    );
    fs::write(
        root.join(".lithe/project.json"),
        r#"{"version":1,"defaultRunConfiguration":"current-file"}"#,
    )
    .unwrap();
    seed_requirements(&root, r#"{"version":1,"toolchains":{}}"#);

    let resolved: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "sidecar",
            "command": "runConfig.resolve",
            "payload": {"root": root}
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(resolved["ok"], true, "{resolved}");
    assert_eq!(resolved["data"]["version"], 2);
    assert_eq!(resolved["data"]["defaultRunConfiguration"], "current-file");

    fs::remove_dir_all(root).unwrap();
}

/// A non-Java service must reach a launch plan without acquiring a Java
/// toolchain or a JAVA_HOME it has no use for.
#[test]
fn process_configurations_launch_without_java_assumptions() {
    let root = temporary_root("run-config-process");
    fs::create_dir_all(root.join(".lithe/run")).unwrap();
    fs::create_dir_all(root.join("frontend")).unwrap();
    seed_generated(
        &root,
        r#"{"version":2,"configurations":[{
            "id":"npm:dev",
            "name":"web dev",
            "provider":"npm.script",
            "execution":"service",
            "confidence":"declared",
            "command":"npm",
            "args":["run","dev"],
            "cwd":"frontend",
            "env":{"PORT":"3000"},
            "toolchains":{}
        }]}"#,
    );

    let plan: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "process-plan",
            "command": "runConfig.createLaunchPlan",
            "payload": {"root": root, "configurationId": "npm:dev"}
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(plan["ok"], true, "{plan}");
    assert_eq!(plan["data"]["executable"]["command"], "npm");
    assert!(plan["data"]["executable"]["toolchain"].is_null());
    assert_eq!(plan["data"]["arguments"], serde_json::json!(["run", "dev"]));
    assert_eq!(plan["data"]["workingDirectory"], "frontend");
    assert_eq!(plan["data"]["env"]["PORT"], "3000");
    assert!(plan["data"]["environment"]["JAVA_HOME"].is_null());

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn toolchain_backed_process_uses_the_generic_runtime_binding() {
    let root = temporary_root("run-config-go-toolchain");
    fs::create_dir_all(root.join(".lithe/run")).unwrap();
    seed_generated(
        &root,
        r#"{"version":2,"configurations":[{
            "id":"go:api","name":"Go API","provider":"go.main",
            "execution":"application","args":["run","./cmd/api"],"cwd":".",
            "env":{"APP_ENV":"dev"},"toolchains":{"runtime":"project-go"}
        }]}"#,
    );

    let plan: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "go-toolchain-plan",
            "command": "runConfig.createLaunchPlan",
            "payload": {"root": root, "configurationId": "go:api"}
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(plan["ok"], true, "{plan}");
    assert_eq!(plan["data"]["executable"]["toolchain"], "project-go");
    assert!(plan["data"]["executable"]["command"].is_null());
    assert_eq!(
        plan["data"]["arguments"],
        serde_json::json!(["run", "./cmd/api"])
    );
    assert_eq!(plan["data"]["env"]["APP_ENV"], "dev");
    assert!(plan["data"]["environment"]["JAVA_HOME"].is_null());

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn pure_go_generation_does_not_require_java_or_add_java_current_file() {
    let root = temporary_root("pure-go-no-jdk");
    fs::create_dir_all(&root).unwrap();
    fs::write(root.join("go.mod"), "module example.com/api\n\ngo 1.24\n").unwrap();
    fs::write(root.join("main.go"), "package main\nfunc main() {}\n").unwrap();

    let generated: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "generate-pure-go",
            "command": "runConfig.generate",
            "payload": {"root": root, "paths": ["go.mod", "main.go"], "modulePaths": []}
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(generated["ok"], true, "{generated}");
    let configurations = generated["data"]["generated"]["configurations"]
        .as_array()
        .unwrap();
    assert!(configurations
        .iter()
        .any(|value| value["provider"] == "go.main"));
    assert!(!configurations
        .iter()
        .any(|value| value["id"] == "current-file"));
    assert!(generated["data"]["toolchainRequirements"]["toolchains"]["project-jdk"].is_null());

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn multi_language_generation_declares_only_consumed_runtime_requirements() {
    let root = temporary_root("generic-toolchain-requirements");
    for directory in ["python", "web", "worker/src"] {
        fs::create_dir_all(root.join(directory)).unwrap();
    }
    fs::write(root.join("go.mod"), "module example.com/api\n\ngo 1.24\n").unwrap();
    fs::write(root.join("main.go"), "package main\nfunc main() {}\n").unwrap();
    fs::write(
        root.join("python/pyproject.toml"),
        "[project]\nname = \"api\"\nrequires-python = \">=3.12\"\n[project.scripts]\napi = \"api:main\"\n",
    )
    .unwrap();
    fs::write(
        root.join("web/package.json"),
        r#"{"engines":{"node":">=22.4"},"scripts":{"dev":"vite"}}"#,
    )
    .unwrap();
    fs::write(
        root.join("worker/Cargo.toml"),
        "[package]\nname = \"worker\"\nversion = \"0.1.0\"\nrust-version = \"1.82\"\n",
    )
    .unwrap();
    fs::write(root.join("worker/src/main.rs"), "fn main() {}\n").unwrap();

    let generated: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "generate-generic-requirements",
            "command": "runConfig.generate",
            "payload": {"root": root}
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(generated["ok"], true, "{generated}");
    let requirements = &generated["data"]["toolchainRequirements"]["toolchains"];
    assert_eq!(
        requirements["project-node"]["type"], "node",
        "{requirements}"
    );
    assert_eq!(
        requirements["project-node"]["minimumVersion"], "22.4",
        "{requirements}"
    );
    for id in ["project-go", "project-python", "project-cargo"] {
        assert!(requirements[id].is_null(), "{id}: {requirements}");
    }
    assert!(requirements["project-jdk"].is_null(), "{requirements}");
    for provider in ["go.main", "python.script", "cargo.binary"] {
        let configuration = generated["data"]["generated"]["configurations"]
            .as_array()
            .unwrap()
            .iter()
            .find(|configuration| configuration["provider"] == provider)
            .unwrap();
        assert!(configuration["toolchains"].as_object().unwrap().is_empty());
    }

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn unknown_provider_without_an_executable_never_falls_into_maven() {
    let root = temporary_root("run-config-unknown-provider");
    fs::create_dir_all(root.join(".lithe/run")).unwrap();
    seed_generated(
        &root,
        r#"{"version":2,"configurations":[{
            "id":"zig:app","name":"Zig App","provider":"zig.main",
            "args":[],"cwd":".","toolchains":{}
        }]}"#,
    );
    let plan: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "unknown-provider-plan",
            "command": "runConfig.createLaunchPlan",
            "payload": {"root": root, "configurationId": "zig:app"}
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(plan["ok"], false, "{plan}");
    assert_eq!(plan["error"]["code"], "invalid_request");
    assert!(plan["error"]["message"]
        .as_str()
        .unwrap_or("")
        .contains("command or runtime toolchain"));

    fs::remove_dir_all(root).unwrap();
}

/// Generic editor options must patch the common process shape. Writing
/// them into extensions.maven makes the UI appear to save successfully
/// while Go/Python/Node launch plans continue using the old arguments.
#[test]
fn process_options_update_common_arguments_and_environment() {
    let root = temporary_root("run-config-process-options");
    fs::create_dir_all(root.join(".lithe/run")).unwrap();
    fs::create_dir_all(root.join("backend")).unwrap();
    seed_generated(
        &root,
        r#"{"version":2,"configurations":[{
            "id":"python:api","name":"API","provider":"python.script",
            "command":"python3","args":["app.py"],"cwd":".","toolchains":{}
        }]}"#,
    );

    let updated: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "update-process-options",
            "command": "runConfig.updateOptions",
            "payload": {
                "root": root,
                "scope": "local",
                "configurationId": "python:api",
                "workingDirectory": "backend",
                "arguments": "app.py --port 9000",
                "environment": {"APP_ENV": "test"}
            }
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(updated["ok"], true, "{updated}");
    let document: Value = serde_json::from_str(
        updated["data"]["document"]
            .as_str()
            .expect("document string"),
    )
    .unwrap();
    let patch = &document["configurations"][0];
    assert_eq!(
        patch["args"],
        serde_json::json!(["app.py", "--port", "9000"])
    );
    assert_eq!(patch["env"]["APP_ENV"], "test");
    assert!(patch["extensions"]["maven"].is_null());

    fs::write(
        root.join(".lithe/run/local.json"),
        updated["data"]["document"].as_str().unwrap(),
    )
    .unwrap();
    let plan: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "updated-process-plan",
            "command": "runConfig.createLaunchPlan",
            "payload": {"root": root, "configurationId": "python:api"}
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(plan["ok"], true, "{plan}");
    assert_eq!(
        plan["data"]["arguments"],
        serde_json::json!(["app.py", "--port", "9000"])
    );
    assert_eq!(plan["data"]["env"]["APP_ENV"], "test");

    fs::remove_dir_all(root).unwrap();
}

/// An absolute or relative path would let a project manifest point the IDE
/// at an executable of its choosing. Commands resolve on PATH only.
#[test]
fn process_configurations_reject_path_qualified_commands() {
    let root = temporary_root("run-config-process-path");
    fs::create_dir_all(root.join(".lithe/run")).unwrap();
    seed_generated(
        &root,
        r#"{"version":2,"configurations":[{
            "id":"evil","name":"evil","provider":"shell.command",
            "command":"../../../usr/bin/curl","args":[],"cwd":".","toolchains":{}
        }]}"#,
    );

    let plan: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "evil-plan",
            "command": "runConfig.createLaunchPlan",
            "payload": {"root": root, "configurationId": "evil"}
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(plan["ok"], false);
    assert_eq!(plan["error"]["code"], "invalid_request");

    fs::remove_dir_all(root).unwrap();
}

/// Without a default in `.lithe/project.json`, a framework service is chosen
/// before a plain main class; a project default still wins when available.
#[test]
fn resolve_chooses_detected_default_unless_the_project_names_one() {
    let root = temporary_root("run-config-detected-default");
    struct Cleanup(PathBuf);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    let _cleanup = Cleanup(root.clone());
    fs::create_dir_all(&root).unwrap();
    seed_generated(
        &root,
        serde_json::json!({"version": 2, "configurations": [
            {"id": "current-file", "name": "Current File", "provider": "java.current-file",
             "execution": "application", "toolchains": {}},
            {"id": "java-main:demo.Tool", "name": "Tool", "provider": "java.main",
             "execution": "application", "toolchains": {}},
            {"id": "spring-boot.maven:.", "name": "app", "provider": "spring-boot.maven",
             "execution": "service", "toolchains": {}}
        ]}),
    );
    let detected = run_config_command("runConfig.resolve", serde_json::json!({ "root": root }));
    assert_eq!(detected["ok"], true, "{detected}");
    assert_eq!(
        detected["data"]["defaultRunConfiguration"],
        "spring-boot.maven:."
    );

    fs::create_dir_all(root.join(".lithe")).unwrap();
    fs::write(
        root.join(".lithe/project.json"),
        r#"{"version":1,"defaultRunConfiguration":"java-main:demo.Tool"}"#,
    )
    .unwrap();
    let named = run_config_command("runConfig.resolve", serde_json::json!({ "root": root }));
    assert_eq!(
        named["data"]["defaultRunConfiguration"],
        "java-main:demo.Tool"
    );
}

fn run_config_command(command: &str, payload: Value) -> Value {
    serde_json::from_str(&execute_json(
        &serde_json::json!({ "id": command, "command": command, "payload": payload }).to_string(),
    ))
    .unwrap()
}

/// Issue #861: resolution hides a configuration whose `cwd` is missing, so a
/// value that cannot name a project directory is rejected when saved, where
/// the editor shows the error, instead of making the entry vanish. Editor
/// variables are not expanded even when the directory they point at exists.
#[test]
fn working_directory_override_must_name_an_existing_project_directory() {
    let root = temporary_root("run-config-invalid-cwd");
    // The guard also removes the workspace when an assertion fails.
    struct Cleanup(PathBuf);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    let _cleanup = Cleanup(root.clone());
    fs::create_dir_all(root.join(".lithe/run")).unwrap();
    fs::create_dir_all(root.join("backend")).unwrap();
    seed_generated(
        &root,
        r#"{"version":2,"configurations":[{
            "id":"python:api","name":"API","provider":"python.script",
            "command":"python3","args":["app.py"],"cwd":".","toolchains":{}
        }]}"#,
    );

    for (directory, message) in [
        (
            "${workspaceFolder}/backend",
            "Working directory variables are not supported; use a path relative to the project",
        ),
        (
            "$PROJECT_DIR$/backend",
            "Working directory variables are not supported; use a path relative to the project",
        ),
        ("frontend", "Project configuration directory does not exist"),
        (
            "../outside",
            "Project configuration paths must stay inside the project",
        ),
    ] {
        for scope in ["local", "project"] {
            let updated = run_config_command(
                "runConfig.updateOptions",
                serde_json::json!({
                    "root": root, "scope": scope, "configurationId": "python:api",
                    "workingDirectory": directory
                }),
            );
            assert_eq!(updated["ok"], false, "{directory}: {updated}");
            assert_eq!(updated["error"]["code"], "invalid_request");
            assert_eq!(updated["error"]["message"], message, "{directory}");
        }
    }

    let absolute = root.join("backend").canonicalize().unwrap();
    let updated = run_config_command(
        "runConfig.updateOptions",
        serde_json::json!({
            "root": root, "scope": "local", "configurationId": "python:api",
            "workingDirectory": absolute
        }),
    );
    assert_eq!(updated["ok"], true, "{updated}");
    let document: Value =
        serde_json::from_str(updated["data"]["document"].as_str().unwrap()).unwrap();
    assert_eq!(document["configurations"][0]["cwd"], "backend");
}

#[test]
fn java_selection_rejects_ambiguous_or_invalid_host_snapshots() {
    for payload in [
        serde_json::json!({"root":"/unused","requirements":{"version":1,"toolchains":{}},"candidates":[]}),
        serde_json::json!({"requirements":{"version":999,"toolchains":{}},"candidates":[]}),
        serde_json::json!({"requirements":{"toolchains":{}},"candidates":[]}),
    ] {
        let response: Value = serde_json::from_str(&execute_json(
            &serde_json::json!({
                "id":"snapshot","command":"runConfig.selectJava","payload":payload
            })
            .to_string(),
        ))
        .unwrap();
        assert_eq!(response["ok"], false, "{response}");
    }
}

#[test]
fn shared_run_scan_excludes_caches_and_keeps_hidden_sources() {
    let root = temporary_root("shared-run-scan");
    struct Cleanup(PathBuf);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.0).unwrap();
        }
    }
    fs::create_dir_all(&root).unwrap();
    let _cleanup = Cleanup(root.clone());
    // Core scans the workspace itself: cache directories are left out, a hidden
    // source directory stays.
    for path in [
        ".sources/Makefile",
        "src/Makefile",
        ".pytest_cache/Makefile",
        "node_modules/Makefile",
        "target/Makefile",
    ] {
        let file = root.join(path);
        fs::create_dir_all(file.parent().unwrap()).unwrap();
        fs::write(file, "all:\n\ttrue\n").unwrap();
    }
    let call = |command, payload| -> Value {
        let response: Value = serde_json::from_str(&execute_json(
            &serde_json::json!({
                "id": "scan", "command": command, "payload": payload
            })
            .to_string(),
        ))
        .unwrap();
        assert_eq!(response["ok"], true, "{response}");
        response["data"].clone()
    };
    let generated = call("runConfig.generate", serde_json::json!({"root": root}));
    let inputs = generated["generated"]["generator"]["inputs"]
        .as_object()
        .unwrap();
    assert!(inputs.contains_key(".sources/Makefile"));
    assert!(inputs.contains_key("src/Makefile"));
    assert!(!inputs.keys().any(|path| {
        path.starts_with(".pytest_cache/")
            || path.starts_with("node_modules/")
            || path.starts_with("target/")
    }));
    let mut document = generated["generated"].clone();
    // A persisted incomplete baseline cannot certify freshness or infer deletion,
    // even after the previously inaccessible directory becomes readable again.
    document["generator"]["unreadablePaths"] = serde_json::json!(["blocked"]);
    fs::create_dir_all(root.join(".lithe/run")).unwrap();
    seed_generated(&root, document.to_string());
    for full in [false, true] {
        let inspected = call(
            "runConfig.inspect",
            serde_json::json!({"root": root, "checkFingerprint": full}),
        );
        assert_eq!(inspected["status"], "ready");
        assert!(inspected["diagnostics"]
            .as_array()
            .unwrap()
            .iter()
            .any(|d| d["code"] == "incompleteProjectScan"));
        assert!(!inspected["diagnostics"]
            .as_array()
            .unwrap()
            .iter()
            .any(|d| d["code"] == "staleFingerprint"));
    }
}

/// Saving a selector never stores an executable, generates a model, or loses local defaults.
#[test]
fn build_provider_configurations_persist_before_generation_and_reuse_identity() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../shared/fixtures/run-configuration/build-provider.json"
    ))
    .unwrap();
    let root = temporary_root("saved-build-provider");
    fs::create_dir_all(root.join("app")).unwrap();
    struct Cleanup(PathBuf);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    let _cleanup = Cleanup(root.clone());
    fs::create_dir_all(root.join(".lithe/run")).unwrap();
    let local = root.join(".lithe/run/local.json");
    fs::write(&local, fixture["unrelated"].to_string()).unwrap();
    let call = |command: &str, payload: Value| -> Value {
        serde_json::from_str(&execute_json(
            &serde_json::json!({"id":"saved-provider","command":command,"payload":payload})
                .to_string(),
        ))
        .unwrap()
    };
    let save = |reference: Value| {
        call(
            "runConfig.createUserConfiguration",
            serde_json::json!({"root":root,"scope":"local","type":"buildProvider","name":fixture["name"],"build":reference}),
        )
    };
    let saved = save(fixture["reference"].clone());
    assert_eq!(saved["ok"], true, "{saved}");
    let mut document: Value =
        serde_json::from_str(saved["data"]["document"].as_str().unwrap()).unwrap();
    assert_eq!(document["toolchain"], fixture["unrelated"]["toolchain"]);
    assert_eq!(
        document["configurations"][0]["extensions"]["build"],
        fixture["reference"]
    );
    assert!(document["configurations"][0].get("command").is_none());
    // The Core mutation is read-only until the platform atomically commits it.
    assert_eq!(
        serde_json::from_slice::<Value>(&fs::read(&local).unwrap()).unwrap(),
        fixture["unrelated"]
    );
    document["configurations"][0]["extensions"]["annotations"] =
        serde_json::json!({"label":"keep user metadata"});
    fs::write(&local, document.to_string()).unwrap();
    let inspected = call(
        "runConfig.inspect",
        serde_json::json!({"root":root,"checkFingerprint":false}),
    );
    assert_eq!(
        inspected["data"]["status"], fixture["expected"]["inspectionStatus"],
        "{inspected}"
    );
    assert_eq!(
        inspected["data"]["requiresGeneration"],
        fixture["expected"]["requiresGeneration"]
    );
    let resolved = call(
        "runConfig.resolve",
        serde_json::json!({"root":root,"toolchainCandidates":[]}),
    );
    assert_eq!(resolved["ok"], true, "{resolved}");
    assert_eq!(
        resolved["data"]["configurations"].as_array().unwrap().len(),
        1
    );
    assert!(!root.join(".lithe/run/generated.json").exists());
    let mut changed = fixture["reference"].clone();
    changed["userArguments"] = serde_json::json!(["new argument"]);
    let updated = save(changed);
    assert_eq!(updated["data"]["id"], saved["data"]["id"]);
    let updated_doc: Value =
        serde_json::from_str(updated["data"]["document"].as_str().unwrap()).unwrap();
    assert_eq!(updated_doc["configurations"].as_array().unwrap().len(), 1);
    assert_eq!(
        updated_doc["configurations"][0]["extensions"]["annotations"],
        serde_json::json!({"label":"keep user metadata"})
    );
    for execution in fixture["executionKinds"].as_array().unwrap() {
        let mut reference = fixture["reference"].clone();
        reference["execution"] = execution.clone();
        let saved_kind = save(reference);
        assert_eq!(saved_kind["ok"], true, "{saved_kind}");
        assert_eq!(saved_kind["data"]["id"], saved["data"]["id"]);
        let kind_document: Value =
            serde_json::from_str(saved_kind["data"]["document"].as_str().unwrap()).unwrap();
        assert_eq!(kind_document["configurations"][0]["execution"], *execution);
        fs::write(&local, kind_document.to_string()).unwrap();
        let kind_resolved = call("runConfig.resolve", serde_json::json!({"root":root}));
        assert_eq!(kind_resolved["ok"], true, "{kind_resolved}");
        assert_eq!(
            kind_resolved["data"]["configurations"][0]["execution"],
            *execution
        );
        let inputs = call(
            "runConfig.providerLaunchInputs",
            serde_json::json!({"root":root,"configurationId":saved_kind["data"]["id"],"providerRoot":"app"}),
        );
        assert_eq!(inputs["ok"], true, "{inputs}");
        assert_eq!(inputs["data"]["launchOptions"]["execution"], *execution);
        assert_eq!(inputs["data"]["reference"]["execution"], *execution);
    }
    for (field, value) in [
        ("root", serde_json::json!("../escape")),
        ("root", serde_json::json!("/outside")),
        ("root", serde_json::json!("app\\bad")),
        ("projectID", serde_json::json!("")),
        ("userArguments", serde_json::json!(["bad\u{0}"])),
        ("userArguments", serde_json::json!(vec!["a"; 65])),
        ("command", serde_json::json!("java")),
    ] {
        let mut invalid = fixture["reference"].clone();
        invalid[field] = value;
        assert_eq!(save(invalid)["ok"], false, "{field}");
    }
    let mut omitted_arguments = document.clone();
    omitted_arguments["configurations"][0]["extensions"]["build"]
        .as_object_mut()
        .unwrap()
        .remove("userArguments");
    fs::write(&local, omitted_arguments.to_string()).unwrap();
    let normalized = call("runConfig.resolve", serde_json::json!({"root":root}));
    assert_eq!(normalized["ok"], true, "{normalized}");
    assert_eq!(
        normalized["data"]["configurations"][0]["extensions"]["build"]["userArguments"],
        serde_json::json!([])
    );
    let mut invalid = document.clone();
    invalid["configurations"][0]["command"] = serde_json::json!("java");
    fs::write(&local, invalid.to_string()).unwrap();
    assert_eq!(
        call("runConfig.resolve", serde_json::json!({"root":root}))["ok"],
        false
    );
}

/// Persisted identity and selector identity serve different purposes: imported IDs
/// retain defaults/overrides, while the selector removes only the duplicate auto entry.
#[test]
fn explicit_provider_references_keep_arbitrary_ids_and_shadow_only_current_selector() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../shared/fixtures/run-configuration/build-provider-stable-identities.json"
    ))
    .unwrap();
    let root = temporary_root("provider-stable-identity");
    fs::create_dir_all(root.join("app")).unwrap();
    fs::create_dir_all(root.join(".lithe/run")).unwrap();
    struct Cleanup(PathBuf);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    let _cleanup = Cleanup(root.clone());
    let call = |command: &str, payload: Value| -> Value {
        let reply: Value = serde_json::from_str(&execute_json(
            &serde_json::json!({"id":"stable","command":command,"payload":payload}).to_string(),
        ))
        .unwrap();
        assert_eq!(reply["ok"], true, "{reply}");
        reply["data"].clone()
    };
    let stable = fixture["expected"]["stableID"].clone();
    let reference = fixture["reference"].clone();
    let team = serde_json::json!({"version":2,"configurations":[{"id":stable,"name":"Team service","provider":"build.provider","execution":"service","cwd":"app","extensions":{"build":reference}}]});
    let team_path = root.join(".lithe/run/configurations.json");
    let local_path = root.join(".lithe/run/local.json");
    fs::write(&team_path, team.to_string()).unwrap();
    let inspected = call(
        "runConfig.inspect",
        serde_json::json!({"root":root,"checkFingerprint":false}),
    );
    assert_eq!(inspected["status"], "ready");
    assert_eq!(inspected["requiresGeneration"], true);
    let before = call("runConfig.resolve", serde_json::json!({"root":root}));
    assert_eq!(before["configurations"][0]["id"], stable);
    assert!(before["diagnostics"]
        .as_array()
        .unwrap()
        .iter()
        .all(|d| d["code"] != "orphanedOverride"));
    let mut second = reference.clone();
    second["targetID"] = serde_json::json!("another/opaque-target");
    let generated = call(
        "runConfig.generate",
        serde_json::json!({"root":root,"paths":[],"projectOwnership":[],"providerRuns":[
            {"projectPath":"app","name":"Auto A","reference":reference},{"projectPath":"app","name":"Auto B","reference":second}
        ]}),
    );
    assert_eq!(
        generated["generated"]["configurations"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    fs::write(
        root.join(".lithe/project.json"),
        serde_json::json!({"version":1,"defaultRunConfiguration":stable}).to_string(),
    )
    .unwrap();
    fs::write(
        &local_path,
        serde_json::json!({"version":2,"configurations":[{"id":stable,"env":{"EXAMPLE":"value"}}]})
            .to_string(),
    )
    .unwrap();
    let resolved = call("runConfig.resolve", serde_json::json!({"root":root}));
    let configs = resolved["configurations"].as_array().unwrap();
    assert_eq!(configs.len(), 2);
    assert_eq!(resolved["defaultRunConfiguration"], stable);
    assert_eq!(
        configs
            .iter()
            .filter(|c| c["extensions"]["build"]["targetID"] == reference["targetID"])
            .count(),
        1
    );
    assert!(resolved["diagnostics"]
        .as_array()
        .unwrap()
        .iter()
        .all(|d| d["code"] != "orphanedOverride"));
    // A local selector patch replaces the effective claim; it must not hide
    // the formerly claimed auto target too.
    fs::write(&local_path,serde_json::json!({"version":2,"configurations":[{"id":stable,"extensions":{"build":{"targetID":second["targetID"]}}}]}).to_string()).unwrap();
    let replaced = call("runConfig.resolve", serde_json::json!({"root":root}));
    let configs = replaced["configurations"].as_array().unwrap();
    assert_eq!(configs.len(), 2);
    assert_eq!(
        configs
            .iter()
            .filter(|c| c["extensions"]["build"]["targetID"] == second["targetID"])
            .count(),
        1
    );
    assert_eq!(
        configs
            .iter()
            .filter(|c| c["extensions"]["build"]["targetID"] == reference["targetID"])
            .count(),
        1
    );
    let original_team = fs::read(&team_path).unwrap();
    let original_local = fs::read(&local_path).unwrap();
    let prepared = serde_json::json!({"version":2,"configurations":[{"id":"prepared:stable","name":"Prepared","provider":"build.provider","execution":"service","extensions":{"build":reference}}]});
    let preview = call(
        "runConfig.resolve",
        serde_json::json!({"root":root,"teamDocument":prepared,"localDocument":{"version":2,"configurations":[]}}),
    );
    assert!(preview["configurations"]
        .as_array()
        .unwrap()
        .iter()
        .any(|c| c["id"] == "prepared:stable"));
    assert_eq!(fs::read(&team_path).unwrap(), original_team);
    assert_eq!(fs::read(&local_path).unwrap(), original_local);
    let mut invalid = prepared.clone();
    invalid["configurations"][0]["extensions"]["build-run"] = serde_json::json!({"entrypoint":17});
    let rejected:Value=serde_json::from_str(&execute_json(&serde_json::json!({"id":"invalid","command":"runConfig.resolve","payload":{"root":root,"teamDocument":invalid,"localDocument":{"version":2,"configurations":[]}}}).to_string())).unwrap();
    assert_eq!(rejected["ok"], false);
    assert_eq!(fs::read(&team_path).unwrap(), original_team);
}

/// Portable choices survive document edits without becoming selector identity or cached launch facts.
#[test]
fn provider_run_options_preserve_exact_arguments_and_layered_build_choices() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../shared/fixtures/run-configuration/build-provider-options.json"
    ))
    .unwrap();
    let root = temporary_root("provider-run-options");
    fs::create_dir_all(root.join("app/work")).unwrap();
    fs::create_dir_all(root.join(".lithe/run")).unwrap();
    struct Cleanup(PathBuf);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    let _cleanup = Cleanup(root.clone());
    let call = |command: &str, payload: Value| -> Value {
        let reply: Value = serde_json::from_str(&execute_json(
            &serde_json::json!({"id":"choices","command":command,"payload":payload}).to_string(),
        ))
        .unwrap();
        assert_eq!(reply["ok"], true, "{reply}");
        reply["data"].clone()
    };
    let save = || {
        call(
            "runConfig.createUserConfiguration",
            serde_json::json!({"root":root,"scope":"local","type":"buildProvider","name":"Service","build":fixture["reference"]}),
        )
    };
    let saved = save();
    let id = saved["id"].clone();
    let local_path = root.join(".lithe/run/local.json");
    let team_path = root.join(".lithe/run/configurations.json");
    fs::write(&local_path, saved["document"].as_str().unwrap()).unwrap();
    let team = serde_json::json!({"version":2,"configurations":[{"id":id,"extensions":{"build-run":fixture["choices"]}}]});
    fs::write(&team_path, team.to_string()).unwrap();
    let read = || {
        call(
            "runConfig.providerLaunchInputs",
            serde_json::json!({"root":root,"configurationId":id,"providerRoot":"app"}),
        )
    };
    let initial = read();
    assert_eq!(initial["tools"], fixture["choices"]["tools"]);
    assert!(initial["launchOptions"].get("tools").is_none());
    assert_eq!(
        initial["buildSystemID"],
        fixture["expected"]["buildSystemID"]
    );
    assert_eq!(
        initial["launchOptions"]["execution"],
        fixture["expected"]["execution"]
    );
    assert_eq!(
        initial["launchOptions"]["runtimeArguments"],
        fixture["choices"]["runtimeArguments"]
    );
    assert_eq!(
        initial["launchOptions"]["entrypoint"],
        fixture["choices"]["entrypoint"]
    );
    assert_eq!(initial["optionOverrides"], fixture["choices"]["options"]);
    assert_eq!(
        initial["launchOptions"]["arguments"],
        fixture["reference"]["userArguments"]
    );
    let update = |choices: Option<Value>| {
        let mut payload = serde_json::json!({"root":root,"scope":"local","configurationId":id,
            "arguments":"--application=\"one two\" 雪","environment":fixture["environment"],"workingDirectory":fixture["workingDirectory"]});
        if let Some(choices) = choices {
            payload["providerRunOptions"] = choices;
        }
        call("runConfig.updateOptions", payload)
    };
    let one_tool = update(Some(
        serde_json::json!({"tools":{"dev.example.engine:compiler":fixture["changed"]["tools"]["dev.example.engine:compiler"]}}),
    ));
    fs::write(&local_path, one_tool["document"].as_str().unwrap()).unwrap();
    let inherited = read();
    assert_eq!(
        inherited["tools"]["dev.example.engine:compiler"],
        fixture["changed"]["tools"]["dev.example.engine:compiler"]
    );
    assert_eq!(
        inherited["tools"]["dev.example.engine:vm"],
        fixture["choices"]["tools"]["dev.example.engine:vm"]
    );
    let document = update(Some(fixture["changed"].clone()));
    fs::write(&local_path, document["document"].as_str().unwrap()).unwrap();
    let changed = read();
    assert_eq!(changed["tools"], fixture["expected"]["tools"]);
    let toolchain = call(
        "runConfig.projectToolchain",
        serde_json::json!({"root":root,"path":"app","configurationId":id}),
    );
    assert_eq!(toolchain["definedTools"], changed["tools"]);
    assert!(
        !root.join(".lithe/local.json").exists(),
        "Run choices must not create directory pins"
    );
    assert_eq!(
        changed["launchOptions"]["runtimeArguments"],
        fixture["changed"]["runtimeArguments"]
    );
    assert!(
        changed["launchOptions"].get("entrypoint").is_none(),
        "Explicit empty clears the team entrypoint"
    );
    assert_eq!(
        changed["optionOverrides"],
        serde_json::json!({}),
        "An explicit empty map clears team options"
    );
    assert_eq!(changed["launchOptions"]["arguments"], fixture["arguments"]);
    assert_eq!(
        changed["launchOptions"]["environment"],
        fixture["environment"]
    );
    assert_eq!(
        changed["launchOptions"]["workingDirectory"],
        fixture["workingDirectory"]
    );
    assert_eq!(changed["reference"], fixture["reference"]);
    let omitted = update(None);
    let omitted: Value = serde_json::from_str(omitted["document"].as_str().unwrap()).unwrap();
    assert_eq!(
        omitted["configurations"][0]["extensions"]["build-run"],
        fixture["changed"]
    );
    let resaved = save();
    assert_eq!(resaved["id"], id);
    let resaved: Value = serde_json::from_str(resaved["document"].as_str().unwrap()).unwrap();
    assert_eq!(
        resaved["configurations"][0]["cwd"],
        fixture["workingDirectory"]
    );
    assert_eq!(
        resaved["configurations"][0]["extensions"]["build-run"],
        fixture["changed"]
    );
    assert_eq!(
        serde_json::from_slice::<Value>(&fs::read(&team_path).unwrap()).unwrap(),
        team
    );
    assert!(!root.join(".lithe/run/generated.json").exists());
}

/// Malformed portable choices fail before a provider request; unknown fields cannot smuggle launch facts.
#[test]
fn provider_run_options_reject_malformed_or_oversized_values() {
    let root = temporary_root("provider-run-options-invalid");
    fs::create_dir_all(root.join(".lithe/run")).unwrap();
    struct Cleanup(PathBuf);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    let _cleanup = Cleanup(root.clone());
    let reference = serde_json::json!({"pluginID":"dev.example","buildSystemID":"engine","root":".","run":"serve","projectID":"p","targetID":"t"});
    let local_path = root.join(".lithe/run/local.json");
    for choices in [
        serde_json::json!(null),
        serde_json::json!({"runtimeArguments":null}),
        serde_json::json!({"runtimeArguments":["bad\u{0}"]}),
        serde_json::json!({"runtimeArguments":vec!["a";1025]}),
        serde_json::json!({"runtimeArguments":["a".repeat(65537)]}),
        serde_json::json!({"entrypoint":null}),
        serde_json::json!({"entrypoint":"a".repeat(4097)}),
        serde_json::json!({"options":null}),
        serde_json::json!({"options":{"bad key":true}}),
        serde_json::json!({"options":{"opaque":"a".repeat(65536)}}),
        serde_json::json!({"options":(0..65).map(|n|(format!("key-{n}"),serde_json::json!(false))).collect::<std::collections::BTreeMap<_,_>>()}),
        serde_json::json!({"tools":null}),
        serde_json::json!({"tools":{"bad key":{"home":"/kit"}}}),
        serde_json::json!({"tools":{"dev.example:compiler":{"home":"relative/kit"}}}),
        serde_json::json!({"tools":{"dev.example:compiler":{"executable":"/a/../b"}}}),
        serde_json::json!({"tools":{"dev.example:compiler":{"home":"/kit","executable":"/bin/compiler"}}}),
        serde_json::json!({"tools":{"dev.example:compiler":{"home":"/kit","version":"21"}}}),
        serde_json::json!({"tools":(0..65).map(|n|(format!("dev.example:tool-{n}"),serde_json::json!(null))).collect::<std::collections::BTreeMap<_,_>>()}),
        serde_json::json!({"command":"cached"}),
        serde_json::json!({"debug":{"adapter":"cached"}}),
    ] {
        fs::write(&local_path, serde_json::json!({"version":2,"configurations":[{"id":"user:service","name":"Service","provider":"build.provider","execution":"application","cwd":".","extensions":{"build":reference,"build-run":choices}}]}).to_string()).unwrap();
        let reply: Value = serde_json::from_str(&execute_json(&serde_json::json!({"id":"invalid","command":"runConfig.resolve","payload":{"root":root}}).to_string())).unwrap();
        assert_eq!(reply["ok"], false, "Invalid choice accepted");
    }
    // The mutation port must reject explicit null as well as persisted null,
    // rather than treating malformed input as an omitted legacy field.
    fs::write(&local_path, serde_json::json!({"version":2,"configurations":[{"id":"user:service","name":"Service","provider":"build.provider","execution":"application","cwd":".","extensions":{"build":reference}}]}).to_string()).unwrap();
    for options in [
        serde_json::json!(null),
        serde_json::json!({"runtimeArguments":null}),
        serde_json::json!({"entrypoint":"bad\u{0}"}),
    ] {
        let reply: Value = serde_json::from_str(&execute_json(&serde_json::json!({"id":"invalid-update","command":"runConfig.updateOptions","payload":{"root":root,"scope":"local","configurationId":"user:service","providerRunOptions":options}}).to_string())).unwrap();
        assert_eq!(reply["ok"], false, "Invalid mutation accepted");
    }
}

/// A non-Java provider owns discovery; regenerating labels must retain user choices,
/// while withdrawing a target must not resurrect it from the previous detected layer.
#[test]
fn generic_provider_runs_regenerate_without_language_facts_and_keep_stable_overrides() {
    let root = temporary_root("generic-provider-generation");
    fs::create_dir_all(root.join("app")).unwrap();
    fs::create_dir_all(root.join(".lithe/run")).unwrap();
    struct Cleanup(PathBuf);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    let _cleanup = Cleanup(root.clone());
    let call = |command: &str, payload: Value| -> Value {
        let result: Value = serde_json::from_str(&execute_json(
            &serde_json::json!({"id":"generic","command":command,"payload":payload}).to_string(),
        ))
        .unwrap();
        assert_eq!(result["ok"], true, "{result}");
        result["data"].clone()
    };
    let generate = |runs: Value| {
        call(
            "runConfig.generate",
            serde_json::json!({
                "root":root,"paths":[],"projectOwnership":[],"providerRuns":runs
            }),
        )
    };
    let reference = serde_json::json!({"pluginID":"dev.example.engine","buildSystemID":"engine","root":"app",
        "run":"serve","projectID":"project/opaque:1","targetID":"target/opaque:2","execution":"service","userArguments":[]});
    let mut runs =
        serde_json::json!([{"projectPath":"app","name":"Initial label","reference":reference}]);
    let first = generate(runs.clone());
    let configuration = &first["generated"]["configurations"][0];
    let id = configuration["id"].clone();
    assert_eq!(configuration["provider"], "build.provider");
    assert!(configuration["toolchains"].as_object().unwrap().is_empty());
    assert!(configuration["extensions"].get("maven").is_none());
    fs::write(
        root.join(".lithe/run/local.json"),
        serde_json::json!({"version":2,"configurations":[
            {"id":id,"env":{"EXAMPLE":"preserved"},"args":["user choice"],"cwd":"app"}
        ]})
        .to_string(),
    )
    .unwrap();
    let resolved = call("runConfig.resolve", serde_json::json!({"root":root}));
    assert_eq!(resolved["defaultRunConfiguration"], id);
    runs[0]["name"] = serde_json::json!("Renamed upstream label");
    runs[0]["reference"]["execution"] = serde_json::json!("task");
    let renamed = generate(runs.clone());
    assert_eq!(renamed["generated"]["configurations"][0]["id"], id);
    assert_ne!(
        renamed["generated"]["generator"]["providerRunFingerprint"],
        first["generated"]["generator"]["providerRunFingerprint"]
    );
    let inputs = call(
        "runConfig.providerLaunchInputs",
        serde_json::json!({"root":root,"configurationId":id,"providerRoot":"app"}),
    );
    assert_eq!(inputs["launchOptions"]["execution"], "task");
    assert_eq!(inputs["launchOptions"]["workingDirectory"], "app");
    assert_eq!(
        inputs["launchOptions"]["arguments"],
        serde_json::json!(["user choice"])
    );
    assert_eq!(
        inputs["launchOptions"]["environment"],
        serde_json::json!({"EXAMPLE":"preserved"})
    );
    let withdrawn = generate(serde_json::json!([]));
    assert!(!withdrawn["generated"]["configurations"]
        .as_array()
        .unwrap()
        .iter()
        .any(|item| item["id"] == id));
    let resolved = call("runConfig.resolve", serde_json::json!({"root":root}));
    assert!(resolved["diagnostics"]
        .as_array()
        .unwrap()
        .iter()
        .any(|item| item["code"] == "orphanedOverride" && item["id"] == id));
    assert!(!resolved["configurations"]
        .as_array()
        .unwrap()
        .iter()
        .any(|item| item["id"] == id));
    let restored = generate(runs);
    assert_eq!(restored["generated"]["configurations"][0]["id"], id);
    let inputs = call(
        "runConfig.providerLaunchInputs",
        serde_json::json!({"root":root,"configurationId":id,"providerRoot":"app"}),
    );
    assert_eq!(
        inputs["launchOptions"]["arguments"],
        serde_json::json!(["user choice"])
    );
    assert!(!root.join(".lithe/run/generated.json").exists());
}

/// Providers receive saved typed choices; Core does not assemble a Maven goal or reread its POM.
#[test]
fn provider_launch_inputs_preserve_document_layers_and_current_selector() {
    let root = temporary_root("provider-launch-inputs");
    fs::create_dir_all(root.join(".lithe/run")).unwrap();
    fs::create_dir_all(root.join("nested/app")).unwrap();
    fs::create_dir_all(root.join("tools")).unwrap();
    struct Cleanup(PathBuf);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            fs::remove_dir_all(&self.0).unwrap();
        }
    }
    let _cleanup = Cleanup(root.clone());
    fs::write(root.join("nested/pom.xml"), "deliberately not a POM").unwrap();
    let generated = serde_json::json!({"version":2,"configurations":[{"id":"service","name":"Service","provider":"build.provider","execution":"service",
        "cwd":"nested","env":{},"extensions":{"build":{"pluginID":"dev.example.engine","buildSystemID":"engine","root":"nested","run":"serve",
        "projectID":"project","targetID":"target","execution":"service"},"build-run":{"runtimeArguments":["--message=base value"]}}}]});
    seed_generated(&root, generated.to_string());
    let local = serde_json::json!({"version":2,"configurations":[{"id":"service","cwd":"tools","env":{"EXAMPLE":"value"},
        "args":["a b","雪",""],"extensions":{"build-run":{"runtimeArguments":["--message=hello world","C:\\literal"],"entrypoint":"opaque/entry:1","options":{"features":["run-feature"],"strict":false}}}}]});
    let call = |provider_root: &str, local: Option<Value>| -> Value {
        let request = serde_json::json!({"id":"inputs","command":"runConfig.providerLaunchInputs","payload":{
            "root":root,"configurationId":"service","providerRoot":provider_root,"localDocument":local}});
        serde_json::from_str(&execute_json(&request.to_string())).unwrap()
    };
    let inspect = || -> Value {
        serde_json::from_str(&execute_json(
            &serde_json::json!({"id":"inspect-launch-inputs","command":"runConfig.inspect",
            "payload":{"root":root,"checkFingerprint":false}})
            .to_string(),
        ))
        .unwrap()
    };
    let baseline = inspect()["data"]["generated"].clone();
    let original = call("nested", None);
    assert_eq!(original["ok"], true, "{original}");
    assert_eq!(original["data"]["projectPath"], "nested");
    assert_eq!(
        original["data"]["launchOptions"]["runtimeArguments"],
        serde_json::json!(["--message=base value"])
    );
    assert!(original["data"]["launchOptions"]
        .get("workingDirectory")
        .is_none());
    let resolved = call("nested", Some(local.clone()));
    assert_eq!(resolved["ok"], true, "{resolved}");
    assert_eq!(resolved["data"]["provider"], "serve");
    assert_eq!(
        resolved["data"]["launchOptions"],
        serde_json::json!({"execution":"service","runtimeArguments":["--message=hello world","C:\\literal"],
        "arguments":["a b","雪",""],"environment":{"EXAMPLE":"value"},"entrypoint":"opaque/entry:1","workingDirectory":"tools"})
    );
    assert_eq!(
        resolved["data"]["optionOverrides"],
        serde_json::json!({"features":["run-feature"],"strict":false})
    );
    assert!(resolved["data"].get("executable").is_none());
    assert_eq!(call(".", Some(local.clone()))["ok"], false);
    assert_eq!(call("../outside", Some(local.clone()))["ok"], false);
    fs::remove_dir_all(root.join("tools")).unwrap();
    assert_eq!(call("nested", Some(local))["ok"], false);
    assert_eq!(inspect()["data"]["generated"], baseline);
    assert!(!root.join(".lithe/run/generated.json").exists());
}

/// Historical discriminators are data for a temporary host import, never a
/// capability to make Core interpret profiles, frameworks or module launches.
#[test]
fn provider_launch_inputs_require_a_typed_reference_after_domain_migration() {
    let root = temporary_root("unmigrated-provider-inputs");
    fs::create_dir_all(&root).unwrap();
    struct Cleanup(PathBuf);
    impl Drop for Cleanup {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    let _cleanup = Cleanup(root.clone());
    for provider in [
        "maven.module",
        "spring-boot.maven",
        "quarkus.maven",
        "micronaut.maven",
    ] {
        let generated = serde_json::json!({"version":2,"configurations":[{"id":"legacy","name":"Legacy",
            "provider":provider,"execution":"task","extensions":{"maven":{"module":".","profiles":["saved"],"skipTests":false}}}]});
        seed_generated(&root, generated.to_string());
        let reply: Value = serde_json::from_str(&execute_json(
            &serde_json::json!({"id":"unmigrated","command":"runConfig.providerLaunchInputs",
            "payload":{"root":root,"configurationId":"legacy","providerRoot":"."}})
            .to_string(),
        ))
        .unwrap();
        assert_eq!(reply["ok"], false, "{reply}");
        assert_eq!(reply["error"]["code"], "invalid_request");
    }
    assert!(!root.join(".lithe/run/local.json").exists());
}
