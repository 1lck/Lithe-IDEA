//! Opt-in end-to-end checks against a real, packaged JDT LS.
//!
//! They run only when `LITHE_JDTLS_SMOKE_ROOT` names a directory prepared by
//! `scripts/prepare-jdtls.{sh,ps1}`, `LITHE_JDTLS_SMOKE_JAVA` names the Java
//! executable that runs JDT LS, and `LITHE_JDTLS_SMOKE_PROJECT_JDK` names a
//! JDK 25 home for the fixture project. Optional `LITHE_JDTLS_SMOKE_MAVEN`
//! names Maven so the discovered composed and inherited tests are also run.
//! They launch JDT LS exactly as the
//! product does (direct Java launch with the Debug and Test bundles) so that a
//! toolchain upgrade that breaks discovery, building, or launching fails here.

use super::tests::{await_real_smoke_ready, RealSmokeCleanup};
use super::*;

/// Paths an opt-in real JDT LS check needs, or `None` when not configured.
struct RealJdtToolchain {
    root: PathBuf,
    java: String,
    project_jdk: PathBuf,
    maven: Option<String>,
}

fn real_jdt_toolchain() -> Option<RealJdtToolchain> {
    let root = std::env::var_os("LITHE_JDTLS_SMOKE_ROOT")?;
    let java = std::env::var("LITHE_JDTLS_SMOKE_JAVA")
        .expect("LITHE_JDTLS_SMOKE_JAVA must accompany LITHE_JDTLS_SMOKE_ROOT");
    let project_jdk = std::env::var_os("LITHE_JDTLS_SMOKE_PROJECT_JDK")
        .expect("LITHE_JDTLS_SMOKE_PROJECT_JDK must accompany LITHE_JDTLS_SMOKE_ROOT");
    let maven = std::env::var("LITHE_JDTLS_SMOKE_MAVEN").ok();
    Some(RealJdtToolchain {
        root: PathBuf::from(root),
        java,
        project_jdk: PathBuf::from(project_jdk),
        maven,
    })
}

/// Size of every file below a JDT LS installation, keyed by relative path.
/// Symbolic links are recorded without being followed.
fn installation_listing(root: &Path) -> BTreeMap<PathBuf, u64> {
    let mut listing = BTreeMap::new();
    let mut pending = vec![root.to_path_buf()];
    while let Some(directory) = pending.pop() {
        for entry in std::fs::read_dir(&directory).expect("installation should be readable") {
            let path = entry.expect("installation entry").path();
            let metadata = std::fs::symlink_metadata(&path).expect("installation metadata");
            if metadata.is_dir() {
                pending.push(path);
            } else {
                let relative = path.strip_prefix(root).expect("entry inside root");
                listing.insert(relative.to_path_buf(), metadata.len());
            }
        }
    }
    listing
}

/// Direct-launch resources laid out by the prepare scripts.
fn packaged_launch_resources(root: &Path) -> JdtlsLaunchResources {
    let plugins = std::fs::read_dir(root.join("plugins")).expect("JDTLS plugins directory");
    let mut launchers = plugins
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.starts_with("org.eclipse.equinox.launcher_"))
        })
        .collect::<Vec<_>>();
    launchers.sort();
    let configuration = if cfg!(windows) {
        "config_win"
    } else if cfg!(target_os = "macos") {
        if cfg!(target_arch = "aarch64") {
            "config_mac_arm"
        } else {
            "config_mac"
        }
    } else {
        "config_linux"
    };
    let debug_bundle = std::fs::read_dir(root.join("java-debug"))
        .expect("Java Debug directory")
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .find(|path| path.extension().is_some_and(|extension| extension == "jar"))
        .expect("Java Debug bundle");
    let test_bundles = std::fs::read_to_string(root.join("java-test").join("extensions.txt"))
        .expect("Java Test bundle list")
        .lines()
        .filter(|name| !name.trim().is_empty())
        .map(|name| {
            root.join("java-test")
                .join("extensions")
                .join(name.trim())
                .to_string_lossy()
                .into_owned()
        })
        .collect::<Vec<_>>();
    JdtlsLaunchResources {
        launcher_jar_path: launchers
            .first()
            .expect("Equinox launcher")
            .to_string_lossy()
            .into_owned(),
        configuration_directory: root.join(configuration).to_string_lossy().into_owned(),
        lombok_agent_path: root
            .join("lombok")
            .join("lombok.jar")
            .to_string_lossy()
            .into_owned(),
        java_debug_bundle_path: Some(debug_bundle.to_string_lossy().into_owned()),
        java_extension_bundle_paths: test_bundles,
    }
}

/// Java 25 sources covering every entry-point form the JVM accepts, plus
/// declarations that only look like entry points.
const JAVA_25_ENTRYPOINT_SOURCES: &[(&str, &str)] = &[
    (
        "src/main/java/demo/ClassicMain.java",
        "package demo;\npublic class ClassicMain { public static void main(String[] args) { System.out.println(\"classic\"); } }\n",
    ),
    (
        "src/main/java/demo/StaticNoArgs.java",
        "package demo;\npublic class StaticNoArgs { static void main() { System.out.println(\"static-noargs\"); } }\n",
    ),
    (
        "src/main/java/demo/InstanceArgs.java",
        "package demo;\npublic class InstanceArgs { void main(String[] args) { System.out.println(\"instance-args\"); } }\n",
    ),
    (
        "src/main/java/demo/InstanceNoArgs.java",
        "package demo;\npublic class InstanceNoArgs { void main() { System.out.println(\"instance-noargs\"); } }\n",
    ),
    (
        "src/main/java/Compact.java",
        "void main() {\n    IO.println(\"compact\");\n}\n",
    ),
    (
        "src/main/java/demo/PrivateMain.java",
        "package demo;\npublic class PrivateMain { private static void main(String[] args) { } }\n",
    ),
    (
        "src/main/java/demo/NotRunnable.java",
        "package demo;\npublic class NotRunnable { public static int main(String[] args) { return 0; } }\n",
    ),
    (
        "src/main/java/demo/Samples.java",
        "package demo;\nclass Samples { String sample = \"public static void main(String[] args) {}\"; }\n",
    ),
];

/// Test sources whose membership cannot be decided by file names or direct
/// annotations alone. Java Test/JDT must resolve the composed annotation and
/// inherited method.
const JAVA_TEST_SOURCES: &[(&str, &str)] = &[
    (
        "src/test/java/MainTests.java",
        "public class MainTests { public static void main(String[] args) { org.junit.jupiter.api.Assertions.assertTrue(true); System.out.println(\"test-main\"); } }\n",
    ),
    (
        "src/test/java/demo/FastTest.java",
        "package demo;\nimport java.lang.annotation.*;\nimport org.junit.jupiter.api.Test;\n@Retention(RetentionPolicy.RUNTIME)\n@Target(ElementType.METHOD)\n@Test\npublic @interface FastTest {}\n",
    ),
    (
        "src/test/java/demo/OddlyNamedSpec.java",
        "package demo;\nimport java.nio.file.*;\nclass OddlyNamedSpec {\n    @FastTest void composedAnnotation() throws Exception { Files.writeString(Path.of(\"target/composed-ran\"), \"yes\"); }\n}\n",
    ),
    (
        "src/test/java/demo/BaseBehavior.java",
        "package demo;\nimport java.nio.file.*;\nimport org.junit.jupiter.api.Test;\nclass BaseBehavior {\n    @Test void inheritedBehavior() throws Exception { Files.writeString(Path.of(\"target/inherited-ran\"), \"yes\"); }\n}\n",
    ),
    (
        "src/test/java/demo/InheritedSuite.java",
        "package demo;\nclass InheritedSuite extends BaseBehavior {}\n",
    ),
];

const JAVA_25_POM: &str = r#"<project xmlns="http://maven.apache.org/POM/4.0.0">
  <modelVersion>4.0.0</modelVersion>
  <groupId>smoke</groupId>
  <artifactId>java25-entrypoints</artifactId>
  <version>1.0.0</version>
  <properties>
    <maven.compiler.release>25</maven.compiler.release>
    <project.build.sourceEncoding>UTF-8</project.build.sourceEncoding>
  </properties>
  <dependencies>
    <dependency>
      <groupId>org.junit.jupiter</groupId>
      <artifactId>junit-jupiter</artifactId>
      <version>5.14.0</version>
      <scope>test</scope>
    </dependency>
  </dependencies>
  <build>
    <testOutputDirectory>${project.basedir}/target/test-main-output</testOutputDirectory>
    <plugins>
      <plugin>
        <groupId>org.apache.maven.plugins</groupId>
        <artifactId>maven-surefire-plugin</artifactId>
        <version>3.5.4</version>
      </plugin>
    </plugins>
  </build>
</project>
"#;

/// Sends one `workspace/executeCommand` and waits for its result event.
fn execute_real_command(
    engine: &LspEngine,
    session: &Arc<RuntimeSession>,
    command: Value,
    timeout: Duration,
) -> Result<Value, String> {
    let operation_id = engine.next_operation_id();
    session
        .request(
            SemanticRequest {
                session_id: session.id.clone(),
                operation_id: Some(operation_id.clone()),
                operation: LspSemanticOperation::ExecuteCommand,
                uri: None,
                virtual_uri: None,
                position: None,
                new_name: None,
                range: None,
                diagnostics: Vec::new(),
                completion_item: None,
                code_action: None,
                command: Some(command.clone()),
            },
            operation_id.clone(),
        )
        .map_err(|error| error.message)?;
    await_operation(session, &operation_id, timeout).map_err(|error| format!("{command}: {error}"))
}

fn await_operation(
    session: &Arc<RuntimeSession>,
    operation_id: &str,
    timeout: Duration,
) -> Result<Value, String> {
    let deadline = Instant::now() + timeout;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            return Err(format!("timed out after {timeout:?}"));
        }
        // Blocks until the engine publishes events rather than sleeping.
        for event in session
            .wait_events(remaining)
            .map_err(|error| error.message)?
        {
            if event.operation_id.as_deref() != Some(operation_id) {
                continue;
            }
            if let Some(error) = event.error {
                return Err(format!("{error:?}"));
            }
            return Ok(event.result.unwrap_or(Value::Null));
        }
    }
}

fn request_real_entrypoints(
    engine: &LspEngine,
    session: &Arc<RuntimeSession>,
) -> Result<Value, String> {
    let operation_id = engine.next_operation_id();
    session
        .request(
            SemanticRequest {
                session_id: session.id.clone(),
                operation_id: Some(operation_id.clone()),
                operation: LspSemanticOperation::JavaEntrypoints,
                uri: None,
                virtual_uri: None,
                position: None,
                new_name: None,
                range: None,
                diagnostics: Vec::new(),
                completion_item: None,
                code_action: None,
                command: None,
            },
            operation_id.clone(),
        )
        .map_err(|error| error.message)?;
    await_operation(session, &operation_id, Duration::from_secs(60))
}

fn request_real_test_items(
    engine: &LspEngine,
    session: &Arc<RuntimeSession>,
    uri: String,
) -> Result<Value, String> {
    let operation_id = engine.next_operation_id();
    session
        .request(
            SemanticRequest {
                session_id: session.id.clone(),
                operation_id: Some(operation_id.clone()),
                operation: LspSemanticOperation::JavaTestItems,
                uri: Some(uri),
                virtual_uri: None,
                position: None,
                new_name: None,
                range: None,
                diagnostics: Vec::new(),
                completion_item: None,
                code_action: None,
                command: None,
            },
            operation_id.clone(),
        )
        .map_err(|error| error.message)?;
    await_operation(session, &operation_id, Duration::from_secs(60))
}

/// Launches JDT LS for `workspace` the way the product does, keeping every
/// cache below `root`.
fn real_start_request(
    toolchain: &RealJdtToolchain,
    root: &Path,
    workspace: &Path,
    root_uri: &str,
) -> StartServerRequest {
    let java_home = PathBuf::from(&toolchain.java)
        .parent()
        .and_then(Path::parent)
        .expect("JDT LS Java should be inside a JDK bin directory")
        .to_path_buf();
    StartServerRequest {
        provider_id: "java".to_string(),
        plugin_id: None,
        executable_path: toolchain
            .root
            .join("bin")
            .join("jdtls")
            .to_string_lossy()
            .into_owned(),
        arguments: Vec::new(),
        environment: BTreeMap::from([(
            "JAVA_HOME".to_string(),
            java_home.to_string_lossy().into_owned(),
        )]),
        root_uri: root_uri.to_string(),
        working_directory: workspace.to_string_lossy().into_owned(),
        initialization_options: None,
        runtime_executable_path: Some(toolchain.java.clone()),
        jdtls_launch_resources: Some(packaged_launch_resources(&toolchain.root)),
        cache_directory: Some(root.join("cache").to_string_lossy().into_owned()),
        workspace_fingerprint: None,
        maven_context: None,
        // The project compiles for release 25 while JDT LS itself runs on
        // an older JDK, as in the product.
        java_runtimes: vec![JavaRuntimeCandidate {
            home_path: toolchain.project_jdk.to_string_lossy().into_owned(),
            version: "25".to_string(),
        }],
        java_gradle: None,
        initialize_timeout_milliseconds: 90_000,
        service_ready_idle_timeout_milliseconds: 45_000,
        service_ready_absolute_timeout_milliseconds: 600_000,
        request_timeout_milliseconds: 60_000,
        java_build_timeout_milliseconds: DEFAULT_JAVA_BUILD_TIMEOUT_MS,
        shutdown_timeout_milliseconds: 10_000,
    }
}

/// Asks for entry points until JDT, which can finish importing shortly after
/// it reports ready, lists at least `minimum` of them.
fn await_real_entrypoints(
    engine: &LspEngine,
    session: &Arc<RuntimeSession>,
    minimum: usize,
) -> Value {
    let import_deadline = Instant::now() + Duration::from_secs(120);
    loop {
        let result = request_real_entrypoints(engine, session)
            .unwrap_or_else(|error| panic!("entry-point discovery failed: {error}"));
        if result["entries"]
            .as_array()
            .is_some_and(|entries| entries.len() >= minimum)
        {
            return result;
        }
        assert!(
            Instant::now() < import_deadline,
            "JDT did not report the fixture entry points: {result}"
        );
        // Import progress arrives as events; wait for the next one instead of
        // sleeping, bounded so a silent server still reaches the deadline.
        session
            .wait_events(
                import_deadline
                    .saturating_duration_since(Instant::now())
                    .min(Duration::from_secs(5)),
            )
            .expect("JDT events should be readable");
    }
}

#[test]
fn real_jdtls_discovers_builds_and_launches_java_25_entrypoints() {
    let Some(toolchain) = real_jdt_toolchain() else {
        return;
    };
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("system clock should follow the Unix epoch")
        .as_nanos();
    let root = std::env::temp_dir().join(format!(
        "lithe-real-jdt-entrypoints-{}-{stamp}",
        std::process::id()
    ));
    let workspace = root.join("workspace");
    for (relative, source) in JAVA_25_ENTRYPOINT_SOURCES {
        let path = workspace.join(relative);
        std::fs::create_dir_all(path.parent().expect("source parent"))
            .expect("fixture source directory");
        std::fs::write(&path, source).expect("fixture source");
    }
    for (relative, source) in JAVA_TEST_SOURCES {
        let path = workspace.join(relative);
        std::fs::create_dir_all(path.parent().expect("test source parent"))
            .expect("fixture test source directory");
        std::fs::write(&path, source).expect("fixture test source");
    }
    std::fs::write(workspace.join("pom.xml"), JAVA_25_POM).expect("fixture pom");
    let canonical_workspace = workspace.canonicalize().expect("workspace canonicalizes");
    let root_uri = url::Url::from_directory_path(&canonical_workspace)
        .expect("workspace converts to a file URI")
        .to_string();
    let installation_before = installation_listing(&toolchain.root);

    let engine = LspEngine::new();
    let started = engine
        .start_server(real_start_request(&toolchain, &root, &workspace, &root_uri))
        .expect("real JDTLS should start");
    let _cleanup = RealSmokeCleanup {
        engine: &engine,
        session_id: started.session_id.clone(),
        root: root.clone(),
    };
    let session = engine
        .session(&started.session_id)
        .expect("real JDTLS session should be registered");
    await_real_smoke_ready(&session).unwrap_or_else(|error| panic!("{error}"));

    let entrypoints = await_real_entrypoints(&engine, &session, 6);
    let discovered = entrypoints["entries"]
        .as_array()
        .expect("entries array")
        .iter()
        .map(|entry| {
            (
                entry["mainClass"].as_str().unwrap_or_default().to_string(),
                entry["sourcePath"].as_str().unwrap_or_default().to_string(),
            )
        })
        .collect::<Vec<_>>();
    assert_eq!(
        discovered,
        vec![
            (
                "Compact".to_string(),
                "src/main/java/Compact.java".to_string()
            ),
            (
                "demo.ClassicMain".to_string(),
                "src/main/java/demo/ClassicMain.java".to_string()
            ),
            (
                "demo.InstanceArgs".to_string(),
                "src/main/java/demo/InstanceArgs.java".to_string()
            ),
            (
                "demo.InstanceNoArgs".to_string(),
                "src/main/java/demo/InstanceNoArgs.java".to_string()
            ),
            (
                "demo.StaticNoArgs".to_string(),
                "src/main/java/demo/StaticNoArgs.java".to_string()
            ),
            (
                "MainTests".to_string(),
                "src/test/java/MainTests.java".to_string()
            ),
        ],
        "JDT should list exactly the launchable forms: {entrypoints}"
    );

    // Editor Run markers ask the same JDT service per file. The Java 25
    // instance form must carry a marker on its `main` line, while a private
    // `main` the JVM cannot launch must not.
    let main_methods_for = |relative: &str| {
        let uri = url::Url::from_file_path(canonical_workspace.join(relative))
            .expect("fixture file converts to a URI")
            .to_string();
        let operation_id = engine.next_operation_id();
        session
            .request(
                SemanticRequest {
                    session_id: session.id.clone(),
                    operation_id: Some(operation_id.clone()),
                    operation: LspSemanticOperation::JavaMainMethods,
                    uri: Some(uri),
                    virtual_uri: None,
                    position: None,
                    new_name: None,
                    range: None,
                    diagnostics: Vec::new(),
                    completion_item: None,
                    code_action: None,
                    command: None,
                },
                operation_id.clone(),
            )
            .expect("main-method request is accepted");
        await_operation(&session, &operation_id, Duration::from_secs(60))
            .expect("JDT answers main-method discovery")
    };
    let instance = main_methods_for("src/main/java/demo/InstanceArgs.java");
    assert_eq!(
        instance["methods"][0]["mainClass"],
        json!("demo.InstanceArgs"),
        "{instance}"
    );
    assert_eq!(
        instance["methods"][0]["range"]["startLine"],
        json!(1),
        "{instance}"
    );
    let private = main_methods_for("src/main/java/demo/PrivateMain.java");
    assert_eq!(private["methods"], json!([]), "{private}");

    // Issue #769's form must also build and run, which requires JDT LS to
    // compile against the project's JDK 25 rather than its own runtime.
    let project_name = entrypoints["entries"]
        .as_array()
        .and_then(|entries| {
            entries
                .iter()
                .find(|entry| entry["mainClass"] == "demo.StaticNoArgs")
        })
        .and_then(|entry| entry["projectName"].as_str())
        .expect("the #769 entry should name its JDT project")
        .to_string();
    let build = execute_real_command(
        &engine,
        &session,
        json!({
            "command": "vscode.java.buildWorkspace",
            "arguments": [json!({
                "mainClass": "demo.StaticNoArgs",
                "projectName": project_name,
                "filePath": canonical_workspace
                    .join("src/main/java/demo/StaticNoArgs.java")
                    .to_string_lossy(),
                "isFullBuild": false
            }).to_string()]
        }),
        Duration::from_secs(300),
    )
    .unwrap_or_else(|error| panic!("the Java 25 project should build: {error}"));
    assert_eq!(build["value"], json!(1), "unexpected build result: {build}");
    let paths = execute_real_command(
        &engine,
        &session,
        json!({
            "command": "vscode.java.resolveClasspath",
            "arguments": ["demo.StaticNoArgs", project_name]
        }),
        Duration::from_secs(60),
    )
    .unwrap_or_else(|error| panic!("the runtime classpath should resolve: {error}"));
    // Issue #379: scope omission must keep production launches free of test
    // output, while a default-package test Main gets custom output and test-only
    // dependencies from m2e/JDT instead of a guessed target/test-classes path.
    let test_paths = execute_real_command(
        &engine,
        &session,
        json!({
            "command": "vscode.java.resolveClasspath",
            "arguments": ["MainTests", project_name]
        }),
        Duration::from_secs(60),
    )
    .unwrap_or_else(|error| panic!("the test Main classpath should resolve: {error}"));
    let test_entries = test_paths["value"][1].as_array().expect("test classpaths");
    let has_test_output = |entries: &[Value]| {
        entries.iter().any(|entry| {
            entry.as_str().is_some_and(|path| {
                path.replace('\\', "/")
                    .ends_with("/target/test-main-output")
            })
        })
    };
    assert!(has_test_output(test_entries), "{test_paths}");
    assert!(
        test_entries.iter().any(|entry| entry
            .as_str()
            .is_some_and(|path| path.contains("junit-jupiter-api"))),
        "{test_paths}"
    );
    assert!(
        !has_test_output(paths["value"][1].as_array().expect("main classpaths")),
        "{paths}"
    );
    assert!(
        canonical_workspace
            .join("target/test-main-output/MainTests.class")
            .is_file(),
        "the test Main should have been compiled"
    );
    // `resolveClasspath` answers `[modulePaths, classPaths]`.
    let class_path = paths["value"][1]
        .as_array()
        .map(|entries| {
            entries
                .iter()
                .filter_map(Value::as_str)
                .collect::<Vec<_>>()
                .join(if cfg!(windows) { ";" } else { ":" })
        })
        .filter(|class_path| !class_path.is_empty())
        .unwrap_or_else(|| panic!("no runtime classpath in {paths}"));
    let executable =
        toolchain
            .project_jdk
            .join("bin")
            .join(if cfg!(windows) { "java.exe" } else { "java" });
    let test_class_path = test_entries
        .iter()
        .filter_map(Value::as_str)
        .collect::<Vec<_>>()
        .join(if cfg!(windows) { ";" } else { ":" });
    for (main_class, paths, expected_output) in [
        ("demo.StaticNoArgs", class_path.as_str(), "static-noargs"),
        ("MainTests", test_class_path.as_str(), "test-main"),
    ] {
        let output = std::process::Command::new(&executable)
            .arg("-cp")
            .arg(paths)
            .arg(main_class)
            .output()
            .expect("the project JDK should start");
        assert!(
            output.status.success(),
            "{main_class} failed: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert_eq!(
            String::from_utf8_lossy(&output.stdout).trim(),
            expected_output
        );
    }

    // No local annotation or file-name rule can produce these answers: JDT
    // resolves the custom meta-annotation and the inherited JUnit method.
    for (relative, expected_class, expected_method) in [
        (
            "src/test/java/demo/OddlyNamedSpec.java",
            "demo.OddlyNamedSpec",
            Some("demo.OddlyNamedSpec#composedAnnotation()"),
        ),
        (
            "src/test/java/demo/InheritedSuite.java",
            "demo.InheritedSuite",
            None,
        ),
    ] {
        let uri = url::Url::from_file_path(canonical_workspace.join(relative))
            .expect("test source converts to a file URI")
            .to_string();
        let result = request_real_test_items(&engine, &session, uri)
            .unwrap_or_else(|error| panic!("test discovery failed for {relative}: {error}"));
        let classes = result["items"]
            .as_array()
            .unwrap_or_else(|| panic!("Java Test returned no item list for {relative}: {result}"));
        let class = classes
            .iter()
            .find(|item| item["fullName"] == expected_class)
            .unwrap_or_else(|| panic!("Java Test did not find {expected_class}: {result}"));
        if let Some(expected_method) = expected_method {
            let method = class["children"]
                .as_array()
                .and_then(|children| {
                    children
                        .iter()
                        .find(|item| item["fullName"] == expected_method)
                })
                .unwrap_or_else(|| {
                    panic!("Java Test did not resolve the composed annotation: {result}")
                });
            let range = &method["range"];
            assert!(
                range["startLine"].as_i64().is_some_and(|line| line >= 0)
                    && range["startUtf16Column"]
                        .as_i64()
                        .is_some_and(|column| column >= 0)
                    && range["endLine"].as_i64().is_some_and(|line| line >= 0)
                    && range["endUtf16Column"]
                        .as_i64()
                        .is_some_and(|column| column >= 0),
                "Java Test returned no usable method range: {result}"
            );
        }
    }

    // The packaged installation is the release baseline for delta updates:
    // after import, build, and classpath resolution JDT LS must not have
    // added, removed, or resized a single file in it. Equinox's framework
    // state has to be in the cache's configuration area instead.
    assert_eq!(installation_listing(&toolchain.root), installation_before);
    let configuration_areas = std::fs::read_dir(root.join("cache").join("jdtls-configuration"))
        .expect("the cache should hold the Equinox configuration area")
        .filter_map(Result::ok)
        .map(|entry| entry.path().join("configuration"))
        .collect::<Vec<_>>();
    assert!(
        configuration_areas
            .iter()
            .any(|area| area.join("org.eclipse.osgi").is_dir()),
        "Equinox did not write its state to the cache: {configuration_areas:?}"
    );

    let Some(maven_executable) = toolchain.maven.as_deref() else {
        return;
    };
    let mut maven = std::process::Command::new(maven_executable);
    maven
        .current_dir(&canonical_workspace)
        .env("JAVA_HOME", &toolchain.project_jdk)
        .args([
            "--batch-mode",
            "--no-transfer-progress",
            "-Dtest=OddlyNamedSpec,InheritedSuite",
            "test",
        ]);
    let test_output = maven.output().expect("Maven should start");
    assert!(
        test_output.status.success(),
        "discovered Java tests failed:\n{}\n{}",
        String::from_utf8_lossy(&test_output.stdout),
        String::from_utf8_lossy(&test_output.stderr)
    );
    assert!(
        canonical_workspace.join("target/composed-ran").is_file(),
        "the custom composed-annotation test did not run"
    );
    assert!(
        canonical_workspace.join("target/inherited-ran").is_file(),
        "the inherited test did not run"
    );
}

/// Regression for a workspace opened through a symbolic link, which is how
/// macOS exposes `/tmp` and `/var`. JDT imports the project at its resolved
/// location, so an entry-point scope naming the link matched no project and
/// Run reported that the open file had no `main` method.
#[cfg(unix)]
#[test]
fn real_jdtls_lists_entrypoints_and_classpaths_behind_a_symbolic_link() {
    let Some(toolchain) = real_jdt_toolchain() else {
        return;
    };
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("system clock should follow the Unix epoch")
        .as_nanos();
    let root = std::env::temp_dir().join(format!(
        "lithe-real-jdt-symlink-{}-{stamp}",
        std::process::id()
    ));
    let resolved_workspace = root.join("resolved");
    let source = "src/main/java/demo/ClassicMain.java";
    let source_path = resolved_workspace.join(source);
    std::fs::create_dir_all(source_path.parent().expect("source parent"))
        .expect("fixture source directory");
    std::fs::write(
        &source_path,
        "package demo;\npublic class ClassicMain { public static void main(String[] args) { } }\n",
    )
    .expect("fixture source");
    std::fs::write(resolved_workspace.join("pom.xml"), JAVA_25_POM).expect("fixture pom");
    let workspace = root.join("link");
    std::os::unix::fs::symlink(&resolved_workspace, &workspace).expect("workspace link");
    let root_uri = url::Url::from_directory_path(&workspace)
        .expect("workspace converts to a file URI")
        .to_string();

    let engine = LspEngine::new();
    let started = engine
        .start_server(real_start_request(&toolchain, &root, &workspace, &root_uri))
        .expect("real JDTLS should start");
    let _cleanup = RealSmokeCleanup {
        engine: &engine,
        session_id: started.session_id.clone(),
        root: root.clone(),
    };
    let session = engine
        .session(&started.session_id)
        .expect("real JDTLS session should be registered");
    await_real_smoke_ready(&session).unwrap_or_else(|error| panic!("{error}"));

    let entrypoints = await_real_entrypoints(&engine, &session, 1);
    assert_eq!(
        entrypoints["entries"][0]["sourcePath"],
        json!(source),
        "{entrypoints}"
    );
    assert_eq!(entrypoints["diagnostics"], json!([]), "{entrypoints}");

    // JDT publishes diagnostics under the resolved path; they must still reach
    // the document the host opened through the link.
    let opened_uri = url::Url::from_file_path(workspace.join(source))
        .expect("linked source converts to a file URI")
        .to_string();
    session
        .sync_document(SyncDocumentRequest {
            session_id: session.id.clone(),
            uri: opened_uri.clone(),
            language_id: "java".to_string(),
            text: "package demo;\npublic class ClassicMain { public static void main(String[] args) { String broken = 1; } }\n".to_string(),
            content_changes: Vec::new(),
        })
        .expect("the linked source should open");
    let diagnostics_deadline = Instant::now() + Duration::from_secs(60);
    let reported = loop {
        let remaining = diagnostics_deadline.saturating_duration_since(Instant::now());
        assert!(
            !remaining.is_zero(),
            "JDT diagnostics did not reach the document opened through the link"
        );
        let events = session
            .wait_events(remaining)
            .expect("JDT events should be readable");
        if let Some(event) = events.into_iter().find(|event| {
            event.kind == "diagnostics"
                && event
                    .diagnostics
                    .as_ref()
                    .is_some_and(|list| !list.is_empty())
        }) {
            break event;
        }
    };
    assert_eq!(reported.uri.as_deref(), Some(opened_uri.as_str()));

    // The dependency projection reads each project's runtime classpath. JDT LS
    // deserializes the options from JSON text only; a JSON object leaves them
    // null and the command fails inside the server.
    let projects = execute_real_command(
        &engine,
        &session,
        json!({ "command": "java.project.getAll", "arguments": [] }),
        Duration::from_secs(60),
    )
    .unwrap_or_else(|error| panic!("JDT should list its projects: {error}"));
    let project_uri = projects["value"]
        .as_array()
        .and_then(|projects| {
            projects
                .iter()
                .filter_map(Value::as_str)
                .find(|uri| !uri.contains("jdt.ls-java-project"))
        })
        .unwrap_or_else(|| panic!("no imported project in {projects}"))
        .to_string();
    let classpaths = execute_real_command(
        &engine,
        &session,
        json!({
            "command": "java.project.getClasspaths",
            "arguments": [project_uri, json!({ "scope": "runtime" }).to_string()]
        }),
        Duration::from_secs(60),
    )
    .unwrap_or_else(|error| panic!("the runtime classpath should resolve: {error}"));
    assert!(
        classpaths["value"]["classpaths"]
            .as_array()
            .is_some_and(|paths| !paths.is_empty()),
        "no runtime classpath in {classpaths}"
    );
}
