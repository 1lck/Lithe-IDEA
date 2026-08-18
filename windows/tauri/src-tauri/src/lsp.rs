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
const JDTLS_EXECUTABLE_NAMES: &[&str] = &["jdtls.bat", "jdtls.cmd", "jdtls.exe", "jdtls"];

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
    java_home: Option<PathBuf>,
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
        project_root,
        java_home_path.as_deref(),
    )?;

    Ok(JavaLspLaunch {
        provider_id: JAVA_PROVIDER_ID.to_string(),
        language_id: JAVA_PROVIDER_ID.to_string(),
        executable_path: normalize_path(&resolution.executable),
        arguments: Vec::new(),
        runtime_executable_path: resolution
            .java_home
            .as_deref()
            .and_then(run::java_executable)
            .as_deref()
            .map(normalize_path),
        cache_directory: normalize_path(&language_server_cache_directory(&app)),
        environment: JavaLspEnvironment {
            java_home: resolution.java_home.as_deref().map(normalize_path),
        },
    })
}

fn resolve_java_lsp_launch(
    path_env: Option<&OsStr>,
    bundled_root: Option<&Path>,
    extra_roots: &[PathBuf],
    project_root: Option<&Path>,
    java_home_override: Option<&str>,
) -> Result<JavaLspResolution, String> {
    let executable =
        find_jdtls_executable(path_env, bundled_root, extra_roots).ok_or_else(|| {
            "Could not find jdtls. Install Eclipse JDT Language Server and add it to PATH."
                .to_string()
        })?;
    let java_home = resolve_java_home(project_root, java_home_override);
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
    app.path()
        .resource_dir()
        .ok()
        .map(|directory| directory.join("LanguageServers").join("jdtls"))
}

fn resolve_java_home(
    project_root: Option<&Path>,
    java_home_override: Option<&str>,
) -> Option<PathBuf> {
    if let Some(configured) = java_home_override
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        let path = PathBuf::from(configured);
        if run::java_executable(&path).is_some() {
            return Some(path);
        }
    }
    run::discover_toolchains(project_root)
        .java
        .into_iter()
        .next()
        .map(|runtime| PathBuf::from(runtime.home_path))
}

fn language_server_cache_directory(app: &AppHandle) -> PathBuf {
    app.path()
        .app_cache_dir()
        .unwrap_or_else(|_| std::env::temp_dir().join("lithe-lsp"))
        .join("language-servers")
}

fn normalize_path(path: &Path) -> String {
    path.to_string_lossy().replace('\\', "/")
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
        let error =
            resolve_java_lsp_launch(None, None, &[missing.clone()], None, None).unwrap_err();
        assert!(error.contains("jdtls"), "{error}");
        fs::remove_dir_all(missing).ok();
    }
}
