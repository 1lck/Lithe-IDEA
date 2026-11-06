//! Failure type whose JSON shape matches the Core error envelope.

use serde::Serialize;

/// Stable failure categories. Names serialize exactly like the matching `lithe-core` codes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum RuleErrorCode {
    /// The request envelope or payload does not match the command contract.
    InvalidRequest,
    /// The command name is not a rule owned by this crate.
    NotSupported,
}

/// A rule failure with a stable category and a message that is safe to display.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RuleError {
    /// Machine-readable category.
    pub code: RuleErrorCode,
    /// Short summary of the failure.
    pub message: String,
    /// Optional diagnostic context; never contains secrets.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<String>,
}

impl RuleError {
    /// Creates an error without diagnostic details.
    pub fn new(code: RuleErrorCode, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            details: None,
        }
    }

    /// Attaches diagnostic context while keeping the category.
    pub fn with_details(mut self, details: impl Into<String>) -> Self {
        self.details = Some(details.into());
        self
    }
}
