//! Native launch resolution for workspace-owned Build Provider processes.
//!
//! Core owns manifest/template semantics. The existing plugin launch adapter
//! checks package paths and runtime versions; Core's LSP runtime owns stdio,
//! cancellation and process-tree cleanup. No Maven command is constructed here.

use super::{launch, lifecycle::LifecycleState, scan::core_execute, settings, store};
use serde::Serialize;
use serde_json::{json, Value};
use tauri::{AppHandle, Manager};

/// A provider process ready for the shared Core session runtime. This transport
/// does not advertise Build capabilities until the product workflow is wired.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BuildProviderLaunch {
    pub plugin_id: String,
    pub build_system_id: String,
    /// Exact package and effective launch inputs, used to revoke old sessions.
    pub identity: Value,
    pub server_path: String,
    pub server_args: Vec<String>,
    pub initialization_options: Option<Value>,
    pub environment: std::collections::BTreeMap<String, String>,
}

/// Resolves only an accepted package's declared provider. State directories are
/// under the platform's writable plugin state, separate from language servers.
#[tauri::command]
pub async fn declarative_plugins_build_launch(
    app: AppHandle,
    plugin_id: String,
    build_system_id: String,
    workspace_path: String,
) -> Result<BuildProviderLaunch, String> {
    crate::blocking::run_blocking(move || {
        let _lease = app.state::<LifecycleState>().acquire(&plugin_id)?;
        let package = launch::package_by_id(&app, &plugin_id)
            .ok_or("Build Provider plugin is unavailable or changing version")?;
        // Derive a path component only after Core has validated the declared ID.
        let system = package.manifest["buildSystems"].as_array().into_iter().flatten()
            .find(|system| system["id"].as_str() == Some(build_system_id.as_str()))
            .ok_or("The plugin does not declare this build system")?;
        let state = build_state_directory(&store::plugin_state_directory(&app, &plugin_id)?,
            system["id"].as_str().ok_or("Invalid build system ID")?)?;
        let workspace_state = state.join(build_workspace_key(&workspace_path));
        let layers = settings::load_layers(&app, &plugin_id, &workspace_path)
            .map_err(|error| format!("Build Provider settings could not be read: {error}"))?;
        let planned = core_execute("plugins.declarative.languageServerLaunchPlan", json!({
            "manifest": package.manifest,
            "buildSystemID": build_system_id,
            "request": launch::launch_request(&state, &package, &workspace_path, layers),
        }))?;
        if planned["status"] == "rejected" {
            return Err(format!("Build Provider launch rejected: {}", planned["error"]["message"]));
        }
        let plan = &planned["plan"];
        if plan["buildProvider"]["buildSystemID"] != build_system_id {
            return Err("Core returned a different Build Provider".into());
        }
        if plan["buildProvider"]["languageServer"].is_string() {
            return Err("This Build Provider requires a shared language session".into());
        }
        launch::prepare_required_directories(plan, &state, &workspace_state)?;
        std::fs::create_dir_all(&state).map_err(|error| error.to_string())?;
        let resolved = launch::resolve_launch(&package, &build_system_id, plan, &state)?;
        Ok(BuildProviderLaunch {
            identity: json!({ "packageDirectory": package.root, "manifest": package.manifest, "plan": plan }),
            plugin_id,
            build_system_id,
            server_path: resolved.server_path,
            server_args: resolved.server_args,
            initialization_options: resolved.initialization_options,
            environment: resolved.environment,
        })
    }).await
}

pub(super) fn build_state_directory(
    plugin_state: &std::path::Path,
    system: &str,
) -> Result<std::path::PathBuf, String> {
    if system.is_empty()
        || system == "."
        || system == ".."
        || !system
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || b"._-".contains(&byte))
    {
        return Err("Build system ID is not a safe state directory component".into());
    }
    Ok(plugin_state.join("build-systems").join(system))
}

pub(super) fn build_workspace_key(workspace: &str) -> String {
    let path = workspace.replace('\\', "/");
    let path = if path.starts_with("//") || path.as_bytes().get(1) == Some(&b':') {
        path.to_lowercase()
    } else {
        path
    };
    store::workspace_state_key(&path)
}

#[cfg(test)]
mod tests {
    #[test]
    fn workspace_storage_uses_the_same_windows_case_and_separator_identity_as_sessions() {
        assert_eq!(
            super::build_workspace_key("C:\\Work\\App"),
            super::build_workspace_key("c:/WORK/App")
        );
        assert_eq!(
            super::build_workspace_key("\\\\Server\\Share\\App"),
            super::build_workspace_key("//server/share/app")
        );
        assert_ne!(
            super::build_workspace_key("C:/work"),
            super::build_workspace_key("C:/other")
        );
    }
    #[test]
    fn build_state_is_under_its_platform_plugin_owner_and_rejects_path_components() {
        let owner = std::path::Path::new("platform-state/plugin");
        assert_eq!(
            super::build_state_directory(owner, "example.build-1").unwrap(),
            owner.join("build-systems/example.build-1")
        );
        for invalid in [
            "",
            ".",
            "..",
            "../escape",
            "C:\\outside",
            "/outside",
            "two/parts",
            "two\\parts",
        ] {
            assert!(
                super::build_state_directory(owner, invalid).is_err(),
                "{invalid}"
            );
        }
    }
}
