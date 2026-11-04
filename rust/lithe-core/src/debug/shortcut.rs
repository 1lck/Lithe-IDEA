//! Portable decision for a combined start-or-continue debugger command.

use crate::protocol::{CoreError, ErrorCode};
use serde::Deserialize;
use serde_json::{json, Value};

/// Chooses one action without restarting a running session or overlapping a request.
pub(crate) fn start_or_continue(payload: Value) -> Result<Value, CoreError> {
    #[derive(Deserialize)]
    #[serde(rename_all = "camelCase", deny_unknown_fields)]
    struct Request {
        active: bool,
        paused: bool,
        request_pending: bool,
    }
    let request: Request = serde_json::from_value(payload).map_err(|error| {
        CoreError::new(ErrorCode::InvalidRequest, "Invalid debug shortcut state.")
            .with_details(error.to_string())
    })?;
    let action = if request.request_pending {
        "none"
    } else if !request.active {
        "start"
    } else if request.paused {
        "continue"
    } else {
        "none"
    };
    Ok(json!({ "action": action }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn starts_or_continues_only_when_the_current_session_allows_it() {
        for (active, paused, pending, expected) in [
            (false, false, false, "start"),
            (false, true, false, "start"),
            (true, true, false, "continue"),
            (true, false, false, "none"),
            (true, true, true, "none"),
            (false, false, true, "none"),
        ] {
            assert_eq!(
                start_or_continue(json!({"active": active, "paused": paused,
                "requestPending": pending}))
                .unwrap()["action"],
                expected
            );
        }
        assert!(start_or_continue(json!({"active": true, "paused": true})).is_err());
        assert!(start_or_continue(json!({"active": true, "paused": true,
            "requestPending": false, "unexpected": true}))
        .is_err());
    }
}
