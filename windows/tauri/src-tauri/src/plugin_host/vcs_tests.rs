use super::registry::*;
use super::*;
use serde_json::json;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT: AtomicU64 = AtomicU64::new(1);
struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "lithe-vcs-roots-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir(&path).unwrap();
        Self(path)
    }
    fn directory(&self, relative: &str) {
        std::fs::create_dir_all(self.0.join(relative)).unwrap();
    }
    fn scope(&self, incarnation: &str) -> Scope {
        Scope {
            workspace_id: "fixture-workspace".into(),
            workspace_root: self.0.to_string_lossy().into_owned(),
            incarnation: incarnation.into(),
        }
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        std::fs::remove_dir_all(&self.0).expect("remove VCS fixture");
    }
}
fn package() -> Package {
    let manifest: Value = serde_json::from_str(include_str!(
        "../../../../../shared/contracts/plugins/v1/fixtures/vcs-provider.plugin.json"
    ))
    .unwrap();
    Package {
        plugin_id: manifest["id"].as_str().unwrap().into(),
        identity: "fixture-approved-whole-package".into(),
        manifest,
    }
}
fn snapshot(scope: &Scope, detection: Detection) -> Snapshot {
    Snapshot {
        generation: 1,
        workspace_id: scope.workspace_id.clone(),
        workspace_root: scope.workspace_root.clone(),
        detection,
    }
}
fn paths(values: &[&str]) -> Vec<String> {
    values.iter().map(|value| (*value).into()).collect()
}

#[test]
fn real_core_detects_mixed_nested_roots_and_never_assigns_cross_root_moves() {
    let fixture = Fixture::new();
    for directory in [
        ".git",
        "legacy/.svn",
        "legacy/nested-git/.git",
        "mixed/.git",
        "mixed/.svn",
        "node_modules/ignored/.svn",
    ] {
        fixture.directory(directory);
    }
    let scope = fixture.scope("one");
    let detection = detect(&Core, &scope, &[package()]).unwrap();
    assert_eq!(
        detection
            .roots
            .iter()
            .map(|root| (root.id.as_str(), root.vcs.as_str()))
            .collect::<Vec<_>>(),
        vec![("", "git"), ("legacy", "svn"), ("legacy/nested-git", "git")]
    );
    assert_eq!(detection.ambiguous[0]["id"], "mixed");
    let state = snapshot(&scope, detection);
    let owned = owners(
        &Core,
        &state,
        &paths(&[
            "README.md",
            "legacy/a.txt",
            "legacy/nested-git/b.txt",
            "mixed/c.txt",
        ]),
    )
    .unwrap();
    assert_eq!(
        owned
            .owners
            .iter()
            .map(|owner| owner.root.as_deref())
            .collect::<Vec<_>>(),
        vec![Some(""), Some("legacy"), Some("legacy/nested-git"), None]
    );
    assert!(owned.common_root.is_none());
    assert_eq!(
        owners(&Core, &state, &paths(&["legacy/a.txt", "legacy/b.txt"]))
            .unwrap()
            .common_root
            .unwrap()
            .id,
        "legacy"
    );
    assert!(
        owners(&Core, &state, &paths(&["legacy/a.txt", "README.md"]))
            .unwrap()
            .common_root
            .is_none()
    );
    assert!(owners(&Core, &state, &paths(&["../escape"])).is_err());
}

#[test]
fn real_core_handles_enclosing_working_copies_and_excluded_plugin_manifests() {
    let fixture = Fixture::new();
    fixture.directory(".svn");
    fixture.directory("project/nested/.git");
    let mut scope = fixture.scope("one");
    scope.workspace_root = fixture.0.join("project").to_string_lossy().into_owned();
    let detected = detect(&Core, &scope, &[package()]).unwrap();
    assert_eq!(
        detected
            .roots
            .iter()
            .map(|root| root.id.as_str())
            .collect::<Vec<_>>(),
        vec!["..", "nested"]
    );
    let state = snapshot(&scope, detected);
    assert_eq!(
        owners(&Core, &state, &paths(&["src/a.txt"]))
            .unwrap()
            .common_root
            .unwrap()
            .id,
        ".."
    );
    // Production supplies only accepted/enabled manifests. Removing that input
    // removes SVN authority while built-in Git detection stays available.
    let without_plugin = detect(&Core, &scope, &[]).unwrap();
    assert!(without_plugin.roots.iter().all(|root| root.vcs == "git"));
    assert!(without_plugin
        .providers
        .iter()
        .all(|provider| provider["origin"]["kind"] == "builtIn"));
}

#[test]
fn truncated_and_ambiguous_snapshots_never_report_a_common_action_owner() {
    let fixture = Fixture::new();
    fixture.directory(".git");
    let scope = fixture.scope("one");
    let mut state = snapshot(&scope, detect(&Core, &scope, &[]).unwrap());
    state.detection.truncated = true;
    let owned = owners(&Core, &state, &paths(&["a.txt", "b.txt"])).unwrap();
    assert!(!owned.complete);
    assert!(owned.common_root.is_none());
    assert_eq!(owned.owners[0].root.as_deref(), Some(""));
    assert!(owners(&Core, &state, &[]).unwrap().common_root.is_none());
}

#[test]
fn a_new_nested_or_ambiguous_root_invalidates_the_previous_core_ownership_snapshot() {
    let fixture = Fixture::new();
    fixture.directory(".git");
    let scope = fixture.scope("one");
    let initial = detect(&Core, &scope, &[package()]).unwrap();
    fixture.directory("legacy/.svn");
    let nested = detect(&Core, &scope, &[package()]).unwrap();
    assert!(!same_roots(&initial, &nested));
    fixture.directory("legacy/.git");
    let ambiguous = detect(&Core, &scope, &[package()]).unwrap();
    assert!(!same_roots(&nested, &ambiguous));
    assert!(same_roots(
        &ambiguous,
        &detect(&Core, &scope, &[package()]).unwrap()
    ));
}

#[test]
fn native_registry_rejects_late_detection_after_close_plugin_change_timeout_or_new_scan() {
    let fixture = Fixture::new();
    fixture.directory(".git");
    let scope = fixture.scope("one");
    let now = Instant::now();
    let detection = detect(&Core, &scope, &[]).unwrap();
    let mut registry = Registry::default();
    let first = registry.begin("main", scope.clone(), 7, now).unwrap();
    assert!(registry.begin("main", scope.clone(), 8, now).is_err());
    let second = registry.begin("main", scope.clone(), 7, now).unwrap();
    assert!(registry
        .publish(&first, detection.clone(), vec![], now)
        .is_err());
    let view = registry
        .publish(&second, detection.clone(), vec![], now)
        .unwrap();
    assert!(registry
        .capture("workspace-other", &scope, view.generation)
        .is_err());
    registry.invalidate();
    assert!(registry.capture("main", &scope, view.generation).is_err());
    assert!(registry
        .publish(&second, detection.clone(), vec![], now)
        .is_err());
    let late = registry.begin("main", scope.clone(), 7, now).unwrap();
    assert!(registry
        .publish(&late, detection.clone(), vec![], now + READ_TIMEOUT)
        .is_err());
    registry.retire("main", &scope).unwrap();
    assert!(registry.begin("main", scope.clone(), 7, now).is_err());
    let fresh = fixture.scope("two");
    let reopened = registry.begin("main", fresh.clone(), 7, now).unwrap();
    registry
        .publish(&reopened, detection.clone(), vec![], now)
        .unwrap();
    registry.close_window("main");
    assert!(registry
        .capture("main", &fresh, reopened.generation)
        .is_err());
    assert!(registry.begin("main", fresh, 7, now).is_err());
}

#[test]
fn closed_old_incarnation_cannot_close_a_reopened_workspace_or_another_window() {
    let fixture = Fixture::new();
    let now = Instant::now();
    let old = fixture.scope("old");
    let fresh = fixture.scope("fresh");
    let detection = detect(&Core, &old, &[]).unwrap();
    let mut registry = Registry::default();
    registry.begin("main", old.clone(), 7, now).unwrap();
    let next = registry.begin("main", fresh.clone(), 7, now).unwrap();
    registry
        .publish(&next, detection.clone(), vec![package()], now)
        .unwrap();
    let other = registry
        .begin("workspace-other", old.clone(), 7, now)
        .unwrap();
    registry.publish(&other, detection, vec![], now).unwrap();
    registry.retire("main", &old).unwrap();
    assert!(registry.capture("main", &fresh, next.generation).is_ok());
    assert!(registry
        .capture("workspace-other", &old, other.generation)
        .is_ok());
    let mut changed_path = fresh.clone();
    changed_path.workspace_root.push_str("/different");
    assert!(registry.begin("main", changed_path, 7, now).is_err());
    assert!(registry
        .begin(
            "main",
            fresh.clone(),
            7,
            now - std::time::Duration::from_nanos(1)
        )
        .is_err());
}

#[test]
fn passive_vcs_queries_do_not_enable_the_provider_capability() {
    assert!(super::super::host_capabilities()
        .get("vcsProviders")
        .is_none());
    assert!(validate(&Scope {
        workspace_id: "fixture".into(),
        workspace_root: "relative".into(),
        incarnation: "one".into()
    })
    .is_err());
    assert!(serde_json::from_value::<Scope>(
        json!({"workspaceId":"fixture","workspaceRoot":"relative","incarnation":"one","plugins":[]})
    )
    .is_err());
}

#[test]
fn plugin_private_pages_cannot_invoke_the_native_vcs_snapshot_commands() {
    let mut context: tauri::Context<tauri::Wry> = tauri::generate_context!();
    let acl = context.runtime_authority_mut();
    let origin = tauri::ipc::Origin::Remote {
        url: url::Url::parse("http://lithe-plugin.fixture.plugin/ui/index.html").unwrap(),
    };
    for command in [
        "declarative_plugins_vcs_detect",
        "declarative_plugins_vcs_owners",
        "declarative_plugins_vcs_close",
        "declarative_plugins_vcs_status",
        "declarative_plugins_vcs_cancel_status",
    ] {
        assert!(acl
            .resolve_access(command, "plugin-web-fixture", "plugin-web-fixture", &origin)
            .is_none());
    }
}
