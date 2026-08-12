mod execution;
mod git;
mod languages;
mod lsp;
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

#[cfg(test)]
mod tests;
