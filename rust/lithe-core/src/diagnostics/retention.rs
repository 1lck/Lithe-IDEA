//! Plans deterministic log cleanup from host snapshots; never deletes files or reads a clock.

use super::channel::{parse_session_directory_name, validate_segment, LogError};
use chrono::DateTime;
use serde::{Deserialize, Serialize};
use std::collections::{BTreeMap, BTreeSet};

/// Default per-channel segment rotation threshold in bytes.
pub const CHANNEL_SEGMENT_BYTES: u64 = 10 * 1024 * 1024;
/// Maximum segments including the active file and two numbered siblings.
pub const MAX_CHANNEL_SEGMENTS: u32 = 3;
/// Default expiration interval in milliseconds, exactly thirty days.
pub const SESSION_MAX_AGE_MS: i64 = 30 * 24 * 60 * 60 * 1000;

/// Caller-owned file metadata relative to its session, or to the log root for legacy files.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RetentionFile {
    /// Slash-separated safe path; no absolute, empty, or traversal components.
    pub relative_path: String,
    /// Uncompressed disk bytes.
    pub size_bytes: u64,
    /// RFC3339 modification instant provided by the native adapter.
    pub modified_at: String,
}
/// One complete native session inventory.
#[derive(Debug, Deserialize)]
pub struct RetentionSession {
    /// Canonical directory basename under sessions/.
    pub name: String,
    /// Complete file inventory; mutable host state is not retained by Core.
    pub files: Vec<RetentionFile>,
}
/// Explicit disk budgets with defaults suitable for production hosts.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct RetentionLimits {
    /// Expiration duration in milliseconds.
    pub max_age_ms: i64,
    /// Combined sessions and legacy bytes.
    pub total_bytes: u64,
    /// Separate performance-file budget across sessions.
    pub perf_bytes: u64,
    /// Per-plugin, per-session native files/ budget.
    pub plugin_files_bytes: u64,
}
impl Default for RetentionLimits {
    fn default() -> Self {
        Self {
            max_age_ms: SESSION_MAX_AGE_MS,
            total_bytes: 100 * 1024 * 1024,
            perf_bytes: 20 * 1024 * 1024,
            plugin_files_bytes: 20 * 1024 * 1024,
        }
    }
}
/// Owned input snapshot. Current-session protection applies to every planned deletion.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlanLogRetentionRequest {
    /// Complete session inventories under a writable log root.
    #[serde(default)]
    pub sessions: Vec<RetentionSession>,
    /// Legacy category/lithe.*.log files; these expire only by age, never by total pressure.
    #[serde(default)]
    pub legacy_files: Vec<RetentionFile>,
    /// Protected live session basename; an empty value means no live session.
    pub current_session: String,
    /// Caller-supplied RFC3339 evaluation instant.
    pub now: String,
    /// Optional budget overrides; omitted fields use production defaults.
    #[serde(default)]
    pub limits: RetentionLimits,
    /// Allows deleting oldest plugin files at startup; runtime checks only emit warnings.
    #[serde(default)]
    pub startup_cleanup: bool,
}
/// Stable reason for one removal candidate.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum RetentionReason {
    /// Whole expired session or expired legacy file.
    Expired,
    /// Whole session removed to reduce combined disk usage.
    TotalBudget,
    /// Individual performance file removed from an old session.
    PerfBudget,
    /// Individual plugin-owned file removed during startup cleanup.
    PluginFilesBudget,
}
/// One root-relative path to delete; native adapters perform and report actual I/O.
#[derive(Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RetentionDeletion {
    /// Path relative to the writable log root, never installation resources.
    pub relative_path: String,
    /// True means delete this entire session directory.
    pub directory: bool,
    /// Stable policy reason for the deletion.
    pub reason: RetentionReason,
}
/// A plugin-owned directory exceeded its budget in the input snapshot.
#[derive(Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PluginFilesWarning {
    /// Session that owns the files.
    pub session: String,
    /// Validated plugin identity.
    pub plugin_id: String,
    /// Root-relative plugin files directory.
    pub relative_path: String,
    /// Total observed bytes before cleanup.
    pub size_bytes: u64,
    /// Applied per-plugin budget.
    pub limit_bytes: u64,
}
/// Deterministically ordered plan without side effects.
#[derive(Debug, Serialize)]
pub struct LogRetentionPlan {
    /// Whole sessions replace any redundant child deletions.
    pub deletions: Vec<RetentionDeletion>,
    /// Runtime warnings also remain present when startup cleanup plans file removal.
    pub warnings: Vec<PluginFilesWarning>,
}

fn timestamp(value: &str) -> Result<i64, LogError> {
    DateTime::parse_from_rfc3339(value)
        .map(|v| v.timestamp_millis())
        .map_err(|_| LogError::new(-32035, "Invalid timestamp"))
}
fn safe_path(path: &str) -> bool {
    !path.is_empty()
        && !path.contains(['\\', ':'])
        && !path.chars().any(char::is_control)
        && path
            .split('/')
            .all(|p| !p.is_empty() && p != "." && p != "..")
}
fn perf(path: &str) -> bool {
    path == "perf.log"
        || path.starts_with("perf/")
        || (path.starts_with("perf~") && path.ends_with(".log"))
}
fn plugin(path: &str) -> Option<&str> {
    let mut parts = path.split('/');
    if parts.next()? != "plugins" {
        return None;
    }
    let id = parts.next()?;
    if parts.next()? != "files" || parts.next().is_none() {
        return None;
    }
    Some(id)
}
fn file_path(session: &str, path: &str) -> String {
    format!("sessions/{session}/{path}")
}

/// Produces an age/total/performance/plugin-budget cleanup plan, protecting all live-session files.
/// Rejects unsafe or duplicate inventory paths rather than creating ambiguous deletion instructions.
pub fn plan_log_retention(request: PlanLogRetentionRequest) -> Result<LogRetentionPlan, LogError> {
    let now = timestamp(&request.now)?;
    if request.limits.max_age_ms < 0 {
        return Err(LogError::new(
            -32049,
            "Invalid retention inventory or limits",
        ));
    }
    if !request.current_session.is_empty() {
        parse_session_directory_name(&request.current_session)?;
    }
    let mut sessions = Vec::new();
    let mut seen = BTreeSet::new();
    for session in request.sessions {
        let started = timestamp(&parse_session_directory_name(&session.name)?.started)?;
        if !seen.insert(session.name.clone()) {
            return Err(LogError::new(
                -32049,
                "Invalid retention inventory or limits",
            ));
        }
        let mut files = Vec::new();
        let mut paths = BTreeSet::new();
        for file in session.files {
            if !safe_path(&file.relative_path) || !paths.insert(file.relative_path.clone()) {
                return Err(LogError::new(
                    -32049,
                    "Invalid retention inventory or limits",
                ));
            }
            if let Some(id) = plugin(&file.relative_path) {
                validate_segment(id)?;
            }
            let modified = timestamp(&file.modified_at)?;
            files.push((file, modified));
        }
        files.sort_by(|a, b| {
            a.1.cmp(&b.1)
                .then_with(|| a.0.relative_path.cmp(&b.0.relative_path))
        });
        sessions.push((session.name, started, files));
    }
    sessions.sort_by(|a, b| a.1.cmp(&b.1).then_with(|| a.0.cmp(&b.0)));
    let mut plan = LogRetentionPlan {
        deletions: Vec::new(),
        warnings: Vec::new(),
    };
    let mut deleted_sessions = BTreeSet::new();
    let mut total = 0u128;
    for file in request.legacy_files {
        let parts: Vec<_> = file.relative_path.split('/').collect();
        if !safe_path(&file.relative_path)
            || parts.len() != 2
            || !super::logging::LOG_CATEGORIES.contains(&parts[0])
            || !parts[1].starts_with("lithe.")
            || !parts[1].ends_with(".log")
            || !seen.insert(file.relative_path.clone())
        {
            return Err(LogError::new(
                -32049,
                "Invalid retention inventory or limits",
            ));
        }
        if now.saturating_sub(timestamp(&file.modified_at)?) > request.limits.max_age_ms {
            plan.deletions.push(RetentionDeletion {
                relative_path: file.relative_path,
                directory: false,
                reason: RetentionReason::Expired,
            });
        } else {
            total += u128::from(file.size_bytes);
        }
    }
    for (name, started, files) in &sessions {
        if name != &request.current_session
            && now.saturating_sub(*started) > request.limits.max_age_ms
        {
            deleted_sessions.insert(name.clone());
            plan.deletions.push(RetentionDeletion {
                relative_path: format!("sessions/{name}"),
                directory: true,
                reason: RetentionReason::Expired,
            });
        } else {
            total += files
                .iter()
                .map(|(f, _)| u128::from(f.size_bytes))
                .sum::<u128>();
        }
    }
    // Apply combined pressure to whole sessions before the independent file budgets.
    for (name, _, files) in &sessions {
        if total <= u128::from(request.limits.total_bytes) {
            break;
        }
        if name == &request.current_session || deleted_sessions.contains(name) {
            continue;
        }
        total -= files
            .iter()
            .map(|(file, _)| u128::from(file.size_bytes))
            .sum::<u128>();
        deleted_sessions.insert(name.clone());
        plan.deletions.push(RetentionDeletion {
            relative_path: format!("sessions/{name}"),
            directory: true,
            reason: RetentionReason::TotalBudget,
        });
    }
    let mut perf_size: u128 = sessions
        .iter()
        .filter(|(name, _, _)| !deleted_sessions.contains(name))
        .flat_map(|(_, _, files)| files)
        .filter(|(f, _)| perf(&f.relative_path))
        .map(|(f, _)| u128::from(f.size_bytes))
        .sum();
    for (name, _, files) in &sessions {
        if deleted_sessions.contains(name) {
            continue;
        }
        if name != &request.current_session {
            for (file, _) in files.iter().filter(|(f, _)| perf(&f.relative_path)) {
                if perf_size <= u128::from(request.limits.perf_bytes) {
                    break;
                }
                perf_size -= u128::from(file.size_bytes);
                let path = file_path(name, &file.relative_path);
                plan.deletions.push(RetentionDeletion {
                    relative_path: path,
                    directory: false,
                    reason: RetentionReason::PerfBudget,
                });
            }
        }
        let mut groups: BTreeMap<&str, Vec<&RetentionFile>> = BTreeMap::new();
        for (file, _) in files {
            if let Some(id) = plugin(&file.relative_path) {
                groups.entry(id).or_default().push(file);
            }
        }
        for (id, group) in groups {
            let mut size: u128 = group.iter().map(|f| u128::from(f.size_bytes)).sum();
            if size <= u128::from(request.limits.plugin_files_bytes) {
                continue;
            }
            plan.warnings.push(PluginFilesWarning {
                session: name.clone(),
                plugin_id: id.into(),
                relative_path: format!("sessions/{name}/plugins/{id}/files/"),
                size_bytes: size.min(u128::from(u64::MAX)) as u64,
                limit_bytes: request.limits.plugin_files_bytes,
            });
            if request.startup_cleanup && name != &request.current_session {
                for file in group {
                    if size <= u128::from(request.limits.plugin_files_bytes) {
                        break;
                    }
                    size -= u128::from(file.size_bytes);
                    let path = file_path(name, &file.relative_path);
                    plan.deletions.push(RetentionDeletion {
                        relative_path: path,
                        directory: false,
                        reason: RetentionReason::PluginFilesBudget,
                    });
                }
            }
        }
    }
    plan.deletions
        .sort_by(|a, b| a.relative_path.cmp(&b.relative_path));
    plan.warnings
        .sort_by(|a, b| a.relative_path.cmp(&b.relative_path));
    Ok(plan)
}

/// A write that would exceed this threshold should rotate before appending.
pub fn should_rotate(size_bytes: u64) -> bool {
    size_bytes > CHANNEL_SEGMENT_BYTES
}

/// Returns existing rotation indices to delete after shifting siblings by one.
/// Active index zero becomes one, one becomes two, and indices two or above are removed.
pub fn rotation_indices_to_delete(existing_indices: &[u32]) -> Vec<u32> {
    existing_indices
        .iter()
        .copied()
        .filter(|i| *i >= MAX_CHANNEL_SEGMENTS - 1)
        .collect::<BTreeSet<_>>()
        .into_iter()
        .collect()
}

/// Resolves obsolete pre-shift segments to paths relative to their writable session directory.
pub fn rotation_paths_to_delete(
    channel: &super::channel::LogChannel,
    existing_indices: &[u32],
) -> Vec<String> {
    rotation_indices_to_delete(existing_indices)
        .into_iter()
        .map(|index| super::channel::relative_log_path(channel, index))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn retention_is_order_independent_and_whole_sessions_supersede_children() {
        let mut request = json!({"now":"2026-11-03T00:00:00Z","currentSession":"", "limits":{"totalBytes":1,"perfBytes":0},"sessions":[
            {"name":"2026-11-02T00-00-00_bbbbbbbb","files":[{"relativePath":"app.log","sizeBytes":5,"modifiedAt":"2026-11-02T01:00:00Z"}]},
            {"name":"2026-11-01T00-00-00_aaaaaaaa","files":[{"relativePath":"app.log","sizeBytes":5,"modifiedAt":"2026-11-01T01:00:00Z"},{"relativePath":"perf.log","sizeBytes":5,"modifiedAt":"2026-11-01T01:00:00Z"}]}
        ]});
        let first = plan_log_retention(serde_json::from_value(request.clone()).unwrap()).unwrap();
        request["sessions"].as_array_mut().unwrap().reverse();
        let second = plan_log_retention(serde_json::from_value(request).unwrap()).unwrap();
        assert_eq!(first.deletions, second.deletions);
        assert_eq!(first.deletions.len(), 2);
        assert!(first
            .deletions
            .iter()
            .all(|deletion| deletion.directory && deletion.reason == RetentionReason::TotalBudget));
    }

    #[test]
    fn retention_rejects_unsafe_and_duplicate_file_inventories() {
        for path in [
            "../outside",
            "/absolute",
            "plugins/p/files/../escape",
            "C:\\outside",
        ] {
            let request = json!({"now":"2026-11-03T00:00:00Z","currentSession":"","sessions":[{"name":"2026-11-01T00-00-00_aaaaaaaa","files":[{"relativePath":path,"sizeBytes":1,"modifiedAt":"2026-11-01T00:00:00Z"}]}]});
            assert_eq!(
                plan_log_retention(serde_json::from_value(request).unwrap())
                    .unwrap_err()
                    .code,
                -32049
            );
        }
        let file =
            json!({"relativePath":"app.log","sizeBytes":1,"modifiedAt":"2026-11-01T00:00:00Z"});
        let request = json!({"now":"2026-11-03T00:00:00Z","currentSession":"","sessions":[{"name":"2026-11-01T00-00-00_aaaaaaaa","files":[file.clone(),file]}]});
        assert_eq!(
            plan_log_retention(serde_json::from_value(request).unwrap())
                .unwrap_err()
                .code,
            -32049
        );
    }
}
