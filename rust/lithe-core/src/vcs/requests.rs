//! Operations of the VCS provider protocol: which method and capability each
//! one uses, how a host's arguments become request params, and how the
//! provider's reply is decoded.
//!
//! The host names an operation, never a method, so a session that negotiated
//! the protocol cannot be used as a generic JSON-RPC tunnel. Arguments come
//! from the host and are checked as strictly as replies: paths stay inside the
//! root, lists are bounded, and unknown fields fail, because a provider runs
//! the VCS client with them.

use super::model::{self, Capabilities, MAX_HISTORY_PAGE, MAX_MESSAGE_BYTES};
use crate::plugins::declarative::Validation;
use crate::protocol::{CoreError, ErrorCode};
use serde::de::DeserializeOwned;
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::BTreeSet;
use std::path::Path;

/// Most paths one mutation may name.
const MAX_PATHS: usize = 10_000;
/// History page size when the host does not ask for one.
const DEFAULT_HISTORY_LIMIT: usize = 100;

/// One operation of protocol version 1.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Operation {
    Status,
    BaseContent,
    History,
    FileHistory,
    Annotate,
    Checkin,
    Rollback,
    Update,
    FileOperation,
    Resolve,
    Cleanup,
}

/// Every operation, for method checks and contract tests.
pub(crate) const OPERATIONS: [Operation; 11] = [
    Operation::Status,
    Operation::BaseContent,
    Operation::History,
    Operation::FileHistory,
    Operation::Annotate,
    Operation::Checkin,
    Operation::Rollback,
    Operation::Update,
    Operation::FileOperation,
    Operation::Resolve,
    Operation::Cleanup,
];

impl Operation {
    /// Parses the operation name a host sends, which is also the last
    /// segment of its method.
    pub(crate) fn parse(name: &str) -> Option<Self> {
        OPERATIONS
            .into_iter()
            .find(|operation| operation.name() == name)
    }

    pub(crate) fn name(self) -> &'static str {
        match self {
            Self::Status => "status",
            Self::BaseContent => "baseContent",
            Self::History => "history",
            Self::FileHistory => "fileHistory",
            Self::Annotate => "annotate",
            Self::Checkin => "checkin",
            Self::Rollback => "rollback",
            Self::Update => "update",
            Self::FileOperation => "fileOperation",
            Self::Resolve => "resolve",
            Self::Cleanup => "cleanup",
        }
    }

    /// JSON-RPC method the host writes to the provider.
    pub(crate) fn method(self) -> &'static str {
        match self {
            Self::Status => "lithe/vcs/status",
            Self::BaseContent => "lithe/vcs/baseContent",
            Self::History => "lithe/vcs/history",
            Self::FileHistory => "lithe/vcs/fileHistory",
            Self::Annotate => "lithe/vcs/annotate",
            Self::Checkin => "lithe/vcs/checkin",
            Self::Rollback => "lithe/vcs/rollback",
            Self::Update => "lithe/vcs/update",
            Self::FileOperation => "lithe/vcs/fileOperation",
            Self::Resolve => "lithe/vcs/resolve",
            Self::Cleanup => "lithe/vcs/cleanup",
        }
    }

    /// Capability the provider must have negotiated for this operation.
    pub(crate) fn capability(self) -> &'static str {
        match self {
            Self::FileOperation => "fileOperations",
            Self::Resolve => "conflicts",
            other => other.name(),
        }
    }
}

/// Whether `method` belongs to the protocol; its replies are wrapped like
/// command results so no LSP normalizer reinterprets them.
pub(crate) fn is_vcs_method(method: &str) -> bool {
    OPERATIONS
        .into_iter()
        .any(|operation| operation.method() == method)
}

fn invalid_request(message: impl Into<String>) -> CoreError {
    CoreError::new(ErrorCode::InvalidRequest, message)
}

fn arguments<T: DeserializeOwned>(operation: Operation, value: Value) -> Result<T, CoreError> {
    // An operation without arguments may omit them entirely.
    let value = if value.is_null() { json!({}) } else { value };
    serde_json::from_value(value).map_err(|error| {
        invalid_request(format!("Invalid {} arguments", operation.name()))
            .with_details(error.to_string())
    })
}

fn root_path(path: &str) -> Result<String, CoreError> {
    if model::is_root_relative(path) {
        Ok(path.to_string())
    } else {
        Err(invalid_request("A VCS path must be relative to its root.").with_details(path))
    }
}

/// Root-relative paths, sorted and unique; at least one, at most
/// [`MAX_PATHS`].
fn path_list(paths: &[String]) -> Result<Vec<String>, CoreError> {
    if paths.is_empty() || paths.len() > MAX_PATHS {
        return Err(invalid_request(format!(
            "An operation names 1-{MAX_PATHS} paths."
        )));
    }
    let unique: BTreeSet<String> = paths
        .iter()
        .map(|path| root_path(path))
        .collect::<Result<_, _>>()?;
    Ok(unique.into_iter().collect())
}

fn absolute_path(value: &str, what: &str) -> Result<String, CoreError> {
    if Path::new(value).is_absolute() && !value.contains('\0') {
        Ok(value.to_string())
    } else {
        Err(invalid_request(format!(
            "The {what} must be an absolute path."
        )))
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct StatusArguments {
    #[serde(default)]
    include_ignored: bool,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PathArguments {
    path: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct PathsArguments {
    paths: Vec<String>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct HistoryArguments {
    #[serde(default)]
    path: Option<String>,
    /// Opaque cursor from the previous page; absent for the first page.
    #[serde(default)]
    cursor: Option<String>,
    #[serde(default)]
    limit: Option<usize>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct CheckinArguments {
    paths: Vec<String>,
    message: String,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct UpdateArguments {
    /// Revision ID to update to, as the provider reported it; absent for
    /// the newest revision.
    #[serde(default)]
    revision: Option<String>,
}

/// A change made in the project tree that the VCS must record. `move`
/// carries both ends so the VCS keeps the file's history.
#[derive(Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase", deny_unknown_fields)]
enum FileOperationArguments {
    Add { paths: Vec<String> },
    Delete { paths: Vec<String> },
    Move { from: String, to: String },
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct NoArguments {}

/// The params of one request, without `root` and `tool`.
fn operation_params(operation: Operation, value: Value) -> Result<Value, CoreError> {
    Ok(match operation {
        Operation::Status => {
            let arguments: StatusArguments = arguments(operation, value)?;
            json!({ "includeIgnored": arguments.include_ignored })
        }
        Operation::BaseContent | Operation::Annotate => {
            let arguments: PathArguments = arguments(operation, value)?;
            json!({ "path": root_path(&arguments.path)? })
        }
        Operation::History | Operation::FileHistory => {
            let arguments: HistoryArguments = arguments(operation, value)?;
            let limit = arguments.limit.unwrap_or(DEFAULT_HISTORY_LIMIT);
            if limit == 0 || limit > MAX_HISTORY_PAGE {
                return Err(invalid_request(format!(
                    "A history page has 1-{MAX_HISTORY_PAGE} entries."
                )));
            }
            if let Some(cursor) = &arguments.cursor {
                if cursor.is_empty() || cursor.len() > 256 || cursor.chars().any(char::is_control) {
                    return Err(invalid_request("The history cursor is malformed."));
                }
            }
            let mut params = json!({ "cursor": arguments.cursor, "limit": limit });
            match (operation, arguments.path) {
                (Operation::FileHistory, Some(path)) => params["path"] = json!(root_path(&path)?),
                (Operation::History, None) => {}
                _ => {
                    return Err(invalid_request(
                        "fileHistory needs a path; history of the whole root takes none.",
                    ))
                }
            }
            params
        }
        Operation::Checkin => {
            let arguments: CheckinArguments = arguments(operation, value)?;
            if arguments.message.trim().is_empty()
                || arguments.message.len() > MAX_MESSAGE_BYTES
                || arguments.message.contains('\0')
            {
                return Err(invalid_request(
                    "A check-in message is non-empty text of at most 1 MiB.",
                ));
            }
            json!({ "paths": path_list(&arguments.paths)?, "message": arguments.message })
        }
        Operation::Rollback | Operation::Resolve => {
            let arguments: PathsArguments = arguments(operation, value)?;
            json!({ "paths": path_list(&arguments.paths)? })
        }
        Operation::Update => {
            let arguments: UpdateArguments = arguments(operation, value)?;
            if let Some(revision) = &arguments.revision {
                if revision.is_empty()
                    || revision.len() > 256
                    || revision.chars().any(char::is_control)
                {
                    return Err(invalid_request("The revision ID is malformed."));
                }
            }
            json!({ "revision": arguments.revision })
        }
        Operation::FileOperation => match arguments(operation, value)? {
            FileOperationArguments::Add { paths } => {
                json!({ "kind": "add", "paths": path_list(&paths)? })
            }
            FileOperationArguments::Delete { paths } => {
                json!({ "kind": "delete", "paths": path_list(&paths)? })
            }
            FileOperationArguments::Move { from, to } => {
                let (from, to) = (root_path(&from)?, root_path(&to)?);
                if from == to {
                    return Err(invalid_request("A move needs two different paths."));
                }
                json!({ "kind": "move", "from": from, "to": to })
            }
        },
        Operation::Cleanup => {
            let _: NoArguments = arguments(operation, value)?;
            json!({})
        }
    })
}

/// A request ready to be written to a provider session.
#[derive(Debug)]
pub(crate) struct PlannedRequest {
    pub(crate) method: &'static str,
    pub(crate) params: Value,
}

/// Plans one request. `root` is the native path of the working-copy root and
/// `tool` the client executable the host resolved for the provider; both are
/// sent with every request so the provider never searches for either.
pub(crate) fn plan(
    operation: Operation,
    root: &str,
    tool: Option<&str>,
    arguments: Value,
    capabilities: &Capabilities,
) -> Result<PlannedRequest, CoreError> {
    if !capabilities.contains_key(operation.capability()) {
        return Err(CoreError::new(
            ErrorCode::NotSupported,
            format!(
                "The VCS provider did not negotiate {}.",
                operation.capability()
            ),
        )
        .with_details("vcs.capability.unsupported"));
    }
    let mut params = operation_params(operation, arguments)?;
    params["root"] = json!({ "path": absolute_path(root, "VCS root")? });
    params["tool"] = match tool {
        Some(tool) => json!({ "executable": absolute_path(tool, "VCS tool")? }),
        None => Value::Null,
    };
    Ok(PlannedRequest {
        method: operation.method(),
        params,
    })
}

/// Decodes the reply to `operation`. `request` is the arguments the host
/// sent, which bound what a valid reply may contain.
pub(crate) fn decode(
    operation: Operation,
    request: &Value,
    reply: &Value,
    capabilities: &Capabilities,
) -> Validation<Value> {
    match operation {
        Operation::Status => model::decode_status(reply, capabilities),
        Operation::BaseContent => model::decode_base_content(reply),
        Operation::History | Operation::FileHistory => {
            let limit = request
                .get("limit")
                .and_then(Value::as_u64)
                .and_then(|limit| usize::try_from(limit).ok())
                .unwrap_or(DEFAULT_HISTORY_LIMIT)
                .min(MAX_HISTORY_PAGE);
            model::decode_history(reply, limit)
        }
        Operation::Annotate => model::decode_annotation(reply),
        Operation::Checkin => model::decode_checkin(reply),
        Operation::Update => model::decode_update(reply),
        Operation::Rollback
        | Operation::FileOperation
        | Operation::Resolve
        | Operation::Cleanup => model::decode_empty(reply),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn all_capabilities() -> Capabilities {
        model::CAPABILITIES
            .iter()
            .map(|(id, _)| (id.to_string(), 1))
            .collect()
    }

    fn root() -> String {
        std::env::temp_dir()
            .join("lithe-vcs-root")
            .to_string_lossy()
            .into_owned()
    }

    #[test]
    fn every_operation_round_trips_its_name_and_uses_a_contract_capability() {
        for operation in OPERATIONS {
            assert_eq!(Operation::parse(operation.name()), Some(operation));
            assert!(is_vcs_method(operation.method()));
            assert!(
                model::is_capability(operation.capability()),
                "{operation:?}"
            );
        }
        assert!(!is_vcs_method("workspace/executeCommand"));
        assert_eq!(Operation::parse("push"), None);
    }

    #[test]
    fn a_plan_carries_root_tool_and_checked_arguments() {
        let tool = std::env::temp_dir()
            .join("svn")
            .to_string_lossy()
            .into_owned();
        let planned = plan(
            Operation::Checkin,
            &root(),
            Some(&tool),
            json!({ "paths": ["b", "a", "b"], "message": "Fix" }),
            &all_capabilities(),
        )
        .expect("planned");
        assert_eq!(planned.method, "lithe/vcs/checkin");
        assert_eq!(planned.params["paths"], json!(["a", "b"]));
        assert_eq!(planned.params["root"]["path"], json!(root()));
        assert_eq!(planned.params["tool"]["executable"], json!(tool));
    }

    #[test]
    fn a_plan_rejects_unsafe_or_unknown_arguments() {
        let capabilities = all_capabilities();
        for (operation, arguments) in [
            (Operation::Rollback, json!({ "paths": ["../x"] })),
            (Operation::Rollback, json!({ "paths": [] })),
            (
                Operation::Checkin,
                json!({ "paths": ["a"], "message": "  " }),
            ),
            (Operation::Status, json!({ "recursive": false })),
            (Operation::History, json!({ "path": "a" })),
            (Operation::FileHistory, json!({})),
            (Operation::History, json!({ "limit": 0 })),
            (
                Operation::FileOperation,
                json!({ "kind": "move", "from": "a", "to": "a" }),
            ),
            (Operation::Cleanup, json!({ "force": true })),
        ] {
            let error = plan(operation, &root(), None, arguments.clone(), &capabilities)
                .expect_err("rejected");
            assert!(
                matches!(error.code, ErrorCode::InvalidRequest),
                "{operation:?} {arguments}"
            );
        }
        assert!(plan(
            Operation::Status,
            "relative",
            None,
            Value::Null,
            &capabilities
        )
        .is_err());
    }

    #[test]
    fn an_operation_needs_its_negotiated_capability() {
        let mut capabilities = all_capabilities();
        capabilities.remove("conflicts");
        let error = plan(
            Operation::Resolve,
            &root(),
            None,
            json!({ "paths": ["a"] }),
            &capabilities,
        )
        .expect_err("unsupported");
        assert!(matches!(error.code, ErrorCode::NotSupported));
        assert_eq!(error.details.as_deref(), Some("vcs.capability.unsupported"));
    }

    #[test]
    fn history_replies_are_bounded_by_the_requested_limit() {
        let reply = json!({ "entries": [
            { "revision": { "id": "2" } }, { "revision": { "id": "1" } }
        ] });
        assert!(decode(
            Operation::History,
            &json!({ "limit": 2 }),
            &reply,
            &all_capabilities()
        )
        .is_ok());
        assert!(decode(
            Operation::History,
            &json!({ "limit": 1 }),
            &reply,
            &all_capabilities()
        )
        .is_err());
    }
}
