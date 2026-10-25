//! Claude Code subscription access through the user's own signed-in CLI.
//!
//! The installed ACP adapter runs the user's Claude Code, which owns the
//! claude.ai login and its credentials. Lithe passes no key, sets no route and
//! never reads, copies or refreshes a token: this mode only refrains from the
//! API-key overrides and reports whether the CLI is signed in.

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
