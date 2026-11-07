//! Permission and read-only policy for language-server jump targets
//! (`lsp.classifyNavigationTarget`).
//!
//! A jump may open a workspace file normally. It may leave the workspace only
//! into a source file of the language that produced it, and such a file opens
//! read-only; configuration, credentials and other files a server might point
//! at stay closed. Hosts own symlink resolution and the path-to-language
//! lookup and pass both as facts; Core owns the decision.

use crate::lsp::{workspace_scope::WorkspaceScope, DocumentPathPlatform};
use crate::protocol::{CoreError, ErrorCode};
use serde::Deserialize;
use serde_json::{json, Value};

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Request {
    platform: DocumentPathPlatform,
    /// Workspace root as opened; `None` when no workspace is open.
    #[serde(default)]
    workspace_root: Option<String>,
    /// Real path of the root, when the host resolved symlinks.
    #[serde(default)]
    resolved_workspace_root: Option<String>,
    /// Absolute target path, as the editor would open it.
    path: String,
    /// Real path of the target, when the host resolved symlinks.
    #[serde(default)]
    resolved_path: Option<String>,
    /// Language that produced the jump; `None` permits no external target.
    #[serde(default, rename = "sourceLanguageID")]
    source_language_id: Option<String>,
    /// Language the host assigns to `path`.
    #[serde(default, rename = "languageID")]
    language_id: Option<String>,
    /// Language the host assigns to `resolvedPath`.
    #[serde(default, rename = "resolvedLanguageID")]
    resolved_language_id: Option<String>,
    /// Read-only flag the server or Core projection put on the location.
    #[serde(default)]
    is_read_only: bool,
}

/// Classifies a physical jump target as `workspace`, `externalReadOnly` or
/// `rejected`, and returns the effective `isReadOnly` for opening it.
///
/// A target is a workspace file only when both its opened path and its real
/// path are inside the workspace (lexically, through either the opened or the
/// real root): an in-workspace symlink to the outside must not skip the
/// source-file check, and an outside path to a workspace file still opens
/// under its outside path. Missing real paths fall back to the opened ones.
pub(crate) fn classify_command(payload: Value) -> Result<Value, CoreError> {
    let request: Request = serde_json::from_value(payload).map_err(|error| {
        CoreError::new(
            ErrorCode::InvalidRequest,
            "Invalid navigation target classification request",
        )
        .with_details(error.to_string())
    })?;
    let classification = classify(&request)?;
    Ok(json!({
        "classification": classification,
        "isReadOnly": request.is_read_only || classification == "externalReadOnly",
    }))
}

fn classify(request: &Request) -> Result<&'static str, CoreError> {
    let Some(root) = request.workspace_root.as_deref() else {
        return Ok("workspace");
    };
    let resolved_root = request.resolved_workspace_root.as_deref().unwrap_or(root);
    let resolved_path = request.resolved_path.as_deref().unwrap_or(&request.path);
    let opened_scope = WorkspaceScope::new(root, request.platform)?;
    let real_scope = WorkspaceScope::new(resolved_root, request.platform)?;
    let opens_inside =
        opened_scope.contains(&request.path)? || real_scope.contains(&request.path)?;
    let resolves_inside = real_scope.contains(resolved_path)?;
    if opens_inside && resolves_inside {
        return Ok("workspace");
    }
    let resolved_language = if request.resolved_path.is_some() {
        request.resolved_language_id.as_deref()
    } else {
        request.language_id.as_deref()
    };
    let same_language = request.source_language_id.as_deref().is_some_and(|source| {
        request.language_id.as_deref() == Some(source) && resolved_language == Some(source)
    });
    Ok(if same_language {
        "externalReadOnly"
    } else {
        "rejected"
    })
}

#[cfg(test)]
mod tests {
    use serde_json::{json, Value};

    /// Every shared-fixture case yields its expected data or error code
    /// through the public JSON command.
    #[test]
    fn matches_shared_fixture() {
        let fixture: Value = serde_json::from_str(include_str!(
            "../../../../shared/fixtures/lsp/navigation-target-v1.json"
        ))
        .unwrap();
        for case in fixture["cases"].as_array().unwrap() {
            let response: Value = serde_json::from_str(&crate::execute_json(
                &json!({"command": "lsp.classifyNavigationTarget", "payload": case["request"]})
                    .to_string(),
            ))
            .unwrap();
            if let Some(code) = case.get("expectedError") {
                assert_eq!(response["ok"], false, "{}: {response}", case["name"]);
                assert_eq!(&response["error"]["code"], code, "{}", case["name"]);
            } else {
                assert_eq!(response["ok"], true, "{}: {response}", case["name"]);
                assert_eq!(response["data"], case["expected"], "{}", case["name"]);
            }
        }
    }
}
