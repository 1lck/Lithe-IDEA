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
pub struct LogCollectionPlan {
    /// Newest sessions first, active files before rotations, then newest native modification time.
    pub reads: Vec<LogTailRead>,
    /// True if any eligible bytes or files were omitted.
    pub truncated: bool,
}

/// Selects v2 evidence before applying file/byte budgets, keeping all active channels ahead of rotations.
pub fn plan_log_collection(
    request: PlanLogCollectionRequest,
) -> Result<LogCollectionPlan, LogError> {
    let invalid = || LogError::new(-32058, "Invalid collection inventory or selection");
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
    candidates.retain(|(session, _, _, _, channel, _)| {
        (match request.session.as_str() {
            "current" => session == &request.current_session,
            "previous" => previous.as_ref() == Some(session),
            _ => true,
        }) && request
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
    };
    let mut remaining = COLLECTION_BYTES;
    for (_, _, _, _, _, file) in candidates {
        if plan.reads.len() >= COLLECTION_FILES || remaining == 0 {
            plan.truncated = true;
            continue;
        }
        let count = file.size_bytes.min(FILE_BYTES).min(remaining);
        let offset = file.size_bytes - count;
        plan.truncated |= offset > 0;
        remaining -= count;
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
        }
    }
}
