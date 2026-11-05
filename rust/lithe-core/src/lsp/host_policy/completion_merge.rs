//! Merging completion lists from several feature providers (`lsp.mergeCompletions`).
//!
//! A host may ask a language server, plugin providers, and the lightweight
//! current-file fallback for completions at the same position. Core decides
//! which candidates survive:
//!
//! - Every candidate a single provider returns is kept. Overloads such as
//!   `print(String)` and `print(int)` often share a label and differ only in
//!   detail, signature, or resolve data, so a provider's own list is never
//!   collapsed.
//! - Lists arrive in provider priority order. A lower-priority candidate is
//!   shadowed when a higher-priority provider already offers the same label,
//!   so fallback suggestions never duplicate what a real provider returned.
//!
//! Only labels cross the boundary. The platform keeps the full items and
//! applies the returned indices, which keeps the per-keystroke payload small.

use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashSet;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Request {
    /// Provider results ordered from highest to lowest priority.
    lists: Vec<CompletionLabels>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct CompletionLabels {
    labels: Vec<String>,
    #[serde(default)]
    is_incomplete: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct Response {
    /// For each submitted list, the indices of the candidates to keep, in order.
    keep: Vec<Vec<usize>>,
    /// True when any provider reported an incomplete list.
    is_incomplete: bool,
}

/// Executes `lsp.mergeCompletions`.
pub(crate) fn merge_command(payload: Value) -> Result<Value, CoreError> {
    let request: Request = serde_json::from_value(payload).map_err(|error| {
        CoreError::new(
            ErrorCode::InvalidRequest,
            "Invalid completion merge request",
        )
        .with_details(error.to_string())
    })?;
    Ok(serde_json::to_value(merge(&request)).expect("completion merge response should encode"))
}

fn merge(request: &Request) -> Response {
    let mut offered = HashSet::<&str>::new();
    let mut keep = Vec::with_capacity(request.lists.len());
    for list in &request.lists {
        let kept: Vec<usize> = list
            .labels
            .iter()
            .enumerate()
            .filter(|(_, label)| !offered.contains(label.as_str()))
            .map(|(index, _)| index)
            .collect();
        // Labels join the shadow set only after the whole list is evaluated,
        // so duplicates inside one provider's list are all kept.
        offered.extend(kept.iter().map(|index| list.labels[*index].as_str()));
        keep.push(kept);
    }
    Response {
        keep,
        is_incomplete: request.lists.iter().any(|list| list.is_incomplete),
    }
}
