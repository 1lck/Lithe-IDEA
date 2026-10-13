//! Native Codex configuration compatibility and bounded reconnect observation.
//!
//! The public ACP adapter replaces the gateway provider table. A per-launch
//! stdio relay supplies native App Server options without modifying the user's
//! CLI, configuration, or installed adapter. Native Codex still owns recovery.
//! Decision: .agents/notes/implemented/architecture/2026-09-25-shared-acp-agent-conversation.md

use std::path::{Path, PathBuf};

use serde_json::Value;

use crate::prompt_retry::MAX_ATTEMPTS;

/// One launch owns its temporary helper until the complete process tree stops.
pub(crate) struct Relay(PathBuf);

impl Relay {
    pub(crate) fn create(executable: &Path) -> Result<(Self, Vec<(String, String)>), String> {
        let directory =
            std::env::temp_dir().join(format!("lithe-codex-retry-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir(&directory)
            .map_err(|_| "Could not prepare Codex retry configuration")?;
        let relay = Self(directory);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&relay.0, std::fs::Permissions::from_mode(0o700))
                .map_err(|_| "Could not protect Codex retry launcher")?;
        }
        let script = relay.0.join("codex-config-relay.cjs");
        std::fs::write(&script, include_str!("codex-config-relay.cjs"))
            .map_err(|_| "Could not write Codex retry configuration")?;
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&script, std::fs::Permissions::from_mode(0o700))
                .map_err(|_| "Could not prepare Codex retry launcher")?;
        }
        #[cfg(windows)]
        let script = {
            let launcher = relay.0.join("codex-config-relay.cmd");
            // Only the upstream adapter's fixed `app-server` argument reaches
            // this launcher. Paths resolve beside it; credentials remain stdio.
            std::fs::write(
                &launcher,
                "@echo off\r\nnode \"%~dp0codex-config-relay.cjs\" app-server\r\n",
            )
            .map_err(|_| "Could not prepare Codex retry launcher")?;
            launcher
        };
        Ok((
            relay,
            vec![
                ("CODEX_PATH".into(), script.to_string_lossy().into_owned()),
                (
                    "LITHE_CODEX_EXECUTABLE".into(),
                    executable.to_string_lossy().into_owned(),
                ),
                (
                    "LITHE_CODEX_STREAM_RETRIES".into(),
                    (MAX_ATTEMPTS - 1).to_string(),
                ),
            ],
        ))
    }
}

impl Drop for Relay {
    fn drop(&mut self) {
        if std::fs::remove_dir_all(&self.0).is_err() {
            eprintln!("Could not remove the temporary Codex retry launcher");
        }
    }
}

/// Decode only the relay's envelope inside negotiated native failure metadata.
/// Malformed or ordinary provider titles retain the adapter's own category.
pub(crate) fn failure(title: &str) -> Option<Value> {
    if title.len() > 64 * 1024 {
        return None;
    }
    let value: Value = serde_json::from_str(title).ok()?;
    let failure = value.get("litheCodexFailure")?;
    failure.get("message")?.as_str()?;
    failure.get("codexErrorInfo")?;
    Some(failure.clone())
}

pub(crate) fn permanent(failure: &Value) -> bool {
    let info = &failure["codexErrorInfo"];
    if matches!(
        info.as_str(),
        Some(
            "unauthorized"
                | "badRequest"
                | "usageLimitExceeded"
                | "contextWindowExceeded"
                | "sessionBudgetExceeded"
                | "cyberPolicy"
                | "misalignmentPolicyViolation"
        )
    ) {
        return true;
    }
    info.as_object().is_some_and(|variants| {
        variants.values().any(|details| {
            details["httpStatusCode"].as_u64().is_some_and(|status| {
                status < 500 && status >= 400 && !matches!(status, 408 | 409 | 429)
            })
        })
    })
}

/// Native HTTP 429 can exhaust immediately: its public HTTP retry policy
/// excludes rate limits. Only that typed gap may use the pre-work Host replay;
/// pre-work native retries and this fallback share one five-attempt budget.
pub(crate) fn rate_limit(error: &agent_client_protocol::Error) -> bool {
    let Some(native) = error
        .data
        .as_ref()
        .and_then(|data| data["sessionFailure"]["title"].as_str())
        .and_then(failure)
    else {
        return false;
    };
    !permanent(&native)
        && native["codexErrorInfo"]
            .as_object()
            .is_some_and(|variants| {
                variants
                    .values()
                    .any(|details| details["httpStatusCode"] == 429)
            })
}

pub(crate) fn terminal_sequence(error: &agent_client_protocol::Error) -> Option<u64> {
    let title = error.data.as_ref()?["sessionFailure"]["title"].as_str()?;
    failure(title)?["sequence"].as_u64()
}
