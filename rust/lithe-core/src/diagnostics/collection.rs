//! Plans bounded log-tail reads from native metadata; hosts execute only the selected I/O.

use super::channel::{log_category, parse_session_directory_name, LogError};
use super::query_v2::source_channel;
use chrono::DateTime;
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;

/// Maximum aggregate native evidence supplied to one query.
const COLLECTION_BYTES: u64 = super::logging::MAX_LOG_EXPORT_BYTES as u64;
/// Maximum tail read from one physical file.
const FILE_BYTES: u64 = 2 * 1024 * 1024;
/// Maximum selected files before any native read.
const COLLECTION_FILES: usize = 200;

/// Raw native metadata; no file contents cross the planning boundary.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CollectionFile {
    /// Log-root-relative physical path.
    pub relative_path: String,
    /// Current file length in bytes.
    pub size_bytes: u64,
    /// Native RFC3339 modification instant.
    pub modified_at: String,
}

/// Query selection and native inventory, owned only for this planning operation.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlanLogCollectionRequest {
    /// Unfiltered metadata from native enumeration.
    pub files: Vec<CollectionFile>,
    /// Canonical live session basename, or empty before the first write.
    pub current_session: String,
    /// Existing product selection: all, current, or previous.
    pub session: String,
    /// Existing product category; absent selects every channel.
    pub category: Option<String>,
    /// Intersect selection with the newest N sessions in the inventory (including current).
    #[serde(default)]
    pub recent_sessions: Option<usize>,
    /// Inclusive RFC3339 cutoff: session start OR file modification must reach it.
    #[serde(default)]
    pub since: Option<String>,
}

/// One bounded native read selected by Core.
#[derive(Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct LogTailRead {
    /// Validated log-root-relative path.
    pub relative_path: String,
    /// Byte offset at which the native adapter starts reading.
    pub offset: u64,
    /// Maximum bytes the adapter may read.
    pub max_bytes: u64,
}

/// Deterministic read order and explicit omission state.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LogCollectionPlan {
    /// Newest sessions first, active files before rotations, then newest native modification time.
    pub reads: Vec<LogTailRead>,
    /// True if any eligible bytes or files were omitted.
    pub truncated: bool,
    /// Sum of bounded reads, before compression; no native byte estimates are inferred.
    pub estimated_bytes: u64,
    /// Eligible session names before budgets, newest first; excludes sessions with no selected files.
    pub sessions: Vec<String>,
}

/// Selects v2 evidence before applying file/byte budgets, keeping all active channels ahead of rotations.
pub fn plan_log_collection(
    request: PlanLogCollectionRequest,
) -> Result<LogCollectionPlan, LogError> {
    let invalid = || LogError::new(-32058, "Invalid collection inventory or selection");
    if request.files.len() > 10000
        || request
            .recent_sessions
            .is_some_and(|n| !(1..=10).contains(&n))
    {
        return Err(invalid());
    }
    let since = request
        .since
        .as_deref()
        .map(DateTime::parse_from_rfc3339)
        .transpose()
        .map_err(|_| LogError::new(-32035, "Invalid timestamp"))?;
    if !["all", "current", "previous"].contains(&request.session.as_str())
        || request
            .category
            .as_ref()
            .is_some_and(|category| !super::logging::LOG_CATEGORIES.contains(&category.as_str()))
    {
        return Err(invalid());
    }
    if !request.current_session.is_empty() {
        parse_session_directory_name(&request.current_session)?;
    }
    let mut seen = BTreeSet::new();
    let mut candidates = Vec::new();
    for file in request.files {
        if !seen.insert(file.relative_path.clone()) {
            return Err(invalid());
        }
        // Native inventories also contain legacy and plugin-owned files. They
        // participate in retention, but are not structured timeline evidence.
        let Some(rest) = file.relative_path.strip_prefix("sessions/") else {
            continue;
        };
        let Some((session, relative)) = rest.split_once('/') else {
            continue;
        };
        let Ok(identity) = parse_session_directory_name(session) else {
            continue;
        };
        let Ok((channel, legacy)) = source_channel(&file.relative_path) else {
            continue;
        };
        if legacy || relative.contains("/files/") {
            continue;
        }
        let modified = DateTime::parse_from_rfc3339(&file.modified_at)
            .map_err(|_| LogError::new(-32035, "Invalid timestamp"))?;
        let started = DateTime::parse_from_rfc3339(&identity.started).map_err(|_| invalid())?;
        let rotation = relative
            .strip_suffix(".log")
            .and_then(|stem| stem.rsplit_once('~'))
            .and_then(|(_, index)| index.parse::<u32>().ok())
            .unwrap_or(0);
        candidates.push((
            session.to_owned(),
            started,
            rotation,
            modified,
            channel,
            file,
        ));
    }
    let previous = candidates
        .iter()
        .filter(|(name, ..)| name != &request.current_session)
        .max_by(|a, b| a.1.cmp(&b.1).then_with(|| a.0.cmp(&b.0)))
        .map(|v| v.0.clone());
    let mut newest: Vec<_> = candidates.iter().map(|c| (c.1, c.0.clone())).collect();
    if !request.current_session.is_empty() {
        let current = parse_session_directory_name(&request.current_session)?;
        newest.push((
            DateTime::parse_from_rfc3339(&current.started).map_err(|_| invalid())?,
            request.current_session.clone(),
        ));
    }
    newest.sort_by(|a, b| b.cmp(a));
    newest.dedup();
    let mut recent = BTreeSet::new();
    if request.recent_sessions.is_some() && !request.current_session.is_empty() {
        // The live session remains included even if native clocks give an inactive directory
        // a future timestamp. Missing live files still consume one requested session slot.
        recent.insert(request.current_session.clone());
    }
    for (_, session) in newest {
        if recent.len() >= request.recent_sessions.unwrap_or(usize::MAX) {
            break;
        }
        recent.insert(session);
    }
    candidates.retain(|(session, started, _, modified, channel, _)| {
        (match request.session.as_str() {
            "current" => session == &request.current_session,
            "previous" => previous.as_ref() == Some(session),
            _ => true,
        }) && recent.contains(session)
            && since.is_none_or(|bound| *started >= bound || *modified >= bound)
            && request
                .category
                .as_ref()
                .is_none_or(|category| log_category(channel) == category)
    });
    candidates.sort_by(|a, b| {
        b.1.cmp(&a.1)
            .then_with(|| b.0.cmp(&a.0))
            .then_with(|| a.2.cmp(&b.2))
            .then_with(|| b.3.cmp(&a.3))
            .then_with(|| a.5.relative_path.cmp(&b.5.relative_path))
    });
    let mut plan = LogCollectionPlan {
        reads: Vec::new(),
        truncated: false,
        estimated_bytes: 0,
        sessions: Vec::new(),
    };
    let mut remaining = COLLECTION_BYTES;
    for (session, _, _, _, _, file) in candidates {
        if plan.sessions.last() != Some(&session) {
            plan.sessions.push(session);
        }
        if plan.reads.len() >= COLLECTION_FILES || remaining == 0 {
            plan.truncated = true;
            continue;
        }
        let count = file.size_bytes.min(FILE_BYTES).min(remaining);
        let offset = file.size_bytes - count;
        plan.truncated |= offset > 0;
        remaining -= count;
        plan.estimated_bytes += count;
        plan.reads.push(LogTailRead {
            relative_path: file.relative_path,
            offset,
            max_bytes: count,
        });
    }
    Ok(plan)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_channel_root_keeps_an_existing_product_category() {
        for (root, category) in [
            ("app", "application"),
            ("update", "application"),
            ("remote", "application"),
            ("agent", "application"),
            ("editor", "language"),
            ("lsp", "language"),
            ("vcs", "git"),
            ("perf", "performance"),
            ("run", "run"),
            ("debug", "run"),
            ("terminal", "run"),
            ("plugins", "plugins"),
            ("_overflow", "application"),
        ] {
            assert_eq!(log_category(root), category, "{root}");
        }
    }

    #[test]
    fn collection_dispatch_rejects_duplicate_inventories_with_a_distinct_code() {
        let request = serde_json::json!({"version":1,"command":"diagnostics.planLogCollection","payload":{
            "files":[],"currentSession":"","session":"all"}});
        let response: serde_json::Value =
            serde_json::from_str(&crate::runtime::execute_json(&request.to_string())).unwrap();
        assert_eq!(response["data"]["result"]["reads"], serde_json::json!([]));
        let file = serde_json::json!({"relativePath":"sessions/2026-11-03T00-00-00_abcdef12/app.log","sizeBytes":1,"modifiedAt":"2026-11-03T01:00:00Z"});
        let input =
            serde_json::json!({"files":[file.clone(),file],"currentSession":"","session":"all"});
        assert_eq!(
            plan_log_collection(serde_json::from_value(input).unwrap())
                .unwrap_err()
                .code,
            -32058
        );
    }

    #[test]
    fn shared_collection_fixture_keeps_active_channels_and_category_compatibility() {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../../shared/fixtures/diagnostics/logging-v2.json"
        ))
        .unwrap();
        for case in fixture["collection"].as_array().unwrap() {
            let plan =
                plan_log_collection(serde_json::from_value(case["request"].clone()).unwrap())
                    .unwrap();
            assert_eq!(
                serde_json::json!(plan.reads),
                case["reads"],
                "{}",
                case["name"]
            );
            assert_eq!(plan.truncated, case["truncated"], "{}", case["name"]);
            assert_eq!(
                plan.estimated_bytes,
                case["estimatedBytes"].as_u64().unwrap()
            );
            assert_eq!(serde_json::json!(plan.sessions), case["sessions"]);
        }
    }
}

#[cfg(test)]
mod selection_tests {
    use super::*;
    use serde_json::json;
    #[test]
    fn recent_time_session_and_category_are_intersections_before_budgets() {
        let current = "2026-11-03T00-00-00_33333333";
        let files = json!([
            {"relativePath":format!("sessions/{current}/app.log"),"sizeBytes":10,"modifiedAt":"2026-11-01T00:00:00Z"},
            {"relativePath":"sessions/2026-11-02T00-00-00_22222222/app.log","sizeBytes":20,"modifiedAt":"2026-11-03T01:00:00Z"},
            {"relativePath":"sessions/2026-11-01T00-00-00_11111111/app.log","sizeBytes":30,"modifiedAt":"2026-11-03T01:00:00Z"},
            {"relativePath":"sessions/2026-11-02T00-00-00_22222222/vcs/git.log","sizeBytes":40,"modifiedAt":"2026-11-03T01:00:00Z"}
        ]);
        let input = json!({"files":files,"currentSession":current,"session":"all","category":"application","recentSessions":2,"since":"2026-11-02T12:00:00Z"});
        let plan = plan_log_collection(serde_json::from_value(input.clone()).unwrap()).unwrap();
        assert_eq!(plan.estimated_bytes, 30);
        assert_eq!(plan.sessions, vec![current, "2026-11-02T00-00-00_22222222"]);
        for (session, expected) in [("current", 10), ("previous", 20)] {
            let mut selected = input.clone();
            selected["session"] = json!(session);
            assert_eq!(
                plan_log_collection(serde_json::from_value(selected).unwrap())
                    .unwrap()
                    .estimated_bytes,
                expected
            );
        }
        let mut selected = input.clone();
        selected["session"] = json!("previous");
        selected["recentSessions"] = json!(1);
        assert!(
            plan_log_collection(serde_json::from_value(selected).unwrap())
                .unwrap()
                .sessions
                .is_empty()
        );
        for recent in [0, 11] {
            let mut selected = input.clone();
            selected["recentSessions"] = json!(recent);
            assert_eq!(
                plan_log_collection(serde_json::from_value(selected).unwrap())
                    .unwrap_err()
                    .code,
                -32058
            );
        }
    }
}

#[cfg(test)]
mod clock_skew_tests {
    #[test]
    fn recent_selection_always_reserves_a_slot_for_the_live_session() {
        let current = "2026-11-02T00-00-00_22222222";
        let input = serde_json::json!({"files":[
            {"relativePath":format!("sessions/{current}/app.log"),"sizeBytes":10,"modifiedAt":"2026-11-02T00:00:00Z"},
            {"relativePath":"sessions/2026-11-03T00-00-00_33333333/app.log","sizeBytes":20,"modifiedAt":"2026-11-03T00:00:00Z"}
        ],"currentSession":current,"session":"all","recentSessions":1});
        let plan = super::plan_log_collection(serde_json::from_value(input).unwrap()).unwrap();
        assert_eq!(plan.sessions, vec![current]);
        assert_eq!(plan.estimated_bytes, 10);
    }
}
