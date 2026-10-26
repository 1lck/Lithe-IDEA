//! Publication and mutation ordering without app windows or real processes.

use super::*;
use crate::plugin_host::{lifecycle::LifecycleState, CatalogEntry};
use std::sync::atomic::AtomicBool;
use std::time::Duration;
use tokio::sync::oneshot;

const DEADLINE: Duration = Duration::from_secs(2);
const PLUGIN: &str = "fixture.provider";

#[derive(Default)]
struct CleanupCore(Mutex<Vec<String>>);

impl super::super::session::Core for CleanupCore {
    fn execute(&self, command: &str, _payload: Value) -> Reply {
        self.0.lock().unwrap().push(command.into());
        Ok(json!({}))
    }

    fn start(&self, _payload: Value, _registered: &dyn Fn(&str)) -> Reply {
        panic!("a rejected owner must never launch a process")
    }
}

fn context() -> ProviderContext {
    ProviderContext {
        window: "workspace-fixture".into(),
        workspace_root: "/fixture/workspace".into(),
        generation: 1,
        plugin_id: PLUGIN.into(),
        package_identity: "fixture:package-digest".into(),
        build_system: "fixture-build".into(),
        instance_root: ".".into(),
        instance_directory: "/fixture/workspace".into(),
    }
}

fn prepared(lease: NativeLease) -> Prepared {
    Prepared {
        context: context(),
        package: ScannedPackage {
            entry: CatalogEntry {
                plugin_id: PLUGIN.into(),
                display_name: "Fixture".into(),
                version: "1.0.0".into(),
                api_version: 3,
                source: "installed",
                enabled: true,
                status: "accepted",
                languages: Vec::new(),
                declared_settings: Vec::new(),
                declares_tests: false,
                primary_language_id: None,
                rejection: None,
            },
            root: PathBuf::from("/fixture/plugin"),
            manifest: json!({}),
            trust: None,
        },
        plan: json!({}),
        state_directory: PathBuf::from("/fixture/state"),
        lease,
    }
}

fn native_transport(lease: NativeLease, shared: bool, core: Arc<CleanupCore>) -> Arc<Transport> {
    let mut entry = transport(
        1,
        context(),
        shared.then(|| "fixture-language".into()),
        None,
        lease,
    );
    Arc::get_mut(&mut entry).unwrap().core = core;
    *entry.status.lock().unwrap() = Status {
        session_id: Some("fixture-session".into()),
        launch_finished: true,
        ..Default::default()
    };
    entry
}

enum PendingOwner {
    Review(Prepared),
    Transport(Arc<Transport>),
}

impl PendingOwner {
    fn publish(self, registry: &mut Registry) -> Result<(), ProviderError> {
        match self {
            Self::Review(review) => {
                registry.prepared.insert(1, review);
            }
            Self::Transport(transport) => {
                registry.transports.insert(transport.id, transport);
            }
        }
        Ok(())
    }
}

async fn rejects_publication_after_mutation_snapshot(owner: PendingOwner) {
    let state = Arc::new(Inner::default());
    let active = AtomicBool::new(true);
    let (reached, reached_result) = oneshot::channel();
    let (resume, resumed) = oneshot::channel();
    let pending = async {
        // The owner already holds its package lease and verified inputs, but
        // has not published the persistent review/session to the close registry.
        let owner = owner;
        reached.send(()).unwrap();
        resumed
            .await
            .map_err(|_| error("Test publication was cancelled"))?;
        state.publish(
            || active.load(Ordering::Acquire),
            |registry| owner.publish(registry),
        )
    };
    tokio::pin!(pending);
    tokio::time::timeout(DEADLINE, async {
        tokio::select! { biased;
            result = &mut pending => panic!("publication passed its closed gate: {result:?}"),
            result = reached_result => result.expect("publication reached its gate"),
        }
    })
    .await
    .expect("publication reached its gate within the test deadline");

    // Match lifecycle.begin's order: revoke new owners, then take the close
    // snapshot while this in-flight preparation is still absent from it.
    active.store(false, Ordering::Release);
    tokio::time::timeout(
        DEADLINE,
        close_matching(state.clone(), |context| context.plugin_id == PLUGIN),
    )
    .await
    .expect("empty close snapshot completed")
    .unwrap();
    resume.send(()).unwrap();
    let result = tokio::time::timeout(DEADLINE, &mut pending)
        .await
        .expect("revoked publication completed");
    assert_eq!(result.unwrap_err().code, "provider.cancelled");
    let registry = state.registry.lock().unwrap();
    assert!(registry.prepared.is_empty());
    assert!(registry.transports.is_empty());
}

#[tokio::test]
async fn pending_review_cannot_publish_after_mutation_close_snapshot() {
    let lifecycle = LifecycleState::default();
    let review = prepared(lifecycle.acquire(PLUGIN).unwrap());
    rejects_publication_after_mutation_snapshot(PendingOwner::Review(review)).await;
}

#[tokio::test]
async fn shared_language_owner_cannot_publish_after_mutation_close_snapshot() {
    let lifecycle = LifecycleState::default();
    let core = Arc::new(CleanupCore::default());
    let entry = native_transport(lifecycle.acquire(PLUGIN).unwrap(), true, core.clone());
    let weak = Arc::downgrade(&entry);
    rejects_publication_after_mutation_snapshot(PendingOwner::Transport(entry)).await;
    assert!(
        weak.upgrade().is_none(),
        "rejection released its native owner and lease"
    );
    assert!(core.0.lock().unwrap().is_empty());
}

#[tokio::test]
async fn dedicated_owner_cannot_publish_after_mutation_close_snapshot() {
    let lifecycle = LifecycleState::default();
    let entry = native_transport(lifecycle.acquire(PLUGIN).unwrap(), false, Arc::default());
    let weak = Arc::downgrade(&entry);
    rejects_publication_after_mutation_snapshot(PendingOwner::Transport(entry)).await;
    assert!(weak.upgrade().is_none());
}

#[tokio::test]
async fn owner_published_before_revocation_is_drained_by_mutation_snapshot() {
    let lifecycle = LifecycleState::default();
    let state = Arc::new(Inner::default());
    let active = AtomicBool::new(true);
    let core = Arc::new(CleanupCore::default());
    let entry = native_transport(lifecycle.acquire(PLUGIN).unwrap(), true, core.clone());
    state
        .publish(
            || active.load(Ordering::Acquire),
            |registry| PendingOwner::Transport(entry.clone()).publish(registry),
        )
        .unwrap();

    active.store(false, Ordering::Release);
    tokio::time::timeout(
        DEADLINE,
        close_matching(state.clone(), |context| context.plugin_id == PLUGIN),
    )
    .await
    .expect("published owner completed bounded cleanup")
    .unwrap();
    assert!(entry.status.lock().unwrap().revoked);
    assert!(entry.lease.lock().unwrap().is_none());
    assert!(!state.contains_for_test(entry.id));
    assert_eq!(
        *core.0.lock().unwrap(),
        vec!["lsp.stopServer", "lsp.destroyServer"]
    );
}
