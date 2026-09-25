//! Agents Lithe can install and launch, and how each receives its settings.
//!
//! Every adapter signs in through the ACP `gateway` method, so the user's API
//! key travels over stdio in the header of the agent's provider protocol.
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

/// How the provider's model name reaches the agent. It is not secret, so the
/// environment is acceptable for every adapter.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ModelDelivery {
    /// `CODEX_CONFIG={"model": ...}`, merged into Codex's session config.
    CodexConfig,
    /// `ANTHROPIC_MODEL`, the Claude adapter's preferred model.
    AnthropicEnvironment,
}

/// The agent's own command-line tool, which the user installs and updates.
///
/// Adapters that can drive an existing CLI are installed without their bundled
/// copy, so Lithe never downloads an agent the user already has.
#[derive(Debug, PartialEq, Eq)]
pub struct AgentCli {
    /// Executable searched on the login shell's `PATH`.
    pub command: &'static str,
    pub name: &'static str,
    /// Lowest version the pinned adapter supports, from its dependency range.
    pub minimum_version: &'static str,
    /// Environment variable that tells the adapter which executable to run.
    pub path_env: &'static str,
    /// How users usually install or update the CLI, shown when it is missing.
    pub install_hint: &'static str,
    /// npm package that provides the CLI, for one-click install or update
    /// with the user's npm.
    pub package: &'static str,
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
    pub model_delivery: ModelDelivery,
    /// The user's CLI the adapter drives, if it does not bundle one we use.
    pub cli: Option<AgentCli>,
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
        model_delivery: ModelDelivery::CodexConfig,
        // `@openai/codex ^0.156.1` in the adapter; its platform binaries are
        // optional dependencies that the install skips.
        cli: Some(AgentCli {
            command: "codex",
            name: "Codex CLI",
            minimum_version: "0.156.0",
            path_env: "CODEX_PATH",
            install_hint: "npm install -g @openai/codex",
            package: "@openai/codex",
        }),
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
        model_delivery: ModelDelivery::AnthropicEnvironment,
        // The Claude Agent SDK pairs with Claude Code 2.1.280; its native
        // binary is an optional dependency that the install skips.
        cli: Some(AgentCli {
            command: "claude",
            name: "Claude Code",
            minimum_version: "2.1.280",
            path_env: "CLAUDE_CODE_EXECUTABLE",
            install_hint: "npm install -g @anthropic-ai/claude-code",
            package: "@anthropic-ai/claude-code",
        }),
        verified: false,
    },
];

pub fn find(id: &str) -> Option<&'static CatalogAgent> {
    CATALOG.iter().find(|agent| agent.id == id)
}
