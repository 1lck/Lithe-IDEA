//! Pure, synchronous product rules shared by every host.
//!
//! This crate holds rules that are small, deterministic and sit on a synchronous hot path
//! (for example a gesture recognizer that runs on every native key event). It performs no
//! file-system, process, thread or clock access: time is always supplied by the caller.
//!
//! The same source is consumed twice:
//! - `lithe-core` links it as a normal dependency and exposes each rule through its JSON
//!   command dispatch, so macOS and the Windows backend reach it over the usual Core channel.
//! - On `wasm32` it is built as a `cdylib` whose `extern "C"` exports (see the private `wasm` module) let the
//!   Windows frontend call the very same rules synchronously, without a Tauri IPC round trip.
//!
//! Requests and responses reuse the Core envelope: `{id, command, payload}` in and
//! `{id, ok, data | error}` out, with the same stable error codes.

mod dispatch;
pub mod editor;
mod error;
pub mod keymap;
pub mod visibility;
#[cfg(target_arch = "wasm32")]
mod wasm;

pub use dispatch::{execute, execute_json, is_rule_command, COMMANDS};
pub use error::{RuleError, RuleErrorCode};
