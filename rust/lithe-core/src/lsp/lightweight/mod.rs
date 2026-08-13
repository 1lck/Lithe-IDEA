//! In-process language features that remain available without an LSP server.

mod edits;
mod snippets;
mod symbols;

pub(crate) use edits::*;
pub(crate) use snippets::*;
pub(crate) use symbols::*;
