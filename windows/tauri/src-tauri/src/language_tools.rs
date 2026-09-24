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
use std::ffi::OsStr;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};
use tauri::{AppHandle, Manager};

const INSTALL_TIMEOUT: Duration = Duration::from_secs(600);
const PROCESS_POLL_INTERVAL: Duration = Duration::from_millis(100);
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

static INSTALL_TASK_ID: AtomicU64 = AtomicU64::new(1);

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
    let path_env = std::env::var_os("PATH");
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
    let operation_id = INSTALL_TASK_ID.fetch_add(1, Ordering::Relaxed);
    tauri::async_runtime::spawn_blocking(move || {
        let _operation_id = operation_id;
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
) -> Result<(), String> {
    match config.runtime {
        ToolRuntime::Bun => install_bun_tool(language_id, config, tools_root, path_env, user_home),
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
) -> Result<(), String> {
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
    run_bun_add(&bun, &tool_directory, &packages)?;
    resolve_bun_tool_path(language_id, config, tools_root, path_env, user_home).ok_or_else(
        || {
            format!(
                "bun installed {} but no {} launcher was found under node_modules/.bin.",
                packages.join(", "),
                config.executable_name()
            )
        },
    )?;
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
    if let Some(launcher) = find_bun_tool_bin(&tool_directory, config.executable_name()) {
        return Some(launcher);
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

/// Runs `bun add --production <packages>` with a bounded lifetime so a hung
/// network install cannot pin the worker thread forever. Output is drained on
/// dedicated threads to keep the pipes from filling while the deadline polls.
fn run_bun_add(bun: &Path, tool_directory: &Path, packages: &[String]) -> Result<(), String> {
    let mut child = Command::new(bun)
        .arg("add")
        .arg("--production")
        .args(packages)
        .current_dir(tool_directory)
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|error| format!("Could not start bun: {error}"))?;

    let captured = Arc::new(Mutex::new(String::new()));
    let mut drains = Vec::new();
    if let Some(stdout) = child.stdout.take() {
        drains.push(drain_to_capture(stdout, Arc::clone(&captured)));
    }
    if let Some(stderr) = child.stderr.take() {
        drains.push(drain_to_capture(stderr, Arc::clone(&captured)));
    }

    let deadline = Instant::now() + INSTALL_TIMEOUT;
    let outcome = loop {
        match child.try_wait() {
            Ok(Some(status)) => break Ok(status),
            Ok(None) if Instant::now() >= deadline => {
                let _ = child.kill();
                let _ = child.wait();
                break Err("timed out".to_string());
            }
            Ok(None) => thread::sleep(PROCESS_POLL_INTERVAL),
            Err(error) => break Err(error.to_string()),
        }
    };
    for drain in drains {
        let _ = drain.join();
    }

    match outcome {
        Ok(status) if status.success() => Ok(()),
        Ok(status) => {
            let output = captured_output_tail(&captured);
            Err(format!(
                "bun add exited with {status}.{}",
                format_output_tail(&output)
            ))
        }
        Err(error) if error == "timed out" => Err(format!(
            "bun add did not finish within {} seconds.",
            INSTALL_TIMEOUT.as_secs()
        )),
        Err(error) => Err(format!("bun add failed: {error}")),
    }
}

/// Drains one child output stream to EOF so the pipes never fill and block the
/// child while the deadline loop polls. The stream ends when the child exits
/// or is killed, so the reader thread always terminates.
fn drain_to_capture<R: Read + Send + 'static>(
    stream: R,
    captured: Arc<Mutex<String>>,
) -> thread::JoinHandle<()> {
    thread::spawn(move || {
        let mut buffer = Vec::new();
        let _ = Read::take(stream, 1_048_576).read_to_end(&mut buffer);
        let append = String::from_utf8_lossy(&buffer);
        if let Ok(mut captured) = captured.lock() {
            if captured.len() < CAPTURED_OUTPUT_LIMIT {
                captured.push_str(&append);
                let excess = captured.len().saturating_sub(CAPTURED_OUTPUT_LIMIT);
                captured.drain(..excess);
            }
        }
    })
}

fn captured_output_tail(captured: &Arc<Mutex<String>>) -> Option<String> {
    let captured = captured.lock().ok()?;
    let tail = captured
        .chars()
        .rev()
        .take(CAPTURED_OUTPUT_LIMIT)
        .collect::<Vec<_>>()
        .into_iter()
        .rev()
        .collect::<String>();
    Some(tail)
}

fn format_output_tail(output: &Option<String>) -> String {
    match output {
        Some(output) if !output.trim().is_empty() => {
            format!(" Output: {}", output.trim())
        }
        _ => String::new(),
    }
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
    if trimmed.is_empty() {
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
    use std::sync::atomic::Ordering;

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
        let error = install_language_tool("markdown", &config, Path::new("C:/cache"), None, None)
            .expect_err("binary runtime has no install support");
        assert!(error.contains("not supported"), "{error}");
    }

    #[test]
    fn missing_system_tool_installs_report_a_path_hint() {
        let config = tool_config(ToolRuntime::System, "rust-analyzer", "");
        let error = install_language_tool("rust", &config, Path::new("C:/cache"), None, None)
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
        )
        .expect("system tool found");
        fs::remove_dir_all(directory).ok();
    }

    #[test]
    fn bun_installs_without_bun_report_the_missing_runtime() {
        let tools_root = temp_dir("bun-missing");
        let config = tool_config(ToolRuntime::Bun, "intelephense", "intelephense");
        let error = install_language_tool("php", &config, &tools_root, None, None)
            .expect_err("bun is required");
        assert!(error.contains("bun"), "{error}");
        fs::remove_dir_all(tools_root).ok();
    }

    #[test]
    fn tool_config_errors_carry_the_tool_type() {
        let error = requested_tool_config(&json!({ "lsp": { "runtime": "bun" } }), "lsp")
            .expect_err("name is required");
        assert!(error.contains("lsp"), "{error}");
        assert!(
            requested_tool_config(&json!({}), "lsp")
                .expect("absent config")
                .is_none()
        );
    }
}
