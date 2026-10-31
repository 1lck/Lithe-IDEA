//! Regression coverage for the package-backed plugin detail model.

use super::details::{self, PluginDetailsError};
use super::scan;
use super::signature;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};

const FIXTURE: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../../shared/contracts/plugins/v1/fixtures/language-packaged-server.plugin.json"
);

struct TestDirectory(PathBuf);

impl TestDirectory {
    fn new(label: &str) -> Self {
        static NEXT: AtomicU64 = AtomicU64::new(1);
        let path = std::env::temp_dir().join(format!(
            "lithe-plugin-details-{label}-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        std::fs::create_dir_all(&path).expect("test directory");
        Self(path)
    }
}

impl Drop for TestDirectory {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn fixture() -> Value {
    serde_json::from_str(&std::fs::read_to_string(FIXTURE).expect("fixture is readable"))
        .expect("fixture is JSON")
}

fn community_manifest() -> Value {
    let mut manifest = fixture();
    manifest["id"] = json!("io.example.details-fixture");
    manifest["displayName"] = json!("Detail Fixture");
    manifest["vendor"]["signatureRequirement"] = json!("none");
    manifest
}

fn review_programs(manifest: &Value) -> Vec<String> {
    let outcome = scan::core_execute(
        "plugins.marketplace.installReview",
        json!({
            "manifest": manifest,
            "hostCapabilities": super::host_capabilities(),
        }),
    )
    .expect("Core install review");
    assert_eq!(outcome["status"], json!("ok"), "review outcome: {outcome}");
    outcome["review"]["programs"]
        .as_array()
        .expect("programs")
        .iter()
        .map(|program| serde_json::to_string(program).expect("canonical program JSON"))
        .collect()
}

fn write_installed_package(install_root: &Path, manifest: &Value, enabled: bool) -> PathBuf {
    let plugin_id = manifest["id"].as_str().expect("plugin ID");
    let version = manifest["version"].as_str().expect("version");
    let package_root = install_root.join(plugin_id).join(version);
    std::fs::create_dir_all(&package_root).expect("package directory");
    std::fs::write(
        package_root.join("plugin.json"),
        serde_json::to_vec_pretty(manifest).expect("manifest bytes"),
    )
    .expect("manifest file");
    let content_digest = signature::content_digest(&package_root).expect("content digest");
    let record = json!({
        "schemaVersion": 2,
        "pluginId": plugin_id,
        "version": version,
        "previousVersion": "0.0.9",
        "enabled": enabled,
        "origin": "community",
        "previousOrigin": "marketplace",
        "disk": {
            "fileName": "detail-fixture.zip",
            "archiveSha256": "archive-current",
            "contentDigest": content_digest,
            "approvedPrograms": review_programs(manifest),
        },
        "previousMarketplace": {
            "sourceId": "lithe-store",
            "sourceName": "Lithe Store",
            "repository": "https://example.invalid/plugins",
            "archiveSha256": "archive-previous",
            "contentDigest": "digest-previous",
            "approvedPrograms": [],
        },
    });
    std::fs::write(
        details::installation_record_path(install_root, plugin_id),
        serde_json::to_vec_pretty(&record).expect("record bytes"),
    )
    .expect("installation record");
    package_root
}

fn find_package<'a>(packages: &'a [super::ScannedPackage], id: &str) -> &'a super::ScannedPackage {
    packages
        .iter()
        .find(|package| package.entry.plugin_id == id)
        .expect("scanned package")
}

#[test]
fn installed_details_use_core_review_and_recorded_current_and_previous_provenance() {
    let root = TestDirectory::new("installed");
    let bundled_root = root.0.join("bundled");
    let install_root = root.0.join("installed");
    std::fs::create_dir_all(&bundled_root).expect("bundled root");
    let manifest = community_manifest();
    write_installed_package(&install_root, &manifest, false);

    let packages = scan::build_catalog_from(&bundled_root, &install_root).expect("catalog");
    let package = find_package(&packages, "io.example.details-fixture");
    assert_eq!(package.entry.status, "accepted");
    let details = details::build_details(package, &install_root, &bundled_root)
        .expect("package-backed details");

    assert!(
        !details.enabled,
        "disabled state comes from the install record"
    );
    assert_eq!(details.status, "accepted");
    assert!(details.localized_descriptions.is_empty());
    assert_eq!(
        details.permissions,
        ["languageServer.launch", "process.run", "process.test"]
    );
    assert_eq!(
        details.programs.len(),
        4,
        "Core returns every complete program"
    );
    assert!(details.programs.iter().all(Value::is_object));
    assert_eq!(details.versions.current.channel, "disk");
    assert_eq!(
        details.versions.current.archive_sha256.as_deref(),
        Some("archive-current")
    );
    assert_eq!(
        details.versions.current.verification.status,
        "approvedDigest"
    );
    let previous = details.versions.previous.expect("previous provenance");
    assert_eq!(previous.version, "0.0.9");
    assert_eq!(previous.channel, "marketplace");
    assert_eq!(previous.source_name.as_deref(), Some("Lithe Store"));
    assert_eq!(previous.verification.status, "unknown");
    assert_eq!(details.versions.update_status, "unknown");
    assert!(details.operations.can_rollback);
    assert!(details.features.iter().any(|feature| {
        feature.kind == "languageServer" && feature.availability == "available"
    }));
    assert!(details
        .features
        .iter()
        .any(|feature| { feature.kind == "run" && feature.availability == "declaredOnly" }));
}

#[test]
fn bundled_details_report_the_verified_host_seal_not_a_manifest_claim() {
    let root = TestDirectory::new("bundled");
    let bundled_root = root.0.join("bundled");
    let install_root = root.0.join("installed");
    let mut manifest = fixture();
    manifest["id"] = json!("dev.lithe.plugin.php-support");
    manifest["vendor"]["signatureRequirement"] = json!("sameTeamAsHost");
    let package_root = bundled_root.join("php").join("0.1.0");
    std::fs::create_dir_all(&package_root).expect("bundled package");
    std::fs::write(
        package_root.join("plugin.json"),
        serde_json::to_vec_pretty(&manifest).expect("manifest bytes"),
    )
    .expect("manifest file");

    let packages = scan::build_catalog_from(&bundled_root, &install_root).expect("catalog");
    let package = find_package(&packages, "dev.lithe.plugin.php-support");
    let details =
        details::build_details(package, &install_root, &bundled_root).expect("bundled details");
    assert_eq!(details.versions.current.origin, "bundled");
    assert_eq!(details.versions.current.verification.status, "hostSeal");
    assert!(!details.operations.can_uninstall);
}

#[test]
fn invalid_installation_record_remains_explainable_and_quarantined() {
    let root = TestDirectory::new("quarantine");
    let bundled_root = root.0.join("bundled");
    let install_root = root.0.join("installed");
    std::fs::create_dir_all(&bundled_root).expect("bundled root");
    let manifest = community_manifest();
    let plugin_id = manifest["id"].as_str().expect("plugin ID");
    let package_root = install_root.join(plugin_id).join("0.1.0");
    std::fs::create_dir_all(&package_root).expect("package root");
    std::fs::write(
        package_root.join("plugin.json"),
        serde_json::to_vec_pretty(&manifest).expect("manifest bytes"),
    )
    .expect("manifest file");
    std::fs::write(
        details::installation_record_path(&install_root, plugin_id),
        json!({
            "schemaVersion": 1,
            "pluginId": plugin_id,
            "version": "0.1.0",
            "enabled": true,
        })
        .to_string(),
    )
    .expect("legacy record");

    let packages = scan::build_catalog_from(&bundled_root, &install_root).expect("catalog");
    let package = find_package(&packages, plugin_id);
    let details = details::build_details(package, &install_root, &bundled_root)
        .expect("quarantine details are readable");
    assert_eq!(details.status, "rejected");
    assert_eq!(
        details.rejection.expect("rejection").code,
        "plugin.manifest.invalid"
    );
    assert_eq!(details.versions.current.verification.status, "rejected");
    assert!(!details.operations.can_set_enabled);
    assert!(details.operations.can_uninstall);
}

#[test]
fn detail_read_refuses_digest_changes_after_the_catalog_snapshot() {
    let root = TestDirectory::new("changed");
    let bundled_root = root.0.join("bundled");
    let install_root = root.0.join("installed");
    std::fs::create_dir_all(&bundled_root).expect("bundled root");
    let manifest = community_manifest();
    let package_root = write_installed_package(&install_root, &manifest, true);
    let packages = scan::build_catalog_from(&bundled_root, &install_root).expect("catalog");
    let package = find_package(&packages, "io.example.details-fixture");
    std::fs::write(package_root.join("changed-after-scan.txt"), b"changed")
        .expect("post-scan mutation");

    let error: PluginDetailsError = details::build_details(package, &install_root, &bundled_root)
        .expect_err("changed digest is refused");
    assert_eq!(error.code, "plugin.details.packageChanged");
}

#[test]
fn detail_read_refuses_an_installation_record_that_no_longer_owns_the_scanned_package() {
    let root = TestDirectory::new("record-changed");
    let bundled_root = root.0.join("bundled");
    let install_root = root.0.join("installed");
    std::fs::create_dir_all(&bundled_root).expect("bundled root");
    let manifest = community_manifest();
    let plugin_id = manifest["id"].as_str().expect("plugin ID");
    write_installed_package(&install_root, &manifest, true);
    let packages = scan::build_catalog_from(&bundled_root, &install_root).expect("catalog");
    let package = find_package(&packages, plugin_id);
    let record_path = details::installation_record_path(&install_root, plugin_id);
    let original: Value =
        serde_json::from_slice(&std::fs::read(&record_path).expect("record bytes"))
            .expect("record JSON");

    for (field, changed) in [
        ("schemaVersion", json!(1)),
        ("pluginId", json!("io.example.different")),
        ("version", json!("9.9.9")),
        ("origin", json!("marketplace")),
        (
            "disk",
            json!({ "fileName": "changed.zip", "contentDigest": "changed", "approvedPrograms": [] }),
        ),
    ] {
        let mut record = original.clone();
        record[field] = changed;
        std::fs::write(
            &record_path,
            serde_json::to_vec(&record).expect("record bytes"),
        )
        .expect("changed record");
        let error = details::build_details(package, &install_root, &bundled_root)
            .expect_err("stale provenance must not be attached to another active package");
        assert_eq!(
            error.code, "plugin.details.installationRecordChanged",
            "changed {field}"
        );
    }
}

#[test]
fn detail_enabled_state_comes_from_the_live_installation_record() {
    let root = TestDirectory::new("enabled-changed");
    let bundled_root = root.0.join("bundled");
    let install_root = root.0.join("installed");
    std::fs::create_dir_all(&bundled_root).expect("bundled root");
    let manifest = community_manifest();
    let plugin_id = manifest["id"].as_str().expect("plugin ID");
    write_installed_package(&install_root, &manifest, true);
    let packages = scan::build_catalog_from(&bundled_root, &install_root).expect("catalog");
    let package = find_package(&packages, plugin_id);
    write_installed_package(&install_root, &manifest, false);

    let details = details::build_details(package, &install_root, &bundled_root)
        .expect("same package with changed enabled state");
    assert!(!details.enabled);
}

#[test]
fn details_reject_a_cached_package_outside_the_owning_store() {
    let root = TestDirectory::new("boundary");
    let bundled_root = root.0.join("bundled");
    let install_root = root.0.join("installed");
    let outside_root = root.0.join("outside");
    std::fs::create_dir_all(&bundled_root).expect("bundled root");
    std::fs::create_dir_all(&install_root).expect("installed root");
    let manifest = community_manifest();
    write_installed_package(&outside_root, &manifest, true);
    let packages = scan::build_catalog_from(&bundled_root, &outside_root).expect("catalog");
    let package = find_package(&packages, "io.example.details-fixture");

    let error = details::build_details(package, &install_root, &bundled_root)
        .expect_err("foreign store path is refused");
    assert_eq!(error.code, "plugin.details.pathBoundary");
}

#[test]
fn provenance_origin_is_not_inferred_from_manifest_vendor_fields() {
    let root = TestDirectory::new("origin");
    let bundled_root = root.0.join("bundled");
    let install_root = root.0.join("installed");
    std::fs::create_dir_all(&bundled_root).expect("bundled root");
    let mut manifest = community_manifest();
    manifest["vendor"]["id"] = json!("dev.lithe");
    manifest["vendor"]["displayName"] = json!("Claims Official");
    write_installed_package(&install_root, &manifest, true);

    let packages = scan::build_catalog_from(&bundled_root, &install_root).expect("catalog");
    let package = find_package(&packages, "io.example.details-fixture");
    let details =
        details::build_details(package, &install_root, &bundled_root).expect("community details");
    assert_eq!(details.versions.current.origin, "community");
    assert_eq!(details.versions.current.channel, "disk");
    assert_eq!(
        details.versions.current.verification.status,
        "approvedDigest"
    );
}
