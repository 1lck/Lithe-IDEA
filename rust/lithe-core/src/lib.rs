//! Deterministic application services shared by the macOS and Windows hosts.

mod community;
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

#[cfg(test)]
mod tests;
