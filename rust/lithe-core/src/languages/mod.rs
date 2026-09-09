//! Language-specific project inspection that is independent from LSP transport.

mod java;
mod java_syntax;
mod mybatis;
mod spring;

pub(crate) use java::*;
pub(crate) use mybatis::*;
pub(crate) use spring::*;
