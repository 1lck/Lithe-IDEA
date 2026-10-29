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

#[test]
fn resolve_requires_real_core_ownership_of_existing_ordinary_conflict_endpoints() {
    let fixture = Fixture::new();
    std::fs::create_dir_all(fixture.0.join("folder")).unwrap();
    std::fs::create_dir_all(fixture.0.join("nested/.git")).unwrap();
    std::fs::create_dir_all(fixture.0.join("mixed/.svn")).unwrap();
    std::fs::create_dir_all(fixture.0.join("mixed/.git")).unwrap();
    for path in [
        "conflict.txt",
        "tree.txt",
        "clean.txt",
        "nested/a.txt",
        "mixed/a.txt",
    ] {
        std::fs::write(fixture.0.join(path), "fixture").unwrap();
    }
    let snapshot = fixture.snapshot(&fixture.0);
    let root = &snapshot.detection.roots[0];
    let mut status = fixture.status(&snapshot, json!([
        {"path":"conflict.txt","status":"conflicted"},
        {"path":"tree.txt","oldPath":"absent-old.txt","status":"renamed","flags":["treeConflict"]},
        {"path":"clean.txt","status":"modified"},
        {"path":"folder","status":"conflicted"},
        {"path":"missing.txt","status":"conflicted"},
        {"path":"nested/a.txt","status":"conflicted"},
        {"path":"mixed/a.txt","status":"conflicted"}
    ]));
    // The operation is named resolve, but its real negotiated capability is conflicts.
    status.capabilities["conflicts"] = json!(1);
    let action = WriteOperation::Resolve {
        paths: vec!["tree.txt".into(), "conflict.txt".into(), "tree.txt".into()],
    };
    assert_eq!(
        targets(&super::super::Core, &snapshot, root, &status, &action)
            .unwrap()
            .arguments(),
        json!({"paths":["conflict.txt","tree.txt"]})
    );
    for path in [
        "clean.txt",
        "folder",
        "missing.txt",
        "nested/a.txt",
        "mixed/a.txt",
        "unlisted.txt",
        "../outside.txt",
    ] {
        assert!(
            targets(
                &super::super::Core,
                &snapshot,
                root,
                &status,
                &WriteOperation::Resolve {
                    paths: vec![path.into()]
                }
            )
            .is_err(),
            "{path}"
        );
    }
    for parent in ["added", "replaced", "renamed", "copied"] {
        std::fs::create_dir_all(fixture.0.join(parent)).unwrap();
        std::fs::write(fixture.0.join(parent).join("child.txt"), "fixture").unwrap();
        let mut scheduled = fixture.status(
            &snapshot,
            json!([
                {"path":parent,"status":parent},
                {"path":format!("{parent}/child.txt"),"status":"conflicted"}
            ]),
        );
        scheduled.capabilities["conflicts"] = json!(1);
        assert_eq!(
            targets(
                &super::super::Core,
                &snapshot,
                root,
                &scheduled,
                &WriteOperation::Resolve {
                    paths: vec![format!("{parent}/child.txt")]
                }
            )
            .unwrap_err(),
            "vcs.provider.pathUnavailable"
        );
    }
    status.capabilities = json!({"resolve":1});
    assert_eq!(
        targets(&super::super::Core, &snapshot, root, &status, &action).unwrap_err(),
        "vcs.capability.unsupported"
    );
}

#[test]
fn cleanup_requires_complete_receipt_and_exact_whole_root_without_nested_or_ambiguous_roots() {
    let fixture = Fixture::new();
    let mut snapshot = fixture.snapshot(&fixture.0);
    let mut status = fixture.status(&snapshot, json!([]));
    status.capabilities["cleanup"] = json!(1);
    let check = |snapshot: &registry::Snapshot, status: &Published| {
        targets(
            &super::super::Core,
            snapshot,
            &snapshot.detection.roots[0],
            status,
            &WriteOperation::Cleanup {},
        )
    };
    assert_eq!(check(&snapshot, &status).unwrap().arguments(), json!({}));
    status.raw["truncated"] = json!(true);
    assert!(check(&snapshot, &status).is_err());
    status.raw["truncated"] = json!(false);
    status.projected["truncated"] = json!(true);
    assert!(check(&snapshot, &status).is_err());
    status.projected["truncated"] = json!(false);
    snapshot.detection.truncated = true;
    assert!(check(&snapshot, &status).is_err());
    snapshot.detection.truncated = false;
    status.capabilities["cleanup"] = json!(0);
    assert_eq!(
        check(&snapshot, &status).unwrap_err(),
        "vcs.capability.unsupported"
    );
    status.capabilities["cleanup"] = json!(1);
    std::fs::create_dir_all(fixture.0.join("inside")).unwrap();
    assert!(check(&fixture.snapshot(&fixture.0.join("inside")), &status).is_err());
    std::fs::create_dir_all(fixture.0.join("mixed/.git")).unwrap();
    std::fs::create_dir_all(fixture.0.join("mixed/.svn")).unwrap();
    assert!(check(&fixture.snapshot(&fixture.0), &status).is_err());
    std::fs::create_dir_all(fixture.0.join("nested/.git")).unwrap();
    assert!(check(&fixture.snapshot(&fixture.0), &status).is_err());
}

#[test]
fn resolve_and_cleanup_deserialize_only_the_frozen_v1_arguments() {
    assert_eq!(
        serde_json::from_value::<WriteOperation>(json!({"operation":"resolve","paths":["a.txt"]}))
            .unwrap()
            .arguments(),
        json!({"paths":["a.txt"]})
    );
    assert_eq!(
        serde_json::from_value::<WriteOperation>(json!({"operation":"cleanup"}))
            .unwrap()
            .arguments(),
        json!({})
    );
    for input in [
        json!({"operation":"resolve","paths":["a.txt"],"accept":"working"}),
        json!({"operation":"cleanup","paths":["a.txt"]}),
        json!({"operation":"cleanup","revision":"r2"}),
    ] {
        assert!(serde_json::from_value::<WriteOperation>(input).is_err());
    }
}

#[cfg(windows)]
#[test]
fn resolve_rejects_windows_case_aliases_before_lexical_core_ownership() {
    let fixture = Fixture::new();
    std::fs::create_dir_all(fixture.0.join("nested/.git")).unwrap();
    std::fs::write(fixture.0.join("nested/file.txt"), "fixture").unwrap();
    let snapshot = fixture.snapshot(&fixture.0);
    let mut status = fixture.status(
        &snapshot,
        json!([{"path":"NESTED/file.txt","status":"conflicted"}]),
    );
    status.capabilities["conflicts"] = json!(1);
    assert!(fixture.0.join("NESTED/file.txt").is_file());
    assert_eq!(
        targets(
            &super::super::Core,
            &snapshot,
            &snapshot.detection.roots[0],
            &status,
            &WriteOperation::Resolve {
                paths: vec!["NESTED/file.txt".into()]
            }
        )
        .unwrap_err(),
        "vcs.provider.pathUnavailable"
    );
}

#[test]
fn file_operations_use_existing_ordinary_files_and_real_core_owners_without_parent_expansion() {
    let fixture = Fixture::new();
    for directory in [
        "folder",
        "parent",
        "nested/.git",
        "mixed/.git",
        "mixed/.svn",
    ] {
        std::fs::create_dir_all(fixture.0.join(directory)).unwrap();
    }
    for path in [
        "new.txt",
        "after.txt",
        "before.txt",
        "parent/child.txt",
        "nested/a.txt",
        "mixed/a.txt",
    ] {
        std::fs::write(fixture.0.join(path), "fixture").unwrap();
    }
    let snapshot = fixture.snapshot(&fixture.0);
    let root = &snapshot.detection.roots[0];
    let mut status = fixture.status(
        &snapshot,
        json!([
            {"path":"new.txt","status":"unversioned"},
            {"path":"after.txt","oldPath":"before.txt","status":"renamed"},
            {"path":"parent/child.txt","status":"unversioned"},
            {"path":"folder","status":"unversioned"},
            {"path":"missing","status":"unversioned"},
            {"path":"nested/a.txt","status":"modified"},
            {"path":"mixed/a.txt","status":"modified"}
        ]),
    );
    status.capabilities["fileOperations"] = json!(1);
    let add = WriteOperation::Add {
        paths: vec!["new.txt".into(), "new.txt".into()],
    };
    let delete = WriteOperation::Delete {
        paths: vec!["after.txt".into()],
    };
    assert_eq!(
        targets(&super::super::Core, &snapshot, root, &status, &add)
            .unwrap()
            .arguments(),
        json!({"kind":"add","paths":["new.txt"]})
    );
    assert_eq!(
        targets(&super::super::Core, &snapshot, root, &status, &delete)
            .unwrap()
            .arguments(),
        json!({"kind":"delete","paths":["after.txt","before.txt"]})
    );
    for path in [
        "parent/child.txt",
        "folder",
        "missing",
        "after.txt",
        "unlisted.txt",
    ] {
        assert!(
            targets(
                &super::super::Core,
                &snapshot,
                root,
                &status,
                &WriteOperation::Add {
                    paths: vec![path.into()]
                }
            )
            .is_err(),
            "{path}"
        );
    }
    for path in [
        "new.txt",
        "folder",
        "missing",
        "nested/a.txt",
        "mixed/a.txt",
    ] {
        assert!(
            targets(
                &super::super::Core,
                &snapshot,
                root,
                &status,
                &WriteOperation::Delete {
                    paths: vec![path.into()]
                }
            )
            .is_err(),
            "{path}"
        );
    }
    // Both confirmed endpoints need disk proof, even when a status row claims
    // a rename and omits all descendant information about the absent endpoint.
    std::fs::remove_file(fixture.0.join("before.txt")).unwrap();
    assert!(targets(&super::super::Core, &snapshot, root, &status, &delete).is_err());
    status.capabilities = json!({"add":1,"delete":1,"fileOperation":1});
    assert_eq!(
        targets(&super::super::Core, &snapshot, root, &status, &add).unwrap_err(),
        "vcs.capability.unsupported"
    );
}

#[test]
fn delete_checks_independent_old_endpoint_rows_regardless_of_order_or_repeated_selection() {
    let fixture = Fixture::new();
    for path in ["after.txt", "before.txt"] {
        std::fs::write(fixture.0.join(path), "fixture").unwrap();
    }
    let snapshot = fixture.snapshot(&fixture.0);
    let root = &snapshot.detection.roots[0];
    for kind in ["renamed", "copied"] {
        for (old_status, flags) in [
            ("unversioned", json!([])),
            ("ignored", json!([])),
            ("conflicted", json!([])),
            ("modified", json!(["external"])),
            ("modified", json!(["submodule"])),
            ("modified", json!(["treeConflict"])),
            ("modified", json!([])),
        ] {
            let current = json!({"path":"after.txt","oldPath":"before.txt","status":kind});
            let old = json!({"path":"before.txt","status":old_status,"flags":flags});
            for changes in [json!([current, old]), json!([old, current])] {
                let mut status = fixture.status(&snapshot, changes);
                status.capabilities["fileOperations"] = json!(1);
                for selected in [
                    vec!["after.txt"],
                    vec!["after.txt", "after.txt"],
                    vec!["before.txt", "after.txt", "before.txt"],
                    vec!["after.txt", "before.txt"],
                ] {
                    let result = targets(
                        &super::super::Core,
                        &snapshot,
                        root,
                        &status,
                        &WriteOperation::Delete {
                            paths: selected.into_iter().map(String::from).collect(),
                        },
                    );
                    if old_status == "modified" && flags == json!([]) {
                        assert_eq!(
                            result.unwrap().arguments(),
                            json!({"kind":"delete","paths":["after.txt","before.txt"]})
                        );
                    } else {
                        assert_eq!(result.unwrap_err(), "vcs.provider.pathUnavailable");
                    }
                }
            }
        }
    }
}

#[test]
fn file_operations_reject_incomplete_receipts_unsafe_flags_and_implicit_scheduled_ancestors() {
    let fixture = Fixture::new();
    std::fs::write(fixture.0.join("new.txt"), "fixture").unwrap();
    std::fs::create_dir_all(fixture.0.join("parent")).unwrap();
    std::fs::write(fixture.0.join("parent/child.txt"), "fixture").unwrap();
    let snapshot = fixture.snapshot(&fixture.0);
    let root = &snapshot.detection.roots[0];
    for parent in [
        "added",
        "replaced",
        "renamed",
        "copied",
        "unversioned",
        "ignored",
    ] {
        let mut status = fixture.status(
            &snapshot,
            json!([
                {"path":"parent","status":parent}, {"path":"parent/child.txt","status":"modified"}
            ]),
        );
        status.capabilities["fileOperations"] = json!(1);
        assert!(
            targets(
                &super::super::Core,
                &snapshot,
                root,
                &status,
                &WriteOperation::Delete {
                    paths: vec!["parent/child.txt".into()]
                }
            )
            .is_err(),
            "{parent}"
        );
    }
    for (kind, row_status) in [("add", "unversioned"), ("delete", "modified")] {
        let action: WriteOperation =
            serde_json::from_value(json!({"operation":kind,"paths":["new.txt"]})).unwrap();
        for flag in ["external", "submodule", "treeConflict"] {
            let mut status = fixture.status(
                &snapshot,
                json!([{"path":"new.txt","status":row_status,"flags":[flag]}]),
            );
            status.capabilities["fileOperations"] = json!(1);
            assert!(targets(&super::super::Core, &snapshot, root, &status, &action).is_err());
        }
        let mut status = fixture.status(&snapshot, json!([{"path":"new.txt","status":row_status}]));
        status.capabilities["fileOperations"] = json!(1);
        for field in ["raw", "projected"] {
            if field == "raw" {
                status.raw["truncated"] = json!(true);
            } else {
                status.projected["truncated"] = json!(true);
            }
            assert!(targets(&super::super::Core, &snapshot, root, &status, &action).is_err());
            status.raw["truncated"] = json!(false);
        }
    }
}

#[test]
fn add_delete_deserialize_no_keep_local_recursion_or_arbitrary_provider_arguments() {
    for kind in ["add", "delete"] {
        let action: WriteOperation =
            serde_json::from_value(json!({"operation":kind,"paths":["a.txt"]})).unwrap();
        assert_eq!(action.name(), kind);
        assert_eq!(action.request_name(), "fileOperation");
        assert_eq!(action.capability(), "fileOperations");
        assert_eq!(action.arguments(), json!({"kind":kind,"paths":["a.txt"]}));
        for field in [
            "keepLocal",
            "recursive",
            "depth",
            "force",
            "root",
            "tool",
            "kind",
        ] {
            let mut input = json!({"operation":kind,"paths":["a.txt"]});
            input[field] = json!(true);
            assert!(
                serde_json::from_value::<WriteOperation>(input).is_err(),
                "{field}"
            );
        }
    }
    assert!(serde_json::from_value::<WriteOperation>(
        json!({"operation":"move","from":"a","to":"b"})
    )
    .is_err());
}

#[cfg(windows)]
#[test]
fn add_delete_reject_windows_case_aliases_before_core_lexical_ownership() {
    let fixture = Fixture::new();
    std::fs::write(fixture.0.join("MixedCase.txt"), "fixture").unwrap();
    let snapshot = fixture.snapshot(&fixture.0);
    let root = &snapshot.detection.roots[0];
    for (kind, row_status) in [("add", "unversioned"), ("delete", "modified")] {
        let mut status = fixture.status(
            &snapshot,
            json!([{"path":"mixedcase.txt","status":row_status}]),
        );
        status.capabilities["fileOperations"] = json!(1);
        let action: WriteOperation =
            serde_json::from_value(json!({"operation":kind,"paths":["mixedcase.txt"]})).unwrap();
        assert!(fixture.0.join("mixedcase.txt").is_file());
        assert_eq!(
            targets(&super::super::Core, &snapshot, root, &status, &action).unwrap_err(),
            "vcs.provider.pathUnavailable"
        );
    }
}
