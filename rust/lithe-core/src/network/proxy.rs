//! Normalization and validation for `network.proxyPolicy`.
//!
//! The settings layer may hold untrimmed or incomplete values; this module is
//! the single authority that turns them into the policy a network stack must
//! apply. A custom server that is missing its host or port normalizes to the
//! system policy instead of silently breaking every request, and credentials
//! are only carried for a configured custom proxy so a later mode switch can
//! never forward them to a different proxy.

use serde::{Deserialize, Serialize};

/// How the application's own HTTP traffic reaches the internet.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum NetworkProxyMode {
    /// Resolve proxies through the operating system configuration.
    System,
    /// Contact every host directly, ignoring configured system proxies.
    Direct,
    /// Tunnel requests through the user-configured server.
    Custom,
}

/// The protocol a custom proxy server speaks.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum NetworkProxyType {
    /// HTTP proxy; also carries HTTPS requests through CONNECT.
    Http,
    /// SOCKS5 proxy; tunnels every protocol and port.
    Socks5,
}

/// Request for `network.proxyPolicy`: the stored proxy settings exactly as
/// the settings layer holds them. Values may be untrimmed or incomplete;
/// normalization happens here. `port` must fit in 16 bits or the dispatcher
/// rejects the request as invalid.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct NetworkProxyPolicyRequest {
    pub mode: NetworkProxyMode,
    /// Proxy protocol for the custom mode; defaults to HTTP when absent.
    #[serde(default)]
    pub proxy_type: Option<NetworkProxyType>,
    #[serde(default)]
    pub host: String,
    #[serde(default)]
    pub port: u16,
    #[serde(default)]
    pub username: String,
    #[serde(default)]
    pub password: String,
    #[serde(default)]
    pub exclusions: Vec<String>,
}

/// The policy kind a network stack must apply after normalization.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum NetworkProxyPolicyKind {
    /// Resolve proxies through the operating system configuration.
    System,
    /// Contact every host directly; an empty proxy dictionary.
    Direct,
    /// Tunnel requests through the normalized custom server.
    Custom,
}

/// Normalized policy for `network.proxyPolicy`. Credentials are only
/// populated for `policy == custom`; system and direct never carry them, so
/// hosts can forward the plan to their network stack without a second
/// credential-scoping decision.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct NetworkProxyPolicy {
    pub policy: NetworkProxyPolicyKind,
    pub proxy_type: NetworkProxyType,
    pub host: String,
    pub port: u16,
    pub username: String,
    pub password: String,
    pub exclusions: Vec<String>,
    /// True when the caller-selected mode could actually be honored; false
    /// for an incomplete custom server that normalized to the system policy.
    pub configured: bool,
}

/// Normalizes stored proxy settings into the policy a network stack applies.
pub fn proxy_policy(request: NetworkProxyPolicyRequest) -> NetworkProxyPolicy {
    let exclusions: Vec<String> = request
        .exclusions
        .iter()
        .map(|entry| entry.trim().to_string())
        .filter(|entry| !entry.is_empty())
        .collect();
    let proxy_type = request.proxy_type.unwrap_or(NetworkProxyType::Http);
    let empty = NetworkProxyPolicy {
        policy: NetworkProxyPolicyKind::System,
        proxy_type,
        host: String::new(),
        port: 0,
        username: String::new(),
        password: String::new(),
        exclusions: Vec::new(),
        configured: false,
    };
    match request.mode {
        NetworkProxyMode::System => empty,
        NetworkProxyMode::Direct => NetworkProxyPolicy {
            policy: NetworkProxyPolicyKind::Direct,
            ..empty
        },
        NetworkProxyMode::Custom => {
            let host = request.host.trim();
            let configured = !host.is_empty() && request.port > 0;
            if !configured {
                return empty;
            }
            NetworkProxyPolicy {
                policy: NetworkProxyPolicyKind::Custom,
                proxy_type,
                host: host.to_string(),
                port: request.port,
                username: request.username.trim().to_string(),
                password: request.password,
                exclusions,
                configured: true,
            }
        }
    }
}
