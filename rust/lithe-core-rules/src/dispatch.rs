//! Command routing and the JSON envelope shared with `lithe-core`.

use crate::{editor, keymap, visibility, RuleError, RuleErrorCode};
use serde::Deserialize;
use serde_json::{json, Value};

/// Every command name this crate owns. `lithe-core` routes exactly these names here.
pub const COMMANDS: &[&str] = &[
    keymap::MODIFIER_GESTURE_STEP,
    editor::REDUCE_WORKBENCH_STATE,
    visibility::CLASSIFY_VISIBILITY,
    visibility::VISIBILITY_DEFAULTS,
];

/// Reports whether `command` is owned by this crate.
pub fn is_rule_command(command: &str) -> bool {
    COMMANDS.contains(&command)
}

/// Runs one rule on an already decoded payload.
pub fn execute(command: &str, payload: Value) -> Result<Value, RuleError> {
    match command {
        keymap::MODIFIER_GESTURE_STEP => keymap::modifier_gesture_step_json(payload),
        editor::REDUCE_WORKBENCH_STATE => editor::reduce_json(payload),
        visibility::CLASSIFY_VISIBILITY => visibility::classify_visibility_json(payload),
        visibility::VISIBILITY_DEFAULTS => visibility::visibility_defaults_json(payload),
        _ => Err(RuleError::new(
            RuleErrorCode::NotSupported,
            "Unknown rule command",
        )),
    }
}

#[derive(Deserialize)]
struct Request {
    id: Option<String>,
    command: String,
    #[serde(default)]
    payload: Value,
}

/// Executes one Core-style JSON request and returns the JSON response envelope.
///
/// Unknown envelope fields (`operationId`, `origin`, ...) are ignored so hosts can send the
/// same request object they send to `lithe-core`.
pub fn execute_json(request: &str) -> String {
    let parsed: Request = match serde_json::from_str(request) {
        Ok(parsed) => parsed,
        Err(error) => {
            let error = RuleError::new(RuleErrorCode::InvalidRequest, "Invalid JSON request")
                .with_details(error.to_string());
            return failure(None, &error);
        }
    };
    match execute(&parsed.command, parsed.payload) {
        Ok(data) => json!({"id": parsed.id, "ok": true, "data": data}).to_string(),
        Err(error) => failure(parsed.id, &error),
    }
}

fn failure(id: Option<String>, error: &RuleError) -> String {
    json!({"id": id, "ok": false, "error": error}).to_string()
}
