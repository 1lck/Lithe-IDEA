//! Dynamic provider metadata and host-model adapters for individual languages.

mod catalog;
pub(crate) mod jdt;
#[cfg(test)]
pub(crate) mod swift;

pub(crate) use catalog::*;
