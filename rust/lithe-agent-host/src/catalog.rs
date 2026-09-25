//! Agents Lithe can install and launch, and how each receives an API key.
//!
//! Entries mirror the official ACP registry
//! (`cdn.agentclientprotocol.com/registry/v1/latest/registry.json`): the same
//! agent ids, npm packages, and pinned versions. A version is raised only after
//! the adapter is re-verified, because each adapter speaks its own dialect of
//! authentication and cancellation.

use serde::{Deserialize, Serialize};

/// Wire protocol of an AI provider, using the platform settings' names.
#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum ProviderProtocol {
    Responses,
    ChatCompletions,
    AnthropicMessages,
}

/// How a user-supplied API key reaches the agent. Account logins offered by
/// agents are never used.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum KeyDelivery {
    /// ACP `authenticate` with the `gateway` method; the key travels over stdio.
    Gateway,
    /// `ANTHROPIC_API_KEY` and `ANTHROPIC_BASE_URL` in the agent's environment,
    /// the only API-key input the Claude Agent SDK accepts.
    AnthropicEnvironment,
}

/// How the provider's model name reaches the agent. It is not secret, so the
/// environment is acceptable for every adapter.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ModelDelivery {
    /// `CODEX_CONFIG={"model": ...}`, merged into Codex's session config.
    CodexConfig,
    /// `ANTHROPIC_MODEL`, read by the Claude Agent SDK.
    AnthropicEnvironment,
}

/// One installable ACP adapter distributed as an npm package.
#[derive(Debug, PartialEq, Eq)]
pub struct CatalogAgent {
    /// ACP registry id, also the install directory name.
    pub id: &'static str,
    pub name: &'static str,
    pub description: &'static str,
    pub package: &'static str,
    /// Pinned, verified package version.
    pub version: &'static str,
    /// Executable the package installs under `node_modules/.bin`.
    pub bin: &'static str,
    /// Lowest Node.js major version the adapter and its dependencies run on.
    pub minimum_node_major: u32,
    pub protocol: ProviderProtocol,
    pub key_delivery: KeyDelivery,
    pub model_delivery: ModelDelivery,
    /// Whether sign-in and a conversation were verified against a real
    /// provider with this version.
    pub verified: bool,
}

pub const CATALOG: &[CatalogAgent] = &[
    CatalogAgent {
        id: "codex-acp",
        name: "Codex",
        description: "OpenAI Codex through its ACP adapter",
        package: "@agentclientprotocol/codex-acp",
        version: "1.13.1",
        bin: "codex-acp",
        // `open@11`, a dependency of the adapter, requires Node.js 20.
        minimum_node_major: 20,
        protocol: ProviderProtocol::Responses,
        key_delivery: KeyDelivery::Gateway,
        model_delivery: ModelDelivery::CodexConfig,
        verified: true,
    },
    CatalogAgent {
        id: "claude-acp",
        name: "Claude",
        description: "Claude Agent through its ACP adapter",
        package: "@agentclientprotocol/claude-agent-acp",
        version: "0.81.2",
        bin: "claude-agent-acp",
        minimum_node_major: 22,
        protocol: ProviderProtocol::AnthropicMessages,
        key_delivery: KeyDelivery::AnthropicEnvironment,
        model_delivery: ModelDelivery::AnthropicEnvironment,
        verified: false,
    },
];

pub fn find(id: &str) -> Option<&'static CatalogAgent> {
    CATALOG.iter().find(|agent| agent.id == id)
}
