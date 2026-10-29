//! Real Core task/test plans and output decoders with a controllable process
//! owner. No test starts a developer tool or waits for real time.

use super::super::build_registry::*;
use super::super::build_resolver::WindowsBuildToolResolver;
use super::operation::*;
use super::output::*;
use super::process::ProcessStart;
use super::run::*;
use serde_json::{json, Value};
use std::cell::{Cell, RefCell};
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, UNIX_EPOCH};

const RUN_START: u64 = 1_700_000_000_000;
struct Core;
impl BuildCoreExecutor for Core {
    fn execute(&self, command: &str, payload: Value) -> Result<Value, String> {
        super::super::scan::core_execute(command, payload)
    }
}
struct Fixture {
    root: PathBuf,
}
impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!("lithe run tests {}", next_operation_id()));
        std::fs::create_dir_all(&root).expect("fixture");
        let fixture = Self { root };
        fixture.file(
            "Cargo.toml",
            "[package]\nname=\"fixture\"\nversion=\"0.1.0\"\nedition=\"2021\"\n",
        );
        fixture.file("src/main.rs", "fn main() {}\n");
        fixture.file("tools/cargo.exe", "placeholder");
        fixture
    }
    fn file(&self, relative: &str, text: &str) -> PathBuf {
        let path = self.root.join(relative);
        std::fs::create_dir_all(path.parent().expect("parent")).expect("directory");
        std::fs::write(&path, text).expect("file");
        path
    }
    fn path(&self) -> String {
        self.root.to_string_lossy().into_owned()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}
fn manifest() -> Value {
    let path = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../../../shared/contracts/plugins/v1/fixtures/build-static-file.plugin.json");
    serde_json::from_str(&std::fs::read_to_string(path).expect("fixture manifest")).expect("JSON")
}
struct Package(BuildPackageInput);
impl BuildPackageSource for Package {
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
fn registry(
    fixture: &Fixture,
    manifest: Value,
    window: &str,
) -> (BuildRegistry, Package, BuildModelContext) {
    let package = Package(BuildPackageInput {
        plugin_id: manifest["id"].as_str().expect("ID").into(),
        version: "0.1.0".into(),
        manifest,
        content_identity: "frozen-bytes".into(),
    });
    let mut registry = BuildRegistry::new();
    let detected = registry
        .refresh(&Core, &package, &Options, window, &fixture.path())
        .expect("passive detect");
    let context = registry
        .model_context(window, &fixture.path(), &package.0.plugin_id, "cargo", ".")
        .unwrap_or_else(|error| {
            panic!(
                "context: {error}; detection: {}",
                serde_json::to_string(&detected).expect("detection diagnostic")
            )
        });
    (registry, package, context)
}
#[derive(Default)]
struct Sink(Mutex<Vec<(String, Value)>>);
impl BuildOutputSink for Sink {
    fn emit(&self, window: &str, event: Value) -> Result<(), String> {
        self.0.lock().expect("events").push((window.into(), event));
        Ok(())
    }
}
fn selection(context: &BuildModelContext, kind: BuildRunKind) -> BuildRunSelection {
    BuildRunSelection {
        task_id: (kind == BuildRunKind::Task).then(|| "build".into()),
        kind,
        project_id: context.model["projects"][0]["id"]
            .as_str()
            .map(str::to_string),
        target_id: None,
        model_task_id: None,
        suite: None,
        case: None,
        user_arguments: vec![],
    }
}
fn operation(
    fixture: &Fixture,
    context: BuildModelContext,
    selection: &BuildRunSelection,
    sink: Arc<Sink>,
) -> ModelOperation {
    let id = next_operation_id();
    let run = prepare_run_plan(
        &Core,
        &context,
        selection,
        &fixture.root,
        &fixture.root,
        &id,
        sink,
    )
    .expect("Core task/test plan");
    let response=Core.execute("build.invocationPlan",json!({"manifest":context.package.manifest,"buildSystemID":"cargo","request":{"root":".","platform":"windows"}})).expect("invocation");
    core_ok(&response).expect("valid invocation");
    let resolver = WindowsBuildToolResolver::with_environment(
        BTreeMap::from([(
            "PATH".into(),
            fixture.root.join("tools").to_string_lossy().into_owned(),
        )]),
        BTreeMap::new(),
    );
    let plan = ModelCommandPlan {
        arguments: run.plan.arguments.clone(),
        environment: run.plan.environment.clone(),
        working_directory: ".".into(),
        output: "stdout".into(),
        executes_project_code: true,
        may_use_network: true,
    };
    let cwd = WindowsBuildToolResolver::instance_directory(&response["invocation"], &fixture.root)
        .expect("cwd");
    let mut operation = ModelOperation::new(
        id,
        context,
        plan,
        response["invocation"].clone(),
        resolver,
        PathBuf::new(),
        cwd,
    );
    operation.run = Some(run);
    operation
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
type OutputCallback<'a> = dyn FnMut(lithe_git_host::Stream, &[u8]) -> Result<(), String> + 'a;
struct Executor<F: Fn(&BuildProcessPlan, &mut OutputCallback<'_>) -> BuildRunProcessOutput> {
    action: F,
    plans: RefCell<Vec<BuildProcessPlan>>,
}
impl<F: Fn(&BuildProcessPlan, &mut OutputCallback<'_>) -> BuildRunProcessOutput>
    BuildProcessExecutor for Executor<F>
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
            stdout: b"cargo 1.80.1".to_vec(),
            stderr: vec![],
        })
    }
    fn run_command(
        &self,
        plan: &BuildProcessPlan,
        guard: &dyn ModelExecutionGuard,
        output: &mut OutputCallback<'_>,
    ) -> BuildRunProcessOutput {
        if let Err(error) = guard.checkpoint() {
            return result(None, Some(&error), false);
        }
        self.plans.borrow_mut().push(plan.clone());
        (self.action)(plan, output)
    }
}
fn executor<F: Fn(&BuildProcessPlan, &mut OutputCallback<'_>) -> BuildRunProcessOutput>(
    action: F,
) -> Executor<F> {
    Executor {
        action,
        plans: RefCell::new(vec![]),
    }
}
fn result(code: Option<i32>, failure: Option<&str>, started: bool) -> BuildRunProcessOutput {
    BuildRunProcessOutput {
        exit_code: code,
        started,
        failure: failure.map(str::to_string),
        started_at_millis: started.then_some(RUN_START),
    }
}
fn finish(operation: &ModelOperation, terminal: &BuildRunTerminal) {
    operation
        .complete_run(terminal.clone(), || Ok(()))
        .expect("terminal");
}

#[test]
fn successful_task_uses_core_argv_same_environment_and_ordered_window_events() {
    let fixture = Fixture::new();
    let (_, _, context) = registry(&fixture, manifest(), "main");
    let sink = Arc::new(Sink::default());
    let operation = operation(
        &fixture,
        context.clone(),
        &selection(&context, BuildRunKind::Task),
        sink.clone(),
    );
    assert!(
        sink.0.lock().expect("events").is_empty(),
        "prepare never runs/probes"
    );
    let executor = executor(|plan, output| {
        assert_eq!(plan.arguments, ["build", "--message-format=short"]);
        output(lithe_git_host::Stream::Stdout, b"compiling\n").expect("stdout");
        output(
            lithe_git_host::Stream::Stderr,
            b"src/main.rs:2:3: warning: fixture\n",
        )
        .expect("stderr");
        result(Some(0), None, true)
    });
    let terminal = execute_run(&operation, &Core, &executor, &Guard(|| Ok(()))).expect("run");
    finish(&operation, &terminal);
    finish(&operation, &terminal);
    assert_eq!(terminal.kind, "succeeded");
    let plans = executor.plans.borrow();
    assert_eq!(plans.len(), 2);
    assert_eq!(plans[0].environment, plans[1].environment);
    assert_eq!(plans[0].executable, plans[1].executable);
    assert!(plans[1].executable.is_absolute());
    let events = sink.0.lock().expect("events");
    assert_eq!(events.len(), 4);
    assert_eq!(
        events
            .iter()
            .map(|(_, e)| e["type"].as_str().expect("type"))
            .collect::<Vec<_>>(),
        ["chunk", "chunk", "diagnostics", "terminal"]
    );
    for (window, event) in events.iter() {
        assert_eq!(window, "main");
        assert_eq!(event["operationId"], operation.id);
        assert_eq!(event["pluginId"], context.plugin_id);
        assert_eq!(event["buildSystemId"], "cargo");
        assert_eq!(event["workspaceRoot"], fixture.path());
        assert_eq!(event["root"], ".");
        assert_eq!(event["generation"], context.generation);
    }
    assert_eq!(events[2].1["diagnostics"][0]["path"], "src/main.rs");
    assert_eq!(events[2].1["diagnostics"][0]["line"], 2);
    assert!(operation
        .run
        .as_ref()
        .expect("run")
        .events
        .chunk("stdout", "late")
        .is_err());
}

#[test]
fn unsuccessful_task_retains_output_and_core_diagnostics_before_terminal() {
    let fixture = Fixture::new();
    let (_, _, context) = registry(&fixture, manifest(), "main");
    let sink = Arc::new(Sink::default());
    let operation = operation(
        &fixture,
        context.clone(),
        &selection(&context, BuildRunKind::Task),
        sink.clone(),
    );
    let executor = executor(|_, output| {
        output(
            lithe_git_host::Stream::Stderr,
            b"src/main.rs:7:2: error: compile failed\n",
        )
        .expect("output");
        result(Some(101), None, true)
    });
    let terminal =
        execute_run(&operation, &Core, &executor, &Guard(|| Ok(()))).expect("drained failure");
    finish(&operation, &terminal);
    assert_eq!(terminal.kind, "failed");
    assert_eq!(terminal.exit_code, Some(101));
    let events = sink.0.lock().expect("events");
    assert_eq!(events[1].1["diagnostics"][0]["severity"], "error");
    assert_eq!(events.last().expect("terminal").1["type"], "terminal");
}

#[test]
fn test_reports_are_decoded_by_core_and_older_reports_are_excluded() {
    let fixture = Fixture::new();
    let mut declaration = manifest();
    declaration["buildSystems"][0]["test"]["results"] =
        json!({"decoder":"junitXml","reports":["reports/*.xml"]});
    let (_, _, context) = registry(&fixture, declaration, "main");
    let sink = Arc::new(Sink::default());
    let operation = operation(
        &fixture,
        context.clone(),
        &selection(&context, BuildRunKind::Test),
        sink.clone(),
    );
    let executor = executor(|_, output| {
        for (name, time, status) in [
            ("old", RUN_START - 1000, "<failure message=\"old\"/>"),
            ("current", RUN_START + 1000, "<failure message=\"new\"/>"),
        ] {
            let path=fixture.file(&format!("reports/{name}.xml"),&format!("<testsuite name=\"suite\"><testcase name=\"{name}\" classname=\"suite\">{status}</testcase></testsuite>"));
            std::fs::OpenOptions::new()
                .write(true)
                .open(path)
                .expect("report")
                .set_modified(UNIX_EPOCH + Duration::from_millis(time))
                .expect("controlled report clock");
        }
        output(lithe_git_host::Stream::Stdout, b"tests finished\n").expect("output");
        result(Some(0), None, true)
    });
    let terminal =
        execute_run(&operation, &Core, &executor, &Guard(|| Ok(()))).expect("decoded tests");
    finish(&operation, &terminal);
    assert_eq!(
        terminal.kind, "failed",
        "test failures override a zero process exit"
    );
    let events = sink.0.lock().expect("events");
    let results = events
        .iter()
        .find(|(_, event)| event["type"] == "testResults")
        .expect("results");
    assert_eq!(results.1["results"]["summary"]["total"], 1);
    assert_eq!(results.1["results"]["tests"][0]["case"], "current");
}

#[test]
fn a_report_written_before_the_started_hook_belongs_to_the_current_run() {
    let fixture = Fixture::new();
    let mut declaration = manifest();
    declaration["buildSystems"][0]["test"]["results"] =
        json!({"decoder":"junitXml","reports":["reports/*.xml"]});
    let (_, _, context) = registry(&fixture, declaration, "main");
    let sink = Arc::new(Sink::default());
    let operation = operation(
        &fixture,
        context.clone(),
        &selection(&context, BuildRunKind::Test),
        sink.clone(),
    );
    let executor = executor(|_, _| {
        let clock = Cell::new(RUN_START);
        let start = ProcessStart::capture(|| Some(clock.get()));
        assert!(!start.started());
        assert_eq!(start.started_at_millis(), None, "no spawn, no report time");
        // The child writes before its native owner gets the started callback.
        // Advance a controlled clock instead of relying on scheduler timing.
        let report = fixture.file(
            "reports/fast.xml",
            "<testsuite><testcase name=\"fast\"><failure message=\"current failure\"/></testcase></testsuite>",
        );
        std::fs::OpenOptions::new()
            .write(true)
            .open(report)
            .expect("report")
            .set_modified(UNIX_EPOCH + Duration::from_millis(clock.get()))
            .expect("controlled report clock");
        clock.set(RUN_START + 1000);
        start.mark_started();
        assert_eq!(start.started_at_millis(), Some(RUN_START));
        BuildRunProcessOutput {
            exit_code: Some(0),
            started: start.started(),
            failure: None,
            started_at_millis: start.started_at_millis(),
        }
    });
    let terminal = execute_run(&operation, &Core, &executor, &Guard(|| Ok(())))
        .expect("decode the immediate report");
    assert_eq!(
        terminal.kind, "failed",
        "the early failure cannot disappear"
    );
    let events = sink.0.lock().expect("events");
    let results = events
        .iter()
        .find(|(_, event)| event["type"] == "testResults")
        .expect("results");
    assert_eq!(results.1["results"]["summary"]["total"], 1);
    assert_eq!(results.1["results"]["summary"]["failed"], 1);
}

#[test]
fn workspace_reports_and_model_selections_require_a_current_declared_model() {
    let fixture = Fixture::new();
    let mut declaration = manifest();
    declaration["buildSystems"][0]["test"]["scopes"] = json!(["workspace", "project", "target"]);
    declaration["buildSystems"][0]["tasks"][0]["scopes"] = json!(["workspace", "project"]);
    declaration["buildSystems"][0]["test"]["results"] =
        json!({"decoder":"junitXml","reports":["reports/*.xml"]});
    let (_, _, static_context) = registry(&fixture, declaration.clone(), "main");
    let mut selected = selection(&static_context, BuildRunKind::Test);
    selected.project_id = None;
    let prepare = |context: &BuildModelContext, selected: &BuildRunSelection| {
        prepare_run_plan(
            &Core,
            context,
            selected,
            &fixture.root,
            &fixture.root,
            "model-validity",
            Arc::new(Sink::default()),
        )
    };
    assert!(
        prepare(&static_context, &selected).is_ok(),
        "fresh static model"
    );

    declaration["buildSystems"][0]["model"] = json!({
        "source":"command", "arguments":["metadata"], "decoder":"litheBuildModel",
        "executesProjectCode":false, "mayUseNetwork":false,
    });
    let (mut registry, package, missing) = registry(&fixture, declaration, "main");
    assert!(
        missing.model.is_null(),
        "detection does not execute the model"
    );
    assert_eq!(
        prepare(&missing, &selected).err().as_deref(),
        Some("plugin.build.modelReloadRequired")
    );
    let before = registry
        .model_fingerprint(&Core, &missing)
        .expect("fingerprint");
    registry
        .apply_command_model(&Core, &missing, static_context.model.clone(), &before)
        .expect("load a model already decoded by Core");
    let loaded = registry
        .model_context("main", &fixture.path(), &missing.plugin_id, "cargo", ".")
        .expect("loaded context");
    assert!(prepare(&loaded, &selected).is_ok(), "loaded command model");
    fixture.file(
        "Cargo.toml",
        "[package]\nname=\"changed\"\nversion=\"0.1.0\"\n",
    );
    registry
        .sync_check(
            &Core,
            &package,
            "main",
            &fixture.path(),
            &missing.plugin_id,
            "cargo",
            ".",
        )
        .expect("mark model stale");
    assert!(
        !registry.context_is_current(&loaded),
        "old approval is invalid"
    );
    let stale = registry
        .model_context("main", &fixture.path(), &missing.plugin_id, "cargo", ".")
        .expect("stale context remains reloadable");
    assert!(stale.model_stale);
    assert_eq!(
        prepare(&stale, &selected).err().as_deref(),
        Some("plugin.build.modelReloadRequired")
    );
    for kind in [BuildRunKind::Task, BuildRunKind::Test] {
        let selected = selection(&stale, kind);
        assert_eq!(
            prepare(&stale, &selected).err().as_deref(),
            Some("plugin.build.modelReloadRequired"),
            "selected model entities must be current"
        );
    }
    let mut independent_task = selection(&stale, BuildRunKind::Task);
    independent_task.project_id = None;
    assert!(
        prepare(&stale, &independent_task).is_ok(),
        "a workspace task with no model selection does not require a model"
    );
}

#[test]
fn workspace_reports_without_a_model_declaration_remain_available() {
    let fixture = Fixture::new();
    let mut declaration = manifest();
    declaration["buildSystems"][0]
        .as_object_mut()
        .expect("system")
        .remove("model");
    declaration["buildSystems"][0]["options"]
        .as_array_mut()
        .expect("options")
        .retain(|option| option["id"] != "features");
    declaration["buildSystems"][0]["run"] = json!([]);
    declaration["buildSystems"][0]["test"]["scopes"] = json!(["workspace"]);
    declaration["buildSystems"][0]["test"]["targetTags"] = json!([]);
    declaration["buildSystems"][0]["test"]["filters"] = json!([]);
    declaration["buildSystems"][0]["test"]["arguments"] = json!(["test", "${optionArguments}"]);
    declaration["buildSystems"][0]["test"]["results"] =
        json!({"decoder":"junitXml","reports":["reports/*.xml"]});
    let (_, _, context) = registry(&fixture, declaration, "main");
    assert!(context.model.is_null());
    let selected = selection(&context, BuildRunKind::Test);
    assert!(selected.project_id.is_none());
    assert!(prepare_run_plan(
        &Core,
        &context,
        &selected,
        &fixture.root,
        &fixture.root,
        "no-model-needed",
        Arc::new(Sink::default()),
    )
    .is_ok());
}

#[test]
fn pending_cancel_and_duplicate_confirmation_never_release_an_active_slot_early() {
    let fixture = Fixture::new();
    let (_, _, context) = registry(&fixture, manifest(), "main");
    let sink = Arc::new(Sink::default());
    let operations = BuildOperations::default();
    let first = operations
        .insert(operation(
            &fixture,
            context.clone(),
            &selection(&context, BuildRunKind::Task),
            sink.clone(),
        ))
        .expect("prepare");
    let pending = operations
        .get("main", &first.operation_id)
        .expect("pending");
    pending.cancel();
    pending.cancel();
    assert!(operations.claim("main", &first.operation_id).is_err());
    assert_eq!(sink.0.lock().expect("events").len(), 1);
    let second = operations
        .insert(operation(
            &fixture,
            context.clone(),
            &selection(&context, BuildRunKind::Task),
            sink.clone(),
        ))
        .expect("new");
    let running = operations
        .claim("main", &second.operation_id)
        .expect("claim");
    assert!(operations.claim("main", &second.operation_id).is_err());
    running.0.cancel();
    assert!(!running.0.finished());
    assert!(operations
        .insert(operation(
            &fixture,
            context.clone(),
            &selection(&context, BuildRunKind::Task),
            sink.clone()
        ))
        .is_err());
    drop(running);
    assert!(operations
        .insert(operation(
            &fixture,
            context.clone(),
            &selection(&context, BuildRunKind::Task),
            sink
        ))
        .is_ok());
}

#[test]
fn cancellation_and_terminal_publication_respect_the_winning_order() {
    for cancel_first in [true, false] {
        let fixture = Fixture::new();
        let (_, _, context) = registry(&fixture, manifest(), "main");
        let sink = Arc::new(Sink::default());
        let operations = BuildOperations::default();
        let review = operations
            .insert(operation(
                &fixture,
                context.clone(),
                &selection(&context, BuildRunKind::Task),
                sink.clone(),
            ))
            .expect("prepare");
        let running = operations
            .claim("main", &review.operation_id)
            .expect("claim");
        // Execution has drained but its terminal has not been published. The
        // controlled order reproduces both sides of the cancel/finish race.
        let executor = executor(|_, _| result(Some(0), None, true));
        let terminal =
            execute_run(&running.0, &Core, &executor, &Guard(|| Ok(()))).expect("drained run");
        assert_eq!(terminal.kind, "succeeded");
        if cancel_first {
            running.0.cancel();
        }
        let terminal = running
            .0
            .complete_run(terminal, || Ok(()))
            .expect("publish");
        running.0.cancel();
        assert!(
            running.0.publish(|| Ok(())).is_err(),
            "no publication after cancel"
        );
        assert!(!running.0.finished(), "owner still holds the busy slot");
        let owner = running.0.clone();
        drop(running);
        assert!(owner.finished());
        let events = sink.0.lock().expect("events");
        let terminals: Vec<_> = events
            .iter()
            .filter(|(_, event)| event["type"] == "terminal")
            .collect();
        assert_eq!(terminals.len(), 1);
        assert_eq!(
            terminal.kind,
            if cancel_first {
                "cancelled"
            } else {
                "succeeded"
            }
        );
        assert_eq!(terminals[0].1["terminal"]["kind"], terminal.kind);
    }
}

#[test]
fn two_windows_have_independent_slots_and_cannot_confirm_each_others_run() {
    let fixture = Fixture::new();
    let (mut registry, package, first) = registry(&fixture, manifest(), "main");
    registry
        .refresh(
            &Core,
            &package,
            &Options,
            "workspace-second",
            &fixture.path(),
        )
        .expect("second window");
    let second = registry
        .model_context(
            "workspace-second",
            &fixture.path(),
            &first.plugin_id,
            "cargo",
            ".",
        )
        .expect("second context");
    let sink = Arc::new(Sink::default());
    let operations = BuildOperations::default();
    let a = operations
        .insert(operation(
            &fixture,
            first.clone(),
            &selection(&first, BuildRunKind::Task),
            sink.clone(),
        ))
        .expect("first");
    let b = operations
        .insert(operation(
            &fixture,
            second.clone(),
            &selection(&second, BuildRunKind::Task),
            sink.clone(),
        ))
        .expect("second");
    assert!(operations.claim("main", &b.operation_id).is_err());
    let running = operations
        .claim("main", &a.operation_id)
        .expect("main claim");
    operations.cancel_matching(|operation| operation.context.window_label == "workspace-second");
    assert!(!running.0.cancelled());
    let events = sink.0.lock().expect("events");
    assert_eq!(events.len(), 1);
    assert_eq!(events[0].0, "workspace-second");
    assert_eq!(events[0].1["operationId"], b.operation_id);
}

#[test]
fn suspension_workspace_return_and_plugin_revocation_invalidate_approval() {
    let fixture = Fixture::new();
    let (mut registry, package, context) = registry(&fixture, manifest(), "main");
    registry.suspend_execution("main");
    registry.suspend_execution("main");
    assert!(!registry.context_is_current(&context));
    assert!(registry
        .model_context("main", &fixture.path(), &context.plugin_id, "cargo", ".")
        .is_err());
    registry.resume_execution("main");
    assert!(
        registry
            .model_context("main", &fixture.path(), &context.plugin_id, "cargo", ".")
            .is_err(),
        "overlapping drains remain suspended"
    );
    registry.resume_execution("main");
    assert!(
        !registry.context_is_current(&context),
        "resuming cannot resurrect approval"
    );
    let current = registry
        .model_context("main", &fixture.path(), &context.plugin_id, "cargo", ".")
        .expect("new");
    registry.close_workspace("main", &fixture.path());
    registry
        .refresh(&Core, &package, &Options, "main", &fixture.path())
        .expect("return");
    assert!(!registry.context_is_current(&current));
    let current = registry
        .model_context("main", &fixture.path(), &context.plugin_id, "cargo", ".")
        .expect("current");
    registry.drop_plugin(&context.plugin_id);
    assert!(!registry.context_is_current(&current));
}

#[test]
fn model_replacement_and_window_recreation_never_reuse_an_approved_snapshot() {
    let fixture = Fixture::new();
    let (mut registry, package, context) = registry(&fixture, manifest(), "main");
    let sink = Arc::new(Sink::default());
    let operation = operation(
        &fixture,
        context.clone(),
        &selection(&context, BuildRunKind::Task),
        sink.clone(),
    );
    let executor = executor(|_, _| result(Some(0), None, true));
    let terminal = execute_run(&operation, &Core, &executor, &Guard(|| Ok(()))).expect("drained");
    let before = registry
        .model_fingerprint(&Core, &context)
        .expect("fingerprint");
    registry
        .apply_command_model(&Core, &context, context.model.clone(), &before)
        .expect("replace model even with identical content");
    assert!(!registry.context_is_current(&context));
    let terminal = operation
        .complete_run(terminal, || {
            if registry.context_is_current(&context) {
                Ok(())
            } else {
                Err("plugin.build.staleContext".into())
            }
        })
        .expect("last checkpoint rejects the replaced model");
    assert_eq!(terminal.kind, "cancelled");
    assert_eq!(
        sink.0.lock().expect("events").last().expect("terminal").1["terminal"]["kind"],
        "cancelled"
    );
    let current = registry
        .model_context("main", &fixture.path(), &context.plugin_id, "cargo", ".")
        .expect("new model context");
    registry.close_window("main");
    registry
        .refresh(&Core, &package, &Options, "main", &fixture.path())
        .expect("recreated window");
    assert!(!registry.context_is_current(&current));
}

#[test]
fn timeout_cancel_output_limit_start_failure_and_cleanup_failure_have_distinct_outcomes() {
    for (code, started, expected) in [
        ("plugin.build.timeout", true, "failed"),
        ("plugin.build.cancelled", true, "cancelled"),
        ("plugin.build.outputLimit", true, "failed"),
        ("plugin.build.processFailed", false, "failedToStart"),
        ("plugin.build.cleanupFailed", true, "occupied"),
    ] {
        let fixture = Fixture::new();
        let (_, _, context) = registry(&fixture, manifest(), "main");
        let sink = Arc::new(Sink::default());
        let operations = BuildOperations::default();
        let review = operations
            .insert(operation(
                &fixture,
                context.clone(),
                &selection(&context, BuildRunKind::Task),
                sink.clone(),
            ))
            .expect("prepare");
        let running = operations
            .claim("main", &review.operation_id)
            .expect("claim");
        let cancelled = Cell::new(false);
        let executor = executor(|_, _| {
            cancelled.set(code == "plugin.build.cancelled");
            result(None, Some(code), started)
        });
        let guard = Guard(|| {
            if cancelled.get() {
                Err("plugin.build.cancelled".into())
            } else {
                Ok(())
            }
        });
        let terminal = execute_run(&running.0, &Core, &executor, &guard);
        if expected == "occupied" {
            assert_eq!(terminal.err().as_deref(), Some(code));
            running.0.retain_failed_cleanup(());
            let control = running.0.clone();
            drop(running);
            assert!(!control.finished());
            assert!(sink.0.lock().expect("events").is_empty());
        } else {
            let terminal = terminal.expect("drained");
            assert_eq!(terminal.kind, expected);
            finish(&running.0, &terminal);
            drop(running);
            assert_eq!(
                sink.0
                    .lock()
                    .expect("events")
                    .iter()
                    .filter(|(_, event)| event["type"] == "terminal")
                    .count(),
                1
            );
        }
    }
}

#[test]
fn revoke_during_streaming_drops_late_output_and_decoding() {
    let fixture = Fixture::new();
    let (_, _, context) = registry(&fixture, manifest(), "main");
    let sink = Arc::new(Sink::default());
    let operation = operation(
        &fixture,
        context.clone(),
        &selection(&context, BuildRunKind::Task),
        sink.clone(),
    );
    let revoked = Cell::new(false);
    let executor = executor(|_, output| {
        output(lithe_git_host::Stream::Stdout, b"early\n").expect("early");
        revoked.set(true);
        assert!(output(lithe_git_host::Stream::Stderr, b"late\n").is_err());
        result(None, Some("plugin.build.cancelled"), true)
    });
    let terminal = execute_run(
        &operation,
        &Core,
        &executor,
        &Guard(|| {
            if revoked.get() {
                Err("plugin.build.packageChanged".into())
            } else {
                Ok(())
            }
        }),
    )
    .expect("cancel");
    finish(&operation, &terminal);
    let events = sink.0.lock().expect("events");
    assert_eq!(events.len(), 2);
    assert_eq!(events[0].1["text"], "early\n");
    assert_eq!(terminal.kind, "cancelled");
}

#[test]
fn selection_refuses_injected_commands_entity_paths_reports_and_unknown_properties() {
    for field in [
        "executable",
        "arguments",
        "environment",
        "workingDirectory",
        "reports",
        "permissions",
        "url",
        "project",
    ] {
        let mut input = json!({"kind":"task","taskId":"build"});
        input[field] = json!("untrusted");
        assert!(
            serde_json::from_value::<BuildRunSelection>(input).is_err(),
            "{field}"
        );
    }
    let fixture = Fixture::new();
    let (_, _, context) = registry(&fixture, manifest(), "main");
    let mut selected = selection(&context, BuildRunKind::Task);
    selected.project_id = Some("../outside".into());
    assert!(prepare_run_plan(
        &Core,
        &context,
        &selected,
        &fixture.root,
        &fixture.root,
        "invalid",
        Arc::new(Sink::default())
    )
    .is_err());
}

#[test]
fn output_budget_and_split_utf8_are_bounded_without_corrupting_characters() {
    let mut stream = Utf8Stream::default();
    let bytes = "中文🙂".as_bytes();
    let mut text = String::new();
    for byte in bytes {
        text.push_str(&stream.push(&[*byte]));
    }
    text.push_str(&stream.finish());
    assert_eq!(text, "中文🙂");
    let fixture = Fixture::new();
    let (_, _, context) = registry(&fixture, manifest(), "main");
    let sink = Arc::new(Sink::default());
    let events = RunEvents::new(&context, "bounded", sink.clone());
    let chunk = "x".repeat(8192);
    for _ in 0..MAX_RUN_OUTPUT / 8192 {
        events.chunk("stdout", &chunk).expect("within budget");
    }
    assert!(events.chunk("stdout", "overflow").is_err());
    let terminal = BuildRunTerminal {
        kind: "failed".into(),
        exit_code: None,
        message: Some("plugin.build.outputLimit".into()),
    };
    events
        .terminal(&terminal)
        .expect("terminal survives output budget");
    assert_eq!(
        sink.0.lock().expect("events").last().expect("last").1["type"],
        "terminal"
    );
}
