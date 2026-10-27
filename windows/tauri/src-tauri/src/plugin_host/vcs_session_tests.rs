//! Deterministic transport boundaries; Core decodes the real status contract.
use super::*;
use crate::plugin_host::lifecycle::LifecycleState;
use std::collections::VecDeque;

const DEADLINE: Duration = Duration::from_secs(2);
#[derive(Default)]
struct ScriptedRuntime {
    calls: Mutex<Vec<(String, Value)>>,
    events: Mutex<VecDeque<Vec<Value>>>,
    reject_disposal: AtomicBool,
    reject_start: AtomicBool,
}
impl Runtime for ScriptedRuntime {
    fn execute(&self, command: &str, payload: Value) -> Reply {
        self.calls
            .lock()
            .unwrap()
            .push((command.into(), payload.clone()));
        match command {
            "lsp.waitEvents" => self
                .events
                .lock()
                .unwrap()
                .pop_front()
                .map(|events| json!({"events":events}))
                .ok_or_else(|| "fixture event script exhausted".into()),
            "vcs.decodeReply" => crate::plugin_host::scan::core_execute(command, payload),
            "lsp.destroyServer" if self.reject_disposal.load(Ordering::Acquire) => {
                Err(CLEANUP_FAILED.into())
            }
            _ => Ok(json!({})),
        }
    }
    fn start(&self, payload: Value, registered: &dyn Fn(&str)) -> Reply {
        self.calls
            .lock()
            .unwrap()
            .push(("lsp.startServer".into(), payload));
        registered("fixture-session");
        if self.reject_start.load(Ordering::Acquire) {
            Err("fixture first write failed".into())
        } else {
            Ok(json!({"sessionId":"fixture-session"}))
        }
    }
}
fn context() -> Context {
    Context {
        host: "workspace-fixture".into(),
        scope: Scope {
            workspace_id: "fixture".into(),
            workspace_root: std::env::temp_dir().to_string_lossy().into_owned(),
            incarnation: "one".into(),
        },
        generation: 7,
        registration: 3,
        request_id: "fixture-request".into(),
        root: Root {
            id: "legacy".into(),
            vcs: "svn".into(),
            path: std::env::temp_dir()
                .join("legacy")
                .to_string_lossy()
                .into_owned(),
            mapped: false,
        },
        root_identity: "fixture-directory-identity".into(),
        plugin_id: "fixture.plugin".into(),
        package_identity: "whole-package-digest".into(),
        settings_revision: 0,
    }
}

#[test]
fn scoped_settings_reload_revokes_only_its_plugin_and_original_workspace_window() {
    let sessions = Sessions::default();
    let original = context();
    let mut contexts = vec![original.clone(); 4];
    contexts[1].host = "another-window".into();
    contexts[2].plugin_id = "another.plugin".into();
    contexts[2].root.path.push_str("-another-plugin");
    contexts[3]
        .scope
        .workspace_root
        .push_str("-another-workspace");
    contexts[3].root.path.push_str("-another-workspace");
    let mut owners = Vec::new();
    for (index, mut context) in contexts.into_iter().enumerate() {
        context.request_id = format!("scope-request-{index}");
        let owner = owner(context, Arc::new(ScriptedRuntime::default()));
        sessions.insert(owner.clone(), || true).unwrap();
        owners.push(owner);
    }
    let revoked = sessions.matching(|context| {
        context.settings_scope(
            &original.host,
            &original.scope.workspace_root,
            &original.plugin_id,
        )
    });
    assert_eq!(revoked.len(), 1);
    assert!(Arc::ptr_eq(&revoked[0], &owners[0]));
    assert_eq!(owners[0].current().unwrap_err(), CANCELLED);
    assert!(owners[1..].iter().all(|owner| owner.current().is_ok()));
}
fn owner(context: Context, runtime: Arc<dyn Runtime>) -> Arc<Owner> {
    let lifecycle = LifecycleState::default();
    let lease = lifecycle.acquire(&context.plugin_id).unwrap();
    let mut owner = Owner::new(context, lease);
    Arc::get_mut(&mut owner).unwrap().runtime = runtime;
    owner
}

struct StartGate(Option<std::sync::mpsc::Sender<()>>);
impl StartGate {
    fn release(&mut self) {
        if let Some(sender) = self.0.take() {
            let _ = sender.send(());
        }
    }
}
impl Drop for StartGate {
    fn drop(&mut self) {
        self.release();
    }
}
struct DelayedStartRuntime {
    script: Arc<ScriptedRuntime>,
    entered: Mutex<Option<tokio::sync::oneshot::Sender<()>>>,
    release: Mutex<std::sync::mpsc::Receiver<()>>,
    destroyed: Mutex<Option<tokio::sync::oneshot::Sender<()>>>,
}
impl Runtime for DelayedStartRuntime {
    fn execute(&self, command: &str, payload: Value) -> Reply {
        let result = self.script.execute(command, payload);
        if command == "lsp.destroyServer" {
            if let Some(sender) = self.destroyed.lock().unwrap().take() {
                let _ = sender.send(());
            }
        }
        result
    }
    fn start(&self, payload: Value, registered: &dyn Fn(&str)) -> Reply {
        if let Some(sender) = self.entered.lock().unwrap().take() {
            let _ = sender.send(());
        }
        // The native boundary is blocking; its gate is released on failure
        // as well as success, and its own deadline bounds a failed test.
        self.release
            .lock()
            .unwrap()
            .recv_timeout(DEADLINE)
            .map_err(|_| "fixture launch gate timed out".to_string())?;
        self.script.start(payload, registered)
    }
}
struct DelayedDestroyRuntime {
    script: Arc<ScriptedRuntime>,
    entered: Mutex<Option<tokio::sync::oneshot::Sender<()>>>,
    release: Mutex<std::sync::mpsc::Receiver<()>>,
    first: AtomicBool,
    destroyed: AtomicBool,
    reject_first: bool,
}
impl Runtime for DelayedDestroyRuntime {
    fn execute(&self, command: &str, payload: Value) -> Reply {
        let result = self.script.execute(command, payload);
        if command != "lsp.destroyServer" {
            return result;
        }
        if self.first.swap(false, Ordering::AcqRel) {
            if let Some(sender) = self.entered.lock().unwrap().take() {
                let _ = sender.send(());
            }
            // Only the native blocking worker waits here. Drop releases the
            // gate after assertions fail, and this local deadline also bounds it.
            self.release
                .lock()
                .unwrap()
                .recv_timeout(DEADLINE)
                .map_err(|_| "fixture disposal gate timed out".to_string())?;
            if self.reject_first {
                return Err(CLEANUP_FAILED.into());
            }
        }
        if self.destroyed.swap(true, Ordering::AcqRel) {
            return Err("unknown_session".into());
        }
        Ok(json!({}))
    }
    fn start(&self, payload: Value, registered: &dyn Fn(&str)) -> Reply {
        self.script.start(payload, registered)
    }
}
fn capabilities() -> Value {
    json!({"status":1,"baseContent":1,"checkin":1,"rollback":1})
}
fn ready(vcs: &str) -> Vec<Value> {
    vec![
        json!({"type":"vcsProvider","sessionId":"fixture-session","result":{"vcs":vcs,"capabilities":capabilities()}}),
        json!({"type":"stateChanged","sessionId":"fixture-session","state":"ready"}),
    ]
}

#[tokio::test]
async fn status_uses_core_negotiation_shape_request_and_real_reply_decoder() {
    tokio::time::timeout(DEADLINE,async {
        let runtime=Arc::new(ScriptedRuntime::default());
        runtime.events.lock().unwrap().extend([ready("svn"),vec![json!({"type":"requestCompleted","sessionId":"fixture-session","operationId":"foreign","result":{"value":{}}}),
            json!({"type":"requestCompleted","sessionId":"fixture-session","operationId":"fixture-request","result":{"value":{
                "head":{"location":"https://user:secret@example.invalid/repo?token=hidden#fragment"},
                "changes":[{"path":"z.txt","status":"modified"},{"path":"a.txt","status":"added"}]}}})]]);
        let owner=owner(context(),runtime.clone());
        owner.start(|| Ok((json!({"pluginId":"fixture.plugin"}),Some("fixture-vcs-tool".into())))).await.unwrap();
        let result=owner.status(|| Ok(())).await.unwrap();
        assert_eq!(result["changes"][0]["path"],"a.txt");
        assert_eq!(result["head"]["location"],"https://example.invalid/repo");
        let calls=runtime.calls.lock().unwrap().clone();
        let payload=&calls.iter().find(|(command,_)| command=="lsp.vcsRequest").unwrap().1;
        assert_eq!(payload["operation"],"status");
        assert_eq!(payload["root"],owner.context.root.path);
        assert_eq!(payload["tool"],"fixture-vcs-tool");
        assert_eq!(payload["arguments"],json!({"includeIgnored":false}));
        assert!(calls.iter().any(|(command,_)| command=="vcs.decodeReply"));
        owner.stop().await.unwrap();
        assert!(owner.lease.lock().unwrap().is_none());
    }).await.expect("bounded native status");
}

#[tokio::test]
async fn a_different_negotiated_vcs_never_receives_a_status_request() {
    tokio::time::timeout(DEADLINE, async {
        let runtime = Arc::new(ScriptedRuntime::default());
        runtime.events.lock().unwrap().push_back(ready("foreign"));
        let owner = owner(context(), runtime.clone());
        owner.start(|| Ok((json!({}), None))).await.unwrap();
        assert_eq!(
            owner.status(|| Ok(())).await.unwrap_err(),
            "vcs.provider.unavailable"
        );
        assert!(!runtime
            .calls
            .lock()
            .unwrap()
            .iter()
            .any(|(command, _)| command == "lsp.vcsRequest"));
        owner.stop().await.unwrap();
    })
    .await
    .expect("bounded rejected negotiation");
}

#[tokio::test]
async fn typed_history_file_history_and_baseline_reads_share_the_core_decoder_and_owner() {
    use super::super::query::ReadOperation;
    tokio::time::timeout(DEADLINE, async {
        for (operation, reply) in [
            (ReadOperation::History { cursor: Some("opaque-before".into()), limit: 2 },
                json!({"entries":[{"revision":{"id":"9","kind":"number"},"changes":[]}],"nextCursor":"opaque-after"})),
            (ReadOperation::FileHistory { path: "deleted.txt".into(), cursor: None, limit: 2 },
                json!({"entries":[],"nextCursor":null})),
            (ReadOperation::BaseContent { path: "old.txt".into(), current_path: "new.txt".into() },
                json!({"content":null,"binary":false})),
        ] {
            let runtime = Arc::new(ScriptedRuntime::default());
            let mut negotiated = ready("svn");
            negotiated[0]["result"]["capabilities"][operation.name()] = json!(1);
            runtime.events.lock().unwrap().extend([
                negotiated,
                vec![json!({"type":"requestCompleted","sessionId":"fixture-session",
                    "operationId":"fixture-request","result":{"value":reply}})],
            ]);
            let owner = owner(context(), runtime.clone());
            owner.start(|| Ok((json!({}), None))).await.unwrap();
            let result = owner.read(&operation, || Ok(())).await.unwrap();
            owner.stop().await.unwrap();
            let calls = runtime.calls.lock().unwrap();
            let request = &calls.iter().find(|(name, _)| name == "lsp.vcsRequest").unwrap().1;
            assert_eq!(request["operation"], operation.name());
            assert_eq!(request["arguments"], operation.arguments());
            assert!(calls.iter().any(|(name, payload)| name == "vcs.decodeReply" && payload["operation"] == operation.name()));
            assert!(calls.iter().any(|(name, _)| name == "lsp.destroyServer"));
            if operation.name() == "history" {
                assert_eq!(result["entries"][0]["revision"]["id"], "9");
                assert_eq!(result["nextCursor"], "opaque-after");
            }
        }
    }).await.expect("bounded typed VCS reads");
}

#[tokio::test]
async fn malformed_status_is_rejected_by_core_and_never_becomes_a_snapshot() {
    tokio::time::timeout(DEADLINE,async {
        let runtime=Arc::new(ScriptedRuntime::default());
        runtime.events.lock().unwrap().extend([ready("svn"),vec![json!({"type":"requestCompleted","sessionId":"fixture-session","operationId":"fixture-request", "result":{"value":{"changes":[{"path":"../escape","status":"modified"}]}}})]]);
        let owner=owner(context(),runtime);
        owner.start(|| Ok((json!({}),None))).await.unwrap();
        assert_eq!(owner.status(|| Ok(())).await.unwrap_err(),"plugin.vcs.invalidOutput");
        owner.stop().await.unwrap();
    }).await.expect("bounded rejected reply");
}

#[tokio::test]
async fn core_initialize_and_request_timeouts_keep_their_category_and_cleanup_owner() {
    tokio::time::timeout(DEADLINE, async {
        for initialize in [true, false] {
            let runtime = Arc::new(ScriptedRuntime::default());
            if initialize {
                runtime.events.lock().unwrap().push_back(vec![json!({"type":"stateChanged",
                    "sessionId":"fixture-session","state":"failed","error":{"code":"initializeTimeout"}})]);
            } else {
                runtime.events.lock().unwrap().extend([ready("svn"),vec![json!({"type":"requestCompleted",
                    "sessionId":"fixture-session","operationId":"fixture-request","error":{"code":"requestTimeout"}})]]);
            }
            let owner = owner(context(), runtime.clone());
            owner.start(|| Ok((json!({}), None))).await.unwrap();
            assert_eq!(owner.status(|| Ok(())).await.unwrap_err(), "requestTimeout");
            assert!(owner.lease.lock().unwrap().is_some());
            owner.stop().await.unwrap();
            assert!(owner.lease.lock().unwrap().is_none());
            let calls = runtime.calls.lock().unwrap();
            assert_eq!(calls.iter().any(|(command,_)| command == "lsp.vcsRequest"), !initialize);
            assert!(calls.iter().any(|(command,_)| command == "lsp.destroyServer"));
        }
    }).await.expect("bounded timeout events");
}

#[test]
fn completed_requests_require_the_core_value_envelope_and_keep_only_known_failure_categories() {
    assert_eq!(
        completed(&json!({"result":{"changes":[]}})).unwrap_err(),
        "plugin.vcs.invalidOutput"
    );
    assert_eq!(
        completed(&json!({"result":{"value":{"changes":[]}}})).unwrap(),
        json!({"changes":[]})
    );
    assert_eq!(
        completed(&json!({"error":{"code":"vcs.authentication.failed"}})).unwrap_err(),
        "vcs.authentication.failed"
    );
    assert_eq!(
        completed(&json!({"error":{"code":"untrusted.plugin.failure"}})).unwrap_err(),
        "vcs.provider.failed"
    );
}

#[tokio::test]
async fn failed_destroy_keeps_the_native_owner_and_lease_until_retry_confirms_cleanup() {
    tokio::time::timeout(DEADLINE, async {
        let runtime = Arc::new(ScriptedRuntime::default());
        runtime.reject_disposal.store(true, Ordering::Release);
        let owner = owner(context(), runtime.clone());
        owner.state.lock().unwrap().session = Some("fixture-session".into());
        let sessions = Sessions::default();
        sessions.insert(owner.clone(), || true).unwrap();
        assert!(!owner.dispose_once().await);
        assert!(owner.lease.lock().unwrap().is_some());
        assert_eq!(sessions.matching(|_| true).len(), 1);
        runtime.reject_disposal.store(false, Ordering::Release);
        sessions.cleanup(owner.clone()).await.unwrap();
        assert!(owner.lease.lock().unwrap().is_none());
        assert!(sessions.matching(|_| true).is_empty());
    })
    .await
    .expect("bounded cleanup retry");
}

#[tokio::test]
async fn a_late_launch_worker_retains_its_lease_after_the_process_tree_is_destroyed() {
    tokio::time::timeout(DEADLINE, async {
        let owner = owner(context(), Arc::new(ScriptedRuntime::default()));
        {
            let mut state = owner.state.lock().unwrap();
            state.session = Some("fixture-session".into());
            state.launch_finished = false;
        }
        assert!(!owner.dispose_once().await);
        assert!(owner.lease.lock().unwrap().is_some());
        owner.state.lock().unwrap().launch_finished = true;
        owner.stop().await.unwrap();
        assert!(owner.lease.lock().unwrap().is_none());
    })
    .await
    .expect("bounded late worker cleanup");
}

#[tokio::test]
async fn a_late_start_after_window_cleanup_deadline_is_automatically_destroyed() {
    tokio::time::timeout(DEADLINE, async {
        let script = Arc::new(ScriptedRuntime::default());
        let (entered, entered_rx) = tokio::sync::oneshot::channel();
        let (release, release_rx) = std::sync::mpsc::channel();
        let (destroyed, destroyed_rx) = tokio::sync::oneshot::channel();
        let mut gate = StartGate(Some(release));
        let runtime = Arc::new(DelayedStartRuntime {
            script: script.clone(),
            entered: Mutex::new(Some(entered)),
            release: Mutex::new(release_rx),
            destroyed: Mutex::new(Some(destroyed)),
        });
        let owner = owner(context(), runtime);
        let sessions = Arc::new(Sessions::default());
        sessions.insert(owner.clone(), || true).unwrap();
        let starting = owner.start(|| Ok((json!({}), None)));
        tokio::pin!(starting);
        tokio::select! {
            result = &mut starting => panic!("start must wait for its controlled gate: {result:?}"),
            result = entered_rx => result.expect("native launcher reached its gate"),
        }
        // Window destruction revokes this exact owner. Expire its caller's
        // cleanup budget before allowing Core to register the late process.
        let closing = sessions.matching(|context| context.host == "workspace-fixture");
        assert_eq!(closing.len(), 1);
        assert!(
            tokio::time::timeout(Duration::ZERO, sessions.cleanup(closing[0].clone()))
                .await
                .is_err()
        );
        assert!(owner.session().is_none());
        assert!(owner.lease.lock().unwrap().is_some());
        gate.release();
        assert_eq!(starting.await.unwrap_err(), CANCELLED);
        // Only the completion reaper can produce this signal: the original
        // cleanup ended and the test has not requested another cleanup yet.
        destroyed_rx
            .await
            .expect("late process was automatically destroyed");
        // Drain the serialized owner before assertions/teardown; a concurrent
        // completion cleanup must not issue duplicate stop/destroy commands.
        sessions.cleanup(owner.clone()).await.unwrap();
        assert!(owner.lease.lock().unwrap().is_none());
        assert!(sessions.matching(|_| true).is_empty());
        let calls = script.calls.lock().unwrap();
        for expected in ["lsp.stopServer", "lsp.destroyServer"] {
            assert_eq!(
                calls
                    .iter()
                    .filter(|(command, _)| command == expected)
                    .count(),
                1
            );
        }
    })
    .await
    .expect("bounded late launch completion cleanup");
}

#[tokio::test]
async fn a_late_cleanup_cannot_remove_or_stop_a_replacement_owner() {
    tokio::time::timeout(DEADLINE, async {
        let sessions = Sessions::default();
        let previous = owner(context(), Arc::new(ScriptedRuntime::default()));
        previous.state.lock().unwrap().session = Some("previous-session".into());
        sessions.insert(previous.clone(), || true).unwrap();
        sessions.cleanup(previous.clone()).await.unwrap();

        // Reuse the request key after confirmed disposal. A completion cleanup
        // still carrying the old Arc must leave the replacement's lease intact.
        let runtime = Arc::new(ScriptedRuntime::default());
        let replacement = owner(context(), runtime.clone());
        replacement.state.lock().unwrap().session = Some("replacement-session".into());
        sessions.insert(replacement.clone(), || true).unwrap();
        sessions.cleanup(previous).await.unwrap();
        {
            let entries = sessions.0.lock().unwrap();
            let key = (context().host, context().request_id);
            assert!(Arc::ptr_eq(
                entries.running.get(&key).unwrap(),
                &replacement
            ));
        }
        assert!(replacement.lease.lock().unwrap().is_some());
        assert!(runtime.calls.lock().unwrap().is_empty());
        sessions.cleanup(replacement.clone()).await.unwrap();
        assert!(replacement.lease.lock().unwrap().is_none());
    })
    .await
    .expect("bounded cleanup owner identity");
}

#[tokio::test]
async fn a_destroy_worker_keeps_its_completion_proof_after_its_waiter_times_out() {
    tokio::time::timeout(DEADLINE, async {
        for reject_first in [false, true] {
            let script = Arc::new(ScriptedRuntime::default());
            let (entered, entered_rx) = tokio::sync::oneshot::channel();
            let (release, release_rx) = std::sync::mpsc::channel();
            let mut gate = StartGate(Some(release));
            let runtime = Arc::new(DelayedDestroyRuntime {
                script: script.clone(),
                entered: Mutex::new(Some(entered)),
                release: Mutex::new(release_rx),
                first: AtomicBool::new(true),
                destroyed: AtomicBool::new(false),
                reject_first,
            });
            let owner = owner(context(), runtime);
            owner.state.lock().unwrap().session = Some("fixture-session".into());
            let sessions = Sessions::default();
            sessions.insert(owner.clone(), || true).unwrap();
            owner.revoke();
            {
                let disposing = owner.dispose_once();
                tokio::pin!(disposing);
                tokio::select! {
                    result = &mut disposing => panic!("destroy must wait for its gate: {result:?}"),
                    result = entered_rx => result.expect("native destroy reached its gate"),
                }
                // Expire a caller's budget while its native destroy is still
                // running. A retry must not issue this non-idempotent RPC twice.
                assert!(tokio::time::timeout(Duration::ZERO, &mut disposing)
                    .await
                    .is_err());
                assert!(!owner.dispose_once().await);
                assert!(owner.lease.lock().unwrap().is_some());
                if reject_first {
                    gate.release();
                    assert!(!disposing.await);
                    let state = owner.state.lock().unwrap();
                    assert!(!state.disposal_running);
                    assert!(!state.disposed);
                    assert!(owner.lease.lock().unwrap().is_some());
                }
            }
            // The successful branch drops its waiter before native completion.
            // Drain the same owner to synchronize any completion cleanup before
            // teardown; the original successful RPC remains the only destroy.
            gate.release();
            sessions.cleanup(owner.clone()).await.unwrap();
            assert!(owner.lease.lock().unwrap().is_none());
            assert!(sessions.0.lock().unwrap().running.is_empty());
            let calls = script.calls.lock().unwrap();
            assert_eq!(
                calls
                    .iter()
                    .filter(|(command, _)| command == "lsp.destroyServer")
                    .count(),
                if reject_first { 2 } else { 1 }
            );
        }
    })
    .await
    .expect("bounded native disposal completion proof");
}

#[tokio::test]
async fn a_failed_first_write_still_has_a_registered_process_owner_to_destroy() {
    tokio::time::timeout(DEADLINE, async {
        let runtime = Arc::new(ScriptedRuntime::default());
        runtime.reject_start.store(true, Ordering::Release);
        let owner = owner(context(), runtime.clone());
        assert!(owner.start(|| Ok((json!({}), None))).await.is_err());
        assert_eq!(owner.session().as_deref(), Some("fixture-session"));
        assert!(owner.lease.lock().unwrap().is_some());
        owner.stop().await.unwrap();
        assert!(runtime
            .calls
            .lock()
            .unwrap()
            .iter()
            .any(|(command, _)| command == "lsp.destroyServer"));
    })
    .await
    .expect("bounded first-write cleanup");
}

#[test]
fn exact_roots_and_windows_are_independent_but_a_new_generation_cannot_overlap_an_old_owner() {
    let sessions = Sessions::default();
    sessions
        .insert(
            owner(context(), Arc::new(ScriptedRuntime::default())),
            || true,
        )
        .unwrap();
    let mut newer = context();
    newer.generation += 1;
    newer.scope.incarnation = "reopened".into();
    newer.scope.workspace_id = "reopened-workspace".into();
    newer.request_id = "next".into();
    assert_eq!(
        sessions
            .insert(owner(newer, Arc::new(ScriptedRuntime::default())), || true)
            .unwrap_err(),
        CLEANUP_FAILED
    );
    let mut other = context();
    other.root.id = "other".into();
    other.root.path.push_str("-other");
    other.request_id = "other".into();
    sessions
        .insert(owner(other, Arc::new(ScriptedRuntime::default())), || true)
        .unwrap();
    let mut window = context();
    window.host = "workspace-other-window".into();
    sessions
        .insert(owner(window, Arc::new(ScriptedRuntime::default())), || true)
        .unwrap();
    assert_eq!(
        sessions
            .matching(|context| context.host == "workspace-fixture")
            .len(),
        2
    );
    assert_eq!(
        sessions
            .matching(|context| context.host == "workspace-other-window")
            .len(),
        1
    );
}

#[test]
fn cancellation_before_preparation_finishes_prevents_late_publication() {
    let sessions = Sessions::default();
    let context = context();
    assert!(sessions
        .get(&context.host, &context.scope, &context.request_id)
        .unwrap()
        .is_none());
    assert_eq!(
        sessions
            .insert(owner(context, Arc::new(ScriptedRuntime::default())), || {
                true
            })
            .unwrap_err(),
        CANCELLED
    );
}

#[tokio::test]
async fn cancellation_after_tree_cleanup_still_rejects_a_late_projection() {
    tokio::time::timeout(DEADLINE, async {
        let context = context();
        let sessions = Sessions::default();
        let owner = owner(context.clone(), Arc::new(ScriptedRuntime::default()));
        sessions.insert(owner.clone(), || true).unwrap();
        sessions.cleanup(owner).await.unwrap();
        assert!(!sessions.cancelled(&context));
        assert!(sessions
            .get(&context.host, &context.scope, &context.request_id)
            .unwrap()
            .is_none());
        assert!(sessions.cancelled(&context));
    })
    .await
    .expect("bounded projection cancellation");
}

#[test]
fn product_pages_cannot_drain_write_or_destroy_a_private_native_vcs_session() {
    let sessions = Sessions::default();
    let owner = owner(context(), Arc::new(ScriptedRuntime::default()));
    owner.state.lock().unwrap().session = Some("fixture-session".into());
    sessions.insert(owner, || true).unwrap();
    for command in [
        "lsp.waitEvents",
        "lsp.pollEvents",
        "lsp.request",
        "lsp.stopServer",
        "lsp.destroyServer",
    ] {
        assert!(
            sessions.private_session(command, &json!({"sessionId":"fixture-session"})),
            "{command}"
        );
        assert!(
            !sessions.private_session(command, &json!({"sessionId":"editor-session"})),
            "{command}"
        );
    }
    assert!(sessions.private_session("lsp.vcsRequest", &json!({"sessionId":"unknown"})));
    assert!(sessions.private_session(
        "lsp.startServer",
        &json!({"providerId":"vcsProvider:fixture:svn:request"})
    ));
}

#[tokio::test]
async fn writes_use_typed_core_requests_real_decoder_and_never_redispatch_on_cleanup_retry() {
    tokio::time::timeout(DEADLINE, async {
        for (operation, reply) in [
            (super::super::actions::WriteOperation::Checkin { paths: vec!["after.txt".into(), "before.txt".into()], message: "Fix selected".into() }, json!({"revision":{"id":"r2"}})),
            (super::super::actions::WriteOperation::Rollback { paths: vec!["gone.txt".into()] }, json!({})),
            (super::super::actions::WriteOperation::Update, json!({"revision":null,"conflicts":["a.txt"]})),
            (super::super::actions::WriteOperation::Resolve { paths: vec!["conflict.txt".into()] }, json!({})),
            (super::super::actions::WriteOperation::Cleanup {}, json!({})),
            (super::super::actions::WriteOperation::Add { paths: vec!["new.txt".into()] }, json!({})),
            (super::super::actions::WriteOperation::Delete { paths: vec!["after.txt".into(), "before.txt".into()] }, json!({})),
        ] {
            let runtime = Arc::new(ScriptedRuntime::default());
            let mut negotiation = ready("svn");
            negotiation[0]["result"]["capabilities"]["update"] = json!(1);
            negotiation[0]["result"]["capabilities"]["conflicts"] = json!(1);
            negotiation[0]["result"]["capabilities"]["cleanup"] = json!(1);
            negotiation[0]["result"]["capabilities"]["fileOperations"] = json!(1);
            runtime.events.lock().unwrap().extend([negotiation, vec![json!({"type":"requestCompleted","sessionId":"fixture-session","operationId":"fixture-request","result":{"value":{"changes":[]}}})],
                vec![json!({"type":"requestCompleted","sessionId":"fixture-session","operationId":"fixture-request-write","result":{"value":reply}})]]);
            let owner = owner(context(), runtime.clone());
            owner.mark_mutation();
            owner.start(|| Ok((json!({}), None))).await.unwrap();
            owner.status(|| Ok(())).await.unwrap();
            let result = owner.write(&operation, || Ok(()), || Ok(())).await.unwrap();
            assert!(!owner.uncertain());
            if operation.name() == "update" { assert_eq!(result["conflicts"], json!(["a.txt"])); }
            // Exercise the public Core request boundary too; the controlled
            // transport has no real session, so Core must reject that identity.
            let request = runtime.calls.lock().unwrap().iter().rev().find(|(command, _)| command == "lsp.vcsRequest").unwrap().1.clone();
            assert_eq!(request["operation"], operation.request_name());
            assert_eq!(request["arguments"], operation.arguments());
            assert_eq!(request["operationId"], "fixture-request-write");
            let rejected = crate::plugin_host::scan::core_execute("lsp.vcsRequest", request);
            assert!(rejected.is_err());
            runtime.reject_disposal.store(true, Ordering::Release);
            assert!(!owner.dispose_once().await);
            assert!(owner.lease.lock().unwrap().is_some());
            runtime.reject_disposal.store(false, Ordering::Release);
            owner.stop().await.unwrap();
            assert!(owner.write(&operation, || Ok(()), || Ok(())).await.is_err());
            assert_eq!(runtime.calls.lock().unwrap().iter().filter(|(command, payload)| command == "lsp.vcsRequest" && payload["operation"] == operation.request_name()).count(), 1);
        }
    }).await.expect("bounded writes and cleanup");
}

#[tokio::test]
async fn optional_writes_never_dispatch_without_their_actual_negotiated_capability() {
    tokio::time::timeout(DEADLINE, async {
        for operation in [
            super::super::actions::WriteOperation::Resolve { paths: vec!["a.txt".into()] },
            super::super::actions::WriteOperation::Cleanup {},
            super::super::actions::WriteOperation::Add { paths: vec!["a.txt".into()] },
            super::super::actions::WriteOperation::Delete { paths: vec!["a.txt".into()] },
        ] {
            let runtime = Arc::new(ScriptedRuntime::default());
            let mut negotiation = ready("svn");
            // A capability named after the operation is not a conflicts negotiation.
            negotiation[0]["result"]["capabilities"]["resolve"] = json!(1);
            negotiation[0]["result"]["capabilities"]["fileOperation"] = json!(1);
            runtime.events.lock().unwrap().extend([negotiation,
                vec![json!({"type":"requestCompleted","sessionId":"fixture-session","operationId":"fixture-request","result":{"value":{"changes":[]}}})]]);
            let owner = owner(context(), runtime.clone());
            owner.start(|| Ok((json!({}), None))).await.unwrap();
            owner.status(|| Ok(())).await.unwrap();
            let result = owner.write(&operation, || Ok(()), || Ok(())).await;
            assert_eq!(result.unwrap_err(), "vcs.capability.unsupported");
            assert!(!owner.uncertain());
            assert!(!runtime.calls.lock().unwrap().iter().any(|(name, payload)| name == "lsp.vcsRequest" && payload["operation"] == operation.request_name()));
            owner.stop().await.unwrap();
        }
    }).await.expect("bounded negotiated resolve/cleanup");
}

#[tokio::test]
async fn optional_write_outcomes_and_failed_disposal_keep_the_original_owner_without_replay() {
    tokio::time::timeout(DEADLINE, async {
        for operation in [
            super::super::actions::WriteOperation::Resolve { paths: vec!["a.txt".into()] },
            super::super::actions::WriteOperation::Cleanup {},
            super::super::actions::WriteOperation::Add { paths: vec!["a.txt".into()] },
            super::super::actions::WriteOperation::Delete { paths: vec!["a.txt".into()] },
        ] {
            for outcome in ["preflight", "provider", "providerGeneric", "success", "successNull", "lost", "cancelled", "timeout", "invalidReply"] {
                let runtime = Arc::new(ScriptedRuntime::default());
                let mut negotiation = ready("svn");
                negotiation[0]["result"]["capabilities"][operation.capability()] = json!(1);
                runtime.events.lock().unwrap().extend([negotiation,
                    vec![json!({"type":"requestCompleted","sessionId":"fixture-session","operationId":"fixture-request","result":{"value":{"changes":[]}}})]]);
                let completion = match outcome {
                    "provider" => Some(json!({"error":{"code":"vcs.workingCopy.locked"}})),
                    "providerGeneric" => Some(json!({"error":{"code":"vcs.provider.failed"}})),
                    "success" => Some(json!({"result":{"value":{}}})),
                    // Core's empty-reply decoder accepts null as success; an
                    // array is malformed and must leave the write uncertain.
                    "successNull" => Some(json!({"result":{"value":null}})),
                    "cancelled" => Some(json!({"error":{"code":"requestCancelled"}})),
                    "timeout" => Some(json!({"error":{"code":"requestTimeout"}})),
                    "invalidReply" => Some(json!({"result":{"value":[]}})),
                    _ => None,
                };
                if let Some(mut event) = completion {
                    event["type"] = json!("requestCompleted");
                    event["sessionId"] = json!("fixture-session");
                    event["operationId"] = json!("fixture-request-write");
                    runtime.events.lock().unwrap().push_back(vec![event]);
                }
                let owner = owner(context(), runtime.clone());
                owner.mark_mutation();
                let sessions = Sessions::default();
                sessions.insert(owner.clone(), || true).unwrap();
                owner.start(|| Ok((json!({}), None))).await.unwrap();
                owner.status(|| Ok(())).await.unwrap();
                let result = owner.write(&operation, move || {
                    if outcome == "preflight" { Err(super::super::registry::STALE.into()) } else { Ok(()) }
                }, || Ok(())).await;
                assert_eq!(result.is_ok(), matches!(outcome, "success" | "successNull"), "{} {outcome}", operation.name());
                assert_eq!(owner.uncertain(), matches!(outcome, "lost" | "cancelled" | "timeout" | "invalidReply"), "{} {outcome}", operation.name());
                runtime.reject_disposal.store(true, Ordering::Release);
                owner.revoke();
                assert!(!owner.dispose_once().await);
                let error = super::super::status::complete_request(result.clone(), Err(CLEANUP_FAILED.into()), true, owner.uncertain()).unwrap_err();
                assert_eq!(error.starts_with("vcs.provider.outcomeUnknown:"), matches!(outcome, "success" | "successNull" | "lost" | "cancelled" | "timeout" | "invalidReply"), "{} {outcome}", operation.name());
                assert!(owner.lease.lock().unwrap().is_some());
                // Another window cannot mutate the same root until disposal is proved.
                let mut other_context = context();
                other_context.host = "another-window".into();
                let other = self::owner(other_context, Arc::new(ScriptedRuntime::default()));
                other.mark_mutation();
                assert_eq!(sessions.insert(other.clone(), || true).unwrap_err(), CLEANUP_FAILED);
                runtime.reject_disposal.store(false, Ordering::Release);
                sessions.cleanup(owner.clone()).await.unwrap();
                assert!(owner.lease.lock().unwrap().is_none());
                sessions.insert(other.clone(), || true).unwrap();
                // A late old cleanup must neither remove nor stop the replacement owner.
                sessions.cleanup(owner.clone()).await.unwrap();
                assert!(other.current().is_ok());
                assert!(other.lease.lock().unwrap().is_some());
                sessions.cleanup(other).await.unwrap();
                assert_eq!(runtime.calls.lock().unwrap().iter().filter(|(name, payload)|
                    name == "lsp.vcsRequest" && payload["operation"] == operation.request_name()).count(), usize::from(outcome != "preflight"));
            }
        }
    }).await.expect("bounded resolve/cleanup outcomes and original owner");
}

#[tokio::test]
async fn replacement_preflight_cancellation_and_lost_write_reply_never_replay_side_effects() {
    tokio::time::timeout(DEADLINE, async {
        for preflight_rejected in [true, false] {
            let runtime = Arc::new(ScriptedRuntime::default());
            runtime.events.lock().unwrap().extend([ready("svn"), vec![json!({"type":"requestCompleted","sessionId":"fixture-session","operationId":"fixture-request","result":{"value":{"changes":[]}}})]]);
            let owner = owner(context(), runtime.clone());
            owner.start(|| Ok((json!({}), None))).await.unwrap();
            owner.status(|| Ok(())).await.unwrap();
            let operation = super::super::actions::WriteOperation::Rollback { paths: vec!["a.txt".into()] };
            assert!(owner.write(&operation, move || if preflight_rejected { Err("requestCancelled".into()) } else { Ok(()) }, || Ok(())).await.is_err());
            assert_eq!(owner.uncertain(), !preflight_rejected);
            assert_eq!(runtime.calls.lock().unwrap().iter().filter(|(command, payload)| command == "lsp.vcsRequest" && payload["operation"] == "rollback").count(), usize::from(!preflight_rejected));
            owner.stop().await.unwrap();
        }
    }).await.expect("bounded uncertain write");
}

#[tokio::test]
async fn definitive_write_rejections_survive_failed_destroy_and_same_owner_cleanup_retry() {
    tokio::time::timeout(DEADLINE, async {
        for code in ["requestCancelled", "vcs.authentication.failed", "vcs.outOfDate"] {
            let runtime = Arc::new(ScriptedRuntime::default());
            runtime.events.lock().unwrap().extend([
                ready("svn"),
                vec![json!({"type":"requestCompleted","sessionId":"fixture-session","operationId":"fixture-request","result":{"value":{"changes":[]}}})],
                vec![json!({"type":"requestCompleted","sessionId":"fixture-session","operationId":"fixture-request-write","error":{"code":code}})],
            ]);
            let owner = owner(context(), runtime.clone());
            owner.mark_mutation();
            let sessions = Sessions::default();
            sessions.insert(owner.clone(), || true).unwrap();
            owner.start(|| Ok((json!({}), None))).await.unwrap();
            owner.status(|| Ok(())).await.unwrap();
            let operation = super::super::actions::WriteOperation::Checkin {
                paths: vec!["a.txt".into()], message: "Selected only".into(),
            };
            let result = owner.write(&operation, move || {
                if code == "requestCancelled" { Err(code.into()) } else { Ok(()) }
            }, || Ok(())).await;
            assert_eq!(result.as_ref().unwrap_err(), code);
            assert!(!owner.uncertain());
            runtime.reject_disposal.store(true, Ordering::Release);
            owner.revoke();
            // Drive one controlled destroy attempt instead of waiting through
            // the production cleanup retry deadline in this regression.
            assert!(!owner.dispose_once().await);
            let error = super::super::status::complete_request(
                result.clone(), Err(CLEANUP_FAILED.into()), true, owner.uncertain(),
            ).unwrap_err();
            assert_eq!(error, format!("{code};{CLEANUP_FAILED}"));
            assert!(owner.lease.lock().unwrap().is_some());
            assert!(sessions.0.lock().unwrap().running.values().any(|entry| Arc::ptr_eq(entry, &owner)));
            runtime.reject_disposal.store(false, Ordering::Release);
            let cleaned = sessions.cleanup(owner.clone()).await;
            assert_eq!(super::super::status::complete_request(result, cleaned, true, owner.uncertain()).unwrap_err(), code);
            assert!(owner.lease.lock().unwrap().is_none());
            assert!(sessions.0.lock().unwrap().running.is_empty());
            let writes = runtime.calls.lock().unwrap().iter().filter(|(command, payload)| command == "lsp.vcsRequest" && payload["operation"] == "checkin").count();
            assert_eq!(writes, usize::from(code != "requestCancelled"));
        }
    }).await.expect("bounded definitive write cleanup retry");
}

#[tokio::test]
async fn successful_or_unanswered_writes_require_cleanup_proof_before_publication() {
    tokio::time::timeout(DEADLINE, async {
        for answered in [false, true] {
            let runtime = Arc::new(ScriptedRuntime::default());
            runtime.events.lock().unwrap().extend([
                ready("svn"),
                vec![json!({"type":"requestCompleted","sessionId":"fixture-session","operationId":"fixture-request","result":{"value":{"changes":[]}}})],
            ]);
            if answered {
                runtime.events.lock().unwrap().push_back(vec![json!({"type":"requestCompleted","sessionId":"fixture-session","operationId":"fixture-request-write","result":{"value":{"revision":{"id":"r2"}}}})]);
            }
            let owner = owner(context(), runtime.clone());
            let sessions = Sessions::default();
            sessions.insert(owner.clone(), || true).unwrap();
            owner.start(|| Ok((json!({}), None))).await.unwrap();
            owner.status(|| Ok(())).await.unwrap();
            let operation = super::super::actions::WriteOperation::Checkin {
                paths: vec!["a.txt".into()], message: "Selected only".into(),
            };
            let result = owner.write(&operation, || Ok(()), || Ok(())).await;
            assert_eq!(result.is_ok(), answered);
            assert_eq!(owner.uncertain(), !answered);
            runtime.reject_disposal.store(true, Ordering::Release);
            owner.revoke();
            assert!(!owner.dispose_once().await);
            let error = super::super::status::complete_request(result, Err(CLEANUP_FAILED.into()), true, owner.uncertain()).unwrap_err();
            assert!(error.starts_with("vcs.provider.outcomeUnknown:"));
            assert!(error.contains(CLEANUP_FAILED));
            assert!(owner.lease.lock().unwrap().is_some());
            runtime.reject_disposal.store(false, Ordering::Release);
            sessions.cleanup(owner.clone()).await.unwrap();
            assert!(owner.lease.lock().unwrap().is_none());
            assert!(sessions.0.lock().unwrap().running.is_empty());
            assert_eq!(runtime.calls.lock().unwrap().iter().filter(|(command, payload)| command == "lsp.vcsRequest" && payload["operation"] == "checkin").count(), 1);
        }
    }).await.expect("bounded write publication cleanup proof");
}

#[tokio::test]
async fn delayed_mutation_watch_callback_after_cleanup_waits_for_the_next_explicit_scan() {
    tokio::time::timeout(DEADLINE, async {
        let runtime = Arc::new(ScriptedRuntime::default());
        let mut negotiation = ready("svn");
        negotiation[0]["result"]["capabilities"]["update"] = json!(1);
        runtime.events.lock().unwrap().extend([
            negotiation,
            vec![json!({"type":"requestCompleted","sessionId":"fixture-session","operationId":"fixture-request","result":{"value":{"changes":[]}}})],
            vec![json!({"type":"requestCompleted","sessionId":"fixture-session","operationId":"fixture-request-write","result":{"value":{}}})],
        ]);
        let mut registry = super::super::registry::Registry::default();
        let mut context = context();
        let now = std::time::Instant::now();
        let first = registry.begin(&context.host, context.scope.clone(), context.registration, now).unwrap();
        let detection: super::super::registry::Detection = serde_json::from_value(json!({
            "providers":[], "roots":[], "ambiguous":[], "unusedMappings":[],
            "truncated":false, "rejected":[], "conflicts":[],
        })).unwrap();
        registry.publish(&first, detection.clone(), vec![], now).unwrap();
        context.generation = first.generation;
        let other = registry.begin("other-window", context.scope.clone(), context.registration, now).unwrap();
        registry.publish(&other, detection.clone(), vec![], now).unwrap();
        let sessions = Sessions::default();
        let owner = owner(context.clone(), runtime);
        owner.mark_mutation();
        sessions.insert(owner.clone(), || true).unwrap();
        owner.start(|| Ok((json!({}), None))).await.unwrap();
        owner.status(|| Ok(())).await.unwrap();
        registry.begin_write(&context.host, &context.scope, context.generation).unwrap();
        owner.write(&super::super::actions::WriteOperation::Update, || Ok(()), || Ok(())).await.unwrap();
        sessions.cleanup(owner).await.unwrap();
        assert!(sessions.0.lock().unwrap().running.is_empty());

        // Deliver the queued metadata event only after the process owner has
        // gone. The original reply stays publishable; another window does not.
        assert!(!registry.invalidate_generation(&context.host, &context.scope, context.generation));
        assert!(registry.capture(&context.host, &context.scope, context.generation).is_ok());
        assert!(registry.invalidate_generation("other-window", &context.scope, other.generation));
        let next = registry.begin(&context.host, context.scope.clone(), context.registration, now).unwrap();
        registry.publish(&next, detection, vec![], now).unwrap();
        assert!(!registry.invalidate_generation(&context.host, &context.scope, context.generation));
        assert!(registry.invalidate_generation(&context.host, &context.scope, next.generation));
    }).await.expect("bounded mutation refresh fence");
}

#[tokio::test]
async fn invalidation_after_a_valid_write_reply_still_requires_unknown_outcome_handling() {
    tokio::time::timeout(DEADLINE, async {
        let runtime = Arc::new(ScriptedRuntime::default());
        let mut negotiation = ready("svn");
        negotiation[0]["result"]["capabilities"]["update"] = json!(1);
        runtime.events.lock().unwrap().extend([
            negotiation,
            vec![json!({"type":"requestCompleted","sessionId":"fixture-session","operationId":"fixture-request","result":{"value":{"changes":[]}}})],
            vec![json!({"type":"requestCompleted","sessionId":"fixture-session","operationId":"fixture-request-write","result":{"value":{"revision":{"id":"r2"}}}})],
        ]);
        let owner = owner(context(), runtime.clone());
        owner.start(|| Ok((json!({}), None))).await.unwrap();
        owner.status(|| Ok(())).await.unwrap();
        // Invalidate at the public decoder completion boundary, after the
        // provider has acknowledged success but before final publication.
        let result = owner.write(&super::super::actions::WriteOperation::Update, || Ok(()), || {
            if runtime.calls.lock().unwrap().iter().any(|(command, payload)| {
                command == "vcs.decodeReply" && payload["operation"] == "update"
            }) { Err(CANCELLED.into()) } else { Ok(()) }
        }).await;
        assert_eq!(result.unwrap_err(), CANCELLED);
        assert!(owner.uncertain());
        owner.stop().await.unwrap();
        assert_eq!(runtime.calls.lock().unwrap().iter().filter(|(command, payload)| {
            command == "lsp.vcsRequest" && payload["operation"] == "update"
        }).count(), 1);
    }).await.expect("bounded reply invalidation");
}
