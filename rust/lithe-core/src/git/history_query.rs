//! Shared commit-date conversion and bounded history date filtering.

use crate::protocol::{CoreError, ErrorCode};
use chrono::{DateTime, FixedOffset, NaiveDateTime, TimeZone};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::HashSet;

const MAX_ENTRIES: usize = 4096;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Entry {
    id: String,
    date: String,
    #[serde(default)]
    utc_offset_minutes: Option<i32>,
    #[serde(default)]
    fallback_unix_seconds: Option<f64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Request {
    entries: Vec<Entry>,
    #[serde(default)]
    after_unix_seconds: Option<f64>,
    #[serde(default)]
    before_unix_seconds: Option<f64>,
}

// Offset-bearing Git dates identify an instant; without one, only an explicit
// ISO-8601 zone or a platform-provided legacy fallback can identify that instant.
pub(super) fn commit_timestamp(date: &str, offset: Option<i32>) -> Option<i64> {
    if let Some(minutes) = offset {
        let offset = FixedOffset::east_opt(minutes.checked_mul(60)?)?;
        let date = NaiveDateTime::parse_from_str(date, "%Y/%m/%d %H:%M").ok()?;
        return offset
            .from_local_datetime(&date)
            .single()
            .map(|date| date.timestamp());
    }
    DateTime::parse_from_rfc3339(date)
        .ok()
        .map(|date| date.timestamp())
}

pub(crate) fn query_command(payload: Value) -> Result<Value, CoreError> {
    let request: Request = serde_json::from_value(payload).map_err(|_| invalid())?;
    if request.entries.len() > MAX_ENTRIES
        || request
            .after_unix_seconds
            .is_some_and(|value| !value.is_finite())
        || request
            .before_unix_seconds
            .is_some_and(|value| !value.is_finite())
    {
        return Err(invalid());
    }
    let mut seen = HashSet::new();
    let mut matching_ids = Vec::new();
    for entry in request.entries {
        if entry.id.is_empty()
            || entry.id.len() > 256
            || entry.date.len() > 128
            || !seen.insert(entry.id.clone())
        {
            return Err(invalid());
        }
        let timestamp = commit_timestamp(&entry.date, entry.utc_offset_minutes)
            .map(|value| value as f64)
            .or_else(|| {
                (entry.utc_offset_minutes.is_none())
                    .then_some(entry.fallback_unix_seconds)
                    .flatten()
                    .filter(|value| value.is_finite())
            });
        if timestamp.is_some_and(|value| {
            request
                .after_unix_seconds
                .is_none_or(|after| value >= after)
                && request
                    .before_unix_seconds
                    .is_none_or(|before| value < before)
        }) {
            matching_ids.push(entry.id);
        }
    }
    Ok(json!({"matchingIds": matching_ids}))
}

fn invalid() -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, "Invalid Git history date query")
}
