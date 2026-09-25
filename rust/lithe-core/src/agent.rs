//! Agent adapter management commands backed by `lithe-agent-host`.
//!
//! Detection and installs use the user's own Node.js and npm; Core only maps
//! requests, cooperative cancellation, and failures onto the shared envelope.

use std::path::PathBuf;

use serde::Deserialize;
use serde_json::Value;

use crate::protocol::{cancellation, CoreError, ErrorCode};
use lithe_agent_host::install::{self, ManagementError};

/// Payload of `agent.status`.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AgentStatusRequest {
    /// Platform-owned directory holding Lithe-managed adapter installs.
    data_directory: PathBuf,
}

/// Payload of `agent.install` and `agent.uninstall`.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct AgentInstallRequest {
    data_directory: PathBuf,
    /// ACP registry id of a catalog agent, e.g. `codex-acp`.
    agent_id: String,
}

fn cancelled() -> bool {
    cancellation::check().is_err()
}

fn absolute(directory: &PathBuf) -> Result<(), CoreError> {
    if directory.is_absolute() {
        Ok(())
    } else {
        Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "The agent data directory must be absolute",
        ))
    }
}

/// Detect Node.js and npm and report every catalog agent's install state.
pub(crate) fn status(request: AgentStatusRequest) -> Result<Value, CoreError> {
    absolute(&request.data_directory)?;
    let status = install::status(&request.data_directory, &cancelled);
    cancellation::check()?;
    serde_json::to_value(status)
        .map_err(|error| CoreError::new(ErrorCode::Unknown, error.to_string()))
}

/// Install the pinned adapter version with the user's npm.
pub(crate) fn install(request: AgentInstallRequest) -> Result<Value, CoreError> {
    absolute(&request.data_directory)?;
    install::install(&request.data_directory, &request.agent_id, &cancelled)
        .map(|version| serde_json::json!({ "agentId": request.agent_id, "installedVersion": version }))
        .map_err(core_error)
}

/// Remove a Lithe-managed adapter install.
pub(crate) fn uninstall(request: AgentInstallRequest) -> Result<Value, CoreError> {
    absolute(&request.data_directory)?;
    install::uninstall(&request.data_directory, &request.agent_id)
        .map(|()| serde_json::json!({ "agentId": request.agent_id }))
        .map_err(core_error)
}

fn core_error(error: ManagementError) -> CoreError {
    // Prefer the envelope's own cancellation state so a deadline reports
    // `timed_out` and a user cancel reports `cancelled`.
    if matches!(error, ManagementError::Cancelled) {
        if let Err(error) = cancellation::check() {
            return error;
        }
    }
    let code = match error {
        ManagementError::UnknownAgent(_) => ErrorCode::InvalidRequest,
        ManagementError::RuntimeMissing(_) => ErrorCode::RuntimeMissing,
        ManagementError::Failed(_) => ErrorCode::ProcessFailed,
        ManagementError::Cancelled => ErrorCode::Cancelled,
        ManagementError::TimedOut => ErrorCode::TimedOut,
    };
    CoreError::new(code, error.message())
}
