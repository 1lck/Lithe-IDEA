//! Plans how a loaded Git history window survives a refresh.
//!
//! A metadata change reloads the history while the user may be deep in it. The
//! window must keep its loaded depth, absorb commits that appeared at the head
//! without evicting its old tail, and keep the selection, focus, and range
//! anchor when those commits are still loaded. Hosts own the commits, cursors,
//! and pixel scroll anchors; they send commit identities and apply the plan.

use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::{HashMap, HashSet};

/// Largest window either Git Log keeps; matches the graph context bound.
pub(crate) const MAX_WINDOW_COMMITS: usize = 5_000;
/// Upper bound for identities in one request (a window plus one extension).
const MAX_IDENTITIES: usize = 2 * MAX_WINDOW_COMMITS;

#[derive(Debug, Deserialize)]
#[serde(
    tag = "operation",
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
enum Request {
    /// Size of the first page a refresh reads.
    RefreshPlan {
        /// Commits in the window before the refresh; `0` for a fresh history.
        loaded_count: usize,
        /// The host's normal page size.
        page_size: usize,
        /// Keep the loaded depth (watcher refresh or retry) instead of resetting.
        preserve_loaded: bool,
    },
    /// Whether the refreshed first page must be extended to keep the old tail.
    ExtendPlan {
        /// Window before the refresh, in display order.
        previous: Vec<String>,
        /// Refreshed first page, in display order.
        page: Vec<String>,
        /// The refreshed page has a continuation cursor.
        can_continue: bool,
    },
    /// Appends a continuation page to a window without repeating commits.
    MergePage {
        window: Vec<String>,
        page: Vec<String>,
        /// The continuation reported more history after `page`.
        page_has_more: bool,
    },
    /// Retains the selection after the window changed.
    ReconcileSelection {
        /// Window after the refresh, in display order.
        window: Vec<String>,
        selected: Vec<String>,
        #[serde(default)]
        focused: Option<String>,
        #[serde(default)]
        anchor: Option<String>,
    },
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase", untagged)]
enum Response {
    #[serde(rename_all = "camelCase")]
    RefreshPlan { limit: usize },
    #[serde(rename_all = "camelCase")]
    ExtendPlan {
        /// Commits to read after the refreshed page; `0` keeps the page as is.
        extension_limit: usize,
    },
    #[serde(rename_all = "camelCase")]
    MergePage {
        /// Positions in `page` to append, ascending.
        append: Vec<usize>,
        /// More history may follow; a page that added nothing ends the window.
        has_more: bool,
    },
    #[serde(rename_all = "camelCase")]
    ReconcileSelection {
        /// Retained selection in window order.
        selected: Vec<String>,
        focused: Option<String>,
        anchor: Option<String>,
    },
}

fn invalid(message: &str) -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, message)
}

/// Handles `git.historyWindow`.
pub(crate) fn command(payload: Value) -> Result<Value, CoreError> {
    let request: Request = serde_json::from_value(payload).map_err(|error| {
        invalid("Invalid Git history window request").with_details(error.to_string())
    })?;
    let response = match request {
        Request::RefreshPlan {
            loaded_count,
            page_size,
            preserve_loaded,
        } => {
            if page_size == 0 || page_size > MAX_WINDOW_COMMITS {
                return Err(invalid("History page size must be between 1 and 5000"));
            }
            let limit = if preserve_loaded {
                page_size.max(loaded_count)
            } else {
                page_size
            };
            Response::RefreshPlan {
                limit: limit.min(MAX_WINDOW_COMMITS),
            }
        }
        Request::ExtendPlan {
            previous,
            page,
            can_continue,
        } => {
            bounded(&[&previous, &page])?;
            Response::ExtendPlan {
                extension_limit: extension_limit(&previous, &page, can_continue),
            }
        }
        Request::MergePage {
            window,
            page,
            page_has_more,
        } => {
            bounded(&[&window, &page])?;
            let mut loaded = window.iter().map(String::as_str).collect::<HashSet<_>>();
            let room = MAX_WINDOW_COMMITS.saturating_sub(window.len());
            let append = page
                .iter()
                .enumerate()
                .filter(|(_, hash)| loaded.insert(hash.as_str()))
                .map(|(index, _)| index)
                .take(room)
                .collect::<Vec<_>>();
            let has_more = page_has_more
                && !append.is_empty()
                && window.len() + append.len() < MAX_WINDOW_COMMITS;
            Response::MergePage { append, has_more }
        }
        Request::ReconcileSelection {
            window,
            selected,
            focused,
            anchor,
        } => {
            bounded(&[&window, &selected])?;
            reconcile(&window, &selected, focused, anchor)
        }
    };
    Ok(serde_json::to_value(response).expect("history window plan encodes"))
}

fn bounded(lists: &[&Vec<String>]) -> Result<(), CoreError> {
    if lists.iter().map(|list| list.len()).sum::<usize>() > MAX_IDENTITIES {
        return Err(invalid("Too many commit identities for one history window"));
    }
    Ok(())
}

/// New heads displace the old window downwards. Extending by exactly that
/// displacement keeps the old tail loaded without reading another full page on
/// every watcher event.
fn extension_limit(previous: &[String], page: &[String], can_continue: bool) -> usize {
    let Some(tail) = previous.last() else {
        return 0;
    };
    if !can_continue || page.contains(tail) {
        return 0;
    }
    let mut positions = HashMap::new();
    for (index, hash) in previous.iter().enumerate() {
        positions.entry(hash.as_str()).or_insert(index);
    }
    let Some((offset, previous_index)) = page
        .iter()
        .enumerate()
        .find_map(|(offset, hash)| positions.get(hash.as_str()).map(|index| (offset, *index)))
    else {
        // A rewritten history shares nothing with the old window; its depth
        // cannot be inferred, so the refreshed page stands on its own.
        return 0;
    };
    offset
        .saturating_sub(previous_index)
        .min(MAX_WINDOW_COMMITS.saturating_sub(page.len()))
}

/// Keeps loaded identities. An emptied selection falls back to the focused
/// commit, which itself falls back to the first loaded commit, and the range
/// anchor falls back to the focus so Shift-selection extends from a visible row.
fn reconcile(
    window: &[String],
    selected: &[String],
    focused: Option<String>,
    anchor: Option<String>,
) -> Response {
    let loaded = window.iter().map(String::as_str).collect::<HashSet<_>>();
    let is_loaded =
        |hash: &Option<String>| hash.as_deref().is_some_and(|hash| loaded.contains(hash));
    let focused = if is_loaded(&focused) {
        focused
    } else {
        window.first().cloned()
    };
    let wanted = selected.iter().map(String::as_str).collect::<HashSet<_>>();
    let mut retained = window
        .iter()
        .filter(|hash| wanted.contains(hash.as_str()))
        .cloned()
        .collect::<Vec<_>>();
    if retained.is_empty() {
        retained.extend(focused.clone());
    }
    let anchor = if is_loaded(&anchor) {
        anchor
    } else {
        focused.clone()
    };
    Response::ReconcileSelection {
        selected: retained,
        focused,
        anchor,
    }
}

#[cfg(test)]
mod tests {
    use serde_json::{json, Value};

    fn call(payload: Value) -> Value {
        serde_json::from_str(&crate::execute_json(
            &json!({"id":"window", "command":"git.historyWindow", "payload":payload}).to_string(),
        ))
        .unwrap()
    }

    #[test]
    fn shared_fixture_windows_keep_depth_and_selection() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../../shared/fixtures/git/history-window-v1.json"
        ))
        .unwrap();
        for case in fixture["cases"].as_array().unwrap() {
            let response = call(case["request"].clone());
            assert_eq!(response["ok"], true, "{}: {response}", case["name"]);
            assert_eq!(response["data"], case["response"], "{}", case["name"]);
        }
        for case in fixture["invalid"].as_array().unwrap() {
            assert_eq!(
                call(case["request"].clone())["ok"],
                false,
                "{}",
                case["name"]
            );
        }
    }

    #[test]
    fn merge_never_grows_past_the_window_bound() {
        let window = (0..4_999)
            .map(|index| format!("w{index}"))
            .collect::<Vec<_>>();
        let response = call(json!({"operation":"mergePage", "window":window,
            "page":["a","b","c"], "pageHasMore":true}));
        assert_eq!(response["data"], json!({"append":[0], "hasMore":false}));
    }
}
