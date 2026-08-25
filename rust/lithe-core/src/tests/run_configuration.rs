use super::support::temporary_root;
use crate::execute_json;
use serde_json::Value;
use std::fs;
use std::path::PathBuf;

#[test]
fn run_configuration_commands_generate_merge_and_plan() {
    let root = temporary_root("run-config");
    fs::create_dir_all(root.join("src/main/java/com/example"))
        .expect("source directory should be creatable");
    fs::write(root.join("src/main/java/com/example/App.java"), "package com.example; @SpringBootApplication class App { public static void main(String[] args) {} }").expect("source should be writable");
    fs::write(root.join("pom.xml"), "<project><artifactId>demo</artifactId><properties><maven.compiler.release>21</maven.compiler.release></properties><build><plugins><plugin><artifactId>spring-boot-maven-plugin</artifactId></plugin></plugins></build></project>").expect("pom should be writable");

    let request = serde_json::json!({"id":"generate","command":"runConfig.generate","payload":{"root":root,"paths":["src/main/java/com/example/App.java"],"modulePaths":[]}});
    let generated: Value = serde_json::from_str(&execute_json(&request.to_string()))
        .expect("generate response should be JSON");
    assert_eq!(generated["ok"], true);
    assert_eq!(generated["data"]["generated"]["version"], 2);
    assert!(generated["data"]["generated"]["configurations"]
        .as_array()
        .unwrap()
        .iter()
        .any(|v| v["id"] == "current-file"));

    let generated_doc = serde_json::to_string(&generated["data"]["generated"]).unwrap();
    fs::create_dir_all(root.join(".lithe/run")).unwrap();
    fs::write(root.join(".lithe/run/generated.json"), generated_doc).unwrap();
    fs::write(root.join(".lithe/run/configurations.json"), r#"{"version":1,"configurations":[{"id":"current-file","name":"My File","type":"java.current-file","workingDirectory":"backend","jvmArguments":["-Xmx2g"],"toolchains":{"maven":"custom-maven"}}]}"#).unwrap();
    fs::write(root.join(".lithe/run/local.json"), r#"{"version":1,"configurations":[{"id":"current-file","name":"Local File","type":"java.current-file","workingDirectory":".","programArguments":["--dev"],"toolchains":{"java":"custom-jdk"}}]}"#).unwrap();

    let resolve: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({"id":"resolve","command":"runConfig.resolve","payload":{"root":root}})
            .to_string(),
    ))
    .unwrap();
    assert_eq!(resolve["ok"], true);
    let current = resolve["data"]["configurations"]
        .as_array()
        .unwrap()
        .iter()
        .find(|v| v["id"] == "current-file")
        .unwrap();
    assert_eq!(current["name"], "Local File");
    assert_eq!(current["toolchains"]["java"], "custom-jdk");
    assert_eq!(current["toolchains"]["maven"], "custom-maven");
    let plan: Value = serde_json::from_str(&execute_json(&serde_json::json!({"id":"plan","command":"runConfig.createLaunchPlan","payload":{"root":root,"configurationId":"current-file","currentFile":"src/main/java/com/example/App.java"}}).to_string())).unwrap();
    assert_eq!(plan["ok"], true);
    assert_eq!(plan["data"]["executable"]["toolchain"], "custom-jdk");
    let debug_plan: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id":"debug-plan",
            "command":"runConfig.createLaunchPlan",
            "payload":{
                "root":root,
                "configurationId":"spring-boot.maven:demo",
                "debugPort":5005
            }
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(debug_plan["ok"], true);
    assert!(debug_plan["data"]["arguments"]
        .as_array()
        .unwrap()
        .iter()
        .filter_map(Value::as_str)
        .any(|argument| argument.contains("address=127.0.0.1:5005")));
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn run_configuration_generation_infers_maven_modules_from_nearest_pom() {
    let root = temporary_root("run-config-inferred-modules");
    let backend = "backend-api/src/main/java/com/example/BackendApplication.java";
    let worker = "batch-worker/src/main/java/com/example/WorkerMain.java";
    fs::create_dir_all(root.join("backend-api/src/main/java/com/example")).unwrap();
    fs::create_dir_all(root.join("batch-worker/src/main/java/com/example")).unwrap();
    fs::write(root.join("pom.xml"), "<project/>").unwrap();
    fs::write(root.join("backend-api/pom.xml"), "<project/>").unwrap();
    fs::write(root.join("batch-worker/pom.xml"), "<project/>").unwrap();
    fs::write(
        root.join(backend),
        "package com.example; @SpringBootApplication class BackendApplication { public static void main(String[] args) {} }",
    )
    .unwrap();
    fs::write(
        root.join(worker),
        "package com.example; class WorkerMain { public static void main(String[] args) {} }",
    )
    .unwrap();

    let response: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "generate-inferred-modules",
            "command": "runConfig.generate",
            "payload": {
                "root": root,
                "paths": [backend, worker],
                "modulePaths": []
            }
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(response["ok"], true);
    let configurations = response["data"]["generated"]["configurations"]
        .as_array()
        .unwrap();
    // No pom declares `spring-boot-maven-plugin`, so neither module is a service.
    // The annotated class is still a runnable main class, and module inference --
    // what this test is about -- has to place it in its own module either way.
    assert!(configurations.iter().any(|value| {
        value["id"] == "java-main:com.example.BackendApplication"
            && value["extensions"]["maven"]["module"] == "backend-api"
    }));
    assert!(configurations.iter().any(|value| {
        value["id"] == "java-main:com.example.WorkerMain"
            && value["extensions"]["maven"]["module"] == "batch-worker"
            && value["execution"] == "application"
    }));
    assert!(!configurations
        .iter()
        .any(|value| value["provider"] == "maven.module"));

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn run_configuration_generation_uses_a_maven_project_below_the_workspace() {
    let root = temporary_root("run-config-nested-maven-root");
    let source = "projects/demo/service/src/main/java/com/example/App.java";
    fs::create_dir_all(root.join("projects/demo/service/src/main/java/com/example")).unwrap();
    fs::create_dir_all(root.join("projects/demo/.mvn/wrapper")).unwrap();
    fs::write(
        root.join("projects/demo/pom.xml"),
        r#"<project><artifactId>demo</artifactId><packaging>pom</packaging><modules><module>service</module></modules><properties><maven.compiler.release>21</maven.compiler.release></properties></project>"#,
    )
    .unwrap();
    fs::write(
        root.join("projects/demo/service/pom.xml"),
        r#"<project><artifactId>service</artifactId><build><plugins><plugin><artifactId>spring-boot-maven-plugin</artifactId></plugin></plugins></build></project>"#,
    )
    .unwrap();
    fs::write(root.join("projects/demo/mvnw"), "#!/bin/sh\n").unwrap();
    fs::write(root.join("projects/demo/.sdkmanrc"), "java=21.0.5-tem\n").unwrap();
    fs::write(
        root.join("projects/demo/.mvn/wrapper/maven-wrapper.properties"),
        "distributionUrl=https://example.invalid/apache-maven-3.9.9-bin.zip\n",
    )
    .unwrap();
    fs::write(
        root.join(source),
        "package com.example; @SpringBootApplication class App { public static void main(String[] args) {} }",
    )
    .unwrap();

    let response: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "generate-nested-maven-root",
            "command": "runConfig.generate",
            "payload": {
                "root": root,
                "paths": ["projects/demo/pom.xml", "projects/demo/service/pom.xml", source],
                "modulePaths": ["service"]
            }
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(response["ok"], true, "{response}");
    let configurations = response["data"]["generated"]["configurations"]
        .as_array()
        .unwrap();
    let service = configurations
        .iter()
        .find(|value| value["provider"] == "spring-boot.maven")
        .unwrap_or_else(|| panic!("missing nested Maven service in {configurations:?}"));
    assert_eq!(service["cwd"], "projects/demo");
    assert_eq!(service["source"], "projects/demo/service/pom.xml");
    assert_eq!(service["extensions"]["maven"]["module"], "service");
    assert_eq!(
        service["extensions"]["maven"]["mainClass"],
        "com.example.App"
    );
    let java_main = configurations
        .iter()
        .find(|value| value["provider"] == "java.main")
        .unwrap();
    assert_eq!(java_main["cwd"], "projects/demo");
    assert_eq!(java_main["extensions"]["maven"]["module"], "service");
    assert_eq!(
        response["data"]["toolchainRequirements"]["toolchains"]["project-jdk"]["minimumVersion"],
        "21"
    );
    assert_eq!(
        response["data"]["toolchainRequirements"]["toolchains"]["project-jdk"]["preferredVendor"],
        "temurin"
    );
    assert_eq!(
        response["data"]["toolchainRequirements"]["toolchains"]["project-maven"]["wrapper"],
        "./mvnw"
    );
    assert_eq!(
        response["data"]["toolchainRequirements"]["toolchains"]["project-maven"]["version"],
        "3.9.9"
    );

    fs::create_dir_all(root.join(".lithe/run")).unwrap();
    fs::write(
        root.join(".lithe/run/generated.json"),
        serde_json::to_string(&response["data"]["generated"]).unwrap(),
    )
    .unwrap();
    let plan: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "plan-nested-maven-root",
            "command": "runConfig.createLaunchPlan",
            "payload": {
                "root": root,
                "configurationId": service["id"]
            }
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(plan["ok"], true, "{plan}");
    assert_eq!(plan["data"]["workingDirectory"], "projects/demo");
    assert!(plan["data"]["arguments"]
        .as_array()
        .unwrap()
        .windows(2)
        .any(|arguments| arguments == ["-pl", "service"]));

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn run_configuration_generation_deduplicates_nested_checkout_sources() {
    let root = temporary_root("run-config-worktree-duplicate");
    let source = "src/main/java/com/example/App.java";
    let duplicate_source = "copied/src/main/java/com/example/App.java";
    let nested_source = ".worktree/feature/src/main/java/com/example/App.java";
    fs::create_dir_all(root.join("src/main/java/com/example")).unwrap();
    fs::create_dir_all(root.join("copied/src/main/java/com/example")).unwrap();
    fs::create_dir_all(root.join(".worktree/feature/src/main/java/com/example")).unwrap();
    fs::write(root.join("pom.xml"), "<project/>").unwrap();
    let java = "package com.example; class App { public static void main(String[] args) {} }";
    fs::write(root.join(source), java).unwrap();
    fs::write(root.join(duplicate_source), java).unwrap();
    fs::write(root.join(nested_source), java).unwrap();

    let generate = |paths: Vec<&str>| -> Value {
        serde_json::from_str(&execute_json(
            &serde_json::json!({
                "id": "generate-worktree-duplicate",
                "command": "runConfig.generate",
                "payload": {
                    "root": root,
                    "paths": paths,
                    "modulePaths": []
                }
            })
            .to_string(),
        ))
        .unwrap()
    };
    let response = generate(vec![source, source, duplicate_source, nested_source]);
    let reversed = generate(vec![nested_source, duplicate_source, source, source]);

    assert_eq!(response["ok"], true, "{response}");
    assert_eq!(
        response["data"]["generated"]["configurations"],
        reversed["data"]["generated"]["configurations"]
    );
    let configurations = response["data"]["generated"]["configurations"]
        .as_array()
        .unwrap();
    assert_eq!(
        configurations
            .iter()
            .filter(|value| value["id"] == "java-main:com.example.App")
            .count(),
        1,
        "{configurations:?}"
    );
    assert_eq!(response["data"]["entryCount"], 1);
    assert_eq!(reversed["data"]["entryCount"], 1);
    let inputs = response["data"]["generated"]["generator"]["inputs"]
        .as_object()
        .unwrap();
    assert!(!inputs.keys().any(|path| path.starts_with(".worktree/")));

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn run_configuration_generation_disambiguates_same_main_class_across_modules() {
    let root = temporary_root("run-config-duplicate-main-classes");
    let module_a = "module-a/src/main/java/com/example/App.java";
    let module_b = "module-b/src/main/java/com/example/App.java";
    fs::create_dir_all(root.join("module-a/src/main/java/com/example")).unwrap();
    fs::create_dir_all(root.join("module-b/src/main/java/com/example")).unwrap();
    fs::write(root.join("pom.xml"), "<project/>").unwrap();
    fs::write(root.join("module-a/pom.xml"), "<project/>").unwrap();
    fs::write(root.join("module-b/pom.xml"), "<project/>").unwrap();
    let java = "package com.example; class App { public static void main(String[] args) {} }";
    fs::write(root.join(module_a), java).unwrap();
    fs::write(root.join(module_b), java).unwrap();

    let generate = |paths: Vec<&str>| -> Value {
        serde_json::from_str(&execute_json(
            &serde_json::json!({
                "id": "generate-duplicate-main-classes",
                "command": "runConfig.generate",
                "payload": {
                    "root": root,
                    "paths": paths,
                    "modulePaths": ["module-a", "module-b"]
                }
            })
            .to_string(),
        ))
        .unwrap()
    };
    let response = generate(vec![module_a, module_b]);
    let reversed = generate(vec![module_b, module_a]);

    assert_eq!(response["ok"], true, "{response}");
    assert_eq!(
        response["data"]["generated"]["configurations"],
        reversed["data"]["generated"]["configurations"]
    );
    let configurations = response["data"]["generated"]["configurations"]
        .as_array()
        .unwrap();
    let module_configurations = configurations
        .iter()
        .filter(|value| value["provider"] == "java.main")
        .collect::<Vec<_>>();
    assert_eq!(module_configurations.len(), 2, "{configurations:?}");
    assert!(module_configurations.iter().any(|value| {
        value["id"] == "java-main:com.example.App:module-a"
            && value["extensions"]["maven"]["module"] == "module-a"
    }));
    assert!(module_configurations.iter().any(|value| {
        value["id"] == "java-main:com.example.App:module-b"
            && value["extensions"]["maven"]["module"] == "module-b"
    }));
    assert_eq!(response["data"]["entryCount"], 2);
    assert_eq!(reversed["data"]["entryCount"], 2);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn ordinary_java_main_uses_an_application_launch_plan() {
    let root = temporary_root("run-config-java-main");
    let source = "batch-worker/src/main/java/com/example/WorkerMain.java";
    fs::create_dir_all(root.join("batch-worker/src/main/java/com/example")).unwrap();
    fs::write(root.join("pom.xml"), "<project/>").unwrap();
    fs::write(root.join("batch-worker/pom.xml"), "<project/>").unwrap();
    fs::write(
        root.join(source),
        "package com.example; class WorkerMain { public static void main(String[] args) {} }",
    )
    .unwrap();

    let generated_response: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "generate-java-main",
            "command": "runConfig.generate",
            "payload": {"root": root, "paths": [source], "modulePaths": []}
        })
        .to_string(),
    ))
    .unwrap();
    let generated = &generated_response["data"]["generated"];
    let java_main = generated["configurations"]
        .as_array()
        .unwrap()
        .iter()
        .find(|value| value["provider"] == "java.main")
        .unwrap();
    assert_eq!(java_main["execution"], "application");
    assert_eq!(java_main["extensions"]["maven"]["module"], "batch-worker");

    fs::create_dir_all(root.join(".lithe/run")).unwrap();
    fs::write(
        root.join(".lithe/run/generated.json"),
        serde_json::to_string(generated).unwrap(),
    )
    .unwrap();
    let plan: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "plan-java-main",
            "command": "runConfig.createLaunchPlan",
            "payload": {
                "root": root,
                "configurationId": "java-main:com.example.WorkerMain"
            }
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(plan["ok"], true, "{plan}");
    assert_eq!(plan["data"]["executable"]["toolchain"], "project-maven");
    assert!(plan["data"]["arguments"]
        .as_array()
        .unwrap()
        .iter()
        .any(|value| value == "-Dexec.mainClass=com.example.WorkerMain"));
    assert_eq!(
        plan["data"]["arguments"]
            .as_array()
            .unwrap()
            .last()
            .unwrap(),
        "org.codehaus.mojo:exec-maven-plugin:3.5.0:java"
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn plain_java_main_uses_the_jdk_without_maven() {
    let root = temporary_root("run-config-plain-java-main");
    let source = "src/com/example/WorkerMain.java";
    fs::create_dir_all(root.join("src/com/example")).unwrap();
    fs::write(
        root.join(source),
        "package com.example; class WorkerMain { public static void main(String[] args) {} }",
    )
    .unwrap();

    let generated_response: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "generate-plain-java-main",
            "command": "runConfig.generate",
            "payload": {"root": root, "paths": [source], "modulePaths": []}
        })
        .to_string(),
    ))
    .unwrap();
    let generated = &generated_response["data"]["generated"];
    let java_main = generated["configurations"]
        .as_array()
        .unwrap()
        .iter()
        .find(|value| value["provider"] == "java.main")
        .unwrap();
    assert_eq!(java_main["toolchains"]["java"], "project-jdk");
    assert!(java_main["toolchains"]["maven"].is_null());
    assert_eq!(java_main["source"], source);

    fs::create_dir_all(root.join(".lithe/run")).unwrap();
    fs::write(
        root.join(".lithe/run/generated.json"),
        serde_json::to_string(generated).unwrap(),
    )
    .unwrap();
    let plan: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "plan-plain-java-main",
            "command": "runConfig.createLaunchPlan",
            "payload": {
                "root": root,
                "configurationId": "java-main:com.example.WorkerMain"
            }
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(plan["ok"], true, "{plan}");
    assert_eq!(plan["data"]["executable"]["toolchain"], "project-jdk");
    assert_eq!(plan["data"]["arguments"], serde_json::json!([source]));

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn resolve_prefers_a_host_provided_local_document() {
    let root = temporary_root("run-config-host-local");
    fs::create_dir_all(root.join(".lithe/run")).unwrap();
    fs::write(
        root.join(".lithe/run/generated.json"),
        r#"{"version":2,"configurations":[{"id":"current-file","name":"Current File","provider":"java.current-file","execution":"application","toolchains":{"java":"project-jdk"}}]}"#,
    )
    .unwrap();
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
fn resolve_applies_global_toolchain_defaults_and_preserves_configuration_overrides() {
    let root = temporary_root("run-config-global-toolchain");
    fs::create_dir_all(root.join(".lithe/run")).unwrap();
    fs::write(
        root.join(".lithe/run/generated.json"),
        r#"{"version":2,"configurations":[
            {"id":"spring","name":"Spring","provider":"spring-boot.maven","execution":"service","toolchains":{"java":"project-jdk","maven":"project-maven"},"extensions":{"maven":{"module":"."},"java":{"homePath":"C:/service-jdk","mavenExecutablePath":"C:/service-mvn.cmd"}}},
            {"id":"plain","name":"Plain","provider":"java.main","execution":"application","toolchains":{"java":"project-jdk"},"extensions":{"java":{"source":"src/App.java"}}}
        ]}"#,
    )
    .unwrap();
    fs::write(
        root.join(".lithe/run/local.json"),
        r#"{"version":2,"toolchain":{"java":{"homePath":"C:/custom-jdk"},"maven":{"executablePath":"C:/mvn.cmd","javaHomePath":"C:/maven-jdk"}},"configurations":[]}"#,
    )
    .unwrap();

    let resolved: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "resolve-global-toolchain",
            "command": "runConfig.resolve",
            "payload": {"root": root}
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(resolved["ok"], true, "{resolved}");
    assert_eq!(
        resolved["data"]["toolchain"]["java"]["homePath"],
        "C:/custom-jdk"
    );
    let plain = resolved["data"]["configurations"]
        .as_array()
        .unwrap()
        .iter()
        .find(|value| value["id"] == "plain")
        .unwrap();
    assert_eq!(plain["extensions"]["java"]["homePath"], "C:/custom-jdk");
    assert_eq!(
        plain["extensions"]["java"]["mavenExecutablePath"],
        "C:/mvn.cmd"
    );
    // The project default fills missing runtime paths but never changes the source path.
    assert_eq!(plain["extensions"]["java"]["source"], "src/App.java");
    let spring = resolved["data"]["configurations"]
        .as_array()
        .unwrap()
        .iter()
        .find(|value| value["id"] == "spring")
        .unwrap();
    assert_eq!(spring["extensions"]["java"]["homePath"], "C:/service-jdk");
    assert_eq!(
        spring["extensions"]["java"]["mavenExecutablePath"],
        "C:/service-mvn.cmd"
    );
    assert_eq!(
        spring["extensions"]["java"]["mavenJavaHomePath"],
        "C:/maven-jdk"
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn global_toolchain_updates_only_in_the_local_layer() {
    let root = temporary_root("run-config-toolchain-update");
    fs::create_dir_all(root.join(".lithe/run")).unwrap();
    fs::write(
        root.join(".lithe/run/local.json"),
        r#"{"version":2,"configurations":[]}"#,
    )
    .unwrap();

    let updated: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "update-global-toolchain",
            "command": "runConfig.updateOptions",
            "payload": {
                "root": root,
                "scope": "local",
                "configurationId": "unused",
                "toolchain": {
                    "javaHomePath": "C:/jdk-21",
                    "mavenExecutablePath": "C:/apache-maven/bin/mvn.cmd",
                    "mavenJavaHomePath": "C:/jdk-17"
                }
            }
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(updated["ok"], true, "{updated}");
    let document: Value =
        serde_json::from_str(updated["data"]["document"].as_str().unwrap()).unwrap();
    assert_eq!(document["toolchain"]["java"]["homePath"], "C:/jdk-21");
    assert_eq!(
        document["toolchain"]["maven"]["executablePath"],
        "C:/apache-maven/bin/mvn.cmd"
    );
    assert_eq!(document["toolchain"]["maven"]["javaHomePath"], "C:/jdk-17");

    // Project scope must never accept toolchain paths.
    let rejected: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "update-global-toolchain-project",
            "command": "runConfig.updateOptions",
            "payload": {
                "root": root,
                "scope": "project",
                "configurationId": "unused",
                "toolchain": {"javaHomePath": "C:/jdk-21"}
            }
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(rejected["ok"], false, "{rejected}");

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn run_configuration_inspect_reports_malformed_and_unsupported_documents() {
    let root = temporary_root("run-config-errors");
    fs::create_dir_all(root.join(".lithe/run")).unwrap();
    fs::write(root.join(".lithe/run/generated.json"), "{").unwrap();

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
        root.join(".lithe/run/generated.json"),
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
        root.join(".lithe/run/generated.json"),
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
fn run_configuration_mutations_are_shared_and_validated() {
    let root = temporary_root("run-config-mutations");
    fs::create_dir_all(root.join("src/main/java/com/example")).unwrap();
    fs::create_dir_all(root.join(".lithe/run")).unwrap();
    fs::write(
        root.join("src/main/java/com/example/App.java"),
        "package com.example; class App { public static void main(String[] args) {} }",
    )
    .unwrap();
    fs::write(
        root.join(".lithe/run/generated.json"),
        r#"{"version":1,"configurations":[{"id":"current-file","name":"Current File","type":"java.current-file","toolchains":{"java":"project-jdk"}}]}"#,
    )
    .unwrap();

    let updated: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "update-options",
            "command": "runConfig.updateOptions",
            "payload": {
                "root": root,
                "scope": "project",
                "configurationId": "current-file",
                "workingDirectory": ".",
                "jvmArguments": "\"-Dlabel=hello world\" -Xmx2g",
                "programArguments": "--dev",
                "mavenProfiles": ["dev"]
            }
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(updated["ok"], true);
    let updated_document: Value =
        serde_json::from_str(updated["data"]["document"].as_str().unwrap()).unwrap();
    assert_eq!(
        updated_document["configurations"][0]["extensions"]["maven"]["jvmArguments"],
        serde_json::json!(["-Dlabel=hello world", "-Xmx2g"])
    );
    fs::write(
        root.join(".lithe/run/configurations.json"),
        updated["data"]["document"].as_str().unwrap(),
    )
    .unwrap();

    let create = |name: &str, module: &str, main_class: &str| -> Value {
        serde_json::from_str(&execute_json(
            &serde_json::json!({
                "id": "create-user",
                "command": "runConfig.createUserConfiguration",
                "payload": {
                    "root": root,
                    "scope": "project",
                    "name": name,
                    "type": "springBoot",
                    "module": module,
                    "mainClass": main_class
                }
            })
            .to_string(),
        ))
        .unwrap()
    };
    let first = create("Backend Dev", ".", "com.example.App");
    assert_eq!(first["data"]["id"], "user:backend-dev");
    fs::write(
        root.join(".lithe/run/configurations.json"),
        first["data"]["document"].as_str().unwrap(),
    )
    .unwrap();
    let second = create("Backend Dev", ".", "com.example.App");
    assert_eq!(second["data"]["id"], "user:backend-dev-2");
    assert_eq!(
        create("Outside", "../outside", "com.example.App")["ok"],
        false
    );
    assert_eq!(create("Missing", ".", "com.example.Missing")["ok"], false);

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn project_scoped_toolchain_paths_are_relative_and_stay_inside_the_project() {
    let root = temporary_root("run-config-project-toolchains");
    let outside = temporary_root("run-config-outside-toolchain");
    fs::create_dir_all(root.join(".lithe/run")).unwrap();
    fs::create_dir_all(root.join("toolchains/jdk")).unwrap();
    fs::create_dir_all(root.join("toolchains/maven/bin")).unwrap();
    fs::create_dir_all(root.join("toolchains/maven-jdk")).unwrap();
    fs::create_dir_all(&outside).unwrap();
    fs::write(root.join("toolchains/maven/bin/mvn"), "#!/bin/sh\n").unwrap();
    fs::write(
        root.join(".lithe/run/generated.json"),
        r#"{"version":2,"configurations":[{"id":"spring","name":"Spring","provider":"spring-boot.maven","execution":"service","toolchains":{"java":"project-jdk","maven":"project-maven"},"extensions":{"maven":{"module":"."}}}]}"#,
    )
    .unwrap();

    let updated: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "project-toolchains",
            "command": "runConfig.updateOptions",
            "payload": {
                "root": root,
                "scope": "project",
                "configurationId": "spring",
                "javaHomePath": root.join("toolchains/jdk"),
                "mavenExecutablePath": root.join("toolchains/maven/bin/mvn"),
                "mavenJavaHomePath": root.join("toolchains/maven-jdk")
            }
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(updated["ok"], true, "{updated}");
    let document: Value =
        serde_json::from_str(updated["data"]["document"].as_str().unwrap()).unwrap();
    let java = &document["configurations"][0]["extensions"]["java"];
    assert_eq!(java["homePath"], "toolchains/jdk");
    assert_eq!(java["mavenExecutablePath"], "toolchains/maven/bin/mvn");
    assert_eq!(java["mavenJavaHomePath"], "toolchains/maven-jdk");

    let rejected: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "outside-project-toolchain",
            "command": "runConfig.updateOptions",
            "payload": {
                "root": root,
                "scope": "project",
                "configurationId": "spring",
                "javaHomePath": outside
            }
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(rejected["ok"], false, "{rejected}");

    fs::remove_dir_all(root).unwrap();
    fs::remove_dir_all(outside).unwrap();
}

#[test]
fn run_configuration_generation_detects_declared_toolchain_versions() {
    let root = temporary_root("run-config-toolchains");
    fs::create_dir_all(root.join(".mvn/wrapper")).unwrap();
    fs::write(root.join(".sdkmanrc"), "java=21.0.5-tem\n").unwrap();
    fs::write(root.join("mvnw"), "#!/bin/sh\n").unwrap();
    fs::write(
        root.join(".mvn/wrapper/maven-wrapper.properties"),
        "distributionUrl=https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/3.9.9/apache-maven-3.9.9-bin.zip\n",
    )
    .unwrap();

    let generated: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "generate-toolchains",
            "command": "runConfig.generate",
            "payload": {"root": root, "paths": [], "modulePaths": []}
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(generated["ok"], true);
    assert_eq!(
        generated["data"]["toolchainRequirements"]["toolchains"]["project-jdk"]["minimumVersion"],
        "21"
    );
    assert_eq!(
        generated["data"]["toolchainRequirements"]["toolchains"]["project-jdk"]["preferredVendor"],
        "temurin"
    );
    assert_eq!(
        generated["data"]["toolchainRequirements"]["toolchains"]["project-maven"]["version"],
        "3.9.9"
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn run_configuration_generation_detects_maven_compiler_target() {
    let root = temporary_root("run-config-compiler-target");
    fs::create_dir_all(&root).unwrap();
    fs::write(
        root.join("pom.xml"),
        "<project><properties><maven.compiler.target>17</maven.compiler.target></properties></project>",
    )
    .unwrap();
    let generated: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "generate-target",
            "command": "runConfig.generate",
            "payload": {"root": root, "paths": [], "modulePaths": []}
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(
        generated["data"]["toolchainRequirements"]["toolchains"]["project-jdk"]["minimumVersion"],
        "17"
    );
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn run_configuration_inspection_summarizes_changed_inputs() {
    let root = temporary_root("run-config-input-summary");
    fs::create_dir_all(root.join("src")).unwrap();
    fs::write(root.join("src/App.java"), "class App {}").unwrap();
    let generated: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "generate-summary",
            "command": "runConfig.generate",
            "payload": {"root": root, "paths": ["src/App.java"], "modulePaths": []}
        })
        .to_string(),
    ))
    .unwrap();
    let generated_again: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "generate-summary-again",
            "command": "runConfig.generate",
            "payload": {"root": root, "paths": ["src/App.java"], "modulePaths": []}
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(generated["data"], generated_again["data"]);
    fs::create_dir_all(root.join(".lithe/run")).unwrap();
    fs::write(
        root.join(".lithe/run/generated.json"),
        serde_json::to_string(&generated["data"]["generated"]).unwrap(),
    )
    .unwrap();
    fs::write(root.join("src/App.java"), "class App { int changed; }").unwrap();

    let inspected: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "inspect-summary",
            "command": "runConfig.inspect",
            "payload": {"root": root}
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(inspected["ok"], true);
    assert_eq!(
        inspected["data"]["diagnostics"][0]["message"],
        "Project inputs changed: 0 added, 0 removed, 1 modified"
    );

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn run_configuration_resolve_matches_toolchains_and_rejects_unsafe_paths() {
    let root = temporary_root("run-config-toolchain-resolution");
    fs::create_dir_all(root.join(".lithe/run")).unwrap();
    fs::create_dir_all(root.join(".lithe/toolchains")).unwrap();
    fs::write(
        root.join(".lithe/run/generated.json"),
        r#"{"version":1,"configurations":[{"id":"current-file","name":"Current File","type":"java.current-file"}]}"#,
    )
    .unwrap();
    fs::write(
        root.join(".lithe/toolchains/requirements.json"),
        r#"{"version":1,"toolchains":{"project-jdk":{"type":"java","minimumVersion":"21","preferredVendor":"temurin"}}}"#,
    )
    .unwrap();

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
fn run_configuration_main_class_validation_uses_the_declared_package() {
    let root = temporary_root("run-config-main-class-package");
    fs::create_dir_all(root.join(".lithe/run")).unwrap();
    fs::create_dir_all(root.join("src/main/java/other")).unwrap();
    fs::write(
        root.join("src/main/java/other/App.java"),
        "package other; class App {}",
    )
    .unwrap();
    fs::write(
        root.join(".lithe/run/generated.json"),
        r#"{"version":1,"configurations":[{"id":"spring:com.example.App","name":"App","type":"spring-boot.maven","mainClass":"com.example.App"}]}"#,
    )
    .unwrap();

    let resolved: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "resolve-main-class",
            "command": "runConfig.resolve",
            "payload": {"root": root}
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(resolved["ok"], true);
    assert!(resolved["data"]["diagnostics"]
        .as_array()
        .unwrap()
        .iter()
        .any(|value| value["code"] == "missingMainClass"));

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
fn run_configuration_resolve_diagnoses_orphans_and_deleted_modules() {
    let root = temporary_root("run-config-diagnostics");
    fs::create_dir_all(root.join(".lithe/run")).unwrap();
    fs::write(
        root.join(".lithe/run/generated.json"),
        r#"{"version":1,"configurations":[{"id":"current-file","name":"Current File","type":"java.current-file"},{"id":"module:deleted","name":"Deleted","type":"maven.module","module":"deleted"}]}"#,
    )
    .unwrap();
    fs::write(
        root.join(".lithe/run/local.json"),
        r#"{"version":1,"configurations":[{"id":"module:old","jvmArguments":["-Xmx1g"]}]}"#,
    )
    .unwrap();

    let resolved: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "resolve-diagnostics",
            "command": "runConfig.resolve",
            "payload": {"root": root}
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(resolved["ok"], true);
    assert!(resolved["data"]["diagnostics"]
        .as_array()
        .unwrap()
        .iter()
        .any(|value| value["code"] == "orphanedOverride"));
    assert!(resolved["data"]["diagnostics"]
        .as_array()
        .unwrap()
        .iter()
        .any(|value| value["code"] == "missingModule"));

    fs::write(
        root.join(".lithe/run/local.json"),
        r#"{"version":1,"configurations":[{"id":"module:deleted","jvmArguments":["-Xmx1g"]}]}"#,
    )
    .unwrap();
    let resolved: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "resolve-missing-module",
            "command": "runConfig.resolve",
            "payload": {"root": root}
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(resolved["ok"], true);
    assert_eq!(
        resolved["data"]["configurations"].as_array().unwrap().len(),
        1
    );
    assert!(resolved["data"]["diagnostics"]
        .as_array()
        .unwrap()
        .iter()
        .any(|value| value["code"] == "missingModule"));

    fs::remove_dir_all(root).unwrap();
}

/// The v1 -> v2 rewrite must not change a single byte of the emitted command
/// line. Values are asserted literally rather than recomputed, so a future
/// refactor that silently drops an argument fails here instead of at runtime.
#[test]
fn migrated_v1_documents_produce_identical_launch_arguments() {
    let root = temporary_root("run-config-migration");
    fs::create_dir_all(root.join("backend/src/main/java/com/example")).unwrap();
    fs::create_dir_all(root.join(".lithe/run")).unwrap();
    fs::write(root.join("pom.xml"), "<project/>").unwrap();
    fs::write(root.join("backend/pom.xml"), "<project/>").unwrap();
    fs::write(
        root.join("backend/src/main/java/com/example/App.java"),
        "package com.example; class App { public static void main(String[] args) {} }",
    )
    .unwrap();
    fs::write(
        root.join(".lithe/run/generated.json"),
        r#"{"version":1,"configurations":[{
            "id":"spring:com.example.App",
            "name":"App",
            "type":"spring-boot.maven",
            "module":"backend",
            "workingDirectory":".",
            "mainClass":"com.example.App",
            "jvmArguments":["-Xmx2g"],
            "programArguments":["--dev"],
            "mavenProfiles":["local"],
            "toolchains":{"java":"project-jdk","maven":"project-maven"}
        }]}"#,
    )
    .unwrap();

    let plan: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "migrated-plan",
            "command": "runConfig.createLaunchPlan",
            "payload": {
                "root": root,
                "configurationId": "spring:com.example.App",
                "debugPort": 5005
            }
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(plan["ok"], true);
    assert_eq!(
        plan["data"]["arguments"],
        serde_json::json!([
            "-B",
            "-ntp",
            "-pl",
            "backend",
            "-P",
            "local",
            "-Dspring-boot.run.main-class=com.example.App",
            "-Dspring-boot.run.jvmArguments=-agentlib:jdwp=transport=dt_socket,server=y,suspend=y,address=127.0.0.1:5005 -Duser.language=en -Duser.country=US -Xmx2g",
            "-Dspring-boot.run.arguments=--dev",
            "spring-boot:run"
        ])
    );
    assert_eq!(plan["data"]["workingDirectory"], ".");
    assert_eq!(plan["data"]["executable"]["toolchain"], "project-maven");

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
    fs::write(
        root.join(".lithe/run/generated.json"),
        r#"{"version":1,"configurations":[{"id":"current-file","name":"Current File","type":"java.current-file"}]}"#,
    )
    .unwrap();
    fs::write(
        root.join(".lithe/project.json"),
        r#"{"version":1,"defaultRunConfiguration":"current-file"}"#,
    )
    .unwrap();
    fs::write(
        root.join(".lithe/toolchains/requirements.json"),
        r#"{"version":1,"toolchains":{}}"#,
    )
    .unwrap();

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
    fs::write(
        root.join(".lithe/run/generated.json"),
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
    )
    .unwrap();

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
    fs::write(
        root.join(".lithe/run/generated.json"),
        r#"{"version":2,"configurations":[{
            "id":"go:api","name":"Go API","provider":"go.main",
            "execution":"application","args":["run","./cmd/api"],"cwd":".",
            "env":{"APP_ENV":"dev"},"toolchains":{"runtime":"project-go"}
        }]}"#,
    )
    .unwrap();

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
fn multi_language_generation_declares_runtime_requirements_and_versions() {
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
    for (id, kind, version) in [
        ("project-go", "go", "1.24"),
        ("project-python", "python", "3.12"),
        ("project-node", "node", "22.4"),
        ("project-cargo", "rust", "1.82"),
    ] {
        assert_eq!(requirements[id]["type"], kind, "{requirements}");
        assert_eq!(
            requirements[id]["minimumVersion"], version,
            "{requirements}"
        );
    }
    assert!(requirements["project-jdk"].is_null(), "{requirements}");

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn unknown_provider_without_an_executable_never_falls_into_maven() {
    let root = temporary_root("run-config-unknown-provider");
    fs::create_dir_all(root.join(".lithe/run")).unwrap();
    fs::write(
        root.join(".lithe/run/generated.json"),
        r#"{"version":2,"configurations":[{
            "id":"zig:app","name":"Zig App","provider":"zig.main",
            "args":[],"cwd":".","toolchains":{}
        }]}"#,
    )
    .unwrap();
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
    fs::write(
        root.join(".lithe/run/generated.json"),
        r#"{"version":2,"configurations":[{
            "id":"python:api","name":"API","provider":"python.script",
            "command":"python3","args":["app.py"],"cwd":".","toolchains":{}
        }]}"#,
    )
    .unwrap();

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
    fs::write(
        root.join(".lithe/run/generated.json"),
        r#"{"version":2,"configurations":[{
            "id":"evil","name":"evil","provider":"shell.command",
            "command":"../../../usr/bin/curl","args":[],"cwd":".","toolchains":{}
        }]}"#,
    )
    .unwrap();

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
