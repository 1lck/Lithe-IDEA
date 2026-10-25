//! The VCS-neutral model: capability IDs, file statuses, revisions, and the
//! validation that turns a plugin provider's reply into a result both hosts
//! can render without trusting the provider.
//!
//! Replies are untrusted input. A value outside the contract fails the reply
//! with `plugin.vcs.invalidOutput`; optional data Core does not know (a flag,
//! a field) is dropped, so a newer provider can add it within version 1.
//! Lists the host renders as sets are sorted here, and every list is capped,
//! so both hosts show the same result for the same reply.

use crate::plugins::declarative::{PluginRejection, Validation};
use serde_json::{json, Map, Value};
use std::collections::{BTreeMap, BTreeSet};

/// Error code of every reply that fails validation or exceeds a limit.
pub(crate) const INVALID_OUTPUT: &str = "plugin.vcs.invalidOutput";

/// Capability IDs of protocol version 1. `true` marks the capabilities
/// every provider must support; a provider without one of them is not used.
pub(crate) const CAPABILITIES: &[(&str, bool)] = &[
    ("annotate", false),
    ("baseContent", true),
    ("checkin", true),
    ("cleanup", false),
    ("conflicts", false),
    ("fileHistory", false),
    ("fileOperations", false),
    ("history", false),
    ("push", false),
    ("rollback", true),
    ("staging", false),
    ("status", true),
    ("update", false),
];

/// Version of each capability this Core build understands.
const CAPABILITY_VERSION: u64 = 1;

/// A snapshot keeps at most this many changes and is then marked truncated.
pub(crate) const MAX_CHANGES: usize = 100_000;
/// Largest base-revision content, in UTF-8 bytes, a reply may carry.
pub(crate) const MAX_BASE_CONTENT_BYTES: usize = 32 * 1024 * 1024;
/// Most entries one history page may return; the request limit is lower.
pub(crate) const MAX_HISTORY_PAGE: usize = 500;
/// Most changed paths one history entry may list.
const MAX_ENTRY_CHANGES: usize = 10_000;
/// Most lines an annotation may cover.
pub(crate) const MAX_ANNOTATED_LINES: usize = 500_000;
/// Most distinct revisions one annotation may reference.
const MAX_ANNOTATION_REVISIONS: usize = 100_000;
/// Longest revision ID, opaque cursor, branch, or author, in characters.
const MAX_SHORT_TEXT: usize = 256;
/// Longest revision display text, in characters.
const MAX_REVISION_DISPLAY: usize = 64;
/// Longest commit message, in UTF-8 bytes.
pub(crate) const MAX_MESSAGE_BYTES: usize = 1024 * 1024;
/// Longest remote location after sanitizing, in characters.
const MAX_LOCATION: usize = 2048;
/// Longest root-relative path, in UTF-8 bytes.
const MAX_PATH_BYTES: usize = 4096;

/// File status values of version 1. A reply with any other value fails.
const STATUSES: &[&str] = &[
    "added",
    "conflicted",
    "copied",
    "deleted",
    "ignored",
    "missing",
    "modified",
    "renamed",
    "replaced",
    "switched",
    "typeChanged",
    "unversioned",
];

/// Statuses whose change names the path it came from.
const STATUSES_WITH_ORIGIN: &[&str] = &["copied", "renamed"];

/// Refinements of a status. Unknown flags are dropped, not rejected.
const FLAGS: &[&str] = &[
    "external",
    "locked",
    "lockedByOther",
    "propertiesModified",
    "submodule",
    "treeConflict",
];

/// Staged state of a change; only providers with `staging` report it.
const STAGING: &[&str] = &["partial", "staged", "unstaged"];

/// How a host presents a revision ID; never used to order revisions.
const REVISION_KINDS: &[&str] = &["hash", "number", "opaque"];

/// Capabilities a provider negotiated, by ID, with their versions.
pub(crate) type Capabilities = BTreeMap<String, u64>;

fn invalid_output(message: impl Into<String>) -> PluginRejection {
    PluginRejection::new(INVALID_OUTPUT, message)
}

/// Whether `id` is a capability of protocol version 1.
pub(crate) fn is_capability(id: &str) -> bool {
    CAPABILITIES.iter().any(|(known, _)| *known == id)
}

/// The capabilities of a provider's `initialize` answer that this build
/// understands, or `None` when a required one is missing or the value is
/// not an object. Unknown IDs and versions are dropped: a newer provider may
/// offer more, and the host then hides only what Core cannot validate.
pub(crate) fn negotiated_capabilities(value: &Value) -> Option<Capabilities> {
    let offered = value.as_object()?;
    let capabilities: Capabilities = offered
        .iter()
        .filter(|(id, version)| is_capability(id) && version.as_u64() == Some(CAPABILITY_VERSION))
        .map(|(id, _)| (id.clone(), CAPABILITY_VERSION))
        .collect();
    CAPABILITIES
        .iter()
        .filter(|(_, required)| *required)
        .all(|(id, _)| capabilities.contains_key(*id))
        .then_some(capabilities)
}

/// Whether a stable VCS ID is well formed: a lowercase letter, then up to
/// 31 lowercase letters, digits, or hyphens (`git`, `svn`, `hg`).
pub(crate) fn is_vcs_id(value: &str) -> bool {
    let mut characters = value.chars();
    characters
        .next()
        .is_some_and(|first| first.is_ascii_lowercase())
        && value.len() <= 32
        && characters.all(|character| {
            character.is_ascii_lowercase() || character.is_ascii_digit() || character == '-'
        })
}

/// Whether `value` is a path inside a root: relative, `/`-separated, and
/// without empty, `.`, or `..` segments that could leave or alias the root.
pub(crate) fn is_root_relative(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= MAX_PATH_BYTES
        && !value.starts_with('/')
        && !value.contains('\\')
        && !value.chars().any(char::is_control)
        && value
            .split('/')
            .all(|segment| !segment.is_empty() && segment != "." && segment != "..")
        // A drive prefix would make the path absolute on Windows.
        && !value.split('/').next().is_some_and(|first| first.ends_with(':'))
}

/// Removes user info, query, and fragment from a remote location, so a URL
/// that carries credentials never leaves Core. Locations without a scheme
/// (a local repository path) are kept apart from the query and fragment.
pub(crate) fn sanitize_location(value: &str) -> Option<String> {
    let value = value.split(['?', '#']).next().unwrap_or_default();
    let sanitized = match value.split_once("://") {
        Some((scheme, rest)) => {
            let (authority, path) = rest
                .find('/')
                .map_or((rest, ""), |index| rest.split_at(index));
            let host = authority
                .rsplit_once('@')
                .map_or(authority, |(_, host)| host);
            format!("{scheme}://{host}{path}")
        }
        None => value.to_string(),
    };
    (!sanitized.is_empty()
        && sanitized.chars().count() <= MAX_LOCATION
        && !sanitized.chars().any(char::is_control))
    .then_some(sanitized)
}

fn object<'a>(value: &'a Value, what: &str) -> Validation<&'a Map<String, Value>> {
    value
        .as_object()
        .ok_or_else(|| invalid_output(format!("The {what} must be an object.")))
}

fn short_text(value: &str, limit: usize) -> bool {
    !value.is_empty() && value.chars().count() <= limit && !value.chars().any(char::is_control)
}

/// An optional string field: absent and `null` are the same, anything but a
/// short single-line string fails.
fn optional_text(
    members: &Map<String, Value>,
    key: &str,
    limit: usize,
    what: &str,
) -> Validation<Option<String>> {
    match members.get(key) {
        None | Some(Value::Null) => Ok(None),
        Some(Value::String(text)) if short_text(text, limit) => Ok(Some(text.clone())),
        Some(_) => Err(invalid_output(format!(
            "The {what} {key} must be a single-line string of at most {limit} characters."
        ))),
    }
}

fn root_path(value: Option<&Value>, what: &str) -> Validation<String> {
    match value {
        Some(Value::String(path)) if is_root_relative(path) => Ok(path.clone()),
        _ => Err(invalid_output(format!(
            "The {what} must be a path inside the root."
        ))),
    }
}

/// A revision as `{id, display, kind}`. `display` falls back to the ID.
pub(crate) fn revision(value: &Value) -> Validation<Value> {
    let members = object(value, "revision")?;
    let id = match members.get("id") {
        Some(Value::String(id)) if short_text(id, MAX_SHORT_TEXT) => id.clone(),
        _ => {
            return Err(invalid_output(
                "A revision ID must be a single-line string of at most 256 characters.",
            ))
        }
    };
    let display = optional_text(members, "display", MAX_REVISION_DISPLAY, "revision")?
        .unwrap_or_else(|| id.chars().take(MAX_REVISION_DISPLAY).collect());
    let kind = match members.get("kind") {
        None | Some(Value::Null) => "opaque",
        Some(Value::String(kind)) if REVISION_KINDS.contains(&kind.as_str()) => kind.as_str(),
        Some(_) => {
            return Err(invalid_output(
                "A revision kind must be hash, number, or opaque.",
            ))
        }
    };
    Ok(json!({ "id": id, "display": display, "kind": kind }))
}

fn optional_revision(value: Option<&Value>) -> Validation<Value> {
    match value {
        None | Some(Value::Null) => Ok(Value::Null),
        Some(value) => revision(value),
    }
}

/// One change of a status snapshot or a history entry.
fn change(value: &Value, staging: bool) -> Validation<Value> {
    let members = object(value, "change")?;
    let path = root_path(members.get("path"), "change path")?;
    let status = match members.get("status") {
        Some(Value::String(status)) if STATUSES.contains(&status.as_str()) => status.clone(),
        Some(Value::String(status)) => {
            return Err(invalid_output(format!(
                "The file status {status} is not part of the contract."
            )))
        }
        _ => return Err(invalid_output("A change needs a status.")),
    };
    let old_path = match members.get("oldPath") {
        None | Some(Value::Null) => Value::Null,
        // Only a copy or rename names where the file came from; anything
        // else would make the host show a move that never happened.
        Some(value) if STATUSES_WITH_ORIGIN.contains(&status.as_str()) => {
            json!(root_path(Some(value), "original path")?)
        }
        Some(_) => {
            return Err(invalid_output(format!(
                "A {status} change cannot name an original path."
            )))
        }
    };
    let flags: BTreeSet<&str> = match members.get("flags") {
        None | Some(Value::Null) => BTreeSet::new(),
        Some(Value::Array(flags)) => flags
            .iter()
            .filter_map(Value::as_str)
            .filter(|flag| FLAGS.contains(flag))
            .collect(),
        Some(_) => return Err(invalid_output("Change flags must be an array.")),
    };
    let mut normalized = json!({
        "path": path,
        "oldPath": old_path,
        "status": status,
        "flags": flags,
    });
    match (members.get("staging"), staging) {
        (None | Some(Value::Null), false) => {}
        (Some(Value::String(state)), true) if STAGING.contains(&state.as_str()) => {
            normalized["staging"] = json!(state);
        }
        (_, true) => return Err(invalid_output(
            "A provider with staging must report staged, unstaged, or partial for every change.",
        )),
        (Some(_), false) => {
            return Err(invalid_output(
                "A change carries staging although the provider did not negotiate staging.",
            ))
        }
    }
    Ok(normalized)
}

/// Validated changes sorted by path; duplicate paths fail the reply.
fn changes(value: Option<&Value>, staging: bool, limit: usize) -> Validation<(Vec<Value>, bool)> {
    let items = match value {
        Some(Value::Array(items)) => items,
        None | Some(Value::Null) => return Ok((Vec::new(), false)),
        Some(_) => return Err(invalid_output("Changes must be an array.")),
    };
    let mut by_path = BTreeMap::new();
    for item in items {
        let change = change(item, staging)?;
        let path = change["path"].as_str().unwrap_or_default().to_string();
        if by_path.insert(path.clone(), change).is_some() {
            return Err(invalid_output(format!(
                "The path {path} is reported more than once."
            )));
        }
    }
    let truncated = by_path.len() > limit;
    Ok((by_path.into_values().take(limit).collect(), truncated))
}

fn boolean(members: &Map<String, Value>, key: &str) -> Validation<bool> {
    match members.get(key) {
        None | Some(Value::Null) => Ok(false),
        Some(Value::Bool(value)) => Ok(*value),
        Some(_) => Err(invalid_output(format!("{key} must be a boolean."))),
    }
}

/// `lithe/vcs/status`: `{head, changes, truncated}` with changes sorted by
/// path and capped at [`MAX_CHANGES`].
pub(crate) fn decode_status(reply: &Value, capabilities: &Capabilities) -> Validation<Value> {
    let members = object(reply, "status reply")?;
    let head = match members.get("head") {
        None | Some(Value::Null) => json!({ "revision": null, "branch": null, "location": null }),
        Some(head) => {
            let head = object(head, "head")?;
            let location = optional_text(head, "location", MAX_LOCATION, "head")?
                .map(|location| {
                    sanitize_location(&location)
                        .ok_or_else(|| invalid_output("The head location is not a location."))
                })
                .transpose()?;
            json!({
                "revision": optional_revision(head.get("revision"))?,
                "branch": optional_text(head, "branch", MAX_SHORT_TEXT, "head")?,
                "location": location,
            })
        }
    };
    let (changes, capped) = changes(
        members.get("changes"),
        capabilities.contains_key("staging"),
        MAX_CHANGES,
    )?;
    Ok(json!({
        "head": head,
        "changes": changes,
        // A provider that stopped early says so; Core adds its own cap.
        "truncated": capped || boolean(members, "truncated")?,
    }))
}

/// `lithe/vcs/baseContent`: the file's text at its base revision, `null`
/// content when it has none (an added file), and `binary` when the host
/// must not diff it as text.
pub(crate) fn decode_base_content(reply: &Value) -> Validation<Value> {
    let members = object(reply, "base content reply")?;
    let binary = boolean(members, "binary")?;
    let content = match members.get("content") {
        None | Some(Value::Null) => Value::Null,
        Some(Value::String(_)) if binary => {
            return Err(invalid_output(
                "Binary base content is reported without text.",
            ))
        }
        Some(Value::String(text)) if text.len() <= MAX_BASE_CONTENT_BYTES => json!(text),
        Some(Value::String(_)) => return Err(invalid_output("The base content exceeds 32 MiB.")),
        Some(_) => return Err(invalid_output("content must be a string or null.")),
    };
    Ok(json!({ "content": content, "binary": binary }))
}

fn message(members: &Map<String, Value>) -> Validation<String> {
    match members.get("message") {
        None | Some(Value::Null) => Ok(String::new()),
        Some(Value::String(text)) if text.len() <= MAX_MESSAGE_BYTES && !text.contains('\0') => {
            Ok(text.clone())
        }
        Some(_) => Err(invalid_output(
            "A message must be a string of at most 1 MiB without NUL.",
        )),
    }
}

/// Author, date, and message of one revision. Dates are passed through as
/// the provider wrote them (RFC 3339); hosts format but never compare them.
fn revision_details(members: &Map<String, Value>) -> Validation<Value> {
    Ok(json!({
        "revision": revision(members.get("revision").unwrap_or(&Value::Null))?,
        "author": optional_text(members, "author", MAX_SHORT_TEXT, "revision")?,
        "date": optional_text(members, "date", MAX_SHORT_TEXT, "revision")?,
        "message": message(members)?,
    }))
}

/// `lithe/vcs/history` and `lithe/vcs/fileHistory`: one page of entries in
/// the provider's order (newest first), and the cursor of the next page.
pub(crate) fn decode_history(reply: &Value, limit: usize) -> Validation<Value> {
    let members = object(reply, "history reply")?;
    let items = match members.get("entries") {
        Some(Value::Array(items)) => items,
        _ => return Err(invalid_output("A history reply needs an entries array.")),
    };
    // The provider received the limit; more entries means it ignored it.
    if items.len() > limit.min(MAX_HISTORY_PAGE) {
        return Err(invalid_output(format!(
            "The history page has more than the {limit} requested entries."
        )));
    }
    let mut entries = Vec::with_capacity(items.len());
    for item in items {
        let entry = object(item, "history entry")?;
        let mut normalized = revision_details(entry)?;
        let (changes, truncated) = changes(entry.get("changes"), false, MAX_ENTRY_CHANGES)?;
        normalized["changes"] = json!(changes);
        normalized["changesTruncated"] = json!(truncated || boolean(entry, "changesTruncated")?);
        entries.push(normalized);
    }
    let next_cursor = optional_text(members, "nextCursor", MAX_SHORT_TEXT, "history")?;
    Ok(json!({ "entries": entries, "nextCursor": next_cursor }))
}

/// `lithe/vcs/annotate`: the revisions a file's lines come from, and per
/// line the ID of one of them, or `null` for a line not yet checked in.
pub(crate) fn decode_annotation(reply: &Value) -> Validation<Value> {
    let members = object(reply, "annotation reply")?;
    let (Some(Value::Array(revisions)), Some(Value::Array(lines))) =
        (members.get("revisions"), members.get("lines"))
    else {
        return Err(invalid_output(
            "An annotation needs revisions and lines arrays.",
        ));
    };
    if revisions.len() > MAX_ANNOTATION_REVISIONS || lines.len() > MAX_ANNOTATED_LINES {
        return Err(invalid_output("The annotation exceeds its size limit."));
    }
    let mut by_id = BTreeMap::new();
    for item in revisions {
        let details = revision_details(object(item, "annotation revision")?)?;
        let id = details["revision"]["id"]
            .as_str()
            .unwrap_or_default()
            .to_string();
        if by_id.insert(id.clone(), details).is_some() {
            return Err(invalid_output(format!(
                "The revision {id} is listed more than once."
            )));
        }
    }
    let mut used = BTreeSet::new();
    let mut normalized_lines = Vec::with_capacity(lines.len());
    for line in lines {
        match line {
            Value::Null => normalized_lines.push(Value::Null),
            Value::String(id) if by_id.contains_key(id) => {
                used.insert(id.clone());
                normalized_lines.push(json!(id));
            }
            _ => {
                return Err(invalid_output(
                    "Every annotated line names a listed revision or null.",
                ))
            }
        }
    }
    // Revisions no line uses would show up in a legend with nothing to point
    // at; sorting by ID keeps the list stable without ordering revisions.
    let revisions: Vec<Value> = by_id
        .into_iter()
        .filter(|(id, _)| used.contains(id))
        .map(|(_, details)| details)
        .collect();
    Ok(json!({ "revisions": revisions, "lines": normalized_lines }))
}

/// `lithe/vcs/checkin`: the new revision, or `null` when the provider
/// cannot name it.
pub(crate) fn decode_checkin(reply: &Value) -> Validation<Value> {
    let members = object(reply, "check-in reply")?;
    Ok(json!({ "revision": optional_revision(members.get("revision"))? }))
}

/// `lithe/vcs/update`: the revision the working copy is at now, and the
/// paths the update left conflicted, sorted.
pub(crate) fn decode_update(reply: &Value) -> Validation<Value> {
    let members = object(reply, "update reply")?;
    let conflicts: BTreeSet<String> = match members.get("conflicts") {
        None | Some(Value::Null) => BTreeSet::new(),
        Some(Value::Array(paths)) => paths
            .iter()
            .map(|path| root_path(Some(path), "conflicted path"))
            .collect::<Validation<_>>()?,
        Some(_) => return Err(invalid_output("conflicts must be an array of paths.")),
    };
    if conflicts.len() > MAX_CHANGES {
        return Err(invalid_output("The update reports too many conflicts."));
    }
    Ok(json!({
        "revision": optional_revision(members.get("revision"))?,
        "conflicts": conflicts,
    }))
}

/// Replies that carry no data. Anything in them is ignored, so a provider
/// may report extra details without breaking an older host.
pub(crate) fn decode_empty(reply: &Value) -> Validation<Value> {
    match reply {
        Value::Null | Value::Object(_) => Ok(json!({})),
        _ => Err(invalid_output("The reply must be an object or null.")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn capabilities(staging: bool) -> Capabilities {
        let mut capabilities: Capabilities = CAPABILITIES
            .iter()
            .filter(|(_, required)| *required)
            .map(|(id, _)| (id.to_string(), 1))
            .collect();
        if staging {
            capabilities.insert("staging".to_string(), 1);
        }
        capabilities
    }

    #[test]
    fn negotiation_keeps_known_version_one_capabilities_and_requires_the_core_set() {
        let negotiated = negotiated_capabilities(&json!({
            "status": 1, "baseContent": 1, "checkin": 1, "rollback": 1,
            "annotate": 2, "futureThing": 1, "update": 1
        }))
        .expect("required set present");
        assert_eq!(
            negotiated.keys().map(String::as_str).collect::<Vec<_>>(),
            ["baseContent", "checkin", "rollback", "status", "update"]
        );
        // A provider without rollback cannot back the generic commit UI.
        assert!(
            negotiated_capabilities(&json!({ "status": 1, "baseContent": 1, "checkin": 1 }))
                .is_none()
        );
        assert!(negotiated_capabilities(&json!(["status"])).is_none());
    }

    #[test]
    fn root_relative_paths_cannot_leave_or_alias_the_root() {
        for valid in ["a.txt", "src/Main.java", ".svnignore", "a b/c"] {
            assert!(is_root_relative(valid), "{valid}");
        }
        for invalid in [
            "",
            "/etc/passwd",
            "../x",
            "a/../b",
            "a//b",
            "./a",
            "a/",
            "a\\b",
            "C:/x",
            "a\u{0}b",
        ] {
            assert!(!is_root_relative(invalid), "{invalid:?}");
        }
    }

    #[test]
    fn locations_lose_credentials_query_and_fragment() {
        assert_eq!(
            sanitize_location("https://user:secret@svn.example.invalid/repo/trunk?p=1#f")
                .as_deref(),
            Some("https://svn.example.invalid/repo/trunk")
        );
        assert_eq!(
            sanitize_location("svn+ssh://me@host.invalid").as_deref(),
            Some("svn+ssh://host.invalid")
        );
        assert_eq!(
            sanitize_location("file:///var/svn/repo").as_deref(),
            Some("file:///var/svn/repo")
        );
        assert_eq!(sanitize_location("?only=query"), None);
    }

    #[test]
    fn status_reply_is_normalized_and_capped() {
        let reply = json!({
            "head": {
                "revision": { "id": "12", "kind": "number" },
                "location": "https://u:p@svn.example.invalid/r",
                "branch": null
            },
            "changes": [
                { "path": "b", "status": "modified", "flags": ["propertiesModified", "locked", "x"] },
                { "path": "a", "oldPath": "old", "status": "renamed" }
            ]
        });
        let snapshot = decode_status(&reply, &capabilities(false)).expect("valid");
        assert_eq!(
            snapshot,
            json!({
                "head": {
                    "revision": { "id": "12", "display": "12", "kind": "number" },
                    "branch": null,
                    "location": "https://svn.example.invalid/r"
                },
                "changes": [
                    { "path": "a", "oldPath": "old", "status": "renamed", "flags": [] },
                    { "path": "b", "oldPath": null, "status": "modified", "flags": ["locked", "propertiesModified"] }
                ],
                "truncated": false
            })
        );
    }

    #[test]
    fn status_reply_rejects_contract_violations() {
        for reply in [
            json!({ "changes": [{ "path": "a", "status": "modified" }, { "path": "a", "status": "added" }] }),
            json!({ "changes": [{ "path": "a", "oldPath": "b", "status": "modified" }] }),
            json!({ "changes": [{ "path": "a", "status": "modified", "flags": "locked" }] }),
            json!({ "changes": "a" }),
            json!({ "head": { "revision": { "id": "" } } }),
            json!({ "head": { "revision": { "id": "1", "kind": "date" } } }),
        ] {
            let error = decode_status(&reply, &capabilities(false)).expect_err("rejected");
            assert_eq!(error.code, INVALID_OUTPUT, "{reply}");
        }
        // With staging negotiated every change must say how it is staged.
        let error = decode_status(
            &json!({ "changes": [{ "path": "a", "status": "modified" }] }),
            &capabilities(true),
        )
        .expect_err("missing staging");
        assert_eq!(error.code, INVALID_OUTPUT);
    }

    #[test]
    fn oversized_snapshots_are_marked_truncated() {
        let changes: Vec<Value> = (0..=MAX_CHANGES)
            .map(|index| json!({ "path": format!("f{index:06}"), "status": "unversioned" }))
            .collect();
        let snapshot =
            decode_status(&json!({ "changes": changes }), &capabilities(false)).expect("valid");
        assert_eq!(
            snapshot["changes"].as_array().map(Vec::len),
            Some(MAX_CHANGES)
        );
        assert_eq!(snapshot["truncated"], json!(true));
    }

    #[test]
    fn base_content_distinguishes_text_binary_and_absent() {
        assert_eq!(
            decode_base_content(&json!({ "content": "x\n" })).expect("text"),
            json!({ "content": "x\n", "binary": false })
        );
        assert_eq!(
            decode_base_content(&json!({ "content": null, "binary": true })).expect("binary"),
            json!({ "content": null, "binary": true })
        );
        assert!(decode_base_content(&json!({ "content": "x", "binary": true })).is_err());
    }

    #[test]
    fn history_page_keeps_provider_order_and_enforces_the_limit() {
        let reply = json!({
            "entries": [
                { "revision": { "id": "9", "kind": "number" }, "author": "ann", "date": "2026-10-22T08:00:00Z", "message": "second",
                  "changes": [{ "path": "b", "status": "modified" }, { "path": "a", "status": "added" }] },
                { "revision": { "id": "3", "kind": "number" }, "message": "first" }
            ],
            "nextCursor": "3"
        });
        let page = decode_history(&reply, 2).expect("valid");
        assert_eq!(page["entries"][0]["revision"]["id"], "9");
        assert_eq!(page["entries"][0]["changes"][0]["path"], "a");
        assert_eq!(page["entries"][1]["author"], Value::Null);
        assert_eq!(page["nextCursor"], "3");
        assert!(decode_history(&reply, 1).is_err());
    }

    #[test]
    fn annotation_lines_must_reference_listed_revisions() {
        let reply = json!({
            "revisions": [
                { "revision": { "id": "2" }, "author": "bo" },
                { "revision": { "id": "1" }, "author": "al" },
                { "revision": { "id": "7" } }
            ],
            "lines": ["1", "2", null, "1"]
        });
        let annotation = decode_annotation(&reply).expect("valid");
        assert_eq!(annotation["lines"], json!(["1", "2", null, "1"]));
        // Unused revision 7 is dropped; the rest are ordered by ID.
        assert_eq!(annotation["revisions"][0]["revision"]["id"], "1");
        assert_eq!(annotation["revisions"].as_array().map(Vec::len), Some(2));
        assert!(decode_annotation(&json!({ "revisions": [], "lines": ["1"] })).is_err());
    }

    #[test]
    fn update_reports_sorted_conflicts_inside_the_root() {
        assert_eq!(
            decode_update(&json!({ "revision": { "id": "5" }, "conflicts": ["b", "a", "b"] }))
                .expect("valid"),
            json!({ "revision": { "id": "5", "display": "5", "kind": "opaque" }, "conflicts": ["a", "b"] })
        );
        assert!(decode_update(&json!({ "conflicts": ["/abs"] })).is_err());
    }
}
