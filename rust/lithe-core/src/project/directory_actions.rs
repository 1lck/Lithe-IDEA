//! Directory roles, exclusion and rule migration for the Project view.
//!
//! A workspace stores three related preferences keyed by workspace-relative directory:
//! the role of a directory (`marks`), the directories that opt back in to indexing
//! although Git ignores them (`includedDirectories`) and the role a directory had before it
//! was excluded (`previousRoles`). Hosts persist these values in their own preference
//! storage and do not interpret them. Every change goes through Core:
//!
//! - `workspace.reduceDirectoryAction` applies "set role", "exclude" and "cancel
//!   exclusion" to a copy of that state.
//! - `workspace.relocateDirectoryRules` moves the keys of a subtree after a rename or
//!   move, drops them after a delete, or hands them to the state of another workspace
//!   root.
//!
//! Directory keys are compared as paths: with `caseInsensitive` set, keys that differ only
//! by case name the same directory. Stored keys keep the spelling they were written with.
//! The sequence contract is `shared/fixtures/workspace/directory-actions-v1.json`; the
//! request and response shapes are pinned by `directory-rules-v1.json`.

use crate::protocol::{CoreError, ErrorCode};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::BTreeMap;

/// Largest number of keys one request may carry.
const MAX_ENTRIES: usize = 100_000;
const ROLES: [&str; 6] = [
    "plain",
    "sources",
    "resources",
    "excluded",
    "module",
    "package",
];

#[derive(Deserialize, Serialize, Clone, Default, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
/// The persisted rule state of one workspace root.
struct Rules {
    /// Directory role by workspace-relative path; a missing key is a plain directory.
    #[serde(default)]
    marks: BTreeMap<String, String>,
    /// Directories that stay indexed although Git ignores them.
    #[serde(default)]
    included_directories: Vec<String>,
    /// The role to restore when a manual exclusion is canceled.
    #[serde(default)]
    previous_roles: BTreeMap<String, String>,
}

#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
enum Action {
    SetRole { role: String },
    Exclude,
    CancelExclusion,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct ReduceRequest {
    /// Workspace-relative directory; `.` is the workspace root.
    path: String,
    action: Action,
    #[serde(default)]
    case_insensitive: bool,
    rules: Rules,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct RelocateRequest {
    /// Directory that was moved or deleted, relative to the root that owns `rules`.
    source: String,
    /// Where it went, relative to the root that owns `target` (or `rules` without a
    /// target); absent when the directory was deleted.
    #[serde(default)]
    destination: Option<String>,
    #[serde(default)]
    case_insensitive: bool,
    rules: Rules,
    /// Rules of the destination root when the move crosses workspace roots.
    #[serde(default)]
    target: Option<Rules>,
}

/// Applies one directory action (`workspace.reduceDirectoryAction`).
///
/// Returns `{ changed, rules }`, where `rules` is the complete state to persist. `changed` is false when the action has no effect, including canceling an
/// exclusion that a manually excluded ancestor still enforces; the state is then the
/// input. Excluding remembers the replaced role and canceling restores it; changing a role
/// keeps include exceptions; excluding deletes only the directory's own exception.
pub(crate) fn reduce_command(payload: Value) -> Result<Value, CoreError> {
    let request: ReduceRequest = parse(payload)?;
    validate_path(&request.path)?;
    validate_rules(&request.rules)?;
    let ident = Identity(request.case_insensitive);
    let before = request.rules.clone();
    let mut rules = request.rules;
    let path = request.path;
    let same = |key: &String| ident.key(key) == ident.key(&path);
    match request.action {
        Action::CancelExclusion => {
            let path_ident = ident.key(&path);
            let blocked = rules.marks.iter().any(|(key, role)| {
                role == "excluded"
                    && ident.key(key) != path_ident
                    && (key == "." || path_ident.starts_with(&format!("{}/", ident.key(key))))
            });
            if blocked {
                return Ok(response(false, before));
            }
            let current = take_same(&mut rules.marks, &same);
            let previous = take_same(&mut rules.previous_roles, &same);
            let restored = if current.as_deref() == Some("excluded") {
                previous
            } else {
                current
            };
            if let Some(role) = restored {
                rules.marks.insert(path.clone(), role);
            }
            if !rules.included_directories.iter().any(same) {
                rules.included_directories.push(path);
            }
        }
        Action::Exclude => {
            let current = take_same(&mut rules.marks, &same);
            if let Some(role) = current.filter(|role| role != "excluded") {
                rules.previous_roles.retain(|key, _| !same(key));
                rules.previous_roles.insert(path.clone(), role);
            }
            rules.marks.insert(path.clone(), "excluded".into());
            rules.included_directories.retain(|key| !same(key));
        }
        Action::SetRole { role } => {
            if !ROLES.contains(&role.as_str()) || role == "excluded" {
                return Err(CoreError::new(
                    ErrorCode::InvalidRequest,
                    "Directory role is not assignable",
                ));
            }
            take_same(&mut rules.marks, &same);
            rules.marks.insert(path, role);
        }
    }
    let changed = rules != before;
    Ok(response(changed, rules))
}

/// Migrates directory rules after a move or delete (`workspace.relocateDirectoryRules`).
///
/// Returns `{ rules, target }`. Every key at or below `source` is removed from `rules`.
/// With a `destination` the key is rewritten under it, in `target` for a move across
/// workspace roots and in `rules` otherwise; without one the keys are dropped. `target` is
/// absent from the response unless the request had one.
pub(crate) fn relocate_command(payload: Value) -> Result<Value, CoreError> {
    let request: RelocateRequest = parse(payload)?;
    validate_path(&request.source)?;
    if let Some(destination) = &request.destination {
        validate_path(destination)?;
    }
    validate_rules(&request.rules)?;
    if let Some(target) = &request.target {
        validate_rules(target)?;
        if request.destination.is_none() {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "A target root needs a destination",
            ));
        }
    }
    let ident = Identity(request.case_insensitive);
    let source_key = ident.key(&request.source);
    let source_len = request.source.chars().count();
    let under = |key: &str| {
        let key = ident.key(key);
        request.source == "." || key == source_key || key.starts_with(&format!("{source_key}/"))
    };
    let moved_key = |key: &str| -> Option<String> {
        let destination = request.destination.as_deref()?;
        let tail: String = if request.source == "." {
            if key == "." {
                String::new()
            } else {
                format!("/{key}")
            }
        } else {
            key.chars().skip(source_len).collect()
        };
        Some(if destination == "." {
            let trimmed = tail.trim_start_matches('/');
            if trimmed.is_empty() {
                ".".into()
            } else {
                trimmed.into()
            }
        } else {
            format!("{destination}{tail}")
        })
    };
    let mut remaining = request.rules.clone();
    let mut destination_rules = request.target.clone();
    let moved = |remaining: &mut Rules, into: &mut Rules| {
        let marks = std::mem::take(&mut remaining.marks);
        for (key, role) in marks {
            if under(&key) {
                if let Some(moved) = moved_key(&key) {
                    into.marks.insert(moved, role);
                }
            } else {
                remaining.marks.insert(key, role);
            }
        }
        let previous = std::mem::take(&mut remaining.previous_roles);
        for (key, role) in previous {
            if under(&key) {
                if let Some(moved) = moved_key(&key) {
                    into.previous_roles.insert(moved, role);
                }
            } else {
                remaining.previous_roles.insert(key, role);
            }
        }
        let included = std::mem::take(&mut remaining.included_directories);
        for key in included {
            if under(&key) {
                if let Some(moved) = moved_key(&key) {
                    push_unique(&mut into.included_directories, moved, &ident);
                }
            } else {
                remaining.included_directories.push(key);
            }
        }
    };
    match destination_rules.as_mut() {
        Some(target) => moved(&mut remaining, target),
        None => {
            // Same root: moved entries are collected first so a key that lands on
            // another moved key cannot be processed twice.
            let mut collected = Rules::default();
            moved(&mut remaining, &mut collected);
            remaining.marks.extend(collected.marks);
            remaining.previous_roles.extend(collected.previous_roles);
            for key in collected.included_directories {
                push_unique(&mut remaining.included_directories, key, &ident);
            }
        }
    }
    Ok(json!({ "rules": remaining, "target": destination_rules }))
}

struct Identity(bool);

impl Identity {
    fn key(&self, path: &str) -> String {
        if self.0 {
            path.to_lowercase()
        } else {
            path.to_owned()
        }
    }
}

fn push_unique(list: &mut Vec<String>, key: String, ident: &Identity) {
    if !list
        .iter()
        .any(|existing| ident.key(existing) == ident.key(&key))
    {
        list.push(key);
    }
}

/// Removes every entry the predicate matches and returns the value of the exact key
/// when one matched, otherwise of the first match.
fn take_same(
    map: &mut BTreeMap<String, String>,
    same: &impl Fn(&String) -> bool,
) -> Option<String> {
    let keys = map
        .keys()
        .filter(|key| same(key))
        .cloned()
        .collect::<Vec<_>>();
    let mut first = None;
    for key in keys {
        let value = map.remove(&key);
        first = first.or(value);
    }
    first
}

fn response(changed: bool, rules: Rules) -> Value {
    json!({ "changed": changed, "rules": rules })
}

fn parse<T: serde::de::DeserializeOwned>(payload: Value) -> Result<T, CoreError> {
    serde_json::from_value(payload).map_err(|error| {
        CoreError::new(ErrorCode::InvalidRequest, "Invalid directory rules request")
            .with_details(error.to_string())
    })
}

fn validate_path(path: &str) -> Result<(), CoreError> {
    if path.is_empty()
        || path.starts_with('/')
        || path.contains(['\\', ':', '\0'])
        || path.split('/').any(|part| part == "..")
    {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Directory rule paths must be workspace-relative",
        ));
    }
    Ok(())
}

fn validate_rules(rules: &Rules) -> Result<(), CoreError> {
    if rules.marks.len() + rules.included_directories.len() + rules.previous_roles.len()
        > MAX_ENTRIES
    {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Too many directory rules",
        ));
    }
    let paths = rules
        .marks
        .keys()
        .chain(&rules.included_directories)
        .chain(rules.previous_roles.keys());
    for path in paths {
        validate_path(path)?;
    }
    for role in rules.marks.values().chain(rules.previous_roles.values()) {
        if !ROLES.contains(&role.as_str()) {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "Unknown directory role",
            ));
        }
    }
    Ok(())
}
