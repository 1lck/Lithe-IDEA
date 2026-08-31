use super::support::temporary_root;
use crate::execute_json;
use serde_json::Value;
use std::fs;

#[test]
fn jdt_workspace_key_matches_the_shared_compatibility_fixture() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../shared/fixtures/lsp/jdt-workspace-key-v1.json"
    ))
    .expect("JDT workspace-key fixture should be valid JSON");

    for case in fixture["cases"]
        .as_array()
        .expect("JDT workspace-key fixture should contain cases")
    {
        let request = serde_json::json!({
            "id": case["name"],
            "command": "lsp.jdtWorkspaceKey",
            "payload": {
                "workspaceRoot": case["workspaceRoot"],
                "workspaceFingerprint": case["workspaceFingerprint"]
            }
        });
        let response: Value = serde_json::from_str(&execute_json(&request.to_string()))
            .expect("JDT workspace-key response should be JSON");

        assert_eq!(response["ok"], true, "case {}", case["name"]);
        assert_eq!(
            response["data"]["workspaceKey"], case["workspaceKey"],
            "case {}",
            case["name"]
        );
    }
}

#[test]
fn java_workspace_policy_matches_the_shared_compatibility_fixture() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../shared/fixtures/lsp/java-workspace-policy-v1.json"
    ))
    .expect("Java workspace-policy fixture should be valid JSON");

    for case in fixture["cases"]
        .as_array()
        .expect("Java workspace-policy fixture should contain cases")
    {
        let request = serde_json::json!({
            "id": case["name"],
            "command": "java.workspacePolicy",
            "payload": {
                "workspacePaths": case["workspacePaths"],
                "changedPaths": case["changedPaths"]
            }
        });
        let response: Value = serde_json::from_str(&execute_json(&request.to_string()))
            .expect("Java workspace-policy response should be JSON");

        assert_eq!(response["ok"], true, "case {}", case["name"]);
        assert_eq!(response["data"], case["expected"], "case {}", case["name"]);
    }
}

#[test]
fn jdt_workspace_fingerprint_matches_the_shared_compatibility_fixture() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../shared/fixtures/lsp/jdt-workspace-fingerprint-v1.json"
    ))
    .expect("JDT workspace-fingerprint fixture should be valid JSON");

    for case in fixture["cases"]
        .as_array()
        .expect("JDT workspace-fingerprint fixture should contain cases")
    {
        let request = serde_json::json!({
            "id": case["name"],
            "command": "java.jdtWorkspaceFingerprint",
            "payload": {
                "buildFiles": case["buildFiles"],
                "directMavenModules": case["directMavenModules"],
                "jdtlsVersion": case["jdtlsVersion"]
            }
        });
        let response: Value = serde_json::from_str(&execute_json(&request.to_string()))
            .expect("JDT workspace-fingerprint response should be JSON");

        assert_eq!(response["ok"], true, "case {}", case["name"]);
        assert_eq!(
            response["data"]["workspaceFingerprint"], case["workspaceFingerprint"],
            "case {}",
            case["name"]
        );
    }
}

#[test]
fn jdt_cache_retention_matches_the_shared_compatibility_fixture() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../shared/fixtures/lsp/jdt-cache-retention-v1.json"
    ))
    .expect("JDT cache-retention fixture should be valid JSON");

    for case in fixture["cases"]
        .as_array()
        .expect("JDT cache-retention fixture should contain cases")
    {
        let request = serde_json::json!({
            "id": case["name"],
            "command": "java.jdtCacheRetention",
            "payload": {
                "nowUnixSeconds": case["nowUnixSeconds"],
                "activeWorkspaceKey": case["activeWorkspaceKey"],
                "entries": case["entries"]
            }
        });
        let response: Value = serde_json::from_str(&execute_json(&request.to_string()))
            .expect("JDT cache-retention response should be JSON");

        assert_eq!(response["ok"], true, "case {}", case["name"]);
        assert_eq!(response["data"], case["expected"], "case {}", case["name"]);
    }
}

#[test]
fn maven_scan_returns_recursive_shared_project_model() {
    let root = temporary_root("maven");
    fs::create_dir_all(root.join("module-a/module-b")).expect("modules should be creatable");
    fs::write(
        root.join("pom.xml"),
        r#"<project><groupId>com.example</groupId><artifactId>demo</artifactId><version>1</version><packaging>pom</packaging><modules><module>module-a</module></modules><profiles><profile><id>dev</id><activation><activeByDefault>true</activeByDefault></activation></profile></profiles></project>"#,
    )
    .expect("root pom should be writable");
    fs::write(
        root.join("module-a/pom.xml"),
        r#"<project><artifactId>one</artifactId><modules><module>module-b</module></modules></project>"#,
    )
    .expect("module pom should be writable");
    fs::write(
        root.join("module-a/module-b/pom.xml"),
        r#"<project><artifactId>two</artifactId></project>"#,
    )
    .expect("nested pom should be writable");
    fs::write(root.join("mvnw.cmd"), "@echo off\n").expect("wrapper should be writable");

    let request = serde_json::json!({
        "id": "maven",
        "command": "maven.scan",
        "payload": {"root": root, "paths": ["module-a/pom.xml", "pom.xml"]}
    });
    let response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&request).expect("Maven request should encode"),
    ))
    .expect("Maven response should be JSON");
    assert_eq!(response["ok"], true);
    assert_eq!(response["data"]["relativePath"], ".");
    assert_eq!(response["data"]["artifactId"], "demo");
    assert_eq!(response["data"]["packaging"], "pom");
    assert_eq!(response["data"]["profiles"][0]["id"], "dev");
    assert_eq!(response["data"]["hasWrapper"], true);
    assert_eq!(response["data"]["modules"][0]["relativePath"], "module-a");
    assert_eq!(
        response["data"]["modules"][0]["modules"][0]["relativePath"],
        "module-a/module-b"
    );
    let diagnostics = serde_json::json!({
        "id": "maven-diagnostics",
        "command": "maven.diagnostics",
        "payload": {
            "root": root,
            "output": "[ERROR] src/App.java:[12,4] cannot find symbol\n[ERROR] src/App.java:[12,4] cannot find symbol\n[WARNING] src/App.java:[4] unused import\n"
        }
    });
    let diagnostics_response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&diagnostics).expect("diagnostics request should encode"),
    ))
    .expect("diagnostics response should be JSON");
    assert_eq!(diagnostics_response["ok"], true);
    assert_eq!(
        diagnostics_response["data"]["issues"]
            .as_array()
            .unwrap()
            .len(),
        2
    );
    assert_eq!(
        diagnostics_response["data"]["issues"][0]["severity"],
        "error"
    );
    fs::remove_dir_all(root).expect("Maven fixture should be removable");
}

#[test]
fn maven_launch_plan_matches_the_shared_compatibility_fixture() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../shared/fixtures/maven/launch-plan-v1.json"
    ))
    .expect("Maven launch-plan fixture should be valid JSON");
    let root = temporary_root("maven-launch-plan");
    fs::create_dir_all(root.join("projects/demo/service-api"))
        .expect("nested Maven reactor should be creatable");
    fs::write(
        root.join("projects/demo/pom.xml"),
        r#"<project><artifactId>demo</artifactId><packaging>pom</packaging><modules><module>service-api</module></modules></project>"#,
    )
    .expect("reactor pom should be writable");
    fs::write(
        root.join("projects/demo/service-api/pom.xml"),
        r#"<project><artifactId>service-api</artifactId></project>"#,
    )
    .expect("module pom should be writable");
    fs::write(
        root.join("pom.xml"),
        r#"<project><artifactId>root</artifactId></project>"#,
    )
    .expect("root pom should be writable");
    fs::create_dir_all(root.join(".mvn")).expect("Maven config directory should be creatable");
    fs::write(root.join(".mvn/maven.config"), "-DfromConfig=true\n")
        .expect("Maven config should be writable");

    for case in fixture["cases"]
        .as_array()
        .expect("Maven launch-plan fixture should contain cases")
    {
        let request = serde_json::json!({
            "id": case["name"],
            "command": "maven.launchPlan",
            "payload": {
                "root": root,
                "context": case["context"],
                "module": case["module"],
                "goals": case["goals"]
            }
        });
        let response: Value = serde_json::from_str(&execute_json(&request.to_string()))
            .expect("Maven launch-plan response should be JSON");

        assert_eq!(response["ok"], true, "case {}: {response}", case["name"]);
        assert_eq!(response["data"], case["expected"], "case {}", case["name"]);
        assert!(!response["data"]["arguments"]
            .as_array()
            .expect("arguments should be an array")
            .iter()
            .any(|argument| argument == "-DfromConfig=true"));
    }
    fs::remove_dir_all(root).expect("Maven launch-plan fixture should be removable");
}

#[test]
fn maven_launch_plan_rejects_unknown_modules_and_invalid_invocation_tokens() {
    let root = temporary_root("maven-launch-invalid");
    fs::create_dir_all(&root).expect("invalid Maven fixture should be creatable");
    fs::write(
        root.join("pom.xml"),
        r#"<project><artifactId>demo</artifactId></project>"#,
    )
    .expect("pom should be writable");
    for (name, module, goals) in [
        ("unknown-module", Some("missing"), vec!["verify"]),
        ("missing-goal", None, vec!["-q", "-DskipTests"]),
        ("invalid-goal", None, vec!["verify;", "-q"]),
        (
            "control-character",
            None,
            vec!["verify", "-Dvalue=line\nbreak"],
        ),
    ] {
        let response: Value = serde_json::from_str(&execute_json(
            &serde_json::json!({
                "id": name,
                "command": "maven.launchPlan",
                "payload": {
                    "root": root,
                    "context": {"version": 1, "reactorPath": "."},
                    "module": module,
                    "goals": goals
                }
            })
            .to_string(),
        ))
        .expect("invalid Maven response should be JSON");
        assert_eq!(response["ok"], false, "case {name}: {response}");
        assert_eq!(response["error"]["code"], "invalid_request");
    }
    fs::remove_dir_all(root).expect("invalid Maven fixture should be removable");
}

#[test]
fn maven_scan_discovers_a_deterministic_project_below_the_workspace() {
    let root = temporary_root("nested-maven");
    fs::create_dir_all(root.join("apps-a/module-a")).expect("first project should be creatable");
    fs::create_dir_all(root.join("apps-z")).expect("second project should be creatable");
    fs::write(
        root.join("apps-a/pom.xml"),
        r#"<project><artifactId>selected</artifactId><packaging>pom</packaging><modules><module>module-a</module></modules></project>"#,
    )
    .expect("first pom should be writable");
    fs::write(
        root.join("apps-a/module-a/pom.xml"),
        r#"<project><artifactId>child</artifactId></project>"#,
    )
    .expect("module pom should be writable");
    fs::write(
        root.join("apps-z/pom.xml"),
        r#"<project><artifactId>other</artifactId></project>"#,
    )
    .expect("second pom should be writable");

    let request = serde_json::json!({
        "id": "nested-maven",
        "command": "maven.scan",
        "payload": {
            "root": root,
            "paths": [
                "apps-z/pom.xml",
                "apps-a/module-a/pom.xml",
                "apps-a/pom.xml"
            ]
        }
    });
    let response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&request).expect("Maven request should encode"),
    ))
    .expect("Maven response should be JSON");

    assert_eq!(response["ok"], true);
    assert_eq!(response["data"]["relativePath"], "apps-a");
    assert_eq!(response["data"]["artifactId"], "selected");
    assert_eq!(response["data"]["modules"][0]["relativePath"], "module-a");
    fs::remove_dir_all(root).expect("Maven fixture should be removable");
}

#[test]
fn maven_scan_skips_a_malformed_root_descriptor_for_a_valid_nested_project() {
    let root = temporary_root("nested-maven-malformed-root");
    fs::create_dir_all(root.join("projects/demo")).expect("nested project should be creatable");
    fs::write(root.join("pom.xml"), "<project><artifactId>broken")
        .expect("malformed root pom should be writable");
    fs::write(
        root.join("projects/demo/pom.xml"),
        r#"<project><artifactId>selected</artifactId></project>"#,
    )
    .expect("nested pom should be writable");

    let request = serde_json::json!({
        "id": "nested-maven-malformed-root",
        "command": "maven.scan",
        "payload": {
            "root": root,
            "paths": ["pom.xml", "projects/demo/pom.xml"]
        }
    });
    let response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&request).expect("Maven request should encode"),
    ))
    .expect("Maven response should be JSON");

    assert_eq!(response["ok"], true, "{response}");
    assert_eq!(response["data"]["relativePath"], "projects/demo");
    assert_eq!(response["data"]["artifactId"], "selected");
    fs::remove_dir_all(root).expect("Maven fixture should be removable");
}

#[test]
fn java_run_configurations_match_workspace_relative_nested_maven_modules() {
    let root = temporary_root("java-nested-maven-module");
    let source = "projects/demo/service/src/main/java/com/example/App.java";
    fs::create_dir_all(root.join("projects/demo/service/src/main/java/com/example"))
        .expect("nested Java source directory should be creatable");
    fs::write(
        root.join(source),
        "package com.example; @SpringBootApplication class App { public static void main(String[] args) {} }",
    )
    .expect("nested Java source should be writable");

    let request = serde_json::json!({
        "id": "java-nested-maven-module",
        "command": "java.runConfigurations",
        "payload": {
            "root": root,
            "paths": [source],
            "modulePaths": ["projects/demo/service"]
        }
    });
    let response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&request).expect("Java request should encode"),
    ))
    .expect("Java response should be JSON");

    assert_eq!(response["ok"], true, "{response}");
    assert_eq!(
        response["data"]["configurations"][0]["modulePath"],
        "projects/demo/service"
    );
    fs::remove_dir_all(root).expect("Java fixture should be removable");
}

#[test]
fn java_core_commands_return_shared_runtime_and_structure_data() {
    let root = temporary_root("java");
    fs::create_dir_all(root.join("src/main/java/com/example"))
        .expect("Java source should be creatable");
    fs::write(
        root.join("src/main/java/com/example/App.java"),
        "package com.example;\n@SpringBootApplication\nclass App {\n    static void main(String[] args) {}\n}\n",
    )
    .expect("Java source should be writable");
    let configurations = serde_json::json!({
        "id": "java-config",
        "command": "java.runConfigurations",
        "payload": {
            "root": root,
            "paths": ["src/main/java/com/example/App.java"],
            "modulePaths": ["src"]
        }
    });
    let response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&configurations).expect("Java request should encode"),
    ))
    .expect("Java response should be JSON");
    assert_eq!(response["ok"], true);
    assert_eq!(
        response["data"]["mainClasses"][0]["qualifiedName"],
        "com.example.App"
    );
    assert_eq!(response["data"]["configurations"][0]["kind"], "springBoot");
    assert_eq!(response["data"]["configurations"][0]["modulePath"], "src");

    let structure = serde_json::json!({
        "id": "java-structure",
        "command": "java.structure",
        "payload": {
            "source": "import a.A;\nimport b.B;\ninterface Service { String call(String value); }\n"
        }
    });
    let structure_response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&structure).expect("Java structure request should encode"),
    ))
    .expect("Java structure response should be JSON");
    assert_eq!(structure_response["ok"], true);
    assert_eq!(
        structure_response["data"]["foldRegions"][0]["kind"],
        "imports"
    );
    assert!(structure_response["data"]
        .get("implementationMarkers")
        .is_none());
    let syntax_highlights = structure_response["data"]["syntaxHighlights"]
        .as_array()
        .expect("Java structure should return syntax highlights");
    assert!(syntax_highlights
        .iter()
        .any(|highlight| highlight["role"] == "keyword"));
    for role in ["functionDeclaration", "parameter", "punctuation", "type"] {
        assert!(
            syntax_highlights
                .iter()
                .any(|highlight| highlight["role"] == role),
            "Java structure should include the {role} role"
        );
    }
    assert!(syntax_highlights.iter().all(|highlight| {
        highlight["utf16Start"].as_u64().is_some()
            && highlight["utf16Length"]
                .as_u64()
                .is_some_and(|length| length > 0)
    }));
    let swift_structure = serde_json::json!({
        "id": "swift-structure",
        "command": "java.structure",
        "payload": {
            "source": "struct Demo {\n    func run() {\n        if ready {\n            work()\n        }\n    }\n}\n"
        }
    });
    let swift_structure_response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&swift_structure).expect("Swift structure request should encode"),
    ))
    .expect("Swift structure response should be JSON");
    let swift_folds = swift_structure_response["data"]["foldRegions"]
        .as_array()
        .expect("Swift structure should return fold regions");
    assert!(swift_folds
        .iter()
        .any(|fold| { fold["startLine"] == 0 && fold["endLine"] == 6 && fold["kind"] == "type" }));
    assert!(swift_folds.iter().any(|fold| {
        fold["startLine"] == 1 && fold["endLine"] == 5 && fold["kind"] == "method"
    }));
    let code_vision = serde_json::json!({
        "id": "java-vision",
        "command": "java.codeVision",
        "payload": {
            "root": root,
            "targetPath": "src/main/java/com/example/App.java",
            "paths": ["src/main/java/com/example/App.java"]
        }
    });
    let vision_response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&code_vision).expect("code vision request should encode"),
    ))
    .expect("code vision response should be JSON");
    assert_eq!(vision_response["ok"], true);
    assert!(vision_response["data"]["hints"]
        .as_array()
        .unwrap()
        .iter()
        .any(|hint| hint["symbol"] == "App"));
    let class_name = serde_json::json!({
        "id": "java-class",
        "command": "java.className",
        "payload": {"source": "package com.example;\nclass App {}", "simpleName": "App"}
    });
    let class_response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&class_name).expect("class name request should encode"),
    ))
    .expect("class name response should be JSON");
    assert_eq!(class_response["data"]["className"], "com.example.App");
    let definition = serde_json::json!({
        "id": "java-definition",
        "command": "java.sourceDefinition",
        "payload": {
            "source": "class App {\n    void run() {}\n}",
            "declarationName": "App",
            "memberName": "run"
        }
    });
    let definition_response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&definition).expect("definition request should encode"),
    ))
    .expect("definition response should be JSON");
    assert_eq!(definition_response["data"]["line"], 1);
    let server_port = serde_json::json!({
        "id": "java-port",
        "command": "java.serverPort",
        "payload": {"content": "server:\n  port: 8080\n", "fileExtension": "yml"}
    });
    let port_response: Value = serde_json::from_str(&execute_json(
        &serde_json::to_string(&server_port).expect("server port request should encode"),
    ))
    .expect("server port response should be JSON");
    assert_eq!(port_response["data"]["port"], 8080);
    fs::remove_dir_all(root).expect("Java fixture should be removable");
}
