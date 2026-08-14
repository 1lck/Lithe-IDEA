//! Stable error categories and safe cross-boundary error serialization.

use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "snake_case")]
/// Stable failure categories understood by all Core consumers.
///
/// Keep these categories independent of Rust libraries and host operating
/// systems; implementation-specific context belongs in [`CoreError::details`].
pub enum ErrorCode {
    /// The request envelope, payload, path, or operation name is invalid.
    InvalidRequest,
    /// The requested workspace or repository root does not exist.
    WorkspaceNotFound,
    /// The operation would escape an allowed root or lacks filesystem access.
    PermissionDenied,
    /// The requested behavior is valid but unavailable in this Core build.
    NotSupported,
    /// A required host-discovered executable or runtime is unavailable.
    RuntimeMissing,
    /// A required child process could not be created.
    ProcessStartFailed,
    /// A child process started but failed while serving the operation.
    ProcessFailed,
    /// Input or tool output could not be decoded into the stable contract.
    ParseFailed,
    /// The caller cooperatively cancelled the operation.
    Cancelled,
    /// The operation exceeded its declared deadline.
    TimedOut,
    /// A failure does not fit a more stable cross-platform category.
    Unknown,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
/// Cross-boundary failure containing a stable category and actionable message.
pub struct CoreError {
    /// Machine-readable category used by application error handling.
    pub code: ErrorCode,
    /// User-facing summary that is safe to display.
    pub message: String,
    /// Optional diagnostic context that must not contain secrets.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub details: Option<String>,
}

impl CoreError {
    /// Creates an error without implementation-specific details.
    pub fn new(code: ErrorCode, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
            details: None,
        }
    }

    /// Adds safe diagnostic context while preserving the stable error category.
    pub fn with_details(mut self, details: impl Into<String>) -> Self {
        self.details = Some(details.into());
        self
    }
}

impl From<std::io::Error> for CoreError {
    fn from(error: std::io::Error) -> Self {
        let code = match error.kind() {
            std::io::ErrorKind::NotFound => ErrorCode::WorkspaceNotFound,
            std::io::ErrorKind::PermissionDenied => ErrorCode::PermissionDenied,
            _ => ErrorCode::Unknown,
        };
        Self::new(code, error.to_string())
    }
}

/// Workspace-relative paths use `/` in the shared contract even when the
/// caller is running on Windows. Validate both separator conventions so a
/// Windows-shaped path cannot bypass checks on another host.
pub fn invalid_relative_path(value: &str) -> bool {
    let normalized = value.replace('\\', "/");
    normalized.is_empty()
        || normalized.starts_with('/')
        || normalized.contains(':')
        || normalized.contains('\0')
        || normalized.split('/').any(|component| component == "..")
}
