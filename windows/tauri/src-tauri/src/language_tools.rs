//! Windows host commands that install and resolve managed language-tool
//! executables for frontend language extensions.
//!
//! Bun-runtime language servers (Intelephense, typescript-language-server,
//! Pyright) are npm packages: this host installs them into a Lithe-owned
//! directory with the user's bun and reports the absolute launcher path so the
//! shared Core can spawn the server process directly. Tool installation and
//! PATH probing are platform process/filesystem behavior, so they live in the
//! Tauri host instead of `lithe-core`.

use serde::Deserialize;
use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Manager};

const INSTALL_TIMEOUT: Duration = Duration::from_secs(600);
const CAPTURED_OUTPUT_LIMIT: usize = 4_000;
const TOOL_TYPES: [&str; 3] = ["lsp", "formatter", "linter"];

/// Mirrors `BackendToolRuntime` in `extension-store-runtime.ts`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "lowercase")]
enum ToolRuntime {
    Bun,
    Node,
    Python,
    Go,
    Rust,
    Ruby,
    R,
    System,
    Binary,
}

/// Mirrors `BackendToolConfig` in `extension-store-runtime.ts`; extra manifest
/// fields (downloadUrl, args, env) are intentionally ignored here.
#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
struct LanguageToolConfig {
    name: String,
    command: Option<String>,
    runtime: ToolRuntime,
    package: Option<String>,
    #[serde(default)]
    packages: Vec<String>,
}

impl LanguageToolConfig {
    /// The launcher file name the npm package exposes in `node_modules/.bin`.
    fn executable_name(&self) -> &str {
        self.command
            .as_deref()
            .map(str::trim)
            .filter(|name| !name.is_empty())
            .unwrap_or(self.name.as_str())
    }

    /// Ordered, de-duplicated npm package list: `package` plus `packages`.
    fn npm_packages(&self) -> Vec<String> {
        let mut packages = Vec::new();
        if let Some(package) = self.package.as_deref().map(str::trim) {
            if !package.is_empty() {
                packages.push(package.to_string());
            }
        }
        for package in &self.packages {
            let package = package.trim();
            if !package.is_empty() && !packages.iter().any(|existing| existing == package) {
                packages.push(package.to_string());
            }
        }
        packages
    }
}

#[derive(Default)]
struct InstallTask {
    cancelled: AtomicBool,
    finished: AtomicBool,
}

fn install_tasks() -> &'static Mutex<HashMap<String, Arc<InstallTask>>> {
    static TASKS: OnceLock<Mutex<HashMap<String, Arc<InstallTask>>>> = OnceLock::new();
    TASKS.get_or_init(|| Mutex::new(HashMap::new()))
}

struct InstallGuard(String, Arc<InstallTask>);
impl Drop for InstallGuard {
    fn drop(&mut self) {
        self.1.finished.store(true, Ordering::Release);
        if let Ok(mut tasks) = install_tasks().lock() {
            tasks.remove(&self.0);
        }
    }
}

pub fn shutdown() {
    if let Ok(tasks) = install_tasks().lock() {
        for task in tasks.values() {
            task.cancelled.store(true, Ordering::Release);
        }
    }
}

/// Cancels owned installs and waits for the bounded native cleanup to complete.
#[tauri::command]
pub async fn cancel_language_tool_install(language_id: String) -> Result<(), String> {
    let task = install_tasks()
        .lock()
        .map_err(|_| "Install state unavailable")?
        .get(&language_id)
        .cloned();
    if let Some(task) = task {
        task.cancelled.store(true, Ordering::Release);
        let deadline = Instant::now() + Duration::from_secs(10);
        while !task.finished.load(Ordering::Acquire) {
            if Instant::now() >= deadline {
                return Err("Language tool cleanup timed out".into());
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }
    Ok(())
}

/// Removes only this language's Lithe-owned cache, never global installations.
#[tauri::command]
pub async fn uninstall_language_tools(app: AppHandle, language_id: String) -> Result<(), String> {
    cancel_language_tool_install(language_id.clone()).await?;
    if language_id.is_empty()
        || sanitize_path_component(&language_id) != language_id
        || language_id == "."
        || language_id == ".."
    {
        return Err("Invalid language identifier".into());
    }
    let task = Arc::new(InstallTask::default());
    {
        let mut tasks = install_tasks()
            .lock()
            .map_err(|_| "Install state unavailable")?;
        if tasks.contains_key(&language_id) {
            return Err("Language tools changed during uninstall; retry".into());
        }
        tasks.insert(language_id.clone(), Arc::clone(&task));
    }
    let guard = InstallGuard(language_id.clone(), task);
    let directory = managed_tools_root(&app).join(language_id);
    tauri::async_runtime::spawn_blocking(move || {
        let _guard = guard;
        if directory.exists() {
            std::fs::remove_dir_all(directory)
                .map_err(|error| format!("Could not remove language tools: {error}"))?;
        }
        Ok(())
    })
    .await
    .map_err(|error| format!("Language tool cleanup task failed: {error}"))?
}

/// Resolves the absolute launcher path for one configured language tool.
///
/// Returns `Ok(None)` when the tool cannot be resolved on this machine; the
/// frontend treats null as "tool not available" and its repair path triggers
/// `install_language_tools`. Missing tools are an expected state, not a host
/// error, so no error is raised here.
#[tauri::command]
pub fn get_tool_path(
    app: AppHandle,
    language_id: String,
    tool_type: String,
    tools: Value,
) -> Result<Option<String>, String> {
    let config = match requested_tool_config(&tools, &tool_type) {
        Ok(config) => config,
        Err(error) => return Err(error),
    };
    let Some(config) = config else {
        return Ok(None);
    };
    if install_tasks()
        .lock()
        .map_err(|_| "Install state unavailable")?
        .contains_key(&language_id)
    {
        return Ok(None);
    }
    let path_env = std::env::var_os("PATH");
    // npm's Intelephense launcher needs Node even when Bun installed the package.
    if config.name == "intelephense" && find_system_tool(path_env.as_deref(), "node").is_none() {
        return Ok(None);
    }
    let resolved = match config.runtime {
        ToolRuntime::Bun => resolve_bun_tool_path(
            &language_id,
            &config,
            &managed_tools_root(&app),
            path_env.as_deref(),
            std::env::var_os("USERPROFILE").as_deref(),
        ),
        ToolRuntime::System => find_system_tool(path_env.as_deref(), config.executable_name()),
        // Runtimes without a Windows implementation stay unresolved here; the
        // install command reports the explicit failure for diagnostics.
        ToolRuntime::Node
        | ToolRuntime::Python
        | ToolRuntime::Go
        | ToolRuntime::Rust
        | ToolRuntime::Ruby
        | ToolRuntime::R
        | ToolRuntime::Binary => None,
    };
    Ok(resolved.map(|path| normalize_path(&path)))
}

/// Installs the configured language tools and reports a per-tool status map.
///
/// Status values are `"ok"` or `{ "Failed": "<message>" }`; the latter matches
/// `extractFailedToolMessage` in `extension-store-runtime.ts`. The command only
/// fails as a whole when the status map itself cannot be produced, so a single
/// broken tool never hides the state of the others.
#[tauri::command]
pub async fn install_language_tools(
    app: AppHandle,
    language_id: String,
    tools: Value,
) -> Result<Value, String> {
    let task = Arc::new(InstallTask::default());
    {
        let mut tasks = install_tasks()
            .lock()
            .map_err(|_| "Install state unavailable")?;
        if tasks.contains_key(&language_id) {
            return Err("Language tools are already being installed".into());
        }
        tasks.insert(language_id.clone(), Arc::clone(&task));
    }
    let guard = InstallGuard(language_id.clone(), Arc::clone(&task));
    tauri::async_runtime::spawn_blocking(move || {
        let _guard = guard;
        let path_env = std::env::var_os("PATH");
        let user_home = std::env::var_os("USERPROFILE");
        let tools_root = managed_tools_root(&app);
        let mut statuses = Map::new();
        for tool_type in TOOL_TYPES {
            let config = match requested_tool_config(&tools, tool_type) {
                Ok(config) => config,
                Err(error) => {
                    statuses.insert(tool_type.to_string(), json!({ "Failed": error }));
                    continue;
                }
            };
            let Some(config) = config else {
                continue;
            };
            let outcome = install_language_tool(
                &language_id,
                &config,
                &tools_root,
                path_env.as_deref(),
                user_home.as_deref(),
                &task.cancelled,
            );
            statuses.insert(
                tool_type.to_string(),
                match outcome {
                    Ok(()) => json!("ok"),
                    Err(error) => json!({ "Failed": error }),
                },
            );
        }
        Ok(Value::Object(statuses))
    })
    .await
    .map_err(|error| format!("Language tool install task failed: {error}"))?
}

fn requested_tool_config(
    tools: &Value,
    tool_type: &str,
) -> Result<Option<LanguageToolConfig>, String> {
    let Some(tool) = tools.get(tool_type) else {
        return Ok(None);
    };
    if tool.is_null() {
        return Ok(None);
    }
    serde_json::from_value(tool.clone())
        .map(Some)
        .map_err(|error| format!("The {tool_type} tool configuration is invalid: {error}"))
}

fn install_language_tool(
    language_id: &str,
    config: &LanguageToolConfig,
    tools_root: &Path,
    path_env: Option<&OsStr>,
    user_home: Option<&OsStr>,
    cancelled: &AtomicBool,
) -> Result<(), String> {
    match config.runtime {
        ToolRuntime::Bun => install_bun_tool(language_id, config, tools_root, path_env, user_home, cancelled),
        ToolRuntime::System => find_system_tool(path_env, config.executable_name())
            .map(|_| ())
            .ok_or_else(|| {
                format!(
                    "{} was not found in PATH. Install it and make sure it is on the PATH environment variable.",
                    config.executable_name()
                )
            }),
        ToolRuntime::Node | ToolRuntime::Python | ToolRuntime::Go | ToolRuntime::Rust
        | ToolRuntime::Ruby | ToolRuntime::R | ToolRuntime::Binary => Err(format!(
            "The {:?} runtime for {} is not supported by this Lithe Windows build yet.",
            config.runtime,
            config.executable_name()
        )),
    }
}

fn install_bun_tool(
    language_id: &str,
    config: &LanguageToolConfig,
    tools_root: &Path,
    path_env: Option<&OsStr>,
    user_home: Option<&OsStr>,
    cancelled: &AtomicBool,
) -> Result<(), String> {
    if cancelled.load(Ordering::Acquire) {
        return Err("Language tool installation cancelled".into());
    }
    if config.name == "intelephense" && find_system_tool(path_env, "node").is_none() {
        return Err("Intelephense requires Node.js on PATH. Install Node.js, then retry PHP Support installation.".into());
    }
    if resolve_bun_tool_path(language_id, config, tools_root, path_env, user_home).is_some() {
        return Ok(());
    }
    let packages = config.npm_packages();
    if packages.is_empty() {
        return Err(format!(
            "No npm package is configured for the {} language tool.",
            config.executable_name()
        ));
    }
    let bun = find_bun_executable(path_env, user_home).ok_or_else(|| {
        "bun was not found. Install bun (https://bun.sh) and make sure it is on the PATH environment variable."
            .to_string()
    })?;
    let tool_directory = managed_tool_directory(tools_root, language_id, &config.name);
    std::fs::create_dir_all(&tool_directory).map_err(|error| {
        format!(
            "Could not create the language tool directory {}: {error}",
            tool_directory.display()
        )
    })?;
    ensure_tool_package_json(&tool_directory)?;
    if let Err(error) = run_bun_add(&bun, &tool_directory, &packages, cancelled) {
        std::fs::remove_dir_all(&tool_directory)
            .map_err(|cleanup| format!("{error}; incomplete tool cleanup failed: {cleanup}"))?;
        return Err(error);
    }
    find_bun_tool_bin(&tool_directory, config.executable_name()).ok_or_else(|| {
        format!(
            "bun installed {} but no {} launcher was found under node_modules/.bin.",
            packages.join(", "),
            config.executable_name()
        )
    })?;
    std::fs::write(tool_directory.join(".lithe-install-complete"), b"1")
        .map_err(|error| format!("Could not record completed tool installation: {error}"))?;
    Ok(())
}

/// Resolves a bun tool launcher: the Lithe-managed install wins so the repair
/// path stays authoritative; the user's global bun bin and PATH follow as
/// fallbacks that reuse an existing installation instead of re-downloading it,
/// mirroring how macOS probes a user-owned server.
fn resolve_bun_tool_path(
    language_id: &str,
    config: &LanguageToolConfig,
    tools_root: &Path,
    path_env: Option<&OsStr>,
    user_home: Option<&OsStr>,
) -> Option<PathBuf> {
    let tool_directory = managed_tool_directory(tools_root, language_id, &config.name);
    if tool_directory.join(".lithe-install-complete").is_file() {
        if let Some(launcher) = find_bun_tool_bin(&tool_directory, config.executable_name()) {
            return Some(launcher);
        }
    }
    if let Some(home) = user_home {
        let global_bin = PathBuf::from(home).join(".bun").join("bin");
        if let Some(launcher) = first_existing(executable_candidates_in(
            &global_bin,
            config.executable_name(),
        )) {
            return Some(launcher);
        }
    }
    find_system_tool(path_env, config.executable_name())
}

fn ensure_tool_package_json(tool_directory: &Path) -> Result<(), String> {
    let package_json = tool_directory.join("package.json");
    if package_json.is_file() {
        return Ok(());
    }
    // `bun add` needs a manifest to record dependencies; the directory is
    // Lithe-owned, so a minimal private package is safe to write.
    let manifest = json!({
        "name": "lithe-language-tools",
        "private": true,
    });
    std::fs::write(
        &package_json,
        serde_json::to_vec_pretty(&manifest).map_err(|error| error.to_string())?,
    )
    .map_err(|error| format!("Could not write {}: {error}", package_json.display()))
}

/// Uses the existing native runner's Job Object/process group and bounded drain.
/// Cancellation is owned by the installing plugin; a deadline also handles a
/// stalled package manager without leaving inherited output pipes alive.
fn run_bun_add(
    bun: &Path,
    tool_directory: &Path,
    packages: &[String],
    cancelled: &AtomicBool,
) -> Result<(), String> {
    let deadline = Instant::now() + INSTALL_TIMEOUT;
    let mut command = Command::new(bun);
    command
        .arg("add")
        .arg("--production")
        .args(packages)
        .current_dir(tool_directory);
    let outcome = lithe_git_host::run(
        &mut command,
        None,
        || cancelled.load(Ordering::Acquire) || Instant::now() >= deadline,
        || {},
        |_, _| {},
    );
    if cancelled.load(Ordering::Acquire) {
        return Err("Language tool installation cancelled".into());
    }
    if Instant::now() >= deadline {
        return Err("Language tool installation timed out".into());
    }
    if let Some(failure) = outcome.failure {
        return Err(format!("Language tool install failed: {failure:?}"));
    }
    if outcome.status.is_some_and(|status| status.success()) {
        return Ok(());
    }
    let output = String::from_utf8_lossy(&outcome.stderr)
        .chars()
        .take(CAPTURED_OUTPUT_LIMIT)
        .collect::<String>();
    Err(format!("bun add failed. {output}"))
}

/// Probes a managed tool directory for a spawnable Windows launcher.
fn find_bun_tool_bin(tool_directory: &Path, name: &str) -> Option<PathBuf> {
    let bin_directory = tool_directory.join("node_modules").join(".bin");
    first_existing(executable_candidates_in(&bin_directory, name))
}

/// Locates bun itself: PATH first, then the default per-user install location
/// so a machine with bun on `%USERPROFILE%\.bun\bin` still resolves when that
/// directory is absent from the inherited PATH.
fn find_bun_executable(path_env: Option<&OsStr>, user_home: Option<&OsStr>) -> Option<PathBuf> {
    if let Some(path_env) = path_env {
        for directory in std::env::split_paths(path_env) {
            if let Some(bun) = first_existing(executable_candidates_in(&directory, "bun")) {
                return Some(bun);
            }
        }
    }
    let home = PathBuf::from(user_home?);
    first_existing(executable_candidates_in(
        &home.join(".bun").join("bin"),
        "bun",
    ))
}

/// Finds a system tool by probing every PATH directory. Only Windows launcher
/// extensions are accepted; a bare extensionless file is a POSIX script that
/// CreateProcess cannot execute.
fn find_system_tool(path_env: Option<&OsStr>, name: &str) -> Option<PathBuf> {
    let path_env = path_env?;
    for directory in std::env::split_paths(path_env) {
        if let Some(tool) = first_existing(executable_candidates_in(&directory, name)) {
            return Some(tool);
        }
    }
    None
}

fn executable_candidates_in(directory: &Path, name: &str) -> Vec<PathBuf> {
    [
        format!("{name}.exe"),
        format!("{name}.cmd"),
        format!("{name}.bat"),
    ]
    .into_iter()
    .map(|file_name| directory.join(file_name))
    .collect()
}

fn first_existing(candidates: Vec<PathBuf>) -> Option<PathBuf> {
    candidates.into_iter().find(|candidate| candidate.is_file())
}

fn managed_tools_root(app: &AppHandle) -> PathBuf {
    app.path()
        .app_cache_dir()
        .unwrap_or_else(|_| std::env::temp_dir().join("lithe-lsp"))
        .join("language-tools")
}

fn managed_tool_directory(tools_root: &Path, language_id: &str, tool_name: &str) -> PathBuf {
    tools_root
        .join(sanitize_path_component(language_id))
        .join(sanitize_path_component(tool_name))
}

/// Language IDs and tool names come from extension manifests; keep only
/// characters that are safe as a single Windows path component.
fn sanitize_path_component(component: &str) -> String {
    let sanitized = component
        .chars()
        .map(|character| {
            if character.is_ascii_alphanumeric() || matches!(character, '-' | '_' | '.') {
                character
            } else {
                '-'
            }
        })
        .collect::<String>();
    let trimmed = sanitized.trim_matches('-');
    if trimmed.is_empty() || trimmed.chars().all(|character| character == '.') {
        "tool".to_string()
    } else {
        trimmed.to_string()
    }
}

/// Tauri can return verbatim resource paths; keep the same normalized forward
/// slash form the Java language-server launch uses.
fn normalize_path(path: &Path) -> String {
    let path = path.to_string_lossy();
    if let Some(network_path) = path.strip_prefix(r"\\?\UNC\") {
        return format!("//{}", network_path.replace('\\', "/"));
    }
    path.strip_prefix(r"\\?\")
        .unwrap_or(path.as_ref())
        .replace('\\', "/")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::sync::atomic::{AtomicU64, Ordering};

    static TEST_TEMP_DIRECTORY_ID: AtomicU64 = AtomicU64::new(1);

    fn temp_dir(label: &str) -> PathBuf {
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("clock")
            .as_nanos();
        let id = TEST_TEMP_DIRECTORY_ID.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!("lithe-language-tools-{label}-{stamp}-{id}"));
        fs::create_dir_all(&path).expect("temp dir");
        path
    }

    fn tool_config(runtime: ToolRuntime, name: &str, package: &str) -> LanguageToolConfig {
        LanguageToolConfig {
            name: name.to_string(),
            command: None,
            runtime,
            package: Some(package.to_string()),
            packages: Vec::new(),
        }
    }

    #[test]
    fn cancelled_install_does_not_create_managed_directories() {
        let root = temp_dir("cancel-before-start");
        let config = tool_config(ToolRuntime::Bun, "intelephense", "intelephense");
        let error =
            install_language_tool("php", &config, &root, None, None, &AtomicBool::new(true))
                .expect_err("cancelled installation");
        assert!(error.contains("cancelled"));
        assert!(!root.join("php").exists());
        fs::remove_dir_all(root).expect("cleanup");
    }

    #[test]
    fn dot_only_identifiers_cannot_escape_managed_directories() {
        for input in [".", "..", "..."] {
            assert_eq!(sanitize_path_component(input), "tool");
        }
    }

    #[test]
    fn launcher_candidates_prefer_exe_over_cmd_and_bat() {
        let directory = temp_dir("candidates-order");
        fs::write(directory.join("intelephense.cmd"), "@echo off").expect("cmd shim");
        let found = first_existing(executable_candidates_in(&directory, "intelephense"))
            .expect("cmd shim resolves");
        assert_eq!(found, directory.join("intelephense.cmd"));

        fs::write(directory.join("intelephense.exe"), []).expect("exe launcher");
        let found = first_existing(executable_candidates_in(&directory, "intelephense"))
            .expect("exe launcher resolves");
        assert_eq!(found, directory.join("intelephense.exe"));
        fs::remove_dir_all(directory).ok();
    }

    #[test]
    fn system_tool_is_found_only_in_configured_path_directories() {
        let directory = temp_dir("system-path");
        fs::create_dir_all(directory.join("bin")).expect("bin");
        fs::write(directory.join("bin").join("rust-analyzer.exe"), []).expect("tool");

        let found = find_system_tool(Some(directory.join("bin").as_os_str()), "rust-analyzer");
        assert_eq!(found, Some(directory.join("bin").join("rust-analyzer.exe")));
        assert_eq!(find_system_tool(None, "rust-analyzer"), None);
        let empty_directory = temp_dir("system-path-empty");
        assert_eq!(
            find_system_tool(Some(empty_directory.as_os_str()), "rust-analyzer"),
            None
        );
        fs::remove_dir_all(directory).ok();
        fs::remove_dir_all(empty_directory).ok();
    }

    #[test]
    fn bun_falls_back_to_the_default_user_install_location() {
        let home = temp_dir("bun-home");
        fs::create_dir_all(home.join(".bun").join("bin")).expect("bun bin");
        fs::write(home.join(".bun").join("bin").join("bun.exe"), []).expect("bun");

        assert_eq!(
            find_bun_executable(None, Some(home.as_os_str())),
            Some(home.join(".bun").join("bin").join("bun.exe"))
        );
        assert_eq!(find_bun_executable(None, None), None);
        fs::remove_dir_all(home).ok();
    }

    #[test]
    fn managed_bun_tool_resolves_from_node_modules_bin() {
        let tools_root = temp_dir("managed-tool");
        let tool_directory = managed_tool_directory(&tools_root, "php", "intelephense");
        let bin_directory = tool_directory.join("node_modules").join(".bin");
        fs::create_dir_all(&bin_directory).expect(".bin");
        fs::write(bin_directory.join("intelephense.cmd"), "@echo off").expect("shim");

        let config = tool_config(ToolRuntime::Bun, "intelephense", "intelephense");
        assert_eq!(
            resolve_bun_tool_path("php", &config, &tools_root, None, None),
            None
        );
        fs::write(tool_directory.join(".lithe-install-complete"), b"1").expect("completion marker");
        assert_eq!(
            resolve_bun_tool_path("php", &config, &tools_root, None, None),
            Some(bin_directory.join("intelephense.cmd"))
        );
        fs::remove_dir_all(tools_root).ok();
    }

    #[test]
    fn global_bun_bin_is_the_fallback_when_the_tool_is_not_managed() {
        let tools_root = temp_dir("managed-fallback");
        let home = temp_dir("global-bun-bin");
        fs::create_dir_all(home.join(".bun").join("bin")).expect("bun bin");
        fs::write(home.join(".bun").join("bin").join("intelephense.exe"), []).expect("tool");

        let config = tool_config(ToolRuntime::Bun, "intelephense", "intelephense");
        assert_eq!(
            resolve_bun_tool_path("php", &config, &tools_root, None, Some(home.as_os_str())),
            Some(home.join(".bun").join("bin").join("intelephense.exe"))
        );
        fs::remove_dir_all(tools_root).ok();
        fs::remove_dir_all(home).ok();
    }

    #[test]
    fn bun_tool_path_falls_back_to_path_before_reporting_unavailable() {
        let tools_root = temp_dir("managed-path-fallback");
        let npm_directory = temp_dir("npm-global-bin");
        fs::write(npm_directory.join("intelephense.cmd"), "@echo off").expect("npm shim");

        let config = tool_config(ToolRuntime::Bun, "intelephense", "intelephense");
        assert_eq!(
            resolve_bun_tool_path(
                "php",
                &config,
                &tools_root,
                Some(npm_directory.as_os_str()),
                None
            ),
            Some(npm_directory.join("intelephense.cmd"))
        );
        fs::remove_dir_all(tools_root).ok();
        fs::remove_dir_all(npm_directory).ok();
    }

    #[test]
    fn managed_tool_directory_sanitizes_manifest_provided_names() {
        let root = PathBuf::from("C:/cache");
        assert_eq!(
            managed_tool_directory(&root, "php", "intelephense"),
            root.join("php").join("intelephense")
        );
        // A hostile manifest name must not escape the tools root.
        let hostile = managed_tool_directory(&root, "../escape", r"to ol?\..");
        assert!(hostile.starts_with(&root));
        for component in hostile
            .strip_prefix(&root)
            .expect("inside root")
            .components()
        {
            let name = component.as_os_str().to_string_lossy();
            assert!(
                name.chars()
                    .all(|character| character.is_ascii_alphanumeric()
                        || matches!(character, '-' | '_' | '.')),
                "unsafe component: {name}"
            );
        }
    }

    #[test]
    fn tool_configs_parse_the_frontend_contract() {
        let php_lsp: LanguageToolConfig = serde_json::from_value(json!({
            "name": "intelephense",
            "runtime": "bun",
            "package": "intelephense",
            "args": ["--stdio"]
        }))
        .expect("php lsp config");
        assert_eq!(php_lsp.runtime, ToolRuntime::Bun);
        assert_eq!(php_lsp.executable_name(), "intelephense");
        assert_eq!(php_lsp.npm_packages(), vec!["intelephense"]);

        let pyright_lsp: LanguageToolConfig = serde_json::from_value(json!({
            "name": "pyright",
            "command": "pyright-langserver",
            "runtime": "bun",
            "package": "pyright"
        }))
        .expect("pyright lsp config");
        assert_eq!(pyright_lsp.executable_name(), "pyright-langserver");

        let typescript_lsp: LanguageToolConfig = serde_json::from_value(json!({
            "name": "typescript-language-server",
            "runtime": "bun",
            "package": "typescript-language-server",
            "packages": ["typescript"]
        }))
        .expect("typescript lsp config");
        assert_eq!(
            typescript_lsp.npm_packages(),
            vec!["typescript-language-server", "typescript"]
        );
    }

    #[test]
    fn npm_packages_deduplicate_while_preserving_order() {
        let config = LanguageToolConfig {
            name: "tool".to_string(),
            command: None,
            runtime: ToolRuntime::Bun,
            package: Some("typescript".to_string()),
            packages: vec![
                "typescript".to_string(),
                " typescript-language-server ".to_string(),
            ],
        };
        assert_eq!(
            config.npm_packages(),
            vec!["typescript", "typescript-language-server"]
        );
    }

    #[test]
    fn unsupported_runtime_installs_fail_explicitly() {
        let config = tool_config(ToolRuntime::Binary, "marksman", "");
        let error = install_language_tool(
            "markdown",
            &config,
            Path::new("C:/cache"),
            None,
            None,
            &AtomicBool::new(false),
        )
        .expect_err("binary runtime has no install support");
        assert!(error.contains("not supported"), "{error}");
    }

    #[test]
    fn missing_system_tool_installs_report_a_path_hint() {
        let config = tool_config(ToolRuntime::System, "rust-analyzer", "");
        let error = install_language_tool(
            "rust",
            &config,
            Path::new("C:/cache"),
            None,
            None,
            &AtomicBool::new(false),
        )
        .expect_err("missing system tool");
        assert!(error.contains("PATH"), "{error}");
    }

    #[test]
    fn present_system_tool_installs_report_ok() {
        let directory = temp_dir("system-install");
        fs::write(directory.join("rust-analyzer.exe"), []).expect("tool");
        let config = tool_config(ToolRuntime::System, "rust-analyzer", "");
        install_language_tool(
            "rust",
            &config,
            Path::new("C:/cache"),
            Some(directory.as_os_str()),
            None,
            &AtomicBool::new(false),
        )
        .expect("system tool found");
        fs::remove_dir_all(directory).ok();
    }

    #[test]
    fn php_installs_without_node_report_the_missing_runtime() {
        let tools_root = temp_dir("bun-missing");
        let config = tool_config(ToolRuntime::Bun, "intelephense", "intelephense");
        let error = install_language_tool(
            "php",
            &config,
            &tools_root,
            None,
            None,
            &AtomicBool::new(false),
        )
        .expect_err("Node.js is required");
        assert!(error.contains("Node.js"), "{error}");
        fs::remove_dir_all(tools_root).ok();
    }

    #[test]
    fn tool_config_errors_carry_the_tool_type() {
        let error = requested_tool_config(&json!({ "lsp": { "runtime": "bun" } }), "lsp")
            .expect_err("name is required");
        assert!(error.contains("lsp"), "{error}");
        assert!(requested_tool_config(&json!({}), "lsp")
            .expect("absent config")
            .is_none());
    }
}
