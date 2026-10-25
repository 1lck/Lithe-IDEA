//! Claude Code subscription access through the user's own signed-in CLI.
//!
//! The installed ACP adapter runs the user's Claude Code, which owns the
//! claude.ai login and its credentials. Lithe passes no key and never reads,
//! copies, stores or refreshes a token: this mode refrains from the API-key
//! overrides and reports whether the CLI is signed in. With model-call
//! statistics on, the only route Lithe adds is the loopback observation proxy
//! (`ANTHROPIC_BASE_URL`), which forwards every request byte-for-byte to the
//! official origin; the CLI keeps sending its own credentials in its headers.

use super::*;

/// Shown when the adapter reports a signed-out CLI. Lithe does not start a
/// browser login; the user signs in with the CLI they already use.
pub(super) const SIGN_IN_REQUIRED: &str =
    "Claude Code is not signed in. Run `claude` in a terminal, sign in with /login, then retry.";

/// The adapter probes `claude auth status` at initialization with a 5 second
/// bound of its own. A missing report is "unknown", never "signed out".
const STATUS_TIMEOUT: Duration = Duration::from_secs(8);

/// Variables inherited from Lithe's environment that would outrank the
/// subscription login or pin a model the restored session does not own.
pub(super) const INHERITED_OVERRIDES: [&str; 6] = [
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_BASE_URL",
    "ANTHROPIC_MODEL",
    "CLAUDE_CODE_OAUTH_TOKEN",
    // An inherited executable can be an unusable Windows batch shim; the
    // resolved CLI path is added back through the launch environment.
    "CLAUDE_CODE_EXECUTABLE",
];

/// Official inference origin the observation proxy forwards to.
pub(super) const INFERENCE_ORIGIN: &str = "https://api.anthropic.com";

/// Whether the user points Claude Code at their own endpoint, through the
/// launch environment or the inherited process environment.
pub(super) fn has_custom_base_url(launch: &ResolvedLaunch) -> bool {
    let is_custom = |value: &str| {
        let value = value.trim().trim_end_matches('/');
        !value.is_empty() && value != INFERENCE_ORIGIN
    };
    match launch
        .env
        .iter()
        .find(|(name, _)| name == "ANTHROPIC_BASE_URL")
    {
        Some((_, value)) => is_custom(value),
        None => std::env::var("ANTHROPIC_BASE_URL").is_ok_and(|value| is_custom(&value)),
    }
}

/// Route Claude Code's requests through the loopback observation proxy. Only the
/// base URL changes; authentication stays with the CLI and the proxy forwards it
/// untouched, so the billing source and account are the ones the user signed in with.
pub(super) fn observe_model_calls(launch: &mut ResolvedLaunch, proxy: &str) {
    launch.env.retain(|(name, _)| name != "ANTHROPIC_BASE_URL");
    launch
        .env
        .push(("ANTHROPIC_BASE_URL".into(), proxy.to_owned()));
}

/// Claude Code's own switch for selecting an isolated account directory.
pub(super) const CONFIG_DIR_ENVIRONMENT: &str = "CLAUDE_CONFIG_DIR";

/// Launch the installed Claude adapter against the detected Claude Code CLI,
/// without an API provider.
pub(super) fn resolve(
    launch: AgentLaunch,
    find_cli: &dyn Fn(&str) -> Option<environment::DetectedTool>,
) -> Result<ResolvedLaunch, String> {
    if launch.agent_id.as_deref() != Some("claude-acp") {
        return Err("Claude subscription sign-in is only available for Claude Agent".into());
    }
    if !launch.cwd.is_absolute() {
        return Err("The workspace path must be absolute".into());
    }
    let data = launch
        .data_directory
        .ok_or("The Agent install directory is not configured")?;
    let agent = catalog::find("claude-acp").ok_or("Claude Agent is unavailable")?;
    if install::installed_version(&data, agent).is_none() {
        return Err("Claude Agent is not installed. Install it in Agent Settings.".into());
    }
    let cli = agent.cli.as_ref().ok_or("Claude Code is unavailable")?;
    let detected = find_cli(cli.command);
    if let Some(issue) = install::cli_issue(cli, detected.as_ref()) {
        return Err(issue);
    }
    let detected = detected.ok_or("Claude Code is unavailable")?;
    let mut env: Vec<(String, String)> = cli_path_env(cli, &detected).into_iter().collect();
    env.extend(claude_context_env(launch.context_limits));
    if let Some(directory) = launch.claude_config_dir {
        // A relative path would resolve against the adapter's working directory
        // and silently select a different account than the one the user chose.
        if !directory.is_absolute() {
            return Err("The Claude account directory must be an absolute path".into());
        }
        env.retain(|(name, _)| name != CONFIG_DIR_ENVIRONMENT);
        env.push((
            CONFIG_DIR_ENVIRONMENT.into(),
            directory.to_string_lossy().into_owned(),
        ));
    }
    let claude_projects = crate::claude_earlier_history::projects_directory(
        env.iter()
            .find(|(name, _)| name == CONFIG_DIR_ENVIRONMENT)
            .map(|(_, value)| std::path::Path::new(value)),
    );
    Ok(ResolvedLaunch {
        command: install::installed_command(&data, agent),
        args: launch.args,
        cwd: launch.cwd,
        env,
        gateway: None,
        secret: String::new(),
        subscription_cli: None,
        claude_subscription: true,
        codex_home: None,
        claude_projects,
    })
}

/// Fail the connection with an actionable message when the CLI is signed out.
/// A status that never arrives, or any signed-in kind (account, API key,
/// external backend), lets the connection continue unchanged. A claude.ai
/// account the adapter reported is returned for display only.
pub(super) async fn ensure_signed_in(
    status: &mut tokio::sync::watch::Receiver<Option<subscription::AuthStatus>>,
) -> Result<Option<subscription::Account>, String> {
    let reported = tokio::time::timeout(STATUS_TIMEOUT, async {
        loop {
            if let Some(value) = status.borrow_and_update().clone() {
                return Some(value);
            }
            if status.changed().await.is_err() {
                return None;
            }
        }
    })
    .await
    .ok()
    .flatten();
    match reported {
        Some(value) if value.kind == "none" => Err(SIGN_IN_REQUIRED.into()),
        Some(value) if value.kind == "account" => Ok(value.account),
        _ => Ok(None),
    }
}
