use super::super::{registry::*, Core};
use super::*;
use serde_json::Value;
use std::sync::atomic::AtomicU64;
static NEXT: AtomicU64 = AtomicU64::new(1);
struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "lithe-vcs-watch-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        for marker in [
            ".svn",
            "project/nested/.git",
            "project/mixed/.git",
            "project/mixed/.svn",
        ] {
            std::fs::create_dir_all(path.join(marker)).unwrap();
        }
        std::fs::write(path.join(".svn/wc.db"), b"opaque fixture, never parsed").unwrap();
        Self(path)
    }
    fn scope(&self, incarnation: &str) -> Scope {
        Scope {
            workspace_id: "fixture".into(),
            workspace_root: self.0.join("project").to_string_lossy().into_owned(),
            incarnation: incarnation.into(),
        }
    }
    fn detection(&self) -> Detection {
        let manifest: Value = serde_json::from_str(include_str!(
            "../../../../../shared/contracts/plugins/v1/fixtures/vcs-provider.plugin.json"
        ))
        .unwrap();
        detect(
            &Core,
            &self.scope("one"),
            &[Package {
                plugin_id: manifest["id"].as_str().unwrap().into(),
                identity: "approved".into(),
                manifest,
            }],
        )
        .unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        std::fs::remove_dir_all(&self.0).expect("remove watch fixture");
    }
}
fn event(path: PathBuf, event_type: FileChangeType) -> FileChangeEvent {
    FileChangeEvent {
        path: path.to_string_lossy().into_owned(),
        event_type,
    }
}

#[test]
fn enclosing_metadata_is_watched_without_recursively_claiming_its_working_copy() {
    let fixture = Fixture::new();
    let plan = plan(
        &fixture.scope("one"),
        &fixture.detection(),
        fixture.0.join("state/choices.json").to_str().unwrap(),
    )
    .unwrap();
    let canonical = fixture.0.canonicalize().unwrap();
    assert_eq!(plan.paths.get(&canonical.join("project")), Some(&true));
    assert_eq!(plan.paths.get(&canonical), Some(&false));
    assert_eq!(plan.paths.get(&canonical.join(".svn")), Some(&false));
    assert!(relevant(
        &plan,
        &event(canonical.join(".svn/wc.db"), FileChangeType::Reloaded)
    ));
    assert!(!relevant(
        &plan,
        &event(canonical.join("sibling/a.txt"), FileChangeType::Reloaded)
    ));
    assert!(relevant(
        &plan,
        &event(canonical.join("project/new/.svn"), FileChangeType::Opened)
    ));
    assert!(relevant(
        &plan,
        &event(
            canonical.join("project/nested/.git"),
            FileChangeType::Deleted
        )
    ));
    assert!(relevant(
        &plan,
        &event(canonical.join("project"), FileChangeType::Rescan)
    ));
}

#[test]
fn declared_metadata_directories_are_watched_recursively_inside_the_verified_enclosing_root() {
    let fixture = Fixture::new();
    let mut detection = fixture.detection();
    detection
        .providers
        .iter_mut()
        .find(|provider| provider["vcs"] == "svn")
        .unwrap()["metadataPaths"] = serde_json::json!([".svn"]);
    let plan = plan(
        &fixture.scope("one"),
        &detection,
        fixture.0.join("state/choices.json").to_str().unwrap(),
    )
    .unwrap();
    let root = fixture.0.canonicalize().unwrap();
    assert_eq!(plan.paths.get(&root), Some(&false));
    assert_eq!(plan.paths.get(&root.join(".svn")), Some(&true));
    assert!(relevant(
        &plan,
        &event(root.join(".svn/deep/metadata"), FileChangeType::Reloaded)
    ));
}

#[test]
fn new_and_removed_roots_use_real_core_and_invalidate_only_the_matching_generation() {
    let fixture = Fixture::new();
    let scope = fixture.scope("one");
    let mut registry = Registry::default();
    let start = std::time::Instant::now();
    let ticket = registry
        .begin("window-one", scope.clone(), 1, start)
        .unwrap();
    let first = registry
        .publish(&ticket, fixture.detection(), vec![], start)
        .unwrap();
    let other = registry
        .begin("window-two", scope.clone(), 2, start)
        .unwrap();
    registry
        .publish(&other, fixture.detection(), vec![], start)
        .unwrap();
    std::fs::create_dir_all(fixture.0.join("project/new/.svn")).unwrap();
    std::fs::remove_dir_all(fixture.0.join("project/nested/.git")).unwrap();
    assert!(!same_roots(&first.detection, &fixture.detection()));
    assert!(!registry.invalidate_generation(
        "window-one",
        &fixture.scope("reopened"),
        ticket.generation
    ));
    assert!(registry.invalidate_generation("window-one", &scope, ticket.generation));
    assert!(!registry.invalidate_generation("window-one", &scope, ticket.generation));
    assert!(registry
        .capture("window-two", &scope, other.generation)
        .is_ok());
    let next = registry
        .begin("window-one", scope.clone(), 1, start)
        .unwrap();
    registry
        .publish(&next, fixture.detection(), vec![], start)
        .unwrap();
    assert!(!registry.invalidate_generation("window-one", &scope, ticket.generation));
    assert!(registry
        .capture("window-one", &scope, next.generation)
        .is_ok());
}

struct Silent;
impl FileChangeEmitter for Silent {
    fn emit_file_change(&self, _: &FileChangeEvent) {}
}
fn lease(scope: Scope, enabled: Arc<AtomicBool>) -> Lease {
    Lease {
        scope,
        generation: 1,
        enabled,
        _watcher: Arc::new(FileWatcher::new(Arc::new(Silent))),
    }
}

#[test]
fn close_and_plugin_revocation_release_exact_watch_leases_and_reject_old_incarnations() {
    let fixture = Fixture::new();
    let watches = Watches::default();
    let enabled = Arc::new(AtomicBool::new(true));
    let other = Arc::new(AtomicBool::new(true));
    watches.0.lock().unwrap().insert(
        ("one".into(), "fixture".into()),
        lease(fixture.scope("new"), enabled.clone()),
    );
    watches.0.lock().unwrap().insert(
        ("two".into(), "fixture".into()),
        lease(fixture.scope("new"), other.clone()),
    );
    watches.remove("one", &fixture.scope("old"));
    assert!(enabled.load(Ordering::Acquire));
    watches.remove_generation("one", &fixture.scope("new"), 0);
    assert!(enabled.load(Ordering::Acquire));
    watches.remove_older("one", "fixture", 2);
    assert!(!enabled.load(Ordering::Acquire));
    assert!(other.load(Ordering::Acquire));
    watches.clear();
    assert!(!other.load(Ordering::Acquire));
}

#[test]
fn window_retirement_rejects_or_releases_a_discovery_lease_at_both_sides_of_revocation() {
    let fixture = Fixture::new();
    let registry = Mutex::new(Registry::default());
    let watches = Watches::default();
    let scope = fixture.scope("one");
    let start = std::time::Instant::now();
    let ticket = registry
        .lock()
        .unwrap()
        .begin("one", scope.clone(), 1, start)
        .unwrap();
    registry
        .lock()
        .unwrap()
        .publish(&ticket, fixture.detection(), vec![], start)
        .unwrap();
    let other_ticket = registry
        .lock()
        .unwrap()
        .begin("two", scope.clone(), 2, start)
        .unwrap();
    registry
        .lock()
        .unwrap()
        .publish(&other_ticket, fixture.detection(), vec![], start)
        .unwrap();
    let other = Arc::new(AtomicBool::new(true));
    let mut other_lease = lease(scope.clone(), other.clone());
    other_lease.generation = other_ticket.generation;
    watches.publish(&registry, "two", other_lease).unwrap();

    let late = Arc::new(AtomicBool::new(true));
    watches.retire_window("one", || {
        // Deterministically gate the interleaving at revocation's entry: an
        // already discovered worker finishes publishing while admission is
        // still open. Removing watches before invoking this callback leaks it.
        let mut pending = lease(scope.clone(), late.clone());
        pending.generation = ticket.generation;
        watches.publish(&registry, "one", pending).unwrap();
        registry.lock().unwrap().close_window("one");
    });
    assert!(!late.load(Ordering::Acquire));
    assert!(other.load(Ordering::Acquire));
    assert_eq!(watches.0.lock().unwrap().len(), 1);

    // A worker completing after revocation cannot register a replacement.
    let rejected = Arc::new(AtomicBool::new(true));
    let mut pending = lease(scope, rejected.clone());
    pending.generation = ticket.generation;
    assert_eq!(
        watches.publish(&registry, "one", pending).unwrap_err(),
        STALE
    );
    assert!(!rejected.load(Ordering::Acquire));
    assert!(registry
        .lock()
        .unwrap()
        .capture("two", &fixture.scope("one"), other_ticket.generation)
        .is_ok());
    watches.clear();
    assert!(!other.load(Ordering::Acquire));
}

#[test]
fn root_watch_budget_fails_explicitly_instead_of_silently_claiming_complete_monitoring() {
    let evidence: Value = serde_json::from_str(include_str!(
        "../../../../../shared/fixtures/vcs/windows-root-mappings-v1.json"
    ))
    .unwrap();
    assert_eq!(evidence["rules"]["maxWatchRoots"], MAX_ROOTS);
    assert_eq!(evidence["rules"]["maxWatchPaths"], MAX_PATHS);
    let fixture = Fixture::new();
    let mut detection = fixture.detection();
    let root = detection.roots[0].clone();
    detection.roots = vec![root; MAX_ROOTS + 1];
    assert!(
        matches!(plan(&fixture.scope("one"), &detection, "ignored"), Err(error) if error == "vcs.watch.limit")
    );
}
