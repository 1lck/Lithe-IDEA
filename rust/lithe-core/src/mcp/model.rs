//! Normalized MCP server definitions shared by discovery and editing.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

/// Transport an Agent uses to reach an MCP server.
#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum McpTransport {
    /// A child process spoken to over standard input and output.
    Stdio,
    /// A streamable HTTP endpoint.
    Http,
    /// A legacy server-sent-events endpoint.
    Sse,
}

impl McpTransport {
    /// Stable wire value used in configuration and identity hashing.
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Stdio => "stdio",
            Self::Http => "http",
            Self::Sse => "sse",
        }
    }
}

/// One environment variable or HTTP header entry.
///
/// Entries stay ordered by key so configuration text and identity hashes are
/// deterministic regardless of the order the user typed them.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct McpKeyValue {
    /// Variable or header name.
    pub key: String,
    /// Variable or header value. Never logged by Core.
    pub value: String,
}

/// A server definition normalized across Agent configuration formats.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct McpServer {
    /// Library key and configuration entry name.
    pub name: String,
    /// Transport used to start or reach the server.
    pub transport: McpTransport,
    /// Executable for `stdio` servers.
    pub command: Option<String>,
    /// Arguments passed to `command`.
    #[serde(default)]
    pub args: Vec<String>,
    /// Environment entries for `stdio` servers.
    #[serde(default)]
    pub env: Vec<McpKeyValue>,
    /// Endpoint for `http` and `sse` servers.
    pub url: Option<String>,
    /// Request headers for `http` and `sse` servers.
    #[serde(default)]
    pub headers: Vec<McpKeyValue>,
    /// SHA-256 of the normalized definition, used for ownership checks.
    #[serde(default)]
    pub definition_hash: String,
}

impl McpServer {
    /// Builds a definition and fills in its identity hash.
    pub fn new(
        name: String,
        transport: McpTransport,
        command: Option<String>,
        mut args: Vec<String>,
        mut env: Vec<McpKeyValue>,
        url: Option<String>,
        mut headers: Vec<McpKeyValue>,
    ) -> Self {
        args.shrink_to_fit();
        env.sort_by(|left, right| left.key.cmp(&right.key));
        headers.sort_by(|left, right| left.key.cmp(&right.key));
        let mut server = Self {
            name,
            transport,
            command,
            args,
            env,
            url,
            headers,
            definition_hash: String::new(),
        };
        server.definition_hash = server.compute_hash();
        server
    }

    /// Recomputes and stores the identity hash after a definition changed.
    pub fn refresh_hash(&mut self) {
        self.definition_hash = self.compute_hash();
    }

    /// Canonical identity: name plus every value that affects how the server runs.
    fn compute_hash(&self) -> String {
        let mut canonical = String::new();
        canonical.push_str(&self.name);
        canonical.push('\n');
        canonical.push_str(self.transport.as_str());
        canonical.push('\n');
        canonical.push_str(self.command.as_deref().unwrap_or(""));
        canonical.push('\n');
        for arg in &self.args {
            canonical.push_str(arg);
            canonical.push('\u{1f}');
        }
        canonical.push('\n');
        for entry in &self.env {
            canonical.push_str(&entry.key);
            canonical.push('=');
            canonical.push_str(&entry.value);
            canonical.push('\u{1f}');
        }
        canonical.push('\n');
        canonical.push_str(self.url.as_deref().unwrap_or(""));
        canonical.push('\n');
        for entry in &self.headers {
            canonical.push_str(&entry.key);
            canonical.push(':');
            canonical.push_str(&entry.value);
            canonical.push('\u{1f}');
        }
        hex(&Sha256::digest(canonical.as_bytes()))
    }
}

/// Lowercase hexadecimal encoding for identity hashes.
pub fn hex(bytes: &[u8]) -> String {
    const DIGITS: &[u8; 16] = b"0123456789abcdef";
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        output.push(DIGITS[(byte >> 4) as usize] as char);
        output.push(DIGITS[(byte & 0x0f) as usize] as char);
    }
    output
}
