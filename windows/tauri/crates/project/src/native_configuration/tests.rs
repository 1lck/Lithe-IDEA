use super::*;
use std::sync::atomic::{AtomicU64, Ordering};
static SEQUENCE: AtomicU64 = AtomicU64::new(0);

struct Fixture {
    root: PathBuf,
    path: PathBuf,
    manifest: Value,
}
impl Fixture {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!(
            "lithe-native-settings-{}-{}",
            std::process::id(),
            SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&root).unwrap();
        let root = root.canonicalize().unwrap();
        Self { path: root.join("user settings.xml"), root,
            manifest: serde_json::from_str(include_str!("../../../../../../shared/contracts/plugins/v1/fixtures/build-provider-configuration.plugin.json")).unwrap() }
    }
    fn snapshot(&self) -> Value {
        let bytes = fs::read(&self.path).ok();
        let revision = bytes
            .map(|bytes| format!("sha256:{:x}", Sha256::digest(&bytes)))
            .unwrap_or("missing".into());
        json!({"format":"litheBuildConfiguration","version":1,"sources":[{
            "id":"user","scope":"user","uri":url::Url::from_file_path(&self.path).unwrap().as_str(),
            "revision":revision,"writable":true,"rootElement":{"name":"settings","namespace":""},
            "fields":[{"id":"localRepository","kind":"directory","value":null,"effectiveValue":"inherited",
                "effectiveSource":"default","path":["localRepository"]}]
        }]})
    }
    fn prepare(
        &self,
        snapshot: &Value,
        value: Value,
        protected: &[PathBuf],
    ) -> Result<Option<PreparedNativeConfiguration>, NativeConfigurationError> {
        prepare(
            &self.manifest,
            "gradle",
            snapshot,
            &json!({"sourceID":"user","revision":snapshot["sources"][0]["revision"],"values":{"localRepository":value}}),
            protected,
        )
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

#[test]
fn edits_preserve_comments_secrets_and_permissions_through_existing_atomic_publication() {
    let f = Fixture::new();
    fs::write(&f.path,"<settings><!--preserved--><servers><server><password>fixture-private-value</password></server></servers></settings>").unwrap();
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&f.path, fs::Permissions::from_mode(0o600)).unwrap();
    }
    let original = fs::read(&f.path).unwrap();
    let prepared = f
        .prepare(&f.snapshot(), json!("selected repository"), &[])
        .unwrap()
        .unwrap();
    assert_eq!(fs::read(&f.path).unwrap(), original, "prepare is read-only");
    prepared.commit(&[]).unwrap();
    let saved = fs::read_to_string(&f.path).unwrap();
    assert!(
        saved.contains("<!--preserved-->")
            && saved.contains("<password>fixture-private-value</password>")
    );
    assert!(saved.contains("<localRepository>selected repository</localRepository>"));
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            fs::metadata(&f.path).unwrap().permissions().mode() & 0o777,
            0o600
        );
    }
    assert!(fs::read_dir(&f.root).unwrap().all(|entry| {
        !entry
            .unwrap()
            .file_name()
            .to_string_lossy()
            .starts_with(".lithe-document-")
    }));
}

#[test]
fn utf8_bom_and_unicode_edits_keep_the_exact_read_revision() {
    let f = Fixture::new();
    fs::write(
        &f.path,
        "\u{feff}<?xml version=\"1.0\" encoding=\"UTF-8\"?><settings><!--保留--></settings>",
    )
    .unwrap();
    let prepared = f
        .prepare(&f.snapshot(), json!("仓库 & spaced value"), &[])
        .unwrap()
        .unwrap();
    prepared.commit(&[]).unwrap();
    let result = fs::read_to_string(&f.path).unwrap();
    assert!(result.starts_with('\u{feff}'));
    assert!(result.contains("<!--保留-->") && result.contains("仓库 &amp; spaced value"));
}

#[cfg(unix)]
#[test]
fn a_file_made_read_only_after_prepare_cannot_be_committed() {
    use std::os::unix::fs::PermissionsExt;
    let f = Fixture::new();
    fs::write(&f.path, "<settings/>").unwrap();
    let prepared = f
        .prepare(&f.snapshot(), json!("repository"), &[])
        .unwrap()
        .unwrap();
    fs::set_permissions(&f.path, fs::Permissions::from_mode(0o400)).unwrap();
    assert_eq!(
        prepared.commit(&[]),
        Err(NativeConfigurationError::Unreadable)
    );
    assert_eq!(fs::read_to_string(&f.path).unwrap(), "<settings/>");
}

#[test]
fn unchanged_inherited_values_never_create_a_file_or_parent() {
    let mut f = Fixture::new();
    f.path = f.root.join("missing/parent/settings.xml");
    assert!(
        f.prepare(&f.snapshot(), Value::Null, &[])
            .unwrap()
            .is_none()
    );
    assert!(!f.root.join("missing").exists());
}

#[test]
fn a_changed_missing_source_is_created_only_during_commit() {
    let mut f = Fixture::new();
    f.path = f.root.join("new parent/settings.xml");
    let prepared = f
        .prepare(&f.snapshot(), json!("repository"), &[])
        .unwrap()
        .unwrap();
    assert!(!f.path.parent().unwrap().exists());
    prepared.commit(&[]).unwrap();
    assert!(
        fs::read_to_string(&f.path)
            .unwrap()
            .contains("<localRepository>repository</localRepository>")
    );
}

#[test]
fn external_edit_between_prepare_and_commit_is_preserved_without_returning_native_text() {
    let f = Fixture::new();
    fs::write(&f.path, "<settings/>").unwrap();
    let prepared = f
        .prepare(&f.snapshot(), json!("repository"), &[])
        .unwrap()
        .unwrap();
    let external = "<settings><servers><server><password>external-private-value</password></server></servers></settings>";
    fs::write(&f.path, external).unwrap();
    assert_eq!(
        prepared.commit(&[]),
        Err(NativeConfigurationError::Conflict)
    );
    assert_eq!(fs::read_to_string(&f.path).unwrap(), external);
}

#[test]
fn a_concurrent_creator_is_never_overwritten() {
    let f = Fixture::new();
    let prepared = f
        .prepare(&f.snapshot(), json!("repository"), &[])
        .unwrap()
        .unwrap();
    fs::write(&f.path, "<settings><!--concurrent creator--></settings>").unwrap();
    assert_eq!(
        prepared.commit(&[]),
        Err(NativeConfigurationError::Conflict)
    );
    assert!(
        fs::read_to_string(&f.path)
            .unwrap()
            .contains("concurrent creator")
    );
}

#[test]
fn installed_and_plugin_roots_are_read_only_even_when_a_source_claims_to_be_writable() {
    let f = Fixture::new();
    fs::write(&f.path, "<settings/>").unwrap();
    assert!(matches!(
        f.prepare(&f.snapshot(), json!("repository"), &[f.root.clone()]),
        Err(NativeConfigurationError::ReadOnly)
    ));
    let prepared = f
        .prepare(&f.snapshot(), json!("repository"), &[])
        .unwrap()
        .unwrap();
    assert_eq!(
        prepared.commit(&[f.root.clone()]),
        Err(NativeConfigurationError::ReadOnly)
    );
    let mut snapshot = f.snapshot();
    snapshot["sources"][0]["scope"] = json!("installation");
    assert!(matches!(
        f.prepare(&snapshot, json!("repository"), &[]),
        Err(NativeConfigurationError::ReadOnly)
    ));
}

#[test]
fn malformed_oversized_or_changed_native_sources_fail_without_rewriting() {
    let f = Fixture::new();
    fs::write(&f.path, "<settings/>").unwrap();
    let snapshot = f.snapshot();
    fs::write(&f.path, "<settings><!--external--></settings>").unwrap();
    assert!(matches!(
        f.prepare(&snapshot, json!("repository"), &[]),
        Err(NativeConfigurationError::Conflict)
    ));
    fs::write(&f.path, [0xff, 0xfe]).unwrap();
    assert!(matches!(
        f.prepare(&f.snapshot(), json!("repository"), &[]),
        Err(NativeConfigurationError::Unreadable)
    ));
    fs::write(&f.path, vec![b'x'; MAX_BYTES as usize + 1]).unwrap();
    assert!(matches!(
        f.prepare(&f.snapshot(), json!("repository"), &[]),
        Err(NativeConfigurationError::Unreadable)
    ));
    let dtd = "<!DOCTYPE settings [<!ENTITY x SYSTEM 'file:///private'>]><settings/>";
    fs::write(&f.path, dtd).unwrap();
    assert!(matches!(
        f.prepare(&f.snapshot(), json!("repository"), &[]),
        Err(NativeConfigurationError::Invalid)
    ));
    assert_eq!(fs::read_to_string(&f.path).unwrap(), dtd);
}

#[cfg(unix)]
#[test]
fn redirected_links_and_distinct_aliases_cannot_change_the_approved_source() {
    use std::os::unix::fs::symlink;
    let f = Fixture::new();
    let first = f.root.join("first.xml");
    let other = f.root.join("other.xml");
    fs::write(&first, "<settings/>").unwrap();
    fs::write(&other, "<settings/>").unwrap();
    symlink(&first, &f.path).unwrap();
    let mut snapshot = f.snapshot();
    let prepared = f
        .prepare(&snapshot, json!("repository"), &[])
        .unwrap()
        .unwrap();
    fs::remove_file(&f.path).unwrap();
    symlink(&other, &f.path).unwrap();
    assert_eq!(
        prepared.commit(&[]),
        Err(NativeConfigurationError::Conflict)
    );
    assert_eq!(fs::read_to_string(&other).unwrap(), "<settings/>");
    let mut alias = snapshot["sources"][0].clone();
    alias["id"] = json!("installation");
    alias["scope"] = json!("installation");
    alias["writable"] = json!(false);
    alias["uri"] = json!(url::Url::from_file_path(&other).unwrap().as_str());
    snapshot["sources"].as_array_mut().unwrap().push(alias);
    assert!(matches!(
        f.prepare(&snapshot, json!("repository"), &[]),
        Err(NativeConfigurationError::ReadOnly)
    ));
}
