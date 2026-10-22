//! Deterministic MCP server configuration parsing and format-preserving edits.
//!
//! Hosts read and write the actual configuration files; this module only turns
//! bounded text into normalized server definitions and computes the next file
//! content. It never consults the filesystem, the environment, or the network.

mod json_edit;
mod model;
mod parse;
mod plan;
mod registry;
mod source_hash;
mod toml_edit;
mod tools;

pub use model::{McpKeyValue, McpServer, McpTransport};
pub use parse::parse_configuration;
pub use plan::plan_write;
pub use registry::{featured_registry, parse_registry};
pub use tools::{command_line, tool_policy};

/// Bridges a user-requested probe to the process/network owner in Agent Host.
pub(crate) fn probe(
    request: lithe_agent_host::mcp_probe::Request,
) -> Result<serde_json::Value, crate::protocol::CoreError> {
    use crate::protocol::{cancellation, CoreError, ErrorCode};
    cancellation::check()?;
    let result = lithe_agent_host::mcp_probe::execute(request, &|| cancellation::check().is_err());
    cancellation::check()?;
    result.map_err(|error| {
        use lithe_agent_host::mcp_probe::Error;
        let (code, message) = match error {
            Error::Invalid => (
                ErrorCode::InvalidRequest,
                "Check the MCP command, URL and headers.",
            ),
            Error::Unsupported => (
                ErrorCode::NotSupported,
                "Legacy SSE probing is unavailable. Use the publisher's Streamable HTTP endpoint.",
            ),
            Error::Start => (
                ErrorCode::RuntimeMissing,
                "Could not start the MCP command. Check its executable and runtime.",
            ),
            Error::Connection => (
                ErrorCode::ProcessFailed,
                "MCP connection failed. Check the server, network and authentication.",
            ),
            Error::Limit => (
                ErrorCode::InvalidRequest,
                "MCP tool metadata exceeded the inspection limit.",
            ),
            Error::Timeout => (
                ErrorCode::TimedOut,
                "MCP detection timed out after 30 seconds.",
            ),
            Error::Cancelled => (ErrorCode::Cancelled, "MCP detection was cancelled."),
        };
        CoreError::new(code, message)
    })
}

#[cfg(test)]
mod tests;
