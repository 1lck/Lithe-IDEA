//! Transport-neutral Debug Adapter Protocol state and normalized debugger models.

mod breakpoint_relocation;
mod engine;
mod java_test;
mod protocol;
mod types;

pub(crate) use breakpoint_relocation::*;
pub(crate) use engine::*;
pub(crate) use java_test::*;
pub(crate) use types::*;

/// Prevents DevTools from restarting the application while a debugger replaces classes.
pub(crate) const JAVA_DEBUG_DISABLE_DEVTOOLS_RESTART: &str =
    "-Dspring.devtools.restart.enabled=false";
