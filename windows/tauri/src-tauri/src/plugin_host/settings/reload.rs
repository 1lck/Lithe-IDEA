//! Project reload uses the existing build owners. A native project claim,
//! saved settings and accepted package bind every read and model publication.
use super::*;
use serde::{Deserialize, Serialize};
use std::sync::atomic::{AtomicU64, Ordering};

struct WindowIncarnation(u64);
impl tauri::Resource for WindowIncarnation {}
static NEXT_WINDOW: AtomicU64 = AtomicU64::new(1);

fn table_incarnation(table: &mut tauri::ResourceTable) -> u64 {
    if let Some(id) = table
        .names()
        .find_map(|(id, _)| table.get::<WindowIncarnation>(id).ok().map(|owner| owner.0))
    {
        return id;
    }
    let id = NEXT_WINDOW.fetch_add(1, Ordering::Relaxed);
    table.add(WindowIncarnation(id));
    id
}

fn window_incarnation(window: &tauri::WebviewWindow) -> u64 {
    table_incarnation(&mut window.as_ref().window().resources_table())
}

fn check_incarnation(current: u64, expected: u64) -> Result<(), String> {
    if current != expected {
        return Err("plugin.settings.staleContext".into());
    }
    Ok(())
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectContext {
    pub workspace_id: String,
    pub registration: u64,
    pub window_incarnation: u64,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Receipt {
    pub plugin_id: String,
    pub workspace_path: String,
    pub expected_identity: String,
    pub expected_package_identity: String,
    pub project: ProjectContext,
}

fn registration(app: &AppHandle, label: &str, root: &str, id: &str) -> Result<u64, String> {
    if !(label == "main" || label.starts_with("workspace-"))
        || app.get_webview_window(label).is_none()
    {
        return Err("plugin.settings.staleContext".into());
    }
    let identity = crate::project_window_registry::ProjectWindowRegistry::identity(Path::new(root))
        .map_err(|_| "plugin.settings.staleContext")?;
    app.state::<crate::project_windows::ProjectWindows>()
        .0
        .blocking_lock()
        .registration(&identity, label, id)
        .ok_or_else(|| "plugin.settings.staleContext".into())
}

pub(super) fn bind(
    app: &AppHandle,
    window: &tauri::WebviewWindow,
    root: &str,
    workspace_id: Option<String>,
    mut snapshot: SettingSnapshot,
) -> Result<SettingSnapshot, String> {
    if !root.is_empty() {
        if let Some(workspace_id) = workspace_id {
            snapshot.reload_context = Some(ProjectContext {
                registration: registration(app, window.label(), root, &workspace_id)?,
                workspace_id,
                window_incarnation: window_incarnation(window),
            });
        }
    }
    Ok(snapshot)
}

pub(crate) fn check_owner(app: &AppHandle, label: &str, receipt: &Receipt) -> Result<(), String> {
    let window = app
        .get_webview_window(label)
        .ok_or("plugin.settings.staleContext")?;
    check_caller(&window, receipt)?;
    let current = registration(
        app,
        label,
        &receipt.workspace_path,
        &receipt.project.workspace_id,
    )?;
    if current != receipt.project.registration {
        return Err("plugin.settings.staleContext".into());
    }
    Ok(())
}

pub(super) fn check_caller(window: &tauri::WebviewWindow, receipt: &Receipt) -> Result<(), String> {
    check_incarnation(
        window_incarnation(window),
        receipt.project.window_incarnation,
    )
}

pub(crate) fn check(
    app: &AppHandle,
    label: &str,
    receipt: &Receipt,
) -> Result<SettingSnapshot, String> {
    check_owner(app, label, receipt)?;
    let snapshot = snapshot::read(app, &receipt.plugin_id, &receipt.workspace_path)?;
    validate(&snapshot, receipt)?;
    check_owner(app, label, receipt)?;
    Ok(snapshot)
}

fn validate(snapshot: &SettingSnapshot, receipt: &Receipt) -> Result<(), String> {
    if snapshot.package_identity != receipt.expected_package_identity {
        return Err("plugin.settings.packageChanged".into());
    }
    if snapshot.identity != receipt.expected_identity {
        return Err("plugin.settings.conflict".into());
    }
    Ok(())
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProjectReload {
    pub view: super::super::build_registry::BuildView,
}

#[tauri::command]
pub async fn declarative_plugins_prepare_settings_reload_model(
    app: AppHandle,
    window: tauri::WebviewWindow,
    receipt: Receipt,
    build_system_id: String,
    root: String,
    runtime_executables: BTreeMap<String, String>,
) -> Result<super::super::build::BuildModelReview, String> {
    check_caller(&window, &receipt)?;
    super::super::build::prepare_settings_reload_model(
        app,
        window.label().into(),
        receipt,
        build_system_id,
        root,
        runtime_executables,
    )
    .await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reload_receipt_is_bound_to_the_actual_window_resource_table() {
        let mut original = tauri::ResourceTable::default();
        let mut replacement = tauri::ResourceTable::default();
        let old = table_incarnation(&mut original);
        assert_eq!(table_incarnation(&mut original), old);
        let next = table_incarnation(&mut replacement);
        assert_ne!(old, next);
        assert!(check_incarnation(old, old).is_ok());
        assert_eq!(
            check_incarnation(next, old).unwrap_err(),
            "plugin.settings.staleContext"
        );
        assert!(check_incarnation(next, next).is_ok());
    }
}
