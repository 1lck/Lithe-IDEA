//! Typed Agent edit rollback planning. Evidence rules belong to Agent Host;
//! platforms own path containment, encoding, guarded writes and Trash.

use crate::protocol::{cancellation, CoreError, ErrorCode};
use lithe_agent_host::edit_review;
use serde_json::Value;

/// Plans `agent.edits.reversePlan` without touching the file system.
/// Rollback conflicts are successful plans; only malformed payloads fail.
pub(crate) fn reverse_plan(request: edit_review::ReverseRequest) -> Result<Value, CoreError> {
    cancellation::check()?;
    serde_json::to_value(edit_review::reverse_plan(&request))
        .map_err(|issue| CoreError::new(ErrorCode::Unknown, issue.to_string()))
}
