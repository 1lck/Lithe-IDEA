//! Codex archived history through a short-lived official App Server.
//!
//! The pinned codex-acp lists only unarchived threads and offers neither an
//! archive filter nor an unarchive request. Like the quota probe, Lithe starts
//! the user's Codex CLI as `codex app-server` for one bounded exchange: listing
//! is read-only, and `thread/unarchive` runs only on an explicit user request.
//! Codex owns the history files; Lithe never reads them and caches nothing.

use super::*;
use serde_json::{json, Value};
use tokio::io::{AsyncBufRead, AsyncWrite, AsyncWriteExt, BufReader};

const PROBE_TIMEOUT: Duration = Duration::from_secs(30);
const PAGE_SIZE: u32 = 50;

/// Source kinds codex-acp lists, so archived and active history share a scope.
const SOURCE_KINDS: [&str; 5] = ["cli", "vscode", "exec", "appServer", "unknown"];

/// Provider ids codex-acp records threads under for each authentication mode.
const SUBSCRIPTION_PROVIDER: &str = "openai";
const GATEWAY_PROVIDER: &str = "custom-gateway";

/// Archived threads for the workspace. `complete` is false when the page bound
/// stopped the listing, so the UI never presents a truncated list as whole.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct ArchivedSessions {
    pub sessions: Vec<AgentSessionSummary>,
    pub complete: bool,
}

/// How to reach the same Codex CLI and history scope as the ACP connection.
#[derive(Clone, Debug)]
pub(crate) struct CodexHistory {
    executable: PathBuf,
    cwd: PathBuf,
    model_provider: &'static str,
}

impl CodexHistory {
    /// Only Codex connections have archived history; other Agents return None.
    pub(crate) fn for_launch(launch: &ResolvedLaunch) -> Option<Self> {
        let (executable, model_provider) = match &launch.subscription_cli {
            Some(executable) => (executable.clone(), SUBSCRIPTION_PROVIDER),
            None => {
                let executable = launch
                    .env
                    .iter()
                    .find(|(name, _)| name == "CODEX_PATH")
                    .map(|(_, value)| PathBuf::from(value))?;
                (executable, GATEWAY_PROVIDER)
            }
        };
        Some(Self {
            executable,
            cwd: launch.cwd.clone(),
            model_provider,
        })
    }

    pub(crate) async fn list_archived(
        &self,
        workspace: &workspace_context::WorkspaceContext,
    ) -> Result<ArchivedSessions, String> {
        let workspace_path = normalize_path(&self.cwd.to_string_lossy());
        let provider = self.model_provider;
        self.exchange(|mut input, mut output| async move {
            list_pages(&mut input, &mut output, provider, &workspace_path).await
        })
        .await
        .map(|(threads, complete)| ArchivedSessions {
            sessions: threads
                .into_iter()
                .map(|thread| AgentSessionSummary {
                    session_id: thread.id,
                    title: thread
                        .title
                        .and_then(|title| workspace.present_title(&title)),
                    updated_at: thread.updated_at,
                })
                .collect(),
            complete,
        })
        .map_err(|_| "Codex archived history could not be read.".to_owned())
    }

    pub(crate) async fn unarchive(&self, session_id: String) -> Result<(), String> {
        self.exchange(|mut input, mut output| async move {
            subscription::request(
                &mut input,
                &mut output,
                2,
                "thread/unarchive",
                json!({ "threadId": session_id }),
            )
            .await
            .map(|_| ())
        })
        .await
        .map_err(|_| "Codex could not restore this archived conversation.".to_owned())
    }

    /// Start `codex app-server`, initialize it, run `operation`, and always
    /// terminate the process tree within the probe bound.
    async fn exchange<T, F, Fut>(&self, operation: F) -> Result<T, &'static str>
    where
        F: FnOnce(tokio::process::ChildStdin, BufReader<tokio::process::ChildStdout>) -> Fut,
        Fut: std::future::Future<Output = Result<T, &'static str>>,
    {
        let mut process = std::process::Command::new(&self.executable);
        // History needs no credentials; never hand API overrides to this process.
        subscription::isolate_environment(&mut process);
        process
            .arg("app-server")
            .current_dir(&self.cwd)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        if let Some(path) = child_path(&self.executable, environment::search_path()) {
            process.env("PATH", path);
        }
        #[cfg(unix)]
        {
            use std::os::unix::process::CommandExt;
            process.process_group(0);
        }
        let mut process = tokio::process::Command::from(process);
        #[cfg(windows)]
        {
            process.creation_flags(CREATE_NO_WINDOW);
        }
        process.kill_on_drop(true);
        let mut child = subscription::ProbeProcess(process.spawn().map_err(|_| "unavailable")?);
        let result = async {
            let mut input = child.0.stdin.take().ok_or("unavailable")?;
            let mut output = BufReader::new(child.0.stdout.take().ok_or("unavailable")?);
            initialize(&mut input, &mut output).await?;
            operation(input, output).await
        };
        let result = tokio::time::timeout(PROBE_TIMEOUT, result)
            .await
            .unwrap_or(Err("timeout"));
        terminate_tree(&mut child.0).await;
        result
    }
}

async fn initialize(
    input: &mut (impl AsyncWrite + Unpin),
    output: &mut (impl AsyncBufRead + Unpin),
) -> Result<(), &'static str> {
    subscription::request(
        input,
        output,
        1,
        "initialize",
        json!({"clientInfo": {"name": "lithe-history", "version": "1"}}),
    )
    .await?;
    input
        .write_all(b"{\"method\":\"initialized\"}\n")
        .await
        .map_err(|_| "unavailable")
}

#[derive(Debug, PartialEq, Eq)]
struct ArchivedThread {
    id: String,
    title: Option<String>,
    updated_at: Option<String>,
}

/// Follow cursors to the end. A page whose threads all belong to other
/// workspaces is still followed: filtering is local, so an empty page does
/// not mean the history ended.
async fn list_pages(
    input: &mut (impl AsyncWrite + Unpin),
    output: &mut (impl AsyncBufRead + Unpin),
    model_provider: &str,
    workspace: &str,
) -> Result<(Vec<ArchivedThread>, bool), &'static str> {
    let mut threads = Vec::new();
    let mut seen = std::collections::HashSet::new();
    let mut cursor: Option<String> = None;
    for page in 0..MAX_SESSION_LIST_PAGES {
        let result = subscription::request(
            input,
            output,
            2 + page as u64,
            "thread/list",
            json!({
                "archived": true,
                "cursor": cursor,
                // Bounded pages keep each reply under the probe's size limit.
                "limit": PAGE_SIZE,
                "modelProviders": [model_provider],
                "sourceKinds": SOURCE_KINDS,
            }),
        )
        .await?;
        let (page_threads, next) = parse_page(&result, workspace)?;
        for thread in page_threads {
            if seen.insert(thread.id.clone()) {
                threads.push(thread);
            }
        }
        match next {
            Some(next) => cursor = Some(next),
            None => return Ok((threads, true)),
        }
    }
    Ok((threads, false))
}

/// Threads of one `thread/list` page that belong to `workspace`, and the next cursor.
fn parse_page(
    result: &Value,
    workspace: &str,
) -> Result<(Vec<ArchivedThread>, Option<String>), &'static str> {
    let data = result["data"].as_array().ok_or("unparsable")?;
    let threads = data
        .iter()
        .filter_map(|thread| {
            let id = thread["id"].as_str().filter(|id| !id.is_empty())?;
            let cwd = thread["cwd"].as_str()?;
            if normalize_path(cwd) != workspace {
                return None;
            }
            // Same title rule as codex-acp: the user's name, else the preview.
            let title = [&thread["name"], &thread["preview"]]
                .into_iter()
                .filter_map(Value::as_str)
                .find(|title| !title.trim().is_empty())
                .map(str::to_owned);
            Some(ArchivedThread {
                id: id.to_owned(),
                title,
                updated_at: thread["updatedAt"].as_i64().and_then(iso8601),
            })
        })
        .collect();
    let next = result["nextCursor"]
        .as_str()
        .filter(|cursor| !cursor.is_empty())
        .map(str::to_owned);
    Ok((threads, next))
}

/// codex-acp's comparison: `.`/`..` and repeated or trailing separators are
/// normalized; Windows drive and UNC paths compare case-insensitively.
fn normalize_path(value: &str) -> String {
    let trimmed = value.trim();
    let bytes = trimmed.as_bytes();
    let windows = (bytes.len() >= 3
        && bytes[0].is_ascii_alphabetic()
        && bytes[1] == b':'
        && (bytes[2] == b'\\' || bytes[2] == b'/'))
        || trimmed.starts_with("\\\\");
    let slashed = if windows {
        trimmed.replace('\\', "/")
    } else {
        trimmed.to_owned()
    };
    let absolute = slashed.starts_with('/');
    let unc = windows && slashed.starts_with("//");
    let mut parts: Vec<&str> = Vec::new();
    for part in slashed.split('/') {
        match part {
            "" | "." => {}
            ".." => {
                if parts.last().is_some_and(|last| *last != "..") {
                    parts.pop();
                } else if !absolute {
                    parts.push("..");
                }
            }
            part => parts.push(part),
        }
    }
    let joined = parts.join("/");
    let normalized = match (unc, absolute) {
        (true, _) => format!("//{joined}"),
        (false, true) => format!("/{joined}"),
        (false, false) => joined,
    };
    if windows {
        normalized.to_lowercase()
    } else {
        normalized
    }
}

/// Unix seconds as `YYYY-MM-DDTHH:MM:SSZ`, the form the platforms already parse.
fn iso8601(seconds: i64) -> Option<String> {
    if seconds < 0 {
        return None;
    }
    let days = seconds / 86_400;
    let time = seconds % 86_400;
    // Howard Hinnant's civil_from_days.
    let z = days + 719_468;
    let era = z / 146_097;
    let day_of_era = z - era * 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1_460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_index = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_index + 2) / 5 + 1;
    let month = if month_index < 10 {
        month_index + 3
    } else {
        month_index - 9
    };
    let year = year_of_era + era * 400 + i64::from(month <= 2);
    Some(format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}Z",
        time / 3_600,
        time / 60 % 60,
        time % 60
    ))
}

#[cfg(test)]
mod tests;
