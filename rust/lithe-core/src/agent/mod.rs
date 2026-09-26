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

/// Payload of `agent.install`, `agent.uninstall`, and `agent.installCli`.
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
    install::install_with_progress(
        &request.data_directory,
        &request.agent_id,
        &cancelled,
        &emit_progress,
    )
    .map(|version| serde_json::json!({ "agentId": request.agent_id, "installedVersion": version }))
    .map_err(core_error)
}

/// Update through the CLI's installation owner and return its verified outcome.
pub(crate) fn install_cli(request: AgentInstallRequest) -> Result<Value, CoreError> {
    absolute(&request.data_directory)?;
    install::install_cli_with_progress(&request.agent_id, &cancelled, &emit_progress)
        .map(|result| {
            serde_json::json!({ "agentId": request.agent_id,
            "cliVersion": result.cli_version, "updaterWarning": result.updater_warning })
        })
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

/// Request-scoped install event destination. No callbacks outlive a synchronous request.
#[derive(Clone)]
struct ProgressContext {
    sink: std::sync::Arc<dyn Fn(&str) + Send + Sync>,
    operation_id: Option<String>,
}
thread_local! {
    static PROGRESS: std::cell::RefCell<Option<ProgressContext>> = const { std::cell::RefCell::new(None) };
}

struct ProgressScope(Option<ProgressContext>);
impl Drop for ProgressScope {
    fn drop(&mut self) {
        PROGRESS.with(|p| *p.borrow_mut() = self.0.take());
    }
}

/// Shares the existing event ABI with npm management, preserving nested request scopes.
pub(crate) fn with_progress_sink<T>(
    request: &str,
    sink: std::sync::Arc<dyn Fn(&str) + Send + Sync>,
    work: impl FnOnce() -> T,
) -> T {
    let request: Value = serde_json::from_str(request).unwrap_or(Value::Null);
    let operation_id = request
        .get("operationId")
        .or_else(|| request.get("id"))
        .and_then(Value::as_str)
        .map(str::to_owned);
    let _scope =
        ProgressScope(PROGRESS.with(|p| p.replace(Some(ProgressContext { sink, operation_id }))));
    work()
}

fn emit_progress(progress: install::InstallProgress) {
    // Temporarily revoke the scope while delivering: a callback may re-enter Core.
    let context = PROGRESS.with(|p| p.take());
    let _restore = ProgressScope(context.clone());
    if let Some(context) = context {
        (context.sink)(&serde_json::json!({
            "kind": "agentInstallProgress", "operationId": context.operation_id, "progress": progress
        }).to_string());
    }
}
