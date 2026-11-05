//! Bounded editor navigation history shared by every platform editor.
//!
//! Platforms decide which gestures count as a jump and how a location is
//! opened. Core owns the back and forward stacks: departure recording,
//! deduplication, forward-branch truncation, the capacity limit, and skipping
//! entries that equal the current location. The reducer is stateless; the
//! platform keeps the returned state and restores its previous value when
//! opening the returned destination fails.

use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use serde_json::Value;

/// Maximum number of locations retained by each history direction.
pub(crate) const MAX_HISTORY_ENTRIES: usize = 100;

/// One editor location recorded in navigation history.
///
/// Identity is `document`, `line` and `column`; `context` is platform-owned
/// presentation data (pane, scroll offsets, read-only state) that Core carries
/// through unchanged. Coordinates are opaque to Core, so each platform keeps
/// its own base and column unit consistently.
#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Location {
    /// Stable document identity, such as a standardized URL or file path.
    document: String,
    line: u64,
    column: u64,
    #[serde(default, skip_serializing_if = "Value::is_null")]
    context: Value,
}

impl Location {
    fn same_position(&self, other: &Self) -> bool {
        self.document == other.document && self.line == other.line && self.column == other.column
    }
}

/// Back and forward stacks, each ordered oldest first so the next destination
/// is the last element.
#[derive(Debug, Default, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct History {
    back: Vec<Location>,
    forward: Vec<Location>,
}

#[derive(Debug, Deserialize)]
#[serde(
    tag = "type",
    rename_all = "camelCase",
    rename_all_fields = "camelCase",
    deny_unknown_fields
)]
enum Event {
    /// A platform-recognized jump left `departure`. `destination` is optional
    /// because some jumps record before the target is resolved.
    Record {
        departure: Option<Location>,
        destination: Option<Location>,
    },
    /// Move one step back from the live `current` location.
    Back { current: Option<Location> },
    /// Move one step forward from the live `current` location.
    Forward { current: Option<Location> },
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Request {
    state: History,
    event: Event,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct Response {
    state: History,
    /// Location to open for `back` and `forward`; null when nothing moved.
    destination: Option<Location>,
}

/// Reduces one navigation history event (`editor.navigationHistory.reduce`).
///
/// Returns `invalidRequest` for malformed payloads or empty document
/// identities. Oversized stacks keep their newest entries.
pub(crate) fn reduce_command(payload: Value) -> Result<Value, CoreError> {
    let request: Request = serde_json::from_value(payload).map_err(|error| {
        CoreError::new(
            ErrorCode::InvalidRequest,
            "Invalid navigation history request",
        )
        .with_details(error.to_string())
    })?;
    let response = reduce(request)?;
    Ok(serde_json::to_value(response).expect("navigation history response should encode"))
}

fn reduce(request: Request) -> Result<Response, CoreError> {
    let Request { mut state, event } = request;
    validate(&state, &event)?;
    trim(&mut state.back);
    trim(&mut state.forward);
    let destination = match event {
        Event::Record {
            departure,
            destination,
        } => {
            if let Some(departure) = departure {
                let stays = destination
                    .as_ref()
                    .is_some_and(|destination| destination.same_position(&departure));
                if !stays {
                    push(&mut state.back, departure);
                    // A new jump starts a new branch, as in browser history.
                    state.forward.clear();
                }
            }
            None
        }
        Event::Back { current } => step(&mut state.back, &mut state.forward, current),
        Event::Forward { current } => step(&mut state.forward, &mut state.back, current),
    };
    Ok(Response { state, destination })
}

/// Pops the next distinct destination from `source` and records the live
/// location on `opposite`, so caret movement since the last jump survives a
/// return trip.
fn step(
    source: &mut Vec<Location>,
    opposite: &mut Vec<Location>,
    current: Option<Location>,
) -> Option<Location> {
    while let Some(destination) = source.pop() {
        // An entry equal to the live location would be a no-op step; drop it
        // so one key press always moves when any distinct entry remains.
        if current
            .as_ref()
            .is_some_and(|current| current.same_position(&destination))
        {
            continue;
        }
        if let Some(current) = current {
            push(opposite, current);
        }
        return Some(destination);
    }
    None
}

fn push(stack: &mut Vec<Location>, location: Location) {
    match stack.last_mut() {
        // Replace rather than skip so the newest platform context is kept.
        Some(last) if last.same_position(&location) => *last = location,
        _ => stack.push(location),
    }
    trim(stack);
}

fn trim(stack: &mut Vec<Location>) {
    if stack.len() > MAX_HISTORY_ENTRIES {
        stack.drain(..stack.len() - MAX_HISTORY_ENTRIES);
    }
}

fn validate(state: &History, event: &Event) -> Result<(), CoreError> {
    let event_locations: Vec<&Location> = match event {
        Event::Record {
            departure,
            destination,
        } => departure.iter().chain(destination.iter()).collect(),
        Event::Back { current } | Event::Forward { current } => current.iter().collect(),
    };
    let empty = state
        .back
        .iter()
        .chain(state.forward.iter())
        .chain(event_locations)
        .any(|location| location.document.is_empty());
    if empty {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Navigation history locations require a document identity",
        ));
    }
    Ok(())
}
