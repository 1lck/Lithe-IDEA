use super::super::super::build_registry::{BuildPackageInput, StoredSystemOptions};
use super::super::{
    navigate_page, owned_label, revoke_owners, state_key, PageOwner, PendingOpenFile,
};
use super::*;
use std::path::PathBuf;
use std::sync::atomic::AtomicUsize;

fn page(
    state: &WebPageHostState,
    host: &str,
    workspace: &str,
    plugin: &str,
    window: &str,
) -> (String, BridgeIdentity) {
    let mut owner = PageOwner {
        generation: super::super::OPEN_PAGE_SEQUENCE.fetch_add(1, Ordering::Relaxed),
        workspace_generation: 0,
        host_label: host.into(),
        workspace_id: workspace.into(),
        workspace_path: format!("C:/fixture/{workspace}"),
        plugin_id: plugin.into(),
        window_id: window.into(),
        state_id: String::new(),
    };
    let label = owned_label(&owner);
    owner.state_id = label.clone();
    let identity = BridgeIdentity {
        generation: owner.generation,
        workspace_generation: owner.workspace_generation,
        plugin_id: owner.plugin_id.clone(),
        window_id: owner.window_id.clone(),
        host_label: owner.host_label.clone(),
        workspace_id: owner.workspace_id.clone(),
        workspace_path: owner.workspace_path.clone(),
        state_id: label.clone(),
    };
    state.owners.lock().unwrap().insert(label.clone(), owner);
    (label, identity)
}

fn pending(
    label: &str,
    identity: &BridgeIdentity,
    now: Instant,
) -> (Arc<PendingBuild>, oneshot::Receiver<Result<Value, String>>) {
    let (sender, receiver) = oneshot::channel();
    (
        Arc::new(PendingBuild {
            page_label: label.into(),
            identity: identity.clone(),
            request: BuildRequest::Instances,
            deadline: now + REQUEST_TIMEOUT,
            claimed: AtomicBool::new(false),
            completion: Mutex::new(Some(sender)),
            reply: Mutex::new(None),
        }),
        receiver,
    )
}

fn code(error: &str) -> String {
    serde_json::from_str::<Value>(error).unwrap()["code"]
        .as_str()
        .unwrap()
        .into()
}

#[test]
fn parameters_refuse_identity_argv_unknown_fields_and_oversized_values() {
    assert!(BuildRequest::parse("build.instances", Value::Null).is_ok());
    assert!(BuildRequest::parse("build.instances", json!({})).is_ok());
    for params in [
        json!({"pluginId":"foreign"}),
        json!([]),
        json!({"workspaceRoot":"other"}),
    ] {
        assert_eq!(
            code(&BuildRequest::parse("build.instances", params).unwrap_err()),
            "plugin.web.invalidRequest"
        );
    }
    assert!(BuildRequest::parse(
        "build.setOptions",
        json!({"instance":"id","values":{"profiles":[],"offline":null}})
    )
    .is_ok());
    for params in [
        json!({"instance":"id","values":{},"argv":["run"]}),
        json!({"instance":"id","values":[],"pluginId":"foreign"}),
        json!({"instance":"","values":{}}),
        json!({"instance":"id","values":{"huge":"x".repeat(MAX_PARAMETER_BYTES)}}),
        json!({"instance":"id","values":(0..65).map(|id| (id.to_string(), json!(true))).collect::<Map<_,_>>()}),
    ] {
        assert!(BuildRequest::parse("build.setOptions", params).is_err());
    }
    for method in [
        "build.refresh",
        "build.runTask",
        "build.runTests",
        "build.cancel",
        "build.dependencies",
    ] {
        assert_eq!(
            code(&BuildRequest::parse(method, json!({})).unwrap_err()),
            "plugin.web.unavailable"
        );
    }
}

#[test]
fn foreign_host_cannot_claim_or_refuse_and_acceptance_is_single_use() {
    let state = WebPageHostState::default();
    let (label, identity) = page(&state, "main", "a", "fixture.plugin", "panel");
    let now = Instant::now();
    let (request, mut receiver) = pending(&label, &identity, now);
    let id = state.builds.admit(request.clone()).unwrap();
    assert!(state.builds.claim(&id, "workspace-other", now).is_err());
    assert!(state.builds.owned(&id, "workspace-other").is_err());
    assert!(!request.claimed.load(Ordering::Acquire));
    assert!(state.builds.claim(&id, "main", now).is_ok());
    assert!(state.builds.claim(&id, "main", now).is_err());
    // A host cleanup may revoke an already accepted request.
    state
        .builds
        .owned(&id, "main")
        .unwrap()
        .complete(Err(forbidden()));
    state.builds.remove(&id);
    assert_eq!(
        code(&receiver.try_recv().unwrap().unwrap_err()),
        "plugin.web.forbidden"
    );
    assert!(state.builds.check(&id, &request, now).is_err());
}

#[test]
fn every_request_including_unaccepted_requests_occupies_capacity_until_removed() {
    let state = WebPageHostState::default();
    let (label, identity) = page(&state, "main", "a", "fixture.plugin", "panel");
    let now = Instant::now();
    let mut ids = Vec::new();
    for _ in 0..MAX_PAGE_REQUESTS {
        let (request, _receiver) = pending(&label, &identity, now);
        ids.push(state.builds.admit(request).unwrap());
    }
    assert!(state
        .builds
        .admit(pending(&label, &identity, now).0)
        .is_err());
    state.builds.remove(&ids[0]);
    assert!(state
        .builds
        .admit(pending(&label, &identity, now).0)
        .is_ok());
    for index in 1..(MAX_HOST_REQUESTS / MAX_PAGE_REQUESTS) {
        let (other, identity) = page(
            &state,
            "main",
            "a",
            "fixture.plugin",
            &format!("panel-{index}"),
        );
        for _ in 0..MAX_PAGE_REQUESTS {
            state
                .builds
                .admit(pending(&other, &identity, now).0)
                .unwrap();
        }
    }
    let (other, identity) = page(&state, "main", "a", "fixture.plugin", "last");
    assert!(state
        .builds
        .admit(pending(&other, &identity, now).0)
        .is_err());
}

#[test]
fn injected_deadline_rejects_queued_and_already_claimed_work_without_sleep() {
    let state = WebPageHostState::default();
    let (label, identity) = page(&state, "main", "a", "fixture.plugin", "panel");
    let now = Instant::now();
    let (request, _receiver) = pending(&label, &identity, now);
    let id = state.builds.admit(request.clone()).unwrap();
    assert!(state.builds.check(&id, &request, now).is_ok());
    assert_eq!(
        code(
            &state
                .builds
                .claim(&id, "main", now + REQUEST_TIMEOUT)
                .err()
                .unwrap()
        ),
        "requestTimeout"
    );
    state.builds.claim(&id, "main", now).unwrap();
    assert_eq!(
        code(
            &state
                .builds
                .check(&id, &request, now + REQUEST_TIMEOUT)
                .unwrap_err()
        ),
        "requestTimeout"
    );
}

#[test]
fn ownership_checks_all_identity_fields_and_workspace_generation() {
    let state = WebPageHostState::default();
    let (label, identity) = page(&state, "main", "a", "fixture.plugin", "panel");
    let tamper: [fn(&mut BridgeIdentity); 8] = [
        |id| id.generation += 1,
        |id| id.workspace_generation += 1,
        |id| id.plugin_id = "foreign.plugin".into(),
        |id| id.window_id = "other".into(),
        |id| id.host_label = "workspace-other".into(),
        |id| id.workspace_id = "b".into(),
        |id| id.workspace_path = "C:/fixture/b".into(),
        |id| id.state_id = "other".into(),
    ];
    for tamper in tamper {
        let mut forged = identity.clone();
        tamper(&mut forged);
        assert!(with_page_owner(&state, &label, &forged, || Ok(())).is_err());
    }
    state
        .workspace_generations
        .lock()
        .unwrap()
        .insert(super::super::workspace_label_suffix("main", "a"), 1);
    assert!(with_page_owner(&state, &label, &identity, || Ok(())).is_err());
}

#[test]
fn navigation_revokes_build_and_open_file_requests_but_preserves_page_state() {
    let state = WebPageHostState::default();
    let (label, identity) = page(&state, "main", "a", "fixture.plugin", "panel");
    let key = state_key(&identity.plugin_id, &identity.state_id);
    state
        .states
        .lock()
        .unwrap()
        .insert(key.clone(), json!({"expanded":true}));
    let (request, mut receiver) = pending(&label, &identity, Instant::now());
    let id = state.builds.admit(request.clone()).unwrap();
    let (completion, mut file_receiver) = oneshot::channel();
    state.open_files.lock().unwrap().insert(
        "file-operation".into(),
        PendingOpenFile {
            host_label: identity.host_label.clone(),
            page_label: label.clone(),
            completion,
        },
    );
    navigate_page(&state, &label);
    assert_eq!(
        code(&receiver.try_recv().unwrap().unwrap_err()),
        "plugin.web.forbidden"
    );
    assert!(file_receiver.try_recv().is_err());
    assert!(state.open_files.lock().unwrap().is_empty());
    assert!(state.builds.check(&id, &request, Instant::now()).is_err());
    assert!(with_page_owner(&state, &label, &identity, || Ok(())).is_err());
    assert_eq!(
        state.states.lock().unwrap().get(&key),
        Some(&json!({"expanded":true}))
    );
}

#[test]
fn close_and_reopen_preserve_state_without_reviving_the_previous_document() {
    let state = WebPageHostState::default();
    let (label, identity) = page(&state, "main", "a", "fixture.plugin", "panel");
    let key = state_key(&identity.plugin_id, &identity.state_id);
    state
        .states
        .lock()
        .unwrap()
        .insert(key.clone(), json!({"selection":"kept"}));
    let (request, mut receiver) = pending(&label, &identity, Instant::now());
    let id = state.builds.admit(request).unwrap();
    revoke_owners(&state, |owner| owned_label(owner) == label, false);
    assert!(receiver.try_recv().unwrap().is_err());
    let (reopened, new_identity) = page(&state, "main", "a", "fixture.plugin", "panel");
    assert_eq!(reopened, label);
    assert_ne!(identity.generation, new_identity.generation);
    assert!(state.builds.claim(&id, "main", Instant::now()).is_err());
    assert!(with_page_owner(&state, &label, &identity, || Ok(())).is_err());
    assert!(with_page_owner(&state, &label, &new_identity, || Ok(())).is_ok());
    assert_eq!(
        state.states.lock().unwrap().get(&key),
        Some(&json!({"selection":"kept"}))
    );
}

#[test]
fn native_reply_waits_for_workbench_confirmation_and_cannot_cross_navigation() {
    let state = WebPageHostState::default();
    let (label, identity) = page(&state, "main", "a", "fixture.plugin", "panel");
    let (request, mut receiver) = pending(&label, &identity, Instant::now());
    let id = state.builds.admit(request.clone()).unwrap();
    state.builds.claim(&id, "main", Instant::now()).unwrap();
    *request.reply.lock().unwrap() = Some(ReadyBuild {
        result: Ok(json!({"instances":[]})),
        generation: Some(1),
    });
    assert!(
        receiver.try_recv().is_err(),
        "finishing native work must not publish before the workbench rechecks context"
    );
    navigate_page(&state, &label);
    assert!(with_page_owner(&state, &label, &identity, || {
        request.complete(request.reply.lock().unwrap().take().unwrap().result);
        Ok(())
    })
    .is_err());
    assert_eq!(
        code(&receiver.try_recv().unwrap().unwrap_err()),
        "plugin.web.forbidden"
    );
}

#[test]
fn plugin_workspace_host_and_page_revocation_do_not_cross_other_owners() {
    for scope in ["plugin", "workspace", "host", "page"] {
        let state = WebPageHostState::default();
        let (label, identity) = page(&state, "main", "a", "fixture.plugin", "panel");
        let (other, other_identity) = page(&state, "workspace-other", "b", "other.plugin", "panel");
        let (request, mut receiver) = pending(&label, &identity, Instant::now());
        state.builds.admit(request).unwrap();
        let (other_request, mut other_receiver) = pending(&other, &other_identity, Instant::now());
        let other_id = state.builds.admit(other_request.clone()).unwrap();
        revoke_owners(
            &state,
            |owner| match scope {
                "plugin" => owner.plugin_id == identity.plugin_id,
                "workspace" => {
                    owner.host_label == identity.host_label
                        && owner.workspace_id == identity.workspace_id
                }
                "host" => owner.host_label == identity.host_label,
                _ => owned_label(owner) == label,
            },
            true,
        );
        assert!(receiver.try_recv().unwrap().is_err());
        assert!(other_receiver.try_recv().is_err());
        assert!(state
            .builds
            .check(&other_id, &other_request, Instant::now())
            .is_ok());
        assert!(with_page_owner(&state, &other, &other_identity, || Ok(())).is_ok());
    }
}

#[derive(Default)]
struct MemoryOptions {
    value: Mutex<StoredBuildOptions>,
    writes: AtomicUsize,
}
impl BuildOptionsPersistence for MemoryOptions {
    fn load(&self, _: &str) -> Result<StoredBuildOptions, String> {
        Ok(self.value.lock().unwrap().clone())
    }
    fn save(&self, _: &str, value: &StoredBuildOptions) -> Result<(), String> {
        *self.value.lock().unwrap() = value.clone();
        self.writes.fetch_add(1, Ordering::Relaxed);
        Ok(())
    }
}

fn options(value: bool) -> StoredBuildOptions {
    StoredBuildOptions {
        systems: BTreeMap::from([(
            "cargo".into(),
            StoredSystemOptions {
                values: BTreeMap::from([("offline".into(), json!(value))]),
                empty_markers: BTreeMap::new(),
            },
        )]),
    }
}

#[test]
fn revoked_write_is_rejected_but_owned_native_rollback_remains_possible() {
    let store = MemoryOptions::default();
    let active = AtomicBool::new(true);
    let check = || {
        if active.load(Ordering::Acquire) {
            Ok(())
        } else {
            Err(timed_out())
        }
    };
    let guarded = CheckedPersistence {
        inner: &store,
        check: &check,
        previous: StoredBuildOptions::default(),
        last_written: Mutex::new(None),
    };
    active.store(false, Ordering::Release);
    assert!(guarded.save("root", &options(true)).is_err());
    assert_eq!(store.writes.load(Ordering::Relaxed), 0);
    active.store(true, Ordering::Release);
    guarded.save("root", &options(true)).unwrap();
    active.store(false, Ordering::Release);
    assert!(guarded.save("root", &options(false)).is_err());
    guarded
        .save("root", &StoredBuildOptions::default())
        .unwrap();
    assert_eq!(store.load("root").unwrap(), StoredBuildOptions::default());
    // A later external value must never be overwritten by cleanup.
    store.save("root", &options(false)).unwrap();
    assert!(guarded
        .save("root", &StoredBuildOptions::default())
        .is_err());
}

#[test]
fn page_instance_json_filters_plugins_keeps_raw_model_and_only_stored_options() {
    let model =
        json!({"projects":[{"id":"project-id","name":"app","path":"."}],"tasks":[],"targets":[]});
    let row = json!({"pluginID":"fixture.plugin","buildSystemID":"cargo","root":"nested", "model":model,
        "options":[{"id":"offline","source":"user","value":true},{"id":"release","source":"default","value":false}]});
    let foreign = json!({"pluginID":"foreign.plugin","buildSystemID":"other","root":"."});
    let view = BuildView {
        generation: 1,
        workspace_root: "C:/fixture/a".into(),
        instances: vec![row.clone(), foreign],
        issues: vec![],
    };
    let value = instances_json(&view, "fixture.plugin");
    assert_eq!(value["instances"].as_array().unwrap().len(), 1);
    assert_eq!(value["instances"][0]["model"], model);
    assert_eq!(value["instances"][0]["state"], "loaded");
    assert_eq!(value["instances"][0]["options"], json!({"offline":true}));
    assert_ne!(
        instance_id(&row),
        instance_id(&json!({"pluginID":"fixture.plugin","buildSystemID":"cargo","root":"."}))
    );
    assert_eq!(
        code(
            &validate_option_names(&row, &BTreeMap::from([("argv".into(), json!([]))]))
                .unwrap_err()
        ),
        "plugin.web.invalidRequest"
    );
}

struct Fixture(PathBuf);
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}
struct Packages(Mutex<BuildPackageInput>);
impl BuildPackageSource for Packages {
    fn accepted_packages(&self) -> Vec<BuildPackageInput> {
        vec![self.0.lock().unwrap().clone()]
    }
    fn package(&self, id: &str) -> Option<BuildPackageInput> {
        let package = self.0.lock().unwrap();
        (package.plugin_id == id).then(|| package.clone())
    }
}

#[test]
fn real_core_options_persist_reset_invalidate_fingerprint_and_refuse_replaced_package() {
    let fixture = Fixture(super::super::serve_tests::unique_temp_root("web-build"));
    std::fs::write(
        fixture.0.join("Cargo.toml"),
        "[package]\nname='fixture'\nversion='0.1.0'\n[features]\nweb=[]\n",
    )
    .unwrap();
    std::fs::create_dir(fixture.0.join("nested")).unwrap();
    std::fs::write(
        fixture.0.join("nested/Cargo.toml"),
        "[package]\nname='nested'\nversion='0.1.0'\n",
    )
    .unwrap();
    let declaration: Value = serde_json::from_str(include_str!(
        "../../../../../shared/contracts/plugins/v1/fixtures/build-static-file.plugin.json"
    ))
    .unwrap();
    let plugin = declaration["id"].as_str().unwrap().to_string();
    let packages = Packages(Mutex::new(BuildPackageInput {
        plugin_id: plugin.clone(),
        version: "0.1.0".into(),
        manifest: declaration,
        content_identity: "original".into(),
    }));
    let persistence = MemoryOptions::default();
    let root = fixture.0.to_string_lossy().into_owned();
    let state = WebPageHostState::default();
    let (_, mut identity) = page(&state, "main", "a", &plugin, "panel");
    identity.workspace_path = root.clone();
    let mut registry = BuildRegistry::new();
    registry
        .refresh(&HostCoreExecutor, &packages, &persistence, "main", &root)
        .unwrap();
    let (first, contexts) = checked_view(&registry, &packages, &identity).unwrap();
    let nested = first
        .instances
        .iter()
        .find(|row| row["root"] == "nested")
        .expect("nested instance");
    assert_eq!(
        selected_context(&first, &contexts, &instance_id(nested).unwrap())
            .unwrap()
            .1
            .root,
        "nested"
    );
    let mut forged = nested.clone();
    forged["pluginID"] = json!("foreign.plugin");
    let mut with_foreign = first.clone();
    with_foreign.instances.push(forged.clone());
    assert!(selected_context(&with_foreign, &contexts, &instance_id(&forged).unwrap()).is_err());
    let context = &contexts[0];
    let original = first.instances[0]["optionFingerprint"].clone();
    let initial_writes = persistence.writes.load(Ordering::Relaxed);
    assert!(validate_option_values(
        &HostCoreExecutor,
        context,
        &BTreeMap::from([("offline".into(), json!("wrong type"))])
    )
    .is_err());
    assert_eq!(persistence.writes.load(Ordering::Relaxed), initial_writes);
    validate_option_values(
        &HostCoreExecutor,
        context,
        &BTreeMap::from([("offline".into(), json!(true))]),
    )
    .unwrap();
    let edited = registry
        .set_option(
            &HostCoreExecutor,
            &packages,
            &persistence,
            "main",
            &root,
            &plugin,
            "cargo",
            ".",
            "offline",
            Some(json!(true)),
        )
        .unwrap();
    assert_eq!(stored_options(&edited.instances[0])["offline"], true);
    assert_ne!(edited.instances[0]["optionFingerprint"], original);
    let empty = registry
        .set_option(
            &HostCoreExecutor,
            &packages,
            &persistence,
            "main",
            &root,
            &plugin,
            "cargo",
            ".",
            "features",
            Some(json!([])),
        )
        .unwrap();
    assert_eq!(stored_options(&empty.instances[0])["features"], json!([]));
    let reset = registry
        .set_option(
            &HostCoreExecutor,
            &packages,
            &persistence,
            "main",
            &root,
            &plugin,
            "cargo",
            ".",
            "offline",
            None,
        )
        .unwrap();
    assert!(stored_options(&reset.instances[0]).get("offline").is_none());
    registry.suspend_execution("main");
    assert!(checked_view(&registry, &packages, &identity).is_err());
    registry.resume_execution("main");
    assert!(checked_view(&registry, &packages, &identity).is_ok());
    let refresh = registry.reserve_refresh("main", &root);
    assert!(checked_view(&registry, &packages, &identity).is_err());
    registry
        .refresh_reserved(
            &HostCoreExecutor,
            &packages,
            &persistence,
            &refresh,
            &|| Ok(()),
        )
        .unwrap();
    assert!(checked_view(&registry, &packages, &identity).is_ok());
    packages.0.lock().unwrap().content_identity = "same-version-replacement".into();
    assert!(checked_view(&registry, &packages, &identity).is_err());
    registry.close_workspace("main", &root);
    assert!(checked_view(&registry, &packages, &identity).is_err());
}
