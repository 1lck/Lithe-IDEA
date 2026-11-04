//! Credential-free JSON entry points for the shared commit generation rules.

use super::generation::commit_input_budget;
use super::{decode_message, plan_commit_bounded, CommitFile, CommitOptions, Provider};
use crate::protocol::{CoreError, ErrorCode};
use serde::Deserialize;
use serde_json::{json, Value};

#[derive(Deserialize)]
struct PlanRequest {
    provider: Provider,
    options: CommitOptions,
    files: Vec<CommitFile>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct BudgetRequest {
    maximum_diff_characters: usize,
    file_lengths: Vec<usize>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DecodeRequest {
    protocol: String,
    response: Value,
    include_body: bool,
}

// Avoid echoing untrusted payloads, including diffs or provider responses, in diagnostics.
fn invalid_payload() -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, "AI_COMMIT_INVALID_OPTIONS")
}

pub(crate) fn plan_commit_command(payload: Value) -> Result<Value, CoreError> {
    let request: PlanRequest = serde_json::from_value(payload).map_err(|_| invalid_payload())?;
    let lengths: Vec<usize> = request
        .files
        .iter()
        .map(|file| file.original_characters)
        .collect::<Option<Vec<_>>>()
        .ok_or_else(invalid_payload)?;
    let files = request.files;
    let plan = plan_commit_bounded(&request.provider, &request.options, &files, &lengths)
        .map_err(|code| CoreError::new(ErrorCode::InvalidRequest, code))?;
    Ok(json!({"url": plan.url, "body": plan.body}))
}

pub(crate) fn decode_commit_command(payload: Value) -> Result<Value, CoreError> {
    let request: DecodeRequest = serde_json::from_value(payload).map_err(|_| invalid_payload())?;
    let message = decode_message(&request.protocol, &request.response, request.include_body)
        .map_err(|code| CoreError::new(ErrorCode::InvalidRequest, code))?;
    Ok(json!({"message": message}))
}

pub(crate) fn commit_input_budget_command(payload: Value) -> Result<Value, CoreError> {
    let request: BudgetRequest = serde_json::from_value(payload).map_err(|_| invalid_payload())?;
    let files = commit_input_budget(request.maximum_diff_characters, &request.file_lengths)
        .map_err(|code| CoreError::new(ErrorCode::InvalidRequest, code))?;
    Ok(json!({"files": files}))
}
