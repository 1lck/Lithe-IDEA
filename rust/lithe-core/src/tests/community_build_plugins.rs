//! The Maven and Gradle community build plugins, checked against what real
//! Maven and Gradle wrote for them.
//!
//! `fixtures/community_build_plugins/` holds each plugin's `plugin.json` and
//! the documents its own integration test captured from a real build:
//!
//! - Maven: `github.com/Lithe-IDEA/lithe-plugin-maven`, `plugin.json` at
//!   944552c, documents captured at ef40103 with Maven 3.10.0 on
//!   `test/fixtures/reactor`;
//! - Gradle: `github.com/Lithe-IDEA/lithe-plugin-gradle`, `plugin.json` at
//!   581b84b, documents captured at d669dad with Gradle 9.6.1 on
//!   `test/fixtures/multi`.
//!
//! The captured documents write the scratch workspace as `${workspace}`. To
//! refresh them, run `node scripts/package.mjs` and then
//! `LITHE_CAPTURE_DIR=<dir> node scripts/test.mjs` in the plugin repository,
//! and copy `<dir>/*.json` and `plugin.json` here.

use super::support::temporary_root;
use crate::build::{
    build_decode_dependencies_command, build_decode_diagnostics_command,
    build_decode_model_command, build_dependency_plan_command, build_detect_command,
    build_language_import_command, build_model_plan_command, build_task_plan_command,
    build_test_plan_command,
};
use crate::plugins::declarative::validate_command;
use crate::plugins::marketplace::install_review_command;
use serde_json::{json, Value};
use std::fs;
use std::path::PathBuf;

macro_rules! plugin_file {
    ($tool:literal, $name:literal) => {
        include_str!(concat!(
            "fixtures/community_build_plugins/",
            $tool,
            "/",
            $name
        ))
    };
}

const MAVEN_MANIFEST: &str = plugin_file!("maven", "plugin.json");
const MAVEN_MODEL: &str = plugin_file!("maven", "model.json");
const MAVEN_DEPENDENCIES: &str = plugin_file!("maven", "dependencies.json");
const MAVEN_APP_DEPENDENCIES: &str = plugin_file!("maven", "app-dependencies.json");
const GRADLE_MANIFEST: &str = plugin_file!("gradle", "plugin.json");
const GRADLE_MODEL: &str = plugin_file!("gradle", "model.json");
const GRADLE_DEPENDENCIES: &str = plugin_file!("gradle", "dependencies.json");
const GRADLE_APP_DEPENDENCIES: &str = plugin_file!("gradle", "app-dependencies.json");

fn maven() -> Value {
    serde_json::from_str(MAVEN_MANIFEST).expect("Maven plugin.json is JSON")
}

fn gradle() -> Value {
    serde_json::from_str(GRADLE_MANIFEST).expect("Gradle plugin.json is JSON")
}

/// Removes its directory when dropped, so a failed assertion cleans up too.
struct Workspace(PathBuf);

impl Workspace {
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

    fn path(&self, relative: &str) -> String {
        self.0.join(relative).to_string_lossy().into_owned()
    }

    /// Writes a captured document with `${workspace}` replaced by this root,
    /// as the plugin would have written it here.
    fn capture(&self, relative: &str, captured: &str) -> String {
        self.write(relative, &capture_for_workspace(captured, &self.root()));
        self.path(relative)
    }
}

impl Drop for Workspace {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn capture_for_workspace(captured: &str, workspace_root: &str) -> String {
    let encoded_root =
        serde_json::to_string(workspace_root).expect("workspace root is a JSON string");
    // Placeholders are inside JSON strings, so insert the escaped contents
    // without the serializer's surrounding quotes, including on Windows.
    captured.replace("${workspace}", &encoded_root[1..encoded_root.len() - 1])
}

#[test]
fn community_captured_documents_escape_workspace_paths() {
    let captured = r#"{
        "root": "${workspace}",
        "nested": [{ "path": "${workspace}/core" }],
        "unchanged": "already \"quoted\""
    }"#;
    for workspace_root in [
        r"C:\Users\fixture\project",
        r"C:\temp\new\target",
        r"\\server\share\project",
        "C:\\fixture\\\"quoted\"\tworkspace\n",
    ] {
        let document: Value =
            serde_json::from_str(&capture_for_workspace(captured, workspace_root))
                .expect("substituted capture remains valid JSON");
        assert_eq!(
            document,
            json!({
                "root": workspace_root,
                "nested": [{ "path": format!("{workspace_root}/core") }],
                "unchanged": "already \"quoted\"",
            }),
        );
    }
}

type Command = fn(Value) -> Result<Value, crate::protocol::CoreError>;

/// Calls one build operation and requires an `ok` outcome.
fn ok(command: Command, manifest: Value, build_system: &str, request: Value) -> Value {
    let outcome = command(json!({
        "manifest": manifest,
        "buildSystemID": build_system,
        "request": request,
    }))
    .expect("payload is well formed");
    assert_eq!(outcome["status"], "ok", "{outcome}");
    outcome
}

fn arguments(outcome: &Value) -> Vec<&str> {
    outcome["plan"]["arguments"]
        .as_array()
        .unwrap()
        .iter()
        .map(|argument| argument.as_str().unwrap())
        .collect()
}

fn detected_ids(workspace: &Workspace, manifest: Value) -> Vec<String> {
    let outcome = build_detect_command(json!({
        "workspaceRoot": workspace.root(),
        "plugins": [{ "manifest": manifest }],
        "options": {},
    }))
    .expect("payload is well formed");
    assert_eq!(outcome["status"], "ok", "{outcome}");
    outcome["detection"]["instances"]
        .as_array()
        .unwrap()
        .iter()
        .map(|instance| instance["id"].as_str().unwrap().to_string())
        .collect()
}

fn strings(value: &Value, key: &str) -> Vec<String> {
    value
        .as_array()
        .unwrap()
        .iter()
        .map(|item| item[key].as_str().unwrap().to_string())
        .collect()
}

/// Both packages pass the checks Lithe runs before loading and installing a
/// plugin, and installing one shows the build tool it will run.
#[test]
fn community_build_plugins_validate_and_review() {
    for (manifest, build_system) in [(maven(), "maven"), (gradle(), "gradle")] {
        let outcome = validate_command(json!({ "manifest": manifest.clone() })).unwrap();
        assert_eq!(outcome["status"], "ok", "{build_system}: {outcome}");
        let review = install_review_command(json!({ "manifest": manifest })).unwrap();
        assert_eq!(review["status"], "ok", "{build_system}: {review}");
        let programs = review["review"]["programs"].as_array().unwrap();
        let entry = programs
            .iter()
            .find(|program| program["kind"] == "buildSystem")
            .unwrap_or_else(|| panic!("{build_system}: no build system program: {programs:?}"));
        assert_eq!(entry["buildSystemID"], build_system, "{entry}");
    }
}

/// A multi-module build is one instance at its outermost build file.
#[test]
fn community_build_plugins_detect_one_instance_per_build() {
    let workspace = Workspace::new("community-maven-detect");
    workspace
        .write(
            "pom.xml",
            "<project><modules><module>app</module></modules></project>",
        )
        .write("app/pom.xml", "<project/>");
    assert_eq!(detected_ids(&workspace, maven()), ["maven:."]);

    let workspace = Workspace::new("community-gradle-detect");
    workspace
        .write("settings.gradle", "include 'app'\n")
        .write("build.gradle", "\n")
        .write("app/build.gradle", "plugins { id 'java' }\n");
    assert_eq!(detected_ids(&workspace, gradle()), ["gradle:."]);
}

/// The model command loads the bundled extension or init script from the
/// installed plugin and writes to the file Lithe chose.
#[test]
fn community_model_plans_name_the_plugin_directory_and_output() {
    let workspace = Workspace::new("community-model-plans");
    let plugin_directory = workspace.path("plugins/p");
    let output_file = workspace.path("state/model.json");
    let gradle_user_home = workspace.path("caches/gradle");
    // Plugin templates append literal `/` suffixes to the host-native directory.
    let request = |options: Value| {
        json!({
            "root": ".",
            "pluginDirectory": plugin_directory,
            "outputFile": output_file,
            "options": options,
        })
    };
    let outcome = ok(
        build_model_plan_command,
        maven(),
        "maven",
        request(json!({ "profiles": ["release", "ci"], "offline": true })),
    );
    assert_eq!(
        arguments(&outcome),
        [
            "-B",
            "-ntp",
            "-P",
            "ci,release",
            "-o",
            &format!("-Dmaven.ext.class.path={plugin_directory}/lib/lithe-maven-extension.jar"),
            &format!("-Dlithe.modelOutput={output_file}"),
            "pre-clean",
        ]
    );
    assert_eq!(outcome["plan"]["decoder"], "litheBuildModel");
    assert_eq!(outcome["plan"]["executesProjectCode"], true);

    let outcome = ok(
        build_model_plan_command,
        gradle(),
        "gradle",
        request(json!({ "offline": true, "gradleUserHome": gradle_user_home })),
    );
    assert_eq!(
        arguments(&outcome),
        [
            "--console=plain",
            "--offline",
            "--gradle-user-home",
            &gradle_user_home,
            "-q",
            "--no-configuration-cache",
            "--no-configure-on-demand",
            "--init-script",
            &format!("{plugin_directory}/lithe.init.gradle"),
            &format!("-PlitheModelOutput={output_file}"),
            "litheModel",
        ]
    );
}

/// The Maven model lists the reactor, its plugin goals and source folders,
/// and offers the profiles the POMs declare.
#[test]
fn maven_captured_model_decodes() {
    let workspace = Workspace::new("community-maven-model");
    let output = workspace.capture("state/model.json", MAVEN_MODEL);
    let outcome = ok(
        build_decode_model_command,
        maven(),
        "maven",
        json!({ "workspaceRoot": workspace.root(), "root": ".", "outputFile": output }),
    );
    let model = &outcome["model"];
    // Core orders projects by path, not in reactor order.
    assert_eq!(strings(&model["projects"], "path"), [".", "app", "core"]);
    assert_eq!(
        model["projects"][0]["displayName"], "Demo Reactor",
        "{model}"
    );
    assert_eq!(model["optionValues"]["profiles"], json!(["ci", "release"]));

    let tasks = model["tasks"].as_array().unwrap();
    let clean = tasks
        .iter()
        .find(|task| task["name"] == "clean:clean")
        .unwrap_or_else(|| panic!("no clean:clean goal: {tasks:?}"));
    assert_eq!(clean["template"], "plugin-goal", "{clean}");
    assert_eq!(clean["category"], json!(["Plugins", "clean"]));
    assert!(
        model["contentRoots"]
            .as_array()
            .unwrap()
            .iter()
            .any(|root| root["path"] == "core/src/test/java" && root["kind"] == "testSource"),
        "{model}"
    );
    assert!(
        model["run"].as_array().is_none_or(Vec::is_empty),
        "plugin goals are not run entries: {model}"
    );
}

/// The Gradle model lists every project's tasks under their group, and a
/// JavaExec task becomes a run entry that runs by its task path.
#[test]
fn gradle_captured_model_decodes() {
    let workspace = Workspace::new("community-gradle-model");
    let output = workspace.capture("state/model.json", GRADLE_MODEL);
    let outcome = ok(
        build_decode_model_command,
        gradle(),
        "gradle",
        json!({ "workspaceRoot": workspace.root(), "root": ".", "outputFile": output }),
    );
    let model = &outcome["model"];
    assert_eq!(strings(&model["projects"], "path"), [".", "app", "core"]);
    let tasks = model["tasks"].as_array().unwrap();
    let test = tasks
        .iter()
        .find(|task| task["name"] == "test" && task["properties"]["path"] == ":core:test")
        .unwrap_or_else(|| panic!("no :core:test: {tasks:?}"));
    assert_eq!(test["category"], json!(["Tasks", "verification"]));
    assert!(
        model["contentRoots"]
            .as_array()
            .unwrap()
            .iter()
            .any(|root| root["path"]
                == "app/build/generated/sources/annotationProcessor/java/main"
                && root["kind"] == "generatedSource"),
        "{model}"
    );

    let run = model["run"].as_array().unwrap();
    assert_eq!(run.len(), 1, "only JavaExec tasks are run entries: {run:?}");
    assert_eq!(run[0]["name"], "run");
    assert_eq!(run[0]["execution"], "application");
    assert_eq!(run[0]["args"], json!(["--console=plain", ":app:run"]));
    assert_eq!(run[0]["cwd"], ".");
}

/// Lifecycle phases select a module with `-pl`, plugin goals from the model
/// run by their full coordinates, and toolbar options apply to both.
#[test]
fn maven_task_plans() {
    let workspace = Workspace::new("community-maven-task-plans");
    let local_repository = workspace.path("m2");
    let app = json!({ "path": "app", "name": "app" });
    let outcome = ok(
        build_task_plan_command,
        maven(),
        "maven",
        json!({
            "root": ".",
            "task": "install",
            "project": app,
            "options": { "skipTests": true, "localRepository": local_repository },
        }),
    );
    assert_eq!(
        arguments(&outcome),
        [
            "-B",
            "-ntp",
            &format!("-Dmaven.repo.local={local_repository}"),
            "-pl",
            "app",
            "-DskipTests",
            "install"
        ]
    );

    let outcome = ok(
        build_task_plan_command,
        maven(),
        "maven",
        json!({
            "root": ".",
            "task": "plugin-goal",
            "project": { "path": ".", "name": "reactor" },
            "modelTask": {
                "name": "clean:clean",
                "properties": { "goal": "org.apache.maven.plugins:maven-clean-plugin:3.5.0:clean" },
            },
        }),
    );
    assert_eq!(
        arguments(&outcome),
        [
            "-B",
            "-ntp",
            "org.apache.maven.plugins:maven-clean-plugin:3.5.0:clean"
        ]
    );

    let outcome = ok(
        build_task_plan_command,
        maven(),
        "maven",
        json!({
            "root": ".",
            "task": "goal",
            "project": app,
            "userArguments": ["dependency:tree"],
        }),
    );
    assert_eq!(
        arguments(&outcome),
        ["-B", "-ntp", "-pl", "app", "dependency:tree"]
    );
}

/// Root tasks run as selectors, nested ones by path, and "Run Gradle
/// Tasks…" runs in the selected project's directory.
#[test]
fn gradle_task_plans() {
    let task = |project: Value, path: &str| {
        let outcome = ok(
            build_task_plan_command,
            gradle(),
            "gradle",
            json!({
                "root": ".",
                "task": "gradle-task",
                "project": project,
                "modelTask": { "name": "build", "properties": { "path": path } },
            }),
        );
        arguments(&outcome).join(" ")
    };
    let root =
        json!({ "path": ".", "name": "multi", "properties": { "path": ":", "taskPrefix": ":" } });
    let core = json!({ "path": "core", "name": "core", "properties": { "path": ":core", "taskPrefix": ":core:" } });
    assert_eq!(task(root.clone(), "build"), "--console=plain build");
    assert_eq!(
        task(core.clone(), ":core:build"),
        "--console=plain :core:build"
    );

    let custom = |project: Value| {
        let outcome = ok(
            build_task_plan_command,
            gradle(),
            "gradle",
            json!({
                "root": ".",
                "task": "tasks",
                "project": project,
                "options": { "offline": true },
                "userArguments": ["dependencies", "--configuration", "runtimeClasspath"],
            }),
        );
        arguments(&outcome).join(" ")
    };
    assert_eq!(
        custom(root),
        "--console=plain --offline dependencies --configuration runtimeClasspath"
    );
    assert_eq!(
        custom(core),
        "--console=plain --offline --project-dir core dependencies --configuration runtimeClasspath"
    );
}

/// Test runs select a class or method and read the reports the build tool
/// writes for the selected project.
#[test]
fn community_test_plans() {
    let outcome = ok(
        build_test_plan_command,
        maven(),
        "maven",
        json!({
            "root": ".",
            "project": { "path": "core", "name": "core" },
            "suite": "demo.core.GreeterTest",
            "case": "greets",
        }),
    );
    assert_eq!(
        arguments(&outcome),
        [
            "-B",
            "-ntp",
            "-pl",
            "core",
            "-am",
            "-Dtest=demo.core.GreeterTest#greets",
            "-Dsurefire.failIfNoSpecifiedTests=false",
            "test",
        ]
    );
    assert_eq!(outcome["plan"]["results"]["decoder"], "junitXml");

    let core = json!({ "path": "core", "name": "core", "properties": { "path": ":core", "taskPrefix": ":core:" } });
    let outcome = ok(
        build_test_plan_command,
        gradle(),
        "gradle",
        json!({ "root": ".", "project": core, "suite": "demo.core.GreeterTest" }),
    );
    assert_eq!(
        arguments(&outcome),
        [
            "--console=plain",
            ":core:test",
            "--tests",
            "demo.core.GreeterTest"
        ]
    );
    assert_eq!(
        outcome["plan"]["results"],
        json!({ "decoder": "junitXml", "reports": ["core/build/test-results/test/TEST-*.xml"] })
    );

    let outcome = ok(
        build_test_plan_command,
        gradle(),
        "gradle",
        json!({ "root": ".", "projects": [".", "app", "core"] }),
    );
    assert_eq!(arguments(&outcome), ["--console=plain", "test"]);
}

/// A project's dependency tree names the project in the build tool's own
/// terms; the workspace tree asks for every project.
#[test]
fn community_dependency_plans() {
    let workspace = Workspace::new("community-dependency-plans");
    let plugin_directory = workspace.path("plugins/p");
    let output_file = workspace.path("state/deps.json");
    let request = |project: Option<Value>| {
        let mut request = json!({
            "root": ".",
            "pluginDirectory": plugin_directory,
            "outputFile": output_file,
        });
        if let Some(project) = project {
            request["project"] = project;
        }
        request
    };
    let app = json!({ "path": "app", "name": "app", "properties": { "path": ":app", "taskPrefix": ":app:" } });
    let outcome = ok(
        build_dependency_plan_command,
        maven(),
        "maven",
        request(Some(app.clone())),
    );
    assert_eq!(
        arguments(&outcome),
        [
            "-B",
            "-ntp",
            &format!("-Dmaven.ext.class.path={plugin_directory}/lib/lithe-maven-extension.jar"),
            &format!("-Dlithe.dependenciesOutput={output_file}"),
            "-Dlithe.dependenciesProject=app",
            "pre-clean",
        ]
    );
    let outcome = ok(
        build_dependency_plan_command,
        maven(),
        "maven",
        request(None),
    );
    assert!(
        !arguments(&outcome)
            .iter()
            .any(|argument| argument.contains("dependenciesProject")),
        "{outcome}"
    );

    let outcome = ok(
        build_dependency_plan_command,
        gradle(),
        "gradle",
        request(Some(app)),
    );
    assert_eq!(
        arguments(&outcome),
        [
            "--console=plain",
            "-q",
            "--no-configuration-cache",
            "--no-configure-on-demand",
            "--init-script",
            &format!("{plugin_directory}/lithe.init.gradle"),
            &format!("-PlitheDependenciesOutput={output_file}"),
            "-PlitheDependenciesProject=:app",
            "litheDependencyReport",
        ]
    );
    assert_eq!(outcome["plan"]["decoder"], "litheDependencies");
}

/// The captured trees decode with their scopes, project nodes and
/// transitive children intact.
#[test]
fn community_captured_dependencies_decode() {
    let decode = |manifest: Value, build_system: &str, captured: &str, project: Option<&str>| {
        let workspace = Workspace::new("community-dependencies");
        let output = workspace.capture("state/deps.json", captured);
        let mut request =
            json!({ "workspaceRoot": workspace.root(), "root": ".", "outputFile": output });
        if let Some(project) = project {
            request["project"] = json!(project);
        }
        ok(
            build_decode_dependencies_command,
            manifest,
            build_system,
            request,
        )["dependencies"]["dependencies"]
            .clone()
    };

    let tree = decode(maven(), "maven", MAVEN_APP_DEPENDENCIES, Some("app"));
    assert_eq!(
        [&tree[0]["name"], &tree[0]["group"], &tree[0]["scope"]],
        ["core", "demo", "compile"]
    );
    let tree = decode(maven(), "maven", MAVEN_DEPENDENCIES, None);
    assert_eq!(strings(&tree, "name"), ["reactor", "core", "app"]);
    let junit = &tree[1]["children"][0];
    assert_eq!(
        [&junit["name"], &junit["version"], &junit["scope"]],
        ["junit", "4.13.2", "test"]
    );
    assert_eq!(junit["children"][0]["name"], "hamcrest-core");

    let tree = decode(gradle(), "gradle", GRADLE_APP_DEPENDENCIES, Some("app"));
    assert_eq!(
        strings(&tree, "name"),
        [
            "compileClasspath",
            "runtimeClasspath",
            "testCompileClasspath",
            "testRuntimeClasspath"
        ]
    );
    assert_eq!(
        tree[0]["children"][0]["properties"],
        json!({ "kind": "project", "path": ":core" })
    );
    let tree = decode(gradle(), "gradle", GRADLE_DEPENDENCIES, None);
    assert_eq!(strings(&tree, "name"), ["multi", "app", "core"]);
    let test_classpath = tree[2]["children"]
        .as_array()
        .unwrap()
        .iter()
        .find(|node| node["name"] == "testCompileClasspath")
        .unwrap();
    assert_eq!(test_classpath["children"][0]["name"], "junit");
    assert_eq!(
        test_classpath["children"][0]["children"][0]["name"],
        "hamcrest-core"
    );
}

/// Compiler output in each tool's format becomes workspace-relative problems.
#[test]
fn community_diagnostics_decode() {
    let workspace = Workspace::new("community-diagnostics");
    let root = workspace.root();
    let decode = |manifest: Value, build_system: &str, output: String| {
        ok(
            build_decode_diagnostics_command,
            manifest,
            build_system,
            json!({ "workspaceRoot": root, "root": ".", "output": output }),
        )["diagnostics"]
            .clone()
    };

    let diagnostics = decode(
        maven(),
        "maven",
        format!(
            "[INFO] Compiling 1 source file\n\
             [ERROR] {root}/core/src/main/java/demo/core/Greeter.java:[7,9] cannot find symbol\n\
             [WARNING] {root}/app/src/main/java/demo/app/Main.java:[3,1] deprecated\n\
             [ERROR] file://{root}/core/src/main/kotlin/Util.kt:4:2 Unresolved reference: x\n"
        ),
    );
    assert_eq!(
        diagnostics,
        json!([
            { "path": "core/src/main/java/demo/core/Greeter.java", "line": 7, "column": 9, "severity": "error", "message": "cannot find symbol" },
            { "path": "app/src/main/java/demo/app/Main.java", "line": 3, "column": 1, "severity": "warning", "message": "deprecated" },
            { "path": "core/src/main/kotlin/Util.kt", "line": 4, "column": 2, "severity": "error", "message": "Unresolved reference: x" },
        ])
    );

    let diagnostics = decode(
        gradle(),
        "gradle",
        format!(
            "> Task :core:compileJava\n\
             {root}/core/src/main/java/demo/core/Greeter.java:7: error: ';' expected\n\
             w: file://{root}/app/build.gradle.kts:3:5 Variable 'x' is never used\n"
        ),
    );
    assert_eq!(
        strings(&diagnostics, "path"),
        [
            "core/src/main/java/demo/core/Greeter.java",
            "app/build.gradle.kts"
        ]
    );
    assert_eq!(strings(&diagnostics, "severity"), ["error", "warning"]);
}

/// The user's build options reach the Java language server's import in the
/// shapes `lsp.startServer` takes, without the host knowing either plugin.
#[test]
fn community_build_options_map_to_the_java_import() {
    let workspace = Workspace::new("community-language-import");
    workspace.write("pom.xml", "<project/>");
    let maven_executable = workspace.path("opt/maven/bin/mvn");
    let settings_file = workspace.path("home/me/.m2/settings.xml");
    let gradle_user_home = workspace.path("caches/gradle");
    let import = |manifest: Value, build_system: &str, options: Value| {
        ok(
            build_language_import_command,
            manifest,
            build_system,
            json!({
                "workspaceRoot": workspace.root(),
                "root": ".",
                "options": options,
                "executablePath": maven_executable,
            }),
        )["languageImport"]
            .clone()
    };

    let maven_import = import(
        maven(),
        "maven",
        json!({
            "profiles": ["release", "ci"],
            "settingsFile": settings_file,
            "offline": true,
            "skipTests": true,
        }),
    );
    assert_eq!(
        maven_import,
        json!({
            "kind": "maven",
            "mavenContext": {
                "version": 1,
                "reactorPath": ".",
                "profiles": ["ci", "release"],
                "settingsPath": settings_file,
                "mavenExecutablePath": maven_executable,
            },
        })
    );
    // Core accepts the context as the Maven launch context it already reads.
    let context: crate::project::MavenLaunchContextRequest =
        serde_json::from_value(maven_import["mavenContext"].clone()).unwrap();
    crate::project::jdt_configuration(&workspace.root(), context).expect("valid Maven context");

    assert_eq!(
        import(gradle(), "gradle", json!({}))["javaGradle"],
        json!({ "wrapperPresent": false, "offline": false })
    );
    workspace.write(
        "gradle/wrapper/gradle-wrapper.properties",
        "distributionUrl=x\n",
    );
    let gradle_import = import(
        gradle(),
        "gradle",
        json!({ "offline": true, "gradleUserHome": gradle_user_home }),
    );
    assert_eq!(
        gradle_import,
        json!({
            "kind": "gradle",
            "javaGradle": { "wrapperPresent": true, "offline": true, "userHome": gradle_user_home },
        })
    );
    let _: crate::lsp::jdt::JdtGradleConfiguration =
        serde_json::from_value(gradle_import["javaGradle"].clone()).unwrap();

    // A build system without the declaration has no import to configure.
    let mut plain = gradle();
    plain["buildSystems"][0]
        .as_object_mut()
        .unwrap()
        .remove("languageImport");
    assert_eq!(import(plain, "gradle", json!({})), Value::Null);
}

/// An import setting must name an option of the kind the setting needs.
#[test]
fn language_import_settings_must_name_matching_options() {
    for (options, field) in [
        (json!({ "profiles": "missing" }), "profiles"),
        (json!({ "profiles": "offline" }), "profiles"),
        (
            json!({ "gradleUserHome": "localRepository" }),
            "gradleUserHome",
        ),
    ] {
        let mut manifest = maven();
        manifest["buildSystems"][0]["languageImport"]["options"] = options.clone();
        let outcome = validate_command(json!({ "manifest": manifest })).unwrap();
        assert_eq!(outcome["status"], "rejected", "{options}: {outcome}");
        assert_eq!(
            outcome["error"]["field"],
            format!("buildSystems[0].languageImport.options.{field}"),
            "{outcome}"
        );
    }
}
