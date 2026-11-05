//! Transport-neutral Debug Adapter Protocol state and normalized debugger models.

pub(crate) mod adapters;
mod backend_start;
mod breakpoint_relocation;
mod capabilities;
mod endpoint;
mod engine;
mod java_test;
mod projection_v2;
mod protocol;
mod shortcut;
mod transport_lifecycle;
mod types;

pub(crate) use backend_start::decode_backend_configuration_command;
pub(crate) use breakpoint_relocation::*;
pub(crate) use endpoint::*;
pub(crate) use engine::*;
pub(crate) use java_test::*;
pub(crate) use shortcut::*;
pub(crate) use transport_lifecycle::*;
pub(crate) use types::*;

/// Prevents DevTools from restarting the application while a debugger replaces classes.
pub(crate) const JAVA_DEBUG_DISABLE_DEVTOOLS_RESTART: &str =
    "-Dspring.devtools.restart.enabled=false";
