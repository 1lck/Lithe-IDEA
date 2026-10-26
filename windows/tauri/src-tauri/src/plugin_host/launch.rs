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
use std::cell::Cell;
use std::collections::BTreeMap;
use std::path::Path;
use std::path::PathBuf;
use std::process::Command;
use std::time::{Duration, Instant};
use tauri::{AppHandle, Manager, WebviewWindow};

/// Windows reparse-point attribute; covers symlinks and junctions alike.
#[cfg(windows)]
const FILE_ATTRIBUTE_REPARSE_POINT: u32 = 0x0400;

/// Runtime version probes are untrusted package-selected executables. Keep
/// both their lifetime and captured output bounded before handing the text to
/// Core's shared version parser.
const RUNTIME_PROBE_TIMEOUT: Duration = Duration::from_secs(5);
const MAX_RUNTIME_PROBE_OUTPUT_BYTES: usize = 64 * 1024;

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
    /// Expanded configuration provided to the server at session start.
    pub workspace_configuration: Option<Value>,
    /// Extra process environment (PATH prepends and LITHE_* exports).
    pub environment: BTreeMap<String, String>,
}

/// Resolves the launch plan of the enabled declarative plugin that owns
/// `file_path`, or `None` when no accepted plugin claims the file.
#[tauri::command]
pub fn declarative_plugins_language_launch(
    app: AppHandle,
    window: WebviewWindow,
    file_path: String,
    workspace_path: String,
) -> Result<Option<ResolvedLaunch>, String> {
    let Some(package) = owning_package(&app, &file_path) else {
        return Ok(None);
    };
    let _native_launch = app
        .state::<super::lifecycle::LifecycleState>()
        .acquire(&package.entry.plugin_id)?;
    let package = verified_package_by_id(&app, &package.entry.plugin_id)?;
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
    // Core wraps the plan in `{status, plan}`; resolve the inner value.
    let resolved_plan = &plan["plan"];
    let workspace_state_directory =
        state_directory.join(store::workspace_state_key(&workspace_path));
    prepare_required_directories(resolved_plan, &state_directory, &workspace_state_directory)?;
    std::fs::create_dir_all(&state_directory).map_err(|error| error.to_string())?;
    let resolved = resolve_launch(&package, &language_id, resolved_plan, &state_directory)?;
    super::provider::remember_language_launch(
        &app,
        window.label(),
        &workspace_path,
        &package,
        &resolved,
    )?;
    Ok(Some(resolved))
}

/// Finds an accepted, enabled scanned package by plugin ID.
pub(crate) fn package_by_id(app: &AppHandle, plugin_id: &str) -> Option<ScannedPackage> {
    if app
        .state::<super::lifecycle::LifecycleState>()
        .blocked(plugin_id)
    {
        return None;
    }
    app.state::<super::PluginHostState>()
        .packages()
        .into_iter()
        .find(|package| {
            package.entry.status == "accepted"
                && package.entry.enabled
                && package.entry.plugin_id == plugin_id
        })
}

/// Finds an accepted package by plugin ID and re-verifies its trust against
/// the live bytes before anything is launched: the pinned signature policy,
/// the origin, and the recorded content digest must hold for the files on
/// disk right now. Every process-starting entry (language launch, run plan,
/// test plan) goes through here, so a package tampered after the scan is
/// refused at launch instead of being started once.
pub(crate) fn verified_package_by_id(
    app: &AppHandle,
    plugin_id: &str,
) -> Result<ScannedPackage, String> {
    let package = package_by_id(app, plugin_id)
        .ok_or_else(|| format!("{plugin_id} is not an accepted declarative plugin"))?;
    let trust = package
        .trust
        .as_ref()
        .expect("accepted packages carry trust evidence");
    // Bundled packages must still sit inside the real resource root; the
    // launch path re-proves the seal instead of trusting the scan's word.
    let bundled_root = store::bundled_root(app).ok();
    super::signature::verify_for_origin(
        &package.root,
        &package.entry.plugin_id,
        &package.entry.version,
        &package.manifest,
        trust.origin,
        trust.expected_content_digest.as_deref(),
        bundled_root.as_deref(),
        &super::signature::trusted_keys(),
    )
    .map_err(|error| format!("{} trust check failed: {}", plugin_id, error.message()))?;
    Ok(package)
}

/// Returns the enabled declarative plugin that owns a file, for the run and
/// test entry points. Mirrors the launch path's ownership matching without
/// expanding a plan.
#[tauri::command]
pub fn declarative_plugins_language_owner(app: AppHandle, file_path: String) -> Option<OwnerInfo> {
    let package = owning_package(&app, &file_path)?;
    Some(OwnerInfo {
        plugin_id: package.entry.plugin_id.clone(),
        display_name: package.entry.display_name.clone(),
        language_id: owning_language_id(&package, &file_path)?,
    })
}

/// Ownership answer for run/test entry points.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OwnerInfo {
    pub plugin_id: String,
    pub display_name: String,
    pub language_id: String,
}

fn owning_package(app: &AppHandle, file_path: &str) -> Option<ScannedPackage> {
    app.state::<super::PluginHostState>()
        .packages()
        .into_iter()
        .find(|package| {
            !app.state::<super::lifecycle::LifecycleState>()
                .blocked(&package.entry.plugin_id)
                && package_matches_file(package, file_path)
        })
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
pub(crate) fn launch_request(
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

/// Creates the host-owned directories requested by Core before the frontend
/// starts the process. The plan only names the two directories from the
/// shared contract; arbitrary paths are rejected at this boundary.
pub(crate) fn prepare_required_directories(
    plan: &Value,
    state_directory: &Path,
    workspace_state_directory: &Path,
) -> Result<(), String> {
    let Some(required) = plan.get("requiredDirectories") else {
        return Ok(());
    };
    let required = required
        .as_array()
        .ok_or("launch plan requiredDirectories is not an array")?;
    for directory in required {
        let path = match directory.as_str() {
            Some("state") => state_directory,
            Some("workspaceState") => workspace_state_directory,
            Some(other) => {
                return Err(format!(
                    "launch plan requested an unknown directory {other}"
                ));
            }
            None => return Err("launch plan requiredDirectories contains a non-string".to_string()),
        };
        std::fs::create_dir_all(path).map_err(|error| {
            format!(
                "could not create launch directory {}: {error}",
                path.display()
            )
        })?;
    }
    Ok(())
}

pub(crate) fn resolve_launch(
    package: &ScannedPackage,
    language_id: &str,
    plan: &Value,
    probe_directory: &Path,
) -> Result<ResolvedLaunch, String> {
    for relative in string_arguments(&plan["requiredPackagePaths"]) {
        verified_package_resource(&package.root, &relative)?;
    }
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
            let key = format!("LITHE_{}_PATH", tool.to_uppercase().replace('-', "_"));
            let path = if let Some(packaged) = launch["packagedRuntime"].as_str() {
                // Packaged runtimes are fixed by the approved package.
                verified_packaged_path(&package.root, packaged)?
            } else if let Some(explicit) = std::env::var_os(&key).filter(|value| !value.is_empty())
            {
                PathBuf::from(explicit)
            } else {
                super::super::language_tools::find_system_tool(
                    std::env::var_os("PATH").as_deref(),
                    tool,
                )
                .ok_or_else(|| format!("runtime tool {tool} is not on PATH"))?
            };
            if !path.is_absolute() || !path.is_file() {
                return Err(format!(
                    "runtime {tool} must name an absolute executable file"
                ));
            }
            if let Some(directory) = path.parent() {
                prepend_path(&mut environment, directory);
            }
            environment.insert(key, path.to_string_lossy().to_string());
            verify_runtime_version(&path, tool, launch, probe_directory)?;
            path
        }
        other => return Err(format!("unsupported launch kind {other}")),
    };
    for requirement in plan["runtimeRequirements"].as_array().into_iter().flatten() {
        let tool = requirement["tool"]
            .as_str()
            .ok_or("runtime requirement has no tool")?;
        let key = format!("LITHE_{}_PATH", tool.to_uppercase().replace('-', "_"));
        // Explicit user exports take precedence; project-local runtimes are
        // never selected by PATH discovery for automatic server starts.
        let path = std::env::var_os(&key)
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
            .or_else(|| environment.get(&key).map(PathBuf::from))
            .or_else(|| {
                super::super::language_tools::find_system_tool(
                    std::env::var_os("PATH").as_deref(),
                    tool,
                )
            })
            .ok_or_else(|| format!("required runtime {tool} is unavailable"))?;
        if !path.is_absolute() || !path.is_file() {
            return Err(format!(
                "runtime {tool} must name an absolute executable file"
            ));
        }
        let mut version = requirement.clone();
        version["versionArguments"] = serde_json::json!(if tool == "java" {
            vec!["-version"]
        } else {
            vec!["--version"]
        });
        verify_runtime_version(&path, tool, &version, probe_directory)?;
        environment.insert(key, path.to_string_lossy().into_owned());
        if let Some(directory) = path.parent() {
            prepend_path(&mut environment, directory);
        }
    }
    let validation = string_arguments(&plan["validationArguments"]);
    if !validation.is_empty() {
        let mut command = Command::new(&server_path);
        command
            .args(&validation)
            .envs(&environment)
            .current_dir(probe_directory);
        run_process_probe(&mut command, "language server validation", true)?;
    }
    Ok(ResolvedLaunch {
        plugin_id: package.entry.plugin_id.clone(),
        language_id: language_id.to_string(),
        server_path: server_path.to_string_lossy().to_string(),
        server_args: string_arguments(&plan["arguments"]),
        initialization_options: plan
            .get("initializationOptions")
            .filter(|value| value.is_object())
            .cloned(),
        workspace_configuration: plan
            .get("workspaceConfiguration")
            .filter(|value| value.is_object())
            .cloned(),
        environment,
    })
}

/// Runs the tool's version probe and rejects a runtime older than the plan's
/// declared `minimumVersion`. Probes run at every launch because the PATH
/// candidate can change between sessions; a failing or unreadable probe is a
/// rejection, not a fallback.
fn verify_runtime_version(
    path: &Path,
    tool: &str,
    launch: &Value,
    probe_directory: &Path,
) -> Result<(), String> {
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
    let output = bounded_version_probe(path, &version_arguments, tool, probe_directory)?;
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&output.0),
        String::from_utf8_lossy(&output.1)
    );
    // Version parsing and comparison are Core semantics (shared
    // runtime-versions fixtures); the host only runs the probe and forwards
    // the output.
    let check = super::scan::core_execute(
        "plugins.declarative.checkRuntimeVersion",
        serde_json::json!({
            "tool": tool,
            "minimumVersion": minimum,
            "output": text,
        }),
    )
    .map_err(|error| format!("runtime version check failed: {error}"))?;
    if check["status"] == serde_json::json!("rejected") {
        return Err(format!(
            "runtime tool {tool}: {}",
            check["error"]["message"]
                .as_str()
                .unwrap_or("version check failed")
        ));
    }
    if check["check"]["satisfied"] == serde_json::json!(false) {
        return Err(format!(
            "runtime tool {tool}: {}",
            check["check"]["reason"]
                .as_str()
                .unwrap_or("the runtime does not satisfy the required minimum version")
        ));
    }
    Ok(())
}

/// Reuses the native executor's Job Object, nonblocking pipes and bounded
/// process-tree cleanup. The deadline covers pipe draining after parent exit;
/// package-selected background helpers cannot keep an LSP launch waiting.
fn bounded_version_probe(
    path: &Path,
    arguments: &[String],
    tool: &str,
    probe_directory: &Path,
) -> Result<(Vec<u8>, Vec<u8>), String> {
    let mut command = Command::new(path);
    command.args(arguments).current_dir(probe_directory);
    run_version_probe(&mut command, tool)
}

fn run_version_probe(command: &mut Command, tool: &str) -> Result<(Vec<u8>, Vec<u8>), String> {
    run_process_probe(command, tool, false)
}

fn run_process_probe(
    command: &mut Command,
    tool: &str,
    require_success: bool,
) -> Result<(Vec<u8>, Vec<u8>), String> {
    let deadline = Instant::now() + RUNTIME_PROBE_TIMEOUT;
    let stdout_bytes = Cell::new(0_usize);
    let stderr_bytes = Cell::new(0_usize);
    let exceeded = || {
        stdout_bytes.get() > MAX_RUNTIME_PROBE_OUTPUT_BYTES
            || stderr_bytes.get() > MAX_RUNTIME_PROBE_OUTPUT_BYTES
    };
    let outcome = lithe_git_host::run(
        command,
        None,
        || exceeded() || Instant::now() >= deadline,
        || {},
        |stream, bytes| {
            let count = match stream {
                lithe_git_host::Stream::Stdout => &stdout_bytes,
                lithe_git_host::Stream::Stderr => &stderr_bytes,
            };
            count.set(count.get().saturating_add(bytes.len()));
        },
    );
    if exceeded() {
        return Err(format!(
            "runtime tool {tool} version probe output exceeds {} bytes",
            MAX_RUNTIME_PROBE_OUTPUT_BYTES
        ));
    }
    if let Some(failure) = outcome.failure {
        return Err(format!(
            "runtime tool {tool} version probe failed or timed out: {failure:?}"
        ));
    }
    if require_success && outcome.status.is_none_or(|status| !status.success()) {
        return Err(format!("{tool} probe exited unsuccessfully"));
    }
    if outcome.status.is_none_or(|status| !status.success())
        && outcome.stdout.is_empty()
        && outcome.stderr.is_empty()
    {
        return Err(format!(
            "runtime tool {tool} version probe exited without version output"
        ));
    }
    Ok((outcome.stdout, outcome.stderr))
}

/// Joins a package-relative plan path and proves it stays inside the package
/// as a regular file. Every launch the host executes passes through here.
fn verified_packaged_path(root: &Path, relative: &str) -> Result<PathBuf, String> {
    let candidate = verified_package_resource(root, relative)?;
    if !candidate.is_file() {
        return Err(format!(
            "packaged entry {} is not a regular file",
            candidate.display()
        ));
    }
    Ok(candidate)
}

/// Required resources may be files or directories. Canonical containment and
/// reparse checks apply before the process starts, including runtime entry files.
fn verified_package_resource(root: &Path, relative: &str) -> Result<PathBuf, String> {
    let relative_path = Path::new(relative);
    if relative_path.is_absolute()
        || relative_path.components().any(|part| {
            matches!(
                part,
                std::path::Component::ParentDir | std::path::Component::Prefix(_)
            )
        })
    {
        return Err("required package resource must stay inside the package".into());
    }
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
    if !metadata.is_file() && !metadata.is_dir() {
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
    let existing = environment
        .get("PATH")
        .cloned()
        .unwrap_or_else(|| std::env::var("PATH").unwrap_or_default());
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

    /// Child-only fixture: environment is attached to Command, never mutated
    /// in the test runner. Its libtest entry is also the executable on CI.
    #[test]
    #[ignore = "launched by runtime probe regression tests"]
    fn version_probe_fixture() {
        use std::io::Write;
        match std::env::var("LITHE_PROBE_FIXTURE").as_deref() {
            Ok("output") => println!("v21.0.0"),
            Ok("failure-output") => {
                println!("version text cannot mask probe failure");
                std::process::exit(7);
            }
            Ok("overflow") => {
                std::io::stdout()
                    .write_all(&vec![b'x'; MAX_RUNTIME_PROBE_OUTPUT_BYTES + 1])
                    .unwrap();
            }
            Ok("parent") => {
                let mut command = probe_fixture_command("hold-pipes");
                command.stdin(std::process::Stdio::null());
                command.spawn().expect("inheriting helper");
                println!("v21.0.0");
            }
            Ok("hold-pipes") => {
                let marker = std::env::var("LITHE_PROBE_MARKER").expect("marker path");
                std::fs::write(marker, std::process::id().to_string()).expect("record helper");
                // The helper's guard only prevents a leaked fixture from living
                // forever; the production Job Object must terminate it first.
                let (_sender, receiver) = std::sync::mpsc::channel::<()>();
                let _ = receiver.recv_timeout(Duration::from_secs(30));
            }
            _ => panic!("fixture requires a scoped child environment"),
        }
    }

    fn probe_fixture_command(mode: &str) -> Command {
        let mut command = Command::new(std::env::current_exe().expect("test executable"));
        command
            .args([
                "--exact",
                "plugin_host::launch::tests::version_probe_fixture",
                "--ignored",
                "--nocapture",
            ])
            .env("LITHE_PROBE_FIXTURE", mode);
        command
    }

    #[test]
    fn runtime_probe_collects_output_and_rejects_overflow() {
        let output =
            run_version_probe(&mut probe_fixture_command("output"), "fixture").expect("probe");
        assert!(String::from_utf8_lossy(&output.0).contains("v21.0.0"));
        let error =
            run_version_probe(&mut probe_fixture_command("overflow"), "fixture").unwrap_err();
        assert!(error.contains("output exceeds"), "{error}");
    }

    #[test]
    #[cfg(windows)]
    fn runtime_probe_reclaims_inherited_pipes_after_parent_exit() {
        struct TempRoot(PathBuf);
        impl Drop for TempRoot {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
        let root = TempRoot(unique_temp_root("inherited-pipes"));
        let marker = root.0.join("helper.pid");
        let mut command = probe_fixture_command("parent");
        command.env("LITHE_PROBE_MARKER", &marker);
        let began = Instant::now();
        let error = run_version_probe(&mut command, "fixture").unwrap_err();
        assert!(
            began.elapsed() < RUNTIME_PROBE_TIMEOUT + Duration::from_secs(3),
            "{error}"
        );
        let pid: u32 = std::fs::read_to_string(marker)
            .expect("helper started")
            .parse()
            .unwrap();
        // The parent is already gone: a PID walk could no longer own this helper.
        // Opening a terminated process may still succeed while the kernel reaps it.
        use windows_sys::Win32::{
            Foundation::CloseHandle,
            System::Threading::{OpenProcess, WaitForSingleObject, PROCESS_SYNCHRONIZE},
        };
        unsafe {
            let handle = OpenProcess(PROCESS_SYNCHRONIZE, 0, pid);
            if !handle.is_null() {
                let waited = WaitForSingleObject(handle, 1000);
                CloseHandle(handle);
                assert_eq!(waited, 0, "version helper survived process-tree cleanup");
            }
        }
    }

    /// The child receives explicit runtime configuration without changing the
    /// test runner's environment or depending on its installed PATH tools.
    #[test]
    fn runtime_launch_uses_the_same_explicit_executable_as_its_dependency() {
        let executable = std::env::current_exe().unwrap();
        let mut command = Command::new(&executable);
        command
            .args([
                "--exact",
                "plugin_host::launch::tests::explicit_runtime_fixture",
                "--ignored",
                "--nocapture",
            ])
            .env("LITHE_NODE_PATH", &executable);
        run_process_probe(&mut command, "explicit runtime fixture", true).unwrap();
    }

    #[test]
    #[ignore = "launched with a scoped runtime export by the regression test"]
    fn explicit_runtime_fixture() {
        struct TempRoot(PathBuf);
        impl Drop for TempRoot {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
        let root = TempRoot(unique_temp_root("explicit-runtime"));
        std::fs::write(root.0.join("fallback.exe"), b"must not execute").unwrap();
        let package = package_with_root(root.0.clone(), serde_json::json!({}));
        let plan = serde_json::json!({
            "launch": {"kind":"runtime", "tool":"node"},
            "runtimeRequirements":[{"tool":"node"}]
        });
        let resolved = resolve_launch(&package, "test", &plan, &package.root).unwrap();
        let executable = std::env::current_exe()
            .unwrap()
            .to_string_lossy()
            .into_owned();
        assert_eq!(resolved.server_path, executable);
        assert_eq!(resolved.environment["LITHE_NODE_PATH"], executable);
        let mut packaged = plan.clone();
        packaged["launch"]["packagedRuntime"] = serde_json::json!("fallback.exe");
        packaged["runtimeRequirements"] = serde_json::json!([]);
        let resolved = resolve_launch(&package, "test", &packaged, &package.root).unwrap();
        let expected = verified_packaged_path(&package.root, "fallback.exe")
            .unwrap()
            .to_string_lossy()
            .into_owned();
        assert_eq!(resolved.server_path, expected);
        assert_eq!(resolved.environment["LITHE_NODE_PATH"], expected);
    }

    #[test]
    fn validation_requires_zero_exit_even_when_probe_prints_output() {
        run_process_probe(&mut probe_fixture_command("output"), "validation", true).unwrap();
        let error = run_process_probe(
            &mut probe_fixture_command("failure-output"),
            "validation",
            true,
        )
        .unwrap_err();
        assert!(error.contains("unsuccessfully"), "{error}");
    }

    #[test]
    fn launch_rejects_missing_required_resources_and_runtime_dependencies() {
        struct TempRoot(PathBuf);
        impl Drop for TempRoot {
            fn drop(&mut self) {
                let _ = std::fs::remove_dir_all(&self.0);
            }
        }
        let root = TempRoot(unique_temp_root("requirements"));
        std::fs::write(root.0.join("server.exe"), b"fixture").unwrap();
        let package = package_with_root(root.0.clone(), serde_json::json!({}));
        let mut plan = serde_json::json!({ "launch": {"kind": "packaged", "path": "server.exe"}, "requiredPackagePaths": ["missing.js"] });
        assert!(resolve_launch(&package, "test", &plan, &package.root)
            .unwrap_err()
            .contains("missing.js"));
        plan["requiredPackagePaths"] = serde_json::json!([]);
        plan["runtimeRequirements"] =
            serde_json::json!([{ "tool": "lithe-fixture-absent-runtime-9416" }]);
        assert!(resolve_launch(&package, "test", &plan, &package.root)
            .unwrap_err()
            .contains("required runtime"));
        std::fs::create_dir(root.0.join("resources")).unwrap();
        assert!(verified_package_resource(&root.0, "resources").is_ok());
        assert!(verified_packaged_path(&root.0, "resources").is_err());
        assert!(verified_package_resource(&root.0, "../escape").is_err());
    }

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
                declares_tests: false,
                primary_language_id: None,
                rejection: None,
            },
            root,
            manifest,
            trust: None,
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

    /// Version judgment goes through Core's checkRuntimeVersion: outputs the
    /// shared fixtures accept (a `java -version` banner line before the
    /// version, an `openjdk 25` two-part version) are judged by Core, not by
    /// host parsing.
    #[test]
    fn version_check_delegates_to_core_semantics() {
        let check = super::super::scan::core_execute(
            "plugins.declarative.checkRuntimeVersion",
            serde_json::json!({
                "tool": "java",
                "minimumVersion": "21",
                "output": "Picked up JAVA_TOOL_OPTIONS: -Dapp.version=99.0\nopenjdk version \"25\" 2026-09-16",
            }),
        )
        .expect("core check executes");
        assert_eq!(check["status"], "ok", "{check}");
        assert_eq!(check["check"]["satisfied"], true);

        let stale = super::super::scan::core_execute(
            "plugins.declarative.checkRuntimeVersion",
            serde_json::json!({
                "tool": "java",
                "minimumVersion": "21",
                "output": "openjdk version \"17.0.2\" 2022-01-18",
            }),
        )
        .expect("core check executes");
        assert_eq!(stale["check"]["satisfied"], false);
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
    fn required_launch_directories_are_created_from_contract_names() {
        let temporary = unique_temp_root("required-directories");
        let state = temporary.join("state");
        let workspace = state.join("workspace");
        let plan = serde_json::json!({
            "requiredDirectories": ["state", "workspaceState"]
        });
        prepare_required_directories(&plan, &state, &workspace).expect("directories created");
        assert!(state.is_dir());
        assert!(workspace.is_dir());
        assert!(prepare_required_directories(
            &serde_json::json!({ "requiredDirectories": ["arbitrary"] }),
            &state,
            &workspace,
        )
        .is_err());
        let _ = std::fs::remove_dir_all(&temporary);
    }

    #[test]
    fn resolve_launch_consumes_the_real_core_response_envelope() {
        let temporary = unique_temp_root("launch-envelope");
        let package_root = temporary.as_path().join("pkg");
        let server = package_root.join("bin").join("server.exe");
        std::fs::create_dir_all(server.parent().unwrap()).expect("bin dir");
        std::fs::write(&server, b"binary").expect("server file");
        // The bundled fixture is API 1 (no settings requirement) with a
        // packaged launch, so a real plan request succeeds.
        let mut manifest = crate::plugin_host::tests::read_fixture_for_tests(
            "language-packaged-server.plugin.json",
        );
        manifest["languageServers"][0]["launch"] = serde_json::json!({
            "kind": "packaged",
            "path": "bin/server.exe"
        });
        let package = package_with_root(package_root, manifest);
        let response = super::super::scan::core_execute(
            "plugins.declarative.languageServerLaunchPlan",
            serde_json::json!({
                "manifest": package.manifest,
                "languageID": "php",
                "request": launch_request(
                    &temporary.as_path().join("state"),
                    &package,
                    &temporary.as_path().to_string_lossy(),
                    crate::plugin_host::settings::SettingLayers {
                        global: Default::default(),
                        project: Default::default(),
                    },
                ),
            }),
        )
        .expect("real Core command executes");
        assert_eq!(response["status"], "ok", "{response}");
        // The production path passes the wrapped outcome; only the inner
        // plan carries the launch.
        let resolved =
            resolve_launch(&package, "php", &response["plan"], &package.root).expect("resolves");
        assert_eq!(resolved.server_path, server.to_string_lossy());
        let _ = std::fs::remove_dir_all(&temporary);
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
        let resolved = resolve_launch(&package, "php", &plan, &package.root).expect("resolves");
        assert_eq!(resolved.server_path, server.to_string_lossy());
        assert_eq!(resolved.server_args, vec!["--stdio".to_string()]);
        assert_eq!(resolved.initialization_options, None);

        std::fs::write(temporary.as_path().join("outside.exe"), b"x").expect("outside file");
        let escape_plan = serde_json::json!({
            "launch": { "kind": "packaged", "path": "../outside.exe" },
            "arguments": []
        });
        assert!(resolve_launch(&package, "php", &escape_plan, &package.root).is_err());
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
        let resolved = resolve_launch(&package, "java", &plan, &package.root).expect("resolves");
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
