//! Turns Core launch plans into process command lines for the frontend.
//!
//! Core expands templates and chooses the launch kind; this module resolves
//! the plan against real paths. Packaged entries must be regular files inside
//! the owning package — reparse points and path escapes are rejected so a
//! tampered package can never make the host execute anything outside its own
//! version directory. Runtime and system-command launches resolve through
//! PATH and export the same `LITHE_<TOOL>_PATH` convention the macOS host
//! uses; the declared `minimumVersion` probe is enforced from the install
//! milestone on, when the host also owns the checkRuntimeVersion wiring.

use super::store;
use super::ScannedPackage;
use serde::Serialize;
use serde_json::Value;
use std::collections::BTreeMap;
use std::path::Path;
use std::path::PathBuf;
use tauri::{AppHandle, Manager};

/// Windows reparse-point attribute; covers symlinks and junctions alike.
#[cfg(windows)]
const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0400;

#[cfg(windows)]
use std::os::windows::fs::MetadataExt;

/// A resolved launch, shaped for `resolveEditorLspLaunch` on the frontend.
#[derive(Debug, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResolvedLaunch {
    pub plugin_id: String,
    pub language_id: String,
    pub server_path: String,
    pub server_args: Vec<String>,
    pub initialization_options: Option<Value>,
    /// Extra process environment (PATH prepends and LITHE_* exports).
    pub environment: BTreeMap<String, String>,
}

/// Resolves the launch plan of the enabled declarative plugin that owns
/// `file_path`, or `None` when no accepted plugin claims the file.
#[tauri::command]
pub fn declarative_plugins_language_launch(
    app: AppHandle,
    file_path: String,
    workspace_path: String,
) -> Result<Option<ResolvedLaunch>, String> {
    let Some(package) = owning_package(&app, &file_path) else {
        return Ok(None);
    };
    let Some(language_id) = owning_language_id(&package, &file_path) else {
        return Ok(None);
    };
    let state_directory = store::plugin_state_directory(&app, &package.entry.plugin_id)?;
    let layers = super::settings::load_layers(&app, &package.entry.plugin_id, &workspace_path)
        .map_err(|error| format!("plugin settings could not be read: {error}"))?;
    let plan = super::scan::core_execute(
        "plugins.declarative.languageServerLaunchPlan",
        serde_json::json!({
            "manifest": package.manifest,
            "languageID": language_id,
            "request": launch_request(&state_directory, &package, &workspace_path, layers),
        }),
    )
    .map_err(|error| format!("launch plan failed: {error}"))?;
    if plan["status"] == serde_json::json!("rejected") {
        return Err(format!(
            "launch plan rejected: {}",
            plan["error"]["message"].as_str().unwrap_or("unknown")
        ));
    }
    resolve_launch(&package, &language_id, &plan).map(Some)
}

/// Finds an accepted, enabled scanned package by plugin ID.
pub(crate) fn package_by_id(app: &AppHandle, plugin_id: &str) -> Option<ScannedPackage> {
    app.state::<super::PluginHostState>()
        .packages()
        .into_iter()
        .find(|package| {
            package.entry.status == "accepted"
                && package.entry.enabled
                && package.entry.plugin_id == plugin_id
        })
}

fn owning_package(app: &AppHandle, file_path: &str) -> Option<ScannedPackage> {
    app.state::<super::PluginHostState>()
        .packages()
        .into_iter()
        .find(|package| package_matches_file(package, file_path))
}

fn package_matches_file(package: &ScannedPackage, file_path: &str) -> bool {
    package.entry.status == "accepted"
        && package.entry.enabled
        && owning_language_id(package, file_path).is_some()
}

/// Matches a file against the manifest's language declarations: extensions
/// compare without their optional leading dot and case-insensitively, file
/// names compare as exact lowercased basenames.
fn owning_language_id(package: &ScannedPackage, file_path: &str) -> Option<String> {
    let file_name = Path::new(file_path)
        .file_name()
        .map(|name| name.to_string_lossy().to_lowercase())
        .unwrap_or_default();
    let extension = Path::new(&file_name)
        .extension()
        .map(|extension| extension.to_string_lossy().to_lowercase());
    package.manifest["languages"]
        .as_array()?
        .iter()
        .find(|language| {
            let matches_extension = language["fileExtensions"].as_array().is_some_and(|items| {
                items.iter().any(|item| {
                    item.as_str()
                        .map(|text| text.trim_start_matches('.').to_lowercase())
                        == extension
                })
            });
            let matches_name = language["fileNames"].as_array().is_some_and(|items| {
                items
                    .iter()
                    .any(|item| item.as_str().map(str::to_lowercase).as_deref() == Some(&file_name))
            });
            matches_extension || matches_name
        })
        .and_then(|language| language["id"].as_str().map(str::to_string))
}

/// Builds the Core launch-plan request with host-owned directories and
/// architecture. Settings layers stay empty until the settings milestone;
/// Core then falls back to declared defaults.
fn launch_request(
    state_directory: &Path,
    package: &ScannedPackage,
    workspace_path: &str,
    layers: super::settings::SettingLayers,
) -> Value {
    let workspace_directory = state_directory.join(store::workspace_state_key(workspace_path));
    serde_json::json!({
        "pluginDirectory": package.root.to_string_lossy(),
        "stateDirectory": state_directory.to_string_lossy(),
        "workspaceStateDirectory": workspace_directory.to_string_lossy(),
        "architecture": super::host_architecture(),
        "settings": layers.global,
        "projectSettings": layers.project,
    })
}

fn resolve_launch(
    package: &ScannedPackage,
    language_id: &str,
    plan: &Value,
) -> Result<ResolvedLaunch, String> {
    let launch = &plan["launch"];
    let kind = launch["kind"].as_str().unwrap_or_default();
    let mut environment: BTreeMap<String, String> = BTreeMap::new();
    let server_path = match kind {
        "packaged" => verified_packaged_path(
            &package.root,
            launch["path"]
                .as_str()
                .ok_or("packaged launch has no path")?,
        )?,
        "systemCommand" => {
            let commands = launch["commands"]
                .as_array()
                .ok_or("systemCommand launch has no commands")?;
            let path_env = std::env::var_os("PATH");
            commands
                .iter()
                .filter_map(|command| command.as_str())
                .find_map(|command| {
                    super::super::language_tools::find_system_tool(path_env.as_deref(), command)
                })
                .ok_or_else(|| {
                    format!("none of the declared system commands is on PATH: {commands:?}")
                })?
        }
        "runtime" => {
            let tool = launch["tool"]
                .as_str()
                .ok_or("runtime launch has no tool")?;
            let path = match launch["packagedRuntime"].as_str() {
                Some(packaged) => {
                    let path = verified_packaged_path(&package.root, packaged)?;
                    prepend_path(
                        &mut environment,
                        path.parent().unwrap_or(package.root.as_path()),
                    );
                    path
                }
                None => {
                    let path_env = std::env::var_os("PATH");
                    super::super::language_tools::find_system_tool(path_env.as_deref(), tool)
                        .ok_or_else(|| format!("runtime tool {tool} is not on PATH"))?
                }
            };
            environment.insert(
                format!("LITHE_{}_PATH", tool.to_uppercase().replace('-', "_")),
                path.to_string_lossy().to_string(),
            );
            verify_runtime_version(&path, tool, launch)?;
            path
        }
        other => return Err(format!("unsupported launch kind {other}")),
    };
    Ok(ResolvedLaunch {
        plugin_id: package.entry.plugin_id.clone(),
        language_id: language_id.to_string(),
        server_path: server_path.to_string_lossy().to_string(),
        server_args: string_arguments(&plan["arguments"]),
        initialization_options: plan
            .get("initializationOptions")
            .filter(|value| value.is_object())
            .cloned(),
        environment,
    })
}

/// Runs the tool's version probe and rejects a runtime older than the plan's
/// declared `minimumVersion`. Probes run at every launch because the PATH
/// candidate can change between sessions; a failing or unreadable probe is a
/// rejection, not a fallback.
fn verify_runtime_version(path: &Path, tool: &str, launch: &Value) -> Result<(), String> {
    let Some(minimum) = launch["minimumVersion"].as_str() else {
        return Ok(());
    };
    let version_arguments: Vec<String> = launch["versionArguments"]
        .as_array()
        .map(|items| {
            items
                .iter()
                .filter_map(|item| item.as_str().map(str::to_string))
                .collect()
        })
        .ok_or_else(|| {
            format!("runtime launch declares minimumVersion without versionArguments")
        })?;
    let output = std::process::Command::new(path)
        .args(&version_arguments)
        .output()
        .map_err(|error| format!("runtime tool {tool} could not be executed: {error}"))?;
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let reported = first_version_token(&text)
        .ok_or_else(|| format!("runtime tool {tool} did not report a parsable version"))?;
    if store::compare_versions(&reported, minimum) == std::cmp::Ordering::Less {
        return Err(format!(
            "runtime tool {tool} reports {reported}, but the plugin requires at least {minimum}"
        ));
    }
    Ok(())
}

/// First `N(.N)*` token in a version output line; tolerates the `v` prefix
/// node uses and the multi-line `java -version` output.
fn first_version_token(text: &str) -> Option<String> {
    for line in text.lines() {
        for token in line.split_whitespace() {
            // Strip quotes and any non-digit prefix (`v20.11.0`,
            // `go1.21.5`, `"17.0.2"`).
            let token = token
                .trim_matches(['"', '\''])
                .trim_start_matches(|character: char| !character.is_ascii_digit());
            let mut candidate = String::new();
            for character in token.chars() {
                if character.is_ascii_digit() || character == '.' {
                    candidate.push(character);
                } else {
                    break;
                }
            }
            // At least two chunks with a digit each make a version.
            if candidate.matches('.').count() >= 1
                && candidate
                    .split('.')
                    .any(|chunk| chunk.parse::<u64>().is_ok())
            {
                return Some(candidate);
            }
        }
    }
    None
}

/// Joins a package-relative plan path and proves it stays inside the package
/// as a regular file. Every launch the host executes passes through here.
fn verified_packaged_path(root: &Path, relative: &str) -> Result<PathBuf, String> {
    let candidate = root.join(relative);
    let metadata = std::fs::symlink_metadata(&candidate).map_err(|error| {
        format!(
            "packaged entry {} is unreadable: {error}",
            candidate.display()
        )
    })?;
    #[cfg(windows)]
    if metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
        return Err(format!(
            "packaged entry {} is a reparse point",
            candidate.display()
        ));
    }
    #[cfg(not(windows))]
    if metadata.file_type().is_symlink() {
        return Err(format!(
            "packaged entry {} is a symbolic link",
            candidate.display()
        ));
    }
    if !metadata.is_file() {
        return Err(format!(
            "packaged entry {} is not a regular file",
            candidate.display()
        ));
    }
    let canonical_root = root
        .canonicalize()
        .map_err(|error| format!("package root {} is unreadable: {error}", root.display()))?;
    let canonical = candidate.canonicalize().map_err(|error| {
        format!(
            "packaged entry {} is unreadable: {error}",
            candidate.display()
        )
    })?;
    if !canonical.starts_with(&canonical_root) {
        return Err(format!(
            "packaged entry {} escapes the package directory",
            candidate.display()
        ));
    }
    // Plan-relative paths use `/`; report the resolved path with the
    // platform separator so frontend logs and spawns see one canonical form.
    #[cfg(windows)]
    let candidate = PathBuf::from(candidate.to_string_lossy().replace('/', "\\"));
    Ok(candidate)
}

fn prepend_path(environment: &mut BTreeMap<String, String>, directory: &Path) {
    let existing = std::env::var("PATH").unwrap_or_default();
    let separator = if cfg!(windows) { ";" } else { ":" };
    environment.insert(
        "PATH".to_string(),
        format!("{}{separator}{existing}", directory.display()),
    );
}

fn string_arguments(value: &Value) -> Vec<String> {
    value
        .as_array()
        .map(|items| {
            items
                .iter()
                .filter_map(|item| item.as_str().map(str::to_string))
                .collect()
        })
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Unique per-run temp root; mirrors the temp-dir convention used by the
    /// other src-tauri tests (std::env::temp_dir + pid + timestamp).
    fn unique_temp_root(label: &str) -> PathBuf {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("system clock")
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "lithe-plugin-host-{label}-{}-{nanos}",
            std::process::id()
        ));
        std::fs::create_dir_all(&root).expect("temp root");
        root
    }

    fn package_with_root(root: PathBuf, manifest: Value) -> ScannedPackage {
        ScannedPackage {
            entry: super::super::CatalogEntry {
                plugin_id: "test.plugin".to_string(),
                display_name: "Test".to_string(),
                version: "1.0.0".to_string(),
                api_version: 1,
                source: "installed",
                enabled: true,
                status: "accepted",
                languages: Vec::new(),
                declared_settings: Vec::new(),
                primary_language_id: None,
                rejection: None,
            },
            root,
            manifest,
        }
    }

    fn php_like_manifest() -> Value {
        serde_json::json!({
            "languages": [
                { "id": "php", "displayName": "PHP", "fileExtensions": [".PHP", "php"] },
                { "id": "ini", "displayName": "INI", "fileNames": ["php.ini"] }
            ]
        })
    }

    #[test]
    fn languages_match_extensions_case_and_dot_insensitively() {
        let package = package_with_root(PathBuf::from("unused"), php_like_manifest());
        assert_eq!(owning_language_id(&package, r"C:\site\index.phtml"), None);
        assert_eq!(
            owning_language_id(&package, r"C:\site\Index.PHP").as_deref(),
            Some("php")
        );
        assert_eq!(owning_language_id(&package, r"C:\site\ini"), None);
        assert_eq!(
            owning_language_id(&package, r"C:\site\PHP.INI").as_deref(),
            Some("ini")
        );
    }

    #[test]
    fn first_version_token_parses_real_tool_outputs() {
        assert_eq!(
            first_version_token(
                "v20.11.0
"
            ),
            Some("20.11.0".to_string())
        );
        assert_eq!(
            first_version_token("openjdk version \"17.0.2\" 2022-01-18"),
            Some("17.0.2".to_string())
        );
        assert_eq!(
            first_version_token("go version go1.21.5 windows/amd64"),
            Some("1.21.5".to_string())
        );
        assert_eq!(first_version_token("no version here"), None);
    }

    #[test]
    fn version_comparison_is_numeric_per_chunk() {
        assert_eq!(
            store::compare_versions("1.10.0", "1.9.0"),
            std::cmp::Ordering::Greater
        );
        assert_eq!(
            store::compare_versions("2.0.0", "10.0.0"),
            std::cmp::Ordering::Less
        );
        assert_eq!(
            store::compare_versions("1.0.0-rc1", "1.0.0"),
            std::cmp::Ordering::Less
        );
        assert_eq!(
            store::compare_versions("1.0.0", "1.0.0"),
            std::cmp::Ordering::Equal
        );
    }

    #[test]
    fn workspace_state_keys_are_stable_and_distinct() {
        assert_eq!(
            store::workspace_state_key(r"D:\work\demo"),
            store::workspace_state_key(r"D:\work\demo")
        );
        assert_ne!(
            store::workspace_state_key(r"D:\work\demo"),
            store::workspace_state_key(r"D:\work\demo2")
        );
    }

    #[test]
    fn packaged_launches_resolve_inside_the_package() {
        let temporary = unique_temp_root("launch");
        let package_root = temporary.as_path().join("pkg");
        let server = package_root.join("bin").join("server.exe");
        std::fs::create_dir_all(server.parent().unwrap()).expect("bin dir");
        std::fs::write(&server, b"binary").expect("server file");
        let package = package_with_root(package_root.clone(), serde_json::json!({}));
        let plan = serde_json::json!({
            "launch": { "kind": "packaged", "path": "bin/server.exe" },
            "arguments": ["--stdio"]
        });
        let resolved = resolve_launch(&package, "php", &plan).expect("resolves");
        assert_eq!(resolved.server_path, server.to_string_lossy());
        assert_eq!(resolved.server_args, vec!["--stdio".to_string()]);
        assert_eq!(resolved.initialization_options, None);

        std::fs::write(temporary.as_path().join("outside.exe"), b"x").expect("outside file");
        let escape_plan = serde_json::json!({
            "launch": { "kind": "packaged", "path": "../outside.exe" },
            "arguments": []
        });
        assert!(resolve_launch(&package, "php", &escape_plan).is_err());
    }

    #[test]
    fn runtime_launches_export_the_tool_path_and_prepend_the_runtime_directory() {
        let temporary = unique_temp_root("launch");
        let package_root = temporary.as_path().join("pkg");
        let runtime = package_root.join("runtime").join("java.exe");
        std::fs::create_dir_all(runtime.parent().unwrap()).expect("runtime dir");
        std::fs::write(&runtime, b"jvm").expect("runtime file");
        let package = package_with_root(package_root, serde_json::json!({}));
        let plan = serde_json::json!({
            "launch": {
                "kind": "runtime",
                "tool": "java",
                "packagedRuntime": "runtime/java.exe",
                "entry": "server.jar"
            },
            "arguments": ["-jar", "server.jar"]
        });
        let resolved = resolve_launch(&package, "java", &plan).expect("resolves");
        assert_eq!(resolved.server_path, runtime.to_string_lossy());
        assert_eq!(
            resolved.environment.get("LITHE_JAVA_PATH"),
            Some(&runtime.to_string_lossy().to_string())
        );
        let path = resolved.environment.get("PATH").expect("PATH export");
        assert!(path.starts_with(&format!(
            "{};",
            temporary.as_path().join("pkg").join("runtime").display()
        )));
    }
}
