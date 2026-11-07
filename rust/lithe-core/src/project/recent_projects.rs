//! Retention and ordering rules for the recently opened project list.
//!
//! Hosts own persistence, display metadata (names, icons, branches), and the
//! decision of which roots are worth recording at all. Core owns which paths
//! survive, in what order, and how pins interact with the retention capacity,
//! so every platform keeps the same set after the same sequence of actions.

use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashSet;

/// Unpinned projects kept when the caller does not override the capacity.
pub const DEFAULT_RECENT_PROJECT_CAPACITY: usize = 20;
/// Largest capacity a caller may request.
const MAX_CAPACITY: usize = 200;
/// Bounds the stored list a host may hand over in one reduction.
const MAX_ENTRIES: usize = 1024;
/// Bounds one action's path list (removals and imports).
const MAX_ACTION_PATHS: usize = 1024;
/// Upper bound for one path identity in UTF-8 bytes.
const MAX_PATH_BYTES: usize = 4096;

/// One retained project identity. `path` is the host's normalized root path
/// and is compared byte for byte; `lastOpenedAt` is milliseconds since the
/// Unix epoch supplied by the host clock.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RecentProjectEntry {
    pub path: String,
    /// Missing timestamps from older stores sort as the oldest entries.
    #[serde(default)]
    pub last_opened_at: i64,
    /// Pinned projects sort first and never count against the capacity.
    #[serde(default)]
    pub pinned: bool,
}

/// One user or host action applied to the stored list.
#[derive(Debug, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
pub enum RecentProjectsAction {
    /// The project was opened at `openedAt`; it moves first and keeps its pin.
    Record {
        path: String,
        #[serde(rename = "openedAt")]
        opened_at: i64,
    },
    /// Projects removed by the user or found unavailable by the host.
    Remove { paths: Vec<String> },
    /// Flips the pin of an existing project; unknown paths are ignored.
    TogglePinned { path: String },
    /// Adds projects discovered elsewhere (for example another IDE) that are
    /// not already listed. The first import is stamped `openedAt` and each
    /// later one a millisecond older, preserving the source order.
    Import {
        paths: Vec<String>,
        #[serde(rename = "openedAt")]
        opened_at: i64,
    },
    /// Re-applies ordering, deduplication, and capacity to a loaded list.
    Normalize,
}

/// `workspace.recentProjects.reduce` request.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct RecentProjectsRequest {
    pub entries: Vec<RecentProjectEntry>,
    pub action: RecentProjectsAction,
    /// Unpinned capacity; defaults to [`DEFAULT_RECENT_PROJECT_CAPACITY`].
    #[serde(default)]
    pub capacity: Option<usize>,
}

/// Ordered retained list plus the paths this reduction added or dropped, so
/// hosts can attach or discard their own per-project metadata.
#[derive(Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RecentProjectsResponse {
    pub entries: Vec<RecentProjectEntry>,
    pub added: Vec<String>,
    pub removed: Vec<String>,
}

/// JSON entry point for `workspace.recentProjects.reduce`.
pub(crate) fn reduce_command(payload: Value) -> Result<Value, CoreError> {
    let request: RecentProjectsRequest = serde_json::from_value(payload).map_err(|error| {
        CoreError::new(ErrorCode::InvalidRequest, "Invalid recent projects request")
            .with_details(error.to_string())
    })?;
    let response = reduce(request)?;
    Ok(serde_json::to_value(response).expect("recent projects response should encode"))
}

/// Applies one action and returns the retained list, pinned projects first,
/// then by most recent `lastOpenedAt`; equal times keep the caller's order.
pub fn reduce(request: RecentProjectsRequest) -> Result<RecentProjectsResponse, CoreError> {
    let capacity = request.capacity.unwrap_or(DEFAULT_RECENT_PROJECT_CAPACITY);
    if capacity == 0 || capacity > MAX_CAPACITY {
        return Err(invalid("Recent project capacity is out of range"));
    }
    if request.entries.len() > MAX_ENTRIES {
        return Err(invalid("Too many recent projects"));
    }
    for entry in &request.entries {
        validate_path(&entry.path)?;
        validate_time(entry.last_opened_at)?;
    }

    let mut entries = deduplicate(request.entries);
    // Deduplicated paths in the caller's order, used to report removals.
    let original: Vec<String> = entries.iter().map(|entry| entry.path.clone()).collect();
    match request.action {
        RecentProjectsAction::Record { path, opened_at } => {
            validate_path(&path)?;
            validate_time(opened_at)?;
            let pinned = match entries.iter().position(|entry| entry.path == path) {
                Some(index) => entries.remove(index).pinned,
                None => false,
            };
            entries.insert(
                0,
                RecentProjectEntry {
                    path,
                    last_opened_at: opened_at,
                    pinned,
                },
            );
        }
        RecentProjectsAction::Remove { paths } => {
            validate_paths(&paths)?;
            let removed: HashSet<&str> = paths.iter().map(String::as_str).collect();
            entries.retain(|entry| !removed.contains(entry.path.as_str()));
        }
        RecentProjectsAction::TogglePinned { path } => {
            validate_path(&path)?;
            if let Some(entry) = entries.iter_mut().find(|entry| entry.path == path) {
                entry.pinned = !entry.pinned;
            }
        }
        RecentProjectsAction::Import { paths, opened_at } => {
            validate_paths(&paths)?;
            validate_time(opened_at)?;
            let mut known: HashSet<String> = entries.iter().map(|e| e.path.clone()).collect();
            let mut offset = 0;
            for path in paths {
                if known.insert(path.clone()) {
                    entries.push(RecentProjectEntry {
                        path,
                        last_opened_at: opened_at.saturating_sub(offset).max(0),
                        pinned: false,
                    });
                    offset += 1;
                }
            }
        }
        RecentProjectsAction::Normalize => {}
    }

    let retained = order_and_limit(entries, capacity);
    let previous: HashSet<&str> = original.iter().map(String::as_str).collect();
    let kept: HashSet<&str> = retained.iter().map(|entry| entry.path.as_str()).collect();
    let added = retained
        .iter()
        .filter(|entry| !previous.contains(entry.path.as_str()))
        .map(|entry| entry.path.clone())
        .collect();
    let removed = original
        .iter()
        .filter(|path| !kept.contains(path.as_str()))
        .cloned()
        .collect();
    Ok(RecentProjectsResponse {
        entries: retained,
        added,
        removed,
    })
}

/// Keeps the newest record of each path; the first occurrence wins a tie.
fn deduplicate(entries: Vec<RecentProjectEntry>) -> Vec<RecentProjectEntry> {
    let mut result: Vec<RecentProjectEntry> = Vec::with_capacity(entries.len());
    for entry in entries {
        match result.iter_mut().find(|kept| kept.path == entry.path) {
            Some(kept) if entry.last_opened_at > kept.last_opened_at => *kept = entry,
            Some(_) => {}
            None => result.push(entry),
        }
    }
    result
}

fn order_and_limit(entries: Vec<RecentProjectEntry>, capacity: usize) -> Vec<RecentProjectEntry> {
    let (mut pinned, mut unpinned): (Vec<_>, Vec<_>) =
        entries.into_iter().partition(|entry| entry.pinned);
    // `sort_by` is stable, so equal timestamps keep the caller's order.
    pinned.sort_by(|left, right| right.last_opened_at.cmp(&left.last_opened_at));
    unpinned.sort_by(|left, right| right.last_opened_at.cmp(&left.last_opened_at));
    unpinned.truncate(capacity);
    // Pins are exempt from the capacity but still bounded by the input limit.
    pinned.truncate(MAX_ENTRIES);
    pinned.extend(unpinned);
    pinned
}

fn validate_paths(paths: &[String]) -> Result<(), CoreError> {
    if paths.len() > MAX_ACTION_PATHS {
        return Err(invalid("Too many recent project paths"));
    }
    paths.iter().try_for_each(|path| validate_path(path))
}

fn validate_path(path: &str) -> Result<(), CoreError> {
    if path.is_empty() || path.len() > MAX_PATH_BYTES || path.contains('\0') {
        return Err(invalid("Recent project path is invalid"));
    }
    Ok(())
}

fn validate_time(value: i64) -> Result<(), CoreError> {
    if value < 0 {
        return Err(invalid("Recent project time is invalid"));
    }
    Ok(())
}

fn invalid(message: &str) -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, message)
}
