use super::*;
use std::sync::atomic::{AtomicU64, Ordering};

struct TempRoot(PathBuf);
impl TempRoot {
    fn new() -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let path = std::env::temp_dir().join(format!(
            "lithe-settings-snapshot-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir(&path).expect("isolated settings root");
        Self(path)
    }
    fn file(&self) -> PathBuf {
        self.0.join("settings.json")
    }
}
impl Drop for TempRoot {
    fn drop(&mut self) {
        std::fs::remove_dir_all(&self.0).expect("remove isolated settings root");
    }
}

#[test]
fn missing_snapshot_is_read_only_and_empty_override_round_trips() {
    let root = TempRoot::new();
    let path = root.file();
    let before = read_store(&path).expect("missing is inherited");
    assert!(before.values.is_empty());
    assert!(before.identity.is_none());
    assert!(!path.exists(), "opening settings must not create defaults");
    let values = json!({"text": "", "checks": []})
        .as_object()
        .unwrap()
        .clone();
    write_guarded(&path, &values, &before).expect("explicit empty overrides");
    let after = read_store(&path).expect("read back actual bytes");
    assert_eq!(after.values, values);
    assert!(after.identity.is_some());
    assert_eq!(
        std::fs::read_dir(&root.0).unwrap().count(),
        1,
        "no temporary files"
    );
}

#[test]
fn external_edits_including_formatting_reject_the_old_snapshot() {
    let root = TempRoot::new();
    let path = root.file();
    std::fs::write(&path, r#"{"other": 2}"#).unwrap();
    let before = read_store(&path).unwrap();
    std::fs::write(&path, "{\n  \"other\": 2\n}\n").unwrap();
    let external = std::fs::read(&path).unwrap();
    assert_eq!(
        write_guarded(&path, &Map::new(), &before).unwrap_err(),
        "plugin.settings.conflict"
    );
    assert_eq!(std::fs::read(&path).unwrap(), external);
    assert_eq!(std::fs::read_dir(&root.0).unwrap().count(), 1);
}

#[test]
fn guarded_write_preserves_unrelated_values_and_corrupt_sources() {
    let root = TempRoot::new();
    let path = root.file();
    std::fs::write(
        &path,
        r#"{"other.plugin":{"opaque":"unchanged"},"example.plugin":{"option":1}}"#,
    )
    .unwrap();
    let before = read_store(&path).unwrap();
    let mut values = before.values.clone();
    values.remove("example.plugin");
    write_guarded(&path, &values, &before).unwrap();
    assert_eq!(
        read_store(&path).unwrap().values["other.plugin"],
        json!({"opaque":"unchanged"})
    );
    std::fs::write(&path, "not JSON").unwrap();
    assert!(read_store(&path).is_err());
    assert!(write_guarded(&path, &Map::new(), &before).is_err());
    assert_eq!(std::fs::read_to_string(&path).unwrap(), "not JSON");
}

#[test]
fn core_validation_rejects_unknown_scope_and_invalid_values() {
    let manifest: Value = serde_json::from_str(include_str!(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../shared/contracts/plugins/v1/fixtures/settings-v2.plugin.json"
    )))
    .unwrap();
    let settings = manifest["settings"].as_array().unwrap();
    assert_eq!(
        validate_change(
            &manifest,
            settings,
            "unknown",
            "global",
            "",
            Some(&json!(true))
        )
        .unwrap_err(),
        "plugin.settings.unknownSetting"
    );
    assert_eq!(
        validate_change(
            &manifest,
            settings,
            "checks",
            "project",
            "workspace",
            Some(&json!([]))
        )
        .unwrap_err(),
        "plugin.settings.invalidScope"
    );
    assert_eq!(
        validate_change(
            &manifest,
            settings,
            "dialyzer",
            "project",
            "",
            Some(&json!(true))
        )
        .unwrap_err(),
        "plugin.settings.invalidScope"
    );
    assert_eq!(
        validate_change(
            &manifest,
            settings,
            "mixEnv",
            "global",
            "",
            Some(&json!("--unsafe"))
        )
        .unwrap_err(),
        "plugin.settings.invalidValue"
    );
    validate_change(
        &manifest,
        settings,
        "dialyzer",
        "project",
        "workspace",
        Some(&json!(false)),
    )
    .unwrap();
    validate_change(
        &manifest,
        settings,
        "checks",
        "global",
        "",
        Some(&json!([])),
    )
    .unwrap();
    validate_change(&manifest, settings, "mixEnv", "global", "", None).unwrap();
}

#[test]
fn read_only_source_remains_readable_but_cannot_be_replaced() {
    struct RestorePermissions(PathBuf, std::fs::Permissions);
    impl Drop for RestorePermissions {
        fn drop(&mut self) {
            std::fs::set_permissions(&self.0, self.1.clone()).expect("restore test permissions");
        }
    }
    let root = TempRoot::new();
    let path = root.file();
    std::fs::write(&path, r#"{"option":"inherited"}"#).unwrap();
    let original = std::fs::metadata(&path).unwrap().permissions();
    let _restore = RestorePermissions(path.clone(), original.clone());
    let mut read_only = original;
    read_only.set_readonly(true);
    std::fs::set_permissions(&path, read_only).unwrap();
    let before = read_store(&path).expect("read-only values are still discoverable");
    assert_eq!(before.values["option"], "inherited");
    assert_eq!(
        write_guarded(&path, &Map::new(), &before).unwrap_err(),
        "plugin.settings.readOnlySource"
    );
    assert_eq!(read_store(&path).unwrap().identity, before.identity);
}

#[test]
fn pending_recovery_cannot_be_mistaken_for_missing_defaults() {
    let root = TempRoot::new();
    let path = root.file();
    std::fs::write(
        root.0.join("settings.json.123-0.backup"),
        r#"{"option":"original"}"#,
    )
    .unwrap();
    assert_eq!(
        read_store(&path).err().unwrap(),
        "plugin.settings.recoveryRequired"
    );
    assert!(!path.exists());
}
