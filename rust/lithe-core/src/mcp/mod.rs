//! Deterministic MCP server configuration parsing and format-preserving edits.
//!
//! Hosts read and write the actual configuration files; this module only turns
//! bounded text into normalized server definitions and computes the next file
//! content. It never consults the filesystem, the environment, or the network.

mod json_edit;
mod model;
mod parse;
mod plan;
mod source_hash;
mod toml_edit;

pub use model::{McpKeyValue, McpServer, McpTransport};
pub use parse::parse_configuration;
pub use plan::plan_write;

#[cfg(test)]
mod tests;
