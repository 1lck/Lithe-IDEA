//! Passive execution discovery and exact reviewed launches. Core owns test
//! semantics; the existing Run manager owns output and process trees.
use super::scan::core_execute;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::io::Read;
use std::path::{Component, Path};
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tauri::{AppHandle, Manager, WebviewWindow};

#[cfg(test)]
mod tests;

/// Captured frontend runtime incarnation, bound to the injected native window.
#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ExecutionContext {
    pub client_id: String,
    pub workspace_id: String,
    pub workspace_path: String,
    pub generation: String,
}

/// Admission epochs only; all live/pending processes remain in Run's table.
#[derive(Default)]
pub struct ExecutionState(Mutex<HashMap<String, ExecutionEpoch>>);

#[derive(Default)]
struct ExecutionEpoch {
    client: String,
    retired_clients: HashSet<String>,
    closed_generations: HashSet<String>,
    revision: u64,
    context: Option<ExecutionContext>,
}
impl ExecutionEpoch {
    fn retire(&mut self) {
        if !self.client.is_empty() {
            self.retired_clients.insert(self.client.clone());
        }
        if let Some(context) = self.context.take() {
            self.closed_generations.insert(context.generation);
        }
    }
    fn update(
        &mut self,
        client: String,
        revision: u64,
        context: Option<ExecutionContext>,
    ) -> Result<(), String> {
        if client.is_empty()
            || self.retired_clients.contains(&client)
            || context
                .as_ref()
                .is_some_and(|context| self.closed_generations.contains(&context.generation))
            || context
                .as_ref()
                .is_some_and(|context| context.client_id != client)
            || (self.client == client && self.revision >= revision)
        {
            return Err("plugin.execution.staleContext".into());
        }
        // A webview reload starts a new sequence, while queued IPC from its
        // previous document can never regain admission afterwards.
        if self.client != client && !self.client.is_empty() {
            if self.retired_clients.len() >= 1024 {
                return Err("plugin.execution.workspaceLimit".into());
            }
            self.retired_clients.insert(self.client.clone());
        }
        self.client = client;
        self.revision = revision;
        self.context = context;
        Ok(())
    }
}

#[tauri::command]
pub fn declarative_plugins_close_execution_workspace(
    app: AppHandle,
    window: WebviewWindow,
    workspace_id: String,
) -> Result<(), String> {
    if !(window.label() == "main" || window.label().starts_with("workspace-")) {
        return Err("plugin.execution.staleContext".into());
    }
    let state = app.state::<ExecutionState>();
    let mut epochs = state
        .0
        .lock()
        .map_err(|_| "plugin.execution.staleContext")?;
    if let Some(epoch) = epochs.get_mut(window.label()) {
        if epoch
            .context
            .as_ref()
            .is_some_and(|context| context.workspace_id == workspace_id)
        {
            if let Some(context) = epoch.context.take() {
                epoch.closed_generations.insert(context.generation);
            }
        }
    }
    Ok(())
}

pub fn window_destroyed(app: &AppHandle, label: &str) {
    if let Some(epoch) = app
        .state::<ExecutionState>()
        .0
        .lock()
        .expect("execution admission")
        .get_mut(label)
    {
        epoch.retire();
    }
}

#[tauri::command]
pub fn declarative_plugins_execution_context(
    app: AppHandle,
    window: WebviewWindow,
    client_id: String,
    revision: u64,
    context: Option<ExecutionContext>,
) -> Result<(), String> {
    if !(window.label() == "main" || window.label().starts_with("workspace-")) {
        return Err("plugin.execution.staleContext".into());
    }
    let state = app.state::<ExecutionState>();
    let mut epochs = state
        .0
        .lock()
        .map_err(|_| "plugin.execution.staleContext")?;
    epochs
        .entry(window.label().into())
        .or_default()
        .update(client_id, revision, context)
}

/// Existing Core scopes. Suites are explicitly unavailable rather than being
/// turned into a workspace run or a guessed test-case identifier.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub enum TestScope {
    Workspace {},
    File {
        #[serde(rename = "relativeFilePath")]
        relative_file_path: String,
    },
    TestCase {
        identifier: String,
        #[serde(
            default,
            rename = "relativeFilePath",
            skip_serializing_if = "Option::is_none"
        )]
        relative_file_path: Option<String>,
    },
    Suite {
        identifier: String,
    },
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub enum ExecutionSelection {
    Run {
        #[serde(rename = "relativeFilePath")]
        relative_file_path: String,
        #[serde(default, rename = "userArguments")]
        user_arguments: Vec<String>,
    },
    Test {
        scope: TestScope,
    },
}

/// Core argv with a receipt covering package bytes, exact selection and scope.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeclarativeRunPlan {
    pub plugin_id: String,
    pub language_id: String,
    pub executable: Value,
    pub arguments: Vec<String>,
    pub working_directory: String,
    pub label: Option<String>,
    pub framework_id: Option<String>,
    /// Empty only for the legacy plan-only API without workspace context.
    pub identity: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeclarativeTests {
    pub items: Value,
    pub identity: String,
}

#[tauri::command]
pub async fn declarative_plugins_run_plan(
    app: AppHandle,
    window: WebviewWindow,
    plugin_id: String,
    language_id: String,
    relative_file_path: String,
    user_arguments: Vec<String>,
    context: Option<ExecutionContext>,
) -> Result<DeclarativeRunPlan, String> {
    let label = window.label().to_string();
    passive(move || {
        prepare(
            &app,
            &label,
            &plugin_id,
            &language_id,
            context.as_ref(),
            &ExecutionSelection::Run {
                relative_file_path,
                user_arguments,
            },
        )
    })
    .await
}

#[tauri::command]
pub async fn declarative_plugins_test_plan(
    app: AppHandle,
    window: WebviewWindow,
    plugin_id: String,
    language_id: String,
    workspace_path: String,
    scope: Option<TestScope>,
    context: Option<ExecutionContext>,
) -> Result<DeclarativeRunPlan, String> {
    let label = window.label().to_string();
    passive(move || {
        if context
            .as_ref()
            .is_some_and(|value| value.workspace_path != workspace_path)
        {
            return Err("plugin.execution.staleContext".into());
        }
        let selection = ExecutionSelection::Test {
            scope: scope.unwrap_or(TestScope::Workspace {}),
        };
        // API 1/2 plan callers retain workspace defaults, without a launch receipt.
        if context.is_none() {
            let _lease = app
                .state::<super::lifecycle::LifecycleState>()
                .acquire(&plugin_id)?;
            let package = super::launch::verified_package_by_id(&app, &plugin_id)?;
            let files =
                existing_root_markers(&package.manifest, &language_id, Path::new(&workspace_path));
            return expand_plan(
                &package.manifest,
                &plugin_id,
                &language_id,
                &selection,
                &files,
            );
        }
        prepare(
            &app,
            &label,
            &plugin_id,
            &language_id,
            context.as_ref(),
            &selection,
        )
    })
    .await
}

#[tauri::command]
pub async fn declarative_plugins_discover_tests(
    app: AppHandle,
    window: WebviewWindow,
    plugin_id: String,
    language_id: String,
    context: ExecutionContext,
) -> Result<DeclarativeTests, String> {
    let label = window.label().to_string();
    passive(move || {
        let _lease = app
            .state::<super::lifecycle::LifecycleState>()
            .acquire(&plugin_id)?;
        check_context(&app, &label, &context)?;
        let package = super::launch::verified_package_by_id(&app, &plugin_id)?;
        let files = inventory(Path::new(&context.workspace_path))?;
        let response = core_execute(
            "plugins.declarative.discoverTests",
            json!({
                "manifest": package.manifest, "languageID": language_id,
                "request": { "relativeProjectFilePaths": files },
            }),
        )?;
        core_ok(&response)?;
        let items = response["items"].clone();
        if !items.is_array() {
            return Err("plugin.execution.invalidPlan".into());
        }
        let identity = receipt(&app, &label, &context, &package, &files, &items)?;
        Ok(DeclarativeTests { items, identity })
    })
    .await
}

async fn passive<T: Send + 'static>(
    work: impl FnOnce() -> Result<T, String> + Send + 'static,
) -> Result<T, String> {
    tauri::async_runtime::spawn_blocking(work)
        .await
        .map_err(|error| error.to_string())?
}

async fn prepare_current(
    app: &AppHandle,
    label: &str,
    plugin: &str,
    language: &str,
    context: &ExecutionContext,
    selection: &ExecutionSelection,
) -> Result<DeclarativeRunPlan, String> {
    let (app, label, plugin, language, context, selection) = (
        app.clone(),
        label.to_string(),
        plugin.to_string(),
        language.to_string(),
        context.clone(),
        selection.clone(),
    );
    passive(move || prepare(&app, &label, &plugin, &language, Some(&context), &selection)).await
}

/// Re-expand the reviewed request against live inputs. Never execute argv or
/// an executable supplied by the frontend. The existing Run pipeline owns it.
#[tauri::command]
pub async fn declarative_plugins_start_execution(
    app: AppHandle,
    window: WebviewWindow,
    plugin_id: String,
    language_id: String,
    context: ExecutionContext,
    selection: ExecutionSelection,
    expected_identity: String,
    session_id: String,
    execution_id: String,
) -> Result<(), String> {
    if expected_identity.is_empty() || session_id.is_empty() || execution_id.is_empty() {
        return Err("plugin.execution.approvalRequired".into());
    }
    let _lease = app
        .state::<super::lifecycle::LifecycleState>()
        .acquire(&plugin_id)?;
    let plan = prepare_current(
        &app,
        window.label(),
        &plugin_id,
        &language_id,
        &context,
        &selection,
    )
    .await?;
    if plan.identity != expected_identity {
        return Err("plugin.execution.staleContext".into());
    }
    // Discovery may probe tools, so it happens only after explicit approval.
    let args = serde_json::from_value(json!({ "root": context.workspace_path,
        "executable": plan.executable, "workingDirectory": plan.working_directory,
    }))
    .map_err(|_| "plugin.execution.invalidPlan")?;
    let resolved =
        tauri::async_runtime::spawn_blocking(move || crate::run::run_resolve_launch(args))
            .await
            .map_err(|error| error.to_string())??;
    let checked = prepare_current(
        &app,
        window.label(),
        &plugin_id,
        &language_id,
        &context,
        &selection,
    )
    .await?;
    if checked.identity != expected_identity {
        return Err("plugin.execution.staleContext".into());
    }
    let admission_app = app.clone();
    let admission_label = window.label().to_string();
    let admission_context = context.clone();
    crate::run::run_start_process_with_admission(
        app.clone(),
        crate::run::StartProcessArgs {
            window_label: window.label().into(),
            session_id: session_id.clone(),
            execution_id: Some(execution_id.clone()),
            title: plan.label,
            background: false,
            executable: resolved.executable,
            arguments: plan.arguments,
            working_directory: resolved.working_directory,
            environment: resolved.environment,
        },
        move |start| {
            if admission_app.get_webview_window(&admission_label).is_none() {
                return Err("plugin.execution.staleContext".into());
            }
            let state = admission_app.state::<ExecutionState>();
            let epochs = state
                .0
                .lock()
                .map_err(|_| "plugin.execution.staleContext")?;
            if epochs
                .get(&admission_label)
                .and_then(|epoch| epoch.context.as_ref())
                != Some(&admission_context)
                || admission_app
                    .state::<super::lifecycle::LifecycleState>()
                    .blocked(&plugin_id)
            {
                return Err("plugin.execution.staleContext".into());
            }
            // Context revocation and spawn/publication share this lock. A revoke
            // before admission cannot launch, a revoke after it sees an owned tree.
            start()
        },
    )
    .await?;
    if let Err(error) = check_context(&app, window.label(), &context) {
        crate::run::run_stop_process(window.label().into(), session_id, Some(execution_id)).await?;
        return Err(error);
    }
    Ok(())
}

fn check_context(app: &AppHandle, label: &str, context: &ExecutionContext) -> Result<(), String> {
    if !(label == "main" || label.starts_with("workspace-"))
        || app.get_webview_window(label).is_none()
        || context.workspace_id.is_empty()
        || context.generation.is_empty()
        || !Path::new(&context.workspace_path).is_absolute()
        || !Path::new(&context.workspace_path).is_dir()
    {
        return Err("plugin.execution.staleContext".into());
    }
    if app
        .state::<ExecutionState>()
        .0
        .lock()
        .map_err(|_| "plugin.execution.staleContext")?
        .get(label)
        .and_then(|epoch| epoch.context.as_ref())
        != Some(context)
    {
        return Err("plugin.execution.staleContext".into());
    }
    Ok(())
}

fn prepare(
    app: &AppHandle,
    label: &str,
    plugin: &str,
    language: &str,
    context: Option<&ExecutionContext>,
    selection: &ExecutionSelection,
) -> Result<DeclarativeRunPlan, String> {
    let _lease = app
        .state::<super::lifecycle::LifecycleState>()
        .acquire(plugin)?;
    let package = super::launch::verified_package_by_id(app, plugin)?;
    let files = if let Some(context) = context {
        check_context(app, label, context)?;
        match selection {
            ExecutionSelection::Run {
                relative_file_path, ..
            } => {
                // File runs need no workspace scan. Core validates the path
                // before the host reads that exact source below.
                let _ = expand_plan(&package.manifest, plugin, language, selection, &[])?;
                vec![relative_file_path.clone()]
            }
            ExecutionSelection::Test { .. } => inventory(Path::new(&context.workspace_path))?,
        }
    } else {
        Vec::new()
    };
    validate_selection(selection, &files, context.is_some())?;
    let mut plan = expand_plan(&package.manifest, plugin, language, selection, &files)?;
    if let Some(context) = context {
        plan.identity = receipt(
            app,
            label,
            context,
            &package,
            &files,
            &json!({ "language": language, "selection": selection, "plan": plan,
                "source": source_identity(Path::new(&context.workspace_path), selection)?, }),
        )?;
    }
    Ok(plan)
}

fn existing_root_markers(manifest: &Value, language: &str, root: &Path) -> Vec<String> {
    let mut markers: Vec<String> = manifest["executionProviders"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|provider| provider["languageID"] == language)
        .flat_map(|provider| {
            provider["test"]["projectMarkers"]
                .as_array()
                .into_iter()
                .flatten()
        })
        .filter_map(Value::as_str)
        .filter(|marker| root.join(marker).is_file())
        .map(str::to_string)
        .collect();
    markers.sort();
    markers.dedup();
    markers
}

fn source_identity(root: &Path, selection: &ExecutionSelection) -> Result<Value, String> {
    let relative = match selection {
        ExecutionSelection::Run {
            relative_file_path, ..
        } => Some(relative_file_path),
        ExecutionSelection::Test {
            scope: TestScope::File { relative_file_path },
        } => Some(relative_file_path),
        ExecutionSelection::Test {
            scope: TestScope::TestCase {
                relative_file_path, ..
            },
        } => relative_file_path.as_ref(),
        _ => None,
    };
    let Some(relative) = relative else {
        return Ok(Value::Null);
    };
    let root = root.canonicalize().map_err(|_| "plugin.path.invalid")?;
    let mut component_path = root.clone();
    for component in Path::new(relative).components() {
        let Component::Normal(part) = component else {
            return Err("plugin.path.invalid".into());
        };
        component_path.push(part);
        if is_link(&std::fs::symlink_metadata(&component_path).map_err(|_| "plugin.path.invalid")?)
        {
            return Err("plugin.path.invalid".into());
        }
    }
    let path = root.join(relative);
    let metadata = std::fs::symlink_metadata(&path).map_err(|_| "plugin.path.invalid")?;
    if !metadata.is_file()
        || is_link(&metadata)
        || !path
            .canonicalize()
            .map_err(|_| "plugin.path.invalid")?
            .starts_with(&root)
    {
        return Err("plugin.path.invalid".into());
    }
    const MAX_SOURCE_BYTES: u64 = 32 * 1024 * 1024;
    let mut bytes = Vec::new();
    std::fs::File::open(path)
        .map_err(|_| "plugin.execution.workspaceReadFailed")?
        .take(MAX_SOURCE_BYTES + 1)
        .read_to_end(&mut bytes)
        .map_err(|_| "plugin.execution.workspaceReadFailed")?;
    if bytes.len() as u64 > MAX_SOURCE_BYTES {
        return Err("plugin.execution.workspaceLimit".into());
    }
    Ok(json!({ "path": relative, "sha256": format!("{:x}", Sha256::digest(bytes)) }))
}

fn validate_selection(
    selection: &ExecutionSelection,
    files: &[String],
    require_file: bool,
) -> Result<(), String> {
    let path = match selection {
        ExecutionSelection::Run {
            relative_file_path, ..
        } => Some(relative_file_path),
        ExecutionSelection::Test {
            scope: TestScope::File { relative_file_path },
        } => Some(relative_file_path),
        ExecutionSelection::Test {
            scope: TestScope::TestCase {
                relative_file_path, ..
            },
        } => relative_file_path.as_ref(),
        ExecutionSelection::Test {
            scope: TestScope::Suite { .. },
        } => return Err("plugin.execution.unavailable".into()),
        _ => None,
    };
    if let Some(path) = path {
        if require_file && !files.contains(path) {
            return Err("plugin.path.invalid".into());
        }
    }
    Ok(())
}

fn receipt(
    app: &AppHandle,
    label: &str,
    context: &ExecutionContext,
    package: &super::ScannedPackage,
    files: &[String],
    output: &Value,
) -> Result<String, String> {
    check_context(app, label, context)?;
    if app
        .state::<super::lifecycle::LifecycleState>()
        .blocked(&package.entry.plugin_id)
    {
        return Err("plugin.execution.staleContext".into());
    }
    let current = super::launch::verified_package_by_id(app, &package.entry.plugin_id)?;
    if current.root != package.root
        || current.manifest != package.manifest
        || current.entry.version != package.entry.version
    {
        return Err("plugin.execution.packageChanged".into());
    }
    let digest =
        super::signature::content_digest(&current.root).map_err(|error| error.message())?;
    let bytes = serde_json::to_vec(&json!({
        "window": label, "context": context,
        "root": Path::new(&context.workspace_path).canonicalize().map_err(|_| "plugin.path.invalid")?,
        "package": digest, "manifest": current.manifest, "files": files,
        "workspaceFiles": inventory_identity(Path::new(&context.workspace_path), files)?, "output": output,
    })).map_err(|error| error.to_string())?;
    Ok(format!("{:x}", Sha256::digest(bytes)))
}

/// Filesystem revision facts only. Actual test identities/argv stay in Core.
fn inventory_identity(root: &Path, files: &[String]) -> Result<String, String> {
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut hash = Sha256::new();
    for relative in files {
        if Instant::now() >= deadline {
            return Err("plugin.execution.workspaceLimit".into());
        }
        let meta = std::fs::symlink_metadata(root.join(relative))
            .map_err(|_| "plugin.execution.staleContext")?;
        if !meta.is_file() || is_link(&meta) {
            return Err("plugin.execution.staleContext".into());
        }
        let modified = meta
            .modified()
            .map_err(|_| "plugin.execution.workspaceReadFailed")?
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|_| "plugin.execution.workspaceReadFailed")?;
        hash.update(
            serde_json::to_vec(&json!([
                relative,
                meta.len(),
                modified.as_secs(),
                modified.subsec_nanos()
            ]))
            .map_err(|error| error.to_string())?,
        );
    }
    Ok(format!("{:x}", hash.finalize()))
}

/// Bounded filesystem facts, not a test matcher. Core alone decides which
/// files/markers are tests. Reparse points are excluded; selecting one fails.
fn inventory(root: &Path) -> Result<Vec<String>, String> {
    let root = root.canonicalize().map_err(|_| "plugin.path.invalid")?;
    let mut pending = vec![(root.clone(), 0usize)];
    let mut files = Vec::new();
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut count = 0usize;
    while let Some((directory, depth)) = pending.pop() {
        if depth > 64 {
            return Err("plugin.execution.workspaceLimit".into());
        }
        for entry in
            std::fs::read_dir(directory).map_err(|_| "plugin.execution.workspaceReadFailed")?
        {
            if Instant::now() >= deadline {
                return Err("plugin.execution.workspaceLimit".into());
            }
            count += 1;
            if count > 100_000 {
                return Err("plugin.execution.workspaceLimit".into());
            }
            let entry = entry.map_err(|_| "plugin.execution.workspaceReadFailed")?;
            let meta = std::fs::symlink_metadata(entry.path())
                .map_err(|_| "plugin.execution.workspaceReadFailed")?;
            if is_link(&meta) {
                continue;
            }
            if meta.is_dir() {
                if entry.file_name() != ".git" {
                    pending.push((entry.path(), depth + 1));
                }
            } else if meta.is_file() {
                let path = entry.path();
                let relative = path
                    .strip_prefix(&root)
                    .map_err(|_| "plugin.path.invalid")?;
                if relative
                    .components()
                    .any(|part| !matches!(part, Component::Normal(_)))
                {
                    return Err("plugin.path.invalid".into());
                }
                files.push(
                    relative
                        .to_str()
                        .ok_or("plugin.path.invalid")?
                        .replace('\\', "/"),
                );
            }
        }
    }
    files.sort();
    files.dedup();
    Ok(files)
}

fn is_link(meta: &std::fs::Metadata) -> bool {
    #[cfg(windows)]
    {
        use std::os::windows::fs::MetadataExt;
        meta.file_attributes() & 0x400 != 0
    }
    #[cfg(not(windows))]
    {
        meta.file_type().is_symlink()
    }
}

fn core_ok(response: &Value) -> Result<(), String> {
    if response["status"] != "ok" {
        return Err(response["error"]["code"]
            .as_str()
            .unwrap_or("plugin.execution.invalidPlan")
            .into());
    }
    Ok(())
}

fn expand_plan(
    manifest: &Value,
    plugin: &str,
    language: &str,
    selection: &ExecutionSelection,
    files: &[String],
) -> Result<DeclarativeRunPlan, String> {
    validate_selection(selection, files, false)?;
    let (command, request) = match selection {
        ExecutionSelection::Run {
            relative_file_path,
            user_arguments,
        } => (
            "plugins.declarative.runPlan",
            json!({ "relativeFilePath": relative_file_path, "arguments": user_arguments }),
        ),
        ExecutionSelection::Test { scope } => (
            "plugins.declarative.testPlan",
            json!({ "scope": scope, "relativeProjectFilePaths": files }),
        ),
    };
    let response = core_execute(
        command,
        json!({ "manifest": manifest, "languageID": language, "request": request }),
    )?;
    core_ok(&response)?;
    let body = &response["plan"];
    let executable = body["executable"].clone();
    let arguments = serde_json::from_value(body["arguments"].clone())
        .map_err(|_| "plugin.execution.invalidPlan")?;
    let working_directory = body["workingDirectory"]
        .as_str()
        .ok_or("plugin.execution.invalidPlan")?
        .to_string();
    if !executable.is_object() {
        return Err("plugin.execution.invalidPlan".into());
    }
    Ok(DeclarativeRunPlan {
        plugin_id: plugin.into(),
        language_id: language.into(),
        executable,
        arguments,
        working_directory,
        label: body["label"].as_str().map(str::to_string),
        framework_id: body["frameworkID"].as_str().map(str::to_string),
        identity: String::new(),
    })
}
