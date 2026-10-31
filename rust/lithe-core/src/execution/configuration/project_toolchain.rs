//! Read-only project tool paths for an authoritative workspace-relative owner.
//! Platforms discover/probe executables; Core resolves only saved Run defaults
//! the nearest path override, and explicit per-Run paths. It never inspects
//! a POM or runs a tool.

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
    /// Current Provider project/reactor root, relative to that workspace.
    pub(crate) path: String,
    /// Optional host-owned replacement for the local Run document.
    #[serde(default)]
    pub(crate) local_document: Option<Value>,
    /// Optional Run whose explicit path overrides take precedence over the
    /// canonical project/reactor selection. Empty fields keep that selection.
    #[serde(default)]
    pub(crate) configuration_id: Option<String>,
}

/// Returns paths, never resolved executables. Empty override fields inherit the
/// workspace defaults, rather than falling through a second ancestor override.
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
    for group in [toolchain, &toolchain["java"], &toolchain["maven"]] {
        if !group.is_null() && !group.is_object() {
            return Err(invalid_paths());
        }
    }
    let java = saved_path(&toolchain["java"]["homePath"])?;
    let maven = saved_path(&toolchain["maven"]["executablePath"])?;
    let maven_java = saved_path(&toolchain["maven"]["javaHomePath"])?;
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
    let selected = toolchain["pathOverrides"]
        .as_object()
        .and_then(|overrides| {
            overrides
                .iter()
                .filter(|(path, _)| {
                    request.path == **path || request.path.starts_with(&format!("{path}/"))
                })
                .max_by_key(|(path, _)| path.len())
                .map(|(_, value)| value)
        });
    let path = |key: &str, default: &str| {
        selected
            .and_then(|value| value[key].as_str())
            .filter(|value| !value.trim().is_empty())
            .unwrap_or(default)
            .trim()
            .to_string()
    };
    let mut result = json!({ "toolchain": {
        "javaHomePath": path("javaHomePath", &java),
        "mavenExecutablePath": path("mavenExecutablePath", &maven),
        "mavenJavaHomePath": path("mavenJavaHomePath", &maven_java),
        "runtimeExecutablePaths": runtimes,
    }});
    if let Some(id) = request.configuration_id.as_deref() {
        let mut explicit = document.clone();
        // Reuse the existing layer merge, without materializing global
        // defaults as if they were per-configuration choices. The caller's
        // canonical reactor defaults have already been selected above.
        explicit
            .as_object_mut()
            .ok_or_else(invalid_paths)?
            .remove("toolchain");
        let resolved = super::resolve(super::ResolveRequest {
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
        for owner in [
            &config["extensions"]["build"]["root"],
            &config["extensions"]["maven"]["reactorPath"],
        ] {
            if owner.as_str().is_some_and(|owner| owner != request.path) {
                return Err(CoreError::new(
                    ErrorCode::InvalidRequest,
                    "Run configuration belongs to a different provider instance",
                ));
            }
        }
        for (key, field) in [
            ("javaHomePath", "homePath"),
            ("mavenExecutablePath", "mavenExecutablePath"),
            ("mavenJavaHomePath", "mavenJavaHomePath"),
        ] {
            let value = saved_path(&config["extensions"]["java"][field])?;
            if !value.is_empty() {
                result["toolchain"][key] = json!(value);
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
