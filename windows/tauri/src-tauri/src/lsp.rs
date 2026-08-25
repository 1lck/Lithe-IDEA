//! Windows discovery for the built-in Java language server.
//!
//! Shared JDT LS process ownership stays in `lithe-core`. This adapter only
//! finds `jdtls`, the bundled JDTLS runtime JDK, and a cache directory.
//!
//! The bundled JDK exists solely to run the language server. Project SDKs are
//! discovered separately by `run.rs` and remain user-owned.

mod jdt_workspace;

use crate::{logging::LogManager, run};
#[cfg(test)]
use jdt_workspace::JDT_CACHE_LAST_USED_MARKER;
use jdt_workspace::{
    cleanup_expired_java_index_directories, clear_java_index_directory,
    collect_workspace_fingerprint_inputs, now_unix_seconds, resolve_workspace_fingerprint,
};
use serde::Serialize;
use serde_json::json;
use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use tauri::{AppHandle, Manager, State};

const JAVA_PROVIDER_ID: &str = "java";
const JDTLS_EXECUTABLE_NAMES: &[&str] = &["jdtls.bat", "jdtls.cmd", "jdtls.exe", "jdtls"];
const MAX_CURRENT_EXE_JDTLS_WALK_DEPTH: usize = 12;
const JDTLS_CORE_PLUGIN_PREFIX: &str = "org.eclipse.jdt.ls.core_";
const BUNDLED_JDTLS_MANIFEST: &str = include_str!("../../../../third_party/jdtls/manifest.json");
static JDT_CACHE_OPERATION_ID: AtomicU64 = AtomicU64::new(1);

/// Launch plan for the built-in Java language server on this machine.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct JavaLspLaunch {
    pub provider_id: String,
    pub language_id: String,
    pub executable_path: String,
    pub arguments: Vec<String>,
    pub runtime_executable_path: Option<String>,
    pub cache_directory: String,
    pub environment: JavaLspEnvironment,
    /// Workspace structure digest forwarded to the Rust core so JDT LS uses a
    /// fresh state directory when the project layout changes.
    pub workspace_fingerprint: Option<String>,
}

/// Environment values the Java language server needs from the host.
#[derive(Debug, Clone, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct JavaLspEnvironment {
    #[serde(rename = "JAVA_HOME", skip_serializing_if = "Option::is_none")]
    pub java_home: Option<String>,
}

#[derive(Debug, Clone)]
struct JavaLspResolution {
    executable: PathBuf,
    java_home: PathBuf,
}

/// Resolves the built-in Java language-server executable, JDK, and cache directory.
#[tauri::command]
pub fn lsp_resolve_java_launch(
    app: AppHandle,
    workspace_path: String,
    log_manager: State<'_, Arc<LogManager>>,
) -> Result<JavaLspLaunch, String> {
    let workspace = PathBuf::from(&workspace_path);
    let project_root = workspace.is_dir().then_some(workspace.as_path());
    let bundled_root = bundled_jdtls_root(&app);
    let bundled_jdk = bundled_jdk_root(&app);
    let resolution = resolve_java_lsp_launch(
        std::env::var_os("PATH").as_deref(),
        bundled_root.as_deref(),
        &jdtls_search_roots(project_root),
        bundled_jdk.as_deref(),
    )?;

    let operation_id = format!(
        "windows-jdt-cache-{}",
        JDT_CACHE_OPERATION_ID.fetch_add(1, Ordering::Relaxed)
    );
    let jdtls_version = jdtls_version_for_executable(&resolution.executable)?;
    let workspace_fingerprint = project_root
        .map(|root| {
            let inputs = collect_workspace_fingerprint_inputs(root)?;
            resolve_workspace_fingerprint(inputs, &jdtls_version, &operation_id)
        })
        .transpose()?;
    let cache_directory = language_server_cache_directory(&app);
    let active_workspace_key =
        lithe_core::jdt_workspace_key(&workspace, workspace_fingerprint.as_deref());
    log_manager.emit_json(
        "info",
        "windows.java.jdt_cache".to_string(),
        "cache cleanup started".to_string(),
        Some(json!({
            "operationId": operation_id,
            "activeWorkspaceKey": active_workspace_key,
        })),
    );
    let cleanup_result = now_unix_seconds().and_then(|now_unix_seconds| {
        cleanup_expired_java_index_directories(
            &cache_directory,
            &active_workspace_key,
            now_unix_seconds,
            &operation_id,
        )
    });
    match cleanup_result {
        Ok(result) => log_manager.emit_json(
            "info",
            "windows.java.jdt_cache".to_string(),
            "cache cleanup succeeded".to_string(),
            Some(json!({
                "operationId": operation_id,
                "retentionDays": result.retention_days,
                "removedCount": result.removed_workspace_keys.len(),
            })),
        ),
        Err(error) => log_manager.emit_json(
            "warn",
            "windows.java.jdt_cache".to_string(),
            "cache cleanup failed".to_string(),
            Some(json!({
                "operationId": operation_id,
                "error": error,
            })),
        ),
    }

    Ok(JavaLspLaunch {
        provider_id: JAVA_PROVIDER_ID.to_string(),
        language_id: JAVA_PROVIDER_ID.to_string(),
        executable_path: normalize_path(&resolution.executable),
        arguments: Vec::new(),
        runtime_executable_path: run::java_executable(&resolution.java_home)
            .as_deref()
            .map(normalize_path),
        cache_directory: normalize_path(&cache_directory),
        environment: JavaLspEnvironment {
            java_home: Some(normalize_path(&resolution.java_home)),
        },
        workspace_fingerprint,
    })
}

fn resolve_java_lsp_launch(
    path_env: Option<&OsStr>,
    bundled_root: Option<&Path>,
    extra_roots: &[PathBuf],
    bundled_jdk: Option<&Path>,
) -> Result<JavaLspResolution, String> {
    let executable =
        find_jdtls_executable(path_env, bundled_root, extra_roots).ok_or_else(|| {
            "Could not find jdtls. Install Eclipse JDT Language Server and add it to PATH, or use a Lithe build that includes the bundled Java language server."
                .to_string()
        })?;
    let java_home = resolve_java_home(bundled_jdk)?;
    Ok(JavaLspResolution {
        executable,
        java_home,
    })
}

fn find_jdtls_executable(
    path_env: Option<&OsStr>,
    bundled_root: Option<&Path>,
    extra_roots: &[PathBuf],
) -> Option<PathBuf> {
    jdtls_candidates(path_env, bundled_root, extra_roots)
        .into_iter()
        .find(|candidate| candidate.is_file())
}

fn jdtls_candidates(
    path_env: Option<&OsStr>,
    bundled_root: Option<&Path>,
    extra_roots: &[PathBuf],
) -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    if let Some(root) = bundled_root {
        push_jdtls_root(&mut candidates, root);
    }
    if let Some(path) = path_env {
        for directory in std::env::split_paths(path) {
            push_jdtls_names(&mut candidates, &directory);
        }
    }
    for root in extra_roots {
        push_jdtls_root(&mut candidates, root);
    }
    candidates
}

fn push_jdtls_root(candidates: &mut Vec<PathBuf>, root: &Path) {
    push_jdtls_names(candidates, root);
    push_jdtls_names(candidates, &root.join("bin"));
}

fn push_jdtls_names(candidates: &mut Vec<PathBuf>, directory: &Path) {
    for name in JDTLS_EXECUTABLE_NAMES {
        candidates.push(directory.join(name));
    }
}

fn jdtls_search_roots(project_root: Option<&Path>) -> Vec<PathBuf> {
    let mut roots = Vec::new();
    if let Ok(home) = std::env::var("JDTLS_HOME") {
        roots.push(PathBuf::from(home));
    }
    if let Ok(root) = std::env::var("LITHE_JDTLS_ROOT") {
        let trimmed = root.trim();
        if !trimmed.is_empty() {
            roots.push(PathBuf::from(trimmed));
        }
    }
    for key in ["LOCALAPPDATA", "ProgramFiles", "ProgramFiles(x86)"] {
        if let Ok(base) = std::env::var(key) {
            let base = PathBuf::from(base);
            roots.push(base.join("jdtls"));
            roots.push(base.join("Eclipse JDT Language Server"));
            roots.push(base.join("Programs").join("jdtls"));
        }
    }
    if let Ok(profile) = std::env::var("USERPROFILE") {
        let profile = PathBuf::from(profile);
        roots.push(profile.join(".jdtls"));
        roots.push(
            profile
                .join("scoop")
                .join("apps")
                .join("jdtls")
                .join("current"),
        );
        roots.push(profile.join("scoop").join("shims"));
    }
    if let Some(root) = project_root {
        roots.push(root.join(".lithe").join("toolchains").join("jdtls"));
    }
    roots
}

fn bundled_jdtls_root(app: &AppHandle) -> Option<PathBuf> {
    select_bundled_jdtls_root(
        app.path().resource_dir().ok().as_deref(),
        std::env::current_exe().ok().as_deref(),
    )
}

/// Resolves the JDK that is bundled alongside JDTLS and used exclusively to
/// run the language server. Falls back to walking up from the current exe so
/// that development (`cargo run`) and unbundled builds also work.
fn bundled_jdk_root(app: &AppHandle) -> Option<PathBuf> {
    let resource_dir = app.path().resource_dir().ok();
    let current_exe = std::env::current_exe().ok();

    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Some(ref dir) = resource_dir {
        candidates.push(dir.join("LanguageServers").join("jdk"));
    }
    if let Some(ref exe) = current_exe {
        if let Some(exe_dir) = exe.parent() {
            candidates.push(exe_dir.join("LanguageServers").join("jdk"));
            let mut cursor = exe_dir.to_path_buf();
            for _ in 0..MAX_CURRENT_EXE_JDTLS_WALK_DEPTH {
                candidates.push(cursor.join(".artifacts").join("jdk"));
                if !cursor.pop() {
                    break;
                }
            }
        }
    }
    candidates.into_iter().find(|root| is_jdk_home(root))
}

fn is_jdk_home(root: &Path) -> bool {
    root.join("bin").join("java.exe").is_file()
}

fn jdtls_version_for_executable(executable: &Path) -> Result<String, String> {
    let mut roots = Vec::new();
    push_jdtls_installation_root(&mut roots, executable);
    if let Ok(canonical) = std::fs::canonicalize(executable) {
        push_jdtls_installation_root(&mut roots, &canonical);
    }
    roots.sort();
    roots.dedup();

    for root in roots {
        if let Some(version) = jdtls_version_from_root(&root)? {
            return Ok(version);
        }
    }

    let manifest: serde_json::Value = serde_json::from_str(BUNDLED_JDTLS_MANIFEST)
        .map_err(|error| format!("The bundled JDTLS manifest is invalid: {error}"))?;
    let version = manifest
        .get("version")
        .and_then(serde_json::Value::as_str)
        .map(str::trim)
        .filter(|version| !version.is_empty())
        .ok_or_else(|| "The bundled JDTLS manifest has no valid version.".to_string())?;
    Ok(version.to_string())
}

fn push_jdtls_installation_root(roots: &mut Vec<PathBuf>, executable: &Path) {
    let Some(parent) = executable.parent() else {
        return;
    };
    if parent
        .file_name()
        .is_some_and(|name| name.eq_ignore_ascii_case("bin"))
    {
        if let Some(root) = parent.parent() {
            roots.push(root.to_path_buf());
        }
    }
    roots.push(parent.to_path_buf());
}

fn jdtls_version_from_root(root: &Path) -> Result<Option<String>, String> {
    let manifest_path = root.join("manifest.json");
    match std::fs::read(&manifest_path) {
        Ok(data) => {
            let manifest: serde_json::Value = serde_json::from_slice(&data).map_err(|error| {
                format!(
                    "The selected JDTLS manifest is invalid at {}: {error}",
                    manifest_path.display()
                )
            })?;
            let version = manifest
                .get("version")
                .and_then(serde_json::Value::as_str)
                .map(str::trim)
                .filter(|version| !version.is_empty())
                .ok_or_else(|| {
                    format!(
                        "The selected JDTLS manifest has no valid version at {}.",
                        manifest_path.display()
                    )
                })?;
            return Ok(Some(version.to_string()));
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => {
            return Err(format!(
                "Failed to read the selected JDTLS manifest at {}: {error}",
                manifest_path.display()
            ))
        }
    }

    let plugins_path = root.join("plugins");
    let plugins = match std::fs::read_dir(&plugins_path) {
        Ok(plugins) => plugins,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(format!(
                "Failed to inspect selected JDTLS plugins at {}: {error}",
                plugins_path.display()
            ))
        }
    };
    let mut plugin_names = Vec::new();
    for entry in plugins {
        let entry = entry.map_err(|error| {
            format!(
                "Failed to inspect an entry in selected JDTLS plugins at {}: {error}",
                plugins_path.display()
            )
        })?;
        let name = entry.file_name().into_string().map_err(|_| {
            format!(
                "A selected JDTLS plugin name is not valid UTF-8 at {}.",
                plugins_path.display()
            )
        })?;
        plugin_names.push(name);
    }
    plugin_names.sort();
    Ok(plugin_names.into_iter().find_map(|name| {
        let suffix = name
            .strip_prefix(JDTLS_CORE_PLUGIN_PREFIX)?
            .strip_suffix(".jar")?;
        let version = suffix.split('.').take(3).collect::<Vec<_>>().join(".");
        (!version.is_empty()).then_some(version)
    }))
}

fn is_jdtls_root(root: &Path) -> bool {
    JDTLS_EXECUTABLE_NAMES
        .iter()
        .any(|name| root.join(name).is_file() || root.join("bin").join(name).is_file())
}

/// NSIS bundles JDTLS under the resource directory. Unbundled `cargo`/`build-windows`
/// executables do not, so also look next to the exe and walk up to repo `.artifacts/jdtls`.
fn select_bundled_jdtls_root(
    resource_dir: Option<&Path>,
    current_exe: Option<&Path>,
) -> Option<PathBuf> {
    let mut candidates = Vec::new();
    if let Some(directory) = resource_dir {
        candidates.push(directory.join("LanguageServers").join("jdtls"));
    }
    if let Some(exe) = current_exe {
        if let Some(exe_dir) = exe.parent() {
            candidates.push(exe_dir.join("LanguageServers").join("jdtls"));
            let mut cursor = exe_dir.to_path_buf();
            for _ in 0..MAX_CURRENT_EXE_JDTLS_WALK_DEPTH {
                candidates.push(cursor.join(".artifacts").join("jdtls"));
                if !cursor.pop() {
                    break;
                }
            }
        }
    }
    candidates.into_iter().find(|root| is_jdtls_root(root))
}

/// Resolves only the Temurin 21 runtime staged with the application.
fn resolve_java_home(bundled_jdk: Option<&Path>) -> Result<PathBuf, String> {
    bundled_jdk.map(Path::to_path_buf).ok_or_else(|| {
        "Bundled Temurin JDK 21 not found. This is a packaging error; please reinstall Lithe."
            .to_string()
    })
}

fn language_server_cache_directory(app: &AppHandle) -> PathBuf {
    app.path()
        .app_cache_dir()
        .unwrap_or_else(|_| std::env::temp_dir().join("lithe-lsp"))
        .join("language-servers")
}

/// Removes the current workspace/fingerprint JDT LS state directory.
///
/// The caller must stop the workspace's active language-server session before
/// invoking this command because Windows prevents deletion of open index files.
#[tauri::command]
pub fn lsp_rebuild_java_index(
    app: AppHandle,
    workspace_path: String,
    workspace_fingerprint: Option<String>,
) -> Result<(), String> {
    clear_java_index_directory(
        &language_server_cache_directory(&app),
        Path::new(&workspace_path),
        workspace_fingerprint.as_deref(),
    )
}

fn normalize_path(path: &Path) -> String {
    let path = path.to_string_lossy();
    if let Some(network_path) = path.strip_prefix(r"\\?\UNC\") {
        return format!("//{}", network_path.replace('\\', "/"));
    }

    // Tauri can return verbatim resource paths, but cmd.exe cannot execute
    // their `//?/` form after slash normalization.
    path.strip_prefix(r"\\?\")
        .unwrap_or(path.as_ref())
        .replace('\\', "/")
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeSet;
    use std::fs;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::{SystemTime, UNIX_EPOCH};

    static TEST_TEMP_DIRECTORY_ID: AtomicU64 = AtomicU64::new(1);

    fn temp_dir() -> PathBuf {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock")
            .as_nanos();
        let id = TEST_TEMP_DIRECTORY_ID.fetch_add(1, Ordering::Relaxed);
        let path = std::env::temp_dir().join(format!("lithe-java-lsp-{stamp}-{id}"));
        fs::create_dir_all(&path).expect("temp dir");
        path
    }

    #[test]
    fn finds_jdtls_bat_in_an_extra_search_root() {
        let root = temp_dir();
        let bin = root.join("bin");
        fs::create_dir_all(&bin).expect("bin");
        let executable = bin.join("jdtls.bat");
        fs::write(&executable, "@echo off\n").expect("jdtls");

        let found = find_jdtls_executable(None, None, &[root.clone()]).expect("found");
        assert_eq!(found, executable);
        fs::remove_dir_all(root).ok();
    }

    #[test]
    fn prefers_path_entries_before_extra_roots() {
        let path_root = temp_dir();
        let extra_root = temp_dir();
        let path_executable = path_root.join("jdtls.cmd");
        let extra_executable = extra_root.join("jdtls.bat");
        fs::write(&path_executable, "@echo off\n").expect("path jdtls");
        fs::write(&extra_executable, "@echo off\n").expect("extra jdtls");

        let found = find_jdtls_executable(Some(path_root.as_os_str()), None, &[extra_root.clone()])
            .expect("found");
        assert_eq!(found, path_executable);
        fs::remove_dir_all(path_root).ok();
        fs::remove_dir_all(extra_root).ok();
    }

    #[test]
    fn prefers_bundled_jdtls_before_path_and_external_roots() {
        let bundled_root = temp_dir();
        let bundled_bin = bundled_root.join("bin");
        let path_root = temp_dir();
        let external_root = temp_dir();
        fs::create_dir_all(&bundled_bin).expect("bundled bin");
        let bundled_executable = bundled_bin.join("jdtls.bat");
        fs::write(&bundled_executable, "@echo off\n").expect("bundled jdtls");
        fs::write(path_root.join("jdtls.cmd"), "@echo off\n").expect("path jdtls");
        fs::write(external_root.join("jdtls.exe"), []).expect("external jdtls");

        let found = find_jdtls_executable(
            Some(path_root.as_os_str()),
            Some(&bundled_root),
            &[external_root.clone()],
        )
        .expect("found");

        assert_eq!(found, bundled_executable);
        fs::remove_dir_all(bundled_root).ok();
        fs::remove_dir_all(path_root).ok();
        fs::remove_dir_all(external_root).ok();
    }

    #[test]
    fn reports_a_stable_error_when_jdtls_is_missing() {
        let missing = temp_dir().join("empty-jdtls-root");
        fs::create_dir_all(&missing).expect("missing root");
        let error = resolve_java_lsp_launch(None, None, &[missing.clone()], None).unwrap_err();
        assert!(error.contains("jdtls"), "{error}");
        fs::remove_dir_all(missing).ok();
    }

    #[test]
    fn bundled_jdk_is_the_only_jdtls_runtime() {
        let root = temp_dir().join("bundled-jdk-test");
        let jdtls_bin = root.join("jdtls").join("bin");
        let jdk_bin = root.join("jdk").join("bin");
        fs::create_dir_all(&jdtls_bin).expect("jdtls bin");
        fs::create_dir_all(&jdk_bin).expect("jdk bin");
        // Minimal JDTLS executable marker.
        fs::write(jdtls_bin.join("jdtls.bat"), "@echo off\n").expect("jdtls.bat");
        // Minimal java.exe marker so is_jdk_home() returns true.
        fs::write(jdk_bin.join("java.exe"), "").expect("java.exe");

        let jdtls_root = root.join("jdtls");
        let bundled_jdk = root.join("jdk");
        let resolution = resolve_java_lsp_launch(None, Some(&jdtls_root), &[], Some(&bundled_jdk))
            .expect("resolution");
        assert_eq!(resolution.java_home, bundled_jdk, "bundled JDK should win");
        fs::remove_dir_all(root).ok();
    }

    #[test]
    fn windows_bundled_jdk_rejects_a_unix_java_executable() {
        let root = temp_dir().join("non-windows-jdk-test");
        let bin = root.join("bin");
        fs::create_dir_all(&bin).expect("JDK bin");
        fs::write(bin.join("java"), "").expect("Unix java marker");

        assert!(!is_jdk_home(&root));
        fs::remove_dir_all(root).ok();
    }

    #[test]
    fn returns_packaging_error_when_no_jdk_is_available() {
        let result = resolve_java_home(None);
        assert!(result.is_err());
        let msg = result.unwrap_err();
        assert!(
            msg.contains("packaging error") || msg.contains("reinstall"),
            "{msg}"
        );
    }

    #[test]
    fn bundled_root_prefers_resource_dir_when_it_contains_jdtls() {
        let resource_dir = temp_dir();
        let bundled = resource_dir
            .join("LanguageServers")
            .join("jdtls")
            .join("bin");
        fs::create_dir_all(&bundled).expect("bundled bin");
        fs::write(bundled.join("jdtls.bat"), "@echo off\n").expect("jdtls");

        let found = select_bundled_jdtls_root(Some(&resource_dir), None).expect("found");
        assert_eq!(found, resource_dir.join("LanguageServers").join("jdtls"));
        fs::remove_dir_all(resource_dir).ok();
    }

    #[test]
    fn bundled_root_walks_from_unbundled_exe_to_repo_artifacts() {
        let repo = temp_dir();
        let artifacts_bin = repo.join(".artifacts").join("jdtls").join("bin");
        fs::create_dir_all(&artifacts_bin).expect("artifacts bin");
        fs::write(artifacts_bin.join("jdtls.bat"), "@echo off\n").expect("jdtls");

        let exe_dir = repo
            .join("windows")
            .join("tauri")
            .join("src-tauri")
            .join("target")
            .join("release");
        fs::create_dir_all(&exe_dir).expect("exe dir");
        let exe = exe_dir.join("lithe-windows.exe");
        fs::write(&exe, []).expect("exe");

        let empty_resource = repo.join("empty-resource");
        fs::create_dir_all(empty_resource.join("LanguageServers").join("jdtls"))
            .expect("empty resource");

        let found = select_bundled_jdtls_root(Some(&empty_resource), Some(&exe)).expect("found");
        assert_eq!(found, repo.join(".artifacts").join("jdtls"));
        fs::remove_dir_all(repo).ok();
    }

    #[test]
    fn bundled_root_uses_language_servers_next_to_the_exe() {
        let exe_dir = temp_dir();
        let bundled_bin = exe_dir.join("LanguageServers").join("jdtls").join("bin");
        fs::create_dir_all(&bundled_bin).expect("exe bundled bin");
        fs::write(bundled_bin.join("jdtls.bat"), "@echo off\n").expect("jdtls");
        let exe = exe_dir.join("lithe-windows.exe");
        fs::write(&exe, []).expect("exe");

        let found = select_bundled_jdtls_root(None, Some(&exe)).expect("found");
        assert_eq!(found, exe_dir.join("LanguageServers").join("jdtls"));
        fs::remove_dir_all(exe_dir).ok();
    }

    #[test]
    fn workspace_fingerprint_routes_platform_observations_through_core() {
        let workspace = temp_dir();

        let inputs = collect_workspace_fingerprint_inputs(&workspace).expect("observations");
        let fingerprint = resolve_workspace_fingerprint(inputs, "9.4.1", "test-fingerprint")
            .expect("Core fingerprint");

        assert_eq!(fingerprint, "build=|modules=|jdtls=9.4.1");
        fs::remove_dir_all(workspace).ok();
    }

    #[test]
    fn workspace_fingerprint_observes_root_build_file_metadata() {
        let workspace = temp_dir();
        let pom = workspace.join("pom.xml");
        fs::write(&pom, "a").expect("initial pom");
        let first = collect_workspace_fingerprint_inputs(&workspace).expect("first observations");

        fs::write(&pom, "a larger project descriptor").expect("updated pom");
        let changed =
            collect_workspace_fingerprint_inputs(&workspace).expect("changed observations");

        assert_eq!(first.build_files.len(), 1);
        assert_eq!(first.build_files[0].path, "pom.xml");
        assert!(changed.build_files[0].size_bytes > first.build_files[0].size_bytes);
        fs::remove_dir_all(workspace).ok();
    }

    #[test]
    fn workspace_fingerprint_observes_direct_maven_modules_only() {
        let workspace = temp_dir();
        for name in ["zeta", "alpha"] {
            let module = workspace.join(name);
            fs::create_dir_all(&module).expect("module directory");
            fs::write(module.join("pom.xml"), "<project/>").expect("module pom");
        }
        let gradle_only = workspace.join("gradle-only");
        fs::create_dir_all(&gradle_only).expect("Gradle module directory");
        fs::write(gradle_only.join("build.gradle"), "plugins {}").expect("Gradle build file");

        let first = collect_workspace_fingerprint_inputs(&workspace).expect("first observations");
        assert_eq!(
            first
                .direct_maven_modules
                .iter()
                .map(String::as_str)
                .collect::<BTreeSet<_>>(),
            BTreeSet::from(["alpha", "zeta"])
        );

        let added = workspace.join("middle");
        fs::create_dir_all(&added).expect("added module directory");
        fs::write(added.join("pom.xml"), "<project/>").expect("added module pom");
        let changed =
            collect_workspace_fingerprint_inputs(&workspace).expect("changed observations");

        assert_eq!(
            changed
                .direct_maven_modules
                .iter()
                .map(String::as_str)
                .collect::<BTreeSet<_>>(),
            BTreeSet::from(["alpha", "middle", "zeta"])
        );
        fs::remove_dir_all(workspace).ok();
    }

    #[test]
    fn jdtls_version_prefers_the_selected_installation_manifest() {
        let root = temp_dir();
        let bin = root.join("bin");
        fs::create_dir_all(&bin).expect("bin directory");
        let executable = bin.join("jdtls.bat");
        fs::write(&executable, "@echo off\n").expect("JDTLS executable");
        fs::write(root.join("manifest.json"), r#"{"version":"7.6.5"}"#).expect("JDTLS manifest");

        assert_eq!(
            jdtls_version_for_executable(&executable).expect("JDTLS version"),
            "7.6.5"
        );
        fs::remove_dir_all(root).ok();
    }

    #[test]
    fn jdtls_version_falls_back_to_the_core_plugin_name() {
        let root = temp_dir();
        let bin = root.join("bin");
        let plugins = root.join("plugins");
        fs::create_dir_all(&bin).expect("bin directory");
        fs::create_dir_all(&plugins).expect("plugins directory");
        let executable = bin.join("jdtls.bat");
        fs::write(&executable, "@echo off\n").expect("JDTLS executable");
        fs::write(
            plugins.join("org.eclipse.jdt.ls.core_4.3.2.20260823.jar"),
            [],
        )
        .expect("JDTLS core plugin");

        assert_eq!(
            jdtls_version_for_executable(&executable).expect("JDTLS version"),
            "4.3.2"
        );
        fs::remove_dir_all(root).ok();
    }

    #[test]
    fn clearing_java_index_preserves_other_workspace_states() {
        let workspace = temp_dir();
        let cache = temp_dir();
        let current_fingerprint = "build=pom.xml@1:1|modules=core|jdtls=1.38.0";
        let current_key = lithe_core::jdt_workspace_key(&workspace, Some(current_fingerprint));
        let sibling_key = lithe_core::jdt_workspace_key(&workspace, Some("older-structure"));
        let current = cache.join("jdtls").join(current_key);
        let sibling = cache.join("jdtls").join(sibling_key);
        fs::create_dir_all(&current).expect("current state directory");
        fs::create_dir_all(&sibling).expect("sibling state directory");
        fs::write(current.join("index.bin"), []).expect("current index");
        fs::write(sibling.join("index.bin"), []).expect("sibling index");

        clear_java_index_directory(&cache, &workspace, Some(current_fingerprint))
            .expect("current Java index should clear");

        assert!(!current.exists());
        assert!(sibling.exists());
        fs::remove_dir_all(workspace).ok();
        fs::remove_dir_all(cache).ok();
    }

    #[test]
    fn expired_cache_cleanup_preserves_active_and_unrecognized_directories() {
        let cache = temp_dir();
        let jdtls_cache = cache.join("jdtls");
        let expired_key = "a".repeat(64);
        let active_key = "b".repeat(64);
        let expired = jdtls_cache.join(&expired_key);
        let active = jdtls_cache.join(&active_key);
        let unrecognized = jdtls_cache.join("not-a-workspace-key");
        for directory in [&expired, &active, &unrecognized] {
            fs::create_dir_all(directory).expect("cache directory");
            fs::write(directory.join("index.bin"), []).expect("cache content");
        }
        let now = now_unix_seconds().expect("clock") + (31 * 24 * 60 * 60);

        let result =
            cleanup_expired_java_index_directories(&cache, &active_key, now, "windows-cache-test")
                .expect("cache cleanup");

        assert_eq!(result.retention_days, 30);
        assert_eq!(result.removed_workspace_keys, vec![expired_key]);
        assert!(!expired.exists());
        assert!(active.exists());
        assert!(active.join(JDT_CACHE_LAST_USED_MARKER).is_file());
        assert!(unrecognized.exists());
        fs::remove_dir_all(cache).ok();
    }

    #[test]
    fn strips_verbatim_prefix_from_windows_launch_paths() {
        assert_eq!(
            normalize_path(Path::new(
                r"\\?\D:\Lithe\LanguageServers\jdtls\bin\jdtls.bat"
            )),
            "D:/Lithe/LanguageServers/jdtls/bin/jdtls.bat"
        );
    }

    #[test]
    fn preserves_unc_root_when_stripping_verbatim_prefix() {
        assert_eq!(
            normalize_path(Path::new(r"\\?\UNC\server\share\jdtls\bin\jdtls.bat")),
            "//server/share/jdtls/bin/jdtls.bat"
        );
    }
}
