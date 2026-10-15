//! Claude API-key routing through the upstream adapter's public session options.
//!
//! Credentials reach the adapter over ACP stdio, never through host launch
//! arguments, environment, or files. The adapter and Claude SDK own their native
//! credential conversion; Lithe does not patch installed third-party packages.

use serde_json::{json, Map, Value};

use crate::{GatewaySignIn, ProviderProtocol};

/// Apply the explicit route and startup model when creating a Claude session.
pub(crate) fn metadata(
    route: Option<&GatewaySignIn>,
) -> Result<Option<Map<String, Value>>, String> {
    let Some(route) = route.filter(|route| route.protocol == ProviderProtocol::AnthropicMessages)
    else {
        return Ok(None);
    };
    let key = route
        .headers
        .iter()
        .find(|(name, value)| name == "x-api-key" && !value.trim().is_empty())
        .ok_or("The Claude API key route is missing its credential")?;
    // Gateway mode injects `Bearer acp-proxy`, even with a real x-api-key. Native
    // API-key options avoid that token and retain the complete upstream agent.
    let env = json!({
        "ANTHROPIC_BASE_URL": route.base_url,
        "ANTHROPIC_API_KEY": key.1,
        "ANTHROPIC_AUTH_TOKEN": "",
        "ANTHROPIC_CUSTOM_HEADERS": "",
        "CLAUDE_CODE_OAUTH_TOKEN": "",
        // The CLI retries even invalid API keys ten times by default. Its public
        // retry budget is shared by all errors and honors long Retry-After.
        // The host instead bounds retries of typed temporary ACP failures.
        "CLAUDE_CODE_MAX_RETRIES": "0",
        "CLAUDE_CODE_RETRY_WATCHDOG": "0",
        // Avoid replaying partial streaming work via a non-streaming fallback.
        // Native model selection may still probe a missing model twice.
        "CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK": "1",
        "CLAUDE_CODE_USE_BEDROCK": "0",
        "CLAUDE_CODE_USE_VERTEX": "0",
        "CLAUDE_CODE_USE_FOUNDRY": "0",
        "CLAUDE_CODE_USE_ANTHROPIC_AWS": "0",
        "ANTHROPIC_BEDROCK_BASE_URL": "",
        "ANTHROPIC_VERTEX_BASE_URL": ""
    });
    let mut options = json!({
        "env": env,
        // Claude loads settings after subprocess env. Both public SDK tiers
        // must carry the selected route so user/project settings cannot replace it.
        "settings": {"apiKeyHelper": "", "env": env}
    });
    if let Some(model) = route
        .model
        .as_deref()
        .map(str::trim)
        .filter(|model| !model.is_empty())
    {
        options["model"] = json!(model);
    }
    Ok(Some(Map::from_iter([(
        "claudeCode".into(),
        json!({"options": options}),
    )])))
}

/// Restore authentication without pinning the SDK to a new-session default.
/// The upstream transcript owns the historical session's selected model.
pub(crate) fn restored_metadata(
    route: Option<&GatewaySignIn>,
) -> Result<Option<Map<String, Value>>, String> {
    let mut meta = metadata(route)?;
    if let Some(options) = meta
        .as_mut()
        .and_then(|meta| meta.get_mut("claudeCode"))
        .and_then(|claude| claude.get_mut("options"))
        .and_then(Value::as_object_mut)
    {
        options.remove("model");
    }
    Ok(meta)
}
