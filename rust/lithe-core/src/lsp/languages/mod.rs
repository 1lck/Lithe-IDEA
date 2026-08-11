//! Dynamic provider metadata and host-model adapters for individual languages.

mod catalog;
pub(crate) mod jdt;
pub(crate) mod swift;

pub(crate) use catalog::*;
