//! Codex-owned subscription authentication and bounded, read-only quota probes.
//!
//! The pinned ACP adapter does not expose structured rate limits. A short-lived
//! official App Server reads them without Lithe opening any credential file.
//! No thread, prompt, model request, or persistent Lithe cache is created.

use super::*;
use serde_json::{json, Value};
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncWrite, AsyncWriteExt, BufReader};

// Official Codex ChatGPT route, matching the upstream default. This is passed
// to Codex configuration only; Lithe never issues authenticated HTTP requests.
const CHATGPT_BASE_URL: &str = "https://chatgpt.com/backend-api/";

const PROBE_TIMEOUT: Duration = Duration::from_secs(20);
const MAX_REPLY_BYTES: u64 = 1024 * 1024;
pub(super) const LOGIN_TIMEOUT: Duration = Duration::from_secs(300);
pub(super) const QUOTA_INTERVAL: Duration = Duration::from_secs(60);

/// Account identity reported by Codex, used only in memory and never logged.
#[derive(Clone, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
pub struct Account {
    pub email: Option<String>,
    pub plan: Option<String>,
}

/// A real quota window. Unknown utilization is never interpreted as zero.
#[derive(Debug, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct QuotaWindow {
    pub id: String,
    pub name: String,
    pub limit_seconds: u64,
    pub used_percent: Option<f64>,
    /// Unix seconds, as reported by Codex.
    pub resets_at: Option<i64>,
}

/// Last successful read; consumers retain it as stale on transient failures.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct QuotaSnapshot {
    pub windows: Vec<QuotaWindow>,
    /// Unix seconds at completion of the bounded query.
    pub fetched_at: u64,
}

#[derive(Clone, Debug, Deserialize, Serialize)]
pub(super) struct AuthStatus {
    pub kind: String,
    pub account: Option<Account>,
}

#[derive(Debug, Clone, Deserialize, Serialize, agent_client_protocol::JsonRpcNotification)]
#[notification(method = "_auth/status_update")]
#[serde(rename_all = "camelCase")]
pub(super) struct AuthNotification {
    pub auth_status: AuthStatus,
}

/// Return None on an explicit stop. No panel lifecycle event starts browser login.
pub(super) async fn authenticate(
    connection: &ConnectionTo<Agent>,
    status: &mut tokio::sync::watch::Receiver<Option<AuthStatus>>,
    controls: &mut async_mpsc::UnboundedReceiver<Control>,
    emit: &Emit,
) -> Result<Option<Account>, agent_client_protocol::Error> {
    let initial = tokio::select! {
        result = wait_status(status, false) => result?,
        _ = wait_for_stop(controls) => return Ok(None),
    };
    if initial.kind != "account" {
        emit(AgentEvent::AuthenticationRequired);
        loop {
            match controls.recv().await {
                Some(Control::Command(AgentCommand::Authenticate)) => break,
                Some(Control::Stop) | None => return Ok(None),
                _ => {}
            }
        }
        emit(AgentEvent::Authenticating);
        tokio::select! {
            result = tokio::time::timeout(LOGIN_TIMEOUT,
                connection.send_request(AuthenticateRequest::new("chat-gpt")).block_task()) => {
                result.map_err(|_| internal("ChatGPT sign-in timed out. Try again."))?
                    .map_err(|_| internal("ChatGPT sign-in did not complete. Try again."))?;
            }
            _ = wait_for_stop(controls) => return Ok(None),
        }
    }
    // Notifications and the authenticate response may be dispatched separately.
    // Wait for the confirmation instead of assuming its handler ran first.
    let confirmed = tokio::select! {
        result = wait_status(status, true) => result?,
        _ = wait_for_stop(controls) => return Ok(None),
    };
    Ok(Some(confirmed.account.unwrap_or_default()))
}

async fn wait_for_stop(controls: &mut async_mpsc::UnboundedReceiver<Control>) {
    while let Some(control) = controls.recv().await {
        if matches!(control, Control::Stop) {
            return;
        }
    }
}

async fn wait_status(
    status: &mut tokio::sync::watch::Receiver<Option<AuthStatus>>,
    require_account: bool,
) -> Result<AuthStatus, agent_client_protocol::Error> {
    tokio::time::timeout(HANDSHAKE_TIMEOUT, async {
        loop {
            if let Some(value) = status.borrow_and_update().clone() {
                if !require_account || value.kind == "account" {
                    return Ok(value);
                }
            }
            status
                .changed()
                .await
                .map_err(|_| internal("Codex account reporting stopped"))?;
        }
    })
    .await
    .map_err(|_| internal("Codex did not confirm its account in time"))?
}

pub(super) fn resolve(
    launch: AgentLaunch,
    find_cli: &dyn Fn(&str) -> Option<environment::DetectedTool>,
) -> Result<ResolvedLaunch, String> {
    if launch.agent_id.as_deref() != Some("codex-acp") || launch.provider.is_some() {
        return Err(
            "Official subscription access is only available for Codex, without an API provider"
                .into(),
        );
    }
    if !launch.cwd.is_absolute() {
        return Err("The workspace path must be absolute".into());
    }
    let data = launch
        .data_directory
        .ok_or("The Agent install directory is not configured")?;
    let agent = catalog::find("codex-acp").ok_or("Codex is unavailable")?;
    if install::installed_version(&data, agent).is_none() {
        return Err("Codex is not installed. Install it in Agent Settings.".into());
    }
    let cli = agent.cli.as_ref().ok_or("Codex CLI is unavailable")?;
    let detected = find_cli(cli.command);
    if let Some(issue) = install::cli_issue(cli, detected.as_ref()) {
        return Err(issue);
    }
    let executable = detected.ok_or("Codex CLI is unavailable")?.path;
    Ok(ResolvedLaunch {
        command: install::installed_command(&data, agent),
        args: launch.args,
        cwd: launch.cwd,
        // Override only this process's routing, preserving the user's CLI files,
        // MCP servers and skills. Session model choices still come from Codex.
        env: vec![
            (
                cli.path_env.into(),
                executable.to_string_lossy().into_owned(),
            ),
            ("MODEL_PROVIDER".into(), "openai".into()),
            (
                "CODEX_CONFIG".into(),
                json!({
                    "model_provider": "openai",
                    // Empty disables a saved openai_base_url override in Codex.
                    "openai_base_url": "",
                    "chatgpt_base_url": CHATGPT_BASE_URL,
                })
                .to_string(),
            ),
        ],
        gateway: None,
        secret: String::new(),
        subscription_cli: Some(executable),
    })
}

/// Prevent inherited API overrides from silently changing the selected billing source.
/// Codex still owns account storage and refresh; CODEX_HOME remains untouched.
pub(super) fn isolate_environment(command: &mut std::process::Command) {
    for name in [
        "OPENAI_API_KEY",
        "CODEX_API_KEY",
        "OPENAI_BASE_URL",
        "CODEX_ACCESS_TOKEN",
        "OPENAI_IDENTITY_TOKEN_FILE",
        "OPENAI_WORKLOAD_IDENTITY_PROVIDER",
        "MODEL_PROVIDER",
        "CODEX_CONFIG",
        "DEFAULT_AUTH_REQUEST",
        "APP_SERVER_LOGS",
    ] {
        command.env_remove(name);
    }
}

/// Own the probe tree even if its future is cancelled during a read or cleanup.
struct ProbeProcess(tokio::process::Child);

impl Drop for ProbeProcess {
    fn drop(&mut self) {
        if let Some(pid) = self.0.id() {
            force_kill_tree(pid);
        }
    }
}

pub(super) async fn read_quota(
    command: &Path,
    cwd: &Path,
    account: &Account,
) -> Result<QuotaSnapshot, &'static str> {
    let mut process = std::process::Command::new(command);
    isolate_environment(&mut process);
    process
        .args([
            "-c",
            "model_provider=\"openai\"",
            "-c",
            "openai_base_url=\"\"",
            "-c",
        ])
        .arg(format!("chatgpt_base_url=\"{CHATGPT_BASE_URL}\""))
        .arg("app-server")
        .current_dir(cwd)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    if let Some(path) = child_path(command, environment::search_path()) {
        process.env("PATH", path);
    }
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        process.process_group(0);
    }
    let mut process = tokio::process::Command::from(process);
    process.kill_on_drop(true);
    let mut child = ProbeProcess(process.spawn().map_err(|_| "unavailable")?);
    let result = async {
        let mut input = child.0.stdin.take().ok_or("unavailable")?;
        let mut output = BufReader::new(child.0.stdout.take().ok_or("unavailable")?);
        exchange(&mut input, &mut output, account).await
    };
    let result = tokio::time::timeout(PROBE_TIMEOUT, result)
        .await
        .unwrap_or(Err("timeout"));
    terminate_tree(&mut child.0).await;
    result
}

async fn exchange(
    input: &mut (impl AsyncWrite + Unpin),
    output: &mut (impl AsyncBufRead + Unpin),
    expected: &Account,
) -> Result<QuotaSnapshot, &'static str> {
    request(
        input,
        output,
        1,
        "initialize",
        json!({"clientInfo": {"name": "lithe-quota", "version": "1"}}),
    )
    .await?;
    input
        .write_all(b"{\"method\":\"initialized\"}\n")
        .await
        .map_err(|_| "unavailable")?;
    let account = request(
        input,
        output,
        2,
        "account/read",
        json!({"refreshToken": false}),
    )
    .await?;
    check_account(&account, expected)?;
    let limits = request(input, output, 3, "account/rateLimits/read", Value::Null).await?;
    // A CLI login in another terminal during the probe must not cross account data.
    let account = request(
        input,
        output,
        4,
        "account/read",
        json!({"refreshToken": false}),
    )
    .await?;
    check_account(&account, expected)?;
    Ok(QuotaSnapshot {
        windows: windows(&limits)?,
        fetched_at: std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_err(|_| "unavailable")?
            .as_secs(),
    })
}

fn check_account(value: &Value, expected: &Account) -> Result<(), &'static str> {
    let account = &value["account"];
    if account["type"] != "chatgpt" {
        return Err("unauthorized");
    }
    let email = account["email"].as_str().filter(|value| !value.is_empty());
    if email.is_none() || expected.email.as_deref() != email {
        return Err("accountChanged");
    }
    Ok(())
}

async fn request(
    input: &mut (impl AsyncWrite + Unpin),
    output: &mut (impl AsyncBufRead + Unpin),
    id: u64,
    method: &str,
    params: Value,
) -> Result<Value, &'static str> {
    let line = format!(
        "{}\n",
        json!({"id": id, "method": method, "params": params})
    );
    input
        .write_all(line.as_bytes())
        .await
        .map_err(|_| "unavailable")?;
    loop {
        let mut line = Vec::new();
        output
            .take(MAX_REPLY_BYTES + 1)
            .read_until(b'\n', &mut line)
            .await
            .map_err(|_| "unavailable")?;
        if line.is_empty() {
            return Err("unavailable");
        }
        if line.len() as u64 > MAX_REPLY_BYTES {
            return Err("unparsable");
        }
        let reply: Value = serde_json::from_slice(&line).map_err(|_| "unparsable")?;
        if reply.get("id").and_then(Value::as_u64) != Some(id) {
            continue;
        }
        // Never expose upstream error text: it may contain paths or account data.
        if reply.get("error").is_some() {
            return Err("unavailable");
        }
        return reply.get("result").cloned().ok_or("unparsable");
    }
}

/// Preserve provider window lengths, including Pro accounts whose primary is weekly.
fn windows(value: &Value) -> Result<Vec<QuotaWindow>, &'static str> {
    let mut snapshots = std::collections::BTreeMap::new();
    if let Some(entries) = value["rateLimitsByLimitId"].as_object() {
        for (id, snapshot) in entries {
            if snapshot.is_object() {
                snapshots.insert(id.as_str(), snapshot);
            }
        }
    }
    if snapshots.is_empty() {
        let snapshot = &value["rateLimits"];
        snapshots.insert(snapshot["limitId"].as_str().unwrap_or("codex"), snapshot);
    }
    let mut windows = Vec::new();
    for (id, snapshot) in snapshots {
        for field in ["primary", "secondary"] {
            let window = &snapshot[field];
            let Some(seconds) = window["windowDurationMins"]
                .as_u64()
                .and_then(|m| m.checked_mul(60))
                .filter(|s| *s > 0)
            else {
                continue;
            };
            windows.push(QuotaWindow {
                id: format!("{id}:{field}"),
                name: snapshot["limitName"].as_str().unwrap_or(id).to_owned(),
                limit_seconds: seconds,
                used_percent: window["usedPercent"]
                    .as_f64()
                    .filter(|p| p.is_finite() && (0.0..=100.0).contains(p)),
                resets_at: window["resetsAt"].as_i64().filter(|s| *s > 0),
            });
        }
    }
    if windows.is_empty() {
        Err("unparsable")
    } else {
        Ok(windows)
    }
}

#[cfg(test)]
mod tests;
