//! Typed Hook management dispatch. Native files and execution belong to Agent Host.

use crate::protocol::{cancellation, CoreError, ErrorCode};
use lithe_agent_host::hooks;
use serde_json::Value;

/// Synchronizes explicit user edits without executing commands or granting trust.
pub(crate) fn execute(request: hooks::Request) -> Result<Value, CoreError> {
    cancellation::check()?;
    let library = hooks::execute(request, &|| cancellation::check().is_err()).map_err(|issue| {
        let code = match issue.reason {
            "cancelled" => ErrorCode::Cancelled,
            "file_access" | "unsafe_file" => ErrorCode::PermissionDenied,
            _ => ErrorCode::InvalidRequest,
        };
        CoreError::new(code, issue.message).with_details(issue.reason)
    })?;
    serde_json::to_value(library)
        .map_err(|issue| CoreError::new(ErrorCode::Unknown, issue.to_string()))
}
