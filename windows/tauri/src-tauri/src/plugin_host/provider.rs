//! Native build-provider session ownership. Core alone implements LSP,
//! negotiation, request framing and cancellation. The build router prepares,
//! reviews and confirms a native binding; capability rollout stays closed.

mod host;
mod runtime;
mod session;
#[cfg(test)]
mod tests;

pub(crate) use host::{
    authorize_shared_language, cancel_review, close_plugin, close_window, close_workspace, confirm,
    core_preflight, discard_review, drain_initialization, language_start, observe_core, prepare,
    remember_language_launch, set_workspace, ProviderHostState, ProviderReview,
};
pub(crate) use session::{ProviderBinding, ProviderContext, ProviderError};
