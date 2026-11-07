//! Double-Shift gesture recognizer as a pure state transition.
//!
//! The host owns the [`GestureState`] value and the clock. For each native event it sends the
//! current state, the event and a timestamp, and stores the state that comes back. Nothing here
//! keeps hidden state, so the same sequence always gives the same result on every host.

use crate::{RuleError, RuleErrorCode};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Command name of the gesture step in the Core command namespace.
pub const MODIFIER_GESTURE_STEP: &str = "keymap.modifierGestureStep";

/// Largest gap, in seconds, between two standalone Shift releases that still counts as a double tap.
pub const THRESHOLD_SECONDS: f64 = 0.35;

/// Recognizer memory carried between events. The default value is the idle state.
#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields, default)]
pub struct GestureState {
    /// Whether Shift is currently held.
    pub shift_was_down: bool,
    /// Whether the current Shift press has not been combined with any other key or modifier.
    pub current_press_is_standalone: bool,
    /// Release time of the previous standalone tap, if one is still pending.
    pub last_standalone_tap: Option<f64>,
}

/// One native input event, reduced to what the gesture needs.
#[derive(Debug, Clone, Copy, PartialEq, Deserialize)]
#[serde(
    tag = "kind",
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
pub enum GestureEvent {
    /// A non-Shift key was pressed; it breaks any pending tap.
    KeyDown,
    /// The host lost track of the keyboard (focus change, suspension); forget everything.
    Reset,
    /// The modifier flags changed.
    Flags {
        /// Whether Shift is down after the change.
        shift: bool,
        /// Whether Command, Control, Option or Function (or Ctrl/Alt/Meta) is down.
        other_modifiers: bool,
    },
}

/// Result of one transition.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GestureStep {
    /// State to hand back with the next event.
    pub state: GestureState,
    /// True exactly when this event completed a double Shift tap.
    pub triggered: bool,
}

/// Applies one event to `state`. `timestamp` is in seconds on any monotonic clock the host keeps.
pub fn modifier_gesture_step(
    state: GestureState,
    event: GestureEvent,
    timestamp: f64,
) -> GestureStep {
    let mut next = state;
    let triggered = match event {
        GestureEvent::KeyDown => {
            next.current_press_is_standalone = false;
            next.last_standalone_tap = None;
            false
        }
        GestureEvent::Reset => {
            next = GestureState::default();
            false
        }
        GestureEvent::Flags {
            shift,
            other_modifiers,
        } => flags_changed(&mut next, shift, other_modifiers, timestamp),
    };
    GestureStep {
        state: next,
        triggered,
    }
}

fn flags_changed(
    state: &mut GestureState,
    shift: bool,
    other_modifiers: bool,
    timestamp: f64,
) -> bool {
    if shift && !state.shift_was_down {
        state.current_press_is_standalone = !other_modifiers;
        state.shift_was_down = true;
        return false;
    }
    if shift && state.shift_was_down {
        if other_modifiers {
            state.current_press_is_standalone = false;
            state.last_standalone_tap = None;
        }
        return false;
    }
    if !shift && state.shift_was_down {
        state.shift_was_down = false;
        let was_standalone = state.current_press_is_standalone;
        state.current_press_is_standalone = false;
        if !was_standalone || other_modifiers {
            state.last_standalone_tap = None;
            return false;
        }
        if let Some(previous) = state.last_standalone_tap {
            let gap = timestamp - previous;
            if gap >= 0.0 && gap < THRESHOLD_SECONDS {
                state.last_standalone_tap = None;
                return true;
            }
        }
        state.last_standalone_tap = Some(timestamp);
        return false;
    }
    if other_modifiers {
        state.last_standalone_tap = None;
    }
    false
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StepRequest {
    #[serde(default)]
    state: GestureState,
    event: GestureEvent,
    #[serde(default)]
    timestamp: f64,
}

/// JSON adapter for `keymap.modifierGestureStep`: `{state?, event, timestamp}` in,
/// `{state, triggered}` out.
pub fn modifier_gesture_step_json(payload: Value) -> Result<Value, RuleError> {
    let request: StepRequest = serde_json::from_value(payload).map_err(|error| {
        RuleError::new(
            RuleErrorCode::InvalidRequest,
            "Invalid modifier gesture request",
        )
        .with_details(error.to_string())
    })?;
    let step = modifier_gesture_step(request.state, request.event, request.timestamp);
    Ok(serde_json::to_value(step).expect("gesture step should encode"))
}
