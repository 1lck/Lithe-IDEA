//! Portable AI commit configuration parsing and HTTP request planning; hosts own I/O and secrets.

mod agent_configuration;
mod commands;
mod configuration;
mod generation;
pub(crate) use generation::{commit_input_budget, plan_commit_bounded, sensitive_path as is_sensitive_commit_path};

pub use agent_configuration::parse_provider_configuration;
pub use configuration::{parse_claude, parse_codex, DetectedConfiguration};
pub use generation::{
    decode_message, plan_commit, ChatTokenLimitField, CommitFile, CommitOptions, CommitRequestPlan,
    Provider,
};

#[cfg(test)]
mod tests;

pub(crate) use commands::{
    commit_input_budget_command, decode_commit_command, plan_commit_command,
};
