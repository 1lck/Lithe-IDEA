use super::support::temporary_root;
use crate::execute_json;
use serde_json::Value;
use std::fs;

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
            "source": "import a.A;\nimport b.B;\ninterface Service {}\n"
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
    assert_eq!(
        structure_response["data"]["implementationMarkers"][0]["direction"],
        "down"
    );
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
