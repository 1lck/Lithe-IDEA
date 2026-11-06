//! Keymap rules that must run synchronously on native key events.

mod modifier_gesture;

pub use modifier_gesture::{
    modifier_gesture_step, modifier_gesture_step_json, GestureEvent, GestureState, GestureStep,
    MODIFIER_GESTURE_STEP, THRESHOLD_SECONDS,
};
