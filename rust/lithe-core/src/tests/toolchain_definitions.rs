use crate::plugins::declarative::{validate_command, validate_manifest_value};
use crate::toolchain::definitions::{registry, validate_declarations};
use serde_json::{json, Value};

fn definition(id: &str) -> Value {
    json!({
        "id":id,"displayName":"Fixture compiler",
        "executableLayouts":[{"path":"bin/compiler"}],
        "executables":[
            {"id":"pin","kind":"setting","settingID":"executable","layer":"project"},
            {"id":"project","kind":"toolchain","scope":"project"},
            {"id":"default","kind":"setting","settingID":"executable","layer":"global"},
            {"id":"global","kind":"toolchain","scope":"global"},
            {"id":"shell","kind":"command","command":"compiler"},
            {"id":"automatic","kind":"toolchain","scope":"installed"}
        ],
        "version":{"arguments":["--version"],"pattern":"([0-9]+(?:\\.[0-9]+)*)"},
        "commands":["compiler"],"exports":[{"name":"COMPILER_HOME","value":"${home}"}],
        "pathPrepend":["${home}/bin"],"launch":["${executable}","${arguments}"]
    })
}

fn manifest(id: &str, definition: Value) -> Value {
    json!({"schemaVersion":2,"id":id,"displayName":"Fixture tool","version":"1.0.0",
        "pluginAPIVersion":3,"requires":{"toolDefinitions":1,"executableResolution":2},
        "vendor":{"id":"org.example","displayName":"Fixture publisher","signatureRequirement":"publisherPackage"},
        "toolDefinitions":[definition]})
}

#[test]
fn tool_definitions_are_complete_contributions_without_languages_or_backend() {
    let plugin = manifest(
        "dev.lithe.fixture.compiler",
        definition("dev.lithe.fixture.compiler:compiler"),
    );
    assert!(validate_manifest_value(plugin.clone()).is_ok());
    let result = registry(&json!({"plugins":[{"manifest":plugin}]})).unwrap();
    assert_eq!(
        result["definitions"][0]["definition"]["id"],
        "dev.lithe.fixture.compiler:compiler"
    );
    assert_eq!(result["providers"], json!([]));
    assert_eq!(result["conflicts"], json!([]));
}

#[test]
fn tool_definitions_second_tool_needs_only_plugin_data() {
    for (plugin, tool, command) in [
        ("dev.lithe.fixture.compiler", "compiler", "compiler"),
        ("dev.lithe.fixture.renderer", "renderer", "render-engine"),
    ] {
        let mut definition = definition(&format!("{plugin}:{tool}"));
        definition["commands"] = json!([command]);
        definition["executables"][4]["command"] = json!(command);
        assert!(validate_manifest_value(manifest(plugin, definition)).is_ok());
    }
}

/// Every plugin is a community plugin, so a short ID needs no host-attested origin.
#[test]
fn registry_accepts_short_ids_from_any_enabled_plugin() {
    let plugin = manifest("dev.lithe.fixture.compiler", definition("compiler"));
    assert!(validate_manifest_value(plugin.clone()).is_ok());
    let result = registry(&json!({"plugins":[{"manifest":plugin}]})).unwrap();
    assert_eq!(result["definitions"][0]["definition"]["id"], "compiler");
    assert_eq!(
        result["definitions"][0]["pluginID"],
        "dev.lithe.fixture.compiler"
    );
    assert_eq!(result["conflicts"], json!([]));
    // The retired host-supplied origin flag is an unknown field, not silently ignored.
    assert!(registry(&json!({"plugins":[{"manifest":plugin,"verifiedOfficial":true}]})).is_err());
}

/// Install order and plugin ID must not pick an owner, so a contested ID has none.
#[test]
fn registry_leaves_a_contested_tool_id_unowned_and_registers_the_rest() {
    let first = manifest("dev.lithe.fixture.first", definition("compiler"));
    let second = manifest("dev.lithe.fixture.second", definition("compiler"));
    let mut third = manifest("dev.lithe.fixture.third", definition("renderer"));
    third["toolDefinitions"]
        .as_array_mut()
        .unwrap()
        .push(definition("dev.lithe.fixture.third:private"));
    for plugins in [
        json!([{"manifest":first},{"manifest":second},{"manifest":third}]),
        json!([{"manifest":third},{"manifest":second},{"manifest":first}]),
    ] {
        let result = registry(&json!({"plugins":plugins})).unwrap();
        let ids: Vec<_> = result["definitions"]
            .as_array()
            .unwrap()
            .iter()
            .map(|entry| entry["definition"]["id"].as_str().unwrap())
            .collect();
        assert_eq!(ids, ["dev.lithe.fixture.third:private", "renderer"]);
        assert_eq!(
            result["conflicts"],
            json!([{"tool":"compiler","pluginIDs":["dev.lithe.fixture.first","dev.lithe.fixture.second"]}])
        );
    }
    assert!(validate_manifest_value(manifest(
        "dev.lithe.fixture.first",
        definition("dev.lithe.fixture.second:compiler")
    ))
    .is_err());
}

/// A provider that lists a contested tool still registers; only the definition is withheld.
#[test]
fn registry_keeps_providers_that_name_a_contested_tool() {
    let first = manifest("dev.lithe.fixture.first", definition("compiler"));
    let second = manifest("dev.lithe.fixture.second", definition("compiler"));
    let provider = json!({"schemaVersion":2,"id":"dev.lithe.fixture.provider","displayName":"Provider","version":"1.0.0",
        "pluginAPIVersion":3,"requires":{"toolchainProviders":1,"backend":2,"serverProcess":1},
        "vendor":{"id":"org.example","displayName":"Fixture","signatureRequirement":"publisherPackage"},
        "permissions":["backend.launch","toolchains.provide"],
        "toolchainProviders":[{"id":"installs","displayName":"Installs","tools":["compiler"]}],
        "backend":{"launch":{"kind":"packaged","path":"bin/provider"}}});
    let plugins = json!([{"manifest":first},{"manifest":second},{"manifest":provider}]);
    let result = registry(&json!({"plugins":plugins})).unwrap();
    assert_eq!(result["definitions"], json!([]));
    assert_eq!(
        result["providers"][0]["pluginID"],
        "dev.lithe.fixture.provider"
    );
    assert_eq!(result["conflicts"][0]["tool"], "compiler");
}

/// The same plugin ID twice makes the enabled set ambiguous, so the whole batch is refused.
#[test]
fn registry_rejects_duplicate_plugin_ids() {
    let first = manifest("dev.lithe.fixture.compiler", definition("compiler"));
    let second = manifest("dev.lithe.fixture.compiler", definition("renderer"));
    assert!(registry(&json!({"plugins":[{"manifest":first},{"manifest":second}]})).is_err());
}

#[test]
fn definition_nested_objects_fail_closed_and_enforce_safe_exports() {
    let base = definition("dev.lithe.fixture.compiler:compiler");
    for (pointer, value) in [
        ("/unexpected", json!(true)),
        ("/version/unexpected", json!(true)),
        ("/exports/0/name", json!("PATH")),
        ("/exports/0/name", json!("Path")),
        ("/exports/0/name", json!("DYLD_INSERT_LIBRARIES")),
        ("/pathPrepend/0", json!("${home}/../escape")),
        ("/version/pattern", json!("no capture")),
        ("/id", json!("dev..lithe.fixture:compiler")),
        ("/version/arguments", json!(["-c", "script"])),
        ("/launch/1", json!("--args=${arguments}")),
        (
            "/discovery",
            json!([{"root":{"kind":"home"},"pattern":"**/compiler"}]),
        ),
    ] {
        let mut changed = base.clone();
        if pointer == "/unexpected" {
            changed["unexpected"] = value;
        } else if pointer == "/version/unexpected" {
            changed["version"]["unexpected"] = value;
        } else if pointer == "/discovery" {
            changed["discovery"] = value;
        } else {
            *changed.pointer_mut(pointer).unwrap() = value;
        }
        assert!(
            validate_declarations("dev.lithe.fixture.compiler", &[changed], &[]).is_err(),
            "{pointer}"
        );
    }
}

#[test]
fn definition_metadata_cannot_disagree_with_executable_plan_or_cross_layers() {
    let base = definition("dev.lithe.fixture.compiler:compiler");
    for candidate in [
        json!({"kind":"command","command":"another"}),
        json!({"kind":"projectFile","path":"wrapper"}),
        json!({"kind":"environment","variable":"COMPILER_HOME","path":"bin/compiler"}),
        json!({"kind":"toolchain","scope":"installed","insertBefore":"pin"}),
        json!({"kind":"command","command":"compiler","insertBefore":"missing"}),
        json!({"kind":"runtime","runtime":"compiler"}),
        json!({"id":null,"kind":"command","command":"compiler"}),
    ] {
        let mut changed = base.clone();
        changed["executables"]
            .as_array_mut()
            .unwrap()
            .push(candidate);
        assert!(validate_declarations("dev.lithe.fixture.compiler", &[changed], &[]).is_err());
    }
}

#[test]
fn definitions_reuse_shared_candidate_graph_ordering() {
    let mut value = definition("dev.lithe.fixture.compiler:compiler");
    value["commands"] = json!(["compiler", "compiler-alt"]);
    value["executables"].as_array_mut().unwrap().insert(
        4,
        json!({"id":"alternative","kind":"command","command":"compiler-alt","insertAfter":"shell"}),
    );
    let plugin = manifest("dev.lithe.fixture.compiler", value);
    let result = registry(&json!({"plugins":[{"manifest":plugin}]})).unwrap();
    assert_eq!(
        result["definitions"][0]["definition"]["executables"][4]["id"],
        "shell"
    );
    assert_eq!(
        result["definitions"][0]["definition"]["executables"][5]["id"],
        "alternative"
    );
}

#[test]
fn providers_use_existing_packaged_backend_and_new_query_trigger_only() {
    let plugin = json!({"schemaVersion":2,"id":"dev.lithe.fixture.provider","displayName":"Provider","version":"1.0.0",
        "pluginAPIVersion":3,"requires":{"toolchainProviders":1,"backend":2,"serverProcess":1},
        "vendor":{"id":"org.example","displayName":"Fixture","signatureRequirement":"publisherPackage"},
        "permissions":["backend.launch","toolchains.provide"],
        "toolchainProviders":[{"id":"manager","displayName":"Manager","tools":["compiler"],"watchFiles":[{"pattern":".compiler-version","reader":"native"}]}],
        "backend":{"launch":{"kind":"packaged","path":"bin/provider"}}});
    assert!(validate_manifest_value(plugin.clone()).is_ok());
    let mut changed = plugin.clone();
    changed["backend"]["launch"] =
        json!({"kind":"runtime","tool":"node","entry":"provider/main.mjs"});
    assert!(validate_manifest_value(changed).is_err());
    let mut changed = plugin.clone();
    changed["permissions"] = json!(["backend.launch"]);
    assert_eq!(
        validate_manifest_value(changed).unwrap_err().code,
        "plugin.permission.undeclared"
    );
    let mut changed = plugin.clone();
    changed
        .as_object_mut()
        .unwrap()
        .remove("toolchainProviders");
    changed["requires"]
        .as_object_mut()
        .unwrap()
        .remove("toolchainProviders");
    changed["permissions"] = json!(["backend.launch"]);
    assert!(validate_manifest_value(changed).is_err());
}

#[test]
fn providers_without_watch_files_report_installations_only() {
    let plugin = json!({"schemaVersion":2,"id":"dev.lithe.fixture.provider","displayName":"Provider","version":"1.0.0",
        "pluginAPIVersion":3,"requires":{"toolchainProviders":1,"backend":2,"serverProcess":1},
        "vendor":{"id":"org.example","displayName":"Fixture","signatureRequirement":"publisherPackage"},
        "permissions":["backend.launch","toolchains.provide"],
        "toolchainProviders":[{"id":"installs","displayName":"Installs","tools":["compiler"]}],
        "backend":{"launch":{"kind":"packaged","path":"bin/provider"}}});
    assert!(validate_manifest_value(plugin.clone()).is_ok());
    let mut changed = plugin;
    changed["toolchainProviders"][0]["watchFiles"] = json!([]);
    assert!(validate_manifest_value(changed).is_err());
}

#[test]
fn a_definition_plugin_may_provide_installations_of_its_own_tool() {
    let id = "dev.lithe.fixture.compiler";
    let mut plugin = manifest(id, definition(&format!("{id}:compiler")));
    plugin["requires"] = json!({"toolDefinitions":1,"executableResolution":2,
        "toolchainProviders":1,"backend":2,"serverProcess":1});
    plugin["permissions"] = json!(["backend.launch", "toolchains.provide"]);
    plugin["toolchainProviders"] =
        json!([{"id":"installs","displayName":"Installs","tools":[format!("{id}:compiler")]}]);
    plugin["backend"] = json!({"launch":{"kind":"packaged","path":"bin/provider"}});
    assert!(validate_manifest_value(plugin.clone()).is_ok());
    let result = registry(&json!({"plugins":[{"manifest":plugin}]})).unwrap();
    assert_eq!(result["definitions"][0]["pluginID"], id);
    assert_eq!(result["providers"][0]["pluginID"], id);
}

#[test]
fn build_toolchain_consumers_keep_resolution_two_without_owning_definitions() {
    let mut plugin: Value = serde_json::from_str(include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../shared/contracts/plugins/v1/fixtures/build-systems/build-toolchains.plugin.json"
    )))
    .unwrap();
    assert!(validate_manifest_value(plugin.clone()).is_ok());
    plugin["buildSystems"][0]["invocation"]["executables"][0]["toolchainID"] =
        json!("dev.lithe.fixture.compiler:compiler");
    assert!(validate_manifest_value(plugin.clone()).is_ok());
    plugin["buildSystems"][0]["invocation"]["executables"][0]["toolchainID"] =
        json!("dev.lithe.fixture.compiler:../compiler");
    assert!(validate_manifest_value(plugin.clone()).is_err());
    plugin["buildSystems"][0]["invocation"]["executables"][0]["toolchainID"] =
        json!("dev.lithe.fixture.compiler:compiler");
    plugin["requires"]["executableResolution"] = json!(1);
    assert!(validate_manifest_value(plugin).is_err());
}

#[test]
fn executable_resolution_two_does_not_enable_toolchain_fields_in_legacy_build_sets() {
    let mut plugin: Value = serde_json::from_str(include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../shared/contracts/plugins/v1/fixtures/build-systems/build-tool-path.plugin.json"
    )))
    .unwrap();
    plugin["requires"]["executableResolution"] = json!(2);
    assert!(validate_manifest_value(plugin.clone()).is_err());
    plugin["requires"]["toolDefinitions"] = json!(1);
    plugin["toolDefinitions"] = json!([definition("dev.lithe.fixture.build-tool-path:compiler")]);
    plugin["buildSystems"][0]["invocation"]["executables"][0]["layer"] = json!("project");
    assert!(validate_manifest_value(plugin).is_err());
}

#[test]
fn production_toolchain_fixtures_require_explicit_host_capabilities() {
    let sources = [
        include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../shared/contracts/plugins/v1/fixtures/toolchains/tool-definition.plugin.json"
        )),
        include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../shared/contracts/plugins/v1/fixtures/toolchains/toolchain-provider.plugin.json"
        )),
    ];
    let old_host = json!({"backend":[1,2],"serverProcess":[1],"executableResolution":[1]});
    let capable_host = json!({"backend":[1,2],"serverProcess":[1],"executableResolution":[1,2],"toolDefinitions":[1],"toolchainProviders":[1]});
    for source in sources {
        let manifest: Value = serde_json::from_str(source).unwrap();
        assert!(validate_manifest_value(manifest.clone()).is_ok());
        let rejected =
            validate_command(json!({"manifest":manifest,"hostCapabilities":old_host})).unwrap();
        assert_eq!(rejected["status"], "rejected", "{rejected}");
        assert_eq!(rejected["error"]["code"], "plugin.api.unsupported");
        let accepted =
            validate_command(json!({"manifest":manifest,"hostCapabilities":capable_host})).unwrap();
        assert_eq!(accepted["status"], "ok", "{accepted}");
    }
}
