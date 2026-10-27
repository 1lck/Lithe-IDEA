use super::*;
use serde_json::json;
use std::sync::atomic::{AtomicU64, Ordering};
static NEXT: AtomicU64 = AtomicU64::new(1);
struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!(
            "lithe-vcs-status-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        for marker in [
            "legacy/.svn",
            "legacy/nested/.git",
            "legacy/mixed/.svn",
            "legacy/mixed/.git",
            "other/.svn",
        ] {
            std::fs::create_dir_all(root.join(marker)).unwrap();
        }
        Self(root)
    }
    fn snapshot(&self) -> registry::Snapshot {
        let manifest: Value = serde_json::from_str(include_str!(
            "../../../../../shared/contracts/plugins/v1/fixtures/vcs-provider.plugin.json"
        ))
        .unwrap();
        let scope = Scope {
            workspace_id: "fixture".into(),
            workspace_root: self.0.to_string_lossy().into_owned(),
            incarnation: "one".into(),
        };
        let packages = [registry::Package {
            plugin_id: manifest["id"].as_str().unwrap().into(),
            identity: "whole-package-digest".into(),
            manifest,
        }];
        registry::Snapshot {
            generation: 1,
            workspace_id: scope.workspace_id.clone(),
            workspace_root: scope.workspace_root.clone(),
            detection: registry::detect(&super::super::Core, &scope, &packages).unwrap(),
        }
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        std::fs::remove_dir_all(&self.0).expect("remove VCS status fixture");
    }
}
fn decoded(changes: Value) -> Value {
    let response=crate::plugin_host::scan::core_execute("vcs.decodeReply",json!({"operation":"status","capabilities":{"status":1,"baseContent":1,"checkin":1,"rollback":1},"request":{"includeIgnored":false},"reply":{"changes":changes}})).unwrap();
    assert_eq!(response["status"], "ok");
    response["result"].clone()
}

#[test]
fn real_core_projection_excludes_nested_git_ambiguous_paths_and_cross_root_moves() {
    let fixture = Fixture::new();
    let snapshot = fixture.snapshot();
    let root = snapshot
        .detection
        .roots
        .iter()
        .find(|root| root.id == "legacy")
        .unwrap();
    let result=project_status(&super::super::Core,&snapshot,root,decoded(json!([
        {"path":"a.txt","status":"modified"},{"path":"nested/git.txt","status":"modified"},
        {"path":"mixed/ambiguous.txt","status":"modified"},{"path":"moved.txt","oldPath":"nested/source.txt","status":"renamed"},
        {"path":"renamed.txt","oldPath":"source.txt","status":"renamed"}
    ]))).unwrap();
    assert_eq!(
        result["changes"]
            .as_array()
            .unwrap()
            .iter()
            .map(|change| change["path"].as_str().unwrap())
            .collect::<Vec<_>>(),
        vec!["a.txt", "renamed.txt"]
    );
    let other = snapshot
        .detection
        .roots
        .iter()
        .find(|root| root.id == "other")
        .unwrap();
    assert_eq!(
        project_status(
            &super::super::Core,
            &snapshot,
            other,
            decoded(json!([{"path":"a.txt","status":"added"}]))
        )
        .unwrap()["changes"][0]["path"],
        "a.txt"
    );
}

#[test]
fn real_core_projection_matches_an_ordinary_workspace_path_and_keeps_deleted_paths() {
    let fixture = Fixture::new();
    let snapshot = fixture.snapshot();
    let root = snapshot
        .detection
        .roots
        .iter()
        .find(|root| root.id == "legacy")
        .unwrap();
    // A normal temp path and Core's canonical root have different Windows
    // prefix kinds. Changes themselves need not exist on disk.
    assert_eq!(
        PathBuf::from(&root.path),
        fixture.0.canonicalize().unwrap().join("legacy")
    );
    assert!(!PathBuf::from(&root.path).join("deleted.txt").exists());
    assert!(!PathBuf::from(&root.path).join("before.txt").exists());
    let result = project_status(
        &super::super::Core,
        &snapshot,
        root,
        decoded(json!([
            {"path":"deleted.txt","status":"deleted"},
            {"path":"after.txt","oldPath":"before.txt","status":"renamed"}
        ])),
    )
    .unwrap();
    assert_eq!(result["changes"].as_array().unwrap().len(), 2);
    assert_eq!(result["changes"][0]["path"], "after.txt");
    assert_eq!(result["changes"][0]["oldPath"], "before.txt");
    assert_eq!(result["changes"][1]["path"], "deleted.txt");
}

#[test]
fn enclosing_working_copy_projects_only_this_workspace_and_complete_detection() {
    let fixture = Fixture::new();
    std::fs::create_dir_all(fixture.0.join(".svn")).unwrap();
    std::fs::create_dir_all(fixture.0.join("child")).unwrap();
    let mut snapshot = fixture.snapshot();
    let root = snapshot
        .detection
        .roots
        .iter()
        .find(|root| root.id.is_empty())
        .unwrap()
        .clone();
    snapshot.workspace_root = fixture.0.join("child").to_string_lossy().into_owned();
    snapshot.detection.roots = vec![registry::Root {
        id: "..".into(),
        ..root
    }];
    snapshot.detection.ambiguous.clear();
    let root = snapshot.detection.roots[0].clone();
    let result = project_status(
        &super::super::Core,
        &snapshot,
        &root,
        decoded(json!([
            {"path":"child/a.txt","status":"modified"},{"path":"sibling.txt","status":"modified"},
            {"path":"child/moved.txt","oldPath":"outside.txt","status":"renamed"}
        ])),
    )
    .unwrap();
    assert_eq!(result["changes"].as_array().unwrap().len(), 1);
    assert_eq!(result["changes"][0]["path"], "child/a.txt");
    snapshot.detection.truncated = true;
    assert_eq!(
        project_status(&super::super::Core, &snapshot, &root, decoded(json!([]))).unwrap_err(),
        "vcs.provider.incompleteRoots"
    );
}

#[test]
fn core_launch_plan_rejects_a_vcs_provider_without_its_real_declared_permissions() {
    let mut manifest: Value = serde_json::from_str(include_str!(
        "../../../../../shared/contracts/plugins/v1/fixtures/vcs-provider.plugin.json"
    ))
    .unwrap();
    manifest["permissions"] = json!(["languageServer.launch"]);
    let response = crate::plugin_host::scan::core_execute(
        "plugins.declarative.validate",
        json!({"manifest":manifest}),
    )
    .unwrap();
    assert_eq!(response["status"], "rejected");
    assert!(response["error"]["message"]
        .as_str()
        .unwrap()
        .contains("process.vcs"));
}
