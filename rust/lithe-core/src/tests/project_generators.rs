use crate::plugins::declarative::validate_command;
use crate::plugins::marketplace::install_review_command;
use crate::project_generators::{
    project_check_name_command, project_generation_plan_command, project_generator_catalog_command,
    project_generator_form_command,
};
use serde_json::{json, Value};
use std::path::PathBuf;

const FIXTURE: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../shared/contracts/plugins/v1/fixtures/project-generators/project-generator.plugin.json"
));
const PLANS: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../shared/contracts/plugins/v1/fixtures/project-generators/project-plans.json"
));
const TOOL_FIELD_FIXTURE: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../shared/contracts/plugins/v1/fixtures/project-generators/project-generator-tool-field.plugin.json"
));
const TOOL_DEFINITION_FIXTURE: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../shared/contracts/plugins/v1/fixtures/toolchains/tool-definition.plugin.json"
));
const BUILD_FIXTURE: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../shared/contracts/plugins/v1/fixtures/build-systems/build-static-file.plugin.json"
));

fn json(source: &str) -> Value {
    serde_json::from_str(source).expect("fixture is JSON")
}

fn repository_path(relative: &str) -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .join(relative)
}

fn fixtures_path() -> PathBuf {
    repository_path("shared/contracts/plugins/v1/fixtures/project-generators")
}

/// A plugin that only contributes the `java` language, so a generator's
/// language requirement has exactly one provider.
fn java_language_only() -> Value {
    json!({
        "schemaVersion": 2,
        "id": "dev.lithe.fixture.java-language",
        "displayName": "Java Language Fixture",
        "version": "0.1.0",
        "pluginAPIVersion": 1,
        "vendor": {"id": "dev.lithe", "displayName": "Lithe", "signatureRequirement": "publisherPackage"},
        "permissions": ["languageServer.launch"],
        "activationEvents": ["onLanguage:java"],
        "languages": [
            {"id": "java", "displayName": "Java", "fileExtensions": ["java"]}
        ],
        "languageServers": [
            {
                "languageID": "java",
                "languageIdentifier": "java",
                "launch": {"kind": "systemCommand", "commands": ["example-ls"]},
                "arguments": [],
                "validationArguments": ["--version"]
            }
        ]
    })
}

fn host() -> Value {
    json!({"languages": [1], "languageServers": [1, 2], "serverProcess": [1], "settings": [1, 2],
           "buildSystems": [1], "projectGenerators": [1, 2], "debugAdapters": [1], "packageTrust": [1], "toolDefinitions": [1], "executableResolution": [1, 2]})
}

/// A case names its manifest fixture in `manifest`; the default is the
/// version 1 generator fixture.
fn case_manifest(case: &Value) -> Value {
    match case["manifest"].as_str() {
        Some(file) => json(
            &std::fs::read_to_string(fixtures_path().join(file))
                .unwrap_or_else(|error| panic!("{file}: {error}")),
        ),
        None => json(FIXTURE),
    }
}

#[test]
fn golden_project_plans_match() {
    let plans = json(PLANS);
    assert_eq!(plans["schemaVersion"], 1);
    for case in plans["cases"].as_array().unwrap() {
        let name = case["name"].as_str().unwrap();
        let manifest = case_manifest(case);
        let actual = match case["operation"].as_str().unwrap() {
            "generatorForm" => project_generator_form_command(json!({
                "manifest": manifest,
                "generatorID": case["generatorID"],
                "form": case["form"],
            })),
            "generationPlan" => project_generation_plan_command(json!({
                "manifest": manifest,
                "generatorID": case["generatorID"],
                "packagePath": fixtures_path(),
                "form": case["form"],
            })),
            "checkName" => project_check_name_command(json!({"projectName": case["projectName"]})),
            operation => panic!("{name}: unknown operation {operation}"),
        }
        .unwrap_or_else(|error| panic!("{name}: {error:?}"));
        assert_eq!(actual, case["expected"], "{name}");
    }
}

#[test]
fn catalog_lists_generators_with_requirement_providers() {
    let language = java_language_only();
    let admission =
        validate_command(json!({"manifest":language,"hostCapabilities":host()})).unwrap();
    assert_eq!(admission["status"], "ok", "{admission}");
    // A disabled plugin that provides the build system the generator asks for.
    let mut build = json(BUILD_FIXTURE);
    build["buildSystems"][0]["id"] = json!("maven");
    build["activationEvents"] = json!(["onBuildSystem:maven"]);
    let result = project_generator_catalog_command(json!({
        "plugins": [
            {"manifest": json(FIXTURE), "enabled": true},
            {"manifest": build, "enabled": false},
            {"manifest": java_language_only(), "enabled": true},
            {"manifest": {"schemaVersion": 2, "id": "broken"}, "enabled": true}
        ],
        "hostCapabilities": host(),
    }))
    .unwrap();
    assert_eq!(result["status"], "ok");
    let generators = result["catalog"]["generators"].as_array().unwrap();
    let ids: Vec<&str> = generators
        .iter()
        .map(|entry| entry["generator"]["id"].as_str().unwrap())
        .collect();
    // Project section first, then generators by order and name.
    assert_eq!(ids, ["app", "initializr", "archetype"]);
    let app = &generators[0];
    assert_eq!(app["pluginEnabled"], true);
    assert_eq!(
        app["requirements"],
        json!([
            {"languageID": "java", "providers": [
                {"pluginID": "dev.lithe.fixture.java-language", "pluginName": "Java Language Fixture", "enabled": true}
            ]},
            {"buildSystemID": "maven", "providers": [
                {"pluginID": "dev.lithe.fixture.build-static-file", "pluginName": "Static File Build Fixture", "enabled": false}
            ]}
        ])
    );
    assert_eq!(generators[1]["usesNetwork"], true);
    assert_eq!(result["catalog"]["issues"].as_array().unwrap().len(), 1);
}

#[test]
fn catalog_skips_plugins_the_host_cannot_run() {
    let result = project_generator_catalog_command(json!({
        "plugins": [{"manifest": json(FIXTURE), "enabled": true}],
        "hostCapabilities": {"languages": [1]},
    }))
    .unwrap();
    assert_eq!(result["catalog"]["generators"], json!([]));
    assert_eq!(
        result["catalog"]["issues"][0]["error"]["code"],
        "plugin.api.unsupported"
    );
}

/// The catalog tells the host which plugins declare the tool a field selects,
/// so a field with no installation can point at the plugin to enable. A tool
/// nobody declares has no provider, which is how an unknown ID shows up.
#[test]
fn catalog_names_the_plugins_that_define_each_tool() {
    // Read the names from the definition fixture, so the test follows it and
    // the host keeps no tool name of its own.
    let definition = json(TOOL_DEFINITION_FIXTURE);
    let definer = definition["id"].as_str().unwrap().to_string();
    let tool = definition["toolDefinitions"][0]["id"]
        .as_str()
        .unwrap()
        .to_string();
    let mut generators = json(TOOL_FIELD_FIXTURE);
    // Point the first field at the tool the definition fixture declares.
    generators["projectGenerators"][0]["fields"][0]["tool"] = json!(tool);
    let result = project_generator_catalog_command(json!({
        "plugins": [
            {"manifest": generators, "enabled": true},
            {"manifest": json(TOOL_DEFINITION_FIXTURE), "enabled": false},
        ],
        "hostCapabilities": host(),
    }))
    .unwrap();
    assert_eq!(result["status"], "ok", "{result}");
    assert_eq!(result["catalog"]["issues"], json!([]), "{result}");
    let entries = result["catalog"]["generators"].as_array().unwrap();
    assert_eq!(
        entries[0]["tools"],
        json!([{
            "fieldID": "python", "tool": tool,
            "providers": [{
                "pluginID": definer,
                "pluginName": "Tool definition fixture",
                "enabled": false
            }]
        }])
    );
    assert_eq!(
        entries[1]["tools"],
        json!([{"fieldID": "node", "tool": "node", "providers": []}])
    );
    // A third-party definition is addressed as `<pluginID>:<id>`; that spelling
    // names the same declaration, but another plugin's prefix does not.
    for (tool, provider_count) in [
        (format!("{definer}:{tool}"), 1),
        (format!("dev.lithe.fixture.other:{tool}"), 0),
    ] {
        let mut generators = json(TOOL_FIELD_FIXTURE);
        generators["projectGenerators"][0]["fields"][0]["tool"] = json!(tool);
        let qualified = project_generator_catalog_command(json!({
            "plugins": [
                {"manifest": generators, "enabled": true},
                {"manifest": json(TOOL_DEFINITION_FIXTURE), "enabled": true},
            ],
            "hostCapabilities": host(),
        }))
        .unwrap();
        let providers = &qualified["catalog"]["generators"][0]["tools"][0]["providers"];
        assert_eq!(
            providers.as_array().unwrap().len(),
            provider_count,
            "{tool}"
        );
    }
    // Version 1 generators have no tool fields.
    let version_1 = project_generator_catalog_command(json!({
        "plugins": [{"manifest": json(FIXTURE), "enabled": true}],
        "hostCapabilities": host(),
    }))
    .unwrap();
    assert_eq!(version_1["catalog"]["generators"][0]["tools"], json!([]));
}

#[test]
fn catalog_skips_tool_fields_on_hosts_without_projectgenerators_2() {
    let result = project_generator_catalog_command(json!({
        "plugins": [{"manifest": json(TOOL_FIELD_FIXTURE), "enabled": true}],
        "hostCapabilities": {"projectGenerators": [1]},
    }))
    .unwrap();
    assert_eq!(result["catalog"]["generators"], json!([]));
    assert_eq!(
        result["catalog"]["issues"][0]["error"]["field"],
        "requires.projectGenerators"
    );
}

/// A form value naming an installation the host did not list never reaches
/// the plan: the plan is built from the newest listed installation instead.
#[test]
fn a_plan_never_uses_an_installation_the_host_did_not_list() {
    let plan = project_generation_plan_command(json!({
        "manifest": json(TOOL_FIELD_FIXTURE),
        "generatorID": "python-app",
        "packagePath": fixtures_path(),
        "form": {
            "projectName": "demo",
            "values": {"python": "/tmp/planted"},
            "tools": {"python": [
                {"home": "/opt/python-3.12", "executable": "/opt/python-3.12/bin/python3", "version": "3.12.4"}
            ]},
        },
    }))
    .unwrap();
    assert_eq!(plan["status"], "ok", "{plan}");
    assert_eq!(plan["plan"]["toolPins"][0]["home"], "/opt/python-3.12");
    assert!(!plan.to_string().contains("/tmp/planted"), "{plan}");
}

#[test]
fn rejects_invalid_generator_declarations() {
    let base = json(FIXTURE);
    let mutate = |change: &dyn Fn(&mut Value)| {
        let mut manifest = base.clone();
        change(&mut manifest);
        validate_command(json!({"manifest": manifest})).unwrap()
    };
    type Mutation = Box<dyn Fn(&mut Value)>;
    let cases: Vec<(&str, Mutation, &str)> = vec![
        (
            "missing capability",
            Box::new(|manifest| {
                manifest["requires"] = json!({"languages": 1});
            }),
            "plugin.manifest.invalid",
        ),
        (
            "missing permission",
            Box::new(|manifest| manifest["permissions"] = json!([])),
            "plugin.permission.undeclared",
        ),
        (
            "field read before declaration",
            Box::new(|manifest| {
                manifest["projectGenerators"][0]["fields"][0]["visibleWhen"] =
                    json!({"field": "sample", "equals": true});
            }),
            "plugin.manifest.invalid",
        ),
        (
            "template escapes the package",
            Box::new(|manifest| {
                manifest["projectGenerators"][0]["steps"][0]["source"] = json!("../secrets");
            }),
            "plugin.manifest.invalid",
        ),
        (
            "unknown variable",
            Box::new(|manifest| {
                manifest["projectGenerators"][1]["steps"][0]["arguments"][2] =
                    json!("-DartifactId=${field.missing}");
            }),
            "plugin.manifest.invalid",
        ),
        (
            "archive URL with query",
            Box::new(|manifest| {
                manifest["projectGenerators"][2]["steps"][0]["url"] =
                    json!("https://start.example.com/starter.zip?type=x");
            }),
            "plugin.manifest.invalid",
        ),
        (
            "command path",
            Box::new(|manifest| {
                manifest["projectGenerators"][1]["steps"][0]["command"] = json!("/usr/bin/mvn");
            }),
            "plugin.manifest.invalid",
        ),
    ];
    for (name, change, code) in cases {
        let result = mutate(&*change);
        assert_eq!(result["status"], "rejected", "{name}: {result}");
        assert_eq!(result["error"]["code"], code, "{name}: {result}");
    }
}

#[test]
fn project_generators_need_api_level_3() {
    let mut manifest = json(FIXTURE);
    manifest["pluginAPIVersion"] = json!(2);
    manifest.as_object_mut().unwrap().remove("requires");
    let result = validate_command(json!({"manifest": manifest})).unwrap();
    assert_eq!(result["status"], "rejected");
}

/// A generator command runs a program on the user's Mac, so the install
/// review must list it, and an update that adds one or changes its argv must
/// ask again; template-only edits must not.
#[test]
fn generator_commands_require_install_review_again() {
    let mut manifest = json(FIXTURE);
    let generators = manifest["projectGenerators"].as_array_mut().unwrap();
    let archetype = generators
        .iter()
        .position(|g| g["id"] == "archetype")
        .unwrap();
    let command_generator = generators.remove(archetype);
    let first = install_review_command(json!({ "manifest": manifest })).unwrap();
    assert_eq!(first["status"], "ok", "{first}");
    let approved = first["review"]["programs"].clone();
    assert_eq!(approved, json!([]), "files and archives start no program");

    manifest["version"] = json!("1.0.1");
    manifest["projectGenerators"]
        .as_array_mut()
        .unwrap()
        .push(command_generator);
    let added = install_review_command(json!({
        "manifest": manifest, "approvedPrograms": approved,
    }))
    .unwrap();
    assert_eq!(added["status"], "ok", "{added}");
    let programs = added["review"]["newPrograms"].as_array().unwrap();
    assert_eq!(programs.len(), 1, "{added}");
    assert_eq!(programs[0]["kind"], "projectGenerator");
    assert_eq!(programs[0]["generatorID"], "archetype");
    let approved = added["review"]["programs"].clone();

    let last = manifest["projectGenerators"].as_array().unwrap().len() - 1;
    manifest["projectGenerators"][last]["displayName"] = json!("Renamed");
    let renamed = install_review_command(json!({
        "manifest": manifest, "approvedPrograms": approved,
    }))
    .unwrap();
    assert_eq!(renamed["review"]["newPrograms"], json!([]), "{renamed}");

    manifest["projectGenerators"][last]["steps"][0]["arguments"]
        .as_array_mut()
        .unwrap()
        .push(json!("-Dchanged=true"));
    let changed = install_review_command(json!({
        "manifest": manifest, "approvedPrograms": approved,
    }))
    .unwrap();
    assert_eq!(
        changed["review"]["newPrograms"].as_array().unwrap().len(),
        1,
        "{changed}"
    );
}
