//! Paged, platform-neutral palette slot assignment for ordered repository identities.

use crate::protocol::{CoreError, ErrorCode};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::HashSet;

/// A small page keeps workspace identities bounded across native and WebView IPC.
const MAX_PAGE: usize = 128;
const MAX_ID_BYTES: usize = 4096;
const SLOT_COUNT: usize = 8;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Request {
    /// Index of the first ID in the full, ordered, unique repository list.
    offset: usize,
    /// Size of that list before visibility filters such as hidden worktrees.
    total_count: usize,
    repository_ids: Vec<String>,
}

pub(crate) fn assign_command(payload: Value) -> Result<Value, CoreError> {
    let request: Request = serde_json::from_value(payload).map_err(|_| invalid())?;
    if request.repository_ids.len() > MAX_PAGE
        || request.offset > request.total_count
        || request.repository_ids.len() > request.total_count - request.offset
    {
        return Err(invalid());
    }
    let mut seen = HashSet::new();
    let mut assignments = Vec::with_capacity(request.repository_ids.len());
    for (index, id) in request.repository_ids.into_iter().enumerate() {
        if id.is_empty() || id.len() > MAX_ID_BYTES || !seen.insert(id.clone()) {
            return Err(invalid());
        }
        assignments.push(json!({"id": id, "slot": (request.offset + index) % SLOT_COUNT}));
    }
    Ok(
        json!({"assignments": assignments, "fallbackSlot": 0, "showColors": request.total_count > 1}),
    )
}

fn invalid() -> CoreError {
    CoreError::new(
        ErrorCode::InvalidRequest,
        "Invalid repository color assignment page",
    )
}
