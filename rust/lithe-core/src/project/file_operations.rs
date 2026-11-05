//! Copy names for Duplicate and Paste in the Project view.
//!
//! macOS and Windows both create the copy themselves (a native, no-overwrite create), but
//! neither decides what the copy is called. A host sends the names it has already seen
//! to exist in the destination directory and Core answers with names that are free
//! against those facts: `foo.txt` becomes `foo copy.txt`, then `foo copy 2.txt`. A file
//! name is split at its last dot, a directory name never is, and a leading dot
//! (`.gitignore`) is not an extension.
//!
//! The facts come from the platform, so the plan can be stale by the time the copy is
//! created. Hosts therefore loop: plan, create without replacing, and when the create
//! reports that the name now exists, add that name to `existing` and plan again. Core
//! never touches the file system.

use crate::protocol::{CoreError, ErrorCode};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::HashSet;

/// Upper bound for the existing names one request may carry; larger requests are rejected.
const MAX_EXISTING_NAMES: usize = 100_000;
/// Upper bound for the items one paste may carry.
const MAX_PASTE_ITEMS: usize = 10_000;
/// Longest accepted file name in UTF-8 bytes.
const MAX_NAME_BYTES: usize = 4_096;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// One item being copied; `name` is the last path component of its source.
struct CopyItem {
    name: String,
    is_directory: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// Duplicate one item next to its source.
struct PlanDuplicateRequest {
    name: String,
    is_directory: bool,
    /// Names the host has observed in the destination directory.
    #[serde(default)]
    existing: Vec<String>,
    /// Whether the destination volume treats names that differ only by case as equal.
    #[serde(default)]
    case_insensitive: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// Paste several items into one destination directory.
struct PlanPasteRequest {
    items: Vec<CopyItem>,
    #[serde(default)]
    existing: Vec<String>,
    #[serde(default)]
    case_insensitive: bool,
}

/// Plans the name of a duplicate (`workspace.planDuplicate`).
///
/// Returns `{ name }`. The name always carries the copy suffix, because a duplicate lives
/// next to its source.
pub(crate) fn plan_duplicate_command(payload: Value) -> Result<Value, CoreError> {
    let request: PlanDuplicateRequest = serde_json::from_value(payload).map_err(invalid)?;
    let item = CopyItem {
        name: request.name,
        is_directory: request.is_directory,
    };
    let names = plan(
        std::slice::from_ref(&item),
        &request.existing,
        request.case_insensitive,
        true,
    )?;
    Ok(json!({ "name": names[0] }))
}

/// Plans the destination names of a paste (`workspace.planPaste`).
///
/// Returns `{ names }`, one per item in request order. An item keeps its own name when
/// that name is free; otherwise it receives the copy suffix. Items planned earlier in the
/// same paste count as taken, so two sources with the same name never collide.
pub(crate) fn plan_paste_command(payload: Value) -> Result<Value, CoreError> {
    let request: PlanPasteRequest = serde_json::from_value(payload).map_err(invalid)?;
    if request.items.len() > MAX_PASTE_ITEMS {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Too many items to paste",
        ));
    }
    let names = plan(
        &request.items,
        &request.existing,
        request.case_insensitive,
        false,
    )?;
    Ok(json!({ "names": names }))
}

fn invalid(error: serde_json::Error) -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, "Invalid file copy request")
        .with_details(error.to_string())
}

fn plan(
    items: &[CopyItem],
    existing: &[String],
    case_insensitive: bool,
    always_suffix: bool,
) -> Result<Vec<String>, CoreError> {
    if existing.len() > MAX_EXISTING_NAMES {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Too many existing names",
        ));
    }
    let key = |name: &str| {
        if case_insensitive {
            name.to_lowercase()
        } else {
            name.to_owned()
        }
    };
    let mut taken: HashSet<String> = existing.iter().map(|name| key(name)).collect();
    let mut planned = Vec::with_capacity(items.len());
    for item in items {
        validate_name(&item.name)?;
        let (stem, extension) = split_name(&item.name, item.is_directory);
        let chosen = std::iter::once(0usize)
            .filter(|_| !always_suffix)
            .chain(1..)
            .map(|index| match index {
                0 => item.name.clone(),
                1 => format!("{stem} copy{extension}"),
                _ => format!("{stem} copy {index}{extension}"),
            })
            .find(|candidate| !taken.contains(&key(candidate)))
            .expect("an unbounded sequence has a free name");
        taken.insert(key(&chosen));
        planned.push(chosen);
    }
    Ok(planned)
}

fn validate_name(name: &str) -> Result<(), CoreError> {
    if name.is_empty()
        || name == "."
        || name == ".."
        || name.len() > MAX_NAME_BYTES
        || name.contains(['/', '\\', '\0'])
    {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Invalid file name to copy",
        ));
    }
    Ok(())
}

/// Splits `name` into the part before the copy suffix and the extension (with its dot).
fn split_name(name: &str, is_directory: bool) -> (&str, &str) {
    if is_directory {
        return (name, "");
    }
    match name.rfind('.') {
        Some(dot) if dot > 0 && dot + 1 < name.len() => name.split_at(dot),
        _ => (name, ""),
    }
}
