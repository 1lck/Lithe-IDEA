//! Real Core plans and decoders with a controlled executor. No test launches
//! developer tools, waits on a wall clock or depends on installed runtimes.

use super::super::build_registry::*;
use super::super::build_resolver::{RuntimeExecutableInput, WindowsBuildToolResolver};
use super::operation::*;
use super::process::{process_failure, ModelOutputFile, NativeBuildExecutor};
use serde_json::{json, Value};
use std::cell::{Cell, RefCell};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;

struct Core;
impl BuildCoreExecutor for Core {
    fn execute(&self, command: &str, payload: Value) -> Result<Value, String> {
        super::super::scan::core_execute(command, payload)
    }
}

struct Fixture {
    path: PathBuf,
}
impl Fixture {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!("lithe model tests {}", next_operation_id()));
        std::fs::create_dir_all(&path).expect("fixture");
        Self { path }
    }
    fn file(&self, relative: &str, contents: &str) -> PathBuf {
        let path = self.path.join(relative);
        std::fs::create_dir_all(path.parent().expect("parent")).expect("parent directory");
        std::fs::write(&path, contents).expect("fixture file");
        path
    }
    fn workspace(&self) -> String {
        self.path.to_string_lossy().into_owned()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.path);
    }
}

fn manifest(name: &str) -> Value {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../shared/contracts/plugins/v1/fixtures")
        .join(name);
    serde_json::from_str(&std::fs::read_to_string(path).expect("fixture JSON")).expect("manifest")
}

struct Packages(Mutex<BuildPackageInput>);
impl BuildPackageSource for Packages {
    fn accepted_packages(&self) -> Vec<BuildPackageInput> {
        vec![self.0.lock().expect("package").clone()]
    }
    fn package(&self, id: &str) -> Option<BuildPackageInput> {
        let package = self.0.lock().expect("package");
        (package.plugin_id == id).then(|| package.clone())
    }
}
struct Options;
impl BuildOptionsPersistence for Options {
    fn load(&self, _: &str) -> Result<StoredBuildOptions, String> {
        Ok(StoredBuildOptions::default())
    }
    fn save(&self, _: &str, _: &StoredBuildOptions) -> Result<(), String> {
        Ok(())
    }
}

fn context(
    fixture: &Fixture,
    declaration: &Value,
    system: &str,
) -> (BuildRegistry, Packages, BuildModelContext) {
    let packages = Packages(Mutex::new(BuildPackageInput {
        plugin_id: declaration["id"].as_str().expect("plugin ID").into(),
        version: "0.1.0".into(),
        manifest: declaration.clone(),
        content_identity: "approved-fixture-bytes".into(),
    }));
    let mut registry = BuildRegistry::new();
    registry
        .refresh(&Core, &packages, &Options, "main", &fixture.workspace())
        .expect("passive detection");
    let id = declaration["id"].as_str().expect("plugin ID");
    let context = registry
        .model_context("main", &fixture.workspace(), id, system, ".")
        .expect("model context");
    (registry, packages, context)
}

fn operation(fixture: &Fixture, context: BuildModelContext, settings: Value) -> ModelOperation {
    let id = next_operation_id();
    let output = fixture.path.join(format!("{id}.json"));
    let response = Core.execute("build.modelPlan", json!({"manifest": context.package.manifest,
        "buildSystemID": context.build_system_id, "request": {"root": context.root, "options": context.options,
            "pluginDirectory": fixture.path, "outputFile": output}})).expect("model plan");
    core_ok(&response).expect("valid model plan");
    let plan = serde_json::from_value(response["plan"].clone()).expect("command plan");
    let invocation = Core.execute("build.invocationPlan", json!({"manifest": context.package.manifest,
        "buildSystemID": context.build_system_id, "request": {"root": context.root, "platform": "windows", "settings": settings}})).expect("invocation");
    core_ok(&invocation).expect("valid invocation");
    let runtimes = BTreeMap::from([
        (
            "go".into(),
            RuntimeExecutableInput::discovered(fixture.file("tools/go.exe", "placeholder")),
        ),
        (
            "java".into(),
            RuntimeExecutableInput::discovered(fixture.file("tools/java.exe", "placeholder")),
        ),
    ]);
    let resolver = WindowsBuildToolResolver::with_environment(BTreeMap::new(), runtimes);
    let directory =
        WindowsBuildToolResolver::instance_directory(&invocation["invocation"], &fixture.path)
            .expect("cwd");
    ModelOperation::new(
        id,
        context,
        plan,
        invocation["invocation"].clone(),
        resolver,
        output,
        directory,
    )
}

struct Guard<F: Fn() -> Result<(), String>>(F);
impl<F: Fn() -> Result<(), String>> ModelExecutionGuard for Guard<F> {
    fn checkpoint(&self) -> Result<(), String> {
        self.0()
    }
    fn cancelled(&self) -> bool {
        self.0().is_err()
    }
}
struct Executor<F: Fn(&BuildProcessPlan) -> Result<BuildProcessOutput, String>> {
    action: F,
    plans: RefCell<Vec<BuildProcessPlan>>,
}
impl<F: Fn(&BuildProcessPlan) -> Result<BuildProcessOutput, String>> Executor<F> {
    fn new(action: F) -> Self {
        Self {
            action,
            plans: RefCell::new(Vec::new()),
        }
    }
}
impl<F: Fn(&BuildProcessPlan) -> Result<BuildProcessOutput, String>> BuildProcessExecutor
    for Executor<F>
{
    fn run(
        &self,
        plan: &BuildProcessPlan,
        guard: &dyn ModelExecutionGuard,
    ) -> Result<BuildProcessOutput, String> {
        guard.checkpoint()?;
        self.plans.borrow_mut().push(plan.clone());
        (self.action)(plan)
    }
}
fn output(stdout: impl Into<String>, stderr: &str) -> BuildProcessOutput {
    BuildProcessOutput {
        stdout: stdout.into().into_bytes(),
        stderr: stderr.as_bytes().to_vec(),
    }
}
fn go_output(fixture: &Fixture) -> String {
    json!({"Module":{"Path":"example.test/app", "Dir":fixture.workspace(), "GoVersion":"1.22"},
        "Name":"main", "ImportPath":"example.test/app", "Dir":fixture.workspace()})
    .to_string()
}

#[test]
fn command_stdout_uses_real_core_and_frozen_runtime_environment() {
    let fixture = Fixture::new();
    fixture.file("go.mod", "module example.test/app");
    let declaration = manifest("build-command-stdout.plugin.json");
    let (mut registry, _, context) = context(&fixture, &declaration, "go");
    let before = registry
        .model_fingerprint(&Core, &context)
        .expect("fingerprint");
    let operation = operation(&fixture, context, json!({}));
    let executor = Executor::new(|plan: &BuildProcessPlan| {
        Ok(if plan.arguments == ["version"] {
            output("go version go1.22.1 windows/amd64", "")
        } else {
            output(go_output(&fixture), "model warning")
        })
    });
    let loaded = execute_model(&operation, &Core, &executor, &Guard(|| Ok(()))).expect("model");
    assert_eq!(loaded.stderr, "model warning");
    assert_eq!(loaded.model["projects"][0]["name"], "example.test/app");
    let plans = executor.plans.borrow();
    assert_eq!(plans.len(), 2);
    assert_eq!(plans[0].executable, plans[1].executable);
    assert_eq!(plans[0].environment, plans[1].environment);
    assert_eq!(plans[1].arguments, ["list", "-json", "./..."]);
    assert_eq!(plans[0].timeout, PROBE_TIMEOUT);
    assert_eq!(plans[1].output_limit, MODEL_OUTPUT_LIMIT);
    let view = registry
        .apply_command_model(&Core, &operation.context, loaded.model, &before)
        .expect("publish");
    assert_eq!(
        view.instances[0]["model"]["projects"][0]["name"],
        "example.test/app"
    );
}

#[test]
fn command_output_file_uses_core_argv_and_cleans_its_owned_resource() {
    let fixture = Fixture::new();
    fixture.file("build.gradle", "");
    fixture.file("gradlew.bat", "placeholder");
    fixture.file("gradle/wrapper/gradle-wrapper.properties", "placeholder");
    let declaration = manifest("build-command-output-file.plugin.json");
    let (_, _, context) = context(&fixture, &declaration, "gradle");
    let operation = operation(&fixture, context, json!({}));
    assert!(operation.review().executes_project_code);
    let resource = ModelOutputFile::create(&operation.output_file).expect("fresh output");
    let executor = Executor::new(|plan: &BuildProcessPlan| {
        if plan.arguments == ["-version"] {
            return Ok(output("", "java version \"17.0.9\""));
        }
        let path = plan.output_file.as_ref().expect("Core output file channel");
        assert!(plan
            .arguments
            .contains(&format!("-PlitheModelOutput={}", path.display())));
        std::fs::write(
            path,
            json!({"format":"litheBuildModel","version":1,"projects":[{"path":".","name":"fixture"}]}).to_string(),
        )
        .expect("controlled output");
        Ok(output(
            "stdout is intentionally not model JSON",
            "gradle diagnostic",
        ))
    });
    let loaded =
        execute_model(&operation, &Core, &executor, &Guard(|| Ok(()))).expect("file model");
    assert_eq!(loaded.model["projects"][0]["name"], "fixture");
    assert_eq!(
        executor.plans.borrow().len(),
        2,
        "wrapper must never receive a version probe"
    );
    drop(resource);
    assert!(!operation.output_file.exists());
}

#[test]
fn configured_java_freezes_the_verified_jdk_home_for_probe_and_wrapper() {
    let fixture = Fixture::new();
    fixture.file("build.gradle", "");
    fixture.file("gradlew.bat", "placeholder");
    fixture.file("gradle/wrapper/gradle-wrapper.properties", "placeholder");
    let selected = fixture.file("selected jdk/bin/java.exe", "placeholder");
    let old = fixture.file("inherited jdk/bin/java.exe", "placeholder");
    let runtime = super::host::explicit_runtime_input("java", selected.clone())
        .expect("passive JDK validation");
    let selected_home = runtime.environment["JAVA_HOME"].clone();
    assert_eq!(
        crate::run::java_executable(Path::new(&selected_home))
            .expect("validated Java")
            .canonicalize()
            .expect("canonical selected Java"),
        selected.canonicalize().expect("canonical fixture Java")
    );
    assert!(super::host::explicit_runtime_input(
        "java",
        fixture.file("launchers/java.exe", "not a JDK layout")
    )
    .is_err());
    assert!(super::host::explicit_runtime_input(
        "java",
        fixture.file("selected jdk/bin/unrelated.exe", "another launcher")
    )
    .is_err());
    let declaration = manifest("build-command-output-file.plugin.json");
    let (_, _, context) = context(&fixture, &declaration, "gradle");
    let mut operation = operation(&fixture, context, json!({}));
    operation.resolver = WindowsBuildToolResolver::with_environment(
        BTreeMap::from([(
            "JAVA_HOME".into(),
            old.parent()
                .and_then(Path::parent)
                .expect("old JDK home")
                .to_string_lossy()
                .into_owned(),
        )]),
        BTreeMap::from([("java".into(), runtime)]),
    );
    let _output = ModelOutputFile::create(&operation.output_file).expect("owned model output");
    let executor = Executor::new(|plan: &BuildProcessPlan| {
        assert_eq!(plan.environment["JAVA_HOME"], selected_home);
        if plan.arguments == ["-version"] {
            assert_eq!(plan.executable, selected);
            Ok(output("", "java version \"17.0.9\""))
        } else {
            std::fs::write(
                plan.output_file.as_ref().expect("model output"),
                json!({"format":"litheBuildModel","version":1,"projects":[{"path":".","name":"fixture"}]}).to_string(),
            )
            .expect("controlled model");
            Ok(output("", "model warning"))
        }
    });
    let loaded = execute_model(&operation, &Core, &executor, &Guard(|| Ok(())))
        .expect("model uses the selected JDK");
    assert_eq!(loaded.model["projects"][0]["name"], "fixture");
    assert_eq!(executor.plans.borrow().len(), 2);
}

#[test]
fn process_failure_preserves_bounded_diagnostics_after_shared_redaction() {
    let error = process_failure(
        "unsuccessful exit",
        b"model output before failure",
        b"cannot resolve dependency; password=\"fixture secret\"; Authorization: Bearer fixture-token",
    );
    assert!(error.starts_with("plugin.build.processFailed:"));
    assert!(error.contains("cannot resolve dependency"));
    assert!(error.contains("stdout: model output before failure"));
    assert!(error.contains("stderr:"));
    assert!(error.contains("<redacted>"));
    assert!(!error.contains("fixture secret"));
    assert!(!error.contains("fixture-token"));

    // Long multibyte text and a quoted secret crossing the display boundary
    // cannot exceed the retained error budget or expose a partial secret.
    let stderr = format!("{} password=\"{}\"", "界".repeat(1300), "s".repeat(20_000));
    let long = process_failure("unsuccessful exit", &[], stderr.as_bytes());
    assert!(long.contains("[truncated]"));
    assert!(long.len() < 4300);
    assert!(!long.contains("ssss"));
}

#[test]
fn consent_context_switch_and_same_version_package_replacement_refuse_execution() {
    let fixture = Fixture::new();
    fixture.file("go.mod", "module example.test/app");
    let declaration = manifest("build-command-stdout.plugin.json");
    let (mut registry, packages, context) = context(&fixture, &declaration, "go");
    let operation = operation(&fixture, context, json!({}));
    registry.close_workspace("main", &fixture.workspace());
    let executor = Executor::new(|_: &BuildProcessPlan| panic!("stale consent must never execute"));
    let guard = Guard(|| {
        if registry.context_is_current(&operation.context) {
            Ok(())
        } else {
            Err("plugin.build.staleContext".into())
        }
    });
    assert!(execute_model(&operation, &Core, &executor, &guard).is_err());
    assert!(executor.plans.borrow().is_empty());
    packages.0.lock().expect("package").content_identity = "replaced-same-version".into();
    let guard = Guard(|| {
        if packages.package(&operation.context.plugin_id).as_ref()
            == Some(&operation.context.package)
        {
            Ok(())
        } else {
            Err("plugin.build.packageChanged".into())
        }
    });
    assert!(execute_model(&operation, &Core, &executor, &guard).is_err());
}

#[test]
fn cancellation_and_revocation_after_runtime_probe_never_start_the_model() {
    for code in [
        "plugin.build.cancelled",
        "plugin.build.staleContext",
        "plugin.build.packageChanged",
    ] {
        let fixture = Fixture::new();
        fixture.file("go.mod", "module example.test/app");
        let declaration = manifest("build-command-stdout.plugin.json");
        let (_, _, context) = context(&fixture, &declaration, "go");
        let operation = operation(&fixture, context, json!({}));
        let invalid = Cell::new(false);
        let guard = Guard(|| {
            if invalid.get() {
                Err(code.into())
            } else {
                Ok(())
            }
        });
        let executor = Executor::new(|_: &BuildProcessPlan| {
            invalid.set(true);
            Ok(output("go version go1.22.1 windows/amd64", ""))
        });
        assert!(execute_model(&operation, &Core, &executor, &guard).is_err());
        assert_eq!(executor.plans.borrow().len(), 1);
    }
}

#[test]
fn timeout_output_limit_and_cleanup_failures_cannot_publish_a_model() {
    for code in [
        "plugin.build.timeout",
        "plugin.build.outputLimit",
        "plugin.build.cleanupFailed",
    ] {
        let fixture = Fixture::new();
        fixture.file("go.mod", "module example.test/app");
        let declaration = manifest("build-command-stdout.plugin.json");
        let (_, _, context) = context(&fixture, &declaration, "go");
        let operation = operation(&fixture, context, json!({}));
        let executor = Executor::new(|plan: &BuildProcessPlan| {
            if plan.arguments == ["version"] {
                Ok(output("go version go1.22.1 windows/amd64", ""))
            } else {
                Err(code.into())
            }
        });
        let error = execute_model(&operation, &Core, &executor, &Guard(|| Ok(())))
            .err()
            .expect("failure");
        assert_eq!(error, code);
        assert!(!operation.output_file.exists());
    }
}

#[test]
fn operation_slot_stays_busy_until_execution_owner_drains_and_is_window_bound() {
    let fixture = Fixture::new();
    fixture.file("go.mod", "module example.test/app");
    let declaration = manifest("build-command-stdout.plugin.json");
    let (_, _, context) = context(&fixture, &declaration, "go");
    let operations = BuildOperations::default();
    let review = operations
        .insert(operation(&fixture, context.clone(), json!({})))
        .expect("prepare");
    assert!(operations
        .claim("other-window", &review.operation_id)
        .is_err());
    let running = operations
        .claim("main", &review.operation_id)
        .expect("claim");
    assert!(operations.claim("main", &review.operation_id).is_err());
    running.0.cancel();
    assert!(
        !running.0.finished(),
        "cancel is not process-tree completion"
    );
    assert!(operations
        .insert(operation(&fixture, context.clone(), json!({})))
        .is_err());
    assert!(running.0.publish(|| Ok(())).is_err());
    let control = running.0.clone();
    drop(running);
    assert!(control.finished());
    assert!(operations
        .insert(operation(&fixture, context, json!({})))
        .is_ok());
}

#[test]
fn explicit_path_with_spaces_is_frozen_and_invalid_path_never_falls_back() {
    let fixture = Fixture::new();
    fixture.file("go.mod", "module example.test/app");
    let mut declaration = manifest("build-command-stdout.plugin.json");
    declaration["requires"]["settings"] = json!(2);
    declaration["requires"]["executableResolution"] = json!(1);
    declaration["settings"] = manifest("build-tool-path.plugin.json")["settings"].clone();
    declaration["settings"][0]["page"]["buildSystemID"] = json!("go");
    declaration["buildSystems"][0]["invocation"]["executables"] = json!([
        {"kind":"setting", "settingID":"toolPath"}, {"kind":"runtime", "runtime":"go"}
    ]);
    let (_, _, context) = context(&fixture, &declaration, "go");
    let tool = fixture.file("custom tools/build.exe", "placeholder");
    for configured in [tool.clone(), fixture.path.join("missing tool.exe")] {
        let operation = operation(&fixture, context.clone(), json!({"toolPath":configured}));
        let executor = Executor::new(|plan: &BuildProcessPlan| {
            Ok(if plan.arguments == ["version"] {
                output("go version go1.22.1 windows/amd64", "")
            } else {
                output(go_output(&fixture), "")
            })
        });
        let result = execute_model(&operation, &Core, &executor, &Guard(|| Ok(())));
        if configured == tool {
            assert!(result.is_ok());
            assert_eq!(
                executor
                    .plans
                    .borrow()
                    .last()
                    .expect("model process")
                    .executable,
                tool
            );
        } else {
            assert!(result.is_err());
            assert_eq!(
                executor.plans.borrow().len(),
                1,
                "only the required runtime was probed"
            );
        }
    }
}

#[test]
fn native_executor_checks_cancellation_before_process_start() {
    let plan = BuildProcessPlan {
        executable: PathBuf::from("must-never-run"),
        arguments: vec![],
        environment: BTreeMap::new(),
        directory: PathBuf::new(),
        timeout: PROBE_TIMEOUT,
        output_limit: PROBE_OUTPUT_LIMIT,
        output_file: None,
    };
    assert_eq!(
        NativeBuildExecutor
            .run(&plan, &Guard(|| Err("plugin.build.cancelled".into())))
            .err()
            .as_deref(),
        Some("plugin.build.cancelled")
    );
}

#[test]
fn cleanup_failure_wins_over_concurrent_revoke_and_keeps_the_slot_owned() {
    let fixture = Fixture::new();
    fixture.file("go.mod", "module example.test/app");
    let declaration = manifest("build-command-stdout.plugin.json");
    let (_, _, context) = context(&fixture, &declaration, "go");
    let operations = BuildOperations::default();
    let review = operations
        .insert(operation(&fixture, context.clone(), json!({})))
        .expect("prepare");
    let running = operations
        .claim("main", &review.operation_id)
        .expect("claim");
    let revoked = Cell::new(false);
    let executor = Executor::new(|_: &BuildProcessPlan| {
        revoked.set(true);
        Err("plugin.build.cleanupFailed".into())
    });
    let guard = Guard(|| {
        if revoked.get() {
            Err("plugin.build.cancelled".into())
        } else {
            Ok(())
        }
    });
    assert_eq!(
        execute_model(&running.0, &Core, &executor, &guard)
            .err()
            .as_deref(),
        Some("plugin.build.cleanupFailed")
    );
    running.0.retain_failed_cleanup(());
    let control = running.0.clone();
    drop(running);
    assert!(!control.finished());
    assert!(operations
        .insert(operation(&fixture, context, json!({})))
        .is_err());
}

#[test]
fn cancelled_operation_refuses_a_native_start_permit() {
    let fixture = Fixture::new();
    fixture.file("go.mod", "module example.test/app");
    let declaration = manifest("build-command-stdout.plugin.json");
    let (_, _, context) = context(&fixture, &declaration, "go");
    let operation = operation(&fixture, context, json!({}));
    drop(operation.start_permit().expect("live permit"));
    operation.cancel();
    assert!(operation.start_permit().is_err());
}

#[test]
fn redetection_and_close_reject_late_command_model_publication() {
    let fixture = Fixture::new();
    fixture.file("go.mod", "module example.test/app");
    let declaration = manifest("build-command-stdout.plugin.json");
    let (mut registry, packages, context) = context(&fixture, &declaration, "go");
    registry
        .refresh(&Core, &packages, &Options, "main", &fixture.workspace())
        .expect("redetect");
    assert!(!registry.context_is_current(&context));
    assert!(registry
        .apply_command_model(&Core, &context, json!({}), "old-fingerprint")
        .is_err());
    let current = registry
        .model_context("main", &fixture.workspace(), &context.plugin_id, "go", ".")
        .expect("current");
    registry.close_window("main");
    assert!(!registry.context_is_current(&current));
}
