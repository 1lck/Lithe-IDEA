//! Shared-fixture acceptance and store-layout tests for the plugin host.
//!
//! The fixture tests are the Windows half of the contract acceptance recorded
//! in the declarative-plugin note: every host must reject the same invalid
//! manifests with the same stable codes, and the host capability declaration
//! must gate level 3 sections this host does not implement yet.

use super::scan::{self, build_catalog_from};
use super::store::{self, DiscoveredPackage};
use serde_json::{json, Value};
use std::path::PathBuf;

const FIXTURES_DIR: &str = concat!(
    env!("CARGO_MANIFEST_DIR"),
    "/../../../shared/contracts/plugins/v1/fixtures"
);

/// Valid manifests that this host's capability declaration accepts.
const ACCEPTED_FIXTURES: [&str; 7] = [
    "language-system-command.plugin.json",
    "hello-lithe.plugin.json",
    "language-host-integration.plugin.json",
    "node-runtime.plugin.json",
    "language-packaged-server.plugin.json",
    "web-panel.plugin.json",
    "project-generator.plugin.json",
];

/// Valid manifests whose capabilities exceed the host declaration; Core
/// rejects them through the capability gate, not through manifest semantics.
const CAPABILITY_GATED_FIXTURES: [&str; 5] = [
    "build-static-file.plugin.json",
    "build-command-stdout.plugin.json",
    "build-command-output-file.plugin.json",
    "build-provider.plugin.json",
    "build-host-integration.plugin.json",
];

fn fixture_path(name: &str) -> PathBuf {
    PathBuf::from(FIXTURES_DIR).join(name)
}

fn read_fixture(name: &str) -> Value {
    let text = std::fs::read_to_string(fixture_path(name))
        .unwrap_or_else(|error| panic!("fixture {name} could not be read: {error}"));
    serde_json::from_str(&text)
        .unwrap_or_else(|error| panic!("fixture {name} is not JSON: {error}"))
}

/// Applies one JSON-Patch-style fixture edit; mirrors the Core test helper so
/// both platforms exercise identical case material.
fn apply_edit(manifest: &mut Value, edit: &Value) {
    let path = edit["path"].as_str().expect("edit path");
    let (parent_path, key) = path.rsplit_once('/').expect("edit path separator");
    let parent = manifest
        .pointer_mut(parent_path)
        .unwrap_or_else(|| panic!("missing edit parent {parent_path}"));
    match edit["op"].as_str().expect("edit op") {
        "set" => match parent {
            Value::Object(object) => {
                object.insert(key.to_string(), edit["value"].clone());
            }
            Value::Array(array) => {
                array[key.parse::<usize>().expect("array index")] = edit["value"].clone()
            }
            _ => panic!("edit parent {parent_path} is not a container"),
        },
        "remove" => {
            parent
                .as_object_mut()
                .expect("remove parent is an object")
                .remove(key);
        }
        other => panic!("unknown edit op {other}"),
    }
}

/// Contract parity: without host capabilities the Windows binary must reject
/// every invalid fixture with the exact code the shared fixture names.
#[test]
fn invalid_manifest_fixtures_keep_their_stable_codes() {
    let fixtures: Value = serde_json::from_str(
        &std::fs::read_to_string(fixture_path("invalid-manifests.json"))
            .expect("invalid-manifests.json is readable"),
    )
    .expect("invalid-manifests.json is JSON");
    let cases = fixtures["cases"].as_array().expect("cases array");
    assert!(!cases.is_empty(), "fixture case list is not empty");
    for case in cases {
        let base = case["base"].as_str().expect("case base");
        let mut manifest = read_fixture(base);
        for edit in case["edits"].as_array().expect("case edits") {
            apply_edit(&mut manifest, edit);
        }
        let outcome = scan::validate_manifest_with(&manifest, None);
        let expected = case["expectedCode"].as_str().expect("expected code");
        match outcome {
            Err(rejection) => assert_eq!(
                rejection.code, expected,
                "case {:?} (base {base}) rejected with {} instead",
                case["name"], rejection.code
            ),
            Ok(_) => panic!(
                "case {:?} (base {base}) was accepted but must reject with {expected}",
                case["name"]
            ),
        }
    }
}

/// Every valid fixture passes contract validation without host capabilities.
#[test]
fn valid_fixtures_validate_without_host_capabilities() {
    let all_fixtures: Vec<&str> = ACCEPTED_FIXTURES
        .iter()
        .copied()
        .chain(CAPABILITY_GATED_FIXTURES.iter().copied())
        .chain(std::iter::once("settings-v2.plugin.json"))
        .collect();
    for name in all_fixtures {
        let outcome = scan::validate_manifest_with(&read_fixture(name), None);
        assert!(outcome.is_ok(), "{name} must validate: {outcome:?}");
    }
}

/// The v0 host capability declaration accepts the fixtures it can run and
/// gates the rest with `plugin.api.unsupported` naming the missing capability.
#[test]
fn host_v0_capabilities_gate_unimplemented_sections() {
    for name in ACCEPTED_FIXTURES {
        let outcome =
            scan::validate_manifest_with(&read_fixture(name), Some(super::host_capabilities()));
        assert!(
            outcome.is_ok(),
            "{name} must be accepted by the host: {outcome:?}"
        );
    }
    for name in CAPABILITY_GATED_FIXTURES {
        let outcome =
            scan::validate_manifest_with(&read_fixture(name), Some(super::host_capabilities()));
        let rejection = outcome.expect_err(&format!("{name} must be capability-gated"));
        assert_eq!(rejection.code, "plugin.api.unsupported", "{name}");
        assert!(rejection
            .path
            .as_deref()
            .unwrap_or_default()
            .starts_with("requires."));
    }
    // settings-v2 requires settings 2 and languageServers 2, both undeclared.
    let outcome = scan::validate_manifest_with(
        &read_fixture("settings-v2.plugin.json"),
        Some(super::host_capabilities()),
    );
    assert_eq!(
        outcome.expect_err("settings-v2 is gated").code,
        "plugin.api.unsupported"
    );
}

/// A scanned package directory produces an accepted entry with normalized
/// languages, and a broken manifest is quarantined instead of registered.
#[test]
fn scan_accepts_valid_packages_and_quarantines_broken_ones() {
    let root = unique_temp_root("scan");
    let package_root = root.join("acme.php");
    std::fs::create_dir_all(&package_root).expect("package dir");
    // A community install requires a non-official ID and an unsigned trust
    // declaration; the fixture's official-namespace manifest is reshaped the
    // way a real disk package looks.
    let mut manifest = read_fixture("language-packaged-server.plugin.json");
    manifest["id"] = serde_json::json!("io.example.acme-php");
    manifest["vendor"]["signatureRequirement"] = serde_json::json!("none");
    std::fs::write(
        package_root.join("plugin.json"),
        serde_json::to_string_pretty(&manifest).expect("manifest text"),
    )
    .expect("manifest file");

    let accepted = scan_package_at(
        &package_root,
        None,
        Some(crate::plugin_host::signature::InstallOrigin::Community),
        Some(
            crate::plugin_host::signature::content_digest(&package_root)
                .expect("digest of the package"),
        ),
    );
    assert_eq!(accepted.entry.status, "accepted");
    assert_eq!(accepted.entry.plugin_id, manifest["id"]);
    assert_eq!(accepted.entry.languages.len(), 1);
    assert_eq!(
        accepted.entry.languages[0].file_extensions,
        vec!["php", "phtml"]
    );

    std::fs::write(package_root.join("plugin.json"), "{ not json").expect("broken manifest");
    let broken = scan_package_at(&package_root, None, None, None);
    assert_eq!(broken.entry.status, "rejected");
    assert_eq!(
        broken.entry.rejection.as_ref().expect("rejection").code,
        "plugin.manifest.invalid"
    );

    let _ = std::fs::remove_dir_all(&root);
}

/// Missing or invalid installation records quarantine the package instead of
/// loading it, even when its manifest is valid.
#[test]
fn store_problems_quarantine_packages_with_valid_manifests() {
    let root = unique_temp_root("store");
    let plugin_directory = root.join("acme.php");
    let version_directory = plugin_directory.join("1.0.0");
    std::fs::create_dir_all(&version_directory).expect("version dir");
    std::fs::write(
        version_directory.join("plugin.json"),
        serde_json::to_string(&read_fixture("language-packaged-server.plugin.json"))
            .expect("manifest"),
    )
    .expect("manifest file");

    // No installation.json: the package was never installed through Lithe.
    let discovered = store::discover_installed_in(&root).expect("discovery works");
    assert_eq!(discovered.len(), 1);
    assert!(discovered[0].record_problem.is_some());

    // A record naming a missing version is a store problem too.
    std::fs::write(
        plugin_directory.join("installation.json"),
        json!({"schemaVersion": 2, "pluginId": "acme.php", "version": "9.9.9", "origin": "community"}).to_string(),
    )
    .expect("record file");
    let discovered = store::discover_installed_in(&root).expect("discovery works");
    assert!(discovered[0].record_problem.is_some());

    // A schema 1 record predates content provenance: it is quarantined even
    // though it names the installed version, because the enabled flag and
    // the manifest cannot prove which bytes the user approved.
    std::fs::write(
        plugin_directory.join("installation.json"),
        json!({"schemaVersion": 1, "pluginId": "acme.php", "version": "1.0.0"}).to_string(),
    )
    .expect("record file");
    let discovered = store::discover_installed_in(&root).expect("discovery works");
    assert!(discovered[0].record_problem.is_some());
    assert!(discovered[0]
        .record_problem
        .as_deref()
        .unwrap_or_default()
        .contains("provenance"));

    // A schema 2 community record without a content digest is the same trap.
    std::fs::write(
        plugin_directory.join("installation.json"),
        json!({"schemaVersion": 2, "pluginId": "acme.php", "version": "1.0.0", "origin": "community"}).to_string(),
    )
    .expect("record file");
    let discovered = store::discover_installed_in(&root).expect("discovery works");
    assert!(discovered[0].record_problem.is_some());

    // Correct record: discovered at the recorded version, enabled by default.
    write_record_v2(
        &plugin_directory,
        "acme.php",
        "1.0.0",
        &version_directory,
        true,
    );
    let discovered = store::discover_installed_in(&root).expect("discovery works");
    assert!(discovered[0].record_problem.is_none());
    assert_eq!(discovered[0].root, version_directory);
    assert!(discovered[0].enabled);

    let _ = std::fs::remove_dir_all(&root);
}

/// Bundled discovery prefers the highest version directory of a package.
#[test]
fn bundled_discovery_picks_the_highest_version() {
    let root = unique_temp_root("bundled");
    for version in ["1.0.0", "1.10.0", "1.9.0"] {
        let directory = root.join("acme.php").join(version);
        std::fs::create_dir_all(&directory).expect("version dir");
        std::fs::write(directory.join("plugin.json"), "{}").expect("manifest file");
    }
    let discovered = store::discover_bundled_in(&root).expect("discovery works");
    assert_eq!(discovered.len(), 1);
    assert_eq!(
        discovered[0].root.file_name().unwrap().to_string_lossy(),
        "1.10.0"
    );
    assert_eq!(discovered[0].source, "bundled");
    let _ = std::fs::remove_dir_all(&root);
}

/// The full catalog build accepts recorded packages, quarantines store
/// problems, and keeps bundled packages enabled.
#[test]
fn catalog_build_combines_bundled_and_installed_sources() {
    let temporary = unique_temp_root("catalog");
    let install_root = temporary.join("plugins");
    let bundled_root = temporary.join("OfficialPlugins");
    let installed_version = install_root.join("acme.php").join("1.0.0");
    std::fs::create_dir_all(&installed_version).expect("installed dir");
    let mut installed_manifest = read_fixture("language-packaged-server.plugin.json");
    installed_manifest["id"] = serde_json::json!("io.example.acme-php");
    installed_manifest["vendor"]["signatureRequirement"] = serde_json::json!("none");
    std::fs::write(
        installed_version.join("plugin.json"),
        serde_json::to_string_pretty(&installed_manifest).expect("manifest"),
    )
    .expect("manifest file");
    write_record_v2(
        &install_root.join("acme.php"),
        "acme.php",
        "1.0.0",
        &installed_version,
        false,
    );
    // A bundled package is trusted through its location: its manifest may
    // keep the sameTeamAsHost policy the bundled PHP contract package uses.
    let mut bundled_manifest = read_fixture("language-system-command.plugin.json");
    bundled_manifest["vendor"]["signatureRequirement"] = serde_json::json!("sameTeamAsHost");
    let bundled_directory = bundled_root.join("acme.go").join("2.0.0");
    std::fs::create_dir_all(&bundled_directory).expect("bundled dir");
    std::fs::write(
        bundled_directory.join("plugin.json"),
        serde_json::to_string_pretty(&bundled_manifest).expect("manifest"),
    )
    .expect("manifest file");

    let catalog = build_catalog_from(&bundled_root, &install_root).expect("catalog builds");
    assert_eq!(catalog.len(), 2);
    let installed = catalog
        .iter()
        .find(|package| package.entry.source == "installed")
        .expect("installed entry");
    assert_eq!(installed.entry.status, "accepted");
    assert!(!installed.entry.enabled, "recorded enabled: false wins");
    let bundled = catalog
        .iter()
        .find(|package| package.entry.source == "bundled")
        .expect("bundled entry");
    assert_eq!(
        bundled.entry.plugin_id,
        "dev.lithe.fixture.language-system-command"
    );
    assert!(bundled.entry.enabled);

    let _ = std::fs::remove_dir_all(&temporary);
}

fn unique_temp_root(label: &str) -> PathBuf {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("system clock")
        .as_nanos();
    let root = std::env::temp_dir().join(format!(
        "lithe-plugin-host-{label}-{}-{nanos}",
        std::process::id()
    ));
    std::fs::create_dir_all(&root).expect("temp root");
    root
}

/// Scans one package directory through the production scan path. `origin`
/// and `content_digest` carry the trust evidence an installation record
/// would provide; `None` mirrors a record without provenance.
fn scan_package_at(
    root: &std::path::Path,
    record_problem: Option<String>,
    origin: Option<crate::plugin_host::signature::InstallOrigin>,
    content_digest: Option<String>,
) -> super::ScannedPackage {
    super::scan::scan_package_for_tests(
        DiscoveredPackage {
            root: root.to_path_buf(),
            source: "installed",
            enabled: true,
            origin,
            content_digest,
            record_problem,
        },
        None,
    )
}

/// Writes a schema 2 community record naming `version`, with the content
/// digest of `version_directory` as the approved-bytes evidence.
fn write_record_v2(
    plugin_directory: &std::path::Path,
    plugin_id: &str,
    version: &str,
    version_directory: &std::path::Path,
    enabled: bool,
) {
    let record = json!({
        "schemaVersion": 2,
        "pluginId": plugin_id,
        "version": version,
        "enabled": enabled,
        "origin": "community",
        "disk": {
            "fileName": "plugin.zip",
            "archiveSHA256": null,
            "contentDigest": crate::plugin_host::signature::content_digest(version_directory)
                .expect("digest of the package directory"),
            "approvedPrograms": [],
        }
    });
    std::fs::write(
        plugin_directory.join("installation.json"),
        record.to_string(),
    )
    .expect("record file");
}

/// Fixture reader shared with the install test module.
pub(crate) fn read_fixture_for_tests(name: &str) -> serde_json::Value {
    read_fixture(name)
}

/// Writes a community-installable package (non-official ID, unsigned trust
/// declaration) and its schema 2 record into an install root.
fn install_community_package(install_root: &std::path::Path, version: &str) -> std::path::PathBuf {
    let plugin_directory = install_root.join("io.example.acme-php");
    let version_directory = plugin_directory.join(version);
    std::fs::create_dir_all(&version_directory).expect("version dir");
    let mut manifest = read_fixture("language-packaged-server.plugin.json");
    manifest["id"] = serde_json::json!("io.example.acme-php");
    manifest["vendor"]["signatureRequirement"] = serde_json::json!("none");
    manifest["version"] = serde_json::json!(version);
    std::fs::write(
        version_directory.join("plugin.json"),
        serde_json::to_string_pretty(&manifest).expect("manifest text"),
    )
    .expect("manifest file");
    std::fs::write(version_directory.join("server.js"), b"entry").expect("package file");
    write_record_v2(
        &plugin_directory,
        "io.example.acme-php",
        version,
        &version_directory,
        true,
    );
    version_directory
}

/// The real bundled PHP contract package passes the M1 trust gate exactly
/// the way the app's resource-directory scan will treat it: bundled origin,
/// pinned `sameTeamAsHost` policy, no install record.
#[test]
fn real_bundled_contract_package_passes_the_trust_gate() {
    let source = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../Plugins/win/Official/PhpSupportContract"
    );
    let root = unique_temp_root("trust-bundled");
    let bundled_root = root
        .join("OfficialPlugins")
        .join("dev.lithe.plugin.php-support");
    std::fs::create_dir_all(&bundled_root).expect("bundled root");
    copy_directory_snapshot_for_tests(std::path::Path::new(source), &bundled_root);

    let catalog = build_catalog_from(&root.join("OfficialPlugins"), &root.join("none"))
        .expect("catalog builds");
    let package = catalog
        .iter()
        .find(|package| package.entry.source == "bundled")
        .expect("bundled entry");
    let entry = &package.entry;
    assert_eq!(entry.status, "accepted", "{:?}", entry.rejection);
    assert_eq!(entry.plugin_id, "dev.lithe.plugin.php-support");
    assert!(entry.enabled);
    // The trust evidence recorded for launch re-verification is bundled.
    assert!(matches!(
        package.trust.as_ref().map(|trust| trust.origin),
        Some(crate::plugin_host::signature::InstallOrigin::Bundled)
    ));
    let _ = std::fs::remove_dir_all(&root);
}

/// Copies a package tree without following reparse points, mirroring the
/// snapshot copy the installer performs.
fn copy_directory_snapshot_for_tests(source: &std::path::Path, target: &std::path::Path) {
    std::fs::create_dir_all(target).expect("target dir");
    for entry in std::fs::read_dir(source).expect("source readable") {
        let entry = entry.expect("entry");
        let entry_target = target.join(entry.file_name());
        if entry.path().is_dir() {
            copy_directory_snapshot_for_tests(&entry.path(), &entry_target);
        } else {
            std::fs::copy(entry.path(), &entry_target).expect("file copy");
        }
    }
}

/// P1 regression: an installed record can never claim bundled origin. The
/// bundled identity comes only from the trusted resource discoverer; a
/// schema 2 record that claims it (for the active or the previous version)
/// is forged and the package is quarantined instead of scanned.
#[test]
fn installed_records_cannot_claim_bundled_origin() {
    let root = unique_temp_root("trust-bundled-claim");
    let install_root = root.join("plugins");
    let plugin_directory = install_root.join("dev.lithe.plugin.php-support");
    let version_directory = plugin_directory.join("1.0.0");
    std::fs::create_dir_all(&version_directory).expect("version dir");
    let mut manifest = read_fixture("language-packaged-server.plugin.json");
    manifest["id"] = serde_json::json!("dev.lithe.plugin.php-support");
    manifest["vendor"]["signatureRequirement"] = serde_json::json!("sameTeamAsHost");
    manifest["version"] = serde_json::json!("1.0.0");
    std::fs::write(
        version_directory.join("plugin.json"),
        serde_json::to_string_pretty(&manifest).expect("manifest text"),
    )
    .expect("manifest file");
    std::fs::write(version_directory.join("server.js"), b"entry").expect("package file");

    // The forged record claims bundled origin with no digest at all.
    std::fs::write(
        plugin_directory.join("installation.json"),
        json!({
            "schemaVersion": 2,
            "pluginId": "dev.lithe.plugin.php-support",
            "version": "1.0.0",
            "enabled": true,
            "origin": "bundled"
        })
        .to_string(),
    )
    .expect("record file");
    let discovered = store::discover_installed_in(&install_root).expect("discovery works");
    assert!(
        discovered[0].record_problem.is_some(),
        "a bundled-origin claim must be a record problem"
    );
    let catalog = build_catalog_from(&root.join("none"), &install_root).expect("catalog builds");
    let entry = &catalog
        .iter()
        .find(|package| package.entry.source == "installed")
        .expect("installed entry")
        .entry;
    assert_eq!(entry.status, "rejected", "the forged package must not load");

    // The same holds when only the previous version claims bundled origin.
    let digest = crate::plugin_host::signature::content_digest(&version_directory)
        .expect("digest of the package");
    std::fs::write(
        plugin_directory.join("installation.json"),
        json!({
            "schemaVersion": 2,
            "pluginId": "dev.lithe.plugin.php-support",
            "version": "1.0.0",
            "enabled": true,
            "origin": "community",
            "disk": {
                "fileName": "plugin.zip",
                "archiveSHA256": null,
                "contentDigest": digest,
                "approvedPrograms": []
            },
            "previousVersion": "0.9.0",
            "previousOrigin": "bundled"
        })
        .to_string(),
    )
    .expect("record file");
    let discovered = store::discover_installed_in(&install_root).expect("discovery works");
    assert!(
        discovered[0].record_problem.is_some(),
        "a bundled previous-origin claim must be a record problem too"
    );
    let _ = std::fs::remove_dir_all(&root);
}

/// The bytes of an installed community package are rechecked against the
/// recorded content digest on every scan, so a package tampered while the
/// app was not running is quarantined at the next startup instead of loaded.
#[test]
fn scan_quarantines_a_tampered_installed_package() {
    let root = unique_temp_root("trust-tamper");
    let install_root = root.join("plugins");
    install_community_package(&install_root, "1.0.0");

    let catalog = build_catalog_from(&root.join("none"), &install_root).expect("catalog builds");
    let entry = &catalog
        .iter()
        .find(|package| package.entry.source == "installed")
        .expect("installed entry")
        .entry;
    assert_eq!(entry.status, "accepted");

    // Tamper while the app is not running: the next scan must refuse.
    std::fs::write(
        install_root
            .join("io.example.acme-php")
            .join("1.0.0")
            .join("server.js"),
        b"tampered",
    )
    .expect("tamper");
    let catalog = build_catalog_from(&root.join("none"), &install_root).expect("catalog builds");
    let entry = &catalog
        .iter()
        .find(|package| package.entry.source == "installed")
        .expect("installed entry")
        .entry;
    assert_eq!(entry.status, "rejected");
    let rejection = entry.rejection.as_ref().expect("rejection");
    assert_eq!(rejection.code, "plugin.trust.contentChanged");

    // An added file is the same rejection: the approved file set is exact.
    std::fs::write(
        install_root
            .join("io.example.acme-php")
            .join("1.0.0")
            .join("server.js"),
        b"entry",
    )
    .expect("restore");
    std::fs::write(
        install_root
            .join("io.example.acme-php")
            .join("1.0.0")
            .join("extra.js"),
        b"added",
    )
    .expect("add file");
    let catalog = build_catalog_from(&root.join("none"), &install_root).expect("catalog builds");
    let entry = &catalog
        .iter()
        .find(|package| package.entry.source == "installed")
        .expect("installed entry")
        .entry;
    assert_eq!(
        entry.rejection.as_ref().expect("rejection").code,
        "plugin.trust.contentChanged"
    );
    let _ = std::fs::remove_dir_all(&root);
}

/// The host's official-ID trust policy overrides the package declaration: a
/// pinned official ID cannot install as an unsigned community package even
/// when its manifest claims a signature requirement the host could honor.
#[test]
fn official_ids_reject_unsigned_community_installs() {
    let root = unique_temp_root("trust-official");
    let package_root = root.join("pkg");
    std::fs::create_dir_all(&package_root).expect("package dir");
    let mut manifest = read_fixture("language-packaged-server.plugin.json");
    // The pinned PHP support ID; its bundled contract package legitimately
    // uses sameTeamAsHost, which a disk install can never prove.
    manifest["id"] = serde_json::json!("dev.lithe.plugin.php-support");
    manifest["vendor"]["signatureRequirement"] = serde_json::json!("sameTeamAsHost");
    std::fs::write(
        package_root.join("plugin.json"),
        serde_json::to_string_pretty(&manifest).expect("manifest text"),
    )
    .expect("manifest file");
    std::fs::write(package_root.join("server.js"), b"entry").expect("package file");

    let scanned = scan_package_at(
        &package_root,
        None,
        Some(crate::plugin_host::signature::InstallOrigin::Community),
        None,
    );
    assert_eq!(scanned.entry.status, "rejected");
    let rejection = scanned.entry.rejection.as_ref().expect("rejection");
    // The pinned sameTeamAsHost policy can never be honored from disk: the
    // package is refused with the seal error even though it declares a
    // requirement the host pins.
    assert_eq!(
        rejection.code, "plugin.trust.hostSealRequired",
        "{rejection:?}"
    );
    let _ = std::fs::remove_dir_all(&root);
}

/// A signature document present in a community package must verify: a forged
/// or damaged document is never silently ignored.
#[test]
fn a_present_signature_document_must_verify_even_for_community_packages() {
    let root = unique_temp_root("trust-signature");
    let install_root = root.join("plugins");
    let version_directory = install_community_package(&install_root, "1.0.0");
    std::fs::write(
        version_directory.join("lithe-plugin-signature.json"),
        r#"{"schemaVersion":1,"algorithm":"ed25519","keyID":"lithe-test-v1","pluginID":"io.example.acme-php","pluginVersion":"1.0.0","files":{},"signature":"AAAA"}"#,
    )
    .expect("signature file");
    let catalog = build_catalog_from(&root.join("none"), &install_root).expect("catalog builds");
    let entry = &catalog
        .iter()
        .find(|package| package.entry.source == "installed")
        .expect("installed entry")
        .entry;
    assert_eq!(
        entry.rejection.as_ref().expect("rejection").code,
        "plugin.trust.signatureInvalid"
    );
    let _ = std::fs::remove_dir_all(&root);
}

/// M3 setting-store tests exercise the two persistence layers directly: the
/// global per-plugin file and the workspace's `.lithe/plugin-settings.json`.
mod settings_tests {
    use crate::plugin_host::settings::{project_store_path, store_global, store_project};

    fn unique_temp_root(label: &str) -> std::path::PathBuf {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("system clock")
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "lithe-plugin-settings-{label}-{}-{nanos}",
            std::process::id()
        ));
        std::fs::create_dir_all(&root).expect("temp root");
        root
    }

    #[test]
    fn project_overrides_round_trip_and_clean_up_empty_entries() {
        let workspace = unique_temp_root("project");
        let workspace_path = workspace.to_string_lossy().to_string();

        store_project(
            &workspace_path,
            "acme.php",
            "heapMaxMB",
            Some(serde_json::json!(4096)),
        )
        .expect("stores override");
        let store =
            std::fs::read_to_string(project_store_path(&workspace_path)).expect("store file");
        let parsed: serde_json::Value = serde_json::from_str(&store).expect("store JSON");
        assert_eq!(parsed["acme.php"]["heapMaxMB"], 4096);

        // Erasing the last override removes the plugin entry, then the file.
        store_project(&workspace_path, "acme.php", "heapMaxMB", None).expect("erases override");
        assert!(!project_store_path(&workspace_path).exists());
        let _ = std::fs::remove_dir_all(&workspace);
    }

    #[test]
    fn project_store_keeps_other_plugins_entries() {
        let workspace = unique_temp_root("project-multi");
        let workspace_path = workspace.to_string_lossy().to_string();
        store_project(&workspace_path, "acme.php", "a", Some(serde_json::json!(1)))
            .expect("stores a");
        store_project(
            &workspace_path,
            "other.plugin",
            "b",
            Some(serde_json::json!(2)),
        )
        .expect("stores b");
        store_project(&workspace_path, "acme.php", "a", None).expect("erases a");

        let store: serde_json::Value = serde_json::from_str(
            &std::fs::read_to_string(project_store_path(&workspace_path)).expect("store"),
        )
        .expect("store JSON");
        assert!(store["acme.php"].is_null());
        assert_eq!(store["other.plugin"]["b"], 2);
        let _ = std::fs::remove_dir_all(&workspace);
    }

    #[test]
    fn corrupted_project_store_is_an_error_not_a_reset() {
        let workspace = unique_temp_root("project-corrupt");
        let path = project_store_path(&workspace.to_string_lossy());
        std::fs::create_dir_all(path.parent().unwrap()).expect(".lithe dir");
        std::fs::write(&path, "{ not json").expect("corrupt store");

        assert!(store_project(
            &workspace.to_string_lossy(),
            "acme.php",
            "a",
            Some(serde_json::json!(1))
        )
        .is_err());
        // The corrupted bytes are preserved for diagnosis.
        assert_eq!(std::fs::read_to_string(&path).expect("store"), "{ not json");
        let _ = std::fs::remove_dir_all(&workspace);
    }

    // store_global needs an AppHandle; its logic is covered through the
    // project variant (same read/write helpers) and the live command test.
    #[allow(unused_imports)]
    fn witness() {
        let _ = store_global;
    }
}

/// The bundled PHP contract package validates, expands run and test plans,
/// and exposes settings resolution through the real Core commands — the
/// end-to-end acceptance of the contract package shipped with the app.
#[test]
fn bundled_php_contract_package_expands_plans() {
    let text = std::fs::read_to_string(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../Plugins/win/Official/PhpSupportContract/plugin.json"
    ))
    .expect("contract package manifest is readable");
    let manifest: serde_json::Value = serde_json::from_str(&text).expect("manifest is JSON");

    let validated = scan::validate_manifest_with(&manifest, Some(super::host_capabilities()));
    let plugin = validated.expect("contract package is accepted by the host");
    assert_eq!(plugin["id"], "dev.lithe.plugin.php-support");
    assert_eq!(plugin["pluginAPIVersion"], 2);

    // Run plan expansion.
    let run = scan::core_execute(
        "plugins.declarative.runPlan",
        serde_json::json!({
            "manifest": manifest,
            "languageID": "php",
            "request": {
                "relativeFilePath": "src/Item.php",
                "arguments": ["--verbose"]
            },
        }),
    )
    .expect("run plan executes");
    assert_eq!(run["status"], "ok", "{run}");
    assert_eq!(run["plan"]["executable"]["command"], "php");
    assert_eq!(
        run["plan"]["arguments"],
        serde_json::json!(["src/Item.php", "--verbose"])
    );

    // Workspace test plan expansion.
    let test = scan::core_execute(
        "plugins.declarative.testPlan",
        serde_json::json!({
            "manifest": manifest,
            "languageID": "php",
            "request": {
                "scope": { "kind": "workspace" },
                "relativeProjectFilePaths": ["composer.json", "tests/ItemTest.php"],
            },
        }),
    )
    .expect("test plan executes");
    assert_eq!(test["status"], "ok", "{test}");
    assert_eq!(
        test["plan"]["arguments"],
        serde_json::json!(["vendor/bin/phpunit"])
    );

    // Settings resolution with an empty store (defaults).
    let settings = scan::core_execute(
        "plugins.declarative.resolveSettings",
        serde_json::json!({
            "manifest": manifest,
            "settings": {},
            "projectSettings": {},
        }),
    )
    .expect("resolve settings executes");
    assert_eq!(settings["status"], "ok", "{settings}");
}

/// A scan owns discovery and publication together, so the second discover
/// cannot snapshot the old catalog and overwrite a newer published result.
#[test]
fn concurrent_catalog_refreshes_publish_in_discovery_order() {
    use std::sync::{mpsc, Arc};
    use std::time::Duration;
    let state = Arc::new(super::PluginHostState::default());
    let (entered_tx, entered_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let (done_tx, done_rx) = mpsc::channel();
    std::thread::scope(|scope| {
        let first = state.clone();
        let done = done_tx.clone();
        scope.spawn(move || {
            first
                .refresh(|| {
                    entered_tx.send(()).unwrap();
                    release_rx.recv_timeout(Duration::from_secs(2)).unwrap();
                    Ok(Vec::new())
                })
                .unwrap();
            done.send(()).unwrap();
        });
        entered_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        assert!(state.scan_lock.try_lock().is_err());
        let second = state.clone();
        scope.spawn(move || {
            second
                .refresh(|| {
                    // This closure runs only after the first publication.
                    assert!(second.scan_lock.try_lock().is_err());
                    Ok(vec![scan_package_at(
                        &PathBuf::from("catalog-new.plugin"),
                        None,
                        None,
                        None,
                    )])
                })
                .unwrap();
            done_tx.send(()).unwrap();
        });
        release_tx.send(()).unwrap();
        done_rx.recv_timeout(Duration::from_secs(2)).unwrap();
        done_rx.recv_timeout(Duration::from_secs(2)).unwrap();
    });
    assert_eq!(state.packages().len(), 1);
    assert_eq!(state.packages()[0].entry.plugin_id, "catalog-new.plugin");
}
