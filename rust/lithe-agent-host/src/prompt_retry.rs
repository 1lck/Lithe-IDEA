//! Shared prompt activity, API-key recovery budgets and failure normalization.
//!
//! The native CLI has one retry budget for permanent and temporary errors and
//! may honor minutes of Retry-After. Disable that layer through public options;
//! retry only categorical pre-work Claude failures and the native HTTP 429 gap
//! here. Codex otherwise owns recovery; both retain one busy turn and owner.

use std::{
    future::Future,
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc,
    },
    time::Duration,
};

use agent_client_protocol::{
    schema::v1::{CancelNotification, PromptRequest, PromptResponse, StopReason},
    Agent, ConnectionTo, Error,
};
use tokio::{sync::watch, time::Instant};

use crate::{codex_retry, AgentEvent, Emit};

pub(crate) const MAX_ATTEMPTS: u32 = 5;
/// Pre-work reconnecting window, excluding the first attempt and cancellation ACK.
pub(crate) const RETRY_WINDOW: Duration = Duration::from_secs(20);

/// Both native clients use this advisory threshold; silence cannot prove a stall.
pub(crate) fn quiet_notice_delay() -> Duration {
    #[derive(serde::Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Policy {
        quiet_notice_milliseconds: u64,
    }
    static DELAY: std::sync::OnceLock<Duration> = std::sync::OnceLock::new();
    *DELAY.get_or_init(|| {
        let policy: Policy = serde_json::from_str(include_str!(
            "../../../shared/contracts/agent-turn-policy.json"
        ))
        .expect("valid bundled Agent turn policy");
        Duration::from_millis(policy.quiet_notice_milliseconds)
    })
}

#[derive(Clone)]
pub(crate) struct State {
    last_progress: Instant,
    pending_permissions: usize,
    eligible: bool,
    pub(crate) cancelling: bool,
    deadline: Option<Instant>,
    last_failure: Option<String>,
    provider_message: Option<String>,
    native: bool,
    native_attempt: u32,
    /// Native recovery after work has no Host deadline. Its first warning starts
    /// an advisory clock; repeated warnings cannot postpone that notice.
    recovery_since: Option<Instant>,
    /// Retained across prompts of this session so delayed old warnings cannot
    /// enter a fresh turn after its predecessor's terminal response.
    native_sequence: Arc<AtomicU64>,
    stop_message: Option<String>,
    native_replay_safe: bool,
}

impl State {
    pub(crate) fn new(enabled: bool) -> Self {
        Self {
            last_progress: Instant::now(),
            pending_permissions: 0,
            eligible: enabled,
            cancelling: false,
            deadline: None,
            last_failure: None,
            provider_message: None,
            native: false,
            native_attempt: 1,
            recovery_since: None,
            native_sequence: Arc::new(AtomicU64::new(0)),
            stop_message: None,
            native_replay_safe: false,
        }
    }

    pub(crate) fn native(sequence: Arc<AtomicU64>) -> Self {
        Self {
            native: true,
            native_replay_safe: true,
            native_sequence: sequence,
            ..Self::new(false)
        }
    }

    /// Output or a permission request makes replay unsafe and ends the short
    /// retry window. The upstream Agent still owns its model and tool budgets.
    pub(crate) fn progress(&mut self) {
        self.last_progress = Instant::now();
        self.eligible = false;
        self.native_replay_safe = false;
        self.deadline = None;
        self.recovery_since = None;
        if self.native && self.stop_message.is_none() {
            self.native_attempt = 1;
        }
        // Output cannot revoke an already observed terminal native failure.
        if self.stop_message.is_some() {
            self.deadline = Some(Instant::now());
        }
    }

    pub(crate) fn permission_started(&mut self) {
        self.progress();
        self.pending_permissions += 1;
    }

    pub(crate) fn permission_finished(&mut self) {
        self.pending_permissions = self.pending_permissions.saturating_sub(1);
        self.progress();
    }

    /// AIR's public failure extension suppresses synthetic assistant error text.
    /// Retain its title for the terminal error; categories never come from text.
    pub(crate) fn observe_failure(&mut self, update: &serde_json::Value) {
        if self.native {
            return;
        }
        let air = &update["_meta"]["jetbrains"]["air"];
        let failure = &air["sessionFailure"];
        if update["sessionUpdate"] == "session_info_update"
            && air["version"] == 1
            && failure["severity"] == "error"
        {
            if let Some(title) = failure["title"]
                .as_str()
                .filter(|title| !title.trim().is_empty() && title.len() <= 8192)
            {
                self.provider_message = Some(failure_message(failure, title));
            }
        }
    }

    /// Native Codex owns retries; the host observes real error notifications
    /// rather than issuing another prompt or parsing its reconnect counter.
    pub(crate) fn observe_native_retry(
        &mut self,
        update: &serde_json::Value,
    ) -> Option<(String, u32, Option<u32>)> {
        if !self.native
            || self.cancelling
            || self.stop_message.is_some()
            || update["sessionUpdate"] != "session_info_update"
        {
            return None;
        }
        let air = &update["_meta"]["jetbrains"]["air"];
        if air["version"] != 1 {
            return None;
        }
        let failure = &air["sessionFailure"];
        let native = codex_retry::failure(failure["title"].as_str()?)?;
        if native["activeTurn"] != true {
            return None;
        }
        let sequence = native["sequence"].as_u64()?;
        if sequence <= self.native_sequence.load(Ordering::SeqCst) {
            return None;
        }
        let turn_id = native["turnId"].as_str()?.to_owned();
        if turn_id.is_empty() {
            return None;
        }
        self.native_sequence.fetch_max(sequence, Ordering::SeqCst);
        let message = native["message"].as_str()?.to_owned();
        if failure["severity"] == "error" || codex_retry::permanent(&native) {
            self.stop_message = Some(message);
            self.deadline = Some(Instant::now());
            return None;
        }
        if failure["severity"] != "warning" || native["willRetry"] != true {
            return None;
        }
        self.last_failure = Some(message.clone());
        self.native_attempt = self.native_attempt.saturating_add(1);
        if !self.native_replay_safe {
            // The engine owns this in-flight stream and its configured budget.
            // A Host deadline or second counter can abort recoverable work;
            // resending the prompt could execute its tools a second time.
            self.recovery_since.get_or_insert_with(Instant::now);
            return Some((turn_id, self.native_attempt, None));
        }
        self.deadline
            .get_or_insert_with(|| Instant::now() + RETRY_WINDOW);
        if self.native_attempt > MAX_ATTEMPTS {
            self.stop_message = Some(format!(
                "Reconnecting failed after five attempts. {message}"
            ));
            self.deadline = Some(Instant::now());
            return None;
        }
        Some((turn_id, self.native_attempt, Some(MAX_ATTEMPTS)))
    }

    pub(crate) fn timeout_message(&self) -> String {
        if let Some(message) = &self.stop_message {
            return message.clone();
        }
        match &self.last_failure {
            Some(message) if self.deadline.is_some() => {
                format!("Reconnecting exceeded 20 seconds. The turn was stopped. {message}")
            }
            _ => "The Agent connection stopped before the turn finished.".into(),
        }
    }

    fn can_replay(&self) -> bool {
        self.stop_message.is_none() && (self.eligible || (self.native && self.native_replay_safe))
    }
}

/// Use the adapter's public errorKind convention; never infer retryability from
/// arbitrary human-readable text, HTTP-looking model prose or unknown errors.
fn retryable(error: &Error) -> bool {
    if let Some(failure) = error
        .data
        .as_ref()
        .and_then(|data| data.get("sessionFailure"))
    {
        // Recovery actions are the adapter's explicit policy. Request, access
        // and exhausted-quota failures carry no retry action in this lane.
        // Some gateways' 400/402 bodies become generic service failures in the
        // CLI. Its error banner may veto retries; it can never enable one.
        if reported_http_status(failure["title"].as_str().unwrap_or_default())
            .is_some_and(|status| status < 500 && !matches!(status, 408 | 409 | 429))
        {
            return false;
        }
        return matches!(failure["category"].as_str(), Some("service" | "limit"))
            && failure["actions"]
                .as_array()
                .is_some_and(|actions| actions.iter().any(|action| action == "retry"));
    }
    matches!(
        error
            .data
            .as_ref()
            .and_then(|data| data.get("errorKind"))
            .and_then(|kind| kind.as_str()),
        Some("rate_limit" | "overloaded" | "server_error" | "transport_lost")
    )
}

/// Narrow compatibility guard for the CLI's provider-error banner, only within
/// a negotiated typed failure. Model text and arbitrary prose never reach it.
fn reported_http_status(title: &str) -> Option<u16> {
    let title = title.strip_prefix("API Error: ")?;
    let title = title.strip_prefix("Request rejected (").unwrap_or(title);
    let code = title.get(..3)?;
    if !code.bytes().all(|byte| byte.is_ascii_digit())
        || !matches!(title.as_bytes().get(3), None | Some(b' ' | b')' | b':'))
    {
        return None;
    }
    code.parse()
        .ok()
        .filter(|status| (100..=599).contains(status))
}

fn failure_message(failure: &serde_json::Value, title: &str) -> String {
    if let Some(native) = codex_retry::failure(title) {
        return native["message"]
            .as_str()
            .unwrap_or("The Codex request failed.")
            .into();
    }
    match failure["details"]
        .as_str()
        .filter(|details| !details.trim().is_empty() && details.len() <= 8192)
    {
        Some(details) => format!("{title}\n{details}"),
        None => title.into(),
    }
}

/// Preserve actionable error text without exposing the AIR incident object.
pub(crate) fn error_message(error: &Error) -> String {
    // Keep incident ids, revisions and duplicated JSON internal to retry policy.
    if error.data.as_ref().is_some_and(|data| {
        data.get("sessionFailure").is_some() || data["litheRecoveryStopped"] == true
    }) {
        error.message.clone()
    } else {
        error.to_string()
    }
}

/// Negotiated AIR failures complete with end_turn and a typed response payload,
/// not a JSON-RPC rejection. Normalize them before success reaches the product.
fn terminal_failure(response: &PromptResponse) -> Option<Error> {
    let meta = serde_json::to_value(response).ok()?;
    let air = &meta["_meta"]["jetbrains"]["air"];
    let failure = &air["sessionFailure"];
    if air["version"] != 1 || failure["severity"] != "error" {
        return None;
    }
    let title = failure["title"]
        .as_str()
        .filter(|title| {
            !title.trim().is_empty()
                && (title.len() <= 8192 || codex_retry::failure(title).is_some())
        })
        .unwrap_or("The Agent request failed.");
    Some(
        Error::new(-32603, failure_message(failure, title))
            .data(serde_json::json!({"sessionFailure": failure})),
    )
}

pub(crate) fn is_progress(update: &serde_json::Value) -> bool {
    match update["sessionUpdate"].as_str() {
        Some("agent_message_chunk" | "agent_thought_chunk") => {
            update["content"]["text"]
                .as_str()
                .is_some_and(|text| !text.is_empty())
                || update["content"]["type"]
                    .as_str()
                    .is_some_and(|kind| kind != "text")
        }
        Some("tool_call" | "tool_call_update" | "plan") => true,
        _ => false,
    }
}

/// Reuse the upstream session and agent, sending another prompt only after the
/// previous one terminated with a known temporary error and no visible work.
pub(crate) async fn run(
    connection: ConnectionTo<Agent>,
    request: PromptRequest,
    state: watch::Sender<State>,
    mut changes: watch::Receiver<State>,
    turn_id: String,
    emit: Emit,
) -> Result<PromptResponse, Error> {
    for attempt in 1..=MAX_ATTEMPTS {
        state.send_modify(|current| current.provider_message = None);
        let mut result = connection.send_request(request.clone()).block_task().await;
        if let Ok(response) = &result {
            if let Some(failure) = terminal_failure(response) {
                if state.borrow().native {
                    if let Some(sequence) = codex_retry::terminal_sequence(&failure) {
                        state
                            .borrow()
                            .native_sequence
                            .fetch_max(sequence, Ordering::SeqCst);
                    }
                }
                result = Err(failure);
            }
        }
        // A native response and the stop deadline can become ready together.
        // Keep the already observed failure even if a late response succeeds;
        // the settled request itself proves acknowledgment in this branch.
        if let Some(message) = &state.borrow().stop_message {
            return Err(Error::new(-32603, message.clone())
                .data(serde_json::json!({"litheRecoveryStopped": true})));
        }
        if let (Err(error), Some(message)) = (&mut result, &state.borrow().provider_message) {
            error.message = message.clone();
        }
        let Err(error) = &result else { return result };
        let can_reconnect = !state.borrow().cancelling
            && state.borrow().can_replay()
            && (retryable(error) && state.borrow().eligible
                || codex_retry::rate_limit(error)
                    && state.borrow().native
                    && state.borrow().native_attempt < MAX_ATTEMPTS);
        if can_reconnect {
            // An ACP failure settled the attempt, but its SDK stream may retain
            // a queued failed request. Clear it even after the final attempt so
            // an explicit next message cannot replay that pending work.
            let _ =
                connection.send_notification(CancelNotification::new(request.session_id.clone()));
        }
        if attempt == MAX_ATTEMPTS || !can_reconnect {
            return result;
        }
        state.send_modify(|current| {
            current
                .deadline
                .get_or_insert_with(|| Instant::now() + RETRY_WINDOW);
            current.last_failure = Some(error_message(error));
            if current.native {
                current.native_attempt += 1;
            }
        });
        emit(AgentEvent::TurnRetrying {
            session_id: request.session_id.0.to_string(),
            turn_id: turn_id.clone(),
            attempt: if state.borrow().native {
                state.borrow().native_attempt
            } else {
                attempt + 1
            },
            max_attempts: Some(MAX_ATTEMPTS),
        });
        // Four delays total 7.5 seconds. Provider Retry-After is not propagated
        // into this interactive policy; the user may retry again after failure.
        let delay = tokio::time::sleep(Duration::from_millis(500 << (attempt - 1)));
        tokio::pin!(delay);
        loop {
            if changes.borrow().cancelling {
                return Ok(PromptResponse::new(StopReason::Cancelled));
            }
            if !changes.borrow().can_replay() {
                return result;
            }
            tokio::select! {
                _ = &mut delay => break,
                changed = changes.changed() => if changed.is_err() { return result; },
            }
        }
        if state.borrow().cancelling {
            return Ok(PromptResponse::new(StopReason::Cancelled));
        }
        if !state.borrow().can_replay() {
            return result;
        }
    }
    unreachable!("bounded retry loop always returns its last result")
}

/// Keep the in-flight future alive on timeout so its owner can cancel and await
/// acknowledgment before releasing the turn or stopping the process tree.
pub(crate) async fn wait<F, T>(
    response: F,
    mut changes: watch::Receiver<State>,
    activity: impl Fn(bool),
) -> Result<T, ()>
where
    F: Future<Output = T>,
{
    let mut quiet_since = None;
    tokio::pin!(response);
    loop {
        let state = changes.borrow().clone();
        let suppressed =
            state.cancelling || state.pending_permissions > 0 || state.deadline.is_some();
        let notice_since = state.recovery_since.unwrap_or(state.last_progress);
        if quiet_since.is_some_and(|previous| previous != notice_since || suppressed) {
            quiet_since = None;
            activity(false);
        }
        let notice =
            (!suppressed && quiet_since.is_none()).then(|| notice_since + quiet_notice_delay());
        // Only pre-work recovery and terminal failures have a hard deadline.
        // Native recovery after work remains active until its engine ends it.
        let deadline = state.deadline.or(notice);
        tokio::select! {
            result = &mut response => return Ok(result),
            _ = async {
                match deadline {
                    Some(deadline) => tokio::time::sleep_until(deadline).await,
                    None => std::future::pending().await,
                }
            } => {
                if state.deadline.is_some() { return Err(()); }
                quiet_since = Some(notice_since);
                activity(true);
            },
            changed = changes.changed() => if changed.is_err() { return Err(()); },
        }
    }
}
