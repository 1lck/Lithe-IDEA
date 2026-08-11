use crate::protocol::{invalid_relative_path, CoreError, ErrorCode};
use crate::protocol::{HistoryEntriesResponse, HistoryEntryResponse};
use serde::{Deserialize, Serialize};
use std::fs;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

const MAX_FILE_SIZE: usize = 2 * 1024 * 1024;
const MAX_ENTRIES_PER_FILE: usize = 100;
const RETENTION_SECONDS: i64 = 30 * 24 * 60 * 60;
const HISTORY_VERSION: u32 = 2;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryRecordRequest {
    pub workspace_root: String,
    pub storage_root: String,
    pub path: String,
    pub reason: String,
    #[serde(default)]
    pub content: Option<String>,
    #[serde(default = "default_prune_expired")]
    pub prune_expired: bool,
    #[serde(default)]
    pub hidden_directory_names: Vec<String>,
    #[serde(default)]
    pub hidden_file_patterns: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryEntriesRequest {
    pub workspace_root: String,
    pub storage_root: String,
    #[serde(default)]
    pub path: Option<String>,
    #[serde(default)]
    pub hidden_directory_names: Vec<String>,
    #[serde(default)]
    pub hidden_file_patterns: Vec<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryContentRequest {
    pub storage_root: String,
    pub content_path: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct HistoryRelocateRequest {
    pub storage_root: String,
    pub source_path: String,
    pub destination_path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct StoredEntry {
    version: u32,
    id: String,
    timestamp: i64,
    relative_path: String,
    reason: String,
    content_path: String,
    byte_count: usize,
}

pub fn record(request: HistoryRecordRequest) -> Result<Option<HistoryEntryResponse>, CoreError> {
    let workspace = existing_root(&request.workspace_root)?;
    let relative_path = safe_relative_path(&request.path)?;
    if !is_valid_reason(&request.reason) {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Unsupported local history reason",
        ));
    }
    let rules = VisibilityRules::new(request.hidden_directory_names, request.hidden_file_patterns);
    if rules.is_hidden(&relative_path, false) {
        return Ok(None);
    }
    let content = match request.content {
        Some(content) => content.into_bytes(),
        None => {
            let file = workspace
                .join(&relative_path)
                .canonicalize()
                .map_err(CoreError::from)?;
            if !file.starts_with(&workspace) {
                return Err(CoreError::new(
                    ErrorCode::PermissionDenied,
                    "Path is outside the workspace",
                ));
            }
            fs::read(file).map_err(CoreError::from)?
        }
    };
    if content.len() > MAX_FILE_SIZE {
        return Ok(None);
    }
    let storage = storage_root(&request.storage_root)?;
    let directory = storage.join(stable_identifier(&relative_path));
    fs::create_dir_all(&directory)?;
    let entries = read_entries(&directory, &storage);
    if let Some(latest) = entries.first() {
        if fs::read(storage.join(&latest.content_path)).ok().as_deref() == Some(content.as_slice())
        {
            return Ok(None);
        }
    }
    let timestamp = unix_seconds();
    let raw_id = format!("{:032x}", timestamp as u128 * 1_000_000 + monotonic_nonce());
    let id = format!(
        "{}-{}-{}-{}-{}",
        &raw_id[0..8],
        &raw_id[8..12],
        &raw_id[12..16],
        &raw_id[16..20],
        &raw_id[20..32]
    );
    let content_path = format!("{}/{}.snapshot", stable_identifier(&relative_path), id);
    let metadata_path = directory.join(format!("{}.json", id));
    let stored = StoredEntry {
        version: HISTORY_VERSION,
        id: id.clone(),
        timestamp,
        relative_path,
        reason: request.reason,
        content_path,
        byte_count: content.len(),
    };
    fs::write(storage.join(&stored.content_path), &content)?;
    fs::write(
        metadata_path,
        serde_json::to_vec(&stored).expect("history metadata should encode"),
    )?;
    trim_entries(&directory, &storage);
    if request.prune_expired {
        prune_expired(&storage);
    }
    Ok(Some(stored.into_response()))
}

pub fn entries(request: HistoryEntriesRequest) -> Result<HistoryEntriesResponse, CoreError> {
    let workspace = existing_root(&request.workspace_root)?;
    let rules = VisibilityRules::new(request.hidden_directory_names, request.hidden_file_patterns);
    let storage = storage_root(&request.storage_root)?;
    let mut values = Vec::new();
    if let Some(path) = request.path {
        let relative = safe_relative_path(&path)?;
        if !rules.is_hidden(&relative, false) {
            let directory = storage.join(stable_identifier(&relative));
            values.extend(read_entries(&directory, &storage));
        }
    } else {
        for directory in fs::read_dir(&storage)?.filter_map(Result::ok) {
            if directory
                .file_type()
                .map(|value| value.is_dir())
                .unwrap_or(false)
            {
                values.extend(read_entries(&directory.path(), &storage));
            }
        }
        values.retain(|entry| {
            workspace.join(&entry.relative_path).starts_with(&workspace)
                && !rules.is_hidden(&entry.relative_path, false)
        });
    }
    values.sort_by(|left, right| {
        right
            .timestamp
            .cmp(&left.timestamp)
            .then_with(|| right.id.cmp(&left.id))
            .then_with(|| left.relative_path.cmp(&right.relative_path))
    });
    Ok(HistoryEntriesResponse {
        entries: values.into_iter().map(StoredEntry::into_response).collect(),
    })
}

pub fn content(request: HistoryContentRequest) -> Result<String, CoreError> {
    let storage = storage_root(&request.storage_root)?;
    let relative = safe_relative_path(&request.content_path)?;
    let data = fs::read(storage.join(relative)).map_err(CoreError::from)?;
    Ok(String::from_utf8_lossy(&data).into_owned())
}

pub fn relocate(request: HistoryRelocateRequest) -> Result<(), CoreError> {
    let storage = storage_root(&request.storage_root)?;
    let source = safe_relative_path(&request.source_path)?;
    let destination = safe_relative_path(&request.destination_path)?;
    let source_directory = storage.join(stable_identifier(&source));
    if !source_directory.exists() {
        return Ok(());
    }
    let destination_directory = storage.join(stable_identifier(&destination));
    fs::create_dir_all(&destination_directory)?;
    for entry in read_entries(&source_directory, &storage) {
        let content_name = format!("{}.snapshot", entry.id);
        let metadata_name = format!("{}.json", entry.id);
        let content_path = destination_directory.join(&content_name);
        fs::rename(storage.join(&entry.content_path), &content_path)?;
        let relocated = StoredEntry {
            relative_path: destination.clone(),
            content_path: format!("{}/{}", stable_identifier(&destination), content_name),
            ..entry
        };
        fs::write(
            destination_directory.join(metadata_name),
            serde_json::to_vec(&relocated).expect("history metadata should encode"),
        )?;
    }
    let _ = fs::remove_dir_all(source_directory);
    Ok(())
}

impl StoredEntry {
    fn into_response(self) -> HistoryEntryResponse {
        HistoryEntryResponse {
            id: self.id,
            timestamp: self.timestamp,
            relative_path: self.relative_path,
            reason: self.reason,
            content_path: self.content_path,
            byte_count: self.byte_count,
        }
    }
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct LegacyStoredEntry {
    id: String,
    timestamp: String,
    relative_path: String,
    reason: String,
    content_url: String,
    byte_count: usize,
}

fn read_entries(directory: &Path, storage: &Path) -> Vec<StoredEntry> {
    let mut entries = fs::read_dir(directory)
        .ok()
        .into_iter()
        .flatten()
        .filter_map(Result::ok)
        .filter(|entry| entry.path().extension().and_then(|value| value.to_str()) == Some("json"))
        .filter_map(|entry| {
            let data = fs::read(entry.path()).ok()?;
            if let Ok(value) = serde_json::from_slice::<StoredEntry>(&data) {
                return (value.version == HISTORY_VERSION).then_some(value);
            }
            let legacy = serde_json::from_slice::<LegacyStoredEntry>(&data).ok()?;
            let content = PathBuf::from(legacy.content_url)
                .strip_prefix(storage)
                .ok()?
                .to_string_lossy()
                .replace('\\', "/");
            Some(StoredEntry {
                version: HISTORY_VERSION,
                id: legacy.id,
                timestamp: parse_iso_timestamp(&legacy.timestamp),
                relative_path: legacy.relative_path,
                reason: legacy.reason,
                content_path: content,
                byte_count: legacy.byte_count,
            })
        })
        .filter(|entry| storage.join(&entry.content_path).is_file())
        .collect::<Vec<_>>();
    entries.sort_by(|left, right| {
        right
            .timestamp
            .cmp(&left.timestamp)
            .then_with(|| right.id.cmp(&left.id))
    });
    entries
}

fn default_prune_expired() -> bool {
    true
}

fn trim_entries(directory: &Path, storage: &Path) {
    for entry in read_entries(directory, storage)
        .into_iter()
        .skip(MAX_ENTRIES_PER_FILE)
    {
        let _ = fs::remove_file(storage.join(&entry.content_path));
        let _ = fs::remove_file(directory.join(format!("{}.json", entry.id)));
    }
}

fn prune_expired(storage: &Path) {
    let cutoff = unix_seconds() - RETENTION_SECONDS;
    let Ok(directories) = fs::read_dir(storage) else {
        return;
    };
    for directory in directories.filter_map(Result::ok) {
        if !directory
            .file_type()
            .map(|value| value.is_dir())
            .unwrap_or(false)
        {
            continue;
        }
        for entry in read_entries(&directory.path(), storage) {
            if entry.timestamp < cutoff {
                let _ = fs::remove_file(storage.join(&entry.content_path));
                let _ = fs::remove_file(directory.path().join(format!("{}.json", entry.id)));
            }
        }
    }
}

fn existing_root(value: &str) -> Result<PathBuf, CoreError> {
    let path = PathBuf::from(value);
    let metadata = fs::metadata(&path)
        .map_err(|_| CoreError::new(ErrorCode::WorkspaceNotFound, "Workspace does not exist"))?;
    if !metadata.is_dir() {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Workspace root must be a directory",
        ));
    }
    path.canonicalize().map_err(CoreError::from)
}

fn storage_root(value: &str) -> Result<PathBuf, CoreError> {
    let path = PathBuf::from(value);
    fs::create_dir_all(&path).map_err(CoreError::from)?;
    path.canonicalize().map_err(CoreError::from)
}

fn safe_relative_path(value: &str) -> Result<String, CoreError> {
    let path = Path::new(value);
    if path.is_absolute() || invalid_relative_path(value) {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Path must be relative",
        ));
    }
    let normalized = value.replace('\\', "/").trim_matches('/').to_string();
    if normalized.is_empty() {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Path must not be empty",
        ));
    }
    Ok(normalized)
}

fn stable_identifier(value: &str) -> String {
    let mut hash: u64 = 14_695_981_039_346_656_037;
    for byte in value.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(1_099_511_628_211);
    }
    format!("{hash:x}")
}

fn unix_seconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.as_secs() as i64)
        .unwrap_or_default()
}

fn monotonic_nonce() -> u128 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|value| value.subsec_nanos() as u128)
        .unwrap_or_default()
}

fn is_valid_reason(value: &str) -> bool {
    matches!(
        value,
        "projectBaseline"
            | "saved"
            | "externalChange"
            | "beforeRename"
            | "beforeDelete"
            | "beforeBatchReplace"
            | "unsavedDiscard"
            | "restored"
    )
}

fn parse_iso_timestamp(value: &str) -> i64 {
    if value.len() < 19 {
        return 0;
    }
    let number = |start: usize, end: usize| -> i64 {
        value
            .get(start..end)
            .and_then(|part| part.parse::<i64>().ok())
            .unwrap_or_default()
    };
    let year = number(0, 4);
    let month = number(5, 7);
    let day = number(8, 10);
    let hour = number(11, 13);
    let minute = number(14, 16);
    let second = number(17, 19);
    let adjusted_year = year - i64::from(month <= 2);
    let era = (if adjusted_year >= 0 {
        adjusted_year
    } else {
        adjusted_year - 399
    }) / 400;
    let year_of_era = adjusted_year - era * 400;
    let month_index = month + if month > 2 { -3 } else { 9 };
    let day_of_year = (153 * month_index + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    let days = era * 146_097 + day_of_era - 719_468;
    days * 86_400 + hour * 3_600 + minute * 60 + second
}

struct VisibilityRules {
    directories: Vec<String>,
    files: Vec<String>,
}

impl VisibilityRules {
    fn new(hidden_directories: Vec<String>, hidden_files: Vec<String>) -> Self {
        let mut directories = vec![".git", ".build", ".swiftpm", "node_modules", "target"]
            .into_iter()
            .map(String::from)
            .collect::<Vec<_>>();
        directories.extend(hidden_directories);
        let mut files = vec![".DS_Store".to_string()];
        files.extend(hidden_files);
        Self { directories, files }
    }

    fn is_hidden(&self, path: &str, is_directory: bool) -> bool {
        let components = path
            .split('/')
            .filter(|value| !value.is_empty())
            .collect::<Vec<_>>();
        if components.iter().any(|component| {
            self.directories
                .iter()
                .any(|hidden| hidden.eq_ignore_ascii_case(component))
        }) {
            return true;
        }
        if is_directory {
            return false;
        }
        let last = components.last().copied().unwrap_or_default();
        self.files
            .iter()
            .any(|pattern| pattern.eq_ignore_ascii_case(last))
    }
}
