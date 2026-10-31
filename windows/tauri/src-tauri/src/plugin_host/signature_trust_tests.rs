//! Origin-specific publisher trust uses the shared fixture and production verifier.

use super::*;
use ed25519_dalek::Signer;
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};

static NEXT_ROOT: AtomicU64 = AtomicU64::new(0);

struct TestPackage {
    root: PathBuf,
    package: PathBuf,
    manifest: Value,
}

impl TestPackage {
    fn new() -> Self {
        let root = std::env::temp_dir().join(format!(
            "lithe-publisher-bundled-{}-{}",
            std::process::id(),
            NEXT_ROOT.fetch_add(1, Ordering::Relaxed)
        ));
        let package = root.join("OfficialPlugins/JavaSupport");
        std::fs::create_dir_all(&package).expect("package directory");
        let mut manifest: Value = serde_json::from_str(include_str!(
            "../../../../../shared/contracts/plugins/v1/fixtures/publisher-bundled.plugin.json"
        ))
        .expect("shared publisher-bundled fixture");
        // Keep the fixture's complete requires and origin policy. Only the ID
        // selects the real catalog pin; no fixture ID becomes production trust.
        manifest["id"] = json!("dev.lithe.plugin.java-support");
        std::fs::write(package.join("plugin.json"), manifest.to_string()).expect("manifest");
        std::fs::write(package.join("server.jar"), b"fixture server").expect("server");
        Self {
            root,
            package,
            manifest,
        }
    }

    fn verify(&self, origin: InstallOrigin) -> Result<(), TrustError> {
        verify_for_install(
            &self.package,
            "dev.lithe.plugin.java-support",
            "1.0.0",
            &self.manifest,
            origin,
            Some(&self.root.join("OfficialPlugins")),
            &self.keys(),
        )
    }

    fn keys(&self) -> BTreeMap<String, VerifyingKey> {
        BTreeMap::from([(
            "lithe-test-v1".to_string(),
            rfc8032_signing_key_for_tests().verifying_key(),
        )])
    }

    fn sign(&self) {
        let files = file_digests(&self.package).expect("file digests");
        let signature = rfc8032_signing_key_for_tests().sign(&canonical_payload(
            "lithe-test-v1",
            "dev.lithe.plugin.java-support",
            "1.0.0",
            &files,
        ));
        let document = SignatureDocument {
            schema_version: SCHEMA_VERSION,
            algorithm: ALGORITHM.to_string(),
            key_id: "lithe-test-v1".to_string(),
            plugin_id: "dev.lithe.plugin.java-support".to_string(),
            plugin_version: "1.0.0".to_string(),
            files,
            signature: STANDARD_BASE64.encode(signature.to_bytes()),
        };
        std::fs::write(
            self.package.join(SIGNATURE_FILE_NAME),
            serde_json::to_vec(&document).expect("signature JSON"),
        )
        .expect("signature file");
    }
}

impl Drop for TestPackage {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.root);
    }
}

#[test]
fn publisher_bundled_fixture_keeps_complete_requires_and_production_gate() {
    let fixture: Value = serde_json::from_str(include_str!(
        "../../../../../shared/contracts/plugins/v1/fixtures/publisher-bundled.plugin.json"
    ))
    .expect("fixture");
    let rejection = crate::plugin_host::scan::validate_manifest_with(
        &fixture,
        Some(crate::plugin_host::host_capabilities()),
    )
    .expect_err("production packageTrust gate stays closed");
    assert_eq!(rejection.code, "plugin.api.unsupported");
    assert_eq!(rejection.path.as_deref(), Some("requires.packageTrust"));
    crate::plugin_host::with_package_trust_for_tests(|| {
        assert!(crate::plugin_host::scan::validate_manifest_with(
            &fixture,
            Some(crate::plugin_host::host_capabilities()),
        )
        .is_ok());
    });
    assert!(crate::plugin_host::host_capabilities()
        .get("packageTrust")
        .is_none());
}

#[test]
fn publisher_bundled_valid_signature_works_for_each_real_origin() {
    let package = TestPackage::new();
    package.sign();
    for origin in [
        InstallOrigin::Bundled,
        InstallOrigin::Marketplace,
        InstallOrigin::Community,
    ] {
        assert_eq!(package.verify(origin), Ok(()), "{origin:?}");
    }
}

#[test]
fn publisher_bundled_unsigned_copy_never_acquires_trust_from_a_directory() {
    let package = TestPackage::new();
    assert_eq!(
        package.verify(InstallOrigin::Community),
        Err(TrustError::SignatureMissing)
    );
    assert_eq!(
        package.verify(InstallOrigin::Marketplace),
        Err(TrustError::SignatureMissing)
    );
    // Even the real discovery root and bundled origin cannot prove a Windows
    // distribution seal. A trusted signed installer/inventory is still pending.
    assert_eq!(
        package.verify(InstallOrigin::Bundled),
        Err(TrustError::HostSealRequired)
    );
    let escaped = package.root.join("OfficialPlugins/../outside");
    std::fs::create_dir_all(&escaped).expect("outside directory");
    assert_eq!(
        verify_for_install(
            &escaped,
            "dev.lithe.plugin.java-support",
            "1.0.0",
            &package.manifest,
            InstallOrigin::Bundled,
            Some(&package.root.join("OfficialPlugins")),
            &package.keys(),
        ),
        Err(TrustError::HostSealRequired)
    );
}

#[test]
fn publisher_bundled_present_bad_signature_is_never_ignored() {
    let package = TestPackage::new();
    package.sign();
    std::fs::write(package.package.join("server.jar"), b"changed after signing").expect("tamper");
    for origin in [
        InstallOrigin::Bundled,
        InstallOrigin::Marketplace,
        InstallOrigin::Community,
    ] {
        assert!(
            matches!(package.verify(origin), Err(TrustError::SignatureInvalid(_))),
            "{origin:?}"
        );
    }
}

#[test]
fn publisher_bundled_catalog_policy_cannot_be_downgraded() {
    let mut package = TestPackage::new();
    package.manifest["vendor"]["signatureRequirement"] = json!("none");
    assert_eq!(
        package.verify(InstallOrigin::Community),
        Err(TrustError::InvalidPolicy)
    );
    package.manifest["vendor"]["signatureRequirement"] = json!("publisherPackage");
    package.manifest["vendor"]
        .as_object_mut()
        .expect("vendor")
        .remove("bundledSignatureRequirement");
    assert_eq!(
        package.verify(InstallOrigin::Community),
        Err(TrustError::InvalidPolicy)
    );
}
