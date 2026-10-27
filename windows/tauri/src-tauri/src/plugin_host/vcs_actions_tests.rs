use super::*;
use std::sync::atomic::{AtomicU64, Ordering};
static NEXT: AtomicU64 = AtomicU64::new(1);
struct Fixture(std::path::PathBuf);
impl Fixture {
    fn new() -> Self {
        let fixture = Self(std::env::temp_dir().join(format!(
            "lithe-vcs-actions-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        )));
        std::fs::create_dir_all(fixture.0.join(".svn")).unwrap();
        fixture
    }
    fn snapshot(&self, workspace: &Path) -> registry::Snapshot {
        let manifest: Value = serde_json::from_str(include_str!(
            "../../../../../shared/contracts/plugins/v1/fixtures/vcs-provider.plugin.json"
        ))
        .unwrap();
        let scope = Scope {
            workspace_id: "fixture".into(),
            workspace_root: workspace.to_string_lossy().into_owned(),
            incarnation: "one".into(),
        };
        registry::Snapshot {
            generation: 1,
            workspace_id: scope.workspace_id.clone(),
            workspace_root: scope.workspace_root.clone(),
            detection: registry::detect(
                &super::super::Core,
                &scope,
                &[registry::Package {
                    plugin_id: manifest["id"].as_str().unwrap().into(),
                    identity: "digest".into(),
                    manifest,
                }],
            )
            .unwrap(),
            mappings: None,
            watch_error: None,
            mapping_choices: Vec::new(),
        }
    }
    fn status(&self, snapshot: &registry::Snapshot, changes: Value) -> Published {
        let decoded = crate::plugin_host::scan::core_execute("vcs.decodeReply", json!({"operation":"status","request":{},"capabilities":{"status":1},"reply":{"changes":changes}})).unwrap();
        assert_eq!(decoded["status"], "ok");
        Published {
            context: session::Context {
                host: "workspace-fixture".into(),
                scope: Scope {
                    workspace_id: "fixture".into(),
                    workspace_root: snapshot.workspace_root.clone(),
                    incarnation: "one".into(),
                },
                generation: 1,
                registration: 2,
                request_id: "status-receipt".into(),
                root: snapshot.detection.roots[0].clone(),
                root_identity: "directory-identity".into(),
                plugin_id: "fixture.plugin".into(),
                package_identity: "digest".into(),
                settings_revision: 0,
            },
            raw: decoded["result"].clone(),
            projected: decoded["result"].clone(),
            capabilities: json!({"status":1,"checkin":1,"rollback":1,"update":1}),
        }
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        std::fs::remove_dir_all(&self.0).expect("remove action fixture");
    }
}
#[test]
fn real_core_owners_keep_existing_selected_endpoints_but_reject_cross_roots() {
    let fixture = Fixture::new();
    for path in ["new.txt", "gone.txt", "after.txt", "before.txt"] {
        std::fs::write(fixture.0.join(path), "fixture").unwrap();
    }
    std::fs::create_dir_all(fixture.0.join("nested/.git")).unwrap();
    std::fs::create_dir_all(fixture.0.join("mixed/.svn")).unwrap();
    std::fs::create_dir_all(fixture.0.join("mixed/.git")).unwrap();
    let snapshot = fixture.snapshot(&fixture.0);
    let root = &snapshot.detection.roots[0];
    let status = fixture.status(
        &snapshot,
        json!([
            {"path":"new.txt","status":"added"}, {"path":"gone.txt","status":"deleted"},
            {"path":"after.txt","oldPath":"before.txt","status":"renamed"},
            {"path":"bad.txt","oldPath":"nested/old.txt","status":"renamed"},
            {"path":"mixed/a.txt","status":"modified"}
        ]),
    );
    let action = WriteOperation::Checkin {
        paths: vec!["new.txt".into(), "gone.txt".into(), "after.txt".into()],
        message: "Selected changes".into(),
    };
    let expanded = targets(&super::super::Core, &snapshot, root, &status, &action).unwrap();
    assert_eq!(
        expanded.arguments(),
        json!({"paths":["after.txt","before.txt","gone.txt","new.txt"],"message":"Selected changes"})
    );
    // Canonicalize the root before joining endpoints, so Windows' ordinary
    // absolute spelling is not rejected merely for lacking the verbatim prefix.
    let mut ordinary_root = root.clone();
    ordinary_root.path = fixture.0.to_string_lossy().into_owned();
    assert!(targets(
        &super::super::Core,
        &snapshot,
        &ordinary_root,
        &status,
        &action
    )
    .is_ok());
    for path in ["bad.txt", "mixed/a.txt", "not-selected.txt"] {
        assert!(targets(
            &super::super::Core,
            &snapshot,
            root,
            &status,
            &WriteOperation::Rollback {
                paths: vec![path.into()]
            }
        )
        .is_err());
    }
    assert!(targets(
        &super::super::Core,
        &snapshot,
        root,
        &status,
        &WriteOperation::Update
    )
    .is_err());
}
#[test]
fn update_requires_exact_whole_unambiguous_working_copy_and_complete_snapshot() {
    let fixture = Fixture::new();
    let mut snapshot = fixture.snapshot(&fixture.0);
    let mut status = fixture.status(&snapshot, json!([]));
    assert!(targets(
        &super::super::Core,
        &snapshot,
        &snapshot.detection.roots[0],
        &status,
        &WriteOperation::Update
    )
    .is_ok());
    status.projected["truncated"] = json!(true);
    assert!(targets(
        &super::super::Core,
        &snapshot,
        &snapshot.detection.roots[0],
        &status,
        &WriteOperation::Update
    )
    .is_err());
    std::fs::create_dir_all(fixture.0.join("inside")).unwrap();
    snapshot = fixture.snapshot(&fixture.0.join("inside"));
    status = fixture.status(&snapshot, json!([]));
    assert!(targets(
        &super::super::Core,
        &snapshot,
        &snapshot.detection.roots[0],
        &status,
        &WriteOperation::Update
    )
    .is_err());
}
#[test]
fn receipts_are_one_shot_scope_owned_and_replacement_identity_cannot_inherit_confirmation() {
    let fixture = Fixture::new();
    let snapshot = fixture.snapshot(&fixture.0);
    let published = fixture.status(&snapshot, json!([]));
    let context = published.context.clone();
    let mut actions = Actions::default();
    actions.publish(published.clone());
    assert!(actions
        .take("another-window", &context.scope, "status-receipt")
        .is_err());
    let mut scope = context.scope.clone();
    scope.incarnation = "replacement".into();
    assert!(actions
        .take(&context.host, &scope, "status-receipt")
        .is_err());
    assert!(actions
        .take(&context.host, &context.scope, "status-receipt")
        .is_ok());
    assert!(actions
        .take(&context.host, &context.scope, "status-receipt")
        .is_err());
    let mut changed = context.clone();
    changed.package_identity = "replaced-bytes".into();
    assert!(!same_source(&published, &changed));
    changed = context.clone();
    changed.registration += 1;
    assert!(!same_source(&published, &changed));
    changed = context.clone();
    changed.root_identity = "replacement-directory".into();
    assert!(!same_source(&published, &changed));
    changed = context.clone();
    changed.settings_revision += 1;
    assert!(!same_source(&published, &changed));
}
#[test]
fn ignored_unversioned_rollback_recursive_directories_and_unselected_paths_are_rejected() {
    let fixture = Fixture::new();
    std::fs::create_dir_all(fixture.0.join("folder")).unwrap();
    let snapshot = fixture.snapshot(&fixture.0);
    let status = fixture.status(
        &snapshot,
        json!([
            {"path":"ignored.txt","status":"ignored"}, {"path":"new.txt","status":"unversioned"},
            {"path":"folder","status":"modified"}, {"path":"missing-folder","status":"missing"},
            {"path":"missing-folder/child.txt","status":"missing"}
        ]),
    );
    for path in [
        "ignored.txt",
        "new.txt",
        "folder",
        "missing-folder",
        "../outside.txt",
    ] {
        assert!(targets(
            &super::super::Core,
            &snapshot,
            &snapshot.detection.roots[0],
            &status,
            &WriteOperation::Rollback {
                paths: vec![path.into()]
            }
        )
        .is_err());
    }
}

#[test]
fn absent_endpoints_cannot_prove_a_file_only_write_even_without_descendant_status_rows() {
    let fixture = Fixture::new();
    std::fs::create_dir_all(fixture.0.join("removed-directory")).unwrap();
    std::fs::write(fixture.0.join("removed-directory/unlisted.txt"), "fixture").unwrap();
    std::fs::remove_dir_all(fixture.0.join("removed-directory")).unwrap();
    std::fs::write(fixture.0.join("after.txt"), "fixture").unwrap();
    let snapshot = fixture.snapshot(&fixture.0);
    let status = fixture.status(
        &snapshot,
        json!([
            {"path":"removed-directory","status":"missing"},
            {"path":"gone.txt","status":"deleted"},
            {"path":"after.txt","oldPath":"before.txt","status":"renamed"}
        ]),
    );
    for path in ["removed-directory", "gone.txt", "after.txt"] {
        for action in [
            WriteOperation::Checkin {
                paths: vec![path.into()],
                message: "Only the confirmed file".into(),
            },
            WriteOperation::Rollback {
                paths: vec![path.into()],
            },
        ] {
            assert_eq!(
                targets(
                    &super::super::Core,
                    &snapshot,
                    &snapshot.detection.roots[0],
                    &status,
                    &action
                )
                .unwrap_err(),
                "vcs.provider.pathUnavailable"
            );
        }
    }
}

#[test]
fn checkin_rejects_implicit_scheduled_parent_changes_but_keeps_unrelated_files_available() {
    let fixture = Fixture::new();
    let mut changes = vec![json!({"path":"other.txt","status":"modified"})];
    std::fs::write(fixture.0.join("other.txt"), "fixture").unwrap();
    for status in ["added", "replaced", "renamed", "copied"] {
        let parent = format!("{status}-parent");
        std::fs::create_dir_all(fixture.0.join(&parent).join("inside")).unwrap();
        std::fs::write(fixture.0.join(&parent).join("inside/child.txt"), "fixture").unwrap();
        changes.push(json!({"path":parent,"status":status}));
        changes.push(json!({"path":format!("{parent}/inside/child.txt"),"status":"added"}));
    }
    let snapshot = fixture.snapshot(&fixture.0);
    let status = fixture.status(&snapshot, json!(changes));
    for parent in ["added", "replaced", "renamed", "copied"] {
        assert_eq!(
            targets(
                &super::super::Core,
                &snapshot,
                &snapshot.detection.roots[0],
                &status,
                &WriteOperation::Checkin {
                    paths: vec![format!("{parent}-parent/inside/child.txt")],
                    message: "No implicit parent".into(),
                }
            )
            .unwrap_err(),
            "vcs.provider.pathUnavailable"
        );
    }
    assert!(targets(
        &super::super::Core,
        &snapshot,
        &snapshot.detection.roots[0],
        &status,
        &WriteOperation::Checkin {
            paths: vec!["other.txt".into()],
            message: "Only the confirmed file".into(),
        }
    )
    .is_ok());
}

#[cfg(windows)]
#[test]
fn windows_case_aliases_cannot_hide_nested_roots_or_implicit_parent_changes() {
    let fixture = Fixture::new();
    std::fs::create_dir_all(fixture.0.join("nested/.git")).unwrap();
    std::fs::write(fixture.0.join("nested/file.txt"), "fixture").unwrap();
    std::fs::create_dir_all(fixture.0.join("AddedParent")).unwrap();
    std::fs::write(fixture.0.join("AddedParent/child.txt"), "fixture").unwrap();
    let snapshot = fixture.snapshot(&fixture.0);
    let status = fixture.status(
        &snapshot,
        json!([
            {"path":"NESTED/file.txt","status":"modified"},
            {"path":"AddedParent","status":"added"},
            {"path":"addedparent/child.txt","status":"added"}
        ]),
    );
    for path in ["NESTED/file.txt", "addedparent/child.txt"] {
        assert!(fixture.0.join(path).is_file(), "Windows resolves the alias");
        assert_eq!(
            targets(
                &super::super::Core,
                &snapshot,
                &snapshot.detection.roots[0],
                &status,
                &WriteOperation::Checkin {
                    paths: vec![path.into()],
                    message: "The spelling cannot bypass ownership".into(),
                }
            )
            .unwrap_err(),
            "vcs.provider.pathUnavailable"
        );
    }
}
