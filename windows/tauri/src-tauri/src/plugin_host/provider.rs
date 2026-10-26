//! Native build-provider session ownership. Core alone implements LSP,
//! negotiation, request framing and cancellation. No build.* route or host
//! capability is enabled here; future routing must prepare, review, confirm,
//! then use the returned native binding.

mod host;
mod runtime;
mod session;
#[cfg(test)]
mod tests;

pub(crate) use host::{
    cancel_review, close_plugin, close_window, close_workspace, confirm, core_preflight,
    language_start, observe_core, prepare, remember_language_launch, set_workspace,
    ProviderHostState, ProviderReview,
};
pub(crate) use session::{ProviderBinding, ProviderContext, ProviderError};
