//! Bounded paging of one debugger variable container (`debug.planVariablePage`,
//! `debug.reduceVariablePage`).
//!
//! A scope or structured variable reports how many named and indexed children
//! it has. Hosts must not ask for all of them at once, and some adapters ignore
//! `start` or report no counts at all. Core owns the page plan and the rules
//! that decide when a container is exhausted; hosts own the page size, the
//! rendered rows, which containers are expanded, and child identity.
//!
//! The state crosses the boundary as JSON on every page. It holds only cursors
//! and page fingerprints, never variable values beyond the page being reduced.

use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

/// The child collection a page reads, matching DAP `variables.filter`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) enum VariablePageFilter {
    Named,
    Indexed,
}

/// Largest page a host may request; DAP adapters serialize every child.
const MAX_PAGE_SIZE: u32 = 1_000;
/// Fingerprints kept per container; a container this long stops paging.
const MAX_LOADED_PAGES: usize = 4_096;

/// One run of children of the same kind: named, indexed, or (when the adapter
/// reported no counts) an unfiltered run whose length is unknown.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct VariablePageSegment {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) filter: Option<VariablePageFilter>,
    pub(crate) next_start: u64,
    /// Adapter-reported child count of this kind; unknown for the unfiltered run.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) total_count: Option<u64>,
}

/// The next `variables` request for a container.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct VariablePageRequest {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) filter: Option<VariablePageFilter>,
    pub(crate) start: u64,
    pub(crate) count: u32,
    /// Children not yet loaded across every remaining kind, when the adapter
    /// reported all counts; hosts show it on their "load more" row.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) remaining_count: Option<u64>,
}

/// Paging cursor of one variable container, owned by Core and echoed by the host.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct VariablePageState {
    pub(crate) variables_reference: i64,
    pub(crate) page_size: u32,
    pub(crate) segments: Vec<VariablePageSegment>,
    /// Digests of pages already merged, to detect adapters that ignore `start`.
    #[serde(default)]
    pub(crate) loaded_pages: Vec<String>,
    /// The request to send next; `None` once the container is exhausted.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) next: Option<VariablePageRequest>,
}

/// Input of `debug.planVariablePage`.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct PlanVariablePageRequest {
    pub(crate) variables_reference: i64,
    #[serde(default)]
    pub(crate) named_variables: i64,
    #[serde(default)]
    pub(crate) indexed_variables: i64,
    pub(crate) page_size: u32,
}

/// The identity of one returned child, used only to fingerprint the page.
#[derive(Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct VariablePageItem {
    pub(crate) name: String,
    #[serde(default)]
    pub(crate) value: String,
    #[serde(default, rename = "type", skip_serializing_if = "Option::is_none")]
    pub(crate) r#type: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub(crate) evaluate_name: Option<String>,
    #[serde(default)]
    pub(crate) variables_reference: i64,
}

/// Input of `debug.reduceVariablePage`.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ReduceVariablePageRequest {
    pub(crate) state: VariablePageState,
    /// The request this page answers; a reply to an older cursor is ignored.
    pub(crate) requested: VariablePageRequest,
    pub(crate) page: Vec<VariablePageItem>,
    /// Children of the page the host did not already show under the same identity.
    pub(crate) new_item_count: u64,
}

/// Output of `debug.reduceVariablePage`.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct ReduceVariablePageResult {
    /// False when the host must drop the page: it answers an older cursor or
    /// repeats a page already shown.
    pub(crate) accept: bool,
    pub(crate) state: VariablePageState,
}

/// Plans the first page of a container from its adapter-reported counts.
///
/// Named children page before indexed ones. Negative counts mean "unknown" in
/// practice and are treated as zero; with neither count the container pages
/// unfiltered until a short or empty page.
pub(crate) fn plan_variable_page(
    request: PlanVariablePageRequest,
) -> Result<VariablePageState, CoreError> {
    validate_page_size(request.page_size)?;
    if request.variables_reference <= 0 {
        return Err(invalid(
            "A variable page needs a positive variablesReference.",
        ));
    }
    let mut segments = Vec::new();
    for (filter, count) in [
        (VariablePageFilter::Named, request.named_variables),
        (VariablePageFilter::Indexed, request.indexed_variables),
    ] {
        if count > 0 {
            segments.push(VariablePageSegment {
                filter: Some(filter),
                next_start: 0,
                total_count: Some(count as u64),
            });
        }
    }
    if segments.is_empty() {
        segments.push(VariablePageSegment {
            filter: None,
            next_start: 0,
            total_count: None,
        });
    }
    let mut state = VariablePageState {
        variables_reference: request.variables_reference,
        page_size: request.page_size,
        segments,
        loaded_pages: Vec::new(),
        next: None,
    };
    state.next = next_request(&state);
    Ok(state)
}

/// Merges one returned page into the cursor.
///
/// A container stops paging when the adapter returns more than was asked for,
/// repeats a page, returns only children the host already shows, reaches the
/// reported count, or (without a count) returns a short or empty page.
pub(crate) fn reduce_variable_page(
    request: ReduceVariablePageRequest,
) -> Result<ReduceVariablePageResult, CoreError> {
    let ReduceVariablePageRequest {
        mut state,
        requested,
        page,
        new_item_count,
    } = request;
    validate_page_size(state.page_size)?;
    if new_item_count > page.len() as u64 {
        return Err(invalid("newItemCount exceeds the page length."));
    }
    let current = state.next.clone();
    let answers_current = current.as_ref().is_some_and(|next| {
        next.filter == requested.filter
            && next.start == requested.start
            && next.count == requested.count
    });
    if !answers_current {
        return Ok(ReduceVariablePageResult {
            accept: false,
            state,
        });
    }
    if !page.is_empty() {
        let fingerprint = page_fingerprint(&page);
        if state.loaded_pages.contains(&fingerprint) {
            // The adapter ignored `start` and sent the same children again.
            state.segments.clear();
            state.next = None;
            return Ok(ReduceVariablePageResult {
                accept: false,
                state,
            });
        }
        state.loaded_pages.push(fingerprint);
    }
    let returned = page.len() as u64;
    if returned > u64::from(requested.count)
        || (returned > 0 && new_item_count == 0)
        || state.loaded_pages.len() >= MAX_LOADED_PAGES
    {
        state.segments.clear();
    } else if let Some(mut segment) = (!state.segments.is_empty()).then(|| state.segments.remove(0))
    {
        segment.next_start = requested.start.saturating_add(returned);
        let reached_total = segment
            .total_count
            .is_some_and(|total| segment.next_start >= total);
        let unknown_length_continues = returned == u64::from(requested.count);
        let continues = returned > 0
            && !reached_total
            && (segment.total_count.is_some() || unknown_length_continues);
        if continues {
            state.segments.insert(0, segment);
        }
    }
    state.next = next_request(&state);
    Ok(ReduceVariablePageResult {
        accept: true,
        state,
    })
}

fn next_request(state: &VariablePageState) -> Option<VariablePageRequest> {
    let segment = state.segments.first()?;
    let remaining_in = |segment: &VariablePageSegment| {
        segment
            .total_count
            .map(|total| total.saturating_sub(segment.next_start))
    };
    let count = remaining_in(segment).map_or(u64::from(state.page_size), |remaining| {
        remaining.min(u64::from(state.page_size))
    });
    let remaining_count = state
        .segments
        .iter()
        .map(remaining_in)
        .try_fold(0u64, |sum, remaining| {
            remaining.map(|value| sum.saturating_add(value))
        });
    (count > 0).then(|| VariablePageRequest {
        filter: segment.filter,
        start: segment.next_start,
        count: count as u32,
        remaining_count,
    })
}

/// Stable digest of the identity fields of a page, independent of the host.
fn page_fingerprint(page: &[VariablePageItem]) -> String {
    let encoded = serde_json::to_vec(page).expect("Variable page identities encode");
    let digest = Sha256::digest(encoded);
    digest[..16]
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

fn validate_page_size(page_size: u32) -> Result<(), CoreError> {
    if page_size == 0 || page_size > MAX_PAGE_SIZE {
        return Err(invalid(
            "The variable page size must be between 1 and 1000.",
        ));
    }
    Ok(())
}

fn invalid(message: &str) -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, message)
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::{json, Value};

    fn fixture() -> Value {
        serde_json::from_str(include_str!(
            "../../../../shared/fixtures/debug/variable-page-plan-v1.json"
        ))
        .unwrap()
    }

    // Each scenario replays the same plan/reduce sequence both hosts run, so a
    // change in the stop rules shows up in the shared fixture first.
    #[test]
    fn variable_page_plan_matches_the_shared_fixture() {
        let fixture = fixture();
        for scenario in fixture["scenarios"].as_array().unwrap() {
            let name = scenario["name"].as_str().unwrap();
            let mut state =
                plan_variable_page(serde_json::from_value(scenario["plan"].clone()).unwrap())
                    .unwrap();
            assert_eq!(
                serde_json::to_value(&state.next).unwrap(),
                scenario["firstRequest"],
                "{name}: first request"
            );
            for (index, step) in scenario["pages"].as_array().unwrap().iter().enumerate() {
                let requested = state.next.clone().unwrap_or(VariablePageRequest {
                    filter: None,
                    start: 0,
                    count: state.page_size,
                    remaining_count: None,
                });
                let result = reduce_variable_page(ReduceVariablePageRequest {
                    state,
                    requested,
                    page: serde_json::from_value(step["page"].clone()).unwrap(),
                    new_item_count: step["newItemCount"].as_u64().unwrap(),
                })
                .unwrap();
                assert_eq!(
                    json!(result.accept),
                    step["accept"],
                    "{name}: page {index} accept"
                );
                assert_eq!(
                    serde_json::to_value(&result.state.next).unwrap(),
                    step["next"],
                    "{name}: page {index} next"
                );
                state = result.state;
            }
        }
    }

    #[test]
    fn a_reply_to_an_older_cursor_is_ignored() {
        let state = plan_variable_page(PlanVariablePageRequest {
            variables_reference: 7,
            named_variables: 0,
            indexed_variables: 250,
            page_size: 100,
        })
        .unwrap();
        let result = reduce_variable_page(ReduceVariablePageRequest {
            state: state.clone(),
            requested: VariablePageRequest {
                filter: Some(VariablePageFilter::Indexed),
                start: 100,
                count: 100,
                remaining_count: None,
            },
            page: vec![],
            new_item_count: 0,
        })
        .unwrap();
        assert!(!result.accept);
        assert_eq!(result.state, state);
    }

    #[test]
    fn invalid_plans_are_rejected() {
        for (reference, page_size) in [(0, 100), (3, 0), (3, MAX_PAGE_SIZE + 1)] {
            assert!(plan_variable_page(PlanVariablePageRequest {
                variables_reference: reference,
                named_variables: 1,
                indexed_variables: 0,
                page_size,
            })
            .is_err());
        }
    }
}
