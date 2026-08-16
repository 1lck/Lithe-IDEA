//! Language-specific project inspection that is independent from LSP transport.

mod java;
mod spring;

pub(crate) use java::*;
pub(crate) use spring::*;
