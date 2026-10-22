//! Run and test plans for declarative plugins.
//!
//! Core expands the declared templates into an executable and arguments; the
//! host resolves the executable like any other launch (`run_resolve_launch`)
//! and starts the process through the shared run pipeline. Process ownership
//! is tracked per workspace and plugin on the frontend, exactly like Worker
//! extension run actions.

use super::scan::core_execute;
use serde::Serialize;
use serde_json::Value;
use tauri::AppHandle;

/// An expanded run or test plan ready for the shared run pipeline.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DeclarativeRunPlan {
    pub plugin_id: String,
    pub language_id: String,
    /// Executable command as declared (e.g. `php`); the frontend resolves it
    /// through `run_resolve_launch` like any extension run action.
    pub executable: Value,
    pub arguments: Vec<String>,
    pub working_directory: String,
}

/// Expands the `run` template for one file of a language a plugin owns.
#[tauri::command]
pub fn declarative_plugins_run_plan(
    app: AppHandle,
    plugin_id: String,
    language_id: String,
    relative_file_path: String,
    user_arguments: Vec<String>,
) -> Result<DeclarativeRunPlan, String> {
    let package = super::launch::package_by_id(&app, &plugin_id)
        .ok_or_else(|| format!("{plugin_id} is not an accepted declarative plugin"))?;
    expand_plan(
        &package.manifest,
        &plugin_id,
        &language_id,
        "plugins.declarative.runPlan",
        serde_json::json!({
            "relativeFilePath": relative_file_path,
            "arguments": user_arguments,
        }),
    )
}

/// Expands the workspace test template for a language a plugin owns.
/// `relative_project_file_paths` is the workspace's file list; the template's
/// project markers decide whether tests can run at all.
#[tauri::command]
pub fn declarative_plugins_test_plan(
    app: AppHandle,
    plugin_id: String,
    language_id: String,
    relative_project_file_paths: Vec<String>,
) -> Result<DeclarativeRunPlan, String> {
    let package = super::launch::package_by_id(&app, &plugin_id)
        .ok_or_else(|| format!("{plugin_id} is not an accepted declarative plugin"))?;
    expand_plan(
        &package.manifest,
        &plugin_id,
        &language_id,
        "plugins.declarative.testPlan",
        serde_json::json!({
            "scope": { "kind": "workspace" },
            "relativeProjectFilePaths": relative_project_file_paths,
        }),
    )
}

fn expand_plan(
    manifest: &Value,
    plugin_id: &str,
    language_id: &str,
    command: &str,
    request: Value,
) -> Result<DeclarativeRunPlan, String> {
    let plan = core_execute(
        command,
        serde_json::json!({
            "manifest": manifest,
            "languageID": language_id,
            "request": request,
        }),
    )?;
    if plan["status"] == serde_json::json!("rejected") {
        return Err(format!(
            "{command} rejected: {}",
            plan["error"]["message"].as_str().unwrap_or("unknown")
        ));
    }
    let body = &plan["plan"];
    Ok(DeclarativeRunPlan {
        plugin_id: plugin_id.to_string(),
        language_id: language_id.to_string(),
        executable: body["executable"].clone(),
        arguments: body["arguments"]
            .as_array()
            .map(|items| {
                items
                    .iter()
                    .filter_map(|item| item.as_str().map(str::to_string))
                    .collect()
            })
            .unwrap_or_default(),
        working_directory: body["workingDirectory"].as_str().unwrap_or(".").to_string(),
    })
}
