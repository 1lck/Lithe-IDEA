use super::super::registry::{detect_mapped, owners, Package, Snapshot};
use super::*;
use std::sync::atomic::{AtomicU64, Ordering};
static NEXT: AtomicU64 = AtomicU64::new(1);
struct Fixture(PathBuf);
impl Fixture {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!(
            "lithe-vcs-mappings-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        for marker in ["mixed/.git", "mixed/.svn", "mixed/nested/.git", "project"] {
            std::fs::create_dir_all(path.join(marker)).unwrap();
        }
        Self(path)
    }
    fn source(&self) -> PathBuf {
        self.0.join("state/choices.json")
    }
    fn scope(&self) -> Scope {
        Scope {
            workspace_id: "fixture".into(),
            workspace_root: self.0.to_string_lossy().into_owned(),
            incarnation: "one".into(),
        }
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        std::fs::remove_dir_all(&self.0).expect("remove mapping fixture");
    }
}
fn packages() -> Vec<Package> {
    let manifest: Value = serde_json::from_str(include_str!(
        "../../../../../shared/contracts/plugins/v1/fixtures/vcs-provider.plugin.json"
    ))
    .unwrap();
    vec![Package {
        plugin_id: manifest["id"].as_str().unwrap().into(),
        identity: "approved-package".into(),
        manifest,
    }]
}

#[test]
fn opening_is_read_only_and_confirmed_mapping_reopens_with_real_core_ownership() {
    let fixture = Fixture::new();
    let first = read_at(&fixture.source(), &fixture.0).unwrap();
    assert!(first.entries.is_empty());
    assert!(!fixture.source().parent().unwrap().exists());
    let saved = save_at(
        &fixture.source(),
        &fixture.0,
        &first,
        "mixed",
        Some("svn"),
        || Ok(()),
    )
    .unwrap();
    let reopened = read_at(&fixture.source(), &fixture.0).unwrap();
    assert_eq!(saved, reopened);
    let scope = fixture.scope();
    let evidence: Value = serde_json::from_str(include_str!(
        "../../../../../shared/fixtures/vcs/windows-root-mappings-v1.json"
    ))
    .unwrap();
    assert_eq!(evidence["rules"]["maxMappings"], MAX_MAPPINGS);
    assert_eq!(evidence["rules"]["maxSourceBytes"], MAX_BYTES);
    assert_eq!(evidence["mapping"], json!(saved.entries[0]));
    let detection = detect_mapped(&Core, &scope, &packages(), &reopened.entries).unwrap();
    assert!(detection.ambiguous.is_empty());
    assert!(detection
        .roots
        .iter()
        .any(|root| root.id == "mixed" && root.vcs == "svn" && root.mapped));
    let snapshot = Snapshot {
        generation: 1,
        workspace_id: scope.workspace_id,
        workspace_root: scope.workspace_root,
        detection,
        mappings: Some(reopened),
        watch_error: None,
        mapping_choices: Vec::new(),
    };
    let paths: Vec<String> = serde_json::from_value(evidence["paths"].clone()).unwrap();
    let ownership = owners(&Core, &snapshot, &paths).unwrap();
    assert_eq!(ownership.owners[0].root.as_deref(), Some("mixed"));
    assert_eq!(ownership.owners[1].root.as_deref(), Some("mixed/nested"));
    assert_eq!(
        json!(ownership
            .owners
            .iter()
            .map(|owner| &owner.root)
            .collect::<Vec<_>>()),
        evidence["owners"]
    );
    assert!(ownership.common_root.is_none());
    assert_eq!(
        detect_mapped(&Core, &fixture.scope(), &[], &saved.entries)
            .unwrap()
            .unused_mappings
            .len(),
        1
    );
}

#[test]
fn saves_preserve_unknown_data_permissions_and_reject_external_edits() {
    let fixture = Fixture::new();
    std::fs::create_dir_all(fixture.source().parent().unwrap()).unwrap();
    let identity = directory_identity(&fixture.0.join("mixed")).unwrap();
    std::fs::write(fixture.source(), json!({"version":1,"future":{"keep":true},"mappings":[{"id":"mixed","vcs":"git","directoryIdentity":identity,"future":"preserve"}]}).to_string()).unwrap();
    let old = read_at(&fixture.source(), &fixture.0).unwrap();
    let permissions = std::fs::metadata(fixture.source()).unwrap().permissions();
    let saved = save_at(
        &fixture.source(),
        &fixture.0,
        &old,
        "mixed",
        Some("svn"),
        || Ok(()),
    )
    .unwrap();
    let bytes = std::fs::read(fixture.source()).unwrap();
    let value: Value = serde_json::from_slice(&bytes).unwrap();
    assert_eq!(value["future"]["keep"], true);
    assert_eq!(value["mappings"][0]["future"], "preserve");
    assert_eq!(
        std::fs::metadata(fixture.source())
            .unwrap()
            .permissions()
            .readonly(),
        permissions.readonly()
    );
    std::fs::write(fixture.source(), b"{\"version\":1,\"external\":true}").unwrap();
    assert_eq!(
        save_at(&fixture.source(), &fixture.0, &saved, "mixed", None, || Ok(
            ()
        ))
        .unwrap_err(),
        "vcs.mapping.conflict"
    );
    assert_eq!(
        std::fs::read(fixture.source()).unwrap(),
        b"{\"version\":1,\"external\":true}"
    );
}

#[test]
fn a_replaced_directory_never_inherits_a_saved_choice_and_stale_commit_cleans_its_temp() {
    let fixture = Fixture::new();
    let first = read_at(&fixture.source(), &fixture.0).unwrap();
    let saved = save_at(
        &fixture.source(),
        &fixture.0,
        &first,
        "mixed",
        Some("svn"),
        || Ok(()),
    )
    .unwrap();
    std::fs::rename(fixture.0.join("mixed"), fixture.0.join("previous")).unwrap();
    std::fs::create_dir(fixture.0.join("mixed")).unwrap();
    assert!(read_at(&fixture.source(), &fixture.0)
        .unwrap()
        .entries
        .is_empty());
    assert_eq!(
        save_at(
            &fixture.source(),
            &fixture.0,
            &saved,
            "mixed",
            Some("git"),
            || Ok(())
        )
        .unwrap_err(),
        "vcs.mapping.conflict"
    );
    let current = read_at(&fixture.source(), &fixture.0).unwrap();
    let before = std::fs::read(fixture.source()).unwrap();
    assert_eq!(
        save_at(
            &fixture.source(),
            &fixture.0,
            &current,
            "mixed",
            Some("git"),
            || Err(registry::STALE.into())
        )
        .unwrap_err(),
        registry::STALE
    );
    assert_eq!(std::fs::read(fixture.source()).unwrap(), before);
    assert_eq!(
        std::fs::read_dir(fixture.source().parent().unwrap())
            .unwrap()
            .count(),
        1
    );
}

#[test]
fn mappings_follow_enclosing_core_ids_and_reject_path_aliases_and_oversized_sources() {
    let fixture = Fixture::new();
    std::fs::create_dir_all(fixture.0.join(".git")).unwrap();
    std::fs::create_dir_all(fixture.0.join(".svn")).unwrap();
    let workspace = fixture.0.join("project");
    let initial = read_at(&fixture.source(), &workspace).unwrap();
    let saved = save_at(
        &fixture.source(),
        &workspace,
        &initial,
        "..",
        Some("svn"),
        || Ok(()),
    )
    .unwrap();
    let mut scope = fixture.scope();
    scope.workspace_root = workspace.to_string_lossy().into_owned();
    let roots = detect_mapped(&Core, &scope, &packages(), &saved.entries).unwrap();
    assert!(roots
        .roots
        .iter()
        .any(|root| root.id == ".." && root.vcs == "svn" && root.mapped));
    for invalid in [
        "../mixed",
        "a/../mixed",
        "/mixed",
        "a//b",
        ".",
        "a\\b",
        "C:alias",
    ] {
        assert!(root_path(&workspace, invalid).is_err(), "{invalid}");
    }
    std::fs::write(fixture.source(), vec![b' '; MAX_BYTES as usize + 1]).unwrap();
    assert!(read_at(&fixture.source(), &workspace).is_err());
}

#[test]
fn unchanged_missing_choice_does_not_create_storage_and_readonly_never_replaces_bytes() {
    let fixture = Fixture::new();
    let initial = read_at(&fixture.source(), &fixture.0).unwrap();
    save_at(
        &fixture.source(),
        &fixture.0,
        &initial,
        "mixed",
        None,
        || Ok(()),
    )
    .unwrap();
    assert!(!fixture.source().exists());
    let saved = save_at(
        &fixture.source(),
        &fixture.0,
        &initial,
        "mixed",
        Some("svn"),
        || Ok(()),
    )
    .unwrap();
    let before = std::fs::read(fixture.source()).unwrap();
    let mut permissions = std::fs::metadata(fixture.source()).unwrap().permissions();
    let original = permissions.clone();
    permissions.set_readonly(true);
    std::fs::set_permissions(fixture.source(), permissions).unwrap();
    // Restore before asserting so an assertion failure never strands a Windows
    // read-only temporary file that the fixture cannot remove.
    let result = save_at(
        &fixture.source(),
        &fixture.0,
        &saved,
        "mixed",
        Some("git"),
        || Ok(()),
    );
    std::fs::set_permissions(fixture.source(), original).unwrap();
    assert_eq!(result.unwrap_err(), "vcs.mapping.readOnly");
    assert_eq!(std::fs::read(fixture.source()).unwrap(), before);
}

#[test]
fn future_rows_with_the_same_id_are_never_modified_or_committed_as_duplicate_choices() {
    let fixture = Fixture::new();
    std::fs::create_dir_all(fixture.source().parent().unwrap()).unwrap();
    let future = json!({"version":1,"mappings":[{"id":"mixed","futureFormat":{"keep":true}}]});
    std::fs::write(fixture.source(), future.to_string()).unwrap();
    let snapshot = read_at(&fixture.source(), &fixture.0).unwrap();
    let before = std::fs::read(fixture.source()).unwrap();
    assert_eq!(
        save_at(
            &fixture.source(),
            &fixture.0,
            &snapshot,
            "mixed",
            Some("svn"),
            || Ok(())
        )
        .unwrap_err(),
        "vcs.mapping.readOnly"
    );
    save_at(
        &fixture.source(),
        &fixture.0,
        &snapshot,
        "mixed",
        None,
        || Ok(()),
    )
    .unwrap();
    assert_eq!(std::fs::read(fixture.source()).unwrap(), before);
    let identity = directory_identity(&fixture.0.join("mixed")).unwrap();
    let duplicate = json!({"version":1,"mappings":[future["mappings"][0],{"id":"mixed","vcs":"svn","directoryIdentity":identity}]});
    std::fs::write(fixture.source(), duplicate.to_string()).unwrap();
    assert!(read_at(&fixture.source(), &fixture.0).is_err());
    assert_eq!(
        serde_json::from_slice::<Value>(&std::fs::read(fixture.source()).unwrap()).unwrap(),
        duplicate
    );
}

#[test]
fn a_choice_whose_marker_disappeared_can_be_explicitly_cleared() {
    let fixture = Fixture::new();
    let initial = read_at(&fixture.source(), &fixture.0).unwrap();
    let saved = save_at(
        &fixture.source(),
        &fixture.0,
        &initial,
        "mixed",
        Some("svn"),
        || Ok(()),
    )
    .unwrap();
    std::fs::remove_dir(fixture.0.join("mixed/.svn")).unwrap();
    assert_eq!(
        detect_mapped(&Core, &fixture.scope(), &packages(), &saved.entries)
            .unwrap()
            .unused_mappings
            .len(),
        1
    );
    let cleared = save_at(&fixture.source(), &fixture.0, &saved, "mixed", None, || {
        Ok(())
    })
    .unwrap();
    assert!(cleared.entries.is_empty());
    assert!(
        detect_mapped(&Core, &fixture.scope(), &packages(), &cleared.entries)
            .unwrap()
            .unused_mappings
            .is_empty()
    );
}

#[test]
fn an_external_edit_during_final_scope_validation_is_not_overwritten() {
    let fixture = Fixture::new();
    let initial = read_at(&fixture.source(), &fixture.0).unwrap();
    let saved = save_at(
        &fixture.source(),
        &fixture.0,
        &initial,
        "mixed",
        Some("svn"),
        || Ok(()),
    )
    .unwrap();
    let external = b"{\"version\":1,\"external\":true}";
    let result = save_at(
        &fixture.source(),
        &fixture.0,
        &saved,
        "mixed",
        Some("git"),
        || {
            std::fs::write(fixture.source(), external).unwrap();
            Ok(())
        },
    );
    assert_eq!(result.unwrap_err(), "vcs.mapping.conflict");
    assert_eq!(std::fs::read(fixture.source()).unwrap(), external);
    assert_eq!(
        std::fs::read_dir(fixture.source().parent().unwrap())
            .unwrap()
            .count(),
        1
    );
}

#[test]
fn storage_preflight_rejection_creates_no_directories_or_temporary_files() {
    let fixture = Fixture::new();
    let result = super::super::super::settings::write_object_snapshot(
        &fixture.source(),
        &Map::new(),
        &None,
        MAX_BYTES,
        || Err("vcs.mapping.readOnly".into()),
        || panic!("final validation cannot run after rejected storage preflight"),
    );
    assert_eq!(result.unwrap_err(), "vcs.mapping.readOnly");
    assert!(!fixture.source().parent().unwrap().exists());
}
