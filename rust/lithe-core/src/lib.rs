//! Deterministic application services shared by the macOS and Windows hosts.

use std::path::Path;

mod community;
mod debug;
mod diagnostics;
mod execution;
mod git;
mod github;
mod languages;
mod lsp;
pub mod plugins;
mod project;
mod protocol;
mod runtime;

pub use protocol::{
    CoreCommand, CoreError, CoreEvent, CoreRequest, CoreResponse, ErrorCode, ResponseData,
};

/// Executes one versioned application command and returns a JSON response.
pub fn execute_json(request: &str) -> String {
    runtime::execute_json(request)
}

/// Requests cooperative cancellation of an active operation.
///
/// Native Rust hosts use this entry point while the Swift and C++ clients keep
/// using the stable `lithe_core_cancel` C ABI.
pub fn cancel_operation(operation_id: &str) -> bool {
    protocol::cancellation::cancel(operation_id)
}

/// Derives the shared directory key for one JDT LS workspace state.
///
/// Platform hosts use this when clearing the same cache directory that the
/// Rust-owned language-server runtime selected during startup.
pub fn jdt_workspace_key(workspace_root: &Path, workspace_fingerprint: Option<&str>) -> String {
    lsp::workspace_key(workspace_root, workspace_fingerprint)
}

#[cfg(test)]
mod tests;

/// Executes a request with ordered, sanitized Git process events. The observer
/// is scoped to this call; callbacks complete before the final JSON is returned.
pub fn execute_json_with_events(
    request: &str,
    sink: std::sync::Arc<dyn Fn(&str) + Send + Sync>,
) -> String {
    git::execution_events::with_sink(sink, || {
        let response = execute_json(request);
        git::execution_events::request_finished(&response);
        response
    })
}

/// Runs the native AskPass helper before either host initializes its user interface.
pub fn git_askpass_main(prompt: &str) -> i32 {
    lithe_git_host::authentication::helper_main(prompt)
}
