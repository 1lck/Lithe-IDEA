//! Portable AI commit configuration parsing and HTTP request planning; hosts own I/O and secrets.

mod agent_configuration;
mod configuration;
mod generation;

pub use agent_configuration::parse_provider_configuration;
pub use configuration::{parse_claude, parse_codex, DetectedConfiguration};
pub use generation::{
    decode_message, plan_commit, ChatTokenLimitField, CommitFile, CommitOptions, CommitRequestPlan,
    Provider,
};

#[cfg(test)]
mod tests;
