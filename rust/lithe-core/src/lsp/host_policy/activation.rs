//! Language-server activation retry policy (`lsp.activationPolicy`).
//!
//! The platform owns processes and stores the returned state per server
//! identity (provider or language plus workspace root). Core decides whether
//! an automatic start may run now, must wait for the failure cooldown, or
//! needs an explicit user retry, so a persistent startup failure can neither
//! loop unboundedly nor retry at different rates on the two platforms.
//!
//! Time is a caller-supplied monotonic millisecond reading. Core never reads a
//! clock, which keeps the policy deterministic and unaffected by wall-clock
//! adjustments.

use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Consecutive failures after which automatic starts stop until the user retries.
pub(crate) const MAX_CONSECUTIVE_FAILURES: u32 = 3;
/// Minimum delay between a failure and the next automatic start.
pub(crate) const FAILURE_COOLDOWN_MS: u64 = 5_000;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Request {
    /// State returned by the previous call for this server; `null` when none.
    #[serde(default)]
    state: Option<ActivationState>,
    event: ActivationEvent,
    /// Monotonic clock reading in milliseconds from the platform.
    now_ms: u64,
}

/// Failure history the platform stores verbatim between calls.
#[derive(Deserialize, Serialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ActivationState {
    /// Failures since the last ready session or explicit start.
    consecutive_failures: u32,
    /// Monotonic time of the latest failure.
    last_failure_at_ms: u64,
}

#[derive(Deserialize, Clone, Copy)]
#[serde(rename_all = "camelCase")]
enum ActivationEvent {
    /// A start triggered by opening or synchronizing a document.
    AutomaticStart,
    /// A start the user requested (restart, retry, or repair).
    ExplicitStart,
    /// A start or a running session failed.
    StartFailed,
    /// The session reached its ready state.
    Ready,
}

#[derive(Serialize, Clone, Copy, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
enum Decision {
    /// A start may run now.
    Allow,
    /// Automatic starts must wait `retryAfterMs`.
    Wait,
    /// Automatic starts are exhausted; only an explicit start may run.
    ExplicitRetryRequired,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Response {
    /// State to store for the next call; `null` clears the history.
    state: Option<ActivationState>,
    decision: Decision,
    /// Remaining cooldown when `decision` is `wait`.
    retry_after_ms: Option<u64>,
}

/// Executes `lsp.activationPolicy`.
pub(crate) fn policy_command(payload: Value) -> Result<Value, CoreError> {
    let request: Request = serde_json::from_value(payload).map_err(|error| {
        CoreError::new(
            ErrorCode::InvalidRequest,
            "Invalid language server activation request",
        )
        .with_details(error.to_string())
    })?;
    Ok(serde_json::to_value(evaluate(request)).expect("activation response should encode"))
}

fn evaluate(request: Request) -> Response {
    match request.event {
        ActivationEvent::ExplicitStart | ActivationEvent::Ready => Response {
            state: None,
            decision: Decision::Allow,
            retry_after_ms: None,
        },
        ActivationEvent::StartFailed => {
            let state = ActivationState {
                consecutive_failures: request
                    .state
                    .map_or(0, |state| state.consecutive_failures)
                    .saturating_add(1),
                last_failure_at_ms: request.now_ms,
            };
            automatic(state, request.now_ms)
        }
        ActivationEvent::AutomaticStart => match request.state {
            None => Response {
                state: None,
                decision: Decision::Allow,
                retry_after_ms: None,
            },
            Some(state) => automatic(state, request.now_ms),
        },
    }
}

fn automatic(state: ActivationState, now_ms: u64) -> Response {
    if state.consecutive_failures >= MAX_CONSECUTIVE_FAILURES {
        return Response {
            state: Some(state),
            decision: Decision::ExplicitRetryRequired,
            retry_after_ms: None,
        };
    }
    // A reading earlier than the stored failure means the platform switched
    // clocks; restart the cooldown from now instead of trusting the gap.
    let state = if now_ms < state.last_failure_at_ms {
        ActivationState {
            last_failure_at_ms: now_ms,
            ..state
        }
    } else {
        state
    };
    let elapsed = now_ms - state.last_failure_at_ms;
    if elapsed < FAILURE_COOLDOWN_MS {
        Response {
            state: Some(state),
            decision: Decision::Wait,
            retry_after_ms: Some(FAILURE_COOLDOWN_MS - elapsed),
        }
    } else {
        Response {
            state: Some(state),
            decision: Decision::Allow,
            retry_after_ms: None,
        }
    }
}
