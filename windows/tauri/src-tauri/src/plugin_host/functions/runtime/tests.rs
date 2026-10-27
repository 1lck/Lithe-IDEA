use super::*;
use std::sync::atomic::AtomicUsize;
use tokio::sync::oneshot;

#[derive(Default)]
struct ScriptedCore {
    calls: Mutex<Vec<(String, Value)>>,
    fail_destroy: AtomicBool,
    panic_destroy: AtomicBool,
    destroy_calls: AtomicUsize,
    entered: Mutex<Option<oneshot::Sender<()>>>,
    release: Mutex<Option<std::sync::mpsc::Receiver<()>>>,
    start_entered: Mutex<Option<oneshot::Sender<()>>>,
    start_release: Mutex<Option<std::sync::mpsc::Receiver<()>>>,
}
impl Core for ScriptedCore {
    fn execute(&self, command: &str, payload: Value) -> Reply<Value> {
        self.calls.lock().unwrap().push((command.into(), payload));
        if command == "lsp.destroyServer" {
            self.destroy_calls.fetch_add(1, Ordering::SeqCst);
            if self.panic_destroy.load(Ordering::SeqCst) {
                panic!("fixture destroy outcome unknown");
            }
            if let Some(entered) = self.entered.lock().unwrap().take() {
                let _ = entered.send(());
            }
            if let Some(release) = self.release.lock().unwrap().take() {
                release
                    .recv_timeout(Duration::from_secs(2))
                    .expect("test releases its bounded destroy gate");
            }
            if self.fail_destroy.load(Ordering::SeqCst) {
                return Err(Error::new("fixture.cleanupFailed"));
            }
        }
        Ok(json!({}))
    }
    fn start(&self, _payload: Value, registered: &dyn Fn(&str)) -> Reply<Value> {
        if let Some(entered) = self.start_entered.lock().unwrap().take() {
            let _ = entered.send(());
        }
        if let Some(release) = self.start_release.lock().unwrap().take() {
            release
                .recv_timeout(Duration::from_secs(2))
                .expect("test releases its bounded start gate");
        }
        registered("owned-session");
        Ok(json!({"sessionId":"owned-session"}))
    }
}
fn fixture(core: Arc<ScriptedCore>) -> Arc<Operation> {
    let review = Review {
        context: super::super::Context {
            window: "workspace-one".into(),
            window_incarnation: 7,
            workspace_path: if cfg!(windows) {
                "C:/fixture/project"
            } else {
                "/fixture/project"
            }
            .into(),
            generation: 3,
            plugin_id: "example.plugin".into(),
            package_identity: "all-package-bytes".into(),
            setting_identity: "global-project-bytes".into(),
            action_id: "refresh".into(),
            function_id: "snapshot.refresh".into(),
            operation_id: "operation-one".into(),
        },
        title: "Refresh".into(),
        confirm: true,
        executes_project_code: true,
        may_use_network: false,
        launch_plan: json!({}),
        program: super::super::super::launch::ResolvedLaunch {
            plugin_id: "example.plugin".into(),
            language_id: "fixture".into(),
            server_path: "/fixture/backend".into(),
            server_args: vec![],
            initialization_options: None,
            workspace_configuration: None,
            environment: Default::default(),
        },
    };
    let lease = super::super::super::lifecycle::LifecycleState::default()
        .acquire("example.plugin")
        .unwrap();
    let owner = Arc::new(WindowOwner {
        id: 7,
        alive: AtomicBool::new(true),
    });
    let mut entry = Operation::new(review, PathBuf::from("/fixture/state"), lease, owner);
    entry.core = core;
    Arc::new(entry)
}
struct ReleaseOnDrop(Option<std::sync::mpsc::Sender<()>>);
impl Drop for ReleaseOnDrop {
    fn drop(&mut self) {
        if let Some(sender) = self.0.take() {
            let _ = sender.send(());
        }
    }
}

fn publish(entry: &Arc<Operation>) -> super::super::FunctionsState {
    let registry = super::super::FunctionsState::default();
    entry.bind_registry(&registry.operations, &registry.retired);
    registry
        .operations
        .lock()
        .unwrap()
        .insert(entry.review.context.operation_id.clone(), entry.clone());
    registry
}

async fn await_retired(entry: &Arc<Operation>, registry: &super::super::FunctionsState) {
    tokio::time::timeout(Duration::from_secs(2), async {
        loop {
            let changed = entry.changed.notified();
            tokio::pin!(changed);
            changed.as_mut().enable();
            let no_lease = entry.lease.lock().unwrap().is_none();
            let no_owner = !registry
                .operations
                .lock()
                .unwrap()
                .contains_key(&entry.review.context.operation_id);
            if no_lease && no_owner {
                break;
            }
            changed.await;
        }
    })
    .await
    .expect("the completed original owner retires without a UI retry");
}

#[tokio::test]
async fn a_start_finishing_after_the_last_window_cleanup_is_reaped_automatically() {
    let core = Arc::new(ScriptedCore::default());
    let (entered_tx, entered_rx) = oneshot::channel();
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    *core.start_entered.lock().unwrap() = Some(entered_tx);
    *core.start_release.lock().unwrap() = Some(release_rx);
    let mut release = ReleaseOnDrop(Some(release_tx));
    let entry = fixture(core.clone());
    let registry = publish(&entry);
    entry.begin().unwrap();
    let worker = entry.clone();
    let (done_tx, done_rx) = oneshot::channel();
    tauri::async_runtime::spawn_blocking(move || {
        let outcome = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
            worker.core.start(json!({}), &|id| {
                worker.status.lock().unwrap().session = Some(id.into());
            })
        }));
        worker.complete_launch(outcome);
        let _ = done_tx.send(());
    });
    tokio::time::timeout(Duration::from_secs(1), entered_rx)
        .await
        .unwrap()
        .unwrap();
    // The final window cleanup is already gone before native registration.
    entry.retire_requested.store(true, Ordering::Release);
    assert!(cleanup_with_budget(&entry, Duration::ZERO).await.is_err());
    assert!(entry.lease.lock().unwrap().is_some());
    release.0.take().unwrap().send(()).unwrap();
    tokio::time::timeout(Duration::from_secs(1), done_rx)
        .await
        .unwrap()
        .unwrap();
    await_retired(&entry, &registry).await;
    assert_eq!(core.destroy_calls.load(Ordering::SeqCst), 1);
    assert_eq!(
        registry
            .retired
            .lock()
            .unwrap()
            .get("operation-one")
            .map(|owner| owner.window.as_str()),
        Some("workspace-one")
    );
}

#[tokio::test]
async fn a_destroy_finishing_after_the_last_window_cleanup_keeps_its_success_proof() {
    let core = Arc::new(ScriptedCore::default());
    let (entered_tx, entered_rx) = oneshot::channel();
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    *core.entered.lock().unwrap() = Some(entered_tx);
    *core.release.lock().unwrap() = Some(release_rx);
    let mut release = ReleaseOnDrop(Some(release_tx));
    let entry = fixture(core.clone());
    let registry = publish(&entry);
    entry.status.lock().unwrap().session = Some("owned-session".into());
    entry.retire_requested.store(true, Ordering::Release);
    assert!(cleanup_with_budget(&entry, Duration::ZERO).await.is_err());
    tokio::time::timeout(Duration::from_secs(1), entered_rx)
        .await
        .unwrap()
        .unwrap();
    assert!(entry.lease.lock().unwrap().is_some());
    release.0.take().unwrap().send(()).unwrap();
    await_retired(&entry, &registry).await;
    assert_eq!(core.destroy_calls.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn web_destroy_completion_retires_the_original_owner_without_a_tombstone() {
    let core = Arc::new(ScriptedCore::default());
    let (entered_tx, entered_rx) = oneshot::channel();
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    *core.entered.lock().unwrap() = Some(entered_tx);
    *core.release.lock().unwrap() = Some(release_rx);
    let mut release = ReleaseOnDrop(Some(release_tx));
    let mut entry = fixture(core.clone());
    Arc::get_mut(&mut entry).unwrap().review.context.action_id =
        "__web__:fixture:snapshot.refresh".into();
    let registry = publish(&entry);
    entry.status.lock().unwrap().session = Some("owned-session".into());
    entry.retire_requested.store(true, Ordering::Release);
    assert!(cleanup_with_budget(&entry, Duration::ZERO).await.is_err());
    tokio::time::timeout(Duration::from_secs(1), entered_rx)
        .await
        .unwrap()
        .unwrap();
    release.0.take().unwrap().send(()).unwrap();
    await_retired(&entry, &registry).await;
    assert!(registry.retired.lock().unwrap().is_empty());
    assert_eq!(core.destroy_calls.load(Ordering::SeqCst), 1);
}

#[test]
fn late_old_window_cleanup_cannot_remove_or_cancel_a_new_owner_receipt() {
    let old = fixture(Arc::new(ScriptedCore::default()));
    let registry = publish(&old);
    registry.retire_window(&old.owner);
    let mut new = fixture(Arc::new(ScriptedCore::default()));
    let new_mut = Arc::get_mut(&mut new).unwrap();
    new_mut.owner = Arc::new(WindowOwner {
        id: 8,
        alive: AtomicBool::new(true),
    });
    new_mut.review.context.window_incarnation = 8;
    new.bind_registry(&registry.operations, &registry.retired);
    registry
        .operations
        .lock()
        .unwrap()
        .insert("operation-one".into(), new.clone());
    assert!(!super::super::owns_operation(&old.owner, &new));
    assert!(super::super::owns_operation(&new.owner, &new));
    old.retire_requested.store(true, Ordering::Release);
    old.retire_clean();
    assert!(Arc::ptr_eq(
        &registry.operations.lock().unwrap()["operation-one"],
        &new
    ));
    assert!(!new.cancelled());
    assert!(registry.retired.lock().unwrap().is_empty());
}

#[tokio::test]
async fn completed_result_receipts_stay_readable_until_the_product_consumes_them() {
    let core = Arc::new(ScriptedCore::default());
    let entry = fixture(core.clone());
    let registry = publish(&entry);
    entry.status.lock().unwrap().session = Some("owned-session".into());
    cleanup_with_budget(&entry, Duration::from_secs(1))
        .await
        .unwrap();
    assert!(entry.lease.lock().unwrap().is_none());
    assert!(registry
        .operations
        .lock()
        .unwrap()
        .contains_key("operation-one"));
    assert!(registry.retired.lock().unwrap().is_empty());
    assert_eq!(core.destroy_calls.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn unknown_destroy_outcome_is_joined_and_never_dispatched_twice() {
    let core = Arc::new(ScriptedCore::default());
    let (entered_tx, entered_rx) = oneshot::channel();
    let (release_tx, release_rx) = std::sync::mpsc::channel();
    *core.entered.lock().unwrap() = Some(entered_tx);
    *core.release.lock().unwrap() = Some(release_rx);
    let mut release = ReleaseOnDrop(Some(release_tx));
    let entry = fixture(core.clone());
    entry.status.lock().unwrap().session = Some("owned-session".into());
    assert!(cleanup_with_budget(&entry, Duration::ZERO).await.is_err());
    tokio::time::timeout(Duration::from_secs(1), entered_rx)
        .await
        .unwrap()
        .unwrap();
    assert!(entry.lease.lock().unwrap().is_some());
    release.0.take().unwrap().send(()).unwrap();
    cleanup_with_budget(&entry, Duration::from_secs(1))
        .await
        .unwrap();
    assert_eq!(core.destroy_calls.load(Ordering::SeqCst), 1);
    assert!(entry.lease.lock().unwrap().is_none());
}

#[tokio::test]
async fn panicked_destroy_keeps_its_unknown_owner_without_replaying_destroy() {
    let core = Arc::new(ScriptedCore::default());
    core.panic_destroy.store(true, Ordering::SeqCst);
    let entry = fixture(core.clone());
    entry.status.lock().unwrap().session = Some("owned-session".into());
    assert!(cleanup(&entry).await.is_err());
    assert!(cleanup(&entry).await.is_err());
    assert_eq!(core.destroy_calls.load(Ordering::SeqCst), 1);
    assert!(!entry.clean());
    assert!(entry.lease.lock().unwrap().is_some());
}

#[tokio::test]
async fn panicked_start_without_a_registered_session_does_not_claim_cleanup() {
    let entry = fixture(Arc::new(ScriptedCore::default()));
    entry.begin().unwrap();
    entry.complete_launch(Err(Box::new("fixture start outcome unknown")));
    assert!(cleanup(&entry).await.is_err());
    assert!(!entry.clean());
    assert!(entry.lease.lock().unwrap().is_some());
}

#[tokio::test]
async fn late_start_completion_retains_package_lease_after_successful_destroy() {
    let core = Arc::new(ScriptedCore::default());
    let entry = fixture(core.clone());
    {
        let mut state = entry.status.lock().unwrap();
        state.session = Some("owned-session".into());
        state.launch_finished = false;
    }
    let cleaning = cleanup(&entry);
    tokio::pin!(cleaning);
    let destroyed = async {
        loop {
            let changed = entry.changed.notified();
            tokio::pin!(changed);
            changed.as_mut().enable();
            if entry.status.lock().unwrap().destroyed {
                break;
            }
            changed.await;
        }
    };
    tokio::select! { biased;
        result = &mut cleaning => panic!("lease released before the start worker exited: {}", result.is_ok()),
        result = tokio::time::timeout(Duration::from_secs(2), destroyed) => result.unwrap(),
    }
    assert!(entry.status.lock().unwrap().destroyed);
    assert!(entry.lease.lock().unwrap().is_some());
    entry.status.lock().unwrap().launch_finished = true;
    entry.changed.notify_waiters();
    cleaning.await.unwrap();
    assert_eq!(core.destroy_calls.load(Ordering::SeqCst), 1);
}

#[tokio::test]
async fn known_cleanup_failure_remains_owned_and_is_retryable() {
    let core = Arc::new(ScriptedCore::default());
    core.fail_destroy.store(true, Ordering::SeqCst);
    let entry = fixture(core.clone());
    entry.status.lock().unwrap().session = Some("owned-session".into());
    assert!(cleanup(&entry).await.is_err());
    assert!(matches!(entry.phase(), Phase::CleanupFailed));
    assert!(!entry.clean());
    assert!(entry.lease.lock().unwrap().is_some());
    core.fail_destroy.store(false, Ordering::SeqCst);
    cleanup(&entry).await.unwrap();
    assert!(entry.clean());
    assert_eq!(core.destroy_calls.load(Ordering::SeqCst), 2);
    for (_, payload) in core.calls.lock().unwrap().iter() {
        assert_eq!(payload["sessionId"], "owned-session");
    }
}

#[test]
fn isolated_launch_offers_no_host_services_and_keeps_its_plugin_identity() {
    let entry = fixture(Arc::new(ScriptedCore::default()));
    let payload = launch_payload(&entry).unwrap();
    assert_eq!(payload["pluginId"], "example.plugin");
    assert_eq!(payload["hostServices"], json!([]));
    assert_eq!(
        payload["providerId"],
        "settingsAction:example.plugin:operation-one"
    );
    assert_eq!(
        payload["workingDirectory"],
        entry.review.context.workspace_path
    );
}
