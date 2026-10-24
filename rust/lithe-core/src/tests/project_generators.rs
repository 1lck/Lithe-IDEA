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
    "/../../shared/contracts/plugins/v1/fixtures/project-generator.plugin.json"
));
const PLANS: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../shared/contracts/plugins/v1/fixtures/project-plans.json"
));
const MAVEN_BUILD_FIXTURE: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../shared/contracts/plugins/v1/fixtures/build-host-integration.plugin.json"
));
const OFFICIAL_JAVA: &str = include_str!(concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../Plugins/mac/Official/JavaSupport/plugin.json"
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
    repository_path("shared/contracts/plugins/v1/fixtures")
}

/// Java Support without its own New Project entries, so catalog tests see
/// it only as the provider of the Java language.
fn java_language_only() -> Value {
    let mut manifest = json(OFFICIAL_JAVA);
    let object = manifest.as_object_mut().unwrap();
    object.remove("projectGenerators");
    object["requires"]
        .as_object_mut()
        .unwrap()
        .remove("projectGenerators");
    object["permissions"] = json!(["languageServer.launch"]);
    manifest
}

fn official_package_path() -> PathBuf {
    repository_path("Plugins/mac/Official/JavaSupport")
}

fn host() -> Value {
    json!({"languages": [1], "languageServers": [1, 2], "serverProcess": [1], "settings": [1, 2],
           "buildSystems": [1], "projectGenerators": [1]})
}

#[test]
fn golden_project_plans_match() {
    let plans = json(PLANS);
    assert_eq!(plans["schemaVersion"], 1);
    let manifest = json(FIXTURE);
    for case in plans["cases"].as_array().unwrap() {
        let name = case["name"].as_str().unwrap();
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
    let result = project_generator_catalog_command(json!({
        "plugins": [
            {"manifest": json(FIXTURE), "enabled": true},
            {"manifest": json(MAVEN_BUILD_FIXTURE), "enabled": false},
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
                {"pluginID": "dev.lithe.plugin.java-support", "pluginName": "Java Support", "enabled": true}
            ]},
            {"buildSystemID": "maven", "providers": [
                {"pluginID": "dev.lithe.fixture.build-host-integration", "pluginName": "Host Integration Build Fixture", "enabled": false}
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

#[test]
fn official_java_templates_validate_and_plan() {
    let manifest = json(OFFICIAL_JAVA);
    let validated =
        validate_command(json!({"manifest": manifest, "hostCapabilities": host()})).unwrap();
    assert_eq!(validated["status"], "ok", "{validated}");

    let runtimes = json!({"jdk": {"home": "/Library/Java/JavaVirtualMachines/temurin-25.jdk/Contents/Home", "version": "25.0.3"}});
    let plan = |generator: &str, values: Value| {
        project_generation_plan_command(json!({
            "manifest": manifest,
            "generatorID": generator,
            "packagePath": official_package_path(),
            "form": {"projectName": "demo-app", "values": values, "runtimes": runtimes},
        }))
        .unwrap()
    };
    let files = |plan: &Value| -> Vec<(String, String)> {
        plan["plan"]["steps"]
            .as_array()
            .unwrap()
            .iter()
            .flat_map(|step| step["files"].as_array().cloned().unwrap_or_default())
            .map(|file| {
                (
                    file["path"].as_str().unwrap().to_string(),
                    file["contents"].as_str().unwrap().to_string(),
                )
            })
            .collect()
    };

    let maven = plan("java", json!({}));
    assert_eq!(maven["status"], "ok", "{maven}");
    let maven_files = files(&maven);
    let paths: Vec<&str> = maven_files.iter().map(|(path, _)| path.as_str()).collect();
    assert!(paths.contains(&"pom.xml"));
    assert!(paths.contains(&".gitignore"));
    assert!(paths.contains(&"src/main/java/org/example/Main.java"));
    let pom = &maven_files
        .iter()
        .find(|(path, _)| path == "pom.xml")
        .unwrap()
        .1;
    assert!(pom.contains("<artifactId>demo-app</artifactId>"));
    assert!(pom.contains("<maven.compiler.release>25</maven.compiler.release>"));
    // Maven 3.8's default Compiler 3.1 ignores the release property.
    assert!(pom.contains("<artifactId>maven-compiler-plugin</artifactId>"));
    assert_eq!(
        maven["plan"]["openFiles"],
        json!(["src/main/java/org/example/Main.java"])
    );
    assert_eq!(maven["plan"]["usesNetwork"], false);

    let gradle = plan(
        "java",
        json!({"buildSystem": "gradle", "addSampleCode": false}),
    );
    let gradle_paths: Vec<String> = files(&gradle).into_iter().map(|(path, _)| path).collect();
    assert!(gradle_paths.contains(&"build.gradle.kts".to_string()));
    assert!(gradle_paths.contains(&"src/main/java/.gitkeep".to_string()));
    assert_eq!(gradle["plan"]["openFiles"], json!([]));

    let plain = plan("java", json!({"buildSystem": "none"}));
    let plain_paths: Vec<String> = files(&plain).into_iter().map(|(path, _)| path).collect();
    assert_eq!(plain_paths, [".gitignore", "src/Main.java"]);

    let archetype = plan(
        "maven-archetype",
        json!({"archetype": "maven-archetype-webapp"}),
    );
    let step = &archetype["plan"]["steps"][0];
    assert_eq!(step["command"], "mvn");
    assert_eq!(step["collect"], "demo-app");
    assert_eq!(step["environment"]["JAVA_HOME"], runtimes["jdk"]["home"]);
    let arguments: Vec<&str> = step["arguments"]
        .as_array()
        .unwrap()
        .iter()
        .map(|argument| argument.as_str().unwrap())
        .collect();
    assert!(arguments.contains(&"-DarchetypeArtifactId=maven-archetype-webapp"));
    assert!(arguments.contains(&"-Dpackage=org.example.demoapp"));
    assert!(!arguments
        .iter()
        .any(|argument| argument.starts_with("-DarchetypeVersion")));

    let spring = plan(
        "spring-boot",
        json!({"dependencies": ["web", "lombok"], "type": "gradle-project-kotlin"}),
    );
    let url = spring["plan"]["steps"][0]["url"].as_str().unwrap();
    assert!(url.starts_with("https://start.spring.io/starter.zip?type=gradle-project-kotlin&language=java&groupId=com.example&artifactId=demo-app&name=demo-app&packageName=com.example.demoapp"), "{url}");
    assert!(
        url.ends_with("&dependencies=lombok%2Cweb") || url.ends_with("&dependencies=web%2Clombok"),
        "{url}"
    );
    assert!(!url.contains("bootVersion"));
    assert_eq!(spring["plan"]["openFiles"], json!(["build.gradle.kts"]));
    assert_eq!(spring["plan"]["usesNetwork"], true);
}

#[test]
fn spring_boot_refuses_a_jdk_older_than_17() {
    let result = project_generation_plan_command(json!({
        "manifest": json(OFFICIAL_JAVA),
        "generatorID": "spring-boot",
        "packagePath": official_package_path(),
        "form": {"projectName": "demo", "runtimes": {"jdk": {"home": "/jdk11", "version": "11.0.22"}}},
    }))
    .unwrap();
    assert_eq!(result["status"], "rejected");
    assert_eq!(result["error"]["code"], "plugin.project.invalidInput");
    assert_eq!(result["error"]["field"], "values.jdk");
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

/// Spring Boot's target Java release follows the selected JDK, so a project
/// the saved JDK cannot compile is refused before anything is downloaded.
#[test]
fn spring_boot_refuses_a_java_release_newer_than_the_jdk() {
    let plan = |jdk: &str, java: &str| {
        project_generation_plan_command(json!({
            "manifest": json(OFFICIAL_JAVA),
            "generatorID": "spring-boot",
            "packagePath": official_package_path(),
            "form": {"projectName": "demo", "values": {"javaVersion": java},
                     "runtimes": {"jdk": {"home": "/jdk", "version": jdk}}},
        }))
        .unwrap()
    };
    let refused = plan("17.0.12", "21");
    assert_ne!(refused["status"], "ok", "{refused}");
    assert!(refused.to_string().contains("versionTooHigh"), "{refused}");
    assert_eq!(plan("21.0.4", "21")["status"], "ok");
}
