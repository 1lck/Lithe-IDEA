//! Windows discovery for the built-in Java language server.
//!
//! Shared JDT LS process ownership stays in `lithe-core`. This adapter only
//! finds `jdtls`, a local JDK, and a cache directory on the current machine.

use crate::run;
use serde::Serialize;
use std::ffi::OsStr;
use std::path::{Path, PathBuf};
use tauri::{AppHandle, Manager};

const JAVA_PROVIDER_ID: &str = "java";
/// Bundled Eclipse JDTLS 1.38 runs on JDK 17–23; newer majors (e.g. 25) fail at startup.
const MIN_JDTLS_JAVA_MAJOR_VERSION: u32 = 17;
const MAX_JDTLS_JAVA_MAJOR_VERSION: u32 = 23;
const JDTLS_EXECUTABLE_NAMES: &[&str] = &["jdtls.bat", "jdtls.cmd", "jdtls.exe", "jdtls"];
const MAX_CURRENT_EXE_JDTLS_WALK_DEPTH: usize = 12;

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

/// Validates a user-selected JDK home before it is stored for JDTLS.
#[tauri::command]
pub fn lsp_validate_java_home(java_home_path: String) -> Result<run::JavaRuntime, String> {
    validate_configured_java_home(&java_home_path)
}

/// Resolves the built-in Java language-server executable, JDK, and cache directory.
#[tauri::command]
pub fn lsp_resolve_java_launch(
    app: AppHandle,
    workspace_path: String,
    java_home_path: Option<String>,
) -> Result<JavaLspLaunch, String> {
    let workspace = PathBuf::from(&workspace_path);
    let project_root = workspace.is_dir().then_some(workspace.as_path());
    let bundled_root = bundled_jdtls_root(&app);
    let resolution = resolve_java_lsp_launch(
        std::env::var_os("PATH").as_deref(),
        bundled_root.as_deref(),
        &jdtls_search_roots(project_root),
        java_home_path.as_deref(),
    )?;

    Ok(JavaLspLaunch {
        provider_id: JAVA_PROVIDER_ID.to_string(),
        language_id: JAVA_PROVIDER_ID.to_string(),
        executable_path: normalize_path(&resolution.executable),
        arguments: Vec::new(),
        runtime_executable_path: run::java_executable(&resolution.java_home)
            .as_deref()
            .map(normalize_path),
        cache_directory: normalize_path(&language_server_cache_directory(&app)),
        environment: JavaLspEnvironment {
            java_home: Some(normalize_path(&resolution.java_home)),
        },
    })
}

fn resolve_java_lsp_launch(
    path_env: Option<&OsStr>,
    bundled_root: Option<&Path>,
    extra_roots: &[PathBuf],
    java_home_override: Option<&str>,
) -> Result<JavaLspResolution, String> {
    let executable =
        find_jdtls_executable(path_env, bundled_root, extra_roots).ok_or_else(|| {
            "Could not find jdtls. Install Eclipse JDT Language Server and add it to PATH, or use a Lithe build that includes the bundled Java language server."
                .to_string()
        })?;
    let java_home = resolve_java_home(java_home_override)?;
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

fn resolve_java_home(java_home_override: Option<&str>) -> Result<PathBuf, String> {
    if let Some(configured) = java_home_override
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        return validate_configured_java_home(configured)
            .map(|runtime| PathBuf::from(runtime.home_path));
    }

    select_compatible_java_runtime(run::discover_toolchains(None).java)
        .map(|runtime| PathBuf::from(runtime.home_path))
        .ok_or_else(|| {
            format!(
                "Could not find JDK {MIN_JDTLS_JAVA_MAJOR_VERSION}–{MAX_JDTLS_JAVA_MAJOR_VERSION} for JDTLS. Install a compatible JDK or select one in Settings > Editor."
            )
        })
}

fn validate_configured_java_home(configured: &str) -> Result<run::JavaRuntime, String> {
    let configured = configured.trim();
    if configured.is_empty() {
        return Err("Select a JDK home directory for JDTLS.".to_string());
    }

    let path = PathBuf::from(configured);
    if !path.is_dir() {
        return Err(format!(
            "The selected JDTLS JDK home is not a directory: {configured}"
        ));
    }

    let runtime = run::probe_java_home(&path).ok_or_else(|| {
        format!("The selected JDTLS JDK home does not contain a working Java runtime: {configured}")
    })?;
    ensure_supported_java_runtime(runtime)
}

fn ensure_supported_java_runtime(runtime: run::JavaRuntime) -> Result<run::JavaRuntime, String> {
    let major_version = java_major_version(&runtime.version).ok_or_else(|| {
        format!(
            "Could not determine the Java version for the selected JDTLS JDK: {}",
            runtime.home_path
        )
    })?;
    if !is_jdtls_compatible_java_major(major_version) {
        return Err(format!(
            "JDTLS requires JDK {MIN_JDTLS_JAVA_MAJOR_VERSION}–{MAX_JDTLS_JAVA_MAJOR_VERSION}; the selected JDK is version {}.",
            runtime.version
        ));
    }
    Ok(runtime)
}

fn is_jdtls_compatible_java_major(major_version: u32) -> bool {
    (MIN_JDTLS_JAVA_MAJOR_VERSION..=MAX_JDTLS_JAVA_MAJOR_VERSION).contains(&major_version)
}

fn select_compatible_java_runtime(runtimes: Vec<run::JavaRuntime>) -> Option<run::JavaRuntime> {
    runtimes
        .into_iter()
        .filter(|runtime| {
            java_major_version(&runtime.version).is_some_and(is_jdtls_compatible_java_major)
        })
        .max_by(|left, right| {
            java_major_version(&left.version)
                .cmp(&java_major_version(&right.version))
                .then_with(|| left.version.cmp(&right.version))
                .then_with(|| right.home_path.cmp(&left.home_path))
        })
}

fn java_major_version(version: &str) -> Option<u32> {
    let components = version
        .split(|character: char| !character.is_ascii_digit())
        .filter(|component| !component.is_empty())
        .filter_map(|component| component.parse::<u32>().ok())
        .collect::<Vec<_>>();

    match components.as_slice() {
        [1, legacy_major, ..] => Some(*legacy_major),
        [major, ..] => Some(*major),
        [] => None,
    }
}

fn language_server_cache_directory(app: &AppHandle) -> PathBuf {
    app.path()
        .app_cache_dir()
        .unwrap_or_else(|_| std::env::temp_dir().join("lithe-lsp"))
        .join("language-servers")
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
    use std::fs;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_dir() -> PathBuf {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock")
            .as_nanos();
        let path = std::env::temp_dir().join(format!("lithe-java-lsp-{stamp}"));
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
    fn parses_modern_and_legacy_java_major_versions() {
        assert_eq!(java_major_version("17.0.18"), Some(17));
        assert_eq!(java_major_version("21-ea"), Some(21));
        assert_eq!(java_major_version("1.8.0_442"), Some(8));
        assert_eq!(java_major_version("unknown"), None);
    }

    #[test]
    fn automatic_jdtls_runtime_ignores_old_jdks_and_prefers_the_newest_compatible() {
        let selected = select_compatible_java_runtime(vec![
            java_runtime("C:/jdk-11", "11.0.26"),
            java_runtime("C:/jdk-17", "17.0.18"),
            java_runtime("C:/jdk-21", "21.0.10"),
        ])
        .expect("compatible runtime");

        assert_eq!(selected.home_path, "C:/jdk-21");
    }

    #[test]
    fn automatic_jdtls_runtime_skips_jdk_25_when_a_compatible_jdk_exists() {
        // Regression for #214: highest installed JDK must not win when it is outside 17–23.
        let selected = select_compatible_java_runtime(vec![
            java_runtime("C:/jdk-25", "25.0.1"),
            java_runtime("C:/jdk-21", "21.0.10"),
            java_runtime("C:/jdk-17", "17.0.18"),
        ])
        .expect("compatible runtime");

        assert_eq!(selected.home_path, "C:/jdk-21");
    }

    #[test]
    fn automatic_jdtls_runtime_returns_none_when_only_incompatible_jdks_exist() {
        let selected = select_compatible_java_runtime(vec![
            java_runtime("C:/jdk-11", "11.0.26"),
            java_runtime("C:/jdk-25", "25"),
        ]);

        assert!(selected.is_none());
    }

    #[test]
    fn configured_jdtls_runtime_rejects_java_older_than_17() {
        let error =
            ensure_supported_java_runtime(java_runtime("C:/jdk-11", "11.0.26")).unwrap_err();

        assert!(error.contains("JDK 17–23"), "{error}");
        assert!(error.contains("11.0.26"), "{error}");
    }

    #[test]
    fn configured_jdtls_runtime_rejects_java_newer_than_23() {
        let error =
            ensure_supported_java_runtime(java_runtime("C:/jdk-25", "25.0.1")).unwrap_err();

        assert!(error.contains("JDK 17–23"), "{error}");
        assert!(error.contains("25.0.1"), "{error}");
    }

    #[test]
    fn configured_jdtls_runtime_accepts_jdk_within_supported_range() {
        let runtime =
            ensure_supported_java_runtime(java_runtime("C:/jdk-21", "21.0.10")).expect("accepted");

        assert_eq!(runtime.home_path, "C:/jdk-21");
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

    fn java_runtime(home_path: &str, version: &str) -> run::JavaRuntime {
        run::JavaRuntime {
            home_path: home_path.to_string(),
            version: version.to_string(),
            vendor: "Test JDK".to_string(),
        }
    }
}
