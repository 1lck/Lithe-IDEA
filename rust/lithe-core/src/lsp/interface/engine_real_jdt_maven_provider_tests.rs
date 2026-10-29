//! Opt-in Maven Provider -> JDT -> project JVM integration, with installed
//! resources kept read-only and both workspace sessions owned by the test.

use super::*;
use sha2::{Digest, Sha256};

fn command(name: &str, payload: Value) -> Value {
    let response: Value = serde_json::from_str(&crate::execute_json(
        &json!({"id":"java-provider-integration", "command":name, "payload":payload}).to_string(),
    ))
    .expect("Core JSON response");
    assert_eq!(response["ok"], true, "{response}");
    assert_eq!(response["data"]["status"], "ok", "{response}");
    response["data"].clone()
}

fn build_command(manifest: &Value, name: &str, request: Value) -> Value {
    command(
        name,
        json!({"manifest":manifest,"buildSystemID":"maven","request":request}),
    )
}

fn provider_request(engine: &LspEngine, session: &Arc<RuntimeSession>, plan: &Value) -> Value {
    let operation = engine.next_operation_id();
    session
        .build_request(
            BuildProviderRequest {
                session_id: session.id.clone(),
                operation_id: Some(operation.clone()),
                method: plan["provider"]["method"]
                    .as_str()
                    .expect("provider method")
                    .into(),
                params: plan["provider"]["params"].clone(),
                timeout_milliseconds: Some(120_000),
            },
            operation.clone(),
        )
        .expect("Core should admit the selected Provider request");
    await_operation(session, &operation, Duration::from_secs(120))
        .unwrap_or_else(|error| panic!("Provider request failed: {error}"))["value"]
        .clone()
}

fn write(root: &Path, path: &str, content: &str) {
    let file = root.join(path);
    std::fs::create_dir_all(file.parent().expect("fixture parent")).expect("fixture directory");
    std::fs::write(file, content).expect("fixture contents");
}

/// A byte-sensitive inventory, unlike a size-only listing, also detects an
/// upstream process rewriting an installed file without changing its length.
fn inventory(root: &Path) -> BTreeMap<PathBuf, String> {
    installation_listing(root)
        .into_keys()
        .map(|relative| {
            let path = root.join(&relative);
            let digest = if path.is_symlink() {
                format!(
                    "link:{:?}",
                    std::fs::read_link(path).expect("installed symlink")
                )
            } else {
                format!(
                    "{:x}",
                    Sha256::digest(std::fs::read(path).expect("installed file"))
                )
            };
            (relative, digest)
        })
        .collect()
}

#[test]
fn real_provider_resources_survive_jdt_build_and_reach_the_project_jvm() {
    // This is an explicit tool integration, never an installed-tools dependency
    // of the ordinary unit lane. A missing requested tool fails, not skips.
    let Some(package) = std::env::var_os("LITHE_JDTLS_SMOKE_MAVEN_PACKAGE") else {
        return;
    };
    let toolchain = real_jdt_toolchain().expect("select the packaged JDT and both JDKs");
    let package = PathBuf::from(package);
    let maven = toolchain
        .maven
        .as_ref()
        .expect("select Maven for the integration");
    let manifest: Value = serde_json::from_slice(
        &std::fs::read(package.join("plugin.json")).expect("Maven manifest"),
    )
    .expect("Maven manifest JSON");
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("Unix time")
        .as_nanos();
    let scratch = std::env::temp_dir().join(format!(
        "lithe-java-provider-{}-{stamp}",
        std::process::id()
    ));
    let engine = LspEngine::new();
    // Own the tree before the first fixture write, including partial setup.
    let _scratch_cleanup = RealSmokeCleanup {
        engine: &engine,
        session_id: "not-started".into(),
        root: scratch.clone(),
    };
    let workspace = scratch.join("workspace");
    // Keep a nested reactor and a nonstandard source/resource layout. No host
    // filename convention can manufacture these project/source-role facts.
    write(
        &workspace,
        "nested/pom.xml",
        r#"<project><modelVersion>4.0.0</modelVersion>
      <groupId>smoke</groupId><artifactId>reactor</artifactId><version>1</version><packaging>pom</packaging>
      <modules><module>library</module><module>app</module></modules>
      <properties><maven.compiler.source>8</maven.compiler.source><maven.compiler.target>8</maven.compiler.target>
        <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding></properties></project>"#,
    );
    write(
        &workspace,
        "nested/library/pom.xml",
        r#"<project><modelVersion>4.0.0</modelVersion>
      <parent><groupId>smoke</groupId><artifactId>reactor</artifactId><version>1</version></parent>
      <artifactId>library</artifactId></project>"#,
    );
    write(&workspace, "nested/library/src/main/java/demo/Library.java",
        "package demo; public class Library { public static String value() { return \"library\"; } }");
    write(
        &workspace,
        "nested/app/pom.xml",
        r#"<project><modelVersion>4.0.0</modelVersion>
      <parent><groupId>smoke</groupId><artifactId>reactor</artifactId><version>1</version></parent><artifactId>app</artifactId>
      <dependencies><dependency><groupId>smoke</groupId><artifactId>library</artifactId><version>1</version></dependency></dependencies>
      <build><sourceDirectory>sources</sourceDirectory><testSourceDirectory>checks</testSourceDirectory>
        <resources><resource><directory>runtime inputs</directory><filtering>true</filtering></resource></resources>
        <testResources><testResource><directory>test inputs</directory><filtering>true</filtering></testResource></testResources>
      </build><profiles><profile><id>launch</id><properties><selected.value>provider</selected.value></properties></profile></profiles></project>"#,
    );
    write(
        &workspace,
        "nested/app/sources/demo/Main.java",
        r#"package demo;
      public class Main { public static void main(String[] args) throws Exception {
        java.util.Properties p = new java.util.Properties();
        try (java.io.InputStream input = Main.class.getResourceAsStream("/runtime.properties")) { p.load(input); }
        System.out.println(p.getProperty("selected") + ":" + Library.value());
      } }"#,
    );
    write(
        &workspace,
        "nested/app/checks/demo/TestMain.java",
        r#"package demo;
      public class TestMain { public static void main(String[] args) throws Exception {
        java.util.Properties p = new java.util.Properties();
        try (java.io.InputStream input = TestMain.class.getResourceAsStream("/test.properties")) { p.load(input); }
        System.out.println(p.getProperty("selected") + ":" + Library.value());
      } }"#,
    );
    write(
        &workspace,
        "nested/app/runtime inputs/runtime.properties",
        "selected=${selected.value}:initial",
    );
    write(
        &workspace,
        "nested/app/test inputs/test.properties",
        "selected=${selected.value}:test-initial",
    );
    let workspace = workspace.canonicalize().expect("canonical workspace");
    let root_uri = url::Url::from_directory_path(&workspace)
        .expect("workspace URI")
        .to_string();
    let before_package = inventory(&package);
    let before_jdt = inventory(&toolchain.root);
    let mut provider_start = real_start_request(&toolchain, &scratch, &workspace, &root_uri);
    provider_start.provider_id = "test.maven".into();
    provider_start.executable_path = toolchain
        .project_jdk
        .join("bin")
        .join(if cfg!(windows) { "java.exe" } else { "java" })
        .to_string_lossy()
        .into();
    provider_start.arguments = vec![
        "-jar".into(),
        package
            .join("lib/lithe-maven-backend.jar")
            .to_string_lossy()
            .into(),
        "--state".into(),
        scratch.join("provider-state").to_string_lossy().into(),
    ];
    provider_start.environment.insert(
        "JAVA_HOME".into(),
        toolchain.project_jdk.to_string_lossy().into(),
    );
    provider_start.runtime_executable_path = None;
    provider_start.jdtls_launch_resources = None;
    provider_start.java_runtimes.clear();
    let started = engine
        .start_server(provider_start)
        .expect("start the real Maven Provider");
    let _provider_cleanup = RealSmokeCleanup {
        engine: &engine,
        session_id: started.session_id.clone(),
        root: scratch.join("provider-state"),
    };
    let provider = engine
        .session(&started.session_id)
        .expect("Provider session");
    await_real_smoke_ready(&provider).unwrap_or_else(|error| panic!("{error}"));
    let options = json!({"profiles":["launch"]});
    let base = json!({"root":"nested","options":options,"pluginDirectory":package,
        "workspaceStateDirectory":scratch.join("provider-state"),"tool":{"executable":maven,
        "environment":{"JAVA_HOME":toolchain.project_jdk}}});
    let model_plan = build_command(&manifest, "build.modelPlan", base.clone());
    let raw = provider_request(&engine, &provider, &model_plan["plan"]);
    let model = build_command(
        &manifest,
        "build.decodeModel",
        json!({"workspaceRoot":workspace,"root":"nested","options":options,"result":raw}),
    )["model"]
        .clone();
    let project = model["projects"]
        .as_array()
        .expect("projects")
        .iter()
        .find(|p| p["name"] == "app")
        .expect("app project");
    assert!(
        model["contentRoots"]
            .as_array()
            .expect("source roles")
            .iter()
            .any(|r| r["path"] == "nested/app/checks" && r["kind"] == "testSource"),
        "{model}"
    );
    let import = build_command(
        &manifest,
        "build.languageImport",
        json!({"workspaceRoot":workspace,"root":"nested","options":options,"executablePath":maven}),
    );
    let mut java_start = real_start_request(&toolchain, &scratch, &workspace, &root_uri);
    java_start.maven_context = Some(
        serde_json::from_value(import["languageImport"]["mavenContext"].clone())
            .expect("public language import"),
    );
    let release = std::fs::read_to_string(toolchain.project_jdk.join("release"))
        .expect("project JDK release");
    java_start.java_runtimes[0].version =
        crate::execution::java_feature_version_from_release(&release)
            .expect("JDK feature")
            .to_string();
    let started = engine.start_server(java_start).expect("start packaged JDT");
    let _jdt_cleanup = RealSmokeCleanup {
        engine: &engine,
        session_id: started.session_id.clone(),
        root: scratch.join("cache"),
    };
    let jdt = engine.session(&started.session_id).expect("JDT session");
    await_real_smoke_ready(&jdt).unwrap_or_else(|error| panic!("{error}"));
    let entries = await_real_entrypoints(&engine, &jdt, 2);
    // Change resources after import: startup copying cannot make the test pass.
    write(
        &workspace,
        "nested/app/runtime inputs/runtime.properties",
        "selected=${selected.value}:changed",
    );
    write(
        &workspace,
        "nested/app/test inputs/test.properties",
        "selected=${selected.value}:test-changed",
    );
    for (class, task, expected) in [
        (
            "demo.Main",
            "java-prepare-run-main",
            "provider:changed:library",
        ),
        (
            "demo.TestMain",
            "java-prepare-run-test",
            "provider:test-changed:library",
        ),
    ] {
        let mut request = base.clone();
        request["task"] = json!(task);
        request["project"] = project.clone();
        let plan = build_command(&manifest, "build.taskPlan", request);
        let result = provider_request(&engine, &provider, &plan["plan"]);
        assert_eq!(result["exitCode"], 0, "{result}");
        let entry = entries["entries"]
            .as_array()
            .expect("entry points")
            .iter()
            .find(|e| e["mainClass"] == class)
            .expect("exact JDT entry");
        let built = execute_real_command(&engine, &jdt, json!({"command":"vscode.java.buildWorkspace","arguments":[json!({
            "mainClass":class,"projectName":entry["projectName"],"filePath":workspace.join(entry["sourcePath"].as_str().expect("source")),"isFullBuild":false}).to_string()]}), Duration::from_secs(120))
            .unwrap_or_else(|error| panic!("JDT build failed: {error}"));
        assert_eq!(built["value"], 1, "{built}");
        let paths = execute_real_command(&engine, &jdt, json!({"command":"vscode.java.resolveClasspath","arguments":[class,entry["projectName"]]}), Duration::from_secs(60))
            .unwrap_or_else(|error| panic!("JDT paths failed: {error}"));
        let classpath = paths["value"][1]
            .as_array()
            .expect("JDT classpaths")
            .iter()
            .map(|p| p.as_str().expect("classpath"))
            .collect::<Vec<_>>()
            .join(if cfg!(windows) { ";" } else { ":" });
        let mut launch =
            std::process::Command::new(toolchain.project_jdk.join("bin").join(if cfg!(windows) {
                "java.exe"
            } else {
                "java"
            }));
        launch
            .args(["-cp", &classpath, class])
            .current_dir(&workspace);
        let deadline = Instant::now() + Duration::from_secs(15);
        let output = lithe_git_host::run(
            &mut launch,
            None,
            || Instant::now() >= deadline,
            || {},
            |_, _| {},
        );
        assert!(
            output.failure.is_none() && output.status.is_some_and(|s| s.success()),
            "JVM failed: {:?} {}",
            output.failure,
            String::from_utf8_lossy(&output.stderr)
        );
        assert_eq!(String::from_utf8_lossy(&output.stdout).trim(), expected);
    }
    drop(_jdt_cleanup);
    drop(_provider_cleanup);
    assert_eq!(
        inventory(&package),
        before_package,
        "Maven plugin package changed"
    );
    assert_eq!(
        inventory(&toolchain.root),
        before_jdt,
        "JDT installation changed"
    );
}
