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
use std::path::Path;
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
    let package = super::launch::verified_package_by_id(&app, &plugin_id)?;
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
/// The host checks declared project markers in the workspace before Core
/// decides whether the test template applies.
#[tauri::command]
pub fn declarative_plugins_test_plan(
    app: AppHandle,
    plugin_id: String,
    language_id: String,
    workspace_path: String,
) -> Result<DeclarativeRunPlan, String> {
    let package = super::launch::verified_package_by_id(&app, &plugin_id)?;
    let relative_project_file_paths =
        existing_project_markers(&package.manifest, &language_id, Path::new(&workspace_path));
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

fn existing_project_markers(manifest: &Value, language_id: &str, root: &Path) -> Vec<String> {
    let mut markers: Vec<String> = manifest["executionProviders"]
        .as_array()
        .into_iter()
        .flatten()
        .filter(|provider| provider["languageID"] == language_id)
        .flat_map(|provider| {
            provider["test"]["projectMarkers"]
                .as_array()
                .into_iter()
                .flatten()
        })
        .filter_map(|marker| marker.as_str())
        .filter(|marker| root.join(marker).is_file())
        .map(str::to_string)
        .collect();
    markers.sort();
    markers.dedup();
    markers
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_markers_come_from_existing_workspace_files_for_the_language() {
        let root = std::env::temp_dir().join(format!(
            "lithe-test-markers-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("clock")
                .as_nanos()
        ));
        std::fs::create_dir_all(&root).expect("workspace");
        std::fs::write(root.join("composer.json"), "{}").expect("marker");
        let manifest = serde_json::json!({
            "executionProviders": [
                {"languageID": "php", "test": {"projectMarkers": ["composer.json", "phpunit.xml"]}},
                {"languageID": "go", "test": {"projectMarkers": ["go.mod"]}}
            ]
        });
        assert_eq!(
            existing_project_markers(&manifest, "php", &root),
            vec!["composer.json"]
        );
        assert!(existing_project_markers(&manifest, "go", &root).is_empty());
        std::fs::remove_dir_all(root).expect("cleanup");
    }
}
