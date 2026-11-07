//! Portable AI CLI configuration parsing and HTTP request planning; hosts own I/O and secrets.

mod agent_configuration;
mod commands;
mod configuration;
mod generation;
mod inline_edit;
mod provider_request;
mod pull_request;
pub(crate) use generation::{
    commit_input_budget, plan_commit_bounded, sensitive_path as is_sensitive_commit_path,
};

pub use agent_configuration::{configuration_sources_command, parse_configuration_command};
pub use configuration::{
    configuration_sources, detect, is_configured, parse_claude, parse_codex, ConfigurationFile,
    ConfigurationFiles, ConfigurationSourceFile, CredentialLocator, DetectedConfiguration,
};
pub use generation::{
    decode_message, plan_commit, ChatTokenLimitField, CommitFile, CommitOptions, CommitRequestPlan,
    Provider,
};
pub use pull_request::{
    decode_pull_request, plan_pull_request, PullRequestComparison, PullRequestDescription,
    PullRequestOptions,
};

#[cfg(test)]
mod request_tests;
#[cfg(test)]
mod tests;

pub(crate) use commands::{
    commit_input_budget_command, decode_commit_command, decode_pull_request_command,
    plan_commit_command, plan_pull_request_command,
};
pub(crate) use inline_edit::{
    decode_command as decode_inline_edit_command, plan_command as plan_inline_edit_command,
};
