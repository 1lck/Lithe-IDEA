//! Generic, consent-bound Windows execution of Core project generation plans.
mod archive;
mod catalog;
#[cfg(test)]
mod tests;
mod transaction;

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::{Path, PathBuf};
#[cfg(test)]
use std::sync::atomic::AtomicU64;
use std::sync::atomic::{AtomicBool, AtomicU8, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Manager, WebviewWindow};
use transaction::{Executor, Parent, Transaction};

type Result<T> = std::result::Result<T, Error>;
const OPERATION_BUDGET: Duration = Duration::from_secs(600);
const REVIEW_TTL: Duration = Duration::from_secs(120);
const OUTPUT_LIMIT: usize = 2 * 1024 * 1024;
#[cfg(test)]
static NEXT_ID: AtomicU64 = AtomicU64::new(1);

#[derive(Debug, Clone, Serialize)]
pub struct Error {
    pub code: String,
    pub message: String,
    pub details: Option<String>,
}
impl Error {
    fn new(code: &str) -> Self {
        Self {
            code: code.into(),
            message: code.into(),
            details: None,
        }
    }
    fn io(error: std::io::Error) -> Self {
        Self {
            details: Some(error.kind().to_string()),
            ..Self::new("generator.ioFailed")
        }
    }
}

fn core(command: &str, payload: Value, key: &str) -> Result<Value> {
    let value = super::scan::core_execute(command, payload)
        .map_err(|_| Error::new("generator.coreFailed"))?;
    if value["status"] != "ok" {
        return Err(Error::new("generator.invalidInput"));
    }
    value
        .get(key)
        .cloned()
        .ok_or_else(|| Error::new("generator.invalidPlan"))
}

fn scope(window: &WebviewWindow) -> Result<String> {
    let label = window.label();
    if label != "main" && !label.starts_with("workspace-") {
        return Err(Error::new("generator.invalidOwner"));
    }
    Ok(label.into())
}

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct Request {
    plugin_id: String,
    generator_id: String,
    package_identity: String,
    form: Value,
    parent: String,
    create_git: bool,
}

#[derive(Clone)]
struct Program {
    executable: PathBuf,
    identity: Arc<same_file::Handle>,
    arguments: Vec<String>,
    environment: BTreeMap<String, String>,
}

struct Review {
    owner: String,
    request: Request,
    plan: Value,
    digest: String,
    requirements: Value,
    package_root: PathBuf,
    parent: Parent,
    programs: BTreeMap<usize, Program>,
    created: Instant,
}
struct Operation {
    owner: String,
    plugin: String,
    target: PathBuf,
    cancelled: AtomicBool,
    download_cancel: super::marketplace_download::CancelToken,
    publication: Mutex<()>,
    finished: AtomicBool,
    changed: tokio::sync::Notify,
    // A failed process-tree cleanup retains the package mutation barrier.
    lease: Mutex<Option<super::lifecycle::NativeLease>>,
    cleanup: Mutex<Option<RetainedCleanup>>,
}

enum RetainedCleanup {
    Filesystem(Transaction),
    // The synchronous Core/Git runner does not return a process owner after
    // uncertain cleanup. Do not remove staging or release its package lease.
    UnconfirmedWriter { _transaction: Transaction },
}

impl Operation {
    fn cancel(&self) {
        let _order = self.publication.lock().expect("generator publication");
        self.cancelled.store(true, Ordering::Release);
        self.download_cancel.cancel();
    }
    fn checkpoint(&self, deadline: Instant) -> Result<()> {
        if self.cancelled.load(Ordering::Acquire) {
            return Err(Error::new("generator.cancelled"));
        }
        if Instant::now() >= deadline {
            return Err(Error::new("generator.timeout"));
        }
        Ok(())
    }

    fn cleanup_finished(&self) -> Result<()> {
        if !self.finished.load(Ordering::Acquire) {
            return Err(Error::new("generator.cleanupFailed"));
        }
        let mut cleanup = self.cleanup.lock().expect("generator cleanup");
        match cleanup.as_ref() {
            Some(RetainedCleanup::Filesystem(transaction)) => transaction.cleanup()?,
            Some(RetainedCleanup::UnconfirmedWriter { .. }) => {
                // The retained directory's existence is not evidence that a
                // writer has terminated. This case requires process restart.
                return Err(Error::new("generator.cleanupFailed"));
            }
            None if self.lease.lock().expect("generator lease").is_some() => {
                return Err(Error::new("generator.cleanupFailed"));
            }
            None => return Ok(()),
        }
        cleanup.take();
        self.lease.lock().expect("generator lease").take();
        Ok(())
    }
}
#[derive(Default)]
struct Registry {
    reviews: HashMap<String, Review>,
    operations: HashMap<String, Arc<Operation>>,
    closed_owners: HashSet<String>,
}
#[derive(Default)]
pub struct GeneratorState(Mutex<Registry>, AtomicU8);

fn package(app: &AppHandle, plugin_id: &str) -> Result<super::ScannedPackage> {
    if app.state::<GeneratorState>().1.load(Ordering::Acquire) != 0 {
        return Err(Error::new("generator.inactive"));
    }
    if app
        .state::<super::lifecycle::LifecycleState>()
        .blocked(plugin_id)
    {
        return Err(Error::new("generator.inactive"));
    }
    super::launch::verified_package_by_id(app, plugin_id)
        .map_err(|_| Error::new("generator.untrusted"))
}

#[tauri::command]
pub async fn declarative_plugins_generator_catalog(
    app: AppHandle,
    window: WebviewWindow,
) -> Result<Value> {
    scope(&window)?;
    tauri::async_runtime::spawn_blocking(move || {
        super::declarative_plugins_rescan(app.clone())
            .map_err(|_| Error::new("generator.coreFailed"))?;
        catalog::load(&app)
    })
    .await
    .map_err(|_| Error::new("generator.workerFailed"))?
}

#[tauri::command]
pub async fn declarative_plugins_generator_form(
    app: AppHandle,
    window: WebviewWindow,
    plugin_id: String,
    generator_id: String,
    package_identity: String,
    form: Value,
) -> Result<Value> {
    scope(&window)?;
    tauri::async_runtime::spawn_blocking(move || {
        let _lease = app
            .state::<super::lifecycle::LifecycleState>()
            .acquire(&plugin_id)
            .map_err(|_| Error::new("generator.inactive"))?;
        let (package, identity) = catalog::read(&app, &plugin_id)?;
        if identity != package_identity {
            return Err(Error::new("generator.stale"));
        }
        let mut form = core(
            "project.generatorForm",
            json!({"manifest":package.manifest,"generatorID":generator_id,"form":form}),
            "form",
        )?;
        form["packageIdentity"] = json!(identity);
        Ok(form)
    })
    .await
    .map_err(|_| Error::new("generator.workerFailed"))?
}

/// Java is the only runtime kind in the shared generator contract. Discovery
/// stays in the existing runtime adapter; fields never select commands to probe.
#[tauri::command]
pub async fn declarative_plugins_generator_runtime(
    app: AppHandle,
    window: WebviewWindow,
    plugin_id: String,
    home: String,
) -> Result<crate::run::JavaRuntime> {
    scope(&window)?;
    tauri::async_runtime::spawn_blocking(move || {
        let _lease = app
            .state::<super::lifecycle::LifecycleState>()
            .acquire(&plugin_id)
            .map_err(|_| Error::new("generator.inactive"))?;
        package(&app, &plugin_id)?;
        let parent = Parent::open(Path::new(&home))?;
        crate::run::probe_java_home(&parent.path)
            .ok_or_else(|| Error::new("generator.runtimeInvalid"))
    })
    .await
    .map_err(|_| Error::new("generator.workerFailed"))?
}

fn plan(app: &AppHandle, request: &Request) -> Result<(super::ScannedPackage, Value)> {
    // Preserve the launch trust gate, then refresh the installation state
    // instead of relying on the scan cache's enabled flag.
    package(app, &request.plugin_id)?;
    let (package, identity) = catalog::read(app, &request.plugin_id)?;
    if !package.entry.enabled {
        return Err(Error::new("generator.inactive"));
    }
    if identity != request.package_identity {
        return Err(Error::new("generator.stale"));
    }
    let plan = core(
        "project.generationPlan",
        json!({"manifest":package.manifest,"generatorID":request.generator_id,
        "packagePath":package.root,"form":request.form}),
        "plan",
    )?;
    Ok((package, plan))
}

fn set_env(environment: &mut BTreeMap<String, String>, key: &str, value: String) {
    environment.retain(|old, _| !old.eq_ignore_ascii_case(key));
    environment.insert(key.into(), value);
}

fn resolve_program(step: &Value) -> Result<Program> {
    let command = step["command"]
        .as_str()
        .ok_or_else(|| Error::new("generator.invalidPlan"))?;
    // Like the reference host, only a Core-declared JAVA_HOME changes this
    // command's runtime. Multiple runtime fields can serve different steps.
    let java_home = step["environment"]["JAVA_HOME"]
        .as_str()
        .filter(|home| !home.is_empty());
    let executable = java_home
        .and_then(|home| crate::run::jdk_tool_executable(Path::new(home), command))
        .or_else(|| crate::run::resolve_command_executable(command, &HashMap::new()))
        .ok_or_else(|| Error::new("generator.toolMissing"))?;
    if !executable.is_absolute() {
        return Err(Error::new("generator.toolMissing"));
    }
    let executable = std::fs::canonicalize(executable).map_err(Error::io)?;
    let identity = Arc::new(same_file::Handle::from_path(&executable).map_err(Error::io)?);
    let arguments: Vec<String> = serde_json::from_value(step["arguments"].clone())
        .map_err(|_| Error::new("generator.invalidPlan"))?;
    // The shared launch adapter uses cmd.exe for batch shims. CALL reparses
    // metacharacters, so reject those inputs rather than treating argv as shell text.
    if executable
        .extension()
        .is_some_and(|ext| ext.eq_ignore_ascii_case("cmd") || ext.eq_ignore_ascii_case("bat"))
        && std::iter::once(executable.to_string_lossy().as_ref())
            .chain(arguments.iter().map(String::as_str))
            .any(|argument| argument.chars().any(|ch| "%!^&|<>()\r\n\"".contains(ch)))
    {
        return Err(Error::new("generator.batchArgumentUnsupported"));
    }
    let mut environment: BTreeMap<String, String> = BTreeMap::new();
    for (key, value) in std::env::vars() {
        set_env(&mut environment, &key, value);
    }
    if let Some(home) = java_home {
        set_env(&mut environment, "JAVA_HOME", home.into());
    }
    let overrides: BTreeMap<String, String> = serde_json::from_value(step["environment"].clone())
        .map_err(|_| Error::new("generator.invalidPlan"))?;
    for (key, value) in overrides {
        set_env(&mut environment, &key, value);
    }
    let mut directories = java_home
        .map(|home| Path::new(home).join("bin"))
        .into_iter()
        .collect::<Vec<_>>();
    if let Some(parent) = executable.parent() {
        directories.push(parent.to_path_buf());
    }
    if let Some(path) = environment
        .iter()
        .find(|(key, _)| key.eq_ignore_ascii_case("PATH"))
        .map(|(_, value)| value)
    {
        directories.extend(std::env::split_paths(path));
    }
    let path =
        std::env::join_paths(directories).map_err(|_| Error::new("generator.invalidPath"))?;
    set_env(
        &mut environment,
        "PATH",
        path.to_string_lossy().into_owned(),
    );
    Ok(Program {
        executable,
        identity,
        arguments,
        environment,
    })
}

#[tauri::command]
pub async fn declarative_plugins_generator_prepare(
    app: AppHandle,
    window: WebviewWindow,
    request: Request,
) -> Result<Value> {
    let owner = scope(&window)?;
    tauri::async_runtime::spawn_blocking(move || {
        let _lease = app.state::<super::lifecycle::LifecycleState>().acquire(&request.plugin_id).map_err(|_| Error::new("generator.inactive"))?;
        let (package, plan) = plan(&app, &request)?;
        let name = plan["projectName"].as_str().ok_or_else(|| Error::new("generator.invalidPlan"))?;
        transaction::component(name)?;
        let parent = Parent::open(Path::new(&request.parent))?;
        transaction::absent(&parent.path.join(name))?;
        let mut programs = BTreeMap::new();
        for (index, step) in plan["steps"].as_array().ok_or_else(|| Error::new("generator.invalidPlan"))?.iter().enumerate() {
            if step["kind"] == "command" { programs.insert(index, resolve_program(step)?); }
        }
        let digest = super::signature::content_digest(&package.root).map_err(|_| Error::new("generator.untrusted"))?;
        let requirements = catalog::requirements(&app, &request, &package)?;
        let id = super::install::uuid_like_suffix();
        let displayed_steps: Vec<_> = plan["steps"].as_array().into_iter().flatten().map(|step| {
            if step["kind"] != "writeFiles" { return step.clone(); }
            json!({"kind":"writeFiles","files":step["files"].as_array().into_iter().flatten()
                .map(|file| json!({"path":file["path"],"executable":file["executable"]})).collect::<Vec<_>>()})
        }).collect();
        let response = json!({"id":id,"requirements":requirements,"plan":{"steps":displayed_steps,"usesNetwork":plan["usesNetwork"],"runtimes":plan["runtimes"]},"destination":parent.path.join(name),
            "programs":programs.values().map(|program| json!({"executable":program.executable,"arguments":program.arguments})).collect::<Vec<_>>()});
        let state = app.state::<GeneratorState>();
        let mut registry = state.0.lock().expect("generator reviews");
        if state.1.load(Ordering::Acquire) != 0 || registry.closed_owners.contains(&owner) { return Err(Error::new("generator.inactive")); }
        registry.reviews.retain(|_, review| review.created.elapsed() < REVIEW_TTL);
        if registry.reviews.len() >= 64 { return Err(Error::new("generator.busy")); }
        registry.reviews.insert(id, Review { owner, request, plan, digest, requirements, package_root: package.root, parent, programs, created: Instant::now() });
        Ok(response)
    }).await.map_err(|_| Error::new("generator.workerFailed"))?
}

struct NativeExecutor<'a> {
    review: &'a Review,
    operation: &'a Operation,
    operation_id: &'a str,
}
impl Executor for NativeExecutor<'_> {
    fn archive(
        &self,
        step: &Value,
        stage: &Path,
        deadline: Instant,
        checkpoint: &dyn Fn() -> Result<()>,
    ) -> Result<()> {
        if step["format"] != "zip" {
            return Err(Error::new("generator.invalidPlan"));
        }
        let transport = super::marketplace_download::ReqwestTransport::new()
            .map_err(|_| Error::new("generator.downloadFailed"))?;
        archive::execute(
            &transport,
            step["url"]
                .as_str()
                .ok_or_else(|| Error::new("generator.invalidPlan"))?,
            stage,
            self.operation_id,
            &self.operation.download_cancel,
            deadline,
            checkpoint,
        )
    }
    fn command(
        &self,
        index: usize,
        step: &Value,
        stage: &Path,
        deadline: Instant,
        checkpoint: &dyn Fn() -> Result<()>,
    ) -> Result<()> {
        checkpoint()?;
        let program = self
            .review
            .programs
            .get(&index)
            .ok_or_else(|| Error::new("generator.invalidPlan"))?;
        if same_file::Handle::from_path(&program.executable).map_err(Error::io)?
            != *program.identity
        {
            return Err(Error::new("generator.stale"));
        }
        let mut command = crate::run::command_for_executable(
            &program.executable.to_string_lossy(),
            &program.arguments,
        );
        command
            .current_dir(stage)
            .env_clear()
            .envs(&program.environment);
        let step_deadline = deadline.min(
            Instant::now()
                + Duration::from_secs(step["timeoutSeconds"].as_u64().unwrap_or(600).min(1800)),
        );
        let bytes = std::cell::Cell::new(0usize);
        let outcome = lithe_git_host::run(
            &mut command,
            None,
            || self.operation.checkpoint(step_deadline).is_err() || bytes.get() > OUTPUT_LIMIT,
            || {},
            |_, chunk| bytes.set(bytes.get().saturating_add(chunk.len())),
        );
        if matches!(outcome.failure, Some(lithe_git_host::Failure::Cleanup)) {
            return Err(Error::new("generator.cleanupFailed"));
        }
        checkpoint()?;
        if Instant::now() >= step_deadline {
            return Err(Error::new("generator.timeout"));
        }
        if bytes.get() > OUTPUT_LIMIT {
            return Err(Error::new("generator.outputLimit"));
        }
        if outcome.failure.is_some() || !outcome.status.is_some_and(|status| status.success()) {
            return Err(Error::new("generator.commandFailed"));
        }
        Ok(())
    }
}

fn preset_runtime(transaction: &Transaction, plan: &Value) -> Result<()> {
    let selections: Vec<_> = plan["runtimes"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|runtime| runtime["runtime"] == "java")
        .collect();
    if selections.is_empty() {
        return Ok(());
    }
    let home = selections
        .last()
        .ok_or_else(|| Error::new("generator.invalidPlan"))?["home"]
        .as_str()
        .ok_or_else(|| Error::new("generator.invalidPlan"))?;
    let document = super::scan::core_execute(
        "runConfig.updateOptions",
        json!({"root":transaction.stage,
        "scope":"local","configurationId":"unused","toolchain":{"javaHomePath":home}}),
    )
    .map_err(|_| Error::new("generator.coreFailed"))?;
    transaction.write(
        ".lithe/run/local.json",
        document["document"]
            .as_str()
            .ok_or_else(|| Error::new("generator.invalidPlan"))?
            .as_bytes(),
    )
}

fn generate(app: &AppHandle, review: &Review, operation: &Operation, id: &str) -> Result<Value> {
    let deadline = Instant::now() + OPERATION_BUDGET;
    let checkpoint = || operation.checkpoint(deadline);
    checkpoint()?;
    let (package, fresh) = plan(app, &review.request)?;
    if catalog::requirements(app, &review.request, &package)? != review.requirements {
        return Err(Error::new("generator.stale"));
    }
    if fresh != review.plan
        || package.root != review.package_root
        || super::signature::content_digest(&package.root)
            .map_err(|_| Error::new("generator.untrusted"))?
            != review.digest
    {
        return Err(Error::new("generator.stale"));
    }
    for runtime in fresh["runtimes"].as_array().into_iter().flatten() {
        checkpoint()?;
        if runtime["runtime"] != "java" {
            return Err(Error::new("generator.runtimeInvalid"));
        }
        let home = Parent::open(Path::new(
            runtime["home"]
                .as_str()
                .ok_or_else(|| Error::new("generator.runtimeInvalid"))?,
        ))?;
        let probed = crate::run::probe_java_home(&home.path)
            .ok_or_else(|| Error::new("generator.runtimeInvalid"))?;
        if runtime["version"] != probed.version {
            return Err(Error::new("generator.stale"));
        }
    }
    review.parent.check()?;
    let name = fresh["projectName"]
        .as_str()
        .ok_or_else(|| Error::new("generator.invalidPlan"))?;
    let mut transaction = Transaction::create(review.parent.reopen()?, name, id)?;
    let result = (|| {
        transaction::execute(
            &mut transaction,
            &fresh,
            &NativeExecutor {
                review,
                operation,
                operation_id: &format!("generator-{id}"),
            },
            deadline,
            &checkpoint,
        )?;
        checkpoint()?;
        preset_runtime(&transaction, &fresh)?;
        if review.request.create_git {
            checkpoint()?;
            // Core's existing Git initializer has its own process deadline. The
            // cancellation command forwards this operation ID while it runs.
            let remaining = deadline
                .saturating_duration_since(Instant::now())
                .as_millis()
                .min(20000)
                .max(1) as u64;
            let request = json!({"command":"git.initialize","operationId":format!("generator-{id}"),"timeoutMilliseconds":remaining,"payload":{"root":transaction.stage}});
            let value = lithe_core::execute_json(&request.to_string());
            let value: Value =
                serde_json::from_str(&value).map_err(|_| Error::new("generator.coreFailed"))?;
            if value["ok"] != true {
                // Core intentionally uses one process_failed category for both
                // I/O failures and an unconfirmed process-tree cleanup. Retain
                // ownership for that ambiguous category instead of parsing text.
                if value["error"]["code"] == "process_failed" {
                    return Err(Error::new("generator.cleanupFailed"));
                }
                return Err(Error::new("generator.gitFailed"));
            }
        }
        let relative_open_files: Vec<PathBuf> = fresh["openFiles"]
            .as_array()
            .into_iter()
            .flatten()
            .map(|path| {
                path.as_str()
                    .ok_or_else(|| Error::new("generator.invalidPlan"))
                    .and_then(transaction::relative)
            })
            .collect::<Result<_>>()?;
        transaction.validate(&checkpoint)?;
        let _publication = operation.publication.lock().expect("generator publication");
        checkpoint()?;
        let root = transaction.publish(&checkpoint)?;
        let open_files: Vec<_> = relative_open_files
            .into_iter()
            .map(|path| root.join(path))
            .collect();
        Ok(json!({"root":root,"openFiles":open_files}))
    })();
    // A process-tree cleanup failure may leave a writer alive. Keep both the
    // stage and NativeLease, preventing an unsafe plugin replacement.
    if result
        .as_ref()
        .err()
        .is_some_and(|error| error.code == "generator.cleanupFailed")
    {
        *operation.cleanup.lock().expect("generator cleanup") =
            Some(RetainedCleanup::UnconfirmedWriter {
                _transaction: transaction,
            });
        return result;
    }
    if let Err(error) = transaction.cleanup() {
        *operation.cleanup.lock().expect("generator cleanup") =
            Some(RetainedCleanup::Filesystem(transaction));
        return Err(error);
    }
    result
}

#[tauri::command]
pub async fn declarative_plugins_generator_generate(
    app: AppHandle,
    window: WebviewWindow,
    id: String,
) -> Result<Value> {
    let owner = scope(&window)?;
    let (review, operation) = {
        let state = app.state::<GeneratorState>();
        let mut registry = state.0.lock().expect("generator registry");
        if state.1.load(Ordering::Acquire) != 0 || registry.closed_owners.contains(&owner) {
            return Err(Error::new("generator.inactive"));
        }
        if registry.operations.len() >= 8 {
            return Err(Error::new("generator.busy"));
        }
        if registry
            .reviews
            .get(&id)
            .is_none_or(|review| review.owner != owner)
        {
            return Err(Error::new("generator.stale"));
        }
        let review = registry
            .reviews
            .remove(&id)
            .ok_or_else(|| Error::new("generator.stale"))?;
        if review.created.elapsed() >= REVIEW_TTL {
            return Err(Error::new("generator.stale"));
        }
        let target = review.parent.path.join(
            review.plan["projectName"]
                .as_str()
                .ok_or_else(|| Error::new("generator.invalidPlan"))?,
        );
        if registry.operations.values().any(|operation| {
            operation
                .target
                .to_string_lossy()
                .eq_ignore_ascii_case(&target.to_string_lossy())
        }) {
            return Err(Error::new("generator.busy"));
        }
        let lease = app
            .state::<super::lifecycle::LifecycleState>()
            .acquire(&review.request.plugin_id)
            .map_err(|_| Error::new("generator.inactive"))?;
        let operation = Arc::new(Operation {
            owner,
            plugin: review.request.plugin_id.clone(),
            target,
            cancelled: AtomicBool::new(false),
            download_cancel: super::marketplace_download::CancelToken::new(),
            publication: Mutex::new(()),
            finished: AtomicBool::new(false),
            changed: tokio::sync::Notify::new(),
            lease: Mutex::new(Some(lease)),
            cleanup: Mutex::new(None),
        });
        registry.operations.insert(id.clone(), operation.clone());
        (review, operation)
    };
    tauri::async_runtime::spawn_blocking(move || {
        let result = generate(&app, &review, &operation, &id);
        if !result
            .as_ref()
            .err()
            .is_some_and(|error| error.code == "generator.cleanupFailed")
        {
            operation.lease.lock().expect("generator lease").take();
            app.state::<GeneratorState>()
                .0
                .lock()
                .expect("generator registry")
                .operations
                .remove(&id);
        }
        operation.finished.store(true, Ordering::Release);
        operation.changed.notify_waiters();
        result
    })
    .await
    .map_err(|_| Error::new("generator.workerFailed"))?
}

async fn stop(
    app: &AppHandle,
    owner: Option<&str>,
    plugin: Option<&str>,
    id: Option<&str>,
) -> Result<()> {
    let operations: Vec<_> = {
        let state = app.state::<GeneratorState>();
        let mut registry = state.0.lock().expect("generator registry");
        registry.reviews.retain(|key, review| {
            !(owner.is_none_or(|owner| review.owner == owner)
                && plugin.is_none_or(|plugin| review.request.plugin_id == plugin)
                && id.is_none_or(|id| key == id))
        });
        registry
            .operations
            .iter()
            .filter(|(key, operation)| {
                owner.is_none_or(|owner| operation.owner == owner)
                    && plugin.is_none_or(|plugin| operation.plugin == plugin)
                    && id.is_none_or(|id| key.as_str() == id)
            })
            .map(|(key, operation)| (key.clone(), operation.clone()))
            .collect()
    };
    tokio::time::timeout(Duration::from_secs(12), async {
        let cancellation = operations.clone();
        tauri::async_runtime::spawn_blocking(move || {
            for (id, operation) in cancellation {
                operation.cancel();
                lithe_core::cancel_operation(&format!("generator-{id}"));
            }
        })
        .await
        .map_err(|_| Error::new("generator.cleanupFailed"))?;
        for (id, operation) in operations {
            loop {
                let changed = operation.changed.notified();
                tokio::pin!(changed);
                changed.as_mut().enable();
                if operation.finished.load(Ordering::Acquire) {
                    let retained = operation.lease.lock().expect("generator lease").is_some();
                    if retained {
                        let retry = operation.clone();
                        tauri::async_runtime::spawn_blocking(move || retry.cleanup_finished())
                            .await
                            .map_err(|_| Error::new("generator.cleanupFailed"))??;
                    }
                    let state = app.state::<GeneratorState>();
                    let mut registry = state.0.lock().expect("generator registry");
                    if registry
                        .operations
                        .get(&id)
                        .is_some_and(|current| Arc::ptr_eq(current, &operation))
                    {
                        registry.operations.remove(&id);
                    }
                    break;
                }
                // A cancellation can precede Core's nested Git registration.
                // Retry against that public operation boundary until it exits.
                tokio::select! {
                    _ = changed => {},
                    _ = tokio::time::sleep(Duration::from_millis(25)) => {
                        lithe_core::cancel_operation(&format!("generator-{id}"));
                    }
                }
            }
        }
        Ok(())
    })
    .await
    .map_err(|_| Error::new("generator.cleanupFailed"))?
}

#[tauri::command]
pub async fn declarative_plugins_generator_cancel(
    app: AppHandle,
    window: WebviewWindow,
    id: String,
) -> Result<()> {
    stop(&app, Some(&scope(&window)?), None, Some(&id)).await
}
pub async fn close_plugin(app: &AppHandle, plugin: &str) -> Result<()> {
    stop(app, None, Some(plugin), None).await
}
pub async fn close_window(app: &AppHandle, owner: &str) -> Result<()> {
    window_destroyed(app, owner);
    stop(app, Some(owner), None, None).await
}

pub fn window_destroyed(app: &AppHandle, owner: &str) {
    let state = app.state::<GeneratorState>();
    let mut registry = state.0.lock().expect("generator registry");
    registry.closed_owners.insert(owner.into());
    registry.reviews.retain(|_, review| review.owner != owner);
    for operation in registry
        .operations
        .values()
        .filter(|operation| operation.owner == owner)
    {
        operation.cancelled.store(true, Ordering::Release);
        operation.download_cancel.cancel();
    }
}

/// Defer exit once, without blocking the event/UI thread, while the existing
/// native process owner drains. A second quit request cannot bypass the drain.
pub fn defer_exit(app: &AppHandle, code: Option<i32>) -> bool {
    let state = app.state::<GeneratorState>();
    match state
        .1
        .compare_exchange(0, 1, Ordering::AcqRel, Ordering::Acquire)
    {
        Ok(_) => {
            let app = app.clone();
            tauri::async_runtime::spawn(async move {
                if let Err(error) = stop(&app, None, None, None).await {
                    eprintln!(
                        "Project generator shutdown retained staging: {}",
                        error.code
                    );
                }
                app.state::<GeneratorState>().1.store(2, Ordering::Release);
                app.exit(code.unwrap_or(0));
            });
            true
        }
        Err(1) => true,
        Err(_) => false,
    }
}
