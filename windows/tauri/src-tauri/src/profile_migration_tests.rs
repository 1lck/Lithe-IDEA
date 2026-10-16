use super::*;
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT_FIXTURE: AtomicU64 = AtomicU64::new(0);

struct Fixture {
    root: PathBuf,
    stable_local: PathBuf,
    local: PathBuf,
    stable_data: PathBuf,
    data: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!(
            "lithe-profile-import-{}-{}",
            std::process::id(), NEXT_FIXTURE.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&root).expect("create exclusive test root");
        Self {
            stable_local: root.join("local/stable"), local: root.join("local/dev"),
            stable_data: root.join("roaming/stable"), data: root.join("roaming/dev"), root,
        }
    }

    fn write(&self, relative: &str, bytes: &[u8]) {
        let path = self.root.join(relative);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, bytes).unwrap();
    }

    fn prepare(&self) -> io::Result<bool> {
        prepare_paths(&self.stable_local, &self.local, &self.stable_data, &self.data)
    }

    fn prepare_with_unavailable_stable(&self) -> io::Result<bool> {
        // An embedded NUL makes any source metadata access fail on every OS,
        // without relying on ACLs, symlink privileges or external processes.
        let unavailable = self.root.join("unavailable\0stable");
        prepare_paths(&unavailable, &self.local, &unavailable, &self.data)
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        fs::remove_dir_all(&self.root).expect("remove owned test fixture");
    }
}

#[test]
fn first_launch_copies_durable_state_without_sharing_files_or_runtime_caches() {
    let fixture = Fixture::new();
    fixture.write("roaming/stable/settings.json", br#"{"theme":"dark"}"#);
    fixture.write("roaming/stable/maven/reactor.json", br#"{"javaHome":"fixture"}"#);
    fixture.write("roaming/stable/maven/runtime.lock", b"not durable preferences");
    fixture.write("roaming/stable/lithe-log-settings.json", br#"{"root":"shared"}"#);
    let storage = format!("local/stable/{LOCAL_STORAGE}");
    fixture.write(&format!("{storage}/LOCK"), b"");
    fixture.write(&format!("{storage}/CURRENT"), b"MANIFEST-000001\n");
    fixture.write(&format!("{storage}/MANIFEST-000001"), b"manifest");
    fixture.write(&format!("{storage}/000001.log"), b"workspace-write-ahead-log");
    fixture.write(&format!("{storage}/LOG"), b"diagnostics");
    fixture.write("local/stable/EBWebView/Default/Cache/cache", b"do not import");

    assert!(fixture.prepare().unwrap());
    assert_eq!(fs::read(fixture.data.join("settings.json")).unwrap(), br#"{"theme":"dark"}"#);
    assert_eq!(fs::read(fixture.local.join(LOCAL_STORAGE).join("000001.log")).unwrap(), b"workspace-write-ahead-log");
    assert!(!fixture.local.join(LOCAL_STORAGE).join("LOCK").exists());
    assert!(!fixture.local.join(LOCAL_STORAGE).join("LOG").exists());
    assert!(!fixture.local.join("EBWebView/Default/Cache").exists());
    assert!(!fixture.data.join("maven/runtime.lock").exists());
    assert!(!fixture.data.join("lithe-log-settings.json").exists());
    fs::write(fixture.data.join("settings.json"), br#"{"theme":"dev"}"#).unwrap();
    fs::write(fixture.local.join(LOCAL_STORAGE).join("000001.log"), b"dev-workspace").unwrap();
    assert!(fixture.prepare().unwrap());
    assert_eq!(fs::read(fixture.data.join("settings.json")).unwrap(), br#"{"theme":"dev"}"#);
    assert_eq!(fs::read(fixture.stable_data.join("settings.json")).unwrap(), br#"{"theme":"dark"}"#);
    assert_eq!(fs::read(fixture.stable_local.join(LOCAL_STORAGE).join("000001.log")).unwrap(), b"workspace-write-ahead-log");
}

#[test]
fn existing_development_state_is_preserved_without_merging_stable_settings() {
    let fixture = Fixture::new();
    fixture.write("roaming/stable/settings.json", br#"{"theme":"stable"}"#);
    fixture.write("roaming/dev/settings.json", br#"{"theme":"dev"}"#);
    assert!(!fixture.prepare().unwrap());
    assert_eq!(fs::read(fixture.data.join("settings.json")).unwrap(), br#"{"theme":"dev"}"#);
    assert_eq!(fs::read_to_string(fixture.local.join(MARKER)).unwrap(), "existing");
}

#[test]
fn completed_profiles_do_not_access_unavailable_stable_roots() {
    for outcome in ["imported", "existing", "fresh"] {
        let fixture = Fixture::new();
        fixture.write(&format!("local/dev/{MARKER}"), outcome.as_bytes());
        fixture.write("roaming/dev/settings.json", br#"{"theme":"dev"}"#);

        assert_eq!(fixture.prepare_with_unavailable_stable().unwrap(), outcome == "imported");
        assert_eq!(fs::read_to_string(fixture.local.join(MARKER)).unwrap(), outcome);
        assert_eq!(fs::read(fixture.data.join("settings.json")).unwrap(), br#"{"theme":"dev"}"#);
    }
}

#[test]
fn existing_development_state_does_not_require_access_to_stable() {
    let fixture = Fixture::new();
    fixture.write("roaming/dev/settings.json", br#"{"theme":"dev"}"#);

    assert!(!fixture.prepare_with_unavailable_stable().unwrap());
    assert_eq!(fs::read_to_string(fixture.local.join(MARKER)).unwrap(), "existing");
    assert_eq!(fs::read(fixture.data.join("settings.json")).unwrap(), br#"{"theme":"dev"}"#);
}

#[test]
fn frozen_snapshot_recovers_without_accessing_stable_roots() {
    let fixture = Fixture::new();
    fixture.write(&format!("local/dev/{MARKER}"), b"pending");
    fixture.write(&format!("local/dev/{STAGING}/data/settings.json"), br#"{"theme":"snapshot"}"#);
    fixture.write(&format!("local/dev/{STAGING}/ready"), b"imported");
    fixture.write("roaming/dev/settings.json", b"partially-installed-file");

    assert!(fixture.prepare_with_unavailable_stable().unwrap());
    assert_eq!(fs::read(fixture.data.join("settings.json")).unwrap(), br#"{"theme":"snapshot"}"#);
    assert_eq!(fs::read_to_string(fixture.local.join(MARKER)).unwrap(), "imported");
    assert!(!fixture.local.join(STAGING).exists());
}

#[test]
fn new_snapshot_still_rejects_unavailable_stable_roots() {
    let fixture = Fixture::new();

    assert!(fixture.prepare_with_unavailable_stable().is_err());
    assert_eq!(fs::read_to_string(fixture.local.join(MARKER)).unwrap(), "pending");
    assert!(!fixture.data.exists());
    assert!(!fixture.local.join(STAGING).exists());
}

#[test]
fn invalid_source_remains_retryable_and_never_marks_migration_successful() {
    let fixture = Fixture::new();
    fixture.write("roaming/stable/settings.json", b"incomplete JSON");
    assert!(fixture.prepare().is_err());
    assert_eq!(fs::read_to_string(fixture.local.join(MARKER)).unwrap(), "pending");
    assert!(!fixture.data.join("settings.json").exists());
    fixture.write("roaming/stable/settings.json", br#"{"theme":"recovered"}"#);
    assert!(fixture.prepare().unwrap());
    assert_eq!(fs::read(fixture.data.join("settings.json")).unwrap(), br#"{"theme":"recovered"}"#);
}

#[test]
fn interrupted_install_uses_the_frozen_snapshot_and_not_newer_stable_changes() {
    let fixture = Fixture::new();
    fixture.write(&format!("local/dev/{MARKER}"), b"pending");
    fixture.write(&format!("local/dev/{STAGING}/data/settings.json"), br#"{"theme":"snapshot"}"#);
    fixture.write(&format!("local/dev/{STAGING}/ready"), b"imported");
    fixture.write("roaming/stable/settings.json", br#"{"theme":"newer-stable"}"#);
    fixture.write("roaming/dev/settings.json", b"partially-installed-file");
    assert!(fixture.prepare().unwrap());
    assert_eq!(fs::read(fixture.data.join("settings.json")).unwrap(), br#"{"theme":"snapshot"}"#);
}

#[test]
fn fresh_profile_is_marked_once_and_does_not_import_later_stable_state() {
    let fixture = Fixture::new();
    assert!(!fixture.prepare().unwrap());
    assert_eq!(fs::read_to_string(fixture.local.join(MARKER)).unwrap(), "fresh");
    fixture.write("roaming/stable/settings.json", br#"{"theme":"later"}"#);
    assert!(!fixture.prepare().unwrap());
    assert!(!fixture.data.join("settings.json").exists());
}

#[cfg(target_os = "windows")]
#[test]
fn live_stable_database_is_not_copied_and_can_be_retried_after_close() {
    use std::os::windows::fs::OpenOptionsExt;
    let fixture = Fixture::new();
    fixture.write(&format!("local/stable/{LOCAL_STORAGE}/LOCK"), b"");
    fixture.write(&format!("local/stable/{LOCAL_STORAGE}/CURRENT"), b"workspace");
    let open_database = OpenOptions::new().read(true).share_mode(0)
        .open(fixture.stable_local.join(LOCAL_STORAGE).join("LOCK")).unwrap();
    assert!(fixture.prepare().is_err());
    assert!(!fixture.local.join(LOCAL_STORAGE).exists());
    assert_eq!(fs::read_to_string(fixture.local.join(MARKER)).unwrap(), "pending");
    drop(open_database);
    assert!(fixture.prepare().unwrap());
    assert_eq!(fs::read(fixture.local.join(LOCAL_STORAGE).join("CURRENT")).unwrap(), b"workspace");
}
