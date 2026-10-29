//! M2-C native coordinator regressions. The transport uses a controlled local
//! HTTP server while Core sees real HTTPS release URLs from the shared fixture
//! shape. No external service, plugin process, UI or installed developer tool is needed.

use super::install;
use super::marketplace_coordinator::{MarketplaceCoordinator, MarketplaceHost};
use super::marketplace_download::tests::{PauseAt, TestHttpServer, TestResponse, TestRoot};
use super::marketplace_download::{
    CancelToken, FetchFailure, FetchPolicy, HttpResponse, HttpTransport, ReqwestTransport,
};
use super::marketplace_sources::MarketplaceSource;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::future::Future;
use std::io::{Cursor, Write};
use std::path::Path;
use std::pin::Pin;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const ID: &str = "io.example.acme-php";
const INDEX_A: &str = "https://raw.githubusercontent.com/example/market-a/HEAD/index.json";
const INDEX_B: &str = "https://raw.githubusercontent.com/example/market-b/HEAD/index.json";
const ARCHIVE_ONE: &str = "/example/lithe-fixture/releases/download/v1.0.0/fixture.zip";
const ARCHIVE_TWO: &str = "/example/lithe-fixture/releases/download/v1.1.0/fixture.zip";

#[tokio::test]
async fn cancel_arriving_before_prepare_registration_prevents_any_network_or_snapshot() {
    let harness = Harness::new(vec![]);
    harness.coordinator.cancel("main", "cancelled-before-start");
    assert!(harness
        .coordinator
        .prepare("main", "cancelled-before-start", "source-a", ID)
        .await
        .is_err());
    assert!(harness
        .coordinator
        .pending_plugin("main", "cancelled-before-start")
        .is_err());
    harness.assert_no_pending_files();
    assert!(!harness.root.0.join("indexes").exists());
    assert!(!harness.root.0.join("plugins").exists());
}

#[tokio::test]
async fn an_existing_directory_without_an_installation_record_cannot_be_adopted() {
    let bytes = archive("1.0.0", false);
    let harness = Harness::new(vec![(
        "/example/market-a/HEAD/index.json",
        vec![TestResponse::ok(index("1.0.0", &bytes, true, false))],
    )]);
    let unknown = harness
        .root
        .0
        .join("plugins")
        .join(ID)
        .join("legacy-version");
    std::fs::create_dir_all(&unknown).expect("legacy directory");
    std::fs::write(unknown.join("keep.txt"), b"existing bytes").expect("legacy bytes");
    harness.refresh().await;
    assert!(harness
        .coordinator
        .prepare("main", "no-provenance", "source-a", ID)
        .await
        .is_err());
    assert_eq!(
        std::fs::read(unknown.join("keep.txt")).expect("kept bytes"),
        b"existing bytes"
    );
    assert!(!harness
        .root
        .0
        .join("plugins")
        .join(ID)
        .join("installation.json")
        .exists());
    harness.assert_no_pending_files();
}

#[tokio::test]
async fn a_duplicate_confirmation_does_not_cancel_the_review_already_owned_by_a_worker() {
    let bytes = archive("1.0.0", false);
    let harness = Harness::new(vec![
        (
            "/example/market-a/HEAD/index.json",
            vec![TestResponse::ok(index("1.0.0", &bytes, true, false))],
        ),
        (ARCHIVE_ONE, vec![TestResponse::ok(bytes)]),
    ]);
    harness.refresh().await;
    let prepared = harness
        .coordinator
        .prepare("main", "once", "source-a", ID)
        .await
        .expect("prepare");
    let owner = harness
        .coordinator
        .claim_confirmation("main", "once")
        .expect("claim");
    assert!(harness
        .coordinator
        .claim_confirmation("main", "once")
        .is_err());
    owner
        .publish(&prepared.prepared.manifest_digest, true)
        .expect("the first confirmation keeps its ownership");
    assert_eq!(harness.record()["version"], "1.0.0");
    harness.assert_no_pending_files();
}

#[tokio::test]
async fn a_cancelled_operation_id_cannot_be_revived_and_old_cleanup_keeps_a_new_review() {
    let bytes = archive("1.0.0", false);
    let harness = Harness::new(vec![
        (
            "/example/market-a/HEAD/index.json",
            vec![TestResponse::ok(index("1.0.0", &bytes, true, false))],
        ),
        (ARCHIVE_ONE, vec![TestResponse::ok(bytes)]),
    ]);
    harness.refresh().await;
    harness
        .coordinator
        .prepare("main", "reused", "source-a", ID)
        .await
        .expect("prepare old");
    let old_owner = harness
        .coordinator
        .claim_confirmation("main", "reused")
        .expect("claim old");
    harness.coordinator.cancel("main", "reused");
    harness.assert_no_pending_files();
    assert!(harness
        .coordinator
        .prepare("main", "reused", "source-a", ID)
        .await
        .is_err());
    let fresh = harness
        .coordinator
        .prepare("main", "new-request", "source-a", ID)
        .await
        .expect("prepare new");
    drop(old_owner);
    harness
        .coordinator
        .confirm("main", "new-request", &fresh.prepared.manifest_digest, true)
        .expect("new review remains owned");
    harness.assert_no_pending_files();
}

#[tokio::test]
async fn dropping_confirmation_ownership_before_its_barrier_finishes_discards_the_snapshot() {
    let bytes = archive("1.0.0", false);
    let harness = Harness::new(vec![
        (
            "/example/market-a/HEAD/index.json",
            vec![TestResponse::ok(index("1.0.0", &bytes, true, false))],
        ),
        (ARCHIVE_ONE, vec![TestResponse::ok(bytes)]),
    ]);
    harness.refresh().await;
    harness
        .coordinator
        .prepare("main", "abandoned", "source-a", ID)
        .await
        .expect("prepare");
    let owner = harness
        .coordinator
        .claim_confirmation("main", "abandoned")
        .expect("claim");
    drop(owner);
    assert!(harness
        .coordinator
        .pending_plugin("main", "abandoned")
        .is_err());
    harness.assert_no_pending_files();
    assert!(!harness.root.0.join("plugins").exists());
}

#[tokio::test]
async fn a_window_closed_before_operation_registration_cannot_leave_a_pending_review() {
    let harness = Harness::new(vec![]);
    harness.coordinator.cancel_window("main");
    harness
        .host
        .closed_windows
        .lock()
        .expect("window ownership")
        .insert("main".into());
    assert!(harness
        .coordinator
        .prepare("main", "late-window", "source-a", ID)
        .await
        .is_err());
    assert!(harness
        .coordinator
        .pending_plugin("main", "late-window")
        .is_err());
    harness.assert_no_pending_files();
}

#[tokio::test]
async fn cancellation_after_staging_before_activation_preserves_the_previous_installation() {
    let bytes = archive("1.0.0", false);
    let harness = Harness::new(vec![
        (
            "/example/market-a/HEAD/index.json",
            vec![TestResponse::ok(index("1.0.0", &bytes, true, false))],
        ),
        (ARCHIVE_ONE, vec![TestResponse::ok(bytes)]),
    ]);
    harness.refresh().await;
    let first = harness
        .coordinator
        .prepare("main", "first", "source-a", ID)
        .await
        .expect("prepare");
    harness
        .coordinator
        .confirm("main", "first", &first.prepared.manifest_digest, true)
        .expect("install");
    let original = harness.record();
    let pending = harness
        .coordinator
        .prepare("main", "cancel-at-commit", "source-a", ID)
        .await
        .expect("update");
    let weak = Arc::downgrade(&harness.coordinator);
    *harness.host.before_commit.lock().expect("commit action") = Some(Box::new(move || {
        weak.upgrade()
            .expect("coordinator alive")
            .cancel("main", "cancel-at-commit");
    }));
    assert!(harness
        .coordinator
        .confirm(
            "main",
            "cancel-at-commit",
            &pending.prepared.manifest_digest,
            true
        )
        .is_err());
    assert_eq!(harness.record(), original);
    assert!(!harness
        .root
        .0
        .join("plugins")
        .join(ID)
        .join(".staging-1.0.0")
        .exists());
    harness.assert_no_pending_files();
}

#[tokio::test]
async fn refreshing_a_source_invalidates_an_older_prepared_selection() {
    let bytes = archive("1.0.0", false);
    let harness = Harness::new(vec![
        (
            "/example/market-a/HEAD/index.json",
            vec![TestResponse::ok(index("1.0.0", &bytes, true, false))],
        ),
        (ARCHIVE_ONE, vec![TestResponse::ok(bytes)]),
    ]);
    harness.refresh().await;
    let prepared = harness
        .coordinator
        .prepare("main", "old-selection", "source-a", ID)
        .await
        .expect("prepare");
    harness.refresh().await;
    assert!(harness
        .coordinator
        .confirm(
            "main",
            "old-selection",
            &prepared.prepared.manifest_digest,
            true
        )
        .is_err());
    harness.assert_no_pending_files();
    assert!(!harness.root.0.join("plugins").exists());
}

#[test]
fn official_identity_requires_both_the_pinned_source_and_a_valid_publisher_signature() {
    use super::marketplace_sources::{OFFICIAL_INDEX_URL, OFFICIAL_SOURCE_ID};
    use super::signature;
    use base64::Engine;
    use ed25519_dalek::Signer;
    let signing = signature::rfc8032_signing_key_for_tests();
    signature::with_trusted_keys_for_tests(
        std::collections::BTreeMap::from([("lithe-test-v1".into(), signing.verifying_key())]),
        || {
            let root = TestRoot::new("marketplace-signed");
            let plain = root.0.join("plain.zip");
            std::fs::write(&plain, archive("1.0.0", false)).expect("plain archive");
            let package = root.0.join("package");
            install::extract_zip_snapshot(&plain, &package).expect("snapshot");
            let mut manifest: Value = serde_json::from_slice(
                &std::fs::read(package.join("plugin.json")).expect("manifest"),
            )
            .expect("JSON");
            manifest["vendor"]["signatureRequirement"] = json!("publisherPackage");
            std::fs::write(
                package.join("plugin.json"),
                serde_json::to_vec(&manifest).expect("manifest bytes"),
            )
            .expect("manifest write");
            let files = signature::file_digests(&package).expect("file digests");
            let signature_bytes = signing.sign(&signature::canonical_payload(
                "lithe-test-v1",
                ID,
                "1.0.0",
                &files,
            ));
            let document = signature::SignatureDocument {
                schema_version: 1,
                algorithm: "ed25519".into(),
                key_id: "lithe-test-v1".into(),
                plugin_id: ID.into(),
                plugin_version: "1.0.0".into(),
                files,
                signature: base64::engine::general_purpose::STANDARD
                    .encode(signature_bytes.to_bytes()),
            };
            std::fs::write(
                package.join(signature::SIGNATURE_FILE_NAME),
                serde_json::to_vec(&document).expect("signature JSON"),
            )
            .expect("signature write");
            let zip_package = |target: &Path| {
                let mut zip = zip::ZipWriter::new(std::fs::File::create(target).expect("zip"));
                for name in [
                    "plugin.json",
                    "language-server/bin/intelephense",
                    signature::SIGNATURE_FILE_NAME,
                ] {
                    zip.start_file(name, zip::write::SimpleFileOptions::default())
                        .expect("file");
                    zip.write_all(&std::fs::read(package.join(name)).expect("bytes"))
                        .expect("write");
                }
                zip.finish().expect("zip closes");
            };
            let signed = root.0.join("signed.zip");
            zip_package(&signed);
            let official = source(OFFICIAL_SOURCE_ID, OFFICIAL_INDEX_URL);
            assert!(super::marketplace_coordinator::official_source(&official));
            assert!(!super::marketplace_coordinator::official_source(&source(
                OFFICIAL_SOURCE_ID,
                INDEX_A
            )));
            let mut selection = install::MarketplaceInstallSource {
                source_id: official.id,
                source_name: official.name,
                index_url: official.index_url,
                repository: "https://github.com/example/lithe-fixture".into(),
                archive_url: format!("https://github.com{ARCHIVE_ONE}"),
                archive_sha256: format!(
                    "{:x}",
                    Sha256::digest(std::fs::read(&signed).expect("archive bytes"))
                ),
                plugin_id: ID.into(),
                version: "1.0.0".into(),
                official: true,
            };
            let temporary = root.0.join("plugin-temp");
            let prepared = install::prepare_marketplace_install_snapshot(
                &root.0.join("plugins"),
                &temporary,
                "lithe-plugin-disk-signed",
                &signed,
                &selection,
            )
            .expect("verified publisher");
            let candidate = install::confirm_marketplace_install_snapshot(
                &root.0.join("plugins"),
                &temporary,
                &prepared.session_id,
                &prepared.manifest_digest,
                &selection,
            )
            .expect("signed confirmation");
            assert_eq!(
                candidate.record.origin,
                Some(signature::InstallOrigin::Marketplace)
            );
            // A valid archive hash cannot bless a package with a broken signature.
            std::fs::write(
                package.join("language-server/bin/intelephense"),
                b"tampered",
            )
            .expect("tamper");
            zip_package(&signed);
            selection.archive_sha256 = format!(
                "{:x}",
                Sha256::digest(std::fs::read(&signed).expect("bad archive"))
            );
            assert!(install::prepare_marketplace_install_snapshot(
                &root.0.join("plugins"),
                &temporary,
                "lithe-plugin-disk-bad-signature",
                &signed,
                &selection
            )
            .is_err());
        },
    );
}

#[tokio::test]
async fn a_changed_snapshot_is_refused_and_its_session_is_discarded() {
    let bytes = archive("1.0.0", false);
    let harness = Harness::new(vec![
        (
            "/example/market-a/HEAD/index.json",
            vec![TestResponse::ok(index("1.0.0", &bytes, true, false))],
        ),
        (ARCHIVE_ONE, vec![TestResponse::ok(bytes)]),
    ]);
    harness.refresh().await;
    let prepared = harness
        .coordinator
        .prepare("main", "tamper", "source-a", ID)
        .await
        .expect("prepare");
    let snapshot = harness
        .root
        .0
        .join("plugin-temp")
        .join(&prepared.prepared.session_id);
    std::fs::write(
        snapshot.join("language-server/bin/intelephense"),
        b"changed",
    )
    .expect("mutate snapshot");
    assert!(harness
        .coordinator
        .confirm("main", "tamper", &prepared.prepared.manifest_digest, true)
        .is_err());
    harness.assert_no_pending_files();
    assert!(!harness.root.0.join("plugins").exists());
}

#[tokio::test]
async fn changing_installation_approval_after_prepare_requires_a_new_review() {
    let bytes = archive("1.0.0", false);
    let harness = Harness::new(vec![
        (
            "/example/market-a/HEAD/index.json",
            vec![TestResponse::ok(index("1.0.0", &bytes, true, false))],
        ),
        (ARCHIVE_ONE, vec![TestResponse::ok(bytes)]),
    ]);
    harness.refresh().await;
    let prepared = harness
        .coordinator
        .prepare("main", "first", "source-a", ID)
        .await
        .expect("prepare");
    harness
        .coordinator
        .confirm("main", "first", &prepared.prepared.manifest_digest, true)
        .expect("install");
    let pending = harness
        .coordinator
        .prepare("main", "pending", "source-a", ID)
        .await
        .expect("update review");
    let mut changed = harness.record();
    changed["enabled"] = json!(false);
    let path = harness
        .root
        .0
        .join("plugins")
        .join(ID)
        .join("installation.json");
    std::fs::write(&path, serde_json::to_vec(&changed).expect("record bytes"))
        .expect("change record");
    assert!(harness
        .coordinator
        .confirm("main", "pending", &pending.prepared.manifest_digest, true)
        .is_err());
    assert_eq!(harness.record(), changed);
    let fresh = harness
        .coordinator
        .prepare("main", "fresh", "source-a", ID)
        .await
        .expect("new review");
    harness
        .coordinator
        .confirm("main", "fresh", &fresh.prepared.manifest_digest, true)
        .expect("explicit approval of the fresh snapshot");
    assert_eq!(
        harness.record()["enabled"],
        false,
        "marketplace updates preserve a disabled installation"
    );
    harness.assert_no_pending_files();
}

#[tokio::test]
async fn removing_a_source_cancels_a_refresh_that_is_waiting_for_headers() {
    let bytes = archive("1.0.0", false);
    let (response, gate) =
        TestResponse::paused(index("1.0.0", &bytes, true, false), PauseAt::Headers);
    let harness = Harness::new(vec![("/example/market-a/HEAD/index.json", vec![response])]);
    let refresh = harness.coordinator.refresh("main", "pending", "source-a");
    tokio::pin!(refresh);
    tokio::select! {
        result = &mut refresh => panic!("index must be gated: {}", result.is_ok()),
        _ = gate.entered() => {}
    }
    harness
        .host
        .sources
        .lock()
        .expect("sources")
        .retain(|source| source.id != "source-a");
    harness.coordinator.cancel_source("source-a");
    assert!(tokio::time::timeout(Duration::from_secs(2), &mut refresh)
        .await
        .expect("cancel stops refresh")
        .is_err());
    assert!(!harness
        .root
        .0
        .join("indexes/source-a.windows-x64.json")
        .exists());
}

struct TestHost {
    sources: Mutex<Vec<MarketplaceSource>>,
    closed_windows: Mutex<std::collections::HashSet<String>>,
    before_commit: Mutex<Option<Box<dyn FnOnce() + Send>>>,
}
impl MarketplaceHost for TestHost {
    fn sources(&self) -> Result<Vec<MarketplaceSource>, String> {
        Ok(self.sources.lock().expect("sources").clone())
    }
    fn platform(&self) -> String {
        "windows-x64".into()
    }
    fn capabilities(&self) -> Value {
        super::host_capabilities()
    }
    fn ensure_window(&self, window: &str) -> Result<(), String> {
        if self
            .closed_windows
            .lock()
            .expect("window ownership")
            .contains(window)
        {
            return Err("the marketplace window was closed".into());
        }
        Ok(())
    }
    fn ensure_installable(&self, _id: &str) -> Result<(), String> {
        Ok(())
    }
    fn with_source(
        &self,
        source: &MarketplaceSource,
        publish: &mut dyn FnMut() -> Result<(), String>,
    ) -> Result<(), String> {
        let sources = self.sources.lock().expect("sources");
        if !sources
            .iter()
            .any(|current| current == source && current.is_enabled)
        {
            return Err("source changed".into());
        }
        if let Some(action) = self.before_commit.lock().expect("commit action").take() {
            action();
        }
        publish()
    }
}

/// Only test routing changes: the actual fetch policy, body budget, cancellation,
/// deadlines, digest verification and Core validation are production code.
struct LocalTransport {
    inner: ReqwestTransport,
    base: String,
}
impl HttpTransport for LocalTransport {
    fn get<'a>(
        &'a self,
        url: &'a str,
        max_bytes: u64,
        deadline: Instant,
        cancel: &'a CancelToken,
    ) -> Pin<Box<dyn Future<Output = Result<HttpResponse, FetchFailure>> + Send + 'a>> {
        Box::pin(async move {
            let parsed =
                url::Url::parse(url).map_err(|error| FetchFailure::Transport(error.to_string()))?;
            let local = format!("{}{}", self.base, parsed.path());
            self.inner.get(&local, max_bytes, deadline, cancel).await
        })
    }
}

fn fixture(name: &str) -> Value {
    let root =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../shared/contracts/plugins/v1/fixtures");
    serde_json::from_slice(&std::fs::read(root.join(name)).expect("fixture bytes"))
        .expect("fixture JSON")
}

fn archive(version: &str, changed_program: bool) -> Vec<u8> {
    archive_with_permissions(version, changed_program, &[])
}

fn archive_with_permissions(
    version: &str,
    changed_program: bool,
    extra_permissions: &[&str],
) -> Vec<u8> {
    let mut manifest = fixture("language-packaged-server.plugin.json");
    manifest["id"] = json!(ID);
    manifest["version"] = json!(version);
    manifest["vendor"]["signatureRequirement"] = json!("none");
    if changed_program {
        manifest["languageServers"][0]["arguments"] = json!(["--stdio", "--new-program-option"]);
    }
    manifest["permissions"]
        .as_array_mut()
        .expect("permission declarations")
        .extend(extra_permissions.iter().map(|permission| json!(permission)));
    let mut zip = zip::ZipWriter::new(Cursor::new(Vec::new()));
    for (name, bytes) in [
        (
            "plugin.json",
            serde_json::to_vec(&manifest).expect("manifest"),
        ),
        (
            "language-server/bin/intelephense",
            b"fixture, never executed".to_vec(),
        ),
    ] {
        zip.start_file(name, zip::write::SimpleFileOptions::default())
            .expect("zip file");
        zip.write_all(&bytes).expect("zip bytes");
    }
    zip.finish().expect("zip closes").into_inner()
}

fn index(version: &str, archive: &[u8], windows: bool, bad_digest: bool) -> Vec<u8> {
    let mut entry = fixture("marketplace/index.json")["plugins"][0].clone();
    entry["id"] = json!(ID);
    entry["repository"] = json!("https://github.com/example/lithe-fixture");
    entry["icon"] = json!("https://raw.githubusercontent.com/example/lithe-fixture/main/icon.png");
    entry["versions"] = json!([{
        "version": version, "pluginAPIVersion": 1, "releaseDate": "2026-10-25",
        "downloads": [{"platforms": [if windows { "windows-x64" } else { "darwin-arm64" }],
            "downloadURL": format!("https://github.com/example/lithe-fixture/releases/download/v{version}/fixture.zip"),
            "sha256": if bad_digest { "0".repeat(64) } else { format!("{:x}", Sha256::digest(archive)) }}]
    }]);
    serde_json::to_vec(&json!({"schemaVersion": 1, "plugins": [entry]})).expect("index")
}

fn source(id: &str, url: &str) -> MarketplaceSource {
    MarketplaceSource {
        id: id.into(),
        name: id.into(),
        input: url.into(),
        index_url: url.into(),
        repository: Some("https://github.com/example/lithe-fixture".into()),
        is_enabled: true,
    }
}

struct Harness {
    coordinator: Arc<MarketplaceCoordinator>,
    host: Arc<TestHost>,
    _server: TestHttpServer,
    root: TestRoot,
}
impl Harness {
    fn new(routes: Vec<(&'static str, Vec<TestResponse>)>) -> Self {
        let root = TestRoot::new("coordinator");
        let server = TestHttpServer::start(routes);
        let transport = LocalTransport {
            inner: ReqwestTransport::new().expect("transport"),
            base: server.base_url.clone(),
        };
        let host = Arc::new(TestHost {
            sources: Mutex::new(vec![
                source("source-a", INDEX_A),
                source("source-b", INDEX_B),
            ]),
            before_commit: Mutex::new(None),
            closed_windows: Mutex::new(std::collections::HashSet::new()),
        });
        let coordinator = Arc::new(MarketplaceCoordinator::new(
            host.clone(),
            Arc::new(transport),
            FetchPolicy::https_only(),
            root.0.join("indexes"),
            root.0.join("plugin-temp"),
            root.0.join("plugins"),
        ));
        Self {
            coordinator,
            host,
            _server: server,
            root,
        }
    }
    fn record(&self) -> Value {
        serde_json::from_slice(
            &std::fs::read(
                self.root
                    .0
                    .join("plugins")
                    .join(ID)
                    .join("installation.json"),
            )
            .expect("record"),
        )
        .expect("record JSON")
    }
    fn installation(&self, source_id: &str) -> Value {
        let listed =
            serde_json::to_value(self.coordinator.list().expect("market list")).expect("list JSON");
        listed
            .as_array()
            .expect("sources")
            .iter()
            .find(|source| source["sourceId"] == source_id)
            .expect("selected source")["installations"][ID]
            .clone()
    }
    fn assert_no_pending_files(&self) {
        let temporary = self.root.0.join("plugin-temp");
        if temporary.exists() {
            assert_eq!(
                std::fs::read_dir(temporary)
                    .expect("temporary root")
                    .count(),
                0
            );
        }
    }
    async fn refresh(&self) {
        self.coordinator
            .refresh("main", "refresh-a", "source-a")
            .await
            .expect("refresh source a");
    }
}

#[tokio::test]
async fn refresh_list_prepare_confirm_reuses_m1_and_records_the_exact_source() {
    let bytes = archive("1.0.0", false);
    let harness = Harness::new(vec![
        (
            "/example/market-a/HEAD/index.json",
            vec![TestResponse::ok(index("1.0.0", &bytes, true, false))],
        ),
        (ARCHIVE_ONE, vec![TestResponse::ok(bytes.clone())]),
    ]);
    harness.refresh().await;
    let listed = harness.coordinator.list().expect("offline list");
    assert!(listed
        .iter()
        .find(|source| source.source_id == "source-a")
        .expect("source")
        .index
        .is_some());
    let prepared = harness
        .coordinator
        .prepare("main", "prepare-a", "source-a", ID)
        .await
        .expect("prepare");
    assert!(prepared.requires_confirmation);
    assert!(!prepared.official_publisher_verified);
    assert!(!prepared.prepared.review.programs.is_empty());
    assert!(harness
        .coordinator
        .confirm(
            "workspace-other",
            "prepare-a",
            &prepared.prepared.manifest_digest,
            true
        )
        .is_err());
    let installed = harness
        .coordinator
        .confirm(
            "main",
            "prepare-a",
            &prepared.prepared.manifest_digest,
            true,
        )
        .expect("confirm");
    assert_eq!(installed.plugin_id, ID);
    let record = harness.record();
    assert!(record["disk"].is_null());
    assert_eq!(record["marketplace"]["sourceId"], "source-a");
    assert_eq!(record["marketplace"]["indexUrl"], INDEX_A);
    assert_eq!(
        record["marketplace"]["archiveSha256"],
        format!("{:x}", Sha256::digest(bytes))
    );
    assert!(record["marketplace"]["contentDigest"]
        .as_str()
        .is_some_and(|digest| digest.len() == 64));
    let catalog = super::scan::build_catalog_from(
        &harness.root.0.join("bundled"),
        &harness.root.0.join("plugins"),
    )
    .expect("production scan revalidates provenance");
    assert!(catalog
        .iter()
        .any(|package| package.entry.plugin_id == ID && package.entry.status == "accepted"));
    assert_eq!(harness.installation("source-a")["origin"], "marketplace");
    assert_eq!(harness.installation("source-a")["canPrepare"], true);
    harness.assert_no_pending_files();
}

#[tokio::test]
async fn same_id_from_another_source_cannot_take_over_an_installation() {
    let bytes = archive("1.0.0", false);
    let document = index("1.0.0", &bytes, true, false);
    let harness = Harness::new(vec![
        (
            "/example/market-a/HEAD/index.json",
            vec![TestResponse::ok(document.clone())],
        ),
        (
            "/example/market-b/HEAD/index.json",
            vec![TestResponse::ok(document)],
        ),
        (ARCHIVE_ONE, vec![TestResponse::ok(bytes)]),
    ]);
    harness.refresh().await;
    let prepared = harness
        .coordinator
        .prepare("main", "first", "source-a", ID)
        .await
        .expect("prepare");
    harness
        .coordinator
        .confirm("main", "first", &prepared.prepared.manifest_digest, true)
        .expect("install");
    let original = harness.record();
    harness
        .coordinator
        .refresh("main", "refresh-b", "source-b")
        .await
        .expect("refresh b");
    assert_eq!(harness.installation("source-b")["sourceId"], "source-a");
    assert_eq!(harness.installation("source-b")["canPrepare"], false);
    assert!(harness
        .coordinator
        .prepare("main", "wrong-source", "source-b", ID)
        .await
        .is_err());
    assert_eq!(harness.record(), original);
    harness.assert_no_pending_files();
}

#[tokio::test]
async fn disk_provenance_cannot_be_adopted_by_a_marketplace_listing() {
    let bytes = archive("1.0.0", false);
    let harness = Harness::new(vec![(
        "/example/market-a/HEAD/index.json",
        vec![TestResponse::ok(index("1.0.0", &bytes, true, false))],
    )]);
    let package = harness.root.0.join("disk.zip");
    std::fs::write(&package, bytes).expect("disk archive");
    let temporary = harness.root.0.join("disk-review");
    let prepared = install::prepare_disk_install_snapshot(
        &temporary,
        "lithe-plugin-disk-test",
        package.to_str().expect("path"),
    )
    .expect("disk review");
    let installed = install::confirm_disk_install_snapshot(
        &harness.root.0.join("plugins"),
        &temporary,
        &prepared.session_id,
        &prepared.manifest_digest,
    )
    .expect("disk confirm");
    install::publish_installed_version(
        &harness.root.0.join("plugins"),
        ID,
        "1.0.0",
        &temporary.join(&prepared.session_id),
        installed.record,
    )
    .expect("disk publish");
    let original = harness.record();
    harness.refresh().await;
    assert_eq!(harness.installation("source-a")["origin"], "disk");
    assert_eq!(harness.installation("source-a")["canPrepare"], false);
    assert!(harness
        .coordinator
        .prepare("main", "adopt", "source-a", ID)
        .await
        .is_err());
    assert_eq!(harness.record(), original);
    harness.assert_no_pending_files();
}

#[tokio::test]
async fn a_plugin_without_a_windows_archive_cannot_be_prepared() {
    let bytes = archive("1.0.0", false);
    let harness = Harness::new(vec![(
        "/example/market-a/HEAD/index.json",
        vec![TestResponse::ok(index("1.0.0", &bytes, false, false))],
    )]);
    harness.refresh().await;
    assert_eq!(harness.installation("source-a")["origin"], "none");
    assert_eq!(harness.installation("source-a")["canPrepare"], false);
    assert!(harness
        .coordinator
        .prepare("main", "no-windows", "source-a", ID)
        .await
        .is_err());
    harness.assert_no_pending_files();
    assert!(!harness.root.0.join("plugins").exists());
}

#[tokio::test]
async fn a_bad_archive_digest_never_reaches_the_install_snapshot() {
    let bytes = archive("1.0.0", false);
    let harness = Harness::new(vec![
        (
            "/example/market-a/HEAD/index.json",
            vec![TestResponse::ok(index("1.0.0", &bytes, true, true))],
        ),
        (ARCHIVE_ONE, vec![TestResponse::ok(bytes)]),
    ]);
    harness.refresh().await;
    assert!(harness
        .coordinator
        .prepare("main", "bad-digest", "source-a", ID)
        .await
        .is_err());
    harness.assert_no_pending_files();
    assert!(!harness.root.0.join("plugins").exists());
}

#[tokio::test]
async fn cancelling_an_in_flight_prepare_drops_late_results_and_all_downloads() {
    let bytes = archive("1.0.0", false);
    let (response, gate) = TestResponse::paused(bytes.clone(), PauseAt::Headers);
    let harness = Harness::new(vec![
        (
            "/example/market-a/HEAD/index.json",
            vec![TestResponse::ok(index("1.0.0", &bytes, true, false))],
        ),
        (ARCHIVE_ONE, vec![response]),
    ]);
    harness.refresh().await;
    let prepare = harness
        .coordinator
        .prepare("main", "pending", "source-a", ID);
    tokio::pin!(prepare);
    tokio::select! {
        result = &mut prepare => panic!("archive must be gated: {}", result.is_ok()),
        _ = gate.entered() => {}
    }
    harness.coordinator.cancel("workspace-other", "pending");
    assert!(harness
        .coordinator
        .pending_plugin("main", "pending")
        .is_ok());
    harness.coordinator.cancel("main", "pending");
    assert!(tokio::time::timeout(Duration::from_secs(2), &mut prepare)
        .await
        .expect("cancel terminates")
        .is_err());
    harness.assert_no_pending_files();
    assert!(!harness.root.0.join("plugins").exists());
}

#[tokio::test]
async fn window_close_source_disable_and_plugin_disable_discard_prepared_reviews() {
    let bytes = archive("1.0.0", false);
    let harness = Harness::new(vec![
        (
            "/example/market-a/HEAD/index.json",
            vec![TestResponse::ok(index("1.0.0", &bytes, true, false))],
        ),
        (ARCHIVE_ONE, vec![TestResponse::ok(bytes)]),
    ]);
    harness.refresh().await;
    for action in ["window", "source", "plugin"] {
        let owner = if action == "window" {
            "workspace-closing"
        } else {
            "main"
        };
        let prepared = harness
            .coordinator
            .prepare(owner, action, "source-a", ID)
            .await
            .expect("prepare");
        match action {
            "window" => harness.coordinator.cancel_window(owner),
            "source" => harness.coordinator.cancel_source("source-a"),
            _ => harness.coordinator.cancel_plugin(ID),
        }
        assert!(harness
            .coordinator
            .confirm(owner, action, &prepared.prepared.manifest_digest, true)
            .is_err());
        harness.assert_no_pending_files();
    }
    assert!(!harness.root.0.join("plugins").exists());
}

#[tokio::test]
async fn source_state_is_rechecked_at_confirmation_even_without_a_notification() {
    let bytes = archive("1.0.0", false);
    let harness = Harness::new(vec![
        (
            "/example/market-a/HEAD/index.json",
            vec![TestResponse::ok(index("1.0.0", &bytes, true, false))],
        ),
        (ARCHIVE_ONE, vec![TestResponse::ok(bytes)]),
    ]);
    harness.refresh().await;
    let prepared = harness
        .coordinator
        .prepare("main", "disabled", "source-a", ID)
        .await
        .expect("prepare");
    harness.host.sources.lock().expect("sources")[0].is_enabled = false;
    assert!(harness
        .coordinator
        .confirm("main", "disabled", &prepared.prepared.manifest_digest, true)
        .is_err());
    harness.assert_no_pending_files();
    assert!(!harness.root.0.join("plugins").exists());
}

#[tokio::test]
async fn every_marketplace_snapshot_requires_explicit_approval_including_unchanged_programs() {
    let first = archive("1.0.0", false);
    let changed = archive("1.1.0", true);
    let harness = Harness::new(vec![
        (
            "/example/market-a/HEAD/index.json",
            vec![
                TestResponse::ok(index("1.0.0", &first, true, false)),
                TestResponse::ok(index("1.1.0", &changed, true, false)),
            ],
        ),
        (ARCHIVE_ONE, vec![TestResponse::ok(first)]),
        (ARCHIVE_TWO, vec![TestResponse::ok(changed)]),
    ]);
    harness.refresh().await;
    let prepared = harness
        .coordinator
        .prepare("main", "first", "source-a", ID)
        .await
        .expect("first review");
    harness
        .coordinator
        .confirm("main", "first", &prepared.prepared.manifest_digest, true)
        .expect("first install");
    let repeat = harness
        .coordinator
        .prepare("main", "repeat", "source-a", ID)
        .await
        .expect("same programs");
    assert!(repeat.prepared.review.new_programs.is_empty());
    assert!(repeat.requires_confirmation);
    assert!(harness
        .coordinator
        .confirm("main", "repeat", &repeat.prepared.manifest_digest, false)
        .is_err());
    let repeat_approved = harness
        .coordinator
        .prepare("main", "repeat-approved", "source-a", ID)
        .await
        .expect("fresh explicit review");
    harness
        .coordinator
        .confirm(
            "main",
            "repeat-approved",
            &repeat_approved.prepared.manifest_digest,
            true,
        )
        .expect("explicit approval of unchanged programs");
    let original = harness.record();
    harness.refresh().await;
    let new = harness
        .coordinator
        .prepare("main", "new-programs", "source-a", ID)
        .await
        .expect("changed review");
    assert!(!new.prepared.review.new_programs.is_empty());
    assert!(new.requires_confirmation);
    assert!(harness
        .coordinator
        .confirm("main", "new-programs", &new.prepared.manifest_digest, false)
        .is_err());
    assert_eq!(harness.record(), original);
    let approved = harness
        .coordinator
        .prepare("main", "approved", "source-a", ID)
        .await
        .expect("new review");
    harness
        .coordinator
        .confirm("main", "approved", &approved.prepared.manifest_digest, true)
        .expect("explicit approval");
    assert_eq!(harness.record()["version"], "1.1.0");
    assert_eq!(harness.record()["previousVersion"], "1.0.0");
    harness.assert_no_pending_files();
}

#[tokio::test]
async fn permission_only_expansion_cannot_reuse_program_approvals_to_skip_consent() {
    // Core's program identity deliberately excludes permission grants. Keeping
    // every executable/argument unchanged must not silently approve ui.web.
    let first = archive("1.0.0", false);
    let expanded = archive_with_permissions("1.1.0", false, &["ui.contribute", "ui.web"]);
    let harness = Harness::new(vec![
        (
            "/example/market-a/HEAD/index.json",
            vec![
                TestResponse::ok(index("1.0.0", &first, true, false)),
                TestResponse::ok(index("1.1.0", &expanded, true, false)),
            ],
        ),
        (ARCHIVE_ONE, vec![TestResponse::ok(first)]),
        (ARCHIVE_TWO, vec![TestResponse::ok(expanded)]),
    ]);
    harness.refresh().await;
    let first = harness
        .coordinator
        .prepare("main", "original", "source-a", ID)
        .await
        .expect("initial snapshot");
    harness
        .coordinator
        .confirm("main", "original", &first.prepared.manifest_digest, true)
        .expect("initial approval");
    let original = harness.record();
    harness.refresh().await;
    let expanded = harness
        .coordinator
        .prepare("main", "permission-only", "source-a", ID)
        .await
        .expect("expanded permission snapshot");
    assert!(expanded.prepared.review.new_programs.is_empty());
    assert!(expanded
        .prepared
        .review
        .permissions
        .iter()
        .any(|permission| permission == "ui.web"));
    assert!(expanded.requires_confirmation);
    assert!(harness
        .coordinator
        .confirm(
            "main",
            "permission-only",
            &expanded.prepared.manifest_digest,
            false,
        )
        .is_err());
    assert_eq!(harness.record(), original);
    harness.assert_no_pending_files();
}
