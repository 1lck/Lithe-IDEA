use lithe_project::indexing_refresh::IndexingRefresh;
use std::collections::{HashMap, HashSet};
use std::sync::{Arc, Mutex, OnceLock};
use tauri::{Emitter, Manager};

#[derive(Default)]
struct WindowIndexingOwners {
    closed: HashSet<String>,
    leases: HashMap<String, HashMap<(String, String), u64>>,
    refreshes: HashMap<String, Arc<IndexingRefresh>>,
    installing: HashMap<String, usize>,
}

fn indexing_owners() -> &'static Mutex<WindowIndexingOwners> {
    static OWNERS: OnceLock<Mutex<WindowIndexingOwners>> = OnceLock::new();
    OWNERS.get_or_init(Mutex::default)
}

fn cancelled_indexing(id: serde_json::Value) -> String {
    serde_json::json!({"id":id,"ok":false,"error":{"code":"cancelled","message":"Workspace window closed"}}).to_string()
}

fn canonical_indexing_root(root: &str) -> String {
    let mut existing = std::path::PathBuf::from(root);
    let mut missing = Vec::new();
    loop {
        if let Ok(mut path) = std::fs::canonicalize(&existing) {
            for part in missing.iter().rev() {
                path.push(part);
            }
            return path.to_string_lossy().into_owned();
        }
        let Some(name) = existing.file_name().map(|name| name.to_owned()) else {
            return root.to_owned();
        };
        missing.push(name);
        if !existing.pop() {
            return root.to_owned();
        }
    }
}

fn root_refresh(root: &str) -> Option<Arc<IndexingRefresh>> {
    indexing_owners()
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .refreshes
        .get(root)
        .cloned()
}

fn prune_refreshes(owners: &mut WindowIndexingOwners) {
    let live: HashSet<_> = owners
        .leases
        .values()
        .flat_map(|leases| leases.keys().map(|(root, _)| root.clone()))
        .collect();
    owners
        .refreshes
        .retain(|root, _| live.contains(root) || owners.installing.contains_key(root));
}

fn freshen_root(
    root: &str,
    state: &IndexingRefresh,
    execute: &impl Fn(&str) -> String,
) -> Result<bool, ()> {
    state.ensure_fresh(|| {
        let lease = indexing_owners().lock().unwrap_or_else(|error| error.into_inner())
            .leases.values().find_map(|leases| leases.iter()
                .find(|((path, _), _)| path == root)
                .map(|((_, owner), revision)| (owner.clone(), *revision)));
        let Some((owner, revision)) = lease else { return Err(()); };
        let request = serde_json::json!({"command":"workspace.refreshIndexing", "timeoutMilliseconds":30000,
            "payload":{"root":root,"ownerId":owner,"revision":revision}});
        let response = execute(&request.to_string());
        let value: serde_json::Value = serde_json::from_str(&response).map_err(|_| ())?;
        if value["ok"] == true { Ok(response) } else { Err(()) }
    }).map_err(|_| ())
}

/// Native events invalidate once before fan-out; WebViews never duplicate the native batch.
pub fn invalidate_indexing_paths(app: &tauri::AppHandle, paths: &[std::path::PathBuf], git: bool) {
    let paths: Vec<_> = paths
        .iter()
        .map(|path| std::path::PathBuf::from(canonical_indexing_root(&path.to_string_lossy())))
        .collect();
    let entries: Vec<_> = indexing_owners()
        .lock()
        .unwrap_or_else(|error| error.into_inner())
        .refreshes
        .iter()
        .filter(|(root, _)| {
            paths.iter().any(|path| {
                let root = std::path::Path::new(root);
                path.starts_with(root) || (git && root.starts_with(path))
            })
        })
        .map(|(root, state)| {
            state.invalidate();
            (root.clone(), Arc::clone(state))
        })
        .collect();
    for (root, state) in entries {
        let app = app.clone();
        tauri::async_runtime::spawn_blocking(move || {
            if freshen_root(&root, &state, &lithe_core::execute_json).is_ok()
                && state.take_completed()
            {
                let _ = app.emit("workspace-indexing-refreshed", &root);
            }
        });
    }
}

fn execute_for_window(owner: &str, request: &str, execute: impl Fn(&str) -> String) -> String {
    let Ok(mut value) = serde_json::from_str::<serde_json::Value>(request) else {
        return execute(request);
    };
    let configuring = value["command"] == "workspace.configureIndexing";
    let releasing = value["command"] == "workspace.releaseIndexing";
    let refreshing = value["command"] == "workspace.refreshIndexing";
    if !configuring && !releasing && !refreshing {
        // Only read-only index consumers can discard a superseded response. A completed
        // write (for example runConfig.saveEditorChanges) must retain its success result.
        let indexing_query = matches!(
            value["command"].as_str(),
            Some(
                "workspace.snapshot"
                    | "workspace.search"
                    | "workspace.searchEverywhere"
                    | "workspace.searchIndex.warm"
                    | "workspace.replacePreview"
            )
        );
        if !indexing_query {
            return execute(request);
        }
        let state = value["payload"]["root"]
            .as_str()
            .map(canonical_indexing_root)
            .and_then(|root| root_refresh(&root).map(|state| (root, state)));
        if let Some((root, state)) = state {
            if freshen_root(&root, &state, &execute).is_err() {
                return cancelled_indexing(value["id"].clone());
            }
            let epoch = state.epoch();
            let response = execute(request);
            if state.epoch() != epoch || !state.is_clean() {
                return cancelled_indexing(value["id"].clone());
            }
            return response;
        }
        return execute(request);
    }
    let (Some(runtime), Some(root)) = (
        value["payload"]["ownerId"].as_str(),
        value["payload"]["root"].as_str(),
    ) else {
        return execute(request);
    };
    // The native label is trusted; a WebView cannot acquire another window's lease.
    let runtime = format!("{owner}/{runtime}");
    let root = canonical_indexing_root(root);
    value["payload"]["root"] = serde_json::json!(root);
    value["payload"]["ownerId"] = serde_json::json!(runtime);
    {
        let mut owners = indexing_owners()
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        if owners.closed.contains(owner) {
            return cancelled_indexing(value["id"].clone());
        }
        owners.leases.entry(owner.to_owned()).or_default();
        if refreshing
            && owners
                .leases
                .get(owner)
                .and_then(|leases| leases.get(&(root.clone(), runtime.clone())))
                .copied()
                != value["payload"]["revision"].as_u64()
        {
            return cancelled_indexing(value["id"].clone());
        }
    }
    let installation = configuring.then(|| PendingInstallation::new(&root));
    let state = root_refresh(&root);
    let epoch = state.as_ref().map(|state| state.epoch());
    if let Some(state) = &state {
        if refreshing {
            return match state.refresh_now(|| {
                let response = execute(&value.to_string());
                if serde_json::from_str::<serde_json::Value>(&response)
                    .ok()
                    .is_some_and(|response| response["ok"] == true)
                {
                    Ok(response)
                } else {
                    Err(response)
                }
            }) {
                Ok(response) => {
                    let owners = indexing_owners().lock().unwrap_or_else(|e| e.into_inner());
                    if owners.closed.contains(owner)
                        || owners
                            .leases
                            .get(owner)
                            .and_then(|leases| leases.get(&(root.clone(), runtime.clone())))
                            .copied()
                            != value["payload"]["revision"].as_u64()
                    {
                        return cancelled_indexing(value["id"].clone());
                    }
                    // A concurrent holder may have performed the shared refresh. Status is
                    // root-wide; the response envelope and release token belong to this caller.
                    let mut result: serde_json::Value = serde_json::from_str(&response).unwrap();
                    result["id"] = value["id"].clone();
                    result["data"]["revision"] = value["payload"]["revision"].clone();
                    result.to_string()
                }
                Err(lithe_project::indexing_refresh::RefreshError::Failed(response)) => response,
                Err(_) => cancelled_indexing(value["id"].clone()),
            };
        }
        if !releasing && !configuring && freshen_root(&root, &state, &execute).is_err() {
            return cancelled_indexing(value["id"].clone());
        }
    }
    let response = execute(&value.to_string());
    let Ok(result) = serde_json::from_str::<serde_json::Value>(&response) else {
        return response;
    };
    if result["ok"] != true {
        return response;
    }
    let revision = if configuring {
        result["data"]["revision"].as_u64()
    } else {
        value["payload"]["revision"].as_u64()
    };
    let Some(revision) = revision else {
        return response;
    };
    let closed = {
        let mut owners = indexing_owners()
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        let closed = owners.closed.contains(owner);
        if !closed {
            let leases = owners.leases.entry(owner.to_owned()).or_default();
            let key = (root.clone(), runtime.clone());
            if configuring {
                if let Some(state) = &state {
                    state.discard_status();
                }
                leases.insert(key, revision);
            } else if leases.get(&key) == Some(&revision) {
                leases.remove(&key);
            }
            if configuring {
                owners.refreshes.entry(root.clone()).or_default();
            }
            prune_refreshes(&mut owners);
        }
        closed
    };
    if closed && configuring {
        // Destruction may win while Core is installing the policy. Reclaim the
        // returned token here, after the destroy callback drained earlier tokens.
        execute(&serde_json::json!({"command":"workspace.releaseIndexing","payload":{"root":root,"ownerId":runtime,"revision":revision}}).to_string());
        return cancelled_indexing(value["id"].clone());
    }
    if configuring {
        let state = state.expect("configuration reserves its root");
        let mut response = response;
        let mut observed = epoch.unwrap();
        for _ in 0..3 {
            if state.epoch() == observed && state.is_clean() {
                return response;
            }
            if freshen_root(&root, &state, &execute).is_err() {
                break;
            }
            observed = state.epoch();
            // Read the requested directory reasons again, using the same published lease.
            value["payload"]["refresh"] = serde_json::json!(false);
            response = execute(&value.to_string());
            if !serde_json::from_str::<serde_json::Value>(&response)
                .ok()
                .is_some_and(|result| {
                    result["ok"] == true && result["data"]["revision"] == revision
                })
            {
                break;
            }
        }
        // No token is returned on failure: reclaim this installation ourselves.
        execute(&serde_json::json!({"command":"workspace.releaseIndexing","payload":{"root":root,"ownerId":runtime,"revision":revision}}).to_string());
        let mut owners = indexing_owners().lock().unwrap_or_else(|e| e.into_inner());
        if let Some(leases) = owners.leases.get_mut(owner) {
            let key = (root.clone(), runtime);
            if leases.get(&key) == Some(&revision) {
                leases.remove(&key);
            }
        }
        drop(owners);
        drop(installation);
        return cancelled_indexing(value["id"].clone());
    }
    response
}

/// A configuration in flight also owns its invalidation record, before it has a Core token.
struct PendingInstallation(String);
impl PendingInstallation {
    fn new(root: &str) -> Self {
        let mut owners = indexing_owners().lock().unwrap_or_else(|e| e.into_inner());
        *owners.installing.entry(root.to_owned()).or_default() += 1;
        owners.refreshes.entry(root.to_owned()).or_default();
        Self(root.to_owned())
    }
}
impl Drop for PendingInstallation {
    fn drop(&mut self) {
        let mut owners = indexing_owners().lock().unwrap_or_else(|e| e.into_inner());
        if let Some(count) = owners.installing.get_mut(&self.0) {
            *count -= 1;
            if *count == 0 {
                owners.installing.remove(&self.0);
            }
        }
        prune_refreshes(&mut owners);
    }
}

/// Native destruction is the fallback when a WebView cannot run workspace teardown.
pub fn close_window_indexing(owner: &str) {
    let leases = {
        let mut owners = indexing_owners()
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        owners.closed.insert(owner.to_owned());
        let leases = owners.leases.remove(owner).unwrap_or_default();
        prune_refreshes(&mut owners);
        leases
    };
    tauri::async_runtime::spawn_blocking(move || {
        for ((root, owner_id), revision) in leases {
            let response = lithe_core::execute_json(&serde_json::json!({"command":"workspace.releaseIndexing","payload":{"root":root,"ownerId":owner_id,"revision":revision}}).to_string());
            if let Ok(value) = serde_json::from_str::<serde_json::Value>(&response) {
                if value["ok"] != true {
                    eprintln!("Could not release window indexing: {}", value["error"]);
                }
            }
        }
    });
}

#[tauri::command]
pub async fn core_execute(window: tauri::WebviewWindow, request: String) -> String {
    let owner = window.label().to_owned();
    let app = window.app_handle().clone();
    tauri::async_runtime::spawn_blocking(move || {
        let parsed = serde_json::from_str::<serde_json::Value>(&request).ok();
        let previous = parsed.as_ref().and_then(|value| {
            let root = canonical_indexing_root(value["payload"]["root"].as_str()?);
            let runtime = format!("{owner}/{}", value["payload"]["ownerId"].as_str()?);
            indexing_owners()
                .lock()
                .unwrap_or_else(|e| e.into_inner())
                .leases
                .get(&owner)?
                .get(&(root, runtime))
                .copied()
        });
        let response = execute_for_window(&owner, &request, lithe_core::execute_json);
        if let (Ok(request), Ok(result)) = (
            serde_json::from_str::<serde_json::Value>(&request),
            serde_json::from_str::<serde_json::Value>(&response),
        ) {
            if result["ok"] == true
                && (request["command"] == "workspace.refreshIndexing"
                    || (request["command"] == "workspace.configureIndexing"
                        && result["data"]["revision"].as_u64() != previous))
            {
                let _ = app.emit("workspace-indexing-refreshed", &request["payload"]["root"]);
            }
        }
        response
    })
    .await
    .unwrap_or_else(|error| {
        serde_json::json!({
            "id": null,
            "ok": false,
            "error": {
                "code": "unknown",
                "message": "The shared core operation could not complete",
                "details": error.to_string()
            }
        })
        .to_string()
    })
}

#[tauri::command]
pub fn core_cancel(operation_id: String) -> bool {
    lithe_core::cancel_operation(&operation_id)
}

/// Resolves MCP's read-only helper and writable connection storage in the native host.
#[tauri::command]
pub fn ide_host_paths(app: tauri::AppHandle) -> Result<serde_json::Value, String> {
    use tauri::Manager;
    let directory = app
        .path()
        .app_local_data_dir()
        .map_err(|e| e.to_string())?
        .join("mcp");
    let helper = app
        .path()
        .resource_dir()
        .map_err(|e| e.to_string())?
        .join("helpers")
        .join("lithe-mcp.exe");
    Ok(serde_json::json!({ "directory":directory, "helperPath":helper }))
}

/// Native window destruction also revokes access when WebView cleanup could not run.
pub fn close_ide_hosts(owner: &str) {
    let response = lithe_core::execute_json(&serde_json::json!({
        "command":"ideHost.control", "payload":{"action":"closeOwner","arguments":{"ownerID":owner}}
    }).to_string());
    if let Ok(value) = serde_json::from_str::<serde_json::Value>(&response) {
        if value["ok"] != true {
            eprintln!("Could not close IDE connections: {}", value["error"]);
        }
    }
}

#[cfg(test)]
mod indexing_tests {
    use super::*;
    use serde_json::{json, Value};
    use std::cell::RefCell;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

    struct IndexingFixture {
        owner: String,
        directory: PathBuf,
    }

    impl IndexingFixture {
        fn new(label: &str) -> Self {
            let owner = format!(
                "lithe-indexing-{label}-{}-{}",
                std::process::id(),
                NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed)
            );
            let directory = std::env::temp_dir().join(&owner);
            std::fs::create_dir(&directory).expect("create indexing fixture directory");
            Self { owner, directory }
        }

        fn request_root(&self) -> String {
            // A lexical alias forces the test to distinguish a request path from its
            // registry identity on every platform, including Windows verbatim paths.
            format!("{}/.", self.directory.display())
        }

        fn canonical_root(&self) -> String {
            std::fs::canonicalize(&self.directory)
                .expect("canonicalize indexing fixture directory")
                .to_string_lossy()
                .into_owned()
        }
    }

    impl Drop for IndexingFixture {
        fn drop(&mut self) {
            {
                let mut owners = indexing_owners()
                    .lock()
                    .unwrap_or_else(|error| error.into_inner());
                owners.closed.remove(&self.owner);
                owners.leases.remove(&self.owner);
                prune_refreshes(&mut owners);
            }
            if let Err(error) = std::fs::remove_dir_all(&self.directory) {
                eprintln!("Could not remove indexing fixture directory: {error}");
            }
        }
    }

    #[test]
    fn native_destruction_reclaims_an_installation_that_finishes_after_close() {
        let fixture = IndexingFixture::new("close-during-install");
        let owner = fixture.owner.as_str();
        let root = fixture.request_root();
        let calls = RefCell::new(Vec::<Value>::new());
        let response = execute_for_window(owner, &json!({"id":"late", "command":"workspace.configureIndexing", "payload":{"root":root, "ownerId":"workspace-one"}}).to_string(), |request| {
            let value: Value = serde_json::from_str(request).unwrap();
            calls.borrow_mut().push(value.clone());
            if value["command"] == "workspace.configureIndexing" {
                indexing_owners().lock().unwrap().closed.insert(owner.to_owned());
                json!({"ok":true,"data":{"revision":7}}).to_string()
            } else { json!({"ok":true,"data":{"released":true}}).to_string() }
        });
        let response: Value = serde_json::from_str(&response).unwrap();
        assert_eq!(response["error"]["code"], "cancelled");
        let calls = calls.borrow();
        assert_eq!(calls.len(), 2);
        assert_eq!(
            calls[0]["payload"]["ownerId"],
            format!("{owner}/workspace-one")
        );
        assert_eq!(calls[1]["command"], "workspace.releaseIndexing");
        assert_eq!(calls[1]["payload"]["revision"], 7);
        assert!(root_refresh(&fixture.canonical_root()).is_none());
    }

    #[test]
    fn late_release_keeps_the_new_native_cleanup_token() {
        let fixture = IndexingFixture::new("late-release");
        let owner = fixture.owner.as_str();
        let root = fixture.request_root();
        let request = |command: &str, revision: u64| {
            json!({"command":command,"payload":{"root":root,"ownerId":"workspace-one","revision":revision}}).to_string()
        };
        for revision in [1, 2] {
            execute_for_window(owner, &request("workspace.configureIndexing", 0), |_| {
                json!({"ok":true,"data":{"revision":revision}}).to_string()
            });
        }
        execute_for_window(owner, &request("workspace.releaseIndexing", 1), |_| {
            json!({"ok":true,"data":{"released":false}}).to_string()
        });
        let owners = indexing_owners().lock().unwrap();
        assert_eq!(
            owners.leases[owner][&(fixture.canonical_root(), format!("{owner}/workspace-one"))],
            2
        );
    }

    #[test]
    fn events_during_first_configuration_refresh_before_returning_without_new_tokens() {
        let fixture = IndexingFixture::new("first-configuration-event");
        let owner = fixture.owner.as_str();
        let root = fixture.request_root();
        let canonical_root = fixture.canonical_root();
        let calls = RefCell::new(Vec::new());
        let response = execute_for_window(owner, &json!({"id":"configure", "command":"workspace.configureIndexing", "payload":{"root":root,"ownerId":"runtime"}}).to_string(), |request| {
            let request: Value = serde_json::from_str(request).unwrap();
            let command = request["command"].as_str().unwrap().to_owned();
            calls.borrow_mut().push(command.clone());
            if calls.borrow().len() == 1 { root_refresh(&canonical_root).expect("canonical root must be registered").invalidate(); }
            json!({"ok":true,"data":{"revision":7,"excludedDirectories":{"archive":"git"},"gitIgnoreFailed":false}}).to_string()
        });
        assert_eq!(
            serde_json::from_str::<Value>(&response).unwrap()["data"]["revision"],
            7
        );
        assert_eq!(
            *calls.borrow(),
            [
                "workspace.configureIndexing",
                "workspace.refreshIndexing",
                "workspace.configureIndexing"
            ]
        );
        execute_for_window(owner, &json!({"command":"workspace.releaseIndexing","payload":{"root":root,"ownerId":"runtime","revision":7}}).to_string(), |_| json!({"ok":true,"data":{"released":true}}).to_string());
        assert!(root_refresh(&canonical_root).is_none());
    }

    #[test]
    fn query_cannot_publish_a_result_superseded_by_an_event() {
        let fixture = IndexingFixture::new("query-event");
        let owner = fixture.owner.as_str();
        let root = fixture.request_root();
        let canonical_root = fixture.canonical_root();
        execute_for_window(owner, &json!({"command":"workspace.configureIndexing","payload":{"root":root,"ownerId":"runtime"}}).to_string(), |_| json!({"ok":true,"data":{"revision":4}}).to_string());
        let result = execute_for_window(
            owner,
            &json!({"id":"query","command":"workspace.snapshot","payload":{"root":root}})
                .to_string(),
            |_| {
                root_refresh(&canonical_root)
                    .expect("canonical root must be registered")
                    .invalidate();
                json!({"ok":true,"data":{"files":["stale"]}}).to_string()
            },
        );
        assert_eq!(
            serde_json::from_str::<Value>(&result).unwrap()["error"]["code"],
            "cancelled"
        );
        execute_for_window(owner, &json!({"command":"workspace.releaseIndexing","payload":{"root":root,"ownerId":"runtime","revision":4}}).to_string(), |_| json!({"ok":true,"data":{"released":true}}).to_string());
    }

    #[test]
    fn completed_write_keeps_success_when_a_watcher_invalidates_its_root() {
        let fixture = IndexingFixture::new("write-event");
        let owner = fixture.owner.as_str();
        let root = fixture.request_root();
        let canonical_root = fixture.canonical_root();
        execute_for_window(owner, &json!({"command":"workspace.configureIndexing","payload":{"root":root,"ownerId":"runtime"}}).to_string(), |_| json!({"ok":true,"data":{"revision":5}}).to_string());
        let expected = json!({"id":"write","ok":true,"data":{"saved":true}}).to_string();
        let response = execute_for_window(
            owner,
            &json!({"id":"write","command":"runConfig.saveEditorChanges","payload":{"root":root}})
                .to_string(),
            |_| {
                root_refresh(&canonical_root)
                    .expect("canonical root must be registered")
                    .invalidate();
                expected.clone()
            },
        );
        assert_eq!(response, expected);
        execute_for_window(owner, &json!({"command":"workspace.releaseIndexing","payload":{"root":root,"ownerId":"runtime","revision":5}}).to_string(), |_| json!({"ok":true,"data":{"released":true}}).to_string());
    }

    #[test]
    fn request_path_aliases_share_refresh_state_until_the_last_lease_is_released() {
        let fixture = IndexingFixture::new("path-aliases");
        let owner = fixture.owner.as_str();
        let alias = fixture.request_root();
        let canonical = fixture.canonical_root();
        assert_ne!(alias, canonical);
        let configure = |root: &str, runtime: &str, revision: u64| {
            execute_for_window(
                owner,
                &json!({"command":"workspace.configureIndexing",
                "payload":{"root":root,"ownerId":runtime}})
                .to_string(),
                |request| {
                    let request: Value = serde_json::from_str(request).unwrap();
                    assert_eq!(request["payload"]["root"], canonical);
                    json!({"ok":true,"data":{"revision":revision}}).to_string()
                },
            )
        };
        assert_eq!(
            serde_json::from_str::<Value>(&configure(&alias, "first", 11)).unwrap()["ok"],
            true
        );
        let state = root_refresh(&canonical).expect("first holder registers the canonical root");
        assert_eq!(
            serde_json::from_str::<Value>(&configure(&canonical, "second", 12)).unwrap()["ok"],
            true
        );
        assert!(Arc::ptr_eq(&state, &root_refresh(&canonical).unwrap()));
        assert!(
            root_refresh(&alias).is_none(),
            "the registry must not create a second lexical-path entry"
        );

        for (root, runtime, revision) in [(&alias, "first", 11), (&canonical, "second", 12)] {
            let response = execute_for_window(
                owner,
                &json!({"command":"workspace.releaseIndexing",
                "payload":{"root":root,"ownerId":runtime,"revision":revision}})
                .to_string(),
                |request| {
                    let request: Value = serde_json::from_str(request).unwrap();
                    assert_eq!(request["payload"]["root"], canonical);
                    json!({"ok":true,"data":{"released":true}}).to_string()
                },
            );
            assert_eq!(
                serde_json::from_str::<Value>(&response).unwrap()["data"]["released"],
                true
            );
            if runtime == "first" {
                assert!(Arc::ptr_eq(&state, &root_refresh(&canonical).unwrap()));
            }
        }
        assert!(root_refresh(&canonical).is_none());
    }
}
