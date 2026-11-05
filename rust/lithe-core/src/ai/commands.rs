//! Credential-free JSON entry points for the shared commit generation rules.

use super::generation::commit_input_budget;
use super::{
    decode_message, decode_pull_request, plan_commit_bounded, plan_pull_request, CommitFile,
    CommitOptions, Provider, PullRequestComparison, PullRequestOptions,
};
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

#[derive(Deserialize)]
struct PullRequestPlanRequest {
    provider: Provider,
    options: PullRequestOptions,
    comparison: PullRequestComparison,
}

#[derive(Deserialize)]
struct PullRequestDecodeRequest {
    protocol: String,
    response: Value,
}

/// `ai.pullRequest.plan`: credential-free request for a pull request title and description.
pub(crate) fn plan_pull_request_command(payload: Value) -> Result<Value, CoreError> {
    let request: PullRequestPlanRequest =
        serde_json::from_value(payload).map_err(|_| invalid_payload())?;
    let plan = plan_pull_request(&request.provider, &request.options, &request.comparison)
        .map_err(|code| CoreError::new(ErrorCode::InvalidRequest, code))?;
    Ok(json!({"url": plan.url, "body": plan.body}))
}

/// `ai.pullRequest.decode`: strict title and description from a provider response.
pub(crate) fn decode_pull_request_command(payload: Value) -> Result<Value, CoreError> {
    let request: PullRequestDecodeRequest =
        serde_json::from_value(payload).map_err(|_| invalid_payload())?;
    let description = decode_pull_request(&request.protocol, &request.response)
        .map_err(|code| CoreError::new(ErrorCode::InvalidRequest, code))?;
    serde_json::to_value(description).map_err(|_| invalid_payload())
}
