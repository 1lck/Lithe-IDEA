//! Editor text-transform commands owned by Rust Core.
//!
//! macOS routes deterministic line-level editing through this package and
//! applies the returned replacement through its native text engine. Windows
//! still uses its local TypeScript implementation and is expected to adopt
//! the same contract in a follow-up change; the contract and fixtures here
//! are the canonical reference for that migration.

pub(crate) mod line_edit;

pub(crate) use line_edit::{
    line_comment_token, line_edit, LineCommentTokenRequest, LineEditRequest,
};

#[cfg(test)]
mod tests;
