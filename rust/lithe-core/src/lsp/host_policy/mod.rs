//! Deterministic language-tooling rules that both platform hosts apply around
//! their native language-server sessions and editor presentation.
//!
//! Every command here is a pure function of the facts the platform submits:
//! no process, document, or clock is owned by Core. Platforms keep the native
//! I/O, the per-session storage of returned state, and localization.

pub(crate) mod activation;
pub(crate) mod completion_merge;
pub(crate) mod problems;

#[cfg(test)]
mod tests;
