//! Receipt-bound native child shells for the existing private plugin pages.
//! The workbench owns geometry; package code retains only its existing bridge.

use super::*;
use same_file::Handle;
use sha2::{Digest, Sha256};
use std::sync::Arc;

const MAX_REQUEST_ID_BYTES: usize = 96;
const MAX_MOUNT_ID_BYTES: usize = 128;
const MAX_WORKSPACE_ID_BYTES: usize = 1024;
const MAX_WORKSPACE_PATH_BYTES: usize = 32768;
const MAX_MOUNT_SLOTS: usize = 128;

#[derive(Clone, Debug, PartialEq)]
pub(super) struct MountOwner {
    pub id: String,
    package_identity: String,
    registration: u64,
    directory: Arc<Handle>,
    sequence: u64,
    revision: u64,
}

#[derive(Clone, Copy, Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct DockBounds {
    x: f64,
    y: f64,
    width: f64,
    height: f64,
}

#[derive(Debug, Clone, Copy, PartialEq)]
struct PhysicalBounds {
    x: i32,
    y: i32,
    width: u32,
    height: u32,
}

impl DockBounds {
    fn normalize(self, client: tauri::PhysicalSize<u32>) -> Result<PhysicalBounds, String> {
        let [x, y, width, height] = [self.x, self.y, self.width, self.height];
        if [x, y, width, height]
            .iter()
            .any(|value| !value.is_finite() || *value < 0.0 || *value > i32::MAX as f64)
            || width <= 0.0
            || height <= 0.0
            || x >= client.width as f64
            || y >= client.height as f64
            || client.width > i32::MAX as u32
            || client.height > i32::MAX as u32
            // CSS viewport rounding at fractional DPI can differ by less than
            // one physical pixel. Permit that edge only, then clip safely.
            || x + width > client.width as f64 + 1.0
            || y + height > client.height as f64 + 1.0
        {
            return Err(bridge_error(
                "plugin.web.invalidRequest",
                "invalid dock bounds",
            ));
        }
        let left = (x.round() as u32).min(client.width.saturating_sub(1));
        let top = (y.round() as u32).min(client.height.saturating_sub(1));
        let right = ((x + width).round() as u32).min(client.width);
        let bottom = ((y + height).round() as u32).min(client.height);
        Ok(PhysicalBounds {
            x: left as i32,
            y: top as i32,
            width: right.saturating_sub(left).max(1),
            height: bottom.saturating_sub(top).max(1),
        })
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MountReceipt {
    mount_id: String,
}

/// Native child geometry is transient workbench state, not a restorable window.
pub fn is_docked_label(label: &str) -> bool {
    label.starts_with("plugin-web-") && label.contains("--m")
}

pub(super) fn package_identity(package: &ScannedPackage) -> Result<String, String> {
    let digest = super::super::signature::content_digest(&package.root)
        .map_err(|error| error.message().to_string())?;
    Ok(package_identity_for(
        &package.root,
        &package.entry.source,
        &package.entry.version,
        &digest,
    ))
}

fn package_identity_for(root: &Path, source: &str, version: &str, digest: &str) -> String {
    // Match the native contribution catalog's complete package identity.
    format!(
        "{:x}",
        Sha256::digest(
            json!({"root":root,"source":source,"version":version,"digest":digest})
                .to_string()
                .as_bytes()
        )
    )
}

fn product_host(label: &str) -> Result<(), String> {
    if label == "main" || label.starts_with("workspace-") {
        Ok(())
    } else {
        Err(bridge_error(
            "plugin.web.forbidden",
            "dock caller is not a product window",
        ))
    }
}

fn valid_request_id(id: &str) -> bool {
    !id.is_empty()
        && id.len() <= MAX_MOUNT_ID_BYTES
        && id
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'-' | b'_'))
}

async fn bind_project(
    app: &AppHandle,
    caller: &tauri::WebviewWindow,
    workspace: &str,
    root: &str,
) -> Result<(Arc<Handle>, u64), String> {
    product_host(caller.label())?;
    if workspace.is_empty()
        || workspace.len() > MAX_WORKSPACE_ID_BYTES
        || workspace.chars().any(char::is_control)
        || root.len() > MAX_WORKSPACE_PATH_BYTES
        || root.contains('\0')
        || !Path::new(root).is_absolute()
    {
        return Err(bridge_error(
            "plugin.web.invalidRequest",
            "invalid workspace identity",
        ));
    }
    let root = PathBuf::from(root);
    let directory = tauri::async_runtime::spawn_blocking(move || {
        crate::project_window_registry::ProjectWindowRegistry::identity(&root)
            .map_err(|_| bridge_error("plugin.web.forbidden", "workspace is unavailable"))
    })
    .await
    .map_err(|error| error.to_string())??;
    let registration = app
        .state::<crate::project_windows::ProjectWindows>()
        .0
        .lock()
        .await
        .registration(&directory, caller.label(), workspace)
        .ok_or_else(|| {
            bridge_error(
                "plugin.web.forbidden",
                "workspace does not belong to this window",
            )
        })?;
    Ok((Arc::new(directory), registration))
}

fn same_slot(owner: &PageOwner, host: &str, workspace: &str, plugin: &str, window: &str) -> bool {
    owner.host_label == host
        && owner.workspace_id == workspace
        && owner.plugin_id == plugin
        && owner.window_id == window
}

fn cleanup_error(mount_id: &str, error: String) -> String {
    json!({"code":"plugin.web.cleanupFailed", "mountId":mount_id, "message":error}).to_string()
}

fn closing_receipt(state: &WebPageHostState, owner: &PageOwner) -> Option<String> {
    let closing = state.closing_owners.lock().expect("closing page owners");
    let mut matches: Vec<_> = closing
        .values()
        .filter(|other| {
            same_slot(
                other,
                &owner.host_label,
                &owner.workspace_id,
                &owner.plugin_id,
                &owner.window_id,
            )
        })
        .filter_map(|other| other.mount.as_ref().map(|mount| mount.id.clone()))
        .collect();
    matches.sort();
    matches.into_iter().next()
}

/// Recheck native registration after every asynchronous page-creation boundary.
pub(super) async fn check_mount(app: &AppHandle, owner: &PageOwner) -> Result<(), String> {
    let mount = owner.mount.as_ref().ok_or("plugin.web.staleMount")?;
    check_request(&app.state::<WebPageHostState>(), owner)?;
    let current_registration = app
        .state::<crate::project_windows::ProjectWindows>()
        .0
        .lock()
        .await
        .registration(&mount.directory, &owner.host_label, &owner.workspace_id);
    if current_registration != Some(mount.registration)
        || app.get_webview_window(&owner.host_label).is_none()
        || app
            .state::<super::super::lifecycle::LifecycleState>()
            .blocked(&owner.plugin_id)
    {
        return Err(bridge_error(
            "plugin.web.staleMount",
            "dock workspace was released",
        ));
    }
    check_request(&app.state::<WebPageHostState>(), owner)?;
    let state = app.state::<WebPageHostState>();
    let owners = state.owners.lock().expect("page owners");
    let current = owners
        .get(&owned_label(owner))
        .filter(|current| {
            current.mount.as_ref().is_some_and(|current| {
                current.id == mount.id
                    && current.package_identity == mount.package_identity
                    && current.registration == mount.registration
            })
        })
        .filter(|current| current.workspace_generation == owner.workspace_generation)
        .filter(|current| {
            current.workspace_generation
                == workspace_generation(&state, &current.host_label, &current.workspace_id)
        });
    if current.is_none() {
        return Err(bridge_error(
            "plugin.web.staleMount",
            "dock ownership was revoked",
        ));
    }
    Ok(())
}

fn reserve_request(state: &WebPageHostState, owner: &PageOwner) -> Result<(), String> {
    let mount = owner.mount.as_ref().ok_or("plugin.web.staleMount")?;
    let slot = state_label(owner);
    let mut requests = state.mount_requests.lock().expect("page mount requests");
    // Workspace close increments the generation before taking this request
    // lock to clear slots. A verification completing afterwards cannot refill
    // that closed scope and consume the global slot budget.
    if owner.workspace_generation
        != workspace_generation(state, &owner.host_label, &owner.workspace_id)
    {
        return Err("plugin.web.staleMount".into());
    }
    if requests
        .get(&slot)
        .is_some_and(|sequence| *sequence > mount.sequence)
    {
        return Err("plugin.web.staleMount".into());
    }
    if !requests.contains_key(&slot) && requests.len() >= MAX_MOUNT_SLOTS {
        return Err(bridge_error(
            "plugin.web.busy",
            "too many mounted tool-window slots",
        ));
    }
    requests.insert(slot, mount.sequence);
    Ok(())
}

fn forget_request(state: &WebPageHostState, owner: &PageOwner) {
    let Some(mount) = &owner.mount else { return };
    let slot = state_label(owner);
    let mut requests = state.mount_requests.lock().expect("page mount requests");
    if requests.get(&slot) == Some(&mount.sequence) {
        requests.remove(&slot);
    }
}

fn check_request(state: &WebPageHostState, owner: &PageOwner) -> Result<(), String> {
    let mount = owner.mount.as_ref().ok_or("plugin.web.staleMount")?;
    let current = state
        .mount_requests
        .lock()
        .expect("page mount requests")
        .get(&state_label(owner))
        .copied();
    if current != Some(mount.sequence)
        || owner.workspace_generation
            != workspace_generation(state, &owner.host_label, &owner.workspace_id)
    {
        return Err("plugin.web.staleMount".into());
    }
    Ok(())
}

/// Creates an inert WS_CHILD shell. Only the first current layout shows it.
#[tauri::command]
pub async fn declarative_plugins_mount_web_window(
    app: AppHandle,
    caller: tauri::WebviewWindow,
    plugin_id: String,
    window_id: String,
    workspace_id: String,
    workspace_path: String,
    expected_package_identity: String,
    appearance: WebPageAppearance,
    mount_id: String,
    bounds: DockBounds,
) -> Result<MountReceipt, String> {
    #[cfg(not(windows))]
    return Err("plugin.web.dockingUnavailable".into());
    if !valid_request_id(&mount_id)
        || mount_id.len() > MAX_REQUEST_ID_BYTES
        || expected_package_identity.is_empty()
    {
        return Err(bridge_error(
            "plugin.web.invalidRequest",
            "invalid dock mount identity",
        ));
    }
    // Capture order and workspace generation before the first await. Package
    // verification can finish out of order, but an older request stays older.
    let generation = OPEN_PAGE_SEQUENCE.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    let workspace_generation = workspace_generation(
        &app.state::<WebPageHostState>(),
        caller.label(),
        &workspace_id,
    );
    bounds.normalize(caller.inner_size().map_err(|error| error.to_string())?)?;
    let (directory, registration) =
        bind_project(&app, &caller, &workspace_id, &workspace_path).await?;
    let _native_page = app
        .state::<super::super::lifecycle::LifecycleState>()
        .acquire(&plugin_id)?;
    let catalog_app = app.clone();
    let catalog_plugin = plugin_id.clone();
    let catalog_window = window_id.clone();
    let window = tauri::async_runtime::spawn_blocking(move || {
        let package = super::super::launch::verified_package_by_id(&catalog_app, &catalog_plugin)?;
        let identity = package_identity(&package)?;
        if identity != expected_package_identity {
            return Err(bridge_error(
                "plugin.web.staleMount",
                "plugin package changed",
            ));
        }
        let mut windows = Vec::new();
        collect_web_windows(&package, &mut windows);
        let mut window = windows
            .into_iter()
            .find(|window| window.window_id == catalog_window)
            .ok_or_else(|| {
                bridge_error("plugin.web.forbidden", "web tool window is not declared")
            })?;
        window.package_identity = identity;
        Ok::<_, String>(window)
    })
    .await
    .map_err(|error| error.to_string())??;
    let id = format!("{mount_id}-{generation:x}");
    let owner = PageOwner {
        generation,
        workspace_generation,
        host_label: caller.label().into(),
        workspace_id,
        workspace_path,
        plugin_id,
        window_id,
        state_id: String::new(),
        mount: Some(MountOwner {
            id: id.clone(),
            package_identity: window.package_identity.clone(),
            registration,
            directory,
            sequence: generation,
            revision: 0,
        }),
    };
    reserve_request(&app.state::<WebPageHostState>(), &owner)?;
    // Check the native registration before touching an existing slot. An old
    // create finishing after release/reclaim cannot close its replacement.
    let current_registration = app
        .state::<crate::project_windows::ProjectWindows>()
        .0
        .lock()
        .await
        .registration(
            &owner.mount.as_ref().expect("mount owner").directory,
            caller.label(),
            &owner.workspace_id,
        );
    if current_registration != Some(registration) {
        forget_request(&app.state::<WebPageHostState>(), &owner);
        return Err("plugin.web.staleMount".into());
    }
    if let Err(error) = check_request(&app.state::<WebPageHostState>(), &owner) {
        forget_request(&app.state::<WebPageHostState>(), &owner);
        return Err(error);
    }
    if let Err(error) = close_matching_pages(
        &app,
        |other| {
            same_slot(
                other,
                &owner.host_label,
                &owner.workspace_id,
                &owner.plugin_id,
                &owner.window_id,
            ) && other
                .mount
                .as_ref()
                .is_none_or(|mount| mount.sequence < generation)
        },
        false,
    ) {
        return Err(
            match closing_receipt(&app.state::<WebPageHostState>(), &owner) {
                Some(receipt) => cleanup_error(&receipt, error),
                // A pre-existing floating window has no mount receipt. Keep it in
                // native pending closes; retrying mount retries that close first.
                None => bridge_error("plugin.web.closeFailed", error),
            },
        );
    }
    let view = open_page(&app, &caller, owner.clone(), window, appearance).await?;
    if let Err(error) = check_mount(&app, &owner).await.and_then(|_| {
        apply_bounds(
            &view,
            bounds.normalize(caller.inner_size().map_err(|error| error.to_string())?)?,
        )
    }) {
        return Err(cleanup_failed_open(&app, &owner, error));
    }
    Ok(MountReceipt { mount_id: id })
}

fn find_mount(
    owners: &HashMap<String, PageOwner>,
    host: &str,
    workspace: &str,
    plugin: &str,
    window: &str,
    mount_id: &str,
) -> Result<PageOwner, String> {
    owners
        .values()
        .find(|owner| {
            same_slot(owner, host, workspace, plugin, window)
                && owner
                    .mount
                    .as_ref()
                    .is_some_and(|mount| mount.id == mount_id)
        })
        .cloned()
        .ok_or_else(|| bridge_error("plugin.web.staleMount", "dock ownership was revoked"))
}

fn apply_bounds(view: &tauri::WebviewWindow, bounds: PhysicalBounds) -> Result<(), String> {
    view.set_position(tauri::PhysicalPosition::new(bounds.x, bounds.y))
        .map_err(|error| error.to_string())?;
    view.set_size(tauri::PhysicalSize::new(bounds.width, bounds.height))
        .map_err(|error| error.to_string())
}

fn apply_layout_revision(
    owner: &mut PageOwner,
    mount_id: &str,
    revision: u64,
    effect: impl FnOnce() -> Result<(), String>,
) -> Result<(), String> {
    let mount = owner
        .mount
        .as_mut()
        .filter(|mount| mount.id == mount_id)
        .ok_or("plugin.web.staleMount")?;
    if revision <= mount.revision {
        return Ok(());
    }
    effect()?;
    mount.revision = revision;
    Ok(())
}

/// Layout revisions order geometry, hiding and focus under the same owner lock.
#[tauri::command]
pub async fn declarative_plugins_layout_web_window(
    app: AppHandle,
    caller: tauri::WebviewWindow,
    plugin_id: String,
    window_id: String,
    workspace_id: String,
    mount_id: String,
    revision: u64,
    bounds: DockBounds,
    visible: bool,
    focus: bool,
) -> Result<(), String> {
    product_host(caller.label())?;
    let state = app.state::<WebPageHostState>();
    let owner = find_mount(
        &state.owners.lock().expect("page owners"),
        caller.label(),
        &workspace_id,
        &plugin_id,
        &window_id,
        &mount_id,
    )?;
    let _native_page = app
        .state::<super::super::lifecycle::LifecycleState>()
        .acquire(&plugin_id)?;
    check_mount(&app, &owner).await?;
    let bounds = if visible {
        Some(bounds.normalize(caller.inner_size().map_err(|error| error.to_string())?)?)
    } else {
        None
    };
    let view = app
        .get_webview_window(&owned_label(&owner))
        .ok_or("plugin.web.staleMount")?;
    let mut owners = state.owners.lock().expect("page owners");
    let current = owners
        .get_mut(&owned_label(&owner))
        .ok_or("plugin.web.staleMount")?;
    apply_layout_revision(current, &mount_id, revision, || {
        if let Some(bounds) = bounds {
            apply_bounds(&view, bounds)?;
            view.show().map_err(|error| error.to_string())?;
            if focus {
                view.as_ref()
                    .set_focus()
                    .map_err(|error| error.to_string())?;
            }
        } else {
            view.hide().map_err(|error| error.to_string())?;
        }
        Ok(())
    })
}

/// Closing needs the precise receipt even after package/workspace revocation.
/// A failed close remains in closing_owners and can be retried by that receipt.
#[tauri::command]
pub fn declarative_plugins_unmount_web_window(
    app: AppHandle,
    caller: tauri::WebviewWindow,
    plugin_id: String,
    window_id: String,
    workspace_id: String,
    mount_id: String,
) -> Result<(), String> {
    product_host(caller.label())?;
    if !valid_request_id(&mount_id) {
        return Err(bridge_error(
            "plugin.web.invalidRequest",
            "invalid dock receipt",
        ));
    }
    let label = format!(
        "{}--m{}",
        slot_label(caller.label(), &workspace_id, &plugin_id, &window_id),
        hex_label_part(&mount_id)
    );
    revoke_owners(
        &app.state::<WebPageHostState>(),
        |owner| owned_label(owner) == label,
        false,
    );
    close_page_labels(&app, &[label]).map_err(|error| cleanup_error(&mount_id, error))
}

#[cfg(test)]
#[path = "web_docking_tests.rs"]
mod tests;
