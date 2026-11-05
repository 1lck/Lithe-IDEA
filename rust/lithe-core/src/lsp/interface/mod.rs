//! Standard LSP contracts and the stateful client/session implementation.

mod build_provider;
mod client;
/// Decodes the path of a `file:` URI an extension reply names.
pub(crate) use client::percent_decode;
mod document_uri;
mod engine;
mod engine_logging;
mod function_relay;
mod keymap_provider;
pub(crate) mod plugin_function;
mod plugin_logging;
mod plugin_server;
pub(crate) mod process;
pub(crate) mod remote_process;
#[cfg(test)]
mod scripted;
mod toolchain_provider;
mod transport;
mod types;
mod vcs_provider;

pub(crate) use client::*;
pub(crate) use document_uri::{
    document_uri_command, resolve_field as resolve_uri_field, resolve_request_paths,
};
pub(crate) use engine::*;
pub(crate) use engine_logging::{resolve_engine_log_subject, ResolveEngineLogSubjectRequest};
pub(crate) use function_relay::RelaySnapshot;
pub(crate) use transport::*;
pub(crate) use types::*;
