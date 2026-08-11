use super::support::temporary_root;
use crate::execute_json;
use serde_json::Value;
use std::fs;
use std::path::Path;

/// Builds a project that mixes six ecosystems in one tree, including the
/// traps that break naive detectors: a lockfile that is not npm's, a
/// `node_modules` full of decoy manifests, and a Go command in a
/// subdirectory with no manifest of its own.
fn multi_language_project(root: &Path) {
    for directory in ["frontend/node_modules/decoy", "api", "cmd/gateway"] {
        fs::create_dir_all(root.join(directory)).unwrap();
    }
    fs::write(
        root.join("frontend/package.json"),
        r#"{"name":"web","scripts":{"dev":"vite","build":"vite build"}}"#,
    )
    .unwrap();
    fs::write(root.join("frontend/pnpm-lock.yaml"), "lockfileVersion: 9\n").unwrap();
    fs::write(
        root.join("frontend/node_modules/decoy/package.json"),
        r#"{"scripts":{"dev":"should-never-appear"}}"#,
    )
    .unwrap();
    fs::write(
        root.join("api/pyproject.toml"),
        "[tool.poetry]\nname = \"api\"\n[tool.poetry.scripts]\napi-server = \"api.main:run\"\n",
    )
    .unwrap();
    fs::write(
        root.join("api/main.py"),
        "from fastapi import FastAPI\napp = FastAPI()\n",
    )
    .unwrap();
    fs::write(root.join("go.mod"), "module example.com/gw\ngo 1.22\n").unwrap();
    fs::write(
        root.join("cmd/gateway/main.go"),
        "package main\nfunc main() {}\n",
    )
    .unwrap();
    fs::write(
        root.join("docker-compose.yml"),
        "services:\n  db:\n    image: postgres\n  cache:\n    image: redis\n",
    )
    .unwrap();
    fs::write(
        root.join("Procfile"),
        "worker: python worker/run.py\nweb: gunicorn api.main:app\n",
    )
    .unwrap();
    fs::write(
        root.join("Makefile"),
        "run:\n\techo run\nclean:\n\techo clean\n",
    )
    .unwrap();
}

fn generated_configurations(root: &Path) -> Vec<Value> {
    let response: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "generate",
            "command": "runConfig.generate",
            "payload": {"root": root}
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(response["ok"], true, "{response}");
    response["data"]["generated"]["configurations"]
        .as_array()
        .cloned()
        .unwrap()
}

/// The headline behaviour: one project, six ecosystems, every service found
/// without the user configuring anything.
#[test]
fn detectors_find_services_across_unrelated_ecosystems() {
    let root = temporary_root("detect-multi");
    fs::create_dir_all(&root).unwrap();
    multi_language_project(&root);

    let ids = generated_configurations(&root)
        .iter()
        .map(|item| item["id"].as_str().unwrap().to_string())
        .collect::<Vec<_>>();

    for expected in [
        "npm.script:frontend/dev",
        "python.script:api/api-server",
        "python.uvicorn:api/main",
        "go.command:cmd/gateway/gateway",
        "compose.service:db",
        "compose.stack:compose up",
        "procfile.process:web",
        "make.target:run",
    ] {
        assert!(
            ids.contains(&expected.to_string()),
            "missing {expected} in {ids:?}"
        );
    }

    fs::remove_dir_all(root).unwrap();
}

/// A dependency tree contains thousands of manifests. Descending into it
/// would both bury the real services and make project open unusably slow.
#[test]
fn detectors_never_descend_into_dependency_directories() {
    let root = temporary_root("detect-prune");
    fs::create_dir_all(&root).unwrap();
    multi_language_project(&root);

    let sources = generated_configurations(&root)
        .iter()
        .filter_map(|item| item["source"].as_str().map(str::to_string))
        .collect::<Vec<_>>();

    assert!(
        !sources.iter().any(|source| source.contains("node_modules")),
        "{sources:?}"
    );

    fs::remove_dir_all(root).unwrap();
}

/// Running `npm run dev` in a pnpm workspace fails at spawn time with an
/// error that points nowhere useful, so the lockfile decides the command.
#[test]
fn npm_detector_uses_the_package_manager_the_lockfile_names() {
    let root = temporary_root("detect-pnpm");
    fs::create_dir_all(&root).unwrap();
    multi_language_project(&root);

    let dev = generated_configurations(&root)
        .into_iter()
        .find(|item| item["id"] == "npm.script:frontend/dev")
        .unwrap();

    assert_eq!(dev["command"], "pnpm");
    assert_eq!(dev["args"], serde_json::json!(["run", "dev"]));
    assert_eq!(dev["cwd"], "frontend");
    assert_eq!(dev["execution"], "service");

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn npm_detector_inherits_the_workspace_package_manager() {
    let root = temporary_root("detect-pnpm-workspace");
    fs::create_dir_all(root.join("apps/web")).unwrap();
    fs::write(root.join("pnpm-lock.yaml"), "lockfileVersion: 9\n").unwrap();
    fs::write(
        root.join("apps/web/package.json"),
        r#"{"scripts":{"dev":"vite"}}"#,
    )
    .unwrap();

    let dev = generated_configurations(&root)
        .into_iter()
        .find(|item| item["id"] == "npm.script:apps/web/dev")
        .unwrap();
    assert_eq!(dev["command"], "pnpm");
    assert_eq!(dev["execution"], "service");

    fs::remove_dir_all(root).unwrap();
}

#[test]
fn detectors_preserve_application_service_and_task_semantics() {
    let root = temporary_root("detect-execution-semantics");
    fs::create_dir_all(&root).unwrap();
    multi_language_project(&root);
    let configurations = generated_configurations(&root);
    let execution = |id: &str| {
        configurations
            .iter()
            .find(|item| item["id"] == id)
            .and_then(|item| item["execution"].as_str())
    };

    assert_eq!(execution("npm.script:frontend/dev"), Some("service"));
    assert_eq!(execution("npm.script:frontend/build"), Some("task"));
    assert_eq!(
        execution("python.script:api/api-server"),
        Some("application")
    );
    assert_eq!(
        execution("go.command:cmd/gateway/gateway"),
        Some("application")
    );
    assert_eq!(execution("compose.stack:compose up"), Some("service"));

    fs::remove_dir_all(root).unwrap();
}

/// Detected entries are process-based, so they must survive the same launch
/// path as any other configuration without acquiring Java assumptions.
#[test]
fn detected_services_produce_runnable_launch_plans() {
    let root = temporary_root("detect-launch");
    fs::create_dir_all(&root).unwrap();
    multi_language_project(&root);
    let generated = serde_json::json!({
        "version": 2,
        "configurations": generated_configurations(&root)
    });
    fs::create_dir_all(root.join(".lithe/run")).unwrap();
    fs::write(
        root.join(".lithe/run/generated.json"),
        serde_json::to_string(&generated).unwrap(),
    )
    .unwrap();

    let plan: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "plan",
            "command": "runConfig.createLaunchPlan",
            "payload": {"root": root, "configurationId": "npm.script:frontend/dev"}
        })
        .to_string(),
    ))
    .unwrap();

    assert_eq!(plan["ok"], true, "{plan}");
    assert_eq!(plan["data"]["executable"]["command"], "pnpm");
    assert!(plan["data"]["executable"]["toolchain"].is_null());
    assert_eq!(plan["data"]["workingDirectory"], "frontend");
    assert!(plan["data"]["environment"]["JAVA_HOME"].is_null());

    fs::remove_dir_all(root).unwrap();
}

/// Ids are the join key for the team and local override layers. A detector
/// that renamed a Java configuration would silently detach every override
/// written against it, with no error anywhere.
#[test]
fn detectors_never_claim_an_id_the_java_scan_already_produced() {
    let root = temporary_root("detect-no-clobber");
    fs::create_dir_all(&root).unwrap();
    multi_language_project(&root);
    fs::create_dir_all(root.join("src")).unwrap();
    fs::write(
        root.join("src/Main.java"),
        "class Main { public static void main(String[] args) {} }",
    )
    .unwrap();

    let response: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "generate-with-java",
            "command": "runConfig.generate",
            "payload": {"root": root, "paths": ["src/Main.java"]}
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(response["ok"], true, "{response}");
    let ids = response["data"]["generated"]["configurations"]
        .as_array()
        .unwrap()
        .iter()
        .map(|item| item["id"].as_str().unwrap().to_string())
        .collect::<Vec<_>>();
    let mut unique = ids.clone();
    unique.sort();
    unique.dedup();

    assert_eq!(ids.len(), unique.len(), "duplicate ids in {ids:?}");
    assert!(ids.contains(&"current-file".to_string()));

    fs::remove_dir_all(root).unwrap();
}

/// A Java project that also ships a frontend must gain the frontend's
/// services without any Java configuration changing id. Ids are the join key
/// for the team and local layers, so a shifted id detaches every override
/// silently -- there is no error to notice.
#[test]
fn detectors_extend_a_java_project_without_disturbing_its_configurations() {
    let root = temporary_root("detect-java-mixed");
    let module = root.join("backend-api/src/main/java/com/demo");
    fs::create_dir_all(&module).unwrap();
    fs::create_dir_all(root.join("frontend-web")).unwrap();
    fs::write(
        root.join("pom.xml"),
        "<project><modules><module>backend-api</module></modules></project>",
    )
    .unwrap();
    fs::write(root.join("backend-api/pom.xml"), "<project></project>").unwrap();
    fs::write(
        module.join("BackendApplication.java"),
        "package com.demo;\n@SpringBootApplication\npublic class BackendApplication { public static void main(String[] a) {} }\n",
    )
    .unwrap();
    fs::write(
        root.join("frontend-web/package.json"),
        r#"{"name":"web","scripts":{"dev":"vite"}}"#,
    )
    .unwrap();

    let response: Value = serde_json::from_str(&execute_json(
        &serde_json::json!({
            "id": "generate",
            "command": "runConfig.generate",
            "payload": {
                "root": root,
                "paths": ["backend-api/src/main/java/com/demo/BackendApplication.java"]
            }
        })
        .to_string(),
    ))
    .unwrap();
    assert_eq!(response["ok"], true, "{response}");
    let configurations = response["data"]["generated"]["configurations"]
        .as_array()
        .unwrap();
    let ids = configurations
        .iter()
        .map(|item| item["id"].as_str().unwrap().to_string())
        .collect::<Vec<_>>();

    assert!(
        ids.contains(&"spring:com.demo.BackendApplication".to_string()),
        "{ids:?}"
    );
    assert!(
        ids.contains(&"npm.script:frontend-web/dev".to_string()),
        "{ids:?}"
    );
    // The Java entries stay toolchain-backed; only the detected ones are
    // process-based. A regression here would send npm through Maven.
    let java = configurations
        .iter()
        .find(|item| item["id"] == "spring:com.demo.BackendApplication")
        .unwrap();
    assert!(java["command"].is_null());
    assert_eq!(java["toolchains"]["maven"], "project-maven");

    fs::remove_dir_all(root).unwrap();
}
