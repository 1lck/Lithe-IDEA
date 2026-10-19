//! Build systems declared by API level 3 plugins: manifest validation, plan
//! expansion, output decoding, and detection over real workspace files.

use super::support::temporary_root;
use crate::build::{
    build_check_tool_version_command, build_decode_dependencies_command,
    build_decode_diagnostics_command, build_decode_model_command,
    build_decode_test_results_command, build_dependency_plan_command, build_detect_command,
    build_invocation_plan_command, build_model_plan_command, build_resolve_options_command,
    build_sync_fingerprint_command, build_task_plan_command, build_test_plan_command,
};
use crate::plugins::declarative::{language_server_launch_plan_command, validate_command};
use crate::plugins::marketplace::install_review_command;
use crate::protocol::ErrorCode;
use serde_json::{json, Value};
use std::fs;
use std::path::PathBuf;

macro_rules! contract_file {
    ($path:literal) => {
        include_str!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../../shared/contracts/plugins/v1/",
            $path
        ))
    };
}

const CARGO_FIXTURE: &str = contract_file!("fixtures/cargo-build.plugin.json");
const GO_FIXTURE: &str = contract_file!("fixtures/go-build.plugin.json");
const GRADLE_FIXTURE: &str = contract_file!("fixtures/gradle-build.plugin.json");
const MAVEN_FIXTURE: &str = contract_file!("fixtures/maven-build.plugin.json");
const GRADLE_PROVIDER_FIXTURE: &str = contract_file!("fixtures/gradle-provider.plugin.json");
const MIX_PROVIDER_FIXTURE: &str = contract_file!("fixtures/mix-provider.plugin.json");
const BUILD_PLANS: &str = contract_file!("fixtures/build-plans.json");

fn fixture(name: &str) -> Value {
    let source = match name {
        "cargo-build.plugin.json" => CARGO_FIXTURE,
        "go-build.plugin.json" => GO_FIXTURE,
        "gradle-build.plugin.json" => GRADLE_FIXTURE,
        "maven-build.plugin.json" => MAVEN_FIXTURE,
        "gradle-provider.plugin.json" => GRADLE_PROVIDER_FIXTURE,
        "mix-provider.plugin.json" => MIX_PROVIDER_FIXTURE,
        other => panic!("unknown fixture {other}"),
    };
    serde_json::from_str(source).expect("fixture manifest is JSON")
}

/// Removes its directory when dropped, so a failed assertion cleans up too.
struct TemporaryWorkspace(PathBuf);

impl TemporaryWorkspace {
    fn new(label: &str) -> Self {
        let root = temporary_root(label);
        fs::create_dir_all(&root).unwrap();
        Self(root)
    }

    fn write(&self, relative: &str, contents: &str) -> &Self {
        let path = self.0.join(relative);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, contents).unwrap();
        self
    }

    fn root(&self) -> String {
        self.0.to_string_lossy().into_owned()
    }
}

impl Drop for TemporaryWorkspace {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

type Command = fn(Value) -> Result<Value, crate::protocol::CoreError>;

fn operation(name: &str) -> Command {
    match name {
        "invocationPlan" => build_invocation_plan_command,
        "checkToolVersion" => build_check_tool_version_command,
        "resolveOptions" => build_resolve_options_command,
        "modelPlan" => build_model_plan_command,
        "taskPlan" => build_task_plan_command,
        "testPlan" => build_test_plan_command,
        "dependencyPlan" => build_dependency_plan_command,
        "decodeModel" => build_decode_model_command,
        "decodeTestResults" => build_decode_test_results_command,
        "decodeDiagnostics" => build_decode_diagnostics_command,
        "decodeDependencies" => build_decode_dependencies_command,
        "syncFingerprint" => build_sync_fingerprint_command,
        other => panic!("unknown operation {other}"),
    }
}

fn call(name: &str, manifest: Value, build_system: &str, request: Value) -> Value {
    operation(name)(json!({
        "manifest": manifest,
        "buildSystemID": build_system,
        "request": request,
    }))
    .expect("payload is well formed")
}

fn validate(manifest: Value) -> Value {
    validate_command(json!({ "manifest": manifest })).expect("payload is well formed")
}

/// Replaces `${workspace}` in every string, so golden requests can name the
/// absolute workspace root without a machine path.
fn substitute(value: &mut Value, workspace: &str) {
    match value {
        Value::String(text) => *text = text.replace("${workspace}", workspace),
        Value::Array(items) => items
            .iter_mut()
            .for_each(|item| substitute(item, workspace)),
        Value::Object(map) => map
            .values_mut()
            .for_each(|item| substitute(item, workspace)),
        _ => {}
    }
}

#[test]
fn build_fixtures_validate() {
    for name in [
        "cargo-build.plugin.json",
        "go-build.plugin.json",
        "gradle-build.plugin.json",
        "maven-build.plugin.json",
        "gradle-provider.plugin.json",
        "mix-provider.plugin.json",
    ] {
        let outcome = validate(fixture(name));
        assert_eq!(outcome["status"], "ok", "{name}: {outcome}");
    }
}

#[test]
fn build_plans_match_the_contract_goldens() {
    let workspace = TemporaryWorkspace::new("build-plans");
    // Goldens spell paths with `/`; Windows accepts them as absolute.
    let root = workspace.root().replace('\\', "/");
    let fixtures: Value = serde_json::from_str(BUILD_PLANS).unwrap();
    for case in fixtures["cases"].as_array().unwrap() {
        let name = case["name"].as_str().unwrap();
        let mut request = case["request"].clone();
        let mut expected = case["expected"].clone();
        substitute(&mut request, &root);
        substitute(&mut expected, &root);
        let outcome = call(
            case["operation"].as_str().unwrap(),
            fixture(case["plugin"].as_str().unwrap()),
            case["buildSystemID"].as_str().unwrap(),
            request,
        );
        assert_eq!(outcome, expected, "{name}");
    }
}

fn detect(workspace: &TemporaryWorkspace, manifests: Vec<Value>, options: Value) -> Value {
    let plugins: Vec<Value> = manifests
        .into_iter()
        .map(|manifest| json!({ "manifest": manifest }))
        .collect();
    let outcome = build_detect_command(json!({
        "workspaceRoot": workspace.root(),
        "plugins": plugins,
        "options": options,
    }))
    .expect("payload is well formed");
    assert_eq!(outcome["status"], "ok", "{outcome}");
    outcome["detection"].clone()
}

fn generated_configurations(workspace: &TemporaryWorkspace) -> Vec<Value> {
    let response: Value = serde_json::from_str(&crate::execute_json(
        &json!({
            "id": "generate",
            "command": "runConfig.generate",
            "payload": { "root": workspace.root() },
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

fn instance<'a>(detection: &'a Value, id: &str) -> &'a Value {
    detection["instances"]
        .as_array()
        .unwrap()
        .iter()
        .find(|instance| instance["id"] == id)
        .unwrap_or_else(|| panic!("no instance {id}: {detection}"))
}

fn instance_ids(detection: &Value) -> Vec<String> {
    detection["instances"]
        .as_array()
        .unwrap()
        .iter()
        .map(|instance| instance["id"].as_str().unwrap().to_string())
        .collect()
}

/// The Cargo plugin reproduces the built-in Cargo detector's run entries
/// field for field, so moving Cargo onto the plugin model keeps every stored
/// run configuration.
#[test]
fn cargo_run_entries_match_the_builtin_detector() {
    let workspace = TemporaryWorkspace::new("build-cargo-parity");
    workspace
        .write(
            "rust/Cargo.toml",
            "[package]\nname = \"rust-app\"\nversion = \"0.1.0\"\nedition = \"2021\"\n\n[features]\ncli = []\nserde = []\n",
        )
        .write("rust/src/main.rs", "fn main() {}\n")
        .write(
            "tools/Cargo.toml",
            "[package]\nname = \"tools\"\nversion = \"0.1.0\"\n\n[[bin]]\nname = \"gen\"\n\n[[bin]]\nname = \"lint\"\n",
        );
    let detection = detect(
        &workspace,
        vec![fixture("cargo-build.plugin.json")],
        json!({}),
    );
    let mut planned: Vec<Value> = detection["instances"]
        .as_array()
        .unwrap()
        .iter()
        .flat_map(|instance| instance["model"]["run"].as_array().unwrap().clone())
        .collect();
    let mut builtin: Vec<Value> = generated_configurations(&workspace)
        .into_iter()
        .filter(|configuration| configuration["provider"] == "cargo.binary")
        .collect();
    planned.sort_by_key(|entry| entry["id"].to_string());
    builtin.sort_by_key(|entry| entry["id"].to_string());
    assert_eq!(planned.len(), 3, "{planned:?}");
    assert_eq!(planned.len(), builtin.len(), "{planned:?} vs {builtin:?}");
    for (plan, configuration) in planned.iter().zip(&builtin) {
        for field in [
            "id",
            "name",
            "provider",
            "execution",
            "command",
            "args",
            "cwd",
            "env",
            "source",
            "extensions",
        ] {
            assert_eq!(
                plan[field], configuration[field],
                "{field}: {plan} vs {configuration}"
            );
        }
    }

    let rust = instance(&detection, "cargo:rust");
    assert_eq!(
        rust["model"]["optionValues"]["features"],
        json!(["cli", "serde"])
    );
    assert_eq!(
        rust["model"]["projects"][0]["properties"]["edition"],
        "2021"
    );
    let roots: Vec<(&str, &str)> = rust["model"]["contentRoots"]
        .as_array()
        .unwrap()
        .iter()
        .map(|root| {
            (
                root["path"].as_str().unwrap(),
                root["kind"].as_str().unwrap(),
            )
        })
        .collect();
    assert_eq!(
        roots,
        [
            ("rust/src", "source"),
            ("rust/target", "excluded"),
            ("rust/tests", "testSource")
        ]
    );
}

/// Cargo's implicit `src/main.rs` target is suppressed by an explicit binary,
/// but not by explicit test or example targets.
#[test]
fn cargo_implicit_main_survives_test_and_example_targets() {
    let workspace = TemporaryWorkspace::new("build-cargo-targets");
    workspace
        .write(
            "demo/Cargo.toml",
            "[package]\nname = \"demo\"\nversion = \"0.1.0\"\n\n[[test]]\nname = \"checks\"\npath = \"tests/checks.rs\"\n\n[[example]]\nname = \"sample\"\npath = \"examples/sample.rs\"\n",
        )
        .write("demo/src/main.rs", "fn main() {}\n")
        .write("demo/tests/checks.rs", "\n")
        .write("demo/examples/sample.rs", "fn main() {}\n")
        .write(
            "cli/Cargo.toml",
            "[package]\nname = \"cli\"\nversion = \"0.1.0\"\n\n[[bin]]\nname = \"cli-bin\"\npath = \"src/bin/cli-bin.rs\"\n",
        )
        .write("cli/src/main.rs", "fn main() {}\n")
        .write("cli/src/bin/cli-bin.rs", "fn main() {}\n");
    let detection = detect(
        &workspace,
        vec![fixture("cargo-build.plugin.json")],
        json!({}),
    );
    let targets = |id: &str| -> Vec<(String, String)> {
        instance(&detection, id)["model"]["targets"]
            .as_array()
            .unwrap()
            .iter()
            .map(|target| {
                (
                    target["name"].as_str().unwrap().to_string(),
                    target["tags"][0].as_str().unwrap().to_string(),
                )
            })
            .collect()
    };
    let demo = targets("cargo:demo");
    assert!(
        demo.contains(&("demo".to_string(), "application".to_string())),
        "{demo:?}"
    );
    assert!(
        demo.contains(&("checks".to_string(), "test".to_string())),
        "{demo:?}"
    );
    assert!(
        demo.contains(&("sample".to_string(), "example".to_string())),
        "{demo:?}"
    );
    // An explicit binary suppresses the implicit main target.
    let applications: Vec<String> = targets("cargo:cli")
        .into_iter()
        .filter(|(_, tag)| tag == "application")
        .map(|(name, _)| name)
        .collect();
    assert_eq!(applications, ["cli-bin"]);
}

/// Each declaration's nesting rule decides how marker directories become
/// instances, and the higher-priority plugin answers for a shared ID.
#[test]
fn detection_applies_nesting_priority_and_rejections() {
    let workspace = TemporaryWorkspace::new("build-detect");
    workspace
        .write("Cargo.toml", "[workspace]\nmembers = [\"crates/*\"]\n")
        .write(
            "crates/a/Cargo.toml",
            "[package]\nname = \"a\"\nversion = \"0.1.0\"\n",
        )
        .write(
            "crates/b/Cargo.toml",
            "[package]\nname = \"b\"\nversion = \"0.1.0\"\n",
        )
        .write("android/settings.gradle.kts", "include(\":app\")\n")
        .write(
            "android/app/build.gradle.kts",
            "plugins { id(\"application\") }\n",
        )
        .write("target/debug/Cargo.toml", "[package]\nname = \"ignored\"\n");

    let mut preferred = fixture("cargo-build.plugin.json");
    preferred["id"] = json!("dev.lithe.fixture.cargo-preferred");
    preferred["buildSystems"][0]["detection"]["priority"] = json!(80);
    let mut broken = fixture("go-build.plugin.json");
    broken["permissions"] = json!([]);

    let detection = detect(
        &workspace,
        vec![
            fixture("cargo-build.plugin.json"),
            broken,
            fixture("gradle-build.plugin.json"),
            preferred,
        ],
        json!({}),
    );
    assert_eq!(
        instance_ids(&detection),
        [
            "cargo:.",
            "cargo:crates/a",
            "cargo:crates/b",
            "gradle:android"
        ]
    );
    assert_eq!(
        instance(&detection, "cargo:crates/a")["pluginID"],
        "dev.lithe.fixture.cargo-preferred"
    );
    assert_eq!(
        detection["shadowed"],
        json!([{
            "pluginID": "dev.lithe.fixture.cargo-build",
            "buildSystemID": "cargo",
            "by": "dev.lithe.fixture.cargo-preferred",
        }])
    );
    assert_eq!(detection["rejected"][0]["index"], 1);
    assert_eq!(
        detection["rejected"][0]["error"]["code"],
        "plugin.permission.undeclared"
    );

    // A workspace root without a package has no project of its own.
    assert_eq!(
        instance(&detection, "cargo:.")["model"]["projects"],
        json!([])
    );
    let gradle = instance(&detection, "gradle:android");
    assert_eq!(gradle["modelSource"], "command");
    assert!(gradle.get("model").is_none(), "{gradle}");
    assert_eq!(gradle["markers"], json!(["android/settings.gradle.kts"]));
}

/// Maven's model comes from the host integration during detection, with the
/// reactor's modules as projects and its profiles as option values.
#[test]
fn maven_method_durations_survive_report_aggregation_and_build_decoding() {
    let timing: Value = serde_json::from_str(include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../shared/fixtures/maven/testcase-durations-v1.json"
    )))
    .unwrap();
    let workspace = TemporaryWorkspace::new("maven-method-durations");
    workspace.write("pom.xml", "<project><modelVersion>4.0.0</modelVersion><groupId>demo</groupId><artifactId>timing</artifactId><version>1</version></project>")
        .write("target/surefire-reports/TEST-demo.DurationTest.xml", timing["xml"].as_str().unwrap());
    let results = crate::project::test_results(
        serde_json::from_value(json!({
            "root": workspace.root(), "output": "", "reports": {"notBeforeMillis": 0}
        }))
        .unwrap(),
    )
    .unwrap();
    assert_eq!(
        serde_json::to_value(&results.test_cases).unwrap(),
        timing["expected"]
    );
    let decoded = call(
        "decodeTestResults",
        fixture("maven-build.plugin.json"),
        "maven",
        json!({
            "workspaceRoot": workspace.root(), "root": ".", "project": ".", "output": "", "notBeforeMillis": 0
        }),
    );
    assert_eq!(decoded["status"], "ok", "{decoded}");
    let methods = decoded["results"]["tests"].as_array().unwrap();
    assert_eq!(methods.len(), timing["expected"].as_array().unwrap().len());
    for expected in timing["expected"].as_array().unwrap() {
        let actual = methods
            .iter()
            .find(|case| case["case"] == expected["method"])
            .unwrap();
        assert_eq!(
            actual["durationMillis"], expected["durationMillis"],
            "{actual}"
        );
        assert_eq!(actual["invocations"], expected["invocations"]);
    }
}

#[test]
fn maven_reactor_detects_through_the_host_integration() {
    let workspace = TemporaryWorkspace::new("build-maven-detect");
    workspace
        .write(
            "backend/pom.xml",
            "<project><modelVersion>4.0.0</modelVersion><groupId>com.example</groupId><artifactId>shop</artifactId><version>1.0.0</version><packaging>pom</packaging><modules><module>api</module></modules><profiles><profile><id>dev</id></profile><profile><id>prod</id></profile></profiles></project>",
        )
        .write(
            "backend/api/pom.xml",
            "<project><modelVersion>4.0.0</modelVersion><parent><groupId>com.example</groupId><artifactId>shop</artifactId><version>1.0.0</version></parent><artifactId>api</artifactId></project>",
        )
        .write("backend/api/src/main/java/demo/App.java", "class App {}\n");
    let detection = detect(
        &workspace,
        vec![fixture("maven-build.plugin.json")],
        json!({ "maven": { "profiles": ["dev", "removed"] } }),
    );
    assert_eq!(instance_ids(&detection), ["maven:backend"]);
    let model = &instance(&detection, "maven:backend")["model"];
    let projects: Vec<(&str, &str)> = model["projects"]
        .as_array()
        .unwrap()
        .iter()
        .map(|project| {
            (
                project["path"].as_str().unwrap(),
                project["name"].as_str().unwrap(),
            )
        })
        .collect();
    assert_eq!(projects, [("backend", "shop"), ("backend/api", "api")]);
    assert_eq!(model["optionValues"]["profiles"], json!(["dev", "prod"]));
    assert!(
        model["contentRoots"]
            .as_array()
            .unwrap()
            .iter()
            .any(|root| root["path"] == "backend/api/src/main/java" && root["kind"] == "source"),
        "{model}"
    );
}

/// The Maven plugin's task plans keep the argument order the built-in Maven
/// tool window produces for the same context.
#[test]
fn maven_task_plans_match_the_builtin_arguments() {
    let settings = "/opt/maven/settings.xml";
    let outcome = call(
        "taskPlan",
        fixture("maven-build.plugin.json"),
        "maven",
        json!({
            "root": ".",
            "task": "install",
            "project": { "path": "services/api", "name": "api" },
            "options": {
                "profiles": ["prod", "dev"],
                "settingsFile": settings,
                "localRepository": "/opt/m2",
                "skipTests": true,
            },
        }),
    );
    let profiles = ["dev".to_string(), "prod".to_string()];
    let expected = crate::project::maven_arguments(
        &profiles,
        Some(settings),
        Some("/opt/m2"),
        Some("services/api"),
        false,
        true,
        &["install".to_string()],
    );
    assert_eq!(outcome["plan"]["arguments"], json!(expected), "{outcome}");
}

/// A model command that writes the canonical format to the host's output
/// file needs no map, and model tasks become run entries through their
/// template task.
#[test]
fn gradle_canonical_outputs_are_read_from_the_output_file() {
    let workspace = TemporaryWorkspace::new("build-gradle-canonical");
    let root = workspace.root().replace('\\', "/");
    workspace
        .write(
            "state/model.json",
            &json!({
                "format": "litheBuildModel",
                "version": 1,
                "projects": [
                    { "path": format!("{root}"), "name": "shop", "properties": { "taskPrefix": ":" } },
                    { "path": "app", "name": "app", "properties": { "taskPrefix": ":app:" } }
                ],
                "tasks": [
                    { "project": "app", "name": "bootRun", "template": "gradle-task", "execution": "service", "properties": { "path": ":app:bootRun" } },
                    { "project": "app", "name": "jar", "template": "gradle-task", "properties": { "path": ":app:jar" } }
                ],
                "contentRoots": [{ "project": "app", "path": "app/src/main/java", "kind": "source" }],
                "futureField": true
            })
            .to_string(),
        )
        .write(
            "state/deps.json",
            &json!({
                "format": "litheDependencies",
                "version": 1,
                "dependencies": [{
                    "name": "spring-web",
                    "group": "org.springframework",
                    "version": "6.1.0",
                    "scope": "runtimeClasspath",
                    "children": [{ "name": "spring-core", "group": "org.springframework", "version": "6.1.0", "children": [] }]
                }]
            })
            .to_string(),
        );

    let model = call(
        "decodeModel",
        fixture("gradle-build.plugin.json"),
        "gradle",
        json!({
            "workspaceRoot": workspace.root(),
            "root": ".",
            "outputFile": workspace.0.join("state/model.json").to_string_lossy(),
        }),
    );
    assert_eq!(model["status"], "ok", "{model}");
    let model = &model["model"];
    let projects: Vec<&str> = model["projects"]
        .as_array()
        .unwrap()
        .iter()
        .map(|project| project["path"].as_str().unwrap())
        .collect();
    assert_eq!(projects, [".", "app"]);
    // Content roots are root-relative like every canonical path; resolving
    // them against their project would produce `app/app/src/main/java`.
    let sources: Vec<&Value> = model["contentRoots"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|root| root["kind"] != "excluded")
        .collect();
    assert_eq!(
        sources,
        [&json!({ "projectID": "gradle:app/app", "path": "app/src/main/java", "kind": "source" })],
        "{model}"
    );
    let run = model["run"].as_array().unwrap();
    assert_eq!(
        run.len(),
        1,
        "only the service task becomes a run entry: {run:?}"
    );
    assert_eq!(run[0]["name"], "bootRun");
    assert_eq!(run[0]["execution"], "service");
    assert_eq!(run[0]["args"], json!(["--console=plain", ":app:bootRun"]));
    assert_eq!(run[0]["cwd"], ".");

    let dependencies = call(
        "decodeDependencies",
        fixture("gradle-build.plugin.json"),
        "gradle",
        json!({
            "workspaceRoot": workspace.root(),
            "root": ".",
            "project": "app",
            "outputFile": workspace.0.join("state/deps.json").to_string_lossy(),
        }),
    );
    assert_eq!(dependencies["status"], "ok", "{dependencies}");
    let tree = &dependencies["dependencies"];
    assert_eq!(tree["project"], "app");
    assert_eq!(tree["dependencies"][0]["name"], "spring-web");
    assert_eq!(
        tree["dependencies"][0]["children"][0]["name"],
        "spring-core"
    );

    let missing = call(
        "decodeModel",
        fixture("gradle-build.plugin.json"),
        "gradle",
        json!({ "workspaceRoot": workspace.root(), "root": "." }),
    );
    assert_eq!(missing["status"], "rejected", "{missing}");
}

/// JUnit reports under the declared globs become per-case results; reports
/// older than the run are ignored.
#[test]
fn junit_reports_become_case_results() {
    let workspace = TemporaryWorkspace::new("build-junit");
    workspace
        .write(
            "app/build/test-results/test/TEST-com.example.OrderTest.xml",
            r#"<?xml version="1.0" encoding="UTF-8"?>
<testsuite name="com.example.OrderTest" tests="3" failures="1" errors="0" skipped="1">
  <testcase name="refunds" classname="com.example.OrderTest" time="0.012"/>
  <testcase name="charges" classname="com.example.OrderTest" time="0.004">
    <failure message="expected 2 but was 3">trace</failure>
  </testcase>
  <testcase name="ships" classname="com.example.OrderTest"><skipped/></testcase>
</testsuite>
"#,
        )
        .write(
            "app/build/test-results/other/TEST-Ignored.xml",
            "<testsuite/>",
        );
    let outcome = call(
        "decodeTestResults",
        fixture("gradle-build.plugin.json"),
        "gradle",
        json!({
            "workspaceRoot": workspace.root(),
            "root": ".",
            "project": "app",
            "output": "",
        }),
    );
    assert_eq!(outcome["status"], "ok", "{outcome}");
    let cases: Vec<(String, String)> = outcome["results"]["tests"]
        .as_array()
        .unwrap()
        .iter()
        .map(|case| {
            (
                case["case"].as_str().unwrap().to_string(),
                case["status"].as_str().unwrap().to_string(),
            )
        })
        .collect();
    assert_eq!(
        cases,
        [
            ("charges".to_string(), "failed".to_string()),
            ("refunds".to_string(), "passed".to_string()),
            ("ships".to_string(), "skipped".to_string()),
        ]
    );
    assert_eq!(
        outcome["results"]["summary"],
        json!({ "total": 3, "passed": 1, "failed": 1, "errors": 0, "skipped": 1 })
    );
    assert_eq!(outcome["results"]["success"], false);
    assert_eq!(
        outcome["results"]["tests"][1]["suite"],
        "com.example.OrderTest"
    );
    assert_eq!(
        outcome["results"]["tests"][0]["message"],
        "expected 2 but was 3"
    );

    let later = call(
        "decodeTestResults",
        fixture("gradle-build.plugin.json"),
        "gradle",
        json!({
            "workspaceRoot": workspace.root(),
            "root": ".",
            "project": "app",
            "output": "",
            "notBeforeMillis": u64::MAX / 2,
        }),
    );
    assert_eq!(later["results"]["tests"], json!([]), "{later}");
}

/// A workspace run has no selected project, so the reports its subprojects
/// wrote must still count; otherwise a failing subproject decodes as zero
/// tests and `success: true`.
#[test]
fn workspace_test_results_cover_every_model_project() {
    let workspace = TemporaryWorkspace::new("build-junit-workspace");
    workspace
        .write(
            "app/build/test-results/test/TEST-com.example.OrderTest.xml",
            r#"<testsuite name="com.example.OrderTest">
  <testcase name="charges" classname="com.example.OrderTest"><failure message="boom"/></testcase>
</testsuite>"#,
        )
        .write(
            "build/test-results/test/TEST-com.example.RootTest.xml",
            r#"<testsuite name="com.example.RootTest"><testcase name="boots" classname="com.example.RootTest"/></testsuite>"#,
        );
    let decode = |request: Value| {
        call(
            "decodeTestResults",
            fixture("gradle-build.plugin.json"),
            "gradle",
            request,
        )
    };

    let outcome = decode(json!({
        "workspaceRoot": workspace.root(), "root": ".", "projects": [".", "app"], "output": "",
    }));
    assert_eq!(outcome["status"], "ok", "{outcome}");
    assert_eq!(
        outcome["results"]["summary"],
        json!({ "total": 2, "passed": 1, "failed": 1, "errors": 0, "skipped": 0 }),
        "{outcome}"
    );
    assert_eq!(outcome["results"]["success"], false);

    // A selected project still reads only its own reports.
    let project = decode(json!({
        "workspaceRoot": workspace.root(), "root": ".", "project": ".", "projects": ["app"], "output": "",
    }));
    assert_eq!(project["results"]["summary"]["total"], 1, "{project}");

    let escaping = decode(json!({
        "workspaceRoot": workspace.root(), "root": ".", "projects": ["../outside"], "output": "",
    }));
    assert_eq!(escaping["status"], "rejected", "{escaping}");
    assert_eq!(escaping["error"]["code"], "plugin.build.invalidSelection");
}

#[test]
fn canonical_model_paths_stay_inside_the_instance_root() {
    let workspace = TemporaryWorkspace::new("canonical-model-boundary");
    for root in [".", "services", "services/api"] {
        let prefix = if root == "." {
            String::new()
        } else {
            format!("{root}/")
        };
        let absolute_inside = workspace.0.join(format!("{prefix}app/src"));
        let absolute_outside = if root == "." {
            workspace.0.with_extension("outside")
        } else {
            workspace.0.join(format!("{root}-sibling/src"))
        };
        let paths = [
            ".".to_string(),
            "app/../shared".to_string(),
            absolute_inside.to_string_lossy().into_owned(),
            "../outside".to_string(),
            "..".to_string(),
            absolute_outside.to_string_lossy().into_owned(),
        ];
        // An explicit valid owner must not admit a child outside this instance.
        let entries: Vec<Value> = paths
            .iter()
            .enumerate()
            .map(|(index, path)| {
                json!({
                    "project": "app", "path": path, "name": format!("entry-{index}"),
                    "tags": ["application"], "template": "gradle-task", "kind": "source"
                })
            })
            .collect();
        let mut document = json!({
            "format": "litheBuildModel", "version": 1,
            "projects": [{ "path": "app", "name": "app" }],
            "targets": entries, "tasks": entries, "contentRoots": entries
        });
        // Omitted target/task paths still inherit the selected project's path.
        for field in ["targets", "tasks"] {
            document[field].as_array_mut().unwrap().push(json!({
                "project": "app", "name": "inherited", "template": "gradle-task"
            }));
        }
        workspace.write("model.json", &document.to_string());
        let result = call(
            "decodeModel",
            fixture("gradle-build.plugin.json"),
            "gradle",
            json!({
                "workspaceRoot": workspace.root(), "root": root, "outputFile": workspace.0.join("model.json")
            }),
        );
        assert_eq!(result["status"], "ok", "{root}: {result}");
        for field in ["targets", "tasks", "contentRoots"] {
            let mut actual: Vec<&str> = result["model"][field]
                .as_array()
                .unwrap()
                .iter()
                .filter(|entry| entry["kind"] != "excluded")
                .map(|entry| entry["path"].as_str().unwrap())
                .collect();
            let mut expected = vec![
                root.to_string(),
                format!("{prefix}shared"),
                format!("{prefix}app/src"),
            ];
            if field != "contentRoots" {
                expected.push(format!("{prefix}app"));
            }
            actual.sort_unstable();
            expected.sort_unstable();
            assert_eq!(actual, expected, "{root}: {field}");
        }
    }
}

#[test]
fn selector_model_paths_stay_inside_the_instance_root() {
    let workspace = TemporaryWorkspace::new("selector-model-boundary");
    let mut manifest = fixture("gradle-build.plugin.json");
    manifest["buildSystems"][0]["model"] = json!({
        "source": "command", "arguments": ["model"], "output": "stdout", "decoder": "jsonStream",
        "executesProjectCode": false, "mayUseNetwork": false,
        "map": { "projects": [{
            "each": "/*", "name": { "value": "app" }, "path": { "value": "app" },
            "targets": [{ "each": "/paths/*", "name": "", "path": "", "tags": ["application"] }],
            "contentRoots": [{ "each": "/paths/*", "path": "", "kind": "source" }]
        }] }
    });
    let validation = validate(manifest.clone());
    assert_eq!(validation["status"], "ok", "{validation}");
    for root in [".", "services", "services/api"] {
        let prefix = if root == "." {
            String::new()
        } else {
            format!("{root}/")
        };
        let absolute_inside = workspace.0.join(format!("{prefix}absolute"));
        let absolute_outside = if root == "." {
            workspace.0.with_extension("outside")
        } else {
            workspace.0.join(format!("{root}-sibling/src"))
        };
        let document = json!({ "paths": [
            ".", "../shared", "src/../generated", absolute_inside,
            "../../outside", "../..", absolute_outside
        ] });
        let result = call(
            "decodeModel",
            manifest.clone(),
            "gradle",
            json!({
                "workspaceRoot": workspace.root(), "root": root, "output": document.to_string()
            }),
        );
        assert_eq!(result["status"], "ok", "{root}: {result}");
        let mut expected = vec![
            format!("{prefix}app"),
            format!("{prefix}shared"),
            format!("{prefix}app/generated"),
            format!("{prefix}absolute"),
        ];
        expected.sort_unstable();
        for field in ["targets", "contentRoots"] {
            let mut actual: Vec<&str> = result["model"][field]
                .as_array()
                .unwrap()
                .iter()
                .filter(|entry| entry["kind"] != "excluded")
                .map(|entry| entry["path"].as_str().unwrap())
                .collect();
            actual.sort_unstable();
            assert_eq!(actual, expected, "{root}: {field}");
        }
    }
}

#[test]
fn rejected_selector_paths_do_not_suppress_valid_fallbacks() {
    let workspace = TemporaryWorkspace::new("selector-model-boundary-fallback");
    let mut manifest = fixture("gradle-build.plugin.json");
    manifest["buildSystems"][0]["model"] = json!({
        "source": "command", "arguments": ["model"], "output": "stdout", "decoder": "jsonStream",
        "executesProjectCode": false, "mayUseNetwork": false,
        "map": { "projects": [{ "each": "/*", "name": { "value": "app" },
            "targets": [
                { "name": { "value": "escape" }, "path": { "value": "../outside" }, "tags": ["application"] },
                { "name": { "value": "valid" }, "fallback": true, "tags": ["application"] }
            ],
            "contentRoots": [
                { "path": { "value": "../outside" }, "kind": "source" },
                { "path": { "value": "src" }, "kind": "source", "fallback": true }
            ]
        }] }
    });
    let result = call(
        "decodeModel",
        manifest,
        "gradle",
        json!({
            "workspaceRoot": workspace.root(), "root": "services/api", "output": "{}"
        }),
    );
    assert_eq!(result["status"], "ok", "{result}");
    assert_eq!(result["model"]["targets"].as_array().unwrap().len(), 1);
    assert_eq!(result["model"]["targets"][0]["path"], "services/api");
    assert_eq!(result["model"]["targets"][0]["name"], "valid");
    let roots: Vec<&Value> = result["model"]["contentRoots"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|entry| entry["kind"] == "source")
        .collect();
    assert_eq!(roots.len(), 1);
    assert_eq!(roots[0]["path"], "services/api/src");
}

/// Canonical content roots resolve against a nested instance root too.
#[test]
fn canonical_content_roots_are_relative_to_the_instance_root() {
    let workspace = TemporaryWorkspace::new("build-canonical-nested-root");
    workspace.write(
        "state/model.json",
        &json!({
            "format": "litheBuildModel",
            "version": 1,
            "projects": [
                { "name": "shop" },
                { "path": "app", "name": "app" }
            ],
            "contentRoots": [
                { "project": "app", "path": "app/src/main/java", "kind": "source" },
                { "path": "buildSrc/src/main/kotlin", "kind": "source" }
            ]
        })
        .to_string(),
    );
    let outcome = call(
        "decodeModel",
        fixture("gradle-build.plugin.json"),
        "gradle",
        json!({
            "workspaceRoot": workspace.root(),
            "root": "services",
            "outputFile": workspace.0.join("state/model.json").to_string_lossy(),
        }),
    );
    assert_eq!(outcome["status"], "ok", "{outcome}");
    let roots: Vec<(&str, &str)> = outcome["model"]["contentRoots"]
        .as_array()
        .unwrap()
        .iter()
        .filter(|root| root["kind"] != "excluded")
        .map(|root| {
            (
                root["projectID"].as_str().unwrap(),
                root["path"].as_str().unwrap(),
            )
        })
        .collect();
    assert_eq!(
        roots,
        [
            ("gradle:services/app/app", "services/app/src/main/java"),
            ("gradle:services/shop", "services/buildSrc/src/main/kotlin"),
        ],
        "{outcome}"
    );
}

/// The sync fingerprint changes with the watched files and nothing else.
#[test]
fn sync_fingerprint_follows_watched_files() {
    let workspace = TemporaryWorkspace::new("build-sync");
    workspace
        .write("Cargo.toml", "[package]\nname = \"app\"\n")
        .write("src/main.rs", "fn main() {}\n");
    let fingerprint = || {
        let outcome = call(
            "syncFingerprint",
            fixture("cargo-build.plugin.json"),
            "cargo",
            json!({ "workspaceRoot": workspace.root(), "root": ".", "projects": ["."] }),
        );
        assert_eq!(outcome["status"], "ok", "{outcome}");
        outcome["sync"].clone()
    };
    let first = fingerprint();
    assert_eq!(
        first["watch"],
        json!(["Cargo.lock", "Cargo.toml"]),
        "{first}"
    );
    assert_eq!(fingerprint(), first);
    workspace.write("src/main.rs", "fn main() { println!(); }\n");
    assert_eq!(fingerprint()["fingerprint"], first["fingerprint"]);
    workspace.write("Cargo.lock", "version = 3\n");
    assert_ne!(fingerprint()["fingerprint"], first["fingerprint"]);
}

/// Repeating option arguments is allowed only when the references can never
/// meet on one command line.
/// An explicit empty value is a user choice, not "no value": describing it
/// as unset would make the host drop it and a non-empty default would return.
#[test]
fn resolve_options_describe_explicit_empty_text_values() {
    let outcome = call(
        "resolveOptions",
        fixture("go-build.plugin.json"),
        "go",
        json!({ "options": { "tags": "" } }),
    );
    assert_eq!(outcome["status"], "ok", "{outcome}");
    let tags = outcome["options"]["options"]
        .as_array()
        .unwrap()
        .iter()
        .find(|option| option["id"] == "tags")
        .expect("the tags option is described");
    assert_eq!(tags["value"], "");
    assert_eq!(tags["source"], "user");
}

#[test]
fn option_arguments_may_repeat_under_opposite_conditions() {
    let mut manifest = fixture("cargo-build.plugin.json");
    manifest["buildSystems"][0]["test"]["arguments"] = json!([
        "test",
        { "value": "${optionArguments}", "when": "targetSelected" },
        { "value": "--test", "when": "targetSelected" },
        { "value": "${target.name}", "when": "targetSelected" },
        { "value": "${optionArguments}", "when": "noTargetSelected" }
    ]);
    assert_eq!(validate(manifest.clone())["status"], "ok");

    manifest["buildSystems"][0]["test"]["arguments"][4] =
        json!({ "value": "${optionArguments:release}", "when": "caseSelected" });
    let outcome = validate(manifest);
    assert_eq!(
        outcome["error"]["code"], "plugin.template.invalid",
        "{outcome}"
    );
}

/// A provider is reviewed like a language server: a process of its own is a
/// program entry with the runtime it needs, and a shared one is part of the
/// build system's entry, so routing build requests to a language server is
/// approved again.
#[test]
fn provider_processes_are_install_review_programs() {
    let programs = |name: &str| {
        let outcome = install_review_command(json!({ "manifest": fixture(name) })).unwrap();
        assert_eq!(outcome["status"], "ok", "{outcome}");
        outcome["review"]["programs"].as_array().unwrap().clone()
    };
    let own = programs("gradle-provider.plugin.json");
    let provider = own
        .iter()
        .find(|program| program["kind"] == "runtimeBuildProvider")
        .unwrap_or_else(|| panic!("no provider program: {own:?}"));
    assert_eq!(provider["buildSystemID"], "gradle");
    assert_eq!(provider["entry"], "provider/gradle-tooling-provider.jar");
    assert_eq!(
        provider["arguments"],
        json!(["--stdio", "--cache", "${workspaceStateDir}/tooling"])
    );
    assert_eq!(provider["executesProjectCode"], true);
    assert!(own.contains(&json!({ "kind": "runtime", "tool": "java", "minimumVersion": "17" })));

    let shared = programs("mix-provider.plugin.json");
    let build_system = shared
        .iter()
        .find(|program| program["kind"] == "buildSystem")
        .unwrap();
    assert_eq!(
        build_system["provider"],
        json!({ "languageServer": "elixir", "executesProjectCode": true, "mayUseNetwork": false })
    );
    assert!(
        !shared
            .iter()
            .any(|program| program["kind"].as_str().unwrap().ends_with("BuildProvider")),
        "a shared provider starts no process of its own: {shared:?}"
    );
}

/// Saved feature values must be checked against the model used for run entries.
#[test]
fn cargo_run_entries_drop_features_removed_from_the_model() {
    let workspace = TemporaryWorkspace::new("build-cargo-stale-features");
    workspace
        .write(
            "Cargo.toml",
            "[package]\nname = \"app\"\nversion = \"0.1.0\"\n[features]\ncli = []\n",
        )
        .write("src/main.rs", "fn main() {}\n");
    let manifest = fixture("cargo-build.plugin.json");
    let options = json!({ "features": ["cli", "removed"] });
    let detection = detect(
        &workspace,
        vec![manifest.clone()],
        json!({ "cargo": options }),
    );
    let detected = instance(&detection, "cargo:.");
    let decoded = call(
        "decodeModel",
        manifest,
        "cargo",
        json!({
            "workspaceRoot": workspace.root(), "root": ".", "options": options,
        }),
    );
    assert_eq!(decoded["status"], "ok", "{decoded}");
    for model in [&detected["model"], &decoded["model"]] {
        let entries = model["run"].as_array().unwrap();
        assert_eq!(entries.len(), 1, "{model}");
        assert_eq!(
            entries[0]["args"],
            json!(["run", "--bin", "app", "--features", "cli"])
        );
        assert_eq!(
            entries[0]["buildSystem"]["optionFingerprint"],
            detected["optionFingerprint"]
        );
    }
}

/// A changed default can select a different script without changing its argv template.
#[test]
fn build_option_defaults_require_install_review_again() {
    let mut manifest = fixture("gradle-build.plugin.json");
    manifest["buildSystems"][0]["options"]
        .as_array_mut()
        .unwrap()
        .push(json!({
            "id": "initScript", "displayName": "Init script", "kind": "text",
            "default": "safe.gradle", "arguments": ["--init-script", "${value}"],
        }));
    let first = install_review_command(json!({ "manifest": manifest })).unwrap();
    assert_eq!(first["status"], "ok", "{first}");
    let approved = first["review"]["programs"].clone();
    manifest["version"] = json!("1.0.1");
    let option = manifest["buildSystems"][0]["options"]
        .as_array()
        .unwrap()
        .len()
        - 1;
    manifest["buildSystems"][0]["options"][option]["displayName"] = json!("Renamed label");
    let renamed = install_review_command(json!({
        "manifest": manifest, "approvedPrograms": approved,
    }))
    .unwrap();
    assert_eq!(renamed["status"], "ok", "{renamed}");
    assert_eq!(renamed["review"]["newPrograms"], json!([]), "{renamed}");
    manifest["buildSystems"][0]["options"][option]["default"] = json!("replacement.gradle");
    let upgraded = install_review_command(json!({
        "manifest": manifest, "approvedPrograms": approved,
    }))
    .unwrap();
    assert_eq!(upgraded["status"], "ok", "{upgraded}");
    assert_eq!(
        upgraded["review"]["newPrograms"].as_array().unwrap().len(),
        1,
        "{upgraded}"
    );
}

/// Workspace reads may follow aliases inside the workspace, but cannot reveal external files.
#[cfg(unix)]
#[test]
fn static_models_and_sync_fingerprints_reject_escaping_symlinks() {
    use std::os::unix::fs::symlink;
    let workspace = TemporaryWorkspace::new("build-confined-files");
    let outside = TemporaryWorkspace::new("build-external-files");
    outside.write("Cargo.toml", "[package]\nname = \"private\"\n");
    symlink(outside.0.join("Cargo.toml"), workspace.0.join("Cargo.toml")).unwrap();
    let manifest = fixture("cargo-build.plugin.json");
    let decoded = call(
        "decodeModel",
        manifest.clone(),
        "cargo",
        json!({
            "workspaceRoot": workspace.root(), "root": ".",
        }),
    );
    assert_eq!(decoded["status"], "rejected", "{decoded}");
    let fingerprint = || {
        let outcome = call(
            "syncFingerprint",
            manifest.clone(),
            "cargo",
            json!({
                "workspaceRoot": workspace.root(), "root": ".", "projects": ["."],
            }),
        );
        assert_eq!(outcome["status"], "ok", "{outcome}");
        outcome["sync"]["fingerprint"].clone()
    };
    let first = fingerprint();
    assert!(first.is_string(), "{first}");
    outside.write(
        "Cargo.toml",
        "[package]\nname = \"another-private-project\"\n",
    );
    assert_eq!(
        fingerprint(),
        first,
        "external file contents must not affect workspace fingerprints"
    );
    workspace.write("data/Cargo.toml", "[package]\nname = \"local\"\n");
    fs::create_dir_all(workspace.0.join("alias")).unwrap();
    symlink(
        workspace.0.join("data/Cargo.toml"),
        workspace.0.join("alias/Cargo.toml"),
    )
    .unwrap();
    let local = call(
        "decodeModel",
        manifest,
        "cargo",
        json!({
            "workspaceRoot": workspace.root(), "root": "alias",
        }),
    );
    assert_eq!(local["status"], "ok", "{local}");
    assert_eq!(local["model"]["projects"][0]["name"], "local");
}

/// The reused Maven reader must not expose linked POM contents either.
#[cfg(unix)]
#[test]
fn maven_models_do_not_read_poms_outside_the_workspace() {
    use std::os::unix::fs::symlink;
    let workspace = TemporaryWorkspace::new("build-confined-maven");
    let outside = TemporaryWorkspace::new("build-external-maven");
    outside.write("pom.xml", "<project><modelVersion>4.0.0</modelVersion><artifactId>private-artifact</artifactId><version>9.9</version></project>");
    symlink(outside.0.join("pom.xml"), workspace.0.join("pom.xml")).unwrap();
    let manifest = fixture("maven-build.plugin.json");
    let decoded = call(
        "decodeModel",
        manifest.clone(),
        "maven",
        json!({
            "workspaceRoot": workspace.root(), "root": ".",
        }),
    );
    assert_eq!(decoded["status"], "rejected", "{decoded}");
    workspace.write("reactor/pom.xml", "<project><modelVersion>4.0.0</modelVersion><artifactId>root</artifactId><packaging>pom</packaging><modules><module>linked</module></modules></project>");
    symlink(&outside.0, workspace.0.join("reactor/linked")).unwrap();
    let modules = call(
        "decodeModel",
        manifest,
        "maven",
        json!({
            "workspaceRoot": workspace.root(), "root": "reactor",
        }),
    );
    assert_eq!(modules["status"], "ok", "{modules}");
    assert!(
        !modules.to_string().contains("private-artifact"),
        "{modules}"
    );
}

/// A selected report directory can itself be an alias outside the workspace.
#[cfg(unix)]
#[test]
fn junit_reports_do_not_follow_escaping_project_directories() {
    use std::os::unix::fs::symlink;
    let workspace = TemporaryWorkspace::new("build-confined-reports");
    let outside = TemporaryWorkspace::new("build-external-reports");
    outside.write(
        "app/build/test-results/test/TEST-private.xml",
        "<testsuite><testcase classname=\"Private\" name=\"secret\"/></testsuite>",
    );
    symlink(outside.0.join("app"), workspace.0.join("app")).unwrap();
    let outcome = call(
        "decodeTestResults",
        fixture("gradle-build.plugin.json"),
        "gradle",
        json!({
            "workspaceRoot": workspace.root(), "root": ".", "project": "app", "output": "",
        }),
    );
    assert_eq!(outcome["status"], "ok", "{outcome}");
    assert_eq!(outcome["results"]["tests"], json!([]), "{outcome}");
}

/// Diagnostics and test results carry paths the Build Output opens, so a link
/// that resolves outside the workspace must not survive decoding. A link that
/// stays inside keeps its workspace-relative form instead of its target.
#[cfg(unix)]
#[test]
fn reported_output_paths_reject_escaping_symlinks() {
    use std::os::unix::fs::symlink;
    let workspace = TemporaryWorkspace::new("build-confined-output-paths");
    let outside = TemporaryWorkspace::new("build-external-output-paths");
    outside.write("Secret.java", "package private1;");
    workspace
        .write("src/Inside.java", "package demo;")
        .write("app/build.gradle", "");
    symlink(&outside.0, workspace.0.join("linked")).unwrap();
    symlink(&outside.0, workspace.0.join("app/linked")).unwrap();
    symlink(workspace.0.join("src"), workspace.0.join("alias")).unwrap();
    symlink(workspace.0.join("src"), workspace.0.join("app/alias")).unwrap();

    let manifest = fixture("gradle-build.plugin.json");
    let diagnostics = |manifest: &Value, output: &str| {
        call(
            "decodeDiagnostics",
            manifest.clone(),
            "gradle",
            json!({
                "workspaceRoot": workspace.root(), "root": ".", "output": output,
            }),
        )
    };
    let escaping = diagnostics(&manifest, "linked/Secret.java:1: error: external");
    assert_eq!(escaping["status"], "ok", "{escaping}");
    assert_eq!(escaping["diagnostics"], json!([]), "{escaping}");
    let local = diagnostics(&manifest, "alias/Inside.java:1: warning: local");
    assert_eq!(
        local["diagnostics"][0]["path"], "alias/Inside.java",
        "{local}"
    );

    let mut canonical_manifest = manifest.clone();
    canonical_manifest["buildSystems"][0]["diagnostics"] = json!({
        "decoder": "litheDiagnostics",
    });
    let canonical = |path: &str| {
        let line = json!({
            "lithe": "diagnostic", "path": path, "line": 1, "message": "canonical",
        });
        diagnostics(&canonical_manifest, &line.to_string())
    };
    let escaping = canonical("linked/Secret.java");
    assert_eq!(escaping["status"], "ok", "{escaping}");
    assert_eq!(escaping["diagnostics"], json!([]), "{escaping}");
    let local = canonical("alias/Inside.java");
    assert_eq!(
        local["diagnostics"][0]["path"], "alias/Inside.java",
        "{local}"
    );

    workspace.write(
        "app/build/test-results/test/TEST-Report.xml",
        r#"<testsuite name="Report">
  <testcase classname="Report" name="external" file="linked/Secret.java"/>
  <testcase classname="Report" name="local" file="alias/Inside.java"/>
</testsuite>"#,
    );
    workspace.write(
        "app/build/test-results/test/report.json",
        r#"{"format": "litheTestResults", "version": 1, "tests": [
  {"suite": "Report", "case": "external", "status": "failed", "path": "linked/Secret.java", "line": 1},
  {"suite": "Report", "case": "local", "status": "failed", "path": "alias/Inside.java", "line": 1}
]}"#,
    );
    let test_results = |manifest: &Value| {
        call(
            "decodeTestResults",
            manifest.clone(),
            "gradle",
            json!({
                "workspaceRoot": workspace.root(), "root": ".", "project": "app", "output": "",
            }),
        )
    };
    let junit = test_results(&manifest);
    assert_eq!(junit["status"], "ok", "{junit}");
    let tests = junit["results"]["tests"].as_array().unwrap();
    assert_eq!(tests.len(), 2, "{junit}");
    assert_eq!(tests[0]["case"], "external");
    assert!(tests[0].get("path").is_none(), "{junit}");
    assert_eq!(tests[1]["path"], "app/alias/Inside.java", "{junit}");

    let mut canonical_results = manifest.clone();
    canonical_results["buildSystems"][0]["test"]["results"] = json!({
        "decoder": "litheTestResults",
        "reports": ["build/test-results/test/*.json"],
    });
    let decoded = test_results(&canonical_results);
    assert_eq!(decoded["status"], "ok", "{decoded}");
    let tests = decoded["results"]["tests"].as_array().unwrap();
    assert_eq!(tests.len(), 2, "{decoded}");
    assert_eq!(tests[0]["case"], "external");
    assert!(tests[0].get("path").is_none(), "{decoded}");
    assert_eq!(tests[1]["path"], "app/alias/Inside.java", "{decoded}");
}

/// A launch plan names one process, by language or by build system; naming
/// neither or both is a malformed payload rather than a rejected plugin.
#[test]
fn launch_plans_name_exactly_one_process() {
    let request = json!({
        "pluginDirectory": "/plugins/mix",
        "stateDirectory": "/state/mix",
        "workspaceStateDirectory": "/state/mix/workspace",
        "architecture": "arm64"
    });
    for selection in [
        json!({}),
        json!({ "languageID": "elixir", "buildSystemID": "mix" }),
    ] {
        let mut payload =
            json!({ "manifest": fixture("mix-provider.plugin.json"), "request": request });
        payload
            .as_object_mut()
            .unwrap()
            .extend(selection.as_object().unwrap().clone());
        let error = language_server_launch_plan_command(payload).unwrap_err();
        assert!(
            matches!(error.code, ErrorCode::InvalidRequest),
            "{selection}: {error:?}"
        );
    }
}

/// Detection never starts a provider: the instance only says where its model
/// comes from, and the host asks the provider once the workspace allows it.
#[test]
fn provider_models_are_not_read_during_detection() {
    let workspace = TemporaryWorkspace::new("build-provider-detect");
    workspace.write("mix.exs", "").write("apps/web/mix.exs", "");
    let detection = detect(
        &workspace,
        vec![fixture("mix-provider.plugin.json")],
        json!({}),
    );
    assert_eq!(instance_ids(&detection), ["mix:."]);
    let mix = instance(&detection, "mix:.");
    assert_eq!(mix["modelSource"], "provider");
    assert!(mix.get("model").is_none(), "{mix}");
}

/// Categories and option placements only tell the host where to show an
/// entry: a model task takes its own category when it is well formed and its
/// template's otherwise, and neither changes what runs.
#[test]
fn task_categories_and_option_placements_are_display_only() {
    let workspace = TemporaryWorkspace::new("build-task-category");
    let mut gradle = fixture("gradle-build.plugin.json");
    let build_system = &mut gradle["buildSystems"][0];
    build_system["icon"] = json!({ "path": "icons/gradle.svg" });
    build_system["tasks"][0]["category"] = json!(["Tasks", "other"]);
    let offline = build_system["options"]
        .as_array_mut()
        .unwrap()
        .iter_mut()
        .find(|option| option["id"] == "offline")
        .unwrap();
    offline["presentation"] = json!("toolbar");
    offline["icon"] = json!({ "path": "icons/offline.svg" });
    let validated = validate(gradle.clone());
    assert_eq!(validated["status"], "ok", "{validated}");
    let normalized = &validated["plugin"]["buildSystems"][0];
    assert_eq!(normalized["icon"]["path"], "icons/gradle.svg");
    let offline = normalized["options"]
        .as_array()
        .unwrap()
        .iter()
        .find(|option| option["id"] == "offline")
        .unwrap();
    assert_eq!(offline["presentation"], "toolbar");

    // A malformed category falls back to the template rather than dropping
    // the task.
    workspace.write("settings.gradle", "").write(
        "state/model.json",
        &json!({
            "format": "litheBuildModel",
            "version": 1,
            "projects": [{ "name": "root" }],
            "tasks": [
                { "name": "run", "template": "gradle-task", "category": ["Tasks", "application"], "properties": { "path": ":run" } },
                { "name": "jar", "template": "gradle-task", "properties": { "path": ":jar" } },
                { "name": "deep", "template": "gradle-task", "category": ["a", "b", "c", "d", "e"], "properties": { "path": ":deep" } },
                { "name": "blank", "template": "gradle-task", "category": ["Tasks", " "], "properties": { "path": ":blank" } }
            ]
        })
        .to_string(),
    );
    let model = call(
        "decodeModel",
        gradle.clone(),
        "gradle",
        json!({
            "workspaceRoot": workspace.root(),
            "root": ".",
            "outputFile": workspace.0.join("state/model.json").to_string_lossy(),
        }),
    );
    assert_eq!(model["status"], "ok", "{model}");
    let categories: Vec<(String, Value)> = model["model"]["tasks"]
        .as_array()
        .unwrap()
        .iter()
        .map(|task| {
            (
                task["name"].as_str().unwrap().to_string(),
                task["category"].clone(),
            )
        })
        .collect();
    assert_eq!(
        categories,
        [
            ("blank".to_string(), json!(["Tasks", "other"])),
            ("deep".to_string(), json!(["Tasks", "other"])),
            ("jar".to_string(), json!(["Tasks", "other"])),
            ("run".to_string(), json!(["Tasks", "application"])),
        ],
        "{model}"
    );
    let plan = call(
        "taskPlan",
        gradle,
        "gradle",
        json!({
            "workspaceRoot": workspace.root(),
            "root": ".",
            "task": "gradle-task",
            "project": { "path": ".", "name": "root" },
            "modelTask": { "name": "run", "properties": { "path": ":run" } },
        }),
    );
    assert_eq!(plan["status"], "ok", "{plan}");
    assert!(plan.to_string().contains("\":run\""), "{plan}");
}
