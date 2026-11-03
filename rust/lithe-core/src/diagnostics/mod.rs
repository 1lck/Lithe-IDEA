//! Diagnostic-bundle redaction and manifest shaping shared by every host.
//!
//! Hosts gather log files, panic reports, and environment facts natively;
//! this module only contains pure, deterministic logic: scrubbing secrets
//! from text and shaping the manifest that lists what a bundle contains.
//! The bounded Core event handoff owns observation timestamps but no file writer.
//! No filesystem or process access happens here; native collection stays in
//! each platform's own adapters per `develop-lithe`'s platform-adapter
//! boundary.

pub mod catalog;
pub mod channel;
pub mod collection;
pub mod core_events;
pub mod filter;
pub mod format;
pub mod logging;
pub mod query_v2;
pub mod record;
pub mod retention;

pub(crate) mod helper_failures;

mod manifest;
mod redaction;

pub(crate) use manifest::*;
pub(crate) use redaction::*;
