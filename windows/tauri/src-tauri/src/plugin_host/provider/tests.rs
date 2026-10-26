//! Deterministic ownership regression tests: no servers, sleeps or app windows.

use super::host::{matches_language_launch, preflight, Inner};
use super::runtime::dispose_once;
use super::session::{
    Core, ProviderBinding, ProviderContext, ProviderError, Reply, Status, Transport,
};
use serde_json::{json, Value};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};

#[derive(Default)]
struct ScriptedCore {
    reject_disposal: AtomicBool,
    calls: Mutex<Vec<String>>,
}
impl Core for ScriptedCore {
    fn execute(&self, command: &str, _payload: Value) -> Reply {
        self.calls.lock().unwrap().push(command.into());
        if command == "lsp.destroyServer" && self.reject_disposal.load(Ordering::Acquire) {
            return Err(ProviderError::new(
                "provider.stopFailed",
                "scripted descendant still alive",
            ));
        }
        Ok(json!({}))
    }
    fn start(&self, _payload: Value, registered: &dyn Fn(&str)) -> Reply {
        registered("session-1");
        Err(ProviderError::new(
            "provider.startFailed",
            "scripted first write failed",
        ))
    }
}

fn context() -> ProviderContext {
    ProviderContext {
        window: "workspace-a".into(),
        workspace_root: "/fixture/workspace".into(),
        launch_workspace_root: "/fixture/workspace".into(),
        generation: 7,
        plugin_id: "fixture.provider".into(),
        package_identity: "package:whole-digest".into(),
        build_system: "fixture-system".into(),
        instance_root: "module-a".into(),
        instance_directory: "/fixture/workspace/module-a".into(),
    }
}

fn entry(core: Arc<ScriptedCore>) -> Arc<Transport> {
    Arc::new(Transport {
        id: 1,
        context: context(),
        language: None,
        launch_plan: None,
        status: Mutex::new(Status {
            generation: 7,
            session_id: Some("session-1".into()),
            launch_finished: true,
            ready: true,
            negotiated: true,
            ..Default::default()
        }),
        changed: Default::default(),
        stopping: Default::default(),
        core,
        lease: Mutex::new(None),
    })
}

fn plan() -> Value {
    json!({"root":context().instance_root,"buildSystemID":context().build_system,
    "provider":{"method":"lithe/build/model","params":{
        "root":context().instance_root,"buildSystemID":context().build_system,"options":{"mode":"test"},
    }}})
}

#[test]
fn identity_rejects_cross_instance_and_build_system_before_request() {
    let transport = entry(Arc::new(ScriptedCore::default()));
    let binding = ProviderBinding {
        approval_plan: json!({}),
        transport,
        context: context(),
    };
    let valid = plan();
    let payload = binding.request_payload("op", &valid, 250).unwrap();
    assert_eq!(payload["params"], valid["provider"]["params"]);
    for path in ["root", "buildSystemID"] {
        let mut wrong = valid.clone();
        wrong[path] = json!("foreign");
        assert_eq!(
            binding.request_payload("op", &wrong, 250).unwrap_err().code,
            "provider.identityChanged"
        );
        let mut wrong = valid.clone();
        wrong["provider"]["params"][path] = json!("foreign");
        assert!(binding.request_payload("op", &wrong, 250).is_err());
    }
}

#[test]
fn native_instance_proof_keeps_core_relative_root_and_refuses_escape() {
    let workspace = std::env::temp_dir().canonicalize().unwrap();
    let actual = super::super::build_resolver::WindowsBuildToolResolver::instance_root_directory(
        ".", &workspace,
    )
    .unwrap();
    assert_eq!(actual, workspace);
    for root in ["../escape", "/absolute", "C:/absolute", r"..\escape"] {
        assert!(
            super::super::build_resolver::WindowsBuildToolResolver::instance_root_directory(
                root, &workspace
            )
            .is_err(),
            "{root}"
        );
    }
}

#[cfg(windows)]
#[test]
fn canonical_windows_prefix_does_not_change_core_provider_params() {
    assert!(super::session::same_root(
        r"\\?\C:\fixture\workspace\module-a",
        "C:/fixture/workspace/module-a"
    ));
    assert!(super::session::same_root(
        r"\\?\UNC\server\share\project",
        r"\\server\share\project"
    ));
}

#[test]
fn one_completion_resolves_only_its_native_session_and_operation() {
    let transport = entry(Arc::new(ScriptedCore::default()));
    let mut first = transport.queue("op-a").unwrap();
    let mut second = transport.queue("op-b").unwrap();
    assert!(transport.queue("op-a").is_err());
    let event = json!({"type":"requestCompleted","sessionId":"foreign","operationId":"op-a","result":{"value":{"modules":[]}}});
    transport.observe(&event);
    assert!(matches!(
        first.try_recv(),
        Err(tokio::sync::oneshot::error::TryRecvError::Empty)
    ));
    let mut event = event;
    event["sessionId"] = json!("session-1");
    transport.observe(&event);
    assert_eq!(first.try_recv().unwrap().unwrap(), json!({"modules":[]}));
    transport.observe(&event); // Duplicate and late events cannot resolve another waiter.
    assert!(matches!(
        second.try_recv(),
        Err(tokio::sync::oneshot::error::TryRecvError::Empty)
    ));
    transport.revoke(ProviderError::new("provider.cancelled", "test cleanup"));
    assert!(second.try_recv().unwrap().is_err());
}

#[test]
fn crash_resolves_every_waiter_and_cannot_be_revived_by_late_ready() {
    let transport = entry(Arc::new(ScriptedCore::default()));
    let mut first = transport.queue("op-a").unwrap();
    let mut second = transport.queue("op-b").unwrap();
    transport.observe(&json!({"type":"stateChanged","sessionId":"session-1","state":"failed"}));
    assert_eq!(
        first.try_recv().unwrap().unwrap_err().code,
        "provider.sessionEnded"
    );
    assert!(second.try_recv().unwrap().is_err());
    transport.observe(&json!({"type":"stateChanged","sessionId":"session-1","state":"ready"}));
    assert!(transport.queue("late").is_err());
}

#[test]
fn unnegotiated_shared_session_never_receives_build_requests() {
    let transport = entry(Arc::new(ScriptedCore::default()));
    transport.observe(
        &json!({"type":"featuresChanged","sessionId":"session-1","capabilities":["hover"]}),
    );
    assert_eq!(transport.queue("op").unwrap_err().code, "provider.notReady");
    transport.observe(
        &json!({"type":"featuresChanged","sessionId":"session-1","capabilities":["litheBuild"]}),
    );
    let mut pending = transport.queue("op").unwrap();
    // A deterministic timeout/cancel consumes the waiter before a late reply.
    transport.finish(
        "op",
        Err(ProviderError::new(
            "provider.requestTimeout",
            "test deadline",
        )),
    );
    transport.observe(&json!({"type":"requestCompleted","sessionId":"session-1","operationId":"op","result":{"value":{}}}));
    assert_eq!(
        pending.try_recv().unwrap().unwrap_err().code,
        "provider.requestTimeout"
    );
}

#[tokio::test]
async fn failed_disposal_preserves_owner_and_lease_until_positive_core_proof() {
    let core = Arc::new(ScriptedCore::default());
    core.reject_disposal.store(true, Ordering::Release);
    let transport = entry(core.clone());
    let lifecycle = super::super::lifecycle::LifecycleState::default();
    *transport.lease.lock().unwrap() = Some(lifecycle.acquire("fixture.provider").unwrap());
    let owners = Inner::default();
    owners.retain_for_test(transport.clone());
    transport.revoke(ProviderError::new("provider.cancelled", "test close"));
    assert!(!dispose_once(&owners, &transport).await);
    assert!(owners.contains_for_test(1));
    assert!(transport.lease.lock().unwrap().is_some());
    core.reject_disposal.store(false, Ordering::Release);
    assert!(dispose_once(&owners, &transport).await);
    assert!(!owners.contains_for_test(1));
    assert!(transport.lease.lock().unwrap().is_none());
    assert!(dispose_once(&owners, &transport).await); // Concurrent close is idempotent.
    assert_eq!(
        *core.calls.lock().unwrap(),
        vec![
            "lsp.stopServer",
            "lsp.destroyServer",
            "lsp.stopServer",
            "lsp.destroyServer"
        ]
    );
}

#[tokio::test]
async fn cancelling_start_keeps_barrier_until_late_start_is_owned_and_disposed() {
    let core = Arc::new(ScriptedCore::default());
    let transport = entry(core.clone());
    {
        let mut status = transport.status.lock().unwrap();
        status.launch_finished = false;
        status.session_id = None;
    }
    let owners = Inner::default();
    owners.retain_for_test(transport.clone());
    transport.revoke(ProviderError::new(
        "provider.cancelled",
        "initialization cancelled",
    ));
    assert!(!dispose_once(&owners, &transport).await);
    assert!(owners.contains_for_test(1));
    assert!(core.calls.lock().unwrap().is_empty());
    assert!(core
        .start(json!({}), &|id| transport
            .status
            .lock()
            .unwrap()
            .session_id = Some(id.into()))
        .is_err());
    assert!(!dispose_once(&owners, &transport).await);
    assert!(
        transport.status.lock().unwrap().disposed,
        "registered child is stopped before the first write returns"
    );
    assert!(
        owners.contains_for_test(1),
        "late launch worker still retains its package inputs"
    );
    transport.status.lock().unwrap().launch_finished = true;
    assert!(dispose_once(&owners, &transport).await);
    assert!(!owners.contains_for_test(1));
}

#[test]
fn shared_start_must_match_the_native_verified_language_launch() {
    let approved = json!({"pluginId":"fixture","languageId":"lang","serverPath":"/fixture/server",
        "serverArgs":["--stdio"],"initializationOptions":null,"workspaceConfiguration":null,"environment":{"TOOL":"/fixture/tool"}});
    let payload = json!({"pluginId":"fixture","providerId":"fixture","executablePath":"/fixture/server",
        "arguments":["--stdio"],"initializationOptions":null,"workspaceConfiguration":null,"environment":{"TOOL":"/fixture/tool"}});
    assert!(matches_language_launch(&approved, &payload));
    for field in [
        "pluginId",
        "providerId",
        "executablePath",
        "arguments",
        "initializationOptions",
        "workspaceConfiguration",
        "environment",
        "hostServices",
        "runtimeExecutablePath",
        "jdtlsLaunchResources",
        "cacheDirectory",
    ] {
        let mut wrong = payload.clone();
        wrong[field] = json!("foreign");
        assert!(!matches_language_launch(&approved, &wrong), "{field}");
    }
    let mut extra = payload.clone();
    extra["environment"]["UNAPPROVED"] = json!("value");
    assert!(!matches_language_launch(&approved, &extra));
}

#[test]
fn shared_owner_requires_window_workspace_generation_plugin_digest_and_language() {
    let mut transport = entry(Arc::new(ScriptedCore::default()));
    Arc::get_mut(&mut transport).unwrap().language = Some("lang".into());
    let scope = context();
    assert!(transport.matches_shared(&scope, "lang"));
    assert!(!transport.matches_shared(&scope, "foreign"));
    let mut sibling = scope.clone();
    sibling.build_system = "sibling-system".into();
    sibling.instance_root = "module-b".into();
    sibling.instance_directory = "/fixture/workspace/module-b".into();
    assert!(transport.matches_shared(&sibling, "lang"));
    for changed in 0..5 {
        let mut wrong = scope.clone();
        match changed {
            0 => wrong.window = "foreign".into(),
            1 => wrong.workspace_root = "/foreign".into(),
            2 => wrong.generation += 1,
            3 => wrong.plugin_id = "foreign".into(),
            _ => wrong.package_identity = "package:replacement-digest".into(),
        }
        assert!(
            !transport.matches_shared(&wrong, "lang"),
            "scope field {changed}"
        );
    }
    transport.revoke(ProviderError::new("provider.cancelled", "scope closed"));
    assert!(!transport.matches_shared(&scope, "lang"));
}

#[tokio::test]
async fn bridge_refuses_foreign_or_unapproved_requests_and_acknowledges_only_verified_cleanup() {
    let core = Arc::new(ScriptedCore::default());
    let mut transport = entry(core.clone());
    Arc::get_mut(&mut transport).unwrap().language = Some("lang".into());
    let owners = Inner::default();
    owners.retain_for_test(transport.clone());
    let payload = json!({"sessionId":"session-1"});
    assert!(preflight(&owners, "foreign", "lsp.pollEvents", &payload)
        .unwrap()
        .is_err());
    assert!(
        preflight(&owners, "workspace-a", "lsp.buildRequest", &payload)
            .unwrap()
            .is_err()
    );
    assert!(preflight(&owners, "workspace-a", "lsp.pollEvents", &payload).is_none());
    core.reject_disposal.store(true, Ordering::Release);
    assert!(!dispose_once(&owners, &transport).await);
    assert!(
        preflight(&owners, "workspace-a", "lsp.destroyServer", &payload).is_none(),
        "failed cleanup cannot synthesize a success"
    );
    core.reject_disposal.store(false, Ordering::Release);
    assert!(dispose_once(&owners, &transport).await);
    assert!(
        preflight(&owners, "workspace-a", "lsp.stopServer", &payload)
            .unwrap()
            .is_ok()
    );
    assert!(
        preflight(&owners, "workspace-a", "lsp.destroyServer", &payload)
            .unwrap()
            .is_ok()
    );
    assert!(preflight(&owners, "foreign", "lsp.destroyServer", &payload)
        .unwrap()
        .is_err());
}

#[test]
fn real_core_contract_plans_distinguish_dedicated_and_same_plugin_language_sources() {
    for (manifest, expected) in [
        (include_str!(concat!(env!("CARGO_MANIFEST_DIR"),"/../../../shared/contracts/plugins/v1/fixtures/build-provider.plugin.json")),None),
        (include_str!(concat!(env!("CARGO_MANIFEST_DIR"),"/../../../shared/contracts/plugins/v1/fixtures/build-provider-language-server.plugin.json")),Some("elixir")),
    ] {
        let manifest:Value=serde_json::from_str(manifest).unwrap();
        let result=super::super::scan::core_execute("plugins.declarative.languageServerLaunchPlan",json!({
            "buildSystemID":manifest["buildSystems"][0]["id"],"manifest":manifest,
            "request":{"pluginDirectory":"/fixture/plugin","stateDirectory":"/fixture/state",
                "workspaceStateDirectory":"/fixture/state/workspace","architecture":"x86_64","settings":{},"projectSettings":{}},
        })).unwrap();
        assert_ne!(result["status"],"rejected","{result}");
        assert_eq!(result["plan"]["buildProvider"]["languageServer"].as_str(),expected);
        assert!(result["plan"]["buildProvider"]["executesProjectCode"].as_bool().unwrap());
        let model=super::super::scan::core_execute("build.modelPlan",json!({
            "buildSystemID":manifest["buildSystems"][0]["id"],"manifest":manifest,
            "request":{"root":"module-a","options":{}},
        })).unwrap();
        assert_eq!(model["plan"]["root"],"module-a","{model}");
        let transport=entry(Arc::new(ScriptedCore::default()));
        let mut context=context();
        context.build_system=manifest["buildSystems"][0]["id"].as_str().unwrap().into();
        let binding=ProviderBinding{transport,context,approval_plan:json!({})};
        let forwarded=binding.request_payload("core-plan",&model["plan"],500).unwrap();
        assert_eq!(forwarded["params"],model["plan"]["provider"]["params"]);
    }
}

#[test]
fn cancelling_one_initialization_waiter_preserves_the_other_waiter() {
    let transport = entry(Arc::new(ScriptedCore::default()));
    let owners = Arc::new(Inner::default());
    let first = super::runtime::OpenGuard::new(owners.clone(), transport.clone());
    let mut second = super::runtime::OpenGuard::new(owners, transport.clone());
    assert_eq!(transport.status.lock().unwrap().open_waiters, 2);
    drop(first);
    assert!(!transport.status.lock().unwrap().revoked);
    second.commit();
    assert!(transport.status.lock().unwrap().bound);
    assert_eq!(transport.status.lock().unwrap().open_waiters, 0);
}

#[tokio::test]
async fn cancelling_one_dispatched_request_does_not_cancel_a_shared_waiter() {
    #[derive(Default)]
    struct Commands {
        values: Mutex<Vec<(String, Value)>>,
        changed: tokio::sync::Notify,
    }
    impl Commands {
        async fn until(&self, count: usize) {
            tokio::time::timeout(std::time::Duration::from_secs(2), async {
                loop {
                    let changed = self.changed.notified();
                    tokio::pin!(changed);
                    changed.as_mut().enable();
                    if self.values.lock().unwrap().len() >= count {
                        return;
                    }
                    changed.await;
                }
            })
            .await
            .expect("native dispatch gate");
        }
    }
    impl Core for Commands {
        fn execute(&self, command: &str, payload: Value) -> Reply {
            self.values.lock().unwrap().push((command.into(), payload));
            self.changed.notify_waiters();
            Ok(json!({}))
        }
        fn start(&self, _: Value, _: &dyn Fn(&str)) -> Reply {
            panic!("sharing must never launch another process")
        }
    }
    let core = Arc::new(Commands::default());
    let mut transport = entry(Arc::new(ScriptedCore::default()));
    Arc::get_mut(&mut transport).unwrap().core = core.clone();
    let mut first = Box::pin(super::runtime::dispatch_request(
        &transport,
        "first".into(),
        json!({"operationId":"first"}),
        5000,
    ));
    let mut second = Box::pin(super::runtime::dispatch_request(
        &transport,
        "second".into(),
        json!({"operationId":"second"}),
        5000,
    ));
    // Both requests reach Core before cancellation; the observable dispatch
    // gate establishes ordering without scheduler-turn or wall-clock guesses.
    tokio::select! {
        result=&mut first=>panic!("first completed before reply: {result:?}"),
        result=&mut second=>panic!("second completed before reply: {result:?}"),
        _=core.until(2)=>{},
    }
    drop(first);
    core.until(3).await;
    {
        let values = core.values.lock().unwrap();
        assert_eq!(values[2].0, "lsp.cancelOperation");
        assert_eq!(values[2].1["operationId"], "first");
    }
    transport.observe(&json!({"type":"requestCompleted","sessionId":"session-1","operationId":"first","result":{"value":{"late":true}}}));
    transport.observe(&json!({"type":"requestCompleted","sessionId":"session-1","operationId":"second","result":{"value":{"kept":true}}}));
    let reply = tokio::time::timeout(std::time::Duration::from_secs(2), second)
        .await
        .unwrap()
        .unwrap();
    assert_eq!(reply, json!({"kept":true}));
    assert!(!transport.status.lock().unwrap().revoked);
    core.until(4).await; // Drain the final harmless cancellation before teardown.
}
