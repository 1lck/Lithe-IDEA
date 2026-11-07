//! Pasted-image retention dispatch. Listing and deleting files belong to the platform.

use crate::protocol::{CoreError, ErrorCode};
use lithe_agent_host::attachment_retention;
use serde_json::Value;

/// Decides which pasted images may be deleted; reads and writes no files.
pub(crate) fn retention_plan(request: attachment_retention::Request) -> Result<Value, CoreError> {
    serde_json::to_value(attachment_retention::plan(&request))
        .map_err(|issue| CoreError::new(ErrorCode::Unknown, issue.to_string()))
}
