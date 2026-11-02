//! One Build preparation owns its temporary toolchain-provider sessions.
//! Core owns process trees, framing, negotiation, deadlines and raw replies.
//! This native worker reuses each plugin backend within that preparation and
//! destroys every session before returning; it creates no background permit cache.
// Note: 后端与状态归属见 .agents/notes/implemented/architecture/2026-10-22-windows-declarative-plugin-host.md
use super::{
    launch,
    lifecycle::{LifecycleState, NativeLease},
    scan::core_execute,
    settings, store,
};
use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, BTreeSet},
    path::{Path, PathBuf},
    sync::atomic::{AtomicU64, Ordering},
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};
use tauri::{AppHandle, Manager};

const UNAVAILABLE: &str = "toolchain.native.providerUnavailable";
const CHANGED: &str = "toolchain.native.changed";
static OPERATION: AtomicU64 = AtomicU64::new(1);

struct Session {
    backend: lithe_project::toolchain_session::BackendSession,
    identity: Value,
    _lease: NativeLease,
}

pub(super) struct Queries<'a> {
    app: &'a AppHandle,
    workspace: &'a Path,
    sessions: BTreeMap<String, Session>,
    state_roots: BTreeMap<String, PathBuf>,
    operation: String,
    owner: &'a dyn Fn() -> Result<(), String>,
}
impl<'a> Queries<'a> {
    pub fn new(
        app: &'a AppHandle,
        workspace: &'a Path,
        owner: &'a dyn Fn() -> Result<(), String>,
    ) -> Self {
        Self {
            app,
            workspace,
            owner,
            sessions: BTreeMap::new(),
            state_roots: BTreeMap::new(),
            operation: format!(
                "{}-{}-{}",
                std::process::id(),
                SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_nanos(),
                OPERATION.fetch_add(1, Ordering::Relaxed)
            ),
        }
    }

    pub fn query(
        &mut self,
        plugin: &str,
        provider: &str,
        params: &Value,
        remaining: Duration,
    ) -> Result<Value, String> {
        (self.owner)()?;
        if remaining.is_zero() {
            return Err(UNAVAILABLE.into());
        }
        let deadline = Instant::now() + remaining;
        let lifecycle = self.app.state::<LifecycleState>();
        let lease = lifecycle.acquire(plugin).map_err(|_| CHANGED)?;
        let package = launch::package_by_id(self.app, plugin).ok_or(CHANGED)?;
        let providers: BTreeSet<_> = package.manifest["toolchainProviders"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(|value| value["id"].as_str().map(str::to_owned))
            .collect();
        if !providers.contains(provider) {
            return Err(UNAVAILABLE.into());
        }
        let workspace = self.workspace.to_string_lossy();
        let layers =
            settings::load_layers(self.app, plugin, &workspace).map_err(|_| UNAVAILABLE)?;
        // Separate the mutable backend state from language-server and Build state.
        let state = if let Some(state) = self.state_roots.get(plugin) {
            state.clone()
        } else {
            let parent = store::plugin_state_directory(self.app, plugin)?.join("toolchain-queries");
            std::fs::create_dir_all(&parent).map_err(|_| UNAVAILABLE)?;
            let state = parent.join(&self.operation);
            // Exclusive creation prevents reusing a crashed or concurrent owner's files.
            std::fs::create_dir(&state).map_err(|_| CHANGED)?;
            self.state_roots.insert(plugin.into(), state.clone());
            state
        };
        let workspace_state = state.join(store::workspace_state_key(&workspace));
        let planned = core_execute(
            "plugins.declarative.languageServerLaunchPlan",
            json!({
                "manifest":package.manifest,"backend":true,
                "request":launch::launch_request(&state,&package,&workspace,layers)
            }),
        )?;
        if planned["status"] != "ok"
            || planned["plan"]["backend"]["hostServices"]
                .as_array()
                .is_some_and(|services| !services.is_empty())
        {
            return Err(UNAVAILABLE.into());
        }
        let plan = &planned["plan"];
        let identity = json!({"root":package.root,"manifest":package.manifest,"plan":plan,
            "publisher":package.publisher.as_ref().map(|proof| json!({"keyID":proof.key_id,"contentDigest":proof.content_digest}))});
        if let Some(session) = self.sessions.get(plugin) {
            if session.identity != identity {
                return Err(CHANGED.into());
            }
        } else {
            if self.sessions.len() >= 8 {
                return Err(UNAVAILABLE.into());
            }
            launch::prepare_required_directories(plan, &state, &workspace_state)?;
            std::fs::create_dir_all(&state).map_err(|_| UNAVAILABLE)?;
            let resolved = launch::resolve_launch(&package, "backend", plan, &state)?;
            let remaining = deadline.saturating_duration_since(Instant::now());
            let backend = lithe_project::toolchain_session::BackendSession::launch(
                json!({
                    "providerId":format!("toolchain-query:{plugin}"),"pluginId":plugin,
                    "toolchainProviders":providers,"executablePath":resolved.server_path,"arguments":resolved.server_args,
                    "environment":resolved.environment,"initializationOptions":resolved.initialization_options,
                    "rootUri":url::Url::from_directory_path(self.workspace).map_err(|_| UNAVAILABLE)?.as_str(),
                    "workingDirectory":workspace
                }),
                remaining,
                || {
                    (self.owner)()?;
                    assert_current(self.app, plugin, deadline)
                },
            )?;
            self.sessions.insert(
                plugin.into(),
                Session {
                    backend,
                    identity,
                    _lease: lease,
                },
            );
        }
        let session = self.sessions.get_mut(plugin).ok_or(UNAVAILABLE)?;
        // Keep ownership even if initialization or its cleanup fails. State is
        // removed only after close has stopped every registered session.
        session
            .backend
            .initialize(deadline.saturating_duration_since(Instant::now()), || {
                (self.owner)()?;
                assert_current(self.app, plugin, deadline)
            })?;
        let response = session.backend.query(
            provider,
            params,
            deadline.saturating_duration_since(Instant::now()),
            || {
                (self.owner)()?;
                assert_current(self.app, plugin, deadline)
            },
        )?;
        if !super::trust::current(&package) {
            return Err(CHANGED.into());
        }
        Ok(response)
    }

    /// Complete every owned backend before returning the native tool result.
    pub fn close(&mut self) -> Result<(), String> {
        let mut failed = false;
        for session in self.sessions.values_mut() {
            failed |= session.backend.close().is_err();
        }
        if failed {
            Err(UNAVAILABLE.into())
        } else {
            self.sessions.clear();
            let mut failed = false;
            self.state_roots.retain(|_, root| {
                let retain = std::fs::remove_dir_all(root)
                    .is_err_and(|error| error.kind() != std::io::ErrorKind::NotFound);
                failed |= retain;
                retain
            });
            if failed {
                return Err(UNAVAILABLE.into());
            }
            Ok(())
        }
    }
}
impl Drop for Queries<'_> {
    fn drop(&mut self) {
        if self.close().is_err() {
            eprintln!("Toolchain preparation could not release all of its owned backend state");
        }
    }
}

fn budget(deadline: Instant) -> Result<u64, String> {
    let remaining = deadline
        .saturating_duration_since(Instant::now())
        .as_millis();
    if remaining == 0 {
        return Err(UNAVAILABLE.into());
    }
    Ok(remaining.min(10_000) as u64)
}
fn assert_current(app: &AppHandle, plugin: &str, deadline: Instant) -> Result<(), String> {
    budget(deadline)?;
    if app.state::<LifecycleState>().blocked(plugin) {
        return Err(CHANGED.into());
    }
    Ok(())
}
