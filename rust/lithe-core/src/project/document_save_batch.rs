//! Membership and result rules for saving a batch of open documents.
//!
//! "Save All" and the save that precedes Run, Debug, Test or a project
//! transition share one rule set: which open documents take part, and when the
//! batch counts as complete. Platforms own the writes themselves (sequential or
//! concurrent), dialogs, and failure notifications; they report each member's
//! outcome together with the live documents observed after the writes, so
//! edits or documents that appeared while saving keep the batch incomplete.

use std::collections::{HashMap, HashSet};

use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Maximum number of open documents accepted by one batch request.
pub(crate) const MAX_SAVE_BATCH_DOCUMENTS: usize = 10_000;

/// Persistence facts a platform reports for one open document.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct BatchDocument {
    /// Platform document identity, unique within the request.
    id: String,
    /// The platform model holds text that differs from the last saved text.
    dirty: bool,
    /// The document cannot be written by the editor.
    read_only: bool,
    /// False when the editor view may still hold input that the platform
    /// model has not received, so a clean model does not prove a clean editor.
    content_synchronized: bool,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct PlanRequest {
    documents: Vec<BatchDocument>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct PlanResponse {
    /// Documents to save, in request order.
    members: Vec<String>,
}

/// Outcome of saving one batch member.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
enum MemberOutcome {
    Saved,
    Failed,
    /// The write did not run because the user or the caller cancelled it.
    Cancelled,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct MemberResult {
    id: String,
    outcome: MemberOutcome,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ReduceRequest {
    /// Members returned by `document.planSaveBatch`.
    members: Vec<String>,
    /// Exactly one result per member.
    results: Vec<MemberResult>,
    /// Live open documents observed after every member finished.
    documents: Vec<BatchDocument>,
}

/// Aggregate batch status, in decreasing precedence.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
enum BatchStatus {
    /// At least one member was cancelled; callers abort without an error.
    Cancelled,
    /// At least one member failed to save.
    Failed,
    /// Every member saved, but a live document is still dirty.
    Incomplete,
    /// Every member saved and no live document is dirty.
    Saved,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ReduceResponse {
    status: BatchStatus,
    /// Members that saved and are not dirty again.
    saved_count: usize,
    failed: Vec<String>,
    cancelled: Vec<String>,
    /// Live dirty documents, in live document order, whether or not they were
    /// members: edits made during the batch and newly opened documents count.
    remaining_dirty: Vec<String>,
}

/// Selects the documents a save batch writes (`document.planSaveBatch`).
///
/// A writable document takes part when it is dirty or when its editor view may
/// hold unsynchronized input. Returns `invalidRequest` for malformed payloads,
/// empty or duplicate identities, or more than [`MAX_SAVE_BATCH_DOCUMENTS`].
pub(crate) fn plan_command(payload: Value) -> Result<Value, CoreError> {
    let request: PlanRequest = decode(payload)?;
    validate_documents(&request.documents)?;
    let members = request
        .documents
        .into_iter()
        .filter(|document| {
            !document.read_only && (document.dirty || !document.content_synchronized)
        })
        .map(|document| document.id)
        .collect();
    Ok(serde_json::to_value(PlanResponse { members }).expect("save batch plan should encode"))
}

/// Reduces member outcomes and live documents into one batch result
/// (`document.reduceSaveBatch`).
///
/// Returns `invalidRequest` when results do not name each member exactly once,
/// in addition to the document validation of [`plan_command`].
pub(crate) fn reduce_command(payload: Value) -> Result<Value, CoreError> {
    let request: ReduceRequest = decode(payload)?;
    validate_documents(&request.documents)?;
    if request.members.len() > MAX_SAVE_BATCH_DOCUMENTS {
        return Err(invalid("Save batch has too many members"));
    }
    let mut outcomes: HashMap<&str, MemberOutcome> = HashMap::new();
    for result in &request.results {
        if outcomes.insert(&result.id, result.outcome).is_some() {
            return Err(invalid("Save batch results repeat a member"));
        }
    }
    let mut members = HashSet::new();
    for member in &request.members {
        if !members.insert(member.as_str()) || !outcomes.contains_key(member.as_str()) {
            return Err(invalid("Save batch results must name each member once"));
        }
    }
    if outcomes.len() != members.len() {
        return Err(invalid("Save batch results name a non-member"));
    }

    // Read-only documents cannot be saved, but unsaved text in one still means
    // the batch did not persist everything the user sees.
    let remaining_dirty: Vec<String> = request
        .documents
        .iter()
        .filter(|document| document.dirty)
        .map(|document| document.id.clone())
        .collect();
    let dirty: HashSet<&str> = remaining_dirty.iter().map(String::as_str).collect();
    let with_outcome = |wanted: MemberOutcome| -> Vec<String> {
        request
            .members
            .iter()
            .filter(|member| outcomes[member.as_str()] == wanted)
            .cloned()
            .collect()
    };
    let failed = with_outcome(MemberOutcome::Failed);
    let cancelled = with_outcome(MemberOutcome::Cancelled);
    let saved_count = request
        .members
        .iter()
        .filter(|member| {
            outcomes[member.as_str()] == MemberOutcome::Saved && !dirty.contains(member.as_str())
        })
        .count();
    let status = if !cancelled.is_empty() {
        BatchStatus::Cancelled
    } else if !failed.is_empty() {
        BatchStatus::Failed
    } else if !remaining_dirty.is_empty() {
        BatchStatus::Incomplete
    } else {
        BatchStatus::Saved
    };
    Ok(serde_json::to_value(ReduceResponse {
        status,
        saved_count,
        failed,
        cancelled,
        remaining_dirty,
    })
    .expect("save batch result should encode"))
}

fn decode<T: serde::de::DeserializeOwned>(payload: Value) -> Result<T, CoreError> {
    serde_json::from_value(payload).map_err(|error| {
        invalid("Invalid document save batch request").with_details(error.to_string())
    })
}

fn validate_documents(documents: &[BatchDocument]) -> Result<(), CoreError> {
    if documents.len() > MAX_SAVE_BATCH_DOCUMENTS {
        return Err(invalid("Save batch has too many documents"));
    }
    let mut seen = HashSet::new();
    for document in documents {
        if document.id.is_empty() || !seen.insert(document.id.as_str()) {
            return Err(invalid("Save batch documents need unique identities"));
        }
    }
    Ok(())
}

fn invalid(message: &str) -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, message)
}
