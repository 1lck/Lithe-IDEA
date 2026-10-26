//! Real Core plans and dependency decoders with a controlled native executor.
//! Fixtures live only in an owned temporary workspace; no tool is spawned.
use super::super::build_registry::*;
use super::super::build_resolver::WindowsBuildToolResolver;
use super::dependencies::*;
use super::operation::*;
use super::output::*;
use super::process::ModelOutputFile;
use serde_json::{json, Value};
use std::cell::RefCell;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

struct Core;
impl BuildCoreExecutor for Core {
    fn execute(&self, command: &str, payload: Value) -> Result<Value, String> {
        super::super::scan::core_execute(command, payload)
    }
}
struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let fixture =
            Self(std::env::temp_dir().join(format!("lithe dependencies {}", next_operation_id())));
        fixture.write("reactor/pom.xml", "<project><modelVersion>4.0.0</modelVersion><groupId>fixture.test</groupId><artifactId>root</artifactId><version>1</version><modules><module>app</module></modules></project>");
        fixture.write(
            "reactor/app/pom.xml",
            "<project><artifactId>app</artifactId><version>1</version></project>",
        );
        fixture.write("tools/mvn.exe", "placeholder");
        fixture
    }
    fn write(&self, relative: &str, text: &str) {
        let path = self.0.join(relative);
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();
        std::fs::write(path, text).unwrap();
    }
    fn path(&self) -> String {
        self.0.to_string_lossy().into_owned()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
struct Packages(BuildPackageInput);
impl BuildPackageSource for Packages {
    fn accepted_packages(&self) -> Vec<BuildPackageInput> {
        vec![self.0.clone()]
    }
    fn package(&self, id: &str) -> Option<BuildPackageInput> {
        (id == self.0.plugin_id).then(|| self.0.clone())
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
fn setup(fixture: &Fixture, stdout: bool) -> (BuildRegistry, Packages, BuildModelContext) {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../shared/contracts/plugins/v1/fixtures/build-host-integration.plugin.json");
    let mut manifest: Value =
        serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    manifest["buildSystems"][0]["invocation"]["runtimeDependencies"] = json!([]);
    if stdout {
        manifest["buildSystems"][0]["dependencies"] = json!({"source":"command","scopes":["workspace","project"],"arguments":["dependencies"],"output":"stdout","decoder":"litheDependencies","executesProjectCode":true,"mayUseNetwork":true});
    }
    let package = Packages(BuildPackageInput {
        plugin_id: manifest["id"].as_str().unwrap().into(),
        version: "0.1.0".into(),
        manifest,
        content_identity: "original".into(),
    });
    let mut registry = BuildRegistry::new();
    let view = registry
        .refresh(&Core, &package, &Options, "main", &fixture.path())
        .unwrap();
    let context = registry
        .model_context(
            "main",
            &fixture.path(),
            &package.0.plugin_id,
            "maven",
            "reactor",
        )
        .unwrap_or_else(|error| panic!("{error}: {}", serde_json::to_string(&view).unwrap()));
    (registry, package, context)
}
#[derive(Default)]
struct Sink(Mutex<Vec<Value>>);
impl BuildOutputSink for Sink {
    fn emit(&self, window: &str, event: Value) -> Result<(), String> {
        assert_eq!(window, "main");
        self.0.lock().unwrap().push(event);
        Ok(())
    }
}
fn operation(
    fixture: &Fixture,
    context: BuildModelContext,
    project: Option<String>,
    sink: Arc<Sink>,
) -> ModelOperation {
    let id = next_operation_id();
    let output = fixture
        .0
        .join("plugin-state")
        .join(format!("{id}.dependencies.json"));
    let (command, prepared) = plan(
        &Core,
        &context,
        &BuildDependenciesSelection {
            project_id: project,
        },
        &fixture.0,
        &fixture.0,
        &output,
        &id,
        "fingerprint".into(),
        sink,
    )
    .unwrap();
    let response = Core.execute("build.invocationPlan",json!({"manifest":context.package.manifest,"buildSystemID":"maven","request":{"root":"reactor","platform":"windows"}})).unwrap();
    core_ok(&response).unwrap();
    let directory =
        WindowsBuildToolResolver::instance_directory(&response["invocation"], &fixture.0).unwrap();
    let resolver = WindowsBuildToolResolver::with_environment(
        BTreeMap::from([(
            "PATH".into(),
            fixture.0.join("tools").to_string_lossy().into_owned(),
        )]),
        BTreeMap::new(),
    );
    let mut operation = ModelOperation::new(
        id,
        context,
        command,
        response["invocation"].clone(),
        resolver,
        output,
        directory,
    );
    operation.dependencies = Some(prepared);
    operation
}
struct Guard<'a> {
    operation: &'a ModelOperation,
    registry: Option<&'a BuildRegistry>,
}
impl ModelExecutionGuard for Guard<'_> {
    fn checkpoint(&self) -> Result<(), String> {
        if self.cancelled() {
            Err("plugin.build.cancelled".into())
        } else {
            Ok(())
        }
    }
    fn cancelled(&self) -> bool {
        self.operation.cancelled()
            || self
                .registry
                .is_some_and(|registry| !registry.context_is_current(&self.operation.context))
    }
}
type Callback<'a> = dyn FnMut(lithe_git_host::Stream, &[u8]) -> Result<(), String> + 'a;
struct Executor<F> {
    action: F,
    plans: RefCell<Vec<BuildProcessPlan>>,
}
impl<F: Fn(&BuildProcessPlan, &mut Callback<'_>) -> BuildRunProcessOutput> BuildProcessExecutor
    for Executor<F>
{
    fn run(
        &self,
        plan: &BuildProcessPlan,
        guard: &dyn ModelExecutionGuard,
    ) -> Result<BuildProcessOutput, String> {
        guard.checkpoint()?;
        self.plans.borrow_mut().push(plan.clone());
        assert_eq!(plan.arguments, ["--version"]);
        Ok(BuildProcessOutput {
            stdout: b"Apache Maven 3.9.9".to_vec(),
            stderr: vec![],
        })
    }
    fn run_command(
        &self,
        plan: &BuildProcessPlan,
        guard: &dyn ModelExecutionGuard,
        output: &mut Callback<'_>,
    ) -> BuildRunProcessOutput {
        guard.checkpoint().unwrap();
        self.plans.borrow_mut().push(plan.clone());
        (self.action)(plan, output)
    }
}
fn outcome(error: Option<&str>) -> BuildRunProcessOutput {
    BuildRunProcessOutput {
        exit_code: Some(if error.is_some() { 1 } else { 0 }),
        started: true,
        failure: error.map(str::to_string),
        started_at_millis: Some(1),
    }
}
fn executor<F: Fn(&BuildProcessPlan, &mut Callback<'_>) -> BuildRunProcessOutput>(
    action: F,
) -> Executor<F> {
    Executor {
        action,
        plans: RefCell::new(vec![]),
    }
}

#[test]
fn maven_output_file_plan_uses_exact_native_project_and_core_decoder() {
    let fixture = Fixture::new();
    let (_, _, context) = setup(&fixture, false);
    let sink = Arc::new(Sink::default());
    let project = context.model["projects"]
        .as_array()
        .unwrap()
        .iter()
        .find(|project| project["path"] == "reactor/app")
        .unwrap()["id"]
        .as_str()
        .unwrap()
        .to_string();
    let operation = operation(&fixture, context, Some(project), sink.clone());
    assert!(
        !operation.output_file.exists(),
        "prepare allocates no file and runs no probes"
    );
    let file = ModelOutputFile::create(&operation.output_file).unwrap();
    let executor = executor(|plan, output| {
        assert_eq!(
            plan.directory,
            fixture.0.join("reactor").canonicalize().unwrap()
        );
        assert!(plan.arguments.windows(2).any(|pair| pair == ["-pl", "app"]));
        assert!(plan
            .arguments
            .iter()
            .any(|arg| arg == "org.apache.maven.plugins:maven-dependency-plugin:3.8.1:tree"));
        std::fs::write(
            plan.output_file.as_ref().unwrap(),
            "fixture.test:app:jar:1\n\\- dep.test:library:jar:2:compile\n",
        )
        .unwrap();
        output(
            lithe_git_host::Stream::Stderr,
            b"download log is not dependency data\n",
        )
        .unwrap();
        outcome(None)
    });
    let (terminal, tree) = execute(
        &operation,
        &Core,
        &executor,
        &Guard {
            operation: &operation,
            registry: None,
        },
    )
    .unwrap();
    assert_eq!(terminal.kind, "succeeded");
    assert_eq!(tree.unwrap().nodes[0]["name"], "library");
    operation.complete_run(terminal, || Ok(())).unwrap();
    let plans = executor.plans.borrow();
    assert_eq!(plans[0].executable, plans[1].executable);
    assert_eq!(plans[0].environment, plans[1].environment);
    assert_eq!(sink.0.lock().unwrap().last().unwrap()["type"], "terminal");
    drop(file);
    assert!(!operation.output_file.exists());
}

#[test]
fn stdout_canonical_dependencies_are_decoded_only_after_successful_execution() {
    let fixture = Fixture::new();
    let (_, _, context) = setup(&fixture, true);
    let operation = operation(&fixture, context, None, Arc::new(Sink::default()));
    let executor = executor(|plan, output| {
        assert!(plan.output_file.is_none());
        output(lithe_git_host::Stream::Stdout,br#"{"format":"litheDependencies","version":1,"dependencies":[{"name":"library","children":[{"name":"transitive"}]}]}"#).unwrap();
        outcome(None)
    });
    let (terminal, tree) = execute(
        &operation,
        &Core,
        &executor,
        &Guard {
            operation: &operation,
            registry: None,
        },
    )
    .unwrap();
    assert_eq!(terminal.kind, "succeeded");
    assert_eq!(tree.unwrap().nodes[0]["children"][0]["name"], "transitive");
}

#[test]
fn pending_reviews_share_busy_and_cancellation_with_tasks_and_models() {
    let fixture = Fixture::new();
    let (_, _, context) = setup(&fixture, true);
    let sink = Arc::new(Sink::default());
    let operations = BuildOperations::default();
    let review = operations
        .insert(operation(&fixture, context.clone(), None, sink.clone()))
        .unwrap();
    let mut model = operation(&fixture, context.clone(), None, sink.clone());
    model.dependencies = None;
    assert!(operations.insert(model).is_err());
    assert!(operations
        .claim("workspace-other", &review.operation_id)
        .is_err());
    let pending = operations.get("main", &review.operation_id).unwrap();
    pending.cancel();
    pending.cancel();
    assert!(operations.claim("main", &review.operation_id).is_err());
    assert_eq!(sink.0.lock().unwrap().len(), 1);
    let review = operations
        .insert(operation(&fixture, context, None, sink))
        .unwrap();
    let running = operations.claim("main", &review.operation_id).unwrap();
    running.0.cancel();
    assert!(!running.0.finished());
    assert!(operations.claim("main", &review.operation_id).is_err());
    let owner = running.0.clone();
    drop(running);
    assert!(owner.finished());
}

#[test]
fn cleanup_failure_retains_the_same_owner_and_its_output_file_without_terminal() {
    let fixture = Fixture::new();
    let (_, _, context) = setup(&fixture, false);
    let sink = Arc::new(Sink::default());
    let operations = BuildOperations::default();
    let review = operations
        .insert(operation(&fixture, context.clone(), None, sink.clone()))
        .unwrap();
    let running = operations.claim("main", &review.operation_id).unwrap();
    let output = ModelOutputFile::create(&running.0.output_file).unwrap();
    let executor = executor(|_, _| outcome(Some("plugin.build.cleanupFailed")));
    assert_eq!(
        execute(
            &running.0,
            &Core,
            &executor,
            &Guard {
                operation: &running.0,
                registry: None
            }
        )
        .err()
        .as_deref(),
        Some("plugin.build.cleanupFailed")
    );
    running.0.retain_failed_cleanup(output);
    let owner = running.0.clone();
    drop(running);
    assert!(!owner.finished());
    assert!(owner.output_file.exists());
    assert!(sink.0.lock().unwrap().is_empty());
    assert!(operations
        .insert(operation(&fixture, context, None, sink))
        .is_err());
    drop(owner);
    drop(operations);
}

#[test]
fn cancelled_stream_drops_tail_and_never_decodes_a_tree() {
    let fixture = Fixture::new();
    let (_, _, context) = setup(&fixture, true);
    let sink = Arc::new(Sink::default());
    let operations = BuildOperations::default();
    let review = operations
        .insert(operation(&fixture, context, None, sink.clone()))
        .unwrap();
    let running = operations.claim("main", &review.operation_id).unwrap();
    let executor = executor(|_, output| {
        output(lithe_git_host::Stream::Stderr, b"before\n").unwrap();
        running.0.cancel();
        assert!(output(lithe_git_host::Stream::Stdout, b"late").is_err());
        outcome(Some("plugin.build.cancelled"))
    });
    let (terminal, tree) = execute(
        &running.0,
        &Core,
        &executor,
        &Guard {
            operation: &running.0,
            registry: None,
        },
    )
    .unwrap();
    assert_eq!(terminal.kind, "cancelled");
    assert!(tree.is_none());
    running.0.complete_run(terminal, || Ok(())).unwrap();
    assert_eq!(sink.0.lock().unwrap().len(), 2);
}

#[test]
fn registry_changes_before_confirmation_reject_without_executing() {
    for change in [
        "option",
        "workspace",
        "window",
        "plugin",
        "model",
        "replacement",
    ] {
        let fixture = Fixture::new();
        let (mut registry, packages, context) = setup(&fixture, true);
        let operation = operation(&fixture, context.clone(), None, Arc::new(Sink::default()));
        match change {
            "option" => {
                registry
                    .set_option(
                        &Core,
                        &packages,
                        &Options,
                        "main",
                        &fixture.path(),
                        &context.plugin_id,
                        "maven",
                        "reactor",
                        "offline",
                        Some(json!(true)),
                    )
                    .unwrap();
            }
            "workspace" => registry.close_workspace("main", &fixture.path()),
            "window" => registry.close_window("main"),
            "plugin" => registry.drop_plugin(&context.plugin_id),
            "model" => {
                let before = registry.model_fingerprint(&Core, &context).unwrap();
                registry
                    .apply_command_model(&Core, &context, context.model.clone(), &before)
                    .unwrap();
            }
            "replacement" => {
                let mut replacement = packages.0.clone();
                replacement.content_identity = "same-version:new-bytes".into();
                registry
                    .sync_check(
                        &Core,
                        &Packages(replacement),
                        "main",
                        &fixture.path(),
                        &context.plugin_id,
                        "maven",
                        "reactor",
                    )
                    .unwrap();
            }
            _ => unreachable!(),
        }
        let executor = executor(|_, _| panic!("stale review must never execute"));
        assert!(execute(
            &operation,
            &Core,
            &executor,
            &Guard {
                operation: &operation,
                registry: Some(&registry)
            }
        )
        .is_err());
        assert!(executor.plans.borrow().is_empty());
    }
}

#[test]
fn selection_and_provider_sources_cannot_inject_native_plan_fields() {
    for field in [
        "project",
        "root",
        "executable",
        "arguments",
        "environment",
        "outputFile",
        "permissions",
    ] {
        let mut input = json!({"projectId":null});
        input[field] = json!("untrusted");
        assert!(serde_json::from_value::<BuildDependenciesSelection>(input).is_err());
    }
    let fixture = Fixture::new();
    let (_, _, mut context) = setup(&fixture, true);
    let sink = Arc::new(Sink::default());
    let prepare = |context: &BuildModelContext, selection: BuildDependenciesSelection| {
        plan(
            &Core,
            context,
            &selection,
            &fixture.0,
            &fixture.0,
            &fixture.0.join("unused"),
            "review",
            "stamp".into(),
            sink.clone(),
        )
    };
    assert!(prepare(
        &context,
        BuildDependenciesSelection {
            project_id: Some("../forged".into())
        }
    )
    .is_err());
    context.model_stale = true;
    assert!(prepare(
        &context,
        BuildDependenciesSelection {
            project_id: context.model["projects"][0]["id"]
                .as_str()
                .map(str::to_string)
        }
    )
    .is_err());
    context.package.manifest["buildSystems"][0]["dependencies"] =
        json!({"source":"provider","scopes":["workspace"]});
    assert_eq!(
        prepare(&context, BuildDependenciesSelection { project_id: None })
            .err()
            .as_deref(),
        Some("plugin.build.unavailable")
    );
}

#[test]
fn malformed_output_and_unsuccessful_exit_never_return_a_dependency_tree() {
    for failure in [
        None,
        Some("plugin.build.timeout"),
        Some("plugin.build.outputLimit"),
        Some("plugin.build.processFailed"),
    ] {
        let fixture = Fixture::new();
        let (_, _, context) = setup(&fixture, false);
        let operation = operation(&fixture, context, None, Arc::new(Sink::default()));
        let output = ModelOutputFile::create(&operation.output_file).unwrap();
        let executor = executor(|plan, _| {
            std::fs::write(plan.output_file.as_ref().unwrap(), "not dependency data").unwrap();
            outcome(failure)
        });
        let (terminal, tree) = execute(
            &operation,
            &Core,
            &executor,
            &Guard {
                operation: &operation,
                registry: None,
            },
        )
        .unwrap();
        assert_eq!(terminal.kind, "failed");
        assert!(tree.is_none());
        drop(output);
        assert!(!operation.output_file.exists());
    }
}

#[test]
fn cancellation_winning_after_decode_prevents_success_publication() {
    let fixture = Fixture::new();
    let (_, _, context) = setup(&fixture, true);
    let sink = Arc::new(Sink::default());
    let operations = BuildOperations::default();
    let review = operations
        .insert(operation(&fixture, context, None, sink.clone()))
        .unwrap();
    let running = operations.claim("main", &review.operation_id).unwrap();
    let executor = executor(|_, output| {
        output(
            lithe_git_host::Stream::Stdout,
            br#"{"format":"litheDependencies","version":1,"dependencies":[{"name":"library"}]}"#,
        )
        .unwrap();
        outcome(None)
    });
    let (terminal, tree) = execute(
        &running.0,
        &Core,
        &executor,
        &Guard {
            operation: &running.0,
            registry: None,
        },
    )
    .unwrap();
    assert!(tree.is_some(), "dependency execution failed: {terminal:?}");
    running.0.cancel();
    let terminal = running.0.complete_run(terminal, || Ok(())).unwrap();
    assert_eq!(terminal.kind, "cancelled");
    assert_eq!(
        sink.0.lock().unwrap().last().unwrap()["terminal"]["kind"],
        "cancelled"
    );
}
