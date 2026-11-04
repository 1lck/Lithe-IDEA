//! Credential-free JSON entry points for the shared commit generation rules.

use super::generation::{commit_input_budget, plan_commit_with_truncation};
use super::{decode_message, CommitFile, CommitOptions, Provider};
use crate::protocol::{CoreError, ErrorCode};
use serde::Deserialize;
use serde_json::{json, Value};

#[derive(Deserialize)]
struct PlanRequest {
    provider: Provider,
    options: CommitOptions,
    files: Vec<BoundedFile>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct BoundedFile {
    #[serde(flatten)]
    file: CommitFile,
    original_characters: usize,
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
        .collect();
    let budgets = commit_input_budget(request.options.maximum_diff_characters, &lengths)
        .map_err(|code| CoreError::new(ErrorCode::InvalidRequest, code))?;
    let mut truncated = Vec::with_capacity(budgets.len());
    for (file, budget) in request.files.iter().zip(&budgets) {
        if file.file.diff.chars().count() != budget.characters {
            return Err(invalid_payload());
        }
        truncated.push(budget.truncated);
    }
    let files: Vec<CommitFile> = request.files.into_iter().map(|item| item.file).collect();
    let plan = plan_commit_with_truncation(&request.provider, &request.options, &files, &truncated)
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
