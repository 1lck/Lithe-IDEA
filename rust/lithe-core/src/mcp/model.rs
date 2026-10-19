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
    /// SHA-256 of the normalized definition, used for library grouping.
    #[serde(default)]
    pub definition_hash: String,
    /// SHA-256 of the complete parsed entry, including unknown fields and name.
    /// Absent on older host requests or definitions not yet written to a source.
    #[serde(default)]
    pub source_hash: Option<String>,
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
            source_hash: None,
        };
        server.definition_hash = server.compute_hash();
        server
    }

    /// Recomputes and stores the identity hash after a definition changed.
    pub fn refresh_hash(&mut self) {
        self.definition_hash = self.compute_hash();
    }

    /// Grouping identity: name plus modeled values used by the active transport.
    ///
    /// Env and header entries are sorted here rather than only at construction:
    /// the write path deserializes definitions from the host, and its hash must
    /// match what the parser computes from the written configuration no matter
    /// what order the UI sent the entries in.
    ///
    /// Only fields the active transport actually uses are hashed. Parsers can
    /// see stray fields on an entry (an HTTP server with `command`, `args` or
    /// `env`, a stdio server with `url` or `headers`), but the write path drops
    /// them, so hashing them would make the ledger disagree with the file
    /// immediately after a write.
    fn compute_hash(&self) -> String {
        let mut canonical = String::new();
        canonical.push_str(&self.name);
        canonical.push('\n');
        canonical.push_str(self.transport.as_str());
        canonical.push('\n');
        match self.transport {
            McpTransport::Stdio => {
                canonical.push_str(self.command.as_deref().unwrap_or(""));
                canonical.push('\n');
                for arg in &self.args {
                    canonical.push_str(arg);
                    canonical.push('\u{1f}');
                }
                canonical.push('\n');
                let mut env: Vec<&McpKeyValue> = self.env.iter().collect();
                env.sort_by(|left, right| {
                    (left.key.as_str(), left.value.as_str())
                        .cmp(&(right.key.as_str(), right.value.as_str()))
                });
                for entry in env {
                    canonical.push_str(&entry.key);
                    canonical.push('=');
                    canonical.push_str(&entry.value);
                    canonical.push('\u{1f}');
                }
            }
            McpTransport::Http | McpTransport::Sse => {
                canonical.push_str(self.url.as_deref().unwrap_or(""));
                canonical.push('\n');
                let mut headers: Vec<&McpKeyValue> = self.headers.iter().collect();
                headers.sort_by(|left, right| {
                    (left.key.as_str(), left.value.as_str())
                        .cmp(&(right.key.as_str(), right.value.as_str()))
                });
                for entry in headers {
                    canonical.push_str(&entry.key);
                    canonical.push(':');
                    canonical.push_str(&entry.value);
                    canonical.push('\u{1f}');
                }
            }
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
