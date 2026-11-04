use super::*;
use serde_json::{Value, json};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

static SEQUENCE: AtomicU64 = AtomicU64::new(0);

struct Fixture {
    root: PathBuf,
    value: Value,
}
impl Fixture {
    fn new() -> Self {
        let value: Value = serde_json::from_str(include_str!(
            "../../../../../../shared/fixtures/plugins/publisher-signature.json"
        ))
        .unwrap();
        let root = std::env::temp_dir().join(format!(
            "lithe-publisher-{}-{}",
            std::process::id(),
            SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir(&root).unwrap();
        for (path, contents) in value["contents"].as_object().unwrap() {
            let path = root.join(path);
            fs::create_dir_all(path.parent().unwrap()).unwrap();
            fs::write(path, contents.as_str().unwrap().as_bytes()).unwrap();
        }
        fs::write(root.join(SIGNATURE_FILE), value["document"].to_string()).unwrap();
        Self { root, value }
    }
    fn verify(&self) -> Result<VerifiedPublisher, SignatureError> {
        let key = STANDARD
            .decode(self.value["publicKey"].as_str().unwrap())
            .unwrap();
        verify_with_key(
            &self.root,
            "dev.example.signed",
            "1.2.3",
            "fixture-rfc8032",
            &key,
        )
    }
    fn write(&self, document: &Value) {
        fs::write(self.root.join(SIGNATURE_FILE), document.to_string()).unwrap();
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

#[test]
fn shared_cross_language_signature_authenticates_every_byte_and_preserves_the_tree() {
    let fixture = Fixture::new();
    let original = fs::read(fixture.root.join(SIGNATURE_FILE)).unwrap();
    let parsed: Document = serde_json::from_value(fixture.value["document"].clone()).unwrap();
    assert_eq!(payload(&parsed), fixture.value["payload"].as_str().unwrap());
    let receipt = fixture.verify().unwrap();
    assert_eq!(receipt.key_id, "fixture-rfc8032");
    assert_eq!(receipt.content_digest.len(), 64);
    assert_eq!(fixture.verify().unwrap(), receipt);
    assert_eq!(
        fs::read(fixture.root.join(SIGNATURE_FILE)).unwrap(),
        original
    );
    assert_eq!(fs::read_dir(&fixture.root).unwrap().count(), 4);
}

#[test]
fn a_valid_test_signature_never_grants_production_publisher_origin() {
    let fixture = Fixture::new();
    assert_eq!(
        verify(&fixture.root, "dev.example.signed", "1.2.3"),
        Err(SignatureError::UntrustedKey)
    );
    assert_eq!(fixture.value["trustedPublisherKeys"][KEY_ID], PUBLIC_KEY);
}

#[test]
fn changed_added_and_removed_files_revoke_the_previous_signature() {
    for change in ["changed", "added", "removed"] {
        let fixture = Fixture::new();
        match change {
            "changed" => fs::write(fixture.root.join("bin/runner.cmd"), "changed").unwrap(),
            "added" => fs::write(fixture.root.join("unexpected"), "extra").unwrap(),
            _ => fs::remove_file(fixture.root.join("bin/runner.cmd")).unwrap(),
        }
        assert_eq!(fixture.verify(), Err(SignatureError::Changed), "{change}");
    }
}

#[test]
fn identity_key_algorithm_and_signature_must_all_match() {
    let fixture = Fixture::new();
    for (field, replacement, expected) in [
        ("schemaVersion", json!(2), SignatureError::InvalidDocument),
        (
            "algorithm",
            json!("sha256"),
            SignatureError::InvalidDocument,
        ),
        (
            "pluginID",
            json!("dev.example.other"),
            SignatureError::InvalidDocument,
        ),
        (
            "pluginVersion",
            json!("2.0.0"),
            SignatureError::InvalidDocument,
        ),
        (
            "keyID",
            json!("another-publisher"),
            SignatureError::UntrustedKey,
        ),
        ("keyID", json!("bad\nkey"), SignatureError::InvalidDocument),
        (
            "signature",
            json!("invalid base64"),
            SignatureError::InvalidDocument,
        ),
        (
            "signature",
            json!(STANDARD.encode([0u8; 64])),
            SignatureError::InvalidSignature,
        ),
    ] {
        let mut document = fixture.value["document"].clone();
        document[field] = replacement;
        fixture.write(&document);
        assert_eq!(fixture.verify(), Err(expected), "{field}");
    }
}

#[test]
fn unsafe_paths_duplicate_keys_and_extra_document_fields_are_rejected() {
    let fixture = Fixture::new();
    for path in [
        "../outside",
        "/absolute",
        "a\\b",
        "C:/x",
        "bad\npath",
        SIGNATURE_FILE,
    ] {
        let mut document = fixture.value["document"].clone();
        document["files"][path] = json!("a".repeat(64));
        fixture.write(&document);
        assert_eq!(fixture.verify(), Err(SignatureError::InvalidDocument));
    }
    let mut document = fixture.value["document"].clone();
    document["files"]["lib/é.txt"] = json!("a".repeat(64));
    fixture.write(&document);
    assert_eq!(fixture.verify(), Err(SignatureError::InvalidDocument), "Canonically equivalent paths cannot hide a second file");
    let mut document = fixture.value["document"].clone();
    document["trustedKey"] = json!(fixture.value["publicKey"]);
    fixture.write(&document);
    assert_eq!(fixture.verify(), Err(SignatureError::InvalidDocument));
    let duplicate = fixture.value["document"].to_string().replacen(
        "\"files\":{",
        "\"files\":{\"plugin.json\":\"invalid\",",
        1,
    );
    fs::write(fixture.root.join(SIGNATURE_FILE), duplicate).unwrap();
    assert_eq!(fixture.verify(), Err(SignatureError::InvalidDocument));
}

#[test]
fn package_and_signature_budgets_fail_before_large_content_is_read() {
    let fixture = Fixture::new();
    let file = File::options()
        .write(true)
        .open(fixture.root.join("bin/runner.cmd"))
        .unwrap();
    file.set_len(MAX_FILE + 1).unwrap();
    assert_eq!(fixture.verify(), Err(SignatureError::Limit));
    let file = File::options()
        .write(true)
        .open(fixture.root.join(SIGNATURE_FILE))
        .unwrap();
    file.set_len(MAX_DOCUMENT + 1).unwrap();
    assert_eq!(fixture.verify(), Err(SignatureError::Limit));
    let budget = Budget {
        deadline: Instant::now(),
        bytes: 0,
    };
    assert!(matches!(
        inventory(&fixture.root, &budget),
        Err(SignatureError::Limit)
    ));
}

#[cfg(unix)]
#[test]
fn symbolic_links_never_become_signed_files_or_signature_documents() {
    for signature in [false, true] {
        let fixture = Fixture::new();
        let destination = if signature {
            SIGNATURE_FILE
        } else {
            "bin/runner.cmd"
        };
        fs::remove_file(fixture.root.join(destination)).unwrap();
        std::os::unix::fs::symlink(
            fixture.root.join("plugin.json"),
            fixture.root.join(destination),
        )
        .unwrap();
        assert_eq!(fixture.verify(), Err(SignatureError::UnsafeFile));
    }
}
