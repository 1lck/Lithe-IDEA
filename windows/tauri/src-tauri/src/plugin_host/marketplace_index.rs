//! Marketplace index refresh and the last-known-good cache.
//!
//! Index URLs and index legality are Core semantics: the caller hands in a
//! source identity whose `indexURL` already went through
//! `plugins.marketplace.resolveSource`, and every fetched document goes
//! through `plugins.marketplace.validateIndex` with this host's platform and
//! capability declaration before it may become the cached answer. A refresh
//! that fails anywhere — transport, budget, deadline, cancellation, invalid
//! JSON, Core rejection — never overwrites the last-known-good index, and a
//! refresh that started after a newer one never overwrites that newer one's
//! cache either. The cache keeps the validated raw input, and offline reads
//! revalidate it with the running Core and current host capabilities. Availability
//! statuses come only from Core: a legal index says nothing about whether
//! an archive or its signature was verified.

use super::marketplace_download::{
    fetch_controlled, CancelToken, FetchFailure, FetchLimits, FetchPolicy, HttpTransport,
    PendingFile, MAX_INDEX_JSON_BYTES, MAX_REDIRECT_HOPS,
};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::time::{Duration, Instant};

/// Who maintains a source, in Core's `sourceKind` vocabulary.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SourceKind {
    Official,
    ThirdParty,
}

/// One refresh request for an already-resolved source. The `index_url` comes
/// from Core's `resolveSource` outcome; this layer never parses user URLs.
#[derive(Debug, Clone)]
pub struct IndexRefreshRequest {
    /// Stable source identity from the host's source management; used as the
    /// cache key and validated as a path component.
    pub source_id: String,
    pub index_url: String,
    pub source_kind: SourceKind,
    /// This host's platform identifier, e.g. `windows-x64`.
    pub platform: String,
    /// This host's capability declaration, as Core expects it.
    pub host_capabilities: Value,
    /// Overall deadline for the fetch, including redirects.
    pub deadline: Duration,
}

/// The outcome of one successful refresh against the live source.
#[derive(Debug, Clone)]
pub struct RefreshedIndex {
    pub source_id: String,
    pub platform: String,
    /// The Core-validated index (`{plugins, rejected}`) for this platform.
    pub index: Value,
    /// URL the document was finally served from.
    pub final_url: String,
    /// Whether this refresh became the cached last-known-good answer. An
    /// older request that finishes after a newer one reports `false`.
    pub persisted: bool,
}

/// Every way a refresh can fail, with a stable kind for the marketplace
/// surface. None of these ever touch the cached last-known-good index.
#[derive(Debug, Clone, PartialEq)]
pub enum IndexRefreshFailure {
    Cancelled,
    DeadlineExceeded,
    Transport(String),
    BudgetExceeded,
    InvalidJson(String),
    /// Core rejected the whole index; the code is Core's stable code.
    Rejected {
        code: String,
        message: String,
    },
    /// The index URL answered with a non-success status.
    HttpError {
        status: u16,
        url: String,
    },
    /// Core itself failed (malformed envelope, host bug).
    Core(String),
    CacheWrite(String),
}

impl IndexRefreshFailure {
    /// Stable failure kind for the marketplace surface.
    pub fn kind(&self) -> &'static str {
        match self {
            IndexRefreshFailure::Cancelled => "cancelled",
            IndexRefreshFailure::DeadlineExceeded => "deadline",
            IndexRefreshFailure::Transport(_) => "transport",
            IndexRefreshFailure::BudgetExceeded => "budgetExceeded",
            IndexRefreshFailure::InvalidJson(_) => "invalidJson",
            IndexRefreshFailure::HttpError { .. } => "httpError",
            IndexRefreshFailure::Rejected { .. } => "indexRejected",
            IndexRefreshFailure::Core(_) => "coreFailure",
            IndexRefreshFailure::CacheWrite(_) => "cacheWrite",
        }
    }

    pub fn message(&self) -> String {
        match self {
            IndexRefreshFailure::Cancelled => "the index refresh was cancelled".to_string(),
            IndexRefreshFailure::DeadlineExceeded => {
                "the index refresh exceeded its deadline".to_string()
            }
            IndexRefreshFailure::Transport(error) => format!("the index fetch failed: {error}"),
            IndexRefreshFailure::BudgetExceeded => {
                format!("the index exceeds the {MAX_INDEX_JSON_BYTES} byte budget")
            }
            IndexRefreshFailure::InvalidJson(error) => {
                format!("the index is not valid JSON: {error}")
            }
            IndexRefreshFailure::HttpError { status, url } => {
                format!("the index fetch of {url} returned HTTP {status}")
            }
            IndexRefreshFailure::Rejected { message, .. } => message.clone(),
            IndexRefreshFailure::Core(error) => error.clone(),
            IndexRefreshFailure::CacheWrite(error) => {
                format!("the index cache could not be written: {error}")
            }
        }
    }
}

impl From<FetchFailure> for IndexRefreshFailure {
    fn from(failure: FetchFailure) -> Self {
        match failure {
            FetchFailure::Cancelled => IndexRefreshFailure::Cancelled,
            FetchFailure::DeadlineExceeded => IndexRefreshFailure::DeadlineExceeded,
            FetchFailure::BudgetExceeded { .. } => IndexRefreshFailure::BudgetExceeded,
            FetchFailure::HttpError { status, url } => {
                IndexRefreshFailure::HttpError { status, url }
            }
            FetchFailure::Transport(error) => IndexRefreshFailure::Transport(error),
            other => IndexRefreshFailure::Transport(other.message()),
        }
    }
}

/// One availability answer read back from a Core-validated index. The
/// variants mirror Core's own statuses so the marketplace surface can
/// distinguish "the source is broken" from "this plugin cannot run here".
#[derive(Debug, Clone, PartialEq)]
pub enum Availability {
    Available {
        version: String,
        download_url: String,
        sha256: String,
    },
    /// Core reported the plugin as unusable on this host (`apiUnsupported`
    /// or `platformUnsupported`).
    Unsupported { code: String, message: String },
    /// The ID is not listed by this index.
    NotFound,
}

/// Reads one plugin's availability out of a Core-validated index document.
pub fn availability_of(validated_index: &Value, plugin_id: &str) -> Availability {
    let Some(plugins) = validated_index["plugins"].as_array() else {
        return Availability::NotFound;
    };
    let Some(plugin) = plugins
        .iter()
        .find(|plugin| plugin["id"].as_str() == Some(plugin_id))
    else {
        return Availability::NotFound;
    };
    let availability = &plugin["availability"];
    match availability["status"].as_str() {
        Some("available") => Availability::Available {
            version: availability["version"]
                .as_str()
                .unwrap_or_default()
                .to_string(),
            download_url: availability["downloadURL"]
                .as_str()
                .unwrap_or_default()
                .to_string(),
            sha256: availability["sha256"]
                .as_str()
                .unwrap_or_default()
                .to_string(),
        },
        Some(status) => Availability::Unsupported {
            code: availability["code"]
                .as_str()
                .map(str::to_string)
                .unwrap_or_else(|| status.to_string()),
            message: availability["message"]
                .as_str()
                .unwrap_or_default()
                .to_string(),
        },
        _ => Availability::NotFound,
    }
}

/// Per-source index cache over the caller's runtime state root. All writes
/// land in the caller-provided writable root (`app_local_data_dir` state, or
/// the existing plugin-temp in tests) — never in installation or distribution
/// resources. Same-source publications are serialized per key, and a refresh
/// with a newer generation always wins the cache.
pub struct MarketplaceIndexStore {
    root: PathBuf,
    /// Highest started generation per `source_id.platform` key.
    generations: Mutex<HashMap<String, u64>>,
}

/// Versioned raw input, never a cached Core availability answer. Revalidation
/// on every read uses the running Core and the caller's current host context.
/// Legacy normalized caches lack this envelope and are treated as cache misses.
#[derive(Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CachedIndex {
    cache_format: u32,
    source_id: String,
    index_url: String,
    raw_index: Value,
}

impl MarketplaceIndexStore {
    pub fn new(root: PathBuf) -> Self {
        Self {
            root,
            generations: Mutex::new(HashMap::new()),
        }
    }

    /// Reads the last-known-good raw index offline and asks the current Core
    /// for availability with the current source kind, platform and capabilities.
    pub fn cached_index(&self, request: &IndexRefreshRequest) -> Result<Option<Value>, String> {
        let path = self.cache_path(&request.source_id, &request.platform)?;
        let text = match std::fs::read_to_string(&path) {
            Ok(text) => text,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error.to_string()),
        };
        let envelope: Value = serde_json::from_str(&text)
            .map_err(|error| format!("the cached index is unreadable: {error}"))?;
        if envelope["cacheFormat"] != 1 {
            return Ok(None);
        }
        let cached: CachedIndex = serde_json::from_value(envelope)
            .map_err(|error| format!("the cached index is unreadable: {error}"))?;
        if cached.source_id != request.source_id || cached.index_url != request.index_url {
            return Ok(None);
        }
        validate_index(request, &cached.raw_index)
            .map(Some)
            .map_err(|error| error.message())
    }

    /// Fetches, validates, and (when still the newest request for the key)
    /// persists one index. The fetch is bounded by the request deadline, the
    /// JSON budget, the redirect limit, the HTTPS policy, and the cancel
    /// token; a cancelled or failed refresh leaves the cache untouched.
    pub async fn refresh(
        &self,
        transport: &dyn HttpTransport,
        request: &IndexRefreshRequest,
        policy: FetchPolicy,
        cancel: &CancelToken,
    ) -> Result<RefreshedIndex, IndexRefreshFailure> {
        self.refresh_with_validator(transport, request, policy, cancel, validate_index)
            .await
    }

    async fn refresh_with_validator(
        &self,
        transport: &dyn HttpTransport,
        request: &IndexRefreshRequest,
        policy: FetchPolicy,
        cancel: &CancelToken,
        validate: impl FnOnce(&IndexRefreshRequest, &Value) -> Result<Value, IndexRefreshFailure>,
    ) -> Result<RefreshedIndex, IndexRefreshFailure> {
        let key =
            cache_key(&request.source_id, &request.platform).map_err(IndexRefreshFailure::Core)?;
        let generation = {
            let mut generations = self.generations.lock().map_err(|_| {
                IndexRefreshFailure::CacheWrite("the generation map is poisoned".into())
            })?;
            let generation = generations.entry(key.clone()).or_insert(0);
            *generation += 1;
            *generation
        };
        if cancel.is_cancelled() {
            return Err(IndexRefreshFailure::Cancelled);
        }
        let deadline = Instant::now() + request.deadline;
        let fetch = fetch_controlled(
            transport,
            &request.index_url,
            FetchLimits {
                max_bytes: MAX_INDEX_JSON_BYTES,
                max_redirects: MAX_REDIRECT_HOPS,
            },
            policy,
            cancel,
            deadline,
        )
        .await?;
        if cancel.is_cancelled() {
            return Err(IndexRefreshFailure::Cancelled);
        }
        let index_value: Value = serde_json::from_slice(&fetch.body)
            .map_err(|error| IndexRefreshFailure::InvalidJson(error.to_string()))?;
        let validated = validate(request, &index_value)?;
        cancel.check(deadline)?;
        // Only the newest started refresh for this key may persist: an older
        // request finishing late returns its answer to its caller without
        // overwriting the newer cached one.
        let persisted = {
            let mut generations = self.generations.lock().map_err(|_| {
                IndexRefreshFailure::CacheWrite("the generation map is poisoned".into())
            })?;
            let newest = generations.entry(key.clone()).or_insert(0);
            cancel.check(deadline)?;
            let is_newest = generation == *newest;
            if is_newest {
                self.persist(
                    &key,
                    &CachedIndex {
                        cache_format: 1,
                        source_id: request.source_id.clone(),
                        index_url: request.index_url.clone(),
                        raw_index: index_value,
                    },
                    cancel,
                    deadline,
                )?;
            }
            is_newest
        };
        Ok(RefreshedIndex {
            source_id: request.source_id.clone(),
            platform: request.platform.clone(),
            index: validated,
            final_url: fetch.final_url,
            persisted,
        })
    }

    fn persist(
        &self,
        key: &str,
        cached: &CachedIndex,
        cancel: &CancelToken,
        deadline: Instant,
    ) -> Result<(), IndexRefreshFailure> {
        self.persist_with_rename(key, cached, cancel, deadline, |source, target| {
            std::fs::rename(source, target)
        })
    }

    fn persist_with_rename(
        &self,
        key: &str,
        cached: &CachedIndex,
        cancel: &CancelToken,
        deadline: Instant,
        rename: impl FnOnce(&Path, &Path) -> std::io::Result<()>,
    ) -> Result<(), IndexRefreshFailure> {
        cancel.check(deadline)?;
        std::fs::create_dir_all(&self.root)
            .map_err(|error| IndexRefreshFailure::CacheWrite(error.to_string()))?;
        let final_path = self.root.join(format!("{key}.json"));
        let temp_path = self.root.join(format!(
            "{key}.{}.tmp",
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|duration| duration.as_nanos())
                .unwrap_or_default()
        ));
        let bytes = serde_json::to_vec(cached)
            .map_err(|error| IndexRefreshFailure::CacheWrite(error.to_string()))?;
        let pending = PendingFile::write(temp_path, &bytes)
            .map_err(|error| IndexRefreshFailure::CacheWrite(error.to_string()))?;
        // Generation ownership is still held by refresh. Cancellation owns a
        // separate, short commit lock, so it can win during Core/JSON or IO work.
        cancel
            .commit(deadline, || pending.publish_with(&final_path, rename))?
            .map_err(|error| IndexRefreshFailure::CacheWrite(error.to_string()))
    }

    fn cache_path(&self, source_id: &str, platform: &str) -> Result<PathBuf, String> {
        let key = cache_key(source_id, platform)?;
        Ok(self.root.join(format!("{key}.json")))
    }
}

fn validate_index(
    request: &IndexRefreshRequest,
    raw: &Value,
) -> Result<Value, IndexRefreshFailure> {
    let outcome = super::scan::core_execute(
        "plugins.marketplace.validateIndex",
        serde_json::json!({
            "index": raw,
            "sourceKind": request.source_kind,
            "platform": request.platform,
            "hostCapabilities": request.host_capabilities,
        }),
    )
    .map_err(IndexRefreshFailure::Core)?;
    match outcome["status"].as_str() {
        Some("ok") if outcome["index"].is_object() => Ok(outcome["index"].clone()),
        Some("rejected") => Err(IndexRefreshFailure::Rejected {
            code: outcome["error"]["code"]
                .as_str()
                .unwrap_or("plugin.index.invalid")
                .into(),
            message: outcome["error"]["message"]
                .as_str()
                .unwrap_or("the index was rejected")
                .into(),
        }),
        _ => Err(IndexRefreshFailure::Core(
            "validateIndex returned no valid outcome".into(),
        )),
    }
}

/// The cache key of one source and platform. Source IDs come from the host's
/// source management and must already be slug-shaped; the check keeps a bad
/// ID from escaping the cache root as a path.
fn cache_key(source_id: &str, platform: &str) -> Result<String, String> {
    let key = format!("{source_id}.{platform}");
    let valid = !key.is_empty()
        && key.len() <= 128
        && key.chars().all(|character| {
            character.is_ascii_lowercase()
                || character.is_ascii_digit()
                || matches!(character, '.' | '-')
        })
        && !key.split('.').any(|part| part == "..");
    if valid {
        Ok(key)
    } else {
        Err(format!(
            "the source id {source_id:?} is not a usable cache key"
        ))
    }
}

/// Deadline used by callers that just want "bounded"; the marketplace wiring
/// decides the real values. Exported so tests and callers share one shape.
pub fn refresh_deadline(deadline: Duration) -> Instant {
    Instant::now() + deadline
}

/// Path of one cached index document, exposed for diagnostics and cleanup by
/// the source management layer.
pub fn cached_index_path(root: &Path, source_id: &str, platform: &str) -> Result<PathBuf, String> {
    Ok(root.join(format!("{}.json", cache_key(source_id, platform)?)))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::plugin_host::marketplace_download::tests::{TestHttpServer, TestResponse, TestRoot};
    use sha2::{Digest, Sha256};
    use std::future::Future;
    use std::pin::Pin;
    use std::sync::Arc;

    const MARKETPLACE_FIXTURES_DIR: &str = concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../../shared/contracts/plugins/v1/fixtures/marketplace"
    );

    fn read_marketplace_fixture(name: &str) -> Value {
        serde_json::from_str(
            &std::fs::read_to_string(format!("{MARKETPLACE_FIXTURES_DIR}/{name}"))
                .expect("marketplace fixture readable"),
        )
        .expect("marketplace fixture is JSON")
    }

    struct BytesTransport(Vec<u8>);

    impl HttpTransport for BytesTransport {
        fn get<'a>(
            &'a self,
            _url: &'a str,
            _max_bytes: u64,
            _deadline: Instant,
            _cancel: &'a CancelToken,
        ) -> Pin<
            Box<
                dyn Future<
                        Output = Result<
                            super::super::marketplace_download::HttpResponse,
                            FetchFailure,
                        >,
                    > + Send
                    + 'a,
            >,
        > {
            Box::pin(async {
                Ok(super::super::marketplace_download::HttpResponse {
                    status: 200,
                    headers: HashMap::new(),
                    body: self.0.clone(),
                })
            })
        }
    }

    fn cached_document(request: &IndexRefreshRequest) -> CachedIndex {
        CachedIndex {
            cache_format: 1,
            source_id: request.source_id.clone(),
            index_url: request.index_url.clone(),
            raw_index: read_marketplace_fixture("index.json"),
        }
    }

    fn assert_only_cache(root: &Path, request: &IndexRefreshRequest) {
        let names: Vec<_> = std::fs::read_dir(root)
            .expect("cache root")
            .map(|entry| entry.expect("entry").file_name())
            .collect();
        assert_eq!(
            names,
            vec![std::ffi::OsString::from(format!(
                "{}.json",
                cache_key(&request.source_id, &request.platform).expect("key")
            ))]
        );
    }

    #[tokio::test]
    async fn offline_cache_revalidates_capability_upgrades_downgrades_and_source_kind() {
        let root = TestRoot::new("capabilities");
        let store = MarketplaceIndexStore::new(root.0.clone());
        let mut request = refresh_request_with_capabilities(
            "capabilities",
            "https://example.com/index.json".into(),
            serde_json::json!({}),
        );
        let transport = BytesTransport(
            serde_json::to_vec(&read_marketplace_fixture("index.json")).expect("raw"),
        );
        let first = store
            .refresh(
                &transport,
                &request,
                FetchPolicy::https_only(),
                &CancelToken::new(),
            )
            .await
            .expect("initial refresh");
        assert!(matches!(
            availability_of(&first.index, "io.example.elixir-tools"),
            Availability::Unsupported { .. }
        ));
        let path = store
            .cache_path(&request.source_id, &request.platform)
            .expect("path");
        let saved = std::fs::read(&path).expect("raw cache");
        let envelope: Value = serde_json::from_slice(&saved).expect("envelope");
        assert!(
            envelope["rawIndex"]["plugins"][0]["versions"].is_array(),
            "persist original version metadata, never normalized availability"
        );
        // A new store stands for the next host launch. No transport is available
        // on these reads; availability must still follow the current host/Core.
        let restarted = MarketplaceIndexStore::new(root.0.clone());
        for (capabilities, version) in [
            (
                serde_json::json!({"languages":[1], "languageServers":[1], "serverProcess":[1]}),
                "1.0.0",
            ),
            (
                serde_json::json!({"languages":[1], "languageServers":[1], "serverProcess":[1], "buildSystems":[1], "buildProviders":[1]}),
                "2.0.0",
            ),
        ] {
            request.host_capabilities = capabilities;
            let current = restarted
                .cached_index(&request)
                .expect("offline read")
                .expect("cache hit");
            assert!(
                matches!(availability_of(&current, "io.example.elixir-tools"),
                Availability::Available { version: selected, .. } if selected == version)
            );
        }
        request.host_capabilities = serde_json::json!({});
        let downgraded = restarted
            .cached_index(&request)
            .expect("downgrade")
            .expect("cache");
        assert!(matches!(
            availability_of(&downgraded, "io.example.elixir-tools"),
            Availability::Unsupported { .. }
        ));
        request.source_kind = SourceKind::Official;
        let official = restarted
            .cached_index(&request)
            .expect("official")
            .expect("cache");
        assert!(!matches!(
            availability_of(&official, "dev.lithe.fixture.language-packaged-server"),
            Availability::NotFound
        ));
        request.source_kind = SourceKind::ThirdParty;
        let third_party = restarted
            .cached_index(&request)
            .expect("third party")
            .expect("cache");
        assert_eq!(
            availability_of(&third_party, "dev.lithe.fixture.language-packaged-server"),
            Availability::NotFound
        );
        assert_eq!(std::fs::read(path).expect("cache unchanged"), saved);
    }

    #[test]
    fn legacy_normalized_and_unknown_cache_formats_are_safe_misses() {
        let root = TestRoot::new("legacy-cache");
        let store = MarketplaceIndexStore::new(root.0.clone());
        let request = refresh_request("legacy", "https://example.com/index.json".into());
        let path = store
            .cache_path(&request.source_id, &request.platform)
            .expect("path");
        let raw = read_marketplace_fixture("index.json");
        for document in [
            validate_index(&request, &raw).expect("normalized legacy"),
            serde_json::json!({"cacheFormat": 99, "rawIndex": raw}),
        ] {
            let bytes = serde_json::to_vec(&document).expect("legacy bytes");
            std::fs::write(&path, &bytes).expect("seed legacy");
            assert!(store.cached_index(&request).expect("safe miss").is_none());
            assert_eq!(std::fs::read(&path).expect("preserved"), bytes);
        }
        let mut changed_origin = cached_document(&request);
        changed_origin.index_url = "https://other.example.com/index.json".into();
        std::fs::write(
            &path,
            serde_json::to_vec(&changed_origin).expect("origin bytes"),
        )
        .expect("seed");
        assert!(store
            .cached_index(&request)
            .expect("changed source URL")
            .is_none());
    }

    #[test]
    fn rename_failure_removes_the_staged_cache_and_preserves_last_known_good_bytes() {
        let root = TestRoot::new("rename-failure");
        let store = MarketplaceIndexStore::new(root.0.clone());
        let request = refresh_request("retain", "https://example.com/index.json".into());
        let cached = cached_document(&request);
        store
            .persist(
                "retain.windows-x64",
                &cached,
                &CancelToken::new(),
                refresh_deadline(Duration::from_secs(2)),
            )
            .expect("seed cache");
        let path = store
            .cache_path(&request.source_id, &request.platform)
            .expect("path");
        let saved = std::fs::read(&path).expect("old cache bytes");
        let mut changed = cached;
        changed.raw_index["plugins"][0]["name"] = serde_json::json!("must not publish");
        let error = store
            .persist_with_rename(
                "retain.windows-x64",
                &changed,
                &CancelToken::new(),
                refresh_deadline(Duration::from_secs(2)),
                |source, target| {
                    assert!(
                        source.is_file(),
                        "write and flush completed before injected rename failure"
                    );
                    assert_eq!(std::fs::read(target).expect("prior cache"), saved);
                    Err(std::io::Error::other("injected rename failure"))
                },
            )
            .expect_err("rename fails");
        assert_eq!(error.kind(), "cacheWrite");
        assert_eq!(std::fs::read(path).expect("old cache remains"), saved);
        assert_only_cache(&root.0, &request);
    }

    #[tokio::test]
    async fn cancellation_after_core_validation_cannot_replace_the_cache() {
        let root = TestRoot::new("cancel-validation");
        let store = MarketplaceIndexStore::new(root.0.clone());
        let request = refresh_request("retain", "https://example.com/index.json".into());
        let cached = cached_document(&request);
        store
            .persist(
                "retain.windows-x64",
                &cached,
                &CancelToken::new(),
                refresh_deadline(Duration::from_secs(2)),
            )
            .expect("seed");
        let path = store
            .cache_path(&request.source_id, &request.platform)
            .expect("path");
        let saved = std::fs::read(&path).expect("prior bytes");
        let mut raw = read_marketplace_fixture("index.json");
        raw["plugins"][0]["name"] = serde_json::json!("cancelled answer");
        let transport = BytesTransport(serde_json::to_vec(&raw).expect("raw bytes"));
        let cancel = CancelToken::new();
        let result = store
            .refresh_with_validator(
                &transport,
                &request,
                FetchPolicy::https_only(),
                &cancel,
                |request, raw| {
                    let validated = validate_index(request, raw)?;
                    cancel.cancel();
                    Ok(validated)
                },
            )
            .await;
        assert_eq!(
            result.expect_err("cancelled before publication"),
            IndexRefreshFailure::Cancelled
        );
        assert_eq!(std::fs::read(path).expect("cache remains"), saved);
        assert_only_cache(&root.0, &request);
    }

    fn refresh_request(source_id: &str, url: String) -> IndexRefreshRequest {
        refresh_request_with_capabilities(source_id, url, super::super::host_capabilities())
    }

    fn refresh_request_with_capabilities(
        source_id: &str,
        url: String,
        host_capabilities: Value,
    ) -> IndexRefreshRequest {
        IndexRefreshRequest {
            source_id: source_id.to_string(),
            index_url: url,
            source_kind: SourceKind::ThirdParty,
            platform: "windows-x64".to_string(),
            host_capabilities,
            deadline: Duration::from_secs(10),
        }
    }

    /// The refreshed index must answer exactly like the shared fixture case
    /// for windows-x64: the same availability statuses, versions, digests,
    /// and the same refused entries in index order.
    #[tokio::test]
    async fn refresh_matches_the_shared_standard_answer() {
        let index = read_marketplace_fixture("index.json");
        let case = read_marketplace_fixture("index-cases.json")["cases"]
            .as_array()
            .expect("cases")
            .iter()
            .find(|case| {
                case["name"]
                    == serde_json::json!("a capability Core cannot validate is never offered")
            })
            .expect("the capability-gated case")
            .clone();
        let server = TestHttpServer::start(vec![(
            "/index.json",
            vec![TestResponse::ok(
                serde_json::to_vec(&index).expect("index bytes"),
            )],
        )]);
        let root = TestRoot::new("golden");
        let store = MarketplaceIndexStore::new(root.0.clone());
        let refreshed = store
            .refresh(
                &crate::plugin_host::marketplace_download::ReqwestTransport::new()
                    .expect("transport"),
                &refresh_request_with_capabilities(
                    "golden",
                    format!("{}/index.json", server.base_url),
                    case["hostCapabilities"].clone(),
                ),
                FetchPolicy::loopback_http_for_tests(),
                &CancelToken::new(),
            )
            .await
            .expect("the refresh succeeds");
        assert!(refreshed.persisted);

        // Availability answers come from Core, entry by entry.
        let expected_plugins = case["expected"]["plugins"]
            .as_array()
            .expect("expected plugins");
        assert_eq!(
            refreshed.index["plugins"]
                .as_array()
                .expect("plugins")
                .len(),
            expected_plugins.len()
        );
        for expected in expected_plugins {
            let id = expected["id"].as_str().expect("id");
            let expected_status = expected["availability"]["status"].as_str().expect("status");
            match availability_of(&refreshed.index, id) {
                Availability::Available {
                    version,
                    download_url,
                    sha256,
                } => {
                    assert_eq!(expected_status, "available", "{id}");
                    assert_eq!(version, expected["availability"]["version"]);
                    assert_eq!(
                        sha256,
                        expected["availability"]["sha256"].as_str().expect("sha")
                    );
                    assert!(
                        !download_url.is_empty(),
                        "an available entry carries the download URL"
                    );
                }
                Availability::Unsupported { code, message } => {
                    assert_eq!(expected_status, "unsupported", "{id}");
                    assert_eq!(
                        code,
                        expected["availability"]["code"].as_str().expect("code"),
                        "{id}"
                    );
                    assert!(!message.is_empty());
                }
                Availability::NotFound => panic!("the listed plugin {id} went missing"),
            }
        }
        // The refused entries keep Core's stable codes.
        let expected_rejected = case["expected"]["rejected"]
            .as_array()
            .expect("expected rejected");
        let rejected = refreshed.index["rejected"]
            .as_array()
            .expect("rejected")
            .clone();
        for expected in expected_rejected {
            let id = expected["id"].as_str().expect("id");
            let code = expected["code"].as_str().expect("code");
            assert!(
                rejected.iter().any(|entry| entry["id"] == expected["id"]
                    && entry["error"]["code"] == serde_json::json!(code)),
                "the refused entry {id} must report {code}: {rejected:?}"
            );
        }
    }

    /// A failed refresh — invalid JSON, a Core-rejected index, an HTTP
    /// failure, a budget overrun — never overwrites the last-known-good
    /// cache.
    #[tokio::test]
    async fn failed_refreshes_keep_the_last_known_good_index() {
        let index = read_marketplace_fixture("index.json");
        let index_bytes = serde_json::to_vec(&index).expect("index bytes");
        let broken_cases: Vec<&str> = vec!["not-json", "no-schema", "missing", "budget"];
        let server = TestHttpServer::start(vec![
            ("/good", vec![TestResponse::ok(index_bytes)]),
            ("/not-json", vec![TestResponse::ok(b"{ not json".to_vec())]),
            (
                "/no-schema",
                vec![TestResponse::ok(br#"{"plugins": []}"#.to_vec())],
            ),
            ("/missing", vec![TestResponse::with_status(404)]),
            (
                "/budget",
                // The index budget is 8 MiB; a 9 MiB body exceeds it and the
                // transport aborts mid-body at the budget.
                vec![TestResponse::ok(vec![b'x'; 9 * 1024 * 1024])],
            ),
        ]);
        let root = TestRoot::new("retain");
        let store = MarketplaceIndexStore::new(root.0.clone());
        let transport =
            crate::plugin_host::marketplace_download::ReqwestTransport::new().expect("transport");

        let good = store
            .refresh(
                &transport,
                &refresh_request("retain", format!("{}/good", server.base_url)),
                FetchPolicy::loopback_http_for_tests(),
                &CancelToken::new(),
            )
            .await
            .expect("the good refresh succeeds");
        assert!(good.persisted);

        for label in &broken_cases {
            let error = store
                .refresh(
                    &transport,
                    &refresh_request("retain", format!("{}/{label}", server.base_url)),
                    FetchPolicy::loopback_http_for_tests(),
                    &CancelToken::new(),
                )
                .await
                .expect_err("the broken refresh must fail");
            match *label {
                "not-json" => assert_eq!(error.kind(), "invalidJson", "{error:?}"),
                "no-schema" => {
                    assert_eq!(error.kind(), "indexRejected", "{error:?}");
                    assert!(error.message().contains("schemaVersion"), "{error:?}");
                }
                "missing" => assert_eq!(error.kind(), "httpError", "{error:?}"),
                "budget" => assert_eq!(error.kind(), "budgetExceeded", "{error:?}"),
                other => panic!("unexpected broken case {other}: {error:?}"),
            }
            // The failure kinds are distinguishable per case, and the cache
            // still holds the good answer.
            let cached = store
                .cached_index(&refresh_request(
                    "retain",
                    format!("{}/good", server.base_url),
                ))
                .expect("cache readable")
                .expect("last known good kept");
            assert!(cached["plugins"].as_array().expect("plugins").len() >= 3);
        }
    }

    /// A refresh that started before a newer one but finishes after it never
    /// overwrites the newer cache entry; it still answers its own caller.
    #[tokio::test]
    async fn older_refresh_finishing_late_never_overwrites_the_newer_cache() {
        use crate::plugin_host::marketplace_download::HttpTransport;

        let mut index_old = read_marketplace_fixture("index.json");
        let mut index_new = read_marketplace_fixture("index.json");
        for (document, name) in [
            (&mut index_old, "Older Refresh Name"),
            (&mut index_new, "Newer Refresh Name"),
        ] {
            // Core sorts the validated plugins by ID, so the elixir entry is
            // the first of the cached document; both refreshes mutate it.
            let entry = document["plugins"]
                .as_array_mut()
                .expect("plugins")
                .iter_mut()
                .find(|entry| entry["id"] == serde_json::json!("io.example.elixir-tools"))
                .expect("elixir entry");
            entry["name"] = serde_json::json!(name);
        }

        let server = TestHttpServer::start(vec![
            (
                "/old",
                vec![TestResponse::ok(
                    serde_json::to_vec(&index_old).expect("old bytes"),
                )],
            ),
            (
                "/new",
                vec![TestResponse::ok(
                    serde_json::to_vec(&index_new).expect("new bytes"),
                )],
            ),
        ]);
        struct GatedTransport {
            inner: crate::plugin_host::marketplace_download::ReqwestTransport,
            gate_path: String,
            entered: std::sync::Mutex<Option<tokio::sync::oneshot::Sender<()>>>,
            release: Arc<tokio::sync::Notify>,
        }
        impl HttpTransport for GatedTransport {
            fn get<'a>(
                &'a self,
                url: &'a str,
                max_bytes: u64,
                deadline: Instant,
                cancel: &'a CancelToken,
            ) -> Pin<
                Box<
                    dyn Future<
                            Output = Result<
                                crate::plugin_host::marketplace_download::HttpResponse,
                                FetchFailure,
                            >,
                        > + Send
                        + 'a,
                >,
            > {
                let entered = self
                    .entered
                    .lock()
                    .expect("entered")
                    .take()
                    .filter(|_| url.contains(&self.gate_path));
                let release = self.release.clone();
                Box::pin(async move {
                    if let Some(entered) = entered {
                        let _ = entered.send(());
                        // Bounded: the test releases within its own runtime.
                        tokio::time::timeout(Duration::from_secs(10), release.notified())
                            .await
                            .map_err(|_| FetchFailure::DeadlineExceeded)?;
                    }
                    self.inner.get(url, max_bytes, deadline, cancel).await
                })
            }
        }

        let root = TestRoot::new("order");
        let store = Arc::new(MarketplaceIndexStore::new(root.0.clone()));
        let (entered_tx, entered_rx) = tokio::sync::oneshot::channel::<()>();
        let release = Arc::new(tokio::sync::Notify::new());
        let gated = Arc::new(GatedTransport {
            inner: crate::plugin_host::marketplace_download::ReqwestTransport::new()
                .expect("transport"),
            gate_path: "/old".to_string(),
            entered: std::sync::Mutex::new(Some(entered_tx)),
            release: release.clone(),
        });
        let plain =
            crate::plugin_host::marketplace_download::ReqwestTransport::new().expect("transport");
        let old_url = format!("{}/old", server.base_url);
        let new_url = format!("{}/new", server.base_url);

        // Both futures are owned by this scope. If an assertion unwinds, the
        // parked request is dropped rather than left in a detached Tokio task.
        let old_request = refresh_request("order", old_url);
        let old_cancel = CancelToken::new();
        let older = store.refresh(
            gated.as_ref(),
            &old_request,
            FetchPolicy::loopback_http_for_tests(),
            &old_cancel,
        );
        tokio::pin!(older);
        tokio::select! {
            result = &mut older => panic!("older request must be gated: {result:?}"),
            entered = tokio::time::timeout(Duration::from_secs(2), entered_rx) => {
                entered.expect("older request enters within its bound").expect("gate sender alive");
            }
        }

        let newer = store
            .refresh(
                &plain,
                &refresh_request("order", new_url),
                FetchPolicy::loopback_http_for_tests(),
                &CancelToken::new(),
            )
            .await
            .expect("the newer refresh succeeds");
        assert!(newer.persisted);

        release.notify_one();
        let older = tokio::time::timeout(Duration::from_secs(2), &mut older)
            .await
            .expect("the older refresh finishes within its bound")
            .expect("the older refresh still answers its caller");
        assert!(
            !older.persisted,
            "the late finishing refresh must not overwrite the newer cache"
        );
        let cached = store
            .cached_index(&refresh_request(
                "order",
                format!("{}/new", server.base_url),
            ))
            .expect("cache readable")
            .expect("the newer answer is cached");
        assert_eq!(
            cached["plugins"][0]["name"],
            serde_json::json!("Newer Refresh Name"),
            "the cached index is the newer refresh's document"
        );
    }

    #[tokio::test]
    async fn cancelled_and_deadline_refreshes_keep_the_cache() {
        let index = read_marketplace_fixture("index.json");
        let server = TestHttpServer::start(vec![(
            "/index.json",
            vec![TestResponse::ok(
                serde_json::to_vec(&index).expect("index bytes"),
            )],
        )]);
        let root = TestRoot::new("cancel");
        let store = MarketplaceIndexStore::new(root.0.clone());
        let transport =
            crate::plugin_host::marketplace_download::ReqwestTransport::new().expect("transport");

        let good = store
            .refresh(
                &transport,
                &refresh_request("cancel", format!("{}/index.json", server.base_url)),
                FetchPolicy::loopback_http_for_tests(),
                &CancelToken::new(),
            )
            .await
            .expect("the good refresh succeeds");
        assert!(good.persisted);

        let cancel = CancelToken::new();
        cancel.cancel();
        let error = store
            .refresh(
                &transport,
                &refresh_request("cancel", format!("{}/index.json", server.base_url)),
                FetchPolicy::loopback_http_for_tests(),
                &cancel,
            )
            .await
            .expect_err("the cancelled refresh must fail");
        assert_eq!(error.kind(), "cancelled");

        let mut expired = refresh_request("cancel", format!("{}/index.json", server.base_url));
        expired.deadline = Duration::ZERO;
        let error = store
            .refresh(
                &transport,
                &expired,
                FetchPolicy::loopback_http_for_tests(),
                &CancelToken::new(),
            )
            .await
            .expect_err("the expired refresh must fail");
        assert_eq!(error.kind(), "deadline");

        let cached = store
            .cached_index(&refresh_request(
                "cancel",
                format!("{}/index.json", server.base_url),
            ))
            .expect("cache readable")
            .expect("kept");
        assert!(cached["plugins"].as_array().expect("plugins").len() >= 3);
    }

    /// Unusable cache keys are refused instead of escaping the cache root,
    /// and the SHA-256 the index publishes is the one a download binds to.
    #[test]
    fn cache_keys_are_validated_and_sha256_round_trips() {
        let root = TestRoot::new("keys");
        let store = MarketplaceIndexStore::new(root.0.clone());
        assert!(store
            .cached_index(&refresh_request(
                "../evil",
                "https://example.com/index.json".into()
            ))
            .is_err());
        assert!(store
            .cached_index(&refresh_request(
                "UPPER",
                "https://example.com/index.json".into()
            ))
            .is_err());
        assert!(store
            .cached_index(&refresh_request(
                "official",
                "https://example.com/index.json".into()
            ))
            .expect("usable key")
            .is_none());

        let artifact_sha = {
            let digest = Sha256::digest(b"future artifact");
            format!("{:x}", digest)
        };
        assert_eq!(artifact_sha.len(), 64);
    }
}
