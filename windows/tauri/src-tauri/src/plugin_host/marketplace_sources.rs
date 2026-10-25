//! Marketplace source list for declarative plugins: the preset sources the
//! host rebuilds from constants, user-added third-party sources, enable
//! state, and their persistence under `app_local_data_dir()`.
//!
//! Semantics mirror the macOS feature model
//! (`macos/Sources/Lithe/Application/Features/PluginMarketplace.swift`) and
//! its adapter (`MacPluginMarketplaceService`): the official source can be
//! disabled but never removed, Lithe Store is a removable preset that stays
//! removed across restarts, source IDs are the same FNV-1a derivation over
//! the index URL, and URL resolution is decided by Core
//! (`plugins.marketplace.resolveSource`) — never reinterpreted here. Index
//! fetching, downloads, and installation are later M2 slices and do not
//! belong to this module.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use tauri::{AppHandle, Manager};

/// The official source: host constant, rebuildable, undeletable.
pub const OFFICIAL_SOURCE_ID: &str = "lithe-official";
pub const OFFICIAL_INDEX_URL: &str =
    "https://raw.githubusercontent.com/Lithe-IDEA/Lithe-IDEA/HEAD/Plugins/marketplace/index.json";
pub const OFFICIAL_REPOSITORY: &str = "https://github.com/Lithe-IDEA/Lithe-IDEA";
/// Lithe Store, the preset community source. Unlike the official source it
/// is third-party and the user may remove it; removal is remembered so the
/// next launch does not add it back.
pub const COMMUNITY_REPOSITORY: &str = "https://github.com/Lithe-IDEA/Lithe-store";
pub const COMMUNITY_INDEX_URL: &str =
    "https://raw.githubusercontent.com/Lithe-IDEA/Lithe-store/HEAD/lithe-plugin-index.json";

const SOURCES_SCHEMA_VERSION: u64 = 1;
const OFFICIAL_SOURCE_NAME: &str = "Lithe";
const COMMUNITY_SOURCE_NAME: &str = "Lithe Store";

/// The largest number of corruption backups one store keeps before giving
/// up; a backup must never overwrite a previous one, so disk-exhausting
/// loops terminate with a diagnosable error instead.
pub(crate) const MAXIMUM_CORRUPTION_BACKUPS: u32 = 64;

/// Serializes every sources.json read-modify-write across the host's
/// windows: each command loads, mutates, and persists the whole list, so
/// two concurrent transactions would otherwise drop one side's update.
/// The store is one file per user, so a process-wide lock over the
/// transaction is the exact scope needed.
static SOURCES_LOCK: Mutex<()> = Mutex::new(());

/// Distinguishes concurrent temp files of the same store (multi-window
/// writes and, in principle, several app instances) so a fixed temp name
/// can never collide mid-rename.
static TEMP_SEQUENCE: AtomicU64 = AtomicU64::new(0);

pub(crate) fn sources_lock() -> &'static Mutex<()> {
    &SOURCES_LOCK
}

/// One marketplace source. Serialized field names match the macOS
/// `sources.json` shape so the stored bytes stay cross-platform readable.
#[derive(Clone, Debug, Deserialize, PartialEq, Serialize)]
pub struct MarketplaceSource {
    pub id: String,
    pub name: String,
    /// What the user entered, or the official index URL for a preset.
    pub input: String,
    #[serde(rename = "indexURL")]
    pub index_url: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub repository: Option<String>,
    #[serde(rename = "isEnabled")]
    pub is_enabled: bool,
}

/// Stable, filesystem-safe ID for a source, derived from its index URL with
/// the exact FNV-1a derivation macOS uses
/// (`PluginMarketplaceSource.id(forIndexURL:)`): offset basis, FNV prime,
/// then `source-` plus lowercase hexadecimal without padding. The same URL
/// must therefore never be addable twice.
pub(crate) fn source_id_for_index_url(index_url: &str) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in index_url.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("source-{hash:x}")
}

/// Whether two index URLs name the same index. GitHub hosts lowercase their
/// addresses, and a user may type the preset's URL in a different case, so
/// the comparison is Unicode case-insensitive like macOS
/// `caseInsensitiveCompare`.
fn same_index(left: &str, right: &str) -> bool {
    left.to_lowercase() == right.to_lowercase()
}

fn official_source() -> MarketplaceSource {
    MarketplaceSource {
        id: OFFICIAL_SOURCE_ID.to_string(),
        name: OFFICIAL_SOURCE_NAME.to_string(),
        input: OFFICIAL_INDEX_URL.to_string(),
        index_url: OFFICIAL_INDEX_URL.to_string(),
        repository: Some(OFFICIAL_REPOSITORY.to_string()),
        is_enabled: true,
    }
}

fn community_source() -> MarketplaceSource {
    MarketplaceSource {
        id: source_id_for_index_url(COMMUNITY_INDEX_URL),
        name: COMMUNITY_SOURCE_NAME.to_string(),
        input: COMMUNITY_REPOSITORY.to_string(),
        index_url: COMMUNITY_INDEX_URL.to_string(),
        repository: Some(COMMUNITY_REPOSITORY.to_string()),
        is_enabled: true,
    }
}

/// `sources.json` next to the other plugin-host stores. Writes only ever
/// target `app_local_data_dir()`; installed packages stay read-only.
fn sources_path(app: &AppHandle) -> Result<PathBuf, String> {
    Ok(app
        .path()
        .app_local_data_dir()
        .map_err(|error| error.to_string())?
        .join("plugin-marketplace")
        .join("sources.json"))
}

/// The persisted shape. `removedPresetSourceIDs` records presets the user
/// removed so a restart does not add them back.
#[derive(Deserialize, Serialize)]
struct SourcesFile {
    #[serde(rename = "schemaVersion")]
    schema_version: u64,
    #[serde(default)]
    sources: Vec<MarketplaceSource>,
    #[serde(
        default,
        rename = "removedPresetSourceIDs",
        skip_serializing_if = "Option::is_none"
    )]
    removed_preset_source_ids: Option<Vec<String>>,
}

/// Rebuilds the preset sources from host constants; only their enable state
/// is the user's. A user-added source typed under a differently cased
/// Lithe Store address stands in for the preset, keeping the ID its plugins
/// already recorded — the same rule as macOS `loadSources`. Takes the host
/// sources lock because a corrupted store is moved aside while reading.
pub(crate) fn load_sources(
    path: &Path,
) -> Result<(Vec<MarketplaceSource>, Option<String>), String> {
    let _guard = sources_lock()
        .lock()
        .map_err(|error| format!("plugin.marketplace.sources.lock: {error}"))?;
    load_sources_unlocked(path)
}

fn load_sources_unlocked(path: &Path) -> Result<(Vec<MarketplaceSource>, Option<String>), String> {
    let mut official = official_source();
    let mut community = community_source();
    let text = match std::fs::read_to_string(path) {
        Ok(text) => text,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
            return Ok((vec![official, community], None));
        }
        Err(error) => return Err(error.to_string()),
    };
    let parsed: Result<SourcesFile, serde_json::Error> = serde_json::from_str(&text);
    let file: SourcesFile = match parsed {
        Ok(file) if file.schema_version == SOURCES_SCHEMA_VERSION => file,
        Ok(file) => {
            let problem = format!(
                "plugin.marketplace.sources.corrupt: schemaVersion {} is not supported",
                file.schema_version
            );
            return Ok((preserve_corrupt_file(path)?, Some(problem)));
        }
        Err(error) => {
            let problem = format!("plugin.marketplace.sources.corrupt: {error}");
            return Ok((preserve_corrupt_file(path)?, Some(problem)));
        }
    };
    official.is_enabled = file
        .sources
        .iter()
        .find(|source| source.id == official.id)
        .map(|source| source.is_enabled)
        .unwrap_or(true);
    // Lithe Store added by hand before it became a preset already has the
    // preset ID, so only its enabled state carries over (macOS rule).
    community.is_enabled = file
        .sources
        .iter()
        .find(|source| source.id == community.id)
        .map(|source| source.is_enabled)
        .unwrap_or(true);
    let preset_ids = [OFFICIAL_SOURCE_ID.to_string(), community.id.clone()];
    let third_party: Vec<MarketplaceSource> = file
        .sources
        .iter()
        .filter(|source| !preset_ids.contains(&source.id))
        .cloned()
        .collect();
    if file
        .removed_preset_source_ids
        .as_ref()
        .is_some_and(|removed| removed.contains(&community.id))
    {
        return Ok((prepend_official(official, third_party), None));
    }
    if third_party
        .iter()
        .any(|source| same_index(&source.index_url, &community.index_url))
    {
        return Ok((prepend_official(official, third_party), None));
    }
    Ok((
        prepend_official(
            official,
            std::iter::once(community).chain(third_party).collect(),
        ),
        None,
    ))
}

fn prepend_official(
    official: MarketplaceSource,
    mut sources: Vec<MarketplaceSource>,
) -> Vec<MarketplaceSource> {
    // The rebuild never lets a stored preset entry's name or URL stand in;
    // the merged enable state lives in `official` already.
    sources.insert(0, official);
    sources
}

/// A corrupted store must never be silently reset and never destroy
/// earlier backups: the original bytes move to the first free
/// `sources.json.corrupt-<n>` (n = 1..64), keeping every historical copy,
/// and the list rebuilds from presets. A failed backup leaves the
/// unreadable file in place untouched.
fn preserve_corrupt_file(path: &Path) -> Result<Vec<MarketplaceSource>, String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    for attempt in 1..=MAXIMUM_CORRUPTION_BACKUPS {
        let backup = path.with_extension(format!("json.corrupt-{attempt}"));
        if backup.exists() {
            continue;
        }
        return match std::fs::rename(path, &backup) {
            Ok(()) => Ok(vec![official_source(), community_source()]),
            Err(error) => Err(format!(
                "plugin.marketplace.sources.corrupt: preserving the unreadable file failed: {error}"
            )),
        };
    }
    Err(format!(
        "plugin.marketplace.sources.corrupt: all {MAXIMUM_CORRUPTION_BACKUPS} backup slots exist; move them aside and retry"
    ))
}

/// Writes the store atomically via a unique temp file + rename, recomputing
/// the removed-preset tombstones from the list: a preset missing here was
/// removed by the user, and one present again clears its tombstone.
pub(crate) fn save_sources(path: &Path, sources: &[MarketplaceSource]) -> Result<(), String> {
    let _guard = sources_lock()
        .lock()
        .map_err(|error| format!("plugin.marketplace.sources.lock: {error}"))?;
    save_sources_unlocked(path, sources)
}

fn save_sources_unlocked(path: &Path, sources: &[MarketplaceSource]) -> Result<(), String> {
    let removed: Vec<String> = [community_source().id]
        .into_iter()
        .filter(|id| !sources.iter().any(|source| &source.id == id))
        .collect();
    let file = SourcesFile {
        schema_version: SOURCES_SCHEMA_VERSION,
        sources: sources.to_vec(),
        // macOS omits the key when nothing was removed; an absent key and an
        // empty list mean the same thing to both loaders.
        removed_preset_source_ids: if removed.is_empty() {
            None
        } else {
            Some(removed)
        },
    };
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    let sequence = TEMP_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    let temp = path.with_extension(format!("json.tmp-{}-{sequence}", std::process::id()));
    // A failed write or rename must not leave this attempt's temp file
    // behind; the previous store stays untouched either way.
    let result = std::fs::write(
        &temp,
        serde_json::to_string_pretty(&file).map_err(|error| error.to_string())?,
    )
    .and_then(|()| std::fs::rename(&temp, path))
    .map_err(|error| error.to_string());
    if result.is_err() {
        let _ = std::fs::remove_file(&temp);
    }
    result
}

/// Adds a source for `input`. Core decides what the input names; the host
/// derives the stable ID, refuses duplicates (by ID or by case-insensitive
/// index URL), and keeps `isEnabled` of everything already listed. A
/// re-added Lithe Store takes its preset ID back in any casing, which also
/// clears its removal tombstone on the next save. The whole
/// load-resolve-mutate-persist sequence holds the host sources lock so
/// concurrent windows cannot drop each other's update.
pub(crate) fn add_source(path: &Path, input: &str) -> Result<Vec<MarketplaceSource>, String> {
    let _guard = sources_lock()
        .lock()
        .map_err(|error| format!("plugin.marketplace.sources.lock: {error}"))?;
    let input = input.trim();
    if input.is_empty() {
        return Err("plugin.marketplace.sources.emptyInput".to_string());
    }
    let resolution = resolve_via_core(input)?;
    let index_url = resolution
        .get("indexURL")
        .and_then(Value::as_str)
        .ok_or_else(|| "plugin.marketplace.sources.invalidResolution".to_string())?
        .to_string();
    let repository = resolution
        .get("repository")
        .and_then(Value::as_str)
        .map(str::to_string);
    let name = resolution
        .get("displayName")
        .and_then(Value::as_str)
        .unwrap_or(index_url.as_str())
        .to_string();
    let community = community_source();
    let id = if same_index(&index_url, &community.index_url) {
        community.id
    } else {
        source_id_for_index_url(&index_url)
    };
    let (mut sources, _) = load_sources_unlocked(path)?;
    if sources
        .iter()
        .any(|source| source.id == id || same_index(&source.index_url, &index_url))
    {
        return Err(format!("plugin.marketplace.sourceAlreadyAdded: {name}"));
    }
    sources.push(MarketplaceSource {
        id,
        name,
        input: input.to_string(),
        index_url,
        repository,
        is_enabled: true,
    });
    save_sources_unlocked(path, &sources)?;
    Ok(sources)
}

/// Toggles one source's enable state under the host sources lock. An
/// unknown ID is a no-op, matching the macOS feature model.
pub(crate) fn set_enabled(
    path: &Path,
    source_id: &str,
    enabled: bool,
) -> Result<Vec<MarketplaceSource>, String> {
    let _guard = sources_lock()
        .lock()
        .map_err(|error| format!("plugin.marketplace.sources.lock: {error}"))?;
    let (mut sources, _) = load_sources_unlocked(path)?;
    if let Some(position) = sources.iter().position(|source| source.id == source_id) {
        sources[position].is_enabled = enabled;
        save_sources_unlocked(path, &sources)?;
    }
    Ok(sources)
}

/// Removes a third-party source under the host sources lock. The official
/// source is refused; removing Lithe Store persists its tombstone so
/// restarts do not revive it.
pub(crate) fn remove_source(
    path: &Path,
    source_id: &str,
) -> Result<Vec<MarketplaceSource>, String> {
    let _guard = sources_lock()
        .lock()
        .map_err(|error| format!("plugin.marketplace.sources.lock: {error}"))?;
    let (sources, _) = load_sources_unlocked(path)?;
    let Some(source) = sources.iter().find(|source| source.id == source_id) else {
        return Err("plugin.marketplace.sourceNotFound".to_string());
    };
    if source.id == OFFICIAL_SOURCE_ID {
        return Err("plugin.marketplace.officialSourceCannotBeRemoved".to_string());
    }
    let remaining: Vec<MarketplaceSource> = sources
        .into_iter()
        .filter(|source| source.id != source_id)
        .collect();
    save_sources_unlocked(path, &remaining)?;
    Ok(remaining)
}

/// One source as the frontend sees it: the stored fields plus the kind and
/// the actions the UI may offer.
pub(crate) fn source_view(source: &MarketplaceSource) -> Value {
    let official = source.id == OFFICIAL_SOURCE_ID;
    let mut value = serde_json::to_value(source).expect("source serializes");
    value["kind"] = json!(if official { "official" } else { "thirdParty" });
    value["isOfficial"] = json!(official);
    value["deletable"] = json!(!official);
    value
}

fn source_views(sources: &[MarketplaceSource]) -> Vec<Value> {
    sources.iter().map(source_view).collect()
}

/// Calls Core for the one decision this module delegates: what the user's
/// input names. The error keeps Core's stable code so the UI can show
/// `plugin.source.invalid` instead of prose. Marketplace commands return
/// rejections in-band (`data.status: "rejected"` with the stable code);
/// malformed requests fail on the envelope itself.
fn resolve_via_core(input: &str) -> Result<Value, String> {
    let request = json!({
        "command": "plugins.marketplace.resolveSource",
        "payload": { "url": input },
    });
    let response_text = lithe_core::execute_json(&request.to_string());
    let response: Value = serde_json::from_str(&response_text).map_err(|error| {
        format!("plugins.marketplace.resolveSource returned an unreadable response: {error}")
    })?;
    if response["ok"] == json!(true) {
        let data = response["data"].clone();
        if data["status"] == json!("ok") {
            return Ok(data["source"].clone());
        }
        Err(rejection_message(&data["error"]))
    } else {
        Err(rejection_message(&response["error"]))
    }
}

fn rejection_message(error: &Value) -> String {
    let code = error["code"].as_str().unwrap_or("unknown");
    let message = error["message"].as_str().unwrap_or("unknown error");
    format!("{code}: {message}")
}

/// Tauri command: current sources plus the corruption diagnosis, if the
/// store had to be rebuilt.
#[tauri::command]
pub fn declarative_marketplace_sources_state(app: AppHandle) -> Result<Value, String> {
    let path = sources_path(&app)?;
    let (sources, problem) = load_sources(&path)?;
    Ok(json!({ "sources": source_views(&sources), "problem": problem }))
}

/// Tauri command: resolves and adds a third-party source, returning the
/// updated list.
#[tauri::command]
pub fn declarative_marketplace_sources_add(
    app: AppHandle,
    url: String,
) -> Result<Vec<Value>, String> {
    let path = sources_path(&app)?;
    let sources = add_source(&path, &url)?;
    Ok(source_views(&sources))
}

/// Tauri command: enables or disables one source, returning the updated list.
#[tauri::command]
pub fn declarative_marketplace_sources_set_enabled(
    app: AppHandle,
    source_id: String,
    enabled: bool,
) -> Result<Vec<Value>, String> {
    let path = sources_path(&app)?;
    let sources = set_enabled(&path, &source_id, enabled)?;
    Ok(source_views(&sources))
}

/// Tauri command: removes a deletable source, returning the updated list.
#[tauri::command]
pub fn declarative_marketplace_sources_remove(
    app: AppHandle,
    source_id: String,
) -> Result<Vec<Value>, String> {
    let path = sources_path(&app)?;
    let sources = remove_source(&path, &source_id)?;
    Ok(source_views(&sources))
}
