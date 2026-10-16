//! Capability-negotiated ACP steering and ownership of detached Codex continuations.
//!
//! The pinned Codex adapter can start a new turn when steering races completion.
//! Its explicit thread-status notifications keep that continuation inside the
//! original Host turn; silence and token counts never imply completion.

use std::sync::Mutex;

use agent_client_protocol::schema::v1::ContentBlock;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use tokio::sync::watch;

#[derive(Debug, Clone, Serialize, Deserialize, agent_client_protocol::JsonRpcRequest)]
#[request(method = "_session/steering", response = Response)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Request {
    session_id: String,
    prompt: Vec<ContentBlock>,
    #[serde(rename = "_meta")]
    meta: Value,
}

#[derive(Debug, Clone, Serialize, Deserialize, agent_client_protocol::JsonRpcResponse)]
pub(crate) struct Response {
    pub outcome: String,
}

#[derive(Clone, Default)]
struct Progress {
    pending: bool,
    idle_count: u64,
    status: Option<String>,
    continuation_idle: Option<u64>,
}

fn terminal(status: Option<&str>) -> bool {
    matches!(status, Some("idle" | "systemError" | "notLoaded"))
}

/// One logical Host turn, including steering that upstream moves into a new turn.
pub(crate) struct Turn {
    progress: Mutex<watch::Sender<Progress>>,
}

impl Default for Turn {
    fn default() -> Self {
        Self {
            progress: Mutex::new(watch::channel(Progress::default()).0),
        }
    }
}

impl Turn {
    /// Reserve one request and remember which native idle must end a fallback.
    pub(crate) fn begin(&self) -> Option<u64> {
        let progress = self.progress.lock().ok()?;
        let snapshot = progress.borrow().clone();
        if snapshot.pending {
            return None;
        }
        // An active original turn must first settle, then its detached
        // continuation must settle. Failed originals can report systemError
        // rather than idle. Duplicate terminal notifications do not count.
        let target = snapshot.idle_count
            + if terminal(snapshot.status.as_deref()) {
                1
            } else {
                2
            };
        progress.send_modify(|state| state.pending = true);
        Some(target)
    }

    pub(crate) fn finish(&self, continuation_idle: Option<u64>) {
        if let Ok(progress) = self.progress.lock() {
            progress.send_modify(|state| {
                state.pending = false;
                if let Some(idle) = continuation_idle {
                    state.continuation_idle = Some(idle);
                }
            });
        }
    }

    pub(crate) fn observe(&self, update: &Value) {
        let Some(status) = update
            .pointer("/_meta/codex/threadStatus/type")
            .and_then(Value::as_str)
        else {
            return;
        };
        if let Ok(progress) = self.progress.lock() {
            progress.send_modify(|state| {
                if terminal(Some(status)) && !terminal(state.status.as_deref()) {
                    state.idle_count += 1;
                }
                state.status = Some(status.to_owned());
            });
        }
    }

    /// Waits without a turn deadline. Connection shutdown aborts the owning
    /// task; the normal Host cancellation watchdog still bounds explicit Stop.
    pub(crate) async fn settled(&self) -> Result<bool, String> {
        let mut receiver = self
            .progress
            .lock()
            .map_err(|_| "Steering state is unavailable")?
            .subscribe();
        loop {
            let state = receiver.borrow_and_update().clone();
            if !state.pending {
                match state.continuation_idle {
                    None => return Ok(false),
                    Some(idle) if state.idle_count >= idle => {
                        return if state.status.as_deref() == Some("idle") {
                            Ok(true)
                        } else {
                            Err("The Agent continuation failed".into())
                        };
                    }
                    _ => {}
                }
            }
            receiver
                .changed()
                .await
                .map_err(|_| "The Agent connection closed")?;
        }
    }
}

pub(crate) fn supported(meta: Option<&serde_json::Map<String, Value>>) -> bool {
    meta.and_then(|meta| meta.get("steering"))
        .and_then(|value| value.get("supported"))
        .and_then(Value::as_bool)
        == Some(true)
}

pub(crate) fn request(session_id: &str, content: Vec<ContentBlock>) -> Request {
    Request {
        session_id: session_id.into(),
        prompt: content,
        meta: json!({ "steering": { "idleBehavior": "promptRequired" } }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    fn status(turn: &Turn, status: &str) {
        turn.observe(&json!({ "_meta": { "codex": { "threadStatus": { "type": status } } } }));
    }

    #[tokio::test]
    async fn continuation_can_finish_before_its_steering_acknowledgement() {
        let turn = Turn::default();
        status(&turn, "active");
        let target = turn.begin().unwrap();
        status(&turn, "idle");
        status(&turn, "active");
        status(&turn, "idle");
        turn.finish(Some(target));
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(1), turn.settled())
                .await
                .unwrap(),
            Ok(true)
        );
    }

    #[tokio::test]
    async fn already_idle_original_requires_only_the_continuations_idle() {
        let turn = Turn::default();
        status(&turn, "idle");
        let target = turn.begin().unwrap();
        assert!(
            turn.begin().is_none(),
            "one outstanding delivery per session"
        );
        status(&turn, "active");
        status(&turn, "idle");
        turn.finish(Some(target));
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(1), turn.settled())
                .await
                .unwrap(),
            Ok(true)
        );
    }

    #[tokio::test]
    async fn a_failed_original_does_not_strand_a_successful_continuation() {
        let turn = Turn::default();
        status(&turn, "active");
        let target = turn.begin().unwrap();
        status(&turn, "systemError");
        status(&turn, "idle");
        status(&turn, "active");
        status(&turn, "idle");
        turn.finish(Some(target));
        assert_eq!(
            tokio::time::timeout(Duration::from_secs(1), turn.settled())
                .await
                .unwrap(),
            Ok(true)
        );
    }
}
