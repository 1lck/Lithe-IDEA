//! Native settings publication. Private XML stays in a bounded, window-owned
//! prepare/commit transaction and never crosses WebView or Provider RPC.

use super::{launch, lifecycle::LifecycleState, scan::core_execute, settings, store};
use lithe_project::native_configuration::{
    self, NativeConfigurationError, PreparedNativeConfiguration,
};
use serde::Serialize;
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    path::PathBuf,
    sync::Mutex,
    time::{Duration, Instant},
};
use tauri::{AppHandle, Manager, Window};

const MAX_PREPARED_WRITES: usize = 8;
const PREPARATION_LIFETIME: Duration = Duration::from_secs(60);

struct PreparedWrite {
    plugin_id: String,
    workspace: String,
    root: String,
    inputs: Value,
    write: PreparedNativeConfiguration,
    created: Instant,
}

#[derive(Default)]
struct PendingWrites {
    writes: HashMap<(String, String), PreparedWrite>,
    window_generations: HashMap<String, u64>,
}
#[derive(Default)]
pub struct NativeConfigurationWrites(Mutex<PendingWrites>);

#[derive(Debug, Serialize)]
pub struct Failure {
    code: &'static str,
    message: &'static str,
}
impl From<NativeConfigurationError> for Failure {
    fn from(error: NativeConfigurationError) -> Self {
        let code = match error {
            NativeConfigurationError::Conflict => "build.configuration.conflict",
            NativeConfigurationError::ReadOnly => "build.configuration.readOnly",
            NativeConfigurationError::Unreadable => "build.configuration.unreadable",
            NativeConfigurationError::Invalid => "build.configuration.invalid",
        };
        Self {
            code,
            message: code,
        }
    }
}
impl From<String> for Failure {
    fn from(_: String) -> Self {
        invalid()
    }
}
fn invalid() -> Failure {
    NativeConfigurationError::Invalid.into()
}
fn conflict() -> Failure {
    NativeConfigurationError::Conflict.into()
}

/// Read-only source reconciliation. Return paths and a changed bit, never XML.
#[tauri::command]
pub async fn declarative_plugins_build_check_configuration(
    app: AppHandle,
    plugin_id: String,
    build_system_id: String,
    sources: Value,
) -> Result<Value, Failure> {
    crate::blocking::run_blocking_result(move || {
        let _lease = app
            .state::<LifecycleState>()
            .acquire(&plugin_id)
            .map_err(|_| invalid())?;
        let package = launch::package_by_id(&app, &plugin_id).ok_or_else(invalid)?;
        let declared = package.manifest["buildSystems"]
            .as_array()
            .into_iter()
            .flatten()
            .any(|system| {
                system["id"] == build_system_id && system["configuration"]["source"] == "provider"
            });
        if !declared {
            return Err(invalid());
        }
        native_configuration::check_sources(&sources).map_err(Failure::from)
    })
    .await
}

/// Returns only a changed bit. XML is retained natively until the caller checks
/// its workspace/configuration generation and explicitly commits or cancels.
#[tauri::command]
pub async fn declarative_plugins_build_prepare_configuration(
    app: AppHandle,
    window: Window,
    plugin_id: String,
    build_system_id: String,
    workspace_path: String,
    root: String,
    operation_id: String,
    snapshot: Value,
    edits: Value,
) -> Result<bool, Failure> {
    if operation_id.is_empty()
        || operation_id.len() > 128
        || operation_id.chars().any(char::is_control)
    {
        return Err(invalid());
    }
    let window_label = window.label().to_owned();
    let window_generation = *app
        .state::<NativeConfigurationWrites>()
        .0
        .lock()
        .map_err(|_| invalid())?
        .window_generations
        .get(&window_label)
        .unwrap_or(&0);
    crate::blocking::run_blocking_result(move || {
        let _lease = app
            .state::<LifecycleState>()
            .acquire(&plugin_id)
            .map_err(|_| conflict())?;
        let package = launch::package_by_id(&app, &plugin_id).ok_or_else(conflict)?;
        let inputs = current_inputs(&app, &plugin_id, &workspace_path, &root)?;
        let write = native_configuration::prepare(
            &package.manifest,
            &build_system_id,
            &snapshot,
            &edits,
            &immutable_roots(&app)?,
        )?;
        let Some(write) = write else {
            return Ok(false);
        };
        let state = app.state::<NativeConfigurationWrites>();
        let mut writes = state.0.lock().map_err(|_| invalid())?;
        if *writes.window_generations.get(&window_label).unwrap_or(&0) != window_generation {
            return Err(conflict());
        }
        writes
            .writes
            .retain(|_, write| write.created.elapsed() < PREPARATION_LIFETIME);
        let owner = (window_label, operation_id);
        if writes.writes.len() >= MAX_PREPARED_WRITES || writes.writes.contains_key(&owner) {
            return Err(invalid());
        }
        writes.writes.insert(
            owner,
            PreparedWrite {
                plugin_id,
                workspace: workspace_path,
                root,
                inputs,
                write,
                created: Instant::now(),
            },
        );
        Ok(true)
    })
    .await
}

/// Publication is the final synchronous native transaction. Package/settings
/// changes, expired preparation, disk edits and link changes all reject it.
#[tauri::command]
pub async fn declarative_plugins_build_commit_configuration(
    app: AppHandle,
    window: Window,
    operation_id: String,
) -> Result<(), Failure> {
    let window_label = window.label().to_owned();
    crate::blocking::run_blocking_result(move || {
        let prepared = app
            .state::<NativeConfigurationWrites>()
            .0
            .lock()
            .map_err(|_| invalid())?
            .writes
            .remove(&(window_label, operation_id))
            .ok_or_else(conflict)?;
        if prepared.created.elapsed() >= PREPARATION_LIFETIME {
            return Err(conflict());
        }
        let _lease = app
            .state::<LifecycleState>()
            .acquire(&prepared.plugin_id)
            .map_err(|_| conflict())?;
        if current_inputs(
            &app,
            &prepared.plugin_id,
            &prepared.workspace,
            &prepared.root,
        )? != prepared.inputs
        {
            return Err(conflict());
        }
        prepared
            .write
            .commit(&immutable_roots(&app)?)
            .map_err(Into::into)
    })
    .await
}

#[tauri::command]
pub fn declarative_plugins_build_cancel_configuration(
    app: AppHandle,
    window: Window,
    operation_id: String,
) -> Result<(), Failure> {
    app.state::<NativeConfigurationWrites>()
        .0
        .lock()
        .map_err(|_| invalid())?
        .writes
        .remove(&(window.label().to_owned(), operation_id));
    Ok(())
}

pub fn close_window(app: &AppHandle, label: &str) {
    if let Ok(mut writes) = app.state::<NativeConfigurationWrites>().0.lock() {
        *writes
            .window_generations
            .entry(label.to_owned())
            .or_default() += 1;
        writes.writes.retain(|(window, _), _| window != label);
    }
}

pub fn forget_plugin(app: &AppHandle, plugin: &str) {
    if let Ok(mut pending) = app.state::<NativeConfigurationWrites>().0.lock() {
        pending.writes.retain(|_, write| write.plugin_id != plugin);
    }
}

fn current_inputs(
    app: &AppHandle,
    plugin: &str,
    workspace: &str,
    root: &str,
) -> Result<Value, Failure> {
    let package = launch::package_by_id(app, plugin).ok_or_else(conflict)?;
    let layers = settings::load_layers(app, plugin, workspace).map_err(|_| invalid())?;
    let paths = core_execute(
        "runConfig.projectToolchain",
        json!({"root":workspace,"path":root}),
    )
    .map_err(|_| invalid())?;
    Ok(
        json!({"package":package.root,"manifest":package.manifest,"global":layers.global,"project":layers.project,"paths":paths}),
    )
}

fn immutable_roots(app: &AppHandle) -> Result<Vec<PathBuf>, Failure> {
    let executable = std::env::current_exe().map_err(|_| invalid())?;
    let mut roots = vec![
        app.path().resource_dir().map_err(|_| invalid())?,
        executable.parent().ok_or_else(invalid)?.to_owned(),
        store::install_root(app).map_err(|_| invalid())?,
    ];
    roots.extend(
        app.state::<super::PluginHostState>()
            .packages()
            .into_iter()
            .map(|package| package.root),
    );
    Ok(roots)
}
