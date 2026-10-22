//! Typed global-instruction requests; native file ownership stays in Agent Host.

use crate::protocol::{cancellation, CoreError, ErrorCode};
use lithe_agent_host::instructions::{self, InstructionError, SaveRequest};
use serde::Deserialize;
use serde_json::Value;

/// Selects a supported upstream Agent, never an arbitrary filesystem path.
#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ReadRequest {
    agent_id: String,
}

/// Reads the effective native global file without creating directories or files.
pub(crate) fn read(request: ReadRequest) -> Result<Value, CoreError> {
    cancellation::check()?;
    encode(instructions::read(&request.agent_id))
}

/// Atomically saves against the snapshot the user edited; preserves native loading.
pub(crate) fn save(request: SaveRequest) -> Result<Value, CoreError> {
    cancellation::check()?;
    encode(instructions::save(request))
}

fn encode(
    result: Result<instructions::InstructionFile, InstructionError>,
) -> Result<Value, CoreError> {
    let file = result.map_err(core_error)?;
    serde_json::to_value(file)
        .map_err(|error| CoreError::new(ErrorCode::Unknown, error.to_string()))
}

/// Reads or synchronizes a platform-owned shared instruction library.
pub(crate) fn shared(request: instructions::shared::Request) -> Result<Value, CoreError> {
    cancellation::check()?;
    let result = instructions::shared::execute(request, &|| cancellation::check().is_err())
        .map_err(core_error)?;
    serde_json::to_value(result)
        .map_err(|error| CoreError::new(ErrorCode::Unknown, error.to_string()))
}

fn core_error(error: InstructionError) -> CoreError {
    let code = match error.reason {
        "unsupported_agent" => ErrorCode::NotSupported,
        "file_access" | "unsafe_file" => ErrorCode::PermissionDenied,
        _ => ErrorCode::InvalidRequest,
    };
    CoreError::new(code, error.message).with_details(error.reason)
}
