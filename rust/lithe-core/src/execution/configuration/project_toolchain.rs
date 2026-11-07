//! Read-only project tool selections for an authoritative workspace-relative
//! owner. Platforms discover and probe executables; Core only returns the saved
//! machine-local runtime paths, tool preferences and the per-Run defined tools.
//! It never inspects a build file or runs a tool.

use super::{existing_root, local_layer_document, read_local_toolchains, validate_version_value};
use crate::protocol::{invalid_relative_path, CoreError, ErrorCode};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::BTreeMap;

/// Reads current tool selections even when no Run configuration was generated.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct ProjectToolchainRequest {
    /// Absolute native workspace root, owned by the platform.
    pub(crate) root: String,
    /// Current Provider project root, relative to that workspace.
    pub(crate) path: String,
    /// Optional host-owned replacement for the local Run document.
    #[serde(default)]
    pub(crate) local_document: Option<Value>,
    /// Optional Run whose provider-declared tools are reported; it must belong
    /// to the same provider instance as `path`.
    #[serde(default)]
    pub(crate) configuration_id: Option<String>,
}

/// Returns saved paths, never resolved executables.
pub(crate) fn project_toolchain(request: ProjectToolchainRequest) -> Result<Value, CoreError> {
    if request.path.len() > 1024
        || invalid_relative_path(&request.path)
        || request.path.contains('\\')
        || request.path.chars().any(char::is_control)
        || request.path != "."
            && request
                .path
                .split('/')
                .any(|part| part.is_empty() || part == ".")
    {
        return Err(CoreError::new(
            ErrorCode::InvalidRequest,
            "Toolchain owner must be a workspace-relative path",
        ));
    }
    let root = existing_root(&request.root)?;
    let document = local_layer_document(&root, request.local_document)?;
    validate_version_value(&document)?;
    let toolchain = &document["toolchain"];
    if !toolchain.is_null() && !toolchain.is_object() {
        return Err(invalid_paths());
    }
    let mut runtimes = BTreeMap::new();
    if let Some(document) = read_local_toolchains(&root)? {
        let entries = document["toolchains"]
            .as_object()
            .ok_or_else(invalid_paths)?;
        if entries.len() > 256 {
            return Err(invalid_paths());
        }
        for (id, value) in entries {
            if !crate::plugins::declarative::is_identifier(id) || !value.is_object() {
                return Err(invalid_paths());
            }
            let executable = saved_path(&value["executable"])?;
            if !executable.is_empty() {
                runtimes.insert(id.clone(), executable);
            }
        }
    }
    let mut result = json!({ "toolchain": {
        "runtimeExecutablePaths": runtimes,
    }});
    if let Some(preferences) = toolchain.get("preferences") {
        result["toolPreferences"] = preferences.clone();
    }
    if let Some(id) = request.configuration_id.as_deref() {
        let mut explicit = document.clone();
        // Reuse the existing layer merge, without materializing global
        // defaults as if they were per-configuration choices. The caller's
        // workspace defaults have already been selected above.
        explicit
            .as_object_mut()
            .ok_or_else(invalid_paths)?
            .remove("toolchain");
        let resolved = super::resolve(super::ResolveRequest {
            team_document: None,
            root: root.to_string_lossy().into_owned(),
            toolchain_candidates: Vec::new(),
            local_document: Some(explicit),
        })?;
        let config = resolved["configurations"]
            .as_array()
            .and_then(|items| {
                items
                    .iter()
                    .find(|item| item["id"] == id && item["disabled"] != true)
            })
            .ok_or_else(|| {
                CoreError::new(
                    ErrorCode::InvalidRequest,
                    "Run configuration is unavailable",
                )
            })?;
        if config["extensions"]["build"]["root"]
            .as_str()
            .is_some_and(|owner| owner != request.path)
        {
            return Err(CoreError::new(
                ErrorCode::InvalidRequest,
                "Run configuration belongs to a different provider instance",
            ));
        }
        if config["provider"] == "build.provider" {
            let extensions = serde_json::from_value(config["extensions"].clone())
                .map_err(|_| invalid_paths())?;
            let choices =
                crate::execution::provider_run_options::BuildProviderRunOptions::from_extensions(
                    &extensions,
                )?;
            let tools = choices.active_tools();
            if !tools.is_empty() {
                result["definedTools"] = json!(tools);
            }
        }
    }
    Ok(result)
}

fn invalid_paths() -> CoreError {
    CoreError::new(
        ErrorCode::ParseFailed,
        "Project toolchain paths must be bounded strings",
    )
}

fn saved_path(value: &Value) -> Result<String, CoreError> {
    if value.is_null() {
        return Ok(String::new());
    }
    let value = value.as_str().ok_or_else(invalid_paths)?;
    if value.len() > 4096 || value.chars().any(char::is_control) {
        return Err(invalid_paths());
    }
    Ok(value.trim().to_string())
}
