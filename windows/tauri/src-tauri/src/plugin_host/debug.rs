//! Registry-owned connection debug plans. Core owns DAP argument bindings;
//! this adapter selects an accepted package and rechecks its publication,
//! signed content and settings at each asynchronous handoff. It does not
//! enable Debug/Build admission or select an adapter by language name.

use super::{
    launch, lifecycle::LifecycleState, scan::core_execute, settings, store, PluginHostState,
    ScannedPackage,
};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tauri::{AppHandle, Manager};

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct ConnectionRequest {
    pub workspace_path: String,
    pub configuration_type: String,
    #[serde(rename = "preferredAdapterID")]
    pub preferred_adapter_id: Option<String>,
    pub port: u16,
}

/// A prepared plan carries no authority to start. The next handoff recomputes
/// this identity against the live registry and rejects even identical reinstalls.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ConnectionPlan {
    pub plugin_id: String,
    #[serde(rename = "adapterID")]
    pub adapter_id: String,
    pub configuration_type: String,
    pub port: u16,
    pub arguments: Value,
    pub adapter: Value,
    pub identity: Value,
    pub language_id: Option<String>,
    pub command: Option<String>,
    pub launch: launch::ResolvedLaunch,
}

fn select(
    packages: Vec<ScannedPackage>,
    request: &ConnectionRequest,
) -> Result<(ScannedPackage, String), String> {
    if request.port == 0
        || request.configuration_type.is_empty()
        || request.configuration_type.len() > 128
    {
        return Err("plugin.debug.unavailable".into());
    }
    let mut selected = None;
    for package in packages
        .into_iter()
        .filter(|package| package.entry.enabled && package.entry.status == "accepted")
    {
        for adapter in package.manifest["debugAdapters"]
            .as_array()
            .into_iter()
            .flatten()
        {
            let Some(id) = adapter["id"].as_str() else {
                continue;
            };
            let identity = format!("{}/{id}", package.entry.plugin_id);
            if request
                .preferred_adapter_id
                .as_ref()
                .is_some_and(|preferred| preferred != &identity)
                || !adapter["requests"]
                    .as_array()
                    .is_some_and(|requests| requests.iter().any(|value| value == "attach"))
                || !adapter["configurationTypes"]
                    .as_array()
                    .is_some_and(|types| {
                        types
                            .iter()
                            .any(|value| value == &request.configuration_type)
                    })
            {
                continue;
            }
            if selected.is_some() {
                return Err("plugin.debug.ambiguous".into());
            }
            selected = Some((package.clone(), id.to_string()));
        }
    }
    selected.ok_or_else(|| "plugin.debug.unavailable".into())
}

fn resolve(
    app: &AppHandle,
    request: &ConnectionRequest,
    prepare_directories: bool,
) -> Result<ConnectionPlan, String> {
    let workspace = std::path::Path::new(&request.workspace_path)
        .canonicalize()
        .map_err(|_| "plugin.debug.stale")?;
    if !workspace.is_dir() {
        return Err("plugin.debug.stale".into());
    }
    let (generation, packages) = app.state::<PluginHostState>().snapshot();
    let (package, local_id) = select(packages, request)?;
    let _lease = app
        .state::<LifecycleState>()
        .acquire(&package.entry.plugin_id)?;
    let current =
        launch::package_by_id(app, &package.entry.plugin_id).ok_or("plugin.debug.stale")?;
    if current.root != package.root
        || current.manifest != package.manifest
        || app.state::<PluginHostState>().generation() != generation
    {
        return Err("plugin.debug.stale".into());
    }
    let started = core_execute(
        "debug.adapters.startArguments",
        json!({
            "manifest": package.manifest, "adapterID":local_id,"request":"attach",
            "facts":{"registration":{"generation":generation,"currentGeneration":generation},
                "target":{"kind":"connection","host":"127.0.0.1","port":request.port}}
        }),
    )?;
    if started["status"] != "ok"
        || started["connection"]["host"] != "127.0.0.1"
        || started["connection"]["port"] != request.port
        || started["connection"]["remote"] != false
    {
        return Err("plugin.debug.unavailable".into());
    }
    let plugin_owner = store::plugin_state_directory(app, &package.entry.plugin_id)?;
    let declaration = package.manifest["debugAdapters"]
        .as_array()
        .and_then(|items| items.iter().find(|item| item["id"] == local_id))
        .ok_or("plugin.debug.unavailable")?;
    let plugin_state = if declaration["launch"]["transport"] == "stdio" {
        plugin_owner.join("debug-adapters").join(&local_id)
    } else {
        plugin_owner
    };
    let layers = settings::load_layers(app, &package.entry.plugin_id, &request.workspace_path)?;
    // Use the normal language-server state owner for shared servers. No second
    // mutable workspace is created merely to attach one debugger.
    let planned = core_execute(
        "plugins.declarative.languageServerLaunchPlan",
        json!({
            "manifest":package.manifest,"debugAdapterID":local_id,
            "request":launch::launch_request(&plugin_state,&package,&request.workspace_path,layers)
        }),
    )?;
    if planned["status"] != "ok" {
        return Err("plugin.debug.unavailable".into());
    }
    let plan = &planned["plan"];
    let adapter = &plan["debugAdapter"];
    if adapter["id"] != local_id {
        return Err("plugin.debug.unavailable".into());
    }
    let (language_id, command) = match adapter["transport"].as_str() {
        Some("stdio") => (None, None),
        Some("tcpLanguageServer") => (
            Some(
                adapter["endpoint"]["languageID"]
                    .as_str()
                    .ok_or("plugin.debug.unavailable")?
                    .to_string(),
            ),
            Some(
                adapter["endpoint"]["command"]
                    .as_str()
                    .ok_or("plugin.debug.unavailable")?
                    .to_string(),
            ),
        ),
        _ => return Err("plugin.debug.unsupportedTransport".into()),
    };
    if prepare_directories {
        let workspace_state =
            plugin_state.join(store::workspace_state_key(&request.workspace_path));
        launch::prepare_required_directories(plan, &plugin_state, &workspace_state)?;
        std::fs::create_dir_all(&plugin_state).map_err(|error| error.to_string())?;
    }
    let resolved = launch::resolve_launch(
        &package,
        language_id.as_deref().unwrap_or(&local_id),
        plan,
        &plugin_state,
    )?;
    let identity = json!({"generation":generation,"packageDirectory":package.root,"manifest":package.manifest,"plan":plan,
        "arguments":started["arguments"],"workspace":workspace,"workspaceInput":request.workspace_path,"resolved":resolved,
        "publisher":package.publisher.as_ref().map(|proof|json!({"keyID":proof.key_id,"contentDigest":proof.content_digest}))});
    if app.state::<PluginHostState>().generation() != generation
        || app
            .state::<LifecycleState>()
            .blocked(&package.entry.plugin_id)
    {
        return Err("plugin.debug.stale".into());
    }
    Ok(ConnectionPlan {
        plugin_id: package.entry.plugin_id.clone(),
        adapter_id: format!("{}/{local_id}", package.entry.plugin_id),
        configuration_type: request.configuration_type.clone(),
        port: request.port,
        arguments: started["arguments"].clone(),
        adapter: adapter.clone(),
        identity,
        language_id,
        command,
        launch: resolved,
    })
}

/// Opening a connection is an explicit action; this plan can probe declared
/// runtimes but never starts the adapter or executes workspace build code.
#[tauri::command]
pub async fn declarative_plugins_debug_connection_plan(
    app: AppHandle,
    request: ConnectionRequest,
) -> Result<ConnectionPlan, String> {
    crate::blocking::run_blocking(move || resolve(&app, &request, true)).await
}

/// Call before and after reaching a shared server, target listener or native
/// session. A frontend snapshot alone cannot keep a revoked package alive.
#[tauri::command]
pub async fn declarative_plugins_debug_validate_connection(
    app: AppHandle,
    request: ConnectionRequest,
    identity: Value,
) -> Result<(), String> {
    crate::blocking::run_blocking(move || {
        if resolve(&app, &request, false)?.identity != identity {
            return Err("plugin.debug.stale".into());
        }
        Ok(())
    })
    .await
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::plugin_host::{CatalogEntry, CatalogLanguage};

    #[test]
    fn native_registry_handoff_uses_shared_core_connection_bindings_and_generations() {
        let manifest:Value=serde_json::from_str(include_str!("../../../../../shared/contracts/plugins/v1/fixtures/debug-adapter-remote-attach.plugin.json")).unwrap();
        let mut payload = json!({"manifest":manifest,"adapterID":"nested","request":"attach",
            "facts":{"registration":{"generation":7,"currentGeneration":7},"target":{"kind":"connection","host":"127.0.0.1","port":51234}}});
        let result = core_execute("debug.adapters.startArguments", payload.clone()).unwrap();
        assert_eq!(result["status"], "ok");
        assert_eq!(
            result["arguments"]["connect"],
            json!({"host":"127.0.0.1","port":51234})
        );
        assert_eq!(result["arguments"]["justMyCode"], false);
        assert_eq!(result["connection"]["remote"], false);
        payload["facts"]["registration"]["currentGeneration"] = json!(8);
        assert_eq!(
            core_execute("debug.adapters.startArguments", payload).unwrap()["status"],
            "rejected"
        );
    }
    fn package(id: &str) -> ScannedPackage {
        ScannedPackage {
            root: "fixture-package".into(),
            publisher: None,
            entry: CatalogEntry {
                plugin_id: id.into(),
                display_name: id.into(),
                version: "1.0.0".into(),
                api_version: 4,
                source: "installed",
                enabled: true,
                status: "accepted",
                languages: Vec::<CatalogLanguage>::new(),
                declared_settings: vec![],
                declares_tests: false,
                primary_language_id: None,
                rejection: None,
            },
            manifest: json!({"debugAdapters":[{"id":"remote","requests":["attach"],"configurationTypes":["engine.remote"]}]}),
        }
    }
    fn request() -> ConnectionRequest {
        ConnectionRequest {
            workspace_path: "fixture-workspace".into(),
            configuration_type: "engine.remote".into(),
            preferred_adapter_id: None,
            port: 51234,
        }
    }
    #[test]
    fn registry_selects_public_type_and_exact_identity_without_language_fallback() {
        assert_eq!(
            select(vec![package("dev.example.one")], &request())
                .unwrap()
                .1,
            "remote"
        );
        assert!(select(
            vec![package("dev.example.one"), package("dev.example.two")],
            &request()
        )
        .is_err());
        let mut chosen = request();
        chosen.preferred_adapter_id = Some("dev.example.two/remote".into());
        assert_eq!(
            select(
                vec![package("dev.example.one"), package("dev.example.two")],
                &chosen
            )
            .unwrap()
            .0
            .entry
            .plugin_id,
            "dev.example.two"
        );
        chosen.configuration_type = "other.type".into();
        assert!(select(vec![package("dev.example.two")], &chosen).is_err());
        chosen = request();
        chosen.port = 0;
        assert!(select(vec![package("dev.example.one")], &chosen).is_err());
    }
    #[test]
    fn registry_ignores_disabled_quarantined_and_launch_only_packages() {
        let mut disabled = package("dev.example.disabled");
        disabled.entry.enabled = false;
        let mut rejected = package("dev.example.rejected");
        rejected.entry.status = "rejected";
        let mut launch_only = package("dev.example.launch");
        launch_only.manifest["debugAdapters"][0]["requests"] = json!(["launch"]);
        assert!(select(vec![disabled, rejected, launch_only], &request()).is_err());
        let registry = PluginHostState::default();
        let before = registry.snapshot().0;
        registry.set_packages(vec![package("dev.example.one")]);
        let first = registry.snapshot();
        registry.set_packages(first.1);
        assert!(registry.snapshot().0 > first.0);
        assert!(first.0 > before);
    }
}
