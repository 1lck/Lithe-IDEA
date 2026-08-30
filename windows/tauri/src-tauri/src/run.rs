//! Windows adapters for run-configuration persistence, toolchain discovery, and process launch.
//!
//! Shared detection, merge, and launch-plan assembly stay in `lithe-core`. This
//! module only writes `.lithe` documents, finds local JDK/Maven installations,
//! and streams child-process output to the workbench.

use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::{Mutex, OnceLock};
use std::thread;
use tauri::{AppHandle, Emitter, Manager};

const CREATE_NO_WINDOW: u32 = 0x0800_0000;
const SKIPPED_DIRECTORIES: &[&str] = &[
    "target",
    "node_modules",
    ".git",
    "build",
    "dist",
    "out",
    ".idea",
    ".lithe",
    "bin",
    "obj",
    "__pycache__",
    ".gradle",
    "vendor",
    "coverage",
    ".svn",
    ".hg",
];
const MAX_JAVA_SOURCES: usize = 8_000;
const LITHE_GITIGNORE_ENTRIES: &[&str] = &["run/local.json", "toolchains/local.json", "**/*.tmp"];

pub struct RunProcessManager;

struct RunningSession {
    pid: u32,
    stdin: Option<ChildStdin>,
}

impl Default for RunProcessManager {
    fn default() -> Self {
        Self
    }
}

fn sessions() -> &'static Mutex<HashMap<String, RunningSession>> {
    static SESSIONS: OnceLock<Mutex<HashMap<String, RunningSession>>> = OnceLock::new();
    SESSIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WriteGeneratedArgs {
    pub root: PathBuf,
    pub generated: Value,
    pub toolchain_requirements: Value,
    pub default_run_configuration: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WriteDocumentsArgs {
    pub root: PathBuf,
    pub documents: Vec<RunDocumentWrite>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RunDocumentWrite {
    pub relative_path: String,
    pub contents: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DiscoveredToolchains {
    pub java: Vec<JavaRuntime>,
    pub maven: Vec<MavenRuntime>,
    pub runtimes: Vec<GenericRuntime>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct JavaRuntime {
    pub home_path: String,
    pub version: String,
    pub vendor: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MavenRuntime {
    pub executable_path: String,
    pub version: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GenericRuntime {
    pub id: String,
    #[serde(rename = "type")]
    pub kind: String,
    pub executable_path: String,
    pub version: String,
    pub vendor: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ResolveLaunchArgs {
    pub root: PathBuf,
    pub executable: LaunchExecutable,
    pub working_directory: String,
    #[serde(default)]
    pub java_home_path: String,
    #[serde(default)]
    pub maven_executable_path: String,
    #[serde(default)]
    pub maven_java_home_path: String,
    #[serde(default)]
    pub runtime_executable_paths: HashMap<String, String>,
    #[serde(default)]
    pub environment: Map<String, Value>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LaunchExecutable {
    pub toolchain: Option<String>,
    pub command: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResolvedLaunch {
    pub executable: String,
    pub working_directory: String,
    pub environment: HashMap<String, String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StartProcessArgs {
    pub session_id: String,
    pub executable: String,
    pub arguments: Vec<String>,
    pub working_directory: String,
    #[serde(default)]
    pub environment: HashMap<String, String>,
}

#[tauri::command]
pub fn run_list_java_sources(root: PathBuf) -> Result<Vec<String>, String> {
    let root = existing_directory(&root)?;
    let mut paths = Vec::new();
    collect_java_sources(&root, &root, &mut paths)?;
    paths.sort();
    Ok(paths)
}

#[tauri::command]
pub fn run_write_generated(args: WriteGeneratedArgs) -> Result<(), String> {
    write_generated_documents(
        &args.root,
        &args.generated,
        &args.toolchain_requirements,
        args.default_run_configuration.as_deref(),
    )
}

#[tauri::command]
pub fn run_write_documents(args: WriteDocumentsArgs) -> Result<(), String> {
    let root = existing_directory(&args.root)?;
    if args.documents.is_empty() || args.documents.len() > 3 {
        return Err("A run configuration save must contain one to three documents.".into());
    }
    let mut seen = std::collections::HashSet::new();
    let mut prepared = Vec::with_capacity(args.documents.len());
    for document in args.documents {
        let target = run_document_target(&root, &document.relative_path)?;
        if !seen.insert(target.clone()) {
            return Err("A run configuration save cannot write the same document twice.".into());
        }
        prepared.push((target, document.contents.into_bytes()));
    }
    for (target, _) in &prepared {
        if let Some(parent) = target.parent() {
            fs::create_dir_all(parent).map_err(|error| error.to_string())?;
        }
    }
    ensure_lithe_gitignore(&root.join(".lithe").join(".gitignore"))?;
    write_document_transaction(&prepared, atomic_write)
}

#[tauri::command]
pub fn run_discover_toolchains(
    root: PathBuf,
    java_home_path: Option<String>,
    maven_executable_path: Option<String>,
    runtime_executable_paths: Option<HashMap<String, String>>,
) -> Result<DiscoveredToolchains, String> {
    let project_root = existing_directory(&root).ok();
    Ok(discover_toolchains_with_overrides(
        project_root.as_deref(),
        java_home_path.as_deref(),
        maven_executable_path.as_deref(),
        runtime_executable_paths.as_ref(),
    ))
}

#[tauri::command]
pub fn run_resolve_launch(args: ResolveLaunchArgs) -> Result<ResolvedLaunch, String> {
    let root = existing_directory(&args.root)?;
    let working_directory = resolve_working_directory(&root, &args.working_directory)?;
    let java_home = resolve_java_home(&root, &args.java_home_path)?;
    let maven_java_home = if args.maven_java_home_path.trim().is_empty() {
        java_home.clone()
    } else {
        resolve_java_home(&root, &args.maven_java_home_path)?
    };
    let executable = resolve_executable(
        &root,
        &working_directory,
        &args.executable,
        &args.maven_executable_path,
        java_home.as_deref(),
        &args.runtime_executable_paths,
    )?;
    let mut environment = std::env::vars().collect::<HashMap<_, _>>();
    if let Some(home) = &java_home {
        environment.insert("JAVA_HOME".into(), home.clone());
    }
    for (key, value) in args.environment {
        if let Some(text) =
            resolve_environment_value(&value, java_home.as_deref(), maven_java_home.as_deref())
        {
            environment.insert(key, text);
        }
    }
    if let Some(home) = maven_java_home.or(java_home) {
        environment.entry("JAVA_HOME".into()).or_insert(home);
    }
    prepend_runtime_paths(
        &mut environment,
        &args.runtime_executable_paths,
        &executable,
    )?;
    Ok(ResolvedLaunch {
        executable,
        working_directory: working_directory.to_string_lossy().into_owned(),
        environment,
    })
}

#[tauri::command]
pub fn run_start_process(app: AppHandle, args: StartProcessArgs) -> Result<(), String> {
    stop_session(&args.session_id);
    let mut command = command_for_executable(&args.executable, &args.arguments);
    command
        .current_dir(&args.working_directory)
        .envs(&args.environment)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    apply_creation_flags(&mut command);
    let mut child = command
        .spawn()
        .map_err(|error| format!("Unable to start process: {error}"))?;
    let pid = child.id();
    let stdin = child.stdin.take();
    let stdout = child.stdout.take();
    let stderr = child.stderr.take();
    sessions()
        .lock()
        .map_err(|_| "Run process state is unavailable".to_string())?
        .insert(args.session_id.clone(), RunningSession { pid, stdin });

    let stdout_reader = spawn_output_reader(app.clone(), args.session_id.clone(), stdout);
    let stderr_reader = spawn_output_reader(app.clone(), args.session_id.clone(), stderr);
    spawn_exit_waiter(
        app,
        args.session_id,
        child,
        pid,
        stdout_reader,
        stderr_reader,
    );
    Ok(())
}

#[tauri::command]
pub fn run_stop_process(session_id: String) -> Result<(), String> {
    stop_session(&session_id);
    Ok(())
}

#[tauri::command]
pub fn run_write_stdin(session_id: String, input: String) -> Result<(), String> {
    let mut current = sessions()
        .lock()
        .map_err(|_| "Run process state is unavailable".to_string())?;
    let session = current
        .get_mut(&session_id)
        .ok_or_else(|| "The run process is no longer active.".to_string())?;
    let stdin = session
        .stdin
        .as_mut()
        .ok_or_else(|| "The run process does not accept input.".to_string())?;
    stdin
        .write_all(input.as_bytes())
        .map_err(|error| format!("Could not write to process input: {error}"))
}

/// Removes the abandoned `run/` app-data directory written by an earlier
/// implementation. Other app-data content (window state, settings) is kept.
pub fn cleanup_legacy_appdata(app: &AppHandle) {
    let Ok(app_dir) = app.path().app_data_dir() else {
        return;
    };
    let run_dir = app_dir.join("run");
    if run_dir.is_dir() {
        let _ = fs::remove_dir_all(&run_dir);
    }
}

fn write_generated_documents(
    root: &Path,
    generated: &Value,
    requirements: &Value,
    default_run_configuration: Option<&str>,
) -> Result<(), String> {
    let root = existing_directory(root)?;
    let lithe_directory = root.join(".lithe");
    let run_directory = lithe_directory.join("run");
    let toolchain_directory = lithe_directory.join("toolchains");
    let generated_path = run_directory.join("generated.json");
    let requirements_path = toolchain_directory.join("requirements.json");
    let ignore_path = lithe_directory.join(".gitignore");
    let manifest_path = lithe_directory.join("project.json");
    for path in [
        &generated_path,
        &requirements_path,
        &ignore_path,
        &manifest_path,
    ] {
        validate_write_target(&root, path)?;
    }
    fs::create_dir_all(&run_directory).map_err(|error| error.to_string())?;
    fs::create_dir_all(&toolchain_directory).map_err(|error| error.to_string())?;
    atomic_write(&requirements_path, pretty_json(requirements)?.as_bytes())?;
    ensure_lithe_gitignore(&ignore_path)?;
    if !manifest_path.exists() {
        let mut manifest = json!({ "version": 1 });
        if let Some(default_id) = default_run_configuration.filter(|value| !value.is_empty()) {
            manifest["defaultRunConfiguration"] = json!(default_id);
        }
        atomic_write(&manifest_path, pretty_json(&manifest)?.as_bytes())?;
    }
    atomic_write(&generated_path, pretty_json(generated)?.as_bytes())
}

fn collect_java_sources(
    root: &Path,
    directory: &Path,
    paths: &mut Vec<String>,
) -> Result<(), String> {
    if paths.len() >= MAX_JAVA_SOURCES {
        return Ok(());
    }
    let entries = fs::read_dir(directory).map_err(|error| error.to_string())?;
    for entry in entries {
        let entry = entry.map_err(|error| error.to_string())?;
        let path = entry.path();
        let file_type = entry.file_type().map_err(|error| error.to_string())?;
        if file_type.is_dir() {
            let name = entry.file_name().to_string_lossy().to_string();
            if is_skipped_directory(&name) {
                continue;
            }
            collect_java_sources(root, &path, paths)?;
            continue;
        }
        if file_type.is_file() {
            let name = entry.file_name().to_string_lossy().to_string();
            if name.to_ascii_lowercase().ends_with(".java") {
                if let Some(relative) = workspace_relative(root, &path) {
                    paths.push(relative);
                }
            }
        }
    }
    Ok(())
}

fn is_skipped_directory(name: &str) -> bool {
    name.starts_with('.')
        || SKIPPED_DIRECTORIES
            .iter()
            .any(|value| value.eq_ignore_ascii_case(name))
}

fn workspace_relative(root: &Path, path: &Path) -> Option<String> {
    path.strip_prefix(root)
        .ok()
        .map(|relative| relative.to_string_lossy().replace('\\', "/"))
}

fn existing_directory(path: &Path) -> Result<PathBuf, String> {
    let canonical = normalize_path(path);
    if !canonical.is_dir() {
        return Err("The project directory is unavailable.".into());
    }
    Ok(canonical)
}

fn normalize_path(path: &Path) -> PathBuf {
    let canonical = path.canonicalize().unwrap_or_else(|_| path.to_path_buf());
    let text = canonical.to_string_lossy();
    PathBuf::from(text.strip_prefix(r"\\?\").unwrap_or(text.as_ref()))
}

fn validate_write_target(root: &Path, target: &Path) -> Result<(), String> {
    let root = normalize_path(root);
    let parent = target
        .parent()
        .map(normalize_path)
        .unwrap_or_else(|| root.clone());
    let root_text = root.to_string_lossy().to_ascii_lowercase();
    let parent_text = parent.to_string_lossy().to_ascii_lowercase();
    if parent_text != root_text && !parent_text.starts_with(&(root_text.clone() + "\\")) {
        return Err("Refusing to write outside the project directory.".into());
    }
    Ok(())
}

pub(crate) fn atomic_write(path: &Path, contents: &[u8]) -> Result<(), String> {
    if path.exists() {
        if let Ok(existing) = fs::read(path) {
            if existing == contents {
                return Ok(());
            }
        }
    }
    let file_name = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| "document.tmp".into());
    let temporary = path.with_file_name(format!("{file_name}.tmp"));
    fs::write(&temporary, contents).map_err(|error| error.to_string())?;
    let result = replace_run_document(&temporary, path);
    if result.is_err() {
        fs::remove_file(&temporary).ok();
    }
    result
}

fn ensure_lithe_gitignore(path: &Path) -> Result<(), String> {
    let existing = if path.is_file() {
        fs::read_to_string(path).map_err(|error| error.to_string())?
    } else {
        String::new()
    };
    let mut lines = existing.lines().map(str::to_string).collect::<Vec<_>>();
    for entry in LITHE_GITIGNORE_ENTRIES {
        if !lines.iter().any(|line| line.trim() == *entry) {
            lines.push((*entry).to_string());
        }
    }
    let contents = lines.join("\n") + "\n";
    atomic_write(path, contents.as_bytes())
}

#[cfg(target_os = "windows")]
fn replace_run_document(source: &Path, destination: &Path) -> Result<(), String> {
    use std::os::windows::ffi::OsStrExt;
    use windows_sys::Win32::Storage::FileSystem::{
        MoveFileExW, MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH,
    };

    let source = source
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect::<Vec<_>>();
    let destination = destination
        .as_os_str()
        .encode_wide()
        .chain(std::iter::once(0))
        .collect::<Vec<_>>();
    // Windows rename does not replace an existing file, so commit through the
    // native replace primitive without creating a missing-document window.
    let moved = unsafe {
        MoveFileExW(
            source.as_ptr(),
            destination.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    };
    if moved == 0 {
        Err(std::io::Error::last_os_error().to_string())
    } else {
        Ok(())
    }
}

#[cfg(not(target_os = "windows"))]
fn replace_run_document(source: &Path, destination: &Path) -> Result<(), String> {
    fs::rename(source, destination).map_err(|error| error.to_string())
}

fn run_document_target(root: &Path, relative_path: &str) -> Result<PathBuf, String> {
    let relative = relative_path.replace('\\', "/");
    if !matches!(
        relative.as_str(),
        "run/local.json" | "run/configurations.json" | "toolchains/local.json" | "project.json"
    ) {
        return Err("Run documents can only be written to supported .lithe paths".into());
    }
    let target = join_relative(&root.join(".lithe"), &relative);
    validate_write_target(root, &target)?;
    Ok(target)
}

fn write_document_transaction<F>(
    documents: &[(PathBuf, Vec<u8>)],
    mut writer: F,
) -> Result<(), String>
where
    F: FnMut(&Path, &[u8]) -> Result<(), String>,
{
    let snapshots = documents
        .iter()
        .map(|(path, _)| {
            if path.exists() {
                fs::read(path).map(Some).map_err(|error| error.to_string())
            } else {
                Ok(None)
            }
        })
        .collect::<Result<Vec<_>, String>>()?;
    let mut completed: Vec<usize> = Vec::new();
    for (index, (path, contents)) in documents.iter().enumerate() {
        if let Err(save_error) = writer(path, contents) {
            let mut rollback_error = None;
            for completed_index in completed.into_iter().rev() {
                let (completed_path, _) = &documents[completed_index];
                let restored = if let Some(previous) = &snapshots[completed_index] {
                    writer(completed_path, previous)
                } else if completed_path.exists() {
                    fs::remove_file(completed_path).map_err(|error| error.to_string())
                } else {
                    Ok(())
                };
                if let Err(error) = restored {
                    rollback_error = Some(error);
                }
            }
            return match rollback_error {
                Some(error) => Err(format!(
                    "Run configuration save failed ({save_error}) and rollback failed ({error})."
                )),
                None => Err(save_error),
            };
        }
        completed.push(index);
    }
    Ok(())
}

fn join_relative(root: &Path, relative: &str) -> PathBuf {
    relative
        .split(['/', '\\'])
        .filter(|part| !part.is_empty() && *part != ".")
        .fold(root.to_path_buf(), |path, part| path.join(part))
}

fn pretty_json(value: &Value) -> Result<String, String> {
    serde_json::to_string_pretty(value).map_err(|error| error.to_string())
}

pub(crate) fn discover_toolchains(project_root: Option<&Path>) -> DiscoveredToolchains {
    discover_toolchains_with_overrides(project_root, None, None, None)
}

fn discover_toolchains_with_overrides(
    project_root: Option<&Path>,
    java_home_path: Option<&str>,
    maven_executable_path: Option<&str>,
    runtime_executable_paths: Option<&HashMap<String, String>>,
) -> DiscoveredToolchains {
    let mut java = Vec::new();
    let mut seen_homes = std::collections::HashSet::new();
    let mut homes = java_home_candidates(project_root);
    if let Some(path) = java_home_path.filter(|value| !value.trim().is_empty()) {
        homes.insert(0, PathBuf::from(path));
    }
    for home in homes {
        if !seen_homes.insert(home.clone()) {
            continue;
        }
        if let Some(runtime) = probe_java_home(&home) {
            java.push(runtime);
        }
    }
    java.sort_by(|left, right| {
        right
            .version
            .cmp(&left.version)
            .then(left.home_path.cmp(&right.home_path))
    });

    let mut maven = Vec::new();
    let mut seen_executables = std::collections::HashSet::new();
    let mut executables = maven_executable_candidates(project_root);
    if let Some(path) = maven_executable_path.filter(|value| !value.trim().is_empty()) {
        executables.splice(0..0, custom_maven_executable_candidates(Path::new(path)));
    }
    for executable in executables {
        if !seen_executables.insert(executable.clone()) {
            continue;
        }
        if let Some(runtime) = probe_maven(&executable) {
            maven.push(runtime);
        }
    }

    let mut runtimes = Vec::new();
    let mut seen_runtimes = std::collections::HashSet::new();
    let mut node_executables = node_executable_candidates(project_root);
    if let Some(path) = runtime_executable_paths
        .and_then(|paths| paths.get("project-node"))
        .filter(|value| !value.trim().is_empty())
    {
        node_executables.splice(0..0, custom_node_executable_candidates(Path::new(path)));
    }
    for executable in node_executables {
        let normalized = normalize_path(&executable);
        if !seen_runtimes.insert(normalized.clone()) {
            continue;
        }
        if let Some(runtime) = probe_node(&normalized) {
            runtimes.push(runtime);
        }
    }
    runtimes.sort_by(|left, right| {
        runtime_version_parts(&right.version)
            .cmp(&runtime_version_parts(&left.version))
            .then(left.executable_path.cmp(&right.executable_path))
    });
    DiscoveredToolchains {
        java,
        maven,
        runtimes,
    }
}

fn node_executable_candidates(project_root: Option<&Path>) -> Vec<PathBuf> {
    let mut executables = Vec::new();
    for name in ["node.exe", "node"] {
        if let Some(path) = lookup_on_path(name) {
            executables.push(path);
        }
    }
    for key in ["NVM_SYMLINK", "NODE_HOME"] {
        if let Ok(path) = std::env::var(key) {
            executables.extend(custom_node_executable_candidates(Path::new(&path)));
        }
    }
    for key in ["ProgramFiles", "LOCALAPPDATA"] {
        if let Ok(base) = std::env::var(key) {
            let base = PathBuf::from(base);
            executables.push(base.join("nodejs").join("node.exe"));
            executables.push(base.join("Programs").join("nodejs").join("node.exe"));
        }
    }
    for key in ["NVM_HOME", "APPDATA"] {
        if let Ok(base) = std::env::var(key) {
            append_node_versions(&mut executables, Path::new(&base));
            append_node_versions(&mut executables, &PathBuf::from(base).join("nvm"));
        }
    }
    if let Ok(profile) = std::env::var("USERPROFILE") {
        let profile = PathBuf::from(profile);
        executables.push(profile.join("scoop/apps/nodejs/current/node.exe"));
        executables.push(profile.join("scoop/apps/nodejs-lts/current/node.exe"));
        append_node_versions(&mut executables, &profile.join("AppData/Roaming/nvm"));
    }
    if let Some(root) = project_root {
        executables.push(root.join(".lithe/toolchains/node/node.exe"));
    }
    executables
}

fn append_node_versions(executables: &mut Vec<PathBuf>, root: &Path) {
    let Ok(entries) = fs::read_dir(root) else {
        return;
    };
    for entry in entries.flatten() {
        if entry.path().is_dir() {
            executables.push(entry.path().join("node.exe"));
        }
    }
}

fn custom_node_executable_candidates(path: &Path) -> Vec<PathBuf> {
    if path.is_file() {
        return vec![path.to_path_buf()];
    }
    vec![path.join("node.exe"), path.join("node")]
}

fn probe_node(executable: &Path) -> Option<GenericRuntime> {
    if !executable.is_file() {
        return None;
    }
    let output = command_output(executable, &["--version"]);
    Some(GenericRuntime {
        id: "project-node".to_string(),
        kind: "node".to_string(),
        executable_path: normalize_path(executable).to_string_lossy().into_owned(),
        version: node_version(&output)?,
        vendor: "Node.js".to_string(),
    })
}

fn java_home_candidates(project_root: Option<&Path>) -> Vec<PathBuf> {
    let mut homes = Vec::new();
    if let Ok(value) = std::env::var("JAVA_HOME") {
        homes.push(PathBuf::from(value));
    }
    if let Some(path_java) = lookup_on_path("java.exe").or_else(|| lookup_on_path("java")) {
        if let Some(home) = java_home_from_executable(&path_java) {
            homes.push(home);
        }
    }
    for root in well_known_java_roots() {
        if let Ok(entries) = fs::read_dir(root) {
            for entry in entries.flatten() {
                let path = entry.path();
                if path.is_dir() {
                    homes.push(path.join("Contents").join("Home"));
                    homes.push(path);
                }
            }
        }
    }
    if let Some(root) = project_root {
        homes.push(root.join(".lithe").join("toolchains").join("jdk"));
    }
    homes
}

fn well_known_java_roots() -> Vec<PathBuf> {
    let mut roots = Vec::new();
    for key in ["ProgramFiles", "ProgramFiles(x86)", "LOCALAPPDATA"] {
        if let Ok(base) = std::env::var(key) {
            let base = PathBuf::from(base);
            roots.push(base.join("Java"));
            roots.push(base.join("Eclipse Adoptium"));
            roots.push(base.join("Microsoft"));
            roots.push(base.join("Amazon Corretto"));
            roots.push(base.join("BellSoft"));
            roots.push(base.join("Zulu"));
            roots.push(base.join("Java").join("jdk"));
            if key == "LOCALAPPDATA" {
                roots.push(base.join("Programs").join("Eclipse Adoptium"));
            }
        }
    }
    if let Ok(profile) = std::env::var("USERPROFILE") {
        let profile = PathBuf::from(profile);
        roots.push(profile.join(".jdks"));
        roots.push(profile.join(".sdkman").join("candidates").join("java"));
    }
    roots
}

fn maven_executable_candidates(project_root: Option<&Path>) -> Vec<PathBuf> {
    let mut executables = Vec::new();
    if let Some(root) = project_root {
        executables.push(root.join("mvnw.cmd"));
        executables.push(root.join("mvnw.bat"));
        executables.push(root.join("mvnw"));
    }
    if let Ok(home) = std::env::var("MAVEN_HOME") {
        let home = PathBuf::from(home);
        executables.push(home.join("bin").join("mvn.cmd"));
        executables.push(home.join("bin").join("mvn.bat"));
        executables.push(home.join("bin").join("mvn"));
    }
    if let Ok(home) = std::env::var("M2_HOME") {
        let home = PathBuf::from(home);
        executables.push(home.join("bin").join("mvn.cmd"));
        executables.push(home.join("bin").join("mvn"));
    }
    for name in ["mvn.cmd", "mvn.bat", "mvn.exe", "mvn"] {
        if let Some(path) = lookup_on_path(name) {
            executables.push(path);
        }
    }
    executables
}

fn custom_maven_executable_candidates(path: &Path) -> Vec<PathBuf> {
    if path.is_file() {
        return vec![path.to_path_buf()];
    }
    let bin = path.join("bin");
    let mut candidates = ["mvn.cmd", "mvn.bat", "mvn.exe", "mvn"]
        .into_iter()
        .map(|name| bin.join(name))
        .collect::<Vec<_>>();
    candidates.push(path.to_path_buf());
    candidates
}

pub(crate) fn probe_java_home(home: &Path) -> Option<JavaRuntime> {
    let java = java_executable(home)?;
    let output = command_output(&java, &["-version"]);
    let version = java_version(&output)?;
    let vendor = output
        .lines()
        .find(|line| line.contains("Runtime Environment") || line.contains("VM"))
        .unwrap_or("")
        .trim()
        .to_string();
    Some(JavaRuntime {
        home_path: normalize_path(home).to_string_lossy().into_owned(),
        version,
        vendor,
    })
}

fn probe_maven(executable: &Path) -> Option<MavenRuntime> {
    if !executable.is_file() {
        return None;
    }
    let output = command_output(executable, &["-version"]);
    let version = maven_version(&output).unwrap_or_default();
    Some(MavenRuntime {
        executable_path: normalize_path(executable).to_string_lossy().into_owned(),
        version,
    })
}

pub(crate) fn java_executable(home: &Path) -> Option<PathBuf> {
    for name in ["java.exe", "java"] {
        let candidate = home.join("bin").join(name);
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

fn java_home_from_executable(executable: &Path) -> Option<PathBuf> {
    executable
        .parent()
        .and_then(Path::parent)
        .map(Path::to_path_buf)
}

fn resolve_java_home(root: &Path, override_path: &str) -> Result<Option<String>, String> {
    let configured = override_path.trim();
    if !configured.is_empty() {
        let path = if Path::new(configured).is_absolute() {
            PathBuf::from(configured)
        } else {
            root.join(configured)
        };
        if java_executable(&path).is_some() {
            return Ok(Some(normalize_path(&path).to_string_lossy().into_owned()));
        }
        return Err(format!(
            "JDK Home does not point to a directory: {configured}"
        ));
    }
    Ok(discover_toolchains(Some(root))
        .java
        .first()
        .map(|runtime| runtime.home_path.clone()))
}

fn resolve_executable(
    root: &Path,
    working_directory: &Path,
    executable: &LaunchExecutable,
    maven_override: &str,
    java_home: Option<&str>,
    runtime_executable_paths: &HashMap<String, String>,
) -> Result<String, String> {
    if let Some(toolchain) = executable.toolchain.as_deref() {
        return match toolchain {
            "project-jdk" => {
                let home = java_home.ok_or_else(|| {
                    "No Java runtime was found. Set JAVA_HOME or install a JDK.".to_string()
                })?;
                java_executable(Path::new(home))
                    .map(|path| path.to_string_lossy().into_owned())
                    .ok_or_else(|| {
                        "No Java runtime was found. Set JAVA_HOME or install a JDK.".into()
                    })
            }
            "project-maven" => resolve_maven_executable(root, working_directory, maven_override),
            other => resolve_generic_runtime(root, other, runtime_executable_paths),
        };
    }
    if let Some(command) = executable
        .command
        .as_deref()
        .filter(|value| !value.is_empty())
    {
        return resolve_command_executable(command, runtime_executable_paths)
            .map(|path| path.to_string_lossy().into_owned())
            .ok_or_else(|| format!("Could not find executable: {command}"));
    }
    Err("The launch plan names neither a toolchain nor a command.".into())
}

fn resolve_generic_runtime(
    root: &Path,
    toolchain: &str,
    runtime_executable_paths: &HashMap<String, String>,
) -> Result<String, String> {
    if let Some(configured) = runtime_executable_paths
        .get(toolchain)
        .map(|value| value.trim())
        .filter(|value| !value.is_empty())
    {
        let path = if Path::new(configured).is_absolute() {
            PathBuf::from(configured)
        } else {
            root.join(configured)
        };
        let candidates = if toolchain == "project-node" {
            custom_node_executable_candidates(&path)
        } else {
            vec![path]
        };
        return candidates
            .into_iter()
            .find(|candidate| candidate.is_file())
            .map(|candidate| normalize_path(&candidate).to_string_lossy().into_owned())
            .ok_or_else(|| format!("Configured executable for {toolchain} does not exist."));
    }
    discover_toolchains(Some(root))
        .runtimes
        .into_iter()
        .find(|runtime| runtime.id == toolchain)
        .map(|runtime| runtime.executable_path)
        .ok_or_else(|| format!("No executable was found for toolchain {toolchain}."))
}

fn resolve_command_executable(
    command: &str,
    runtime_executable_paths: &HashMap<String, String>,
) -> Option<PathBuf> {
    resolve_command_executable_with(command, runtime_executable_paths, lookup_on_path)
}

fn resolve_command_executable_with(
    command: &str,
    runtime_executable_paths: &HashMap<String, String>,
    lookup: impl Fn(&str) -> Option<PathBuf>,
) -> Option<PathBuf> {
    let command_lower = command.to_ascii_lowercase();
    let consumes_node = matches!(
        command_lower.as_str(),
        "node" | "node.exe" | "npm" | "npm.cmd" | "pnpm" | "pnpm.cmd" | "yarn" | "yarn.cmd"
    );
    if consumes_node {
        if let Some(directory) =
            selected_runtime_directory(runtime_executable_paths, "project-node")
        {
            for name in command_file_names(command) {
                let candidate = directory.join(name);
                if candidate.is_file() {
                    return Some(candidate);
                }
            }
            // A package-manager shim can bind to a node.exe beside itself. Once
            // Node is selected, falling back to PATH could launch a different
            // runtime from the one Core validated.
            return None;
        }
    }
    command_file_names(command)
        .into_iter()
        .find_map(|name| lookup(&name))
}

fn command_file_names(command: &str) -> Vec<String> {
    if Path::new(command).extension().is_some() {
        return vec![command.to_string()];
    }
    vec![
        format!("{command}.exe"),
        format!("{command}.cmd"),
        format!("{command}.bat"),
        command.to_string(),
    ]
}

fn selected_runtime_directory(
    runtime_executable_paths: &HashMap<String, String>,
    toolchain: &str,
) -> Option<PathBuf> {
    let path = PathBuf::from(runtime_executable_paths.get(toolchain)?.trim());
    if path.is_dir() {
        Some(path)
    } else {
        path.parent().map(Path::to_path_buf)
    }
}

fn selected_runtime_directories(
    runtime_executable_paths: &HashMap<String, String>,
) -> Vec<PathBuf> {
    runtime_executable_paths
        .values()
        .filter_map(|value| {
            let path = PathBuf::from(value.trim());
            if path.is_dir() {
                Some(path)
            } else {
                path.parent().map(Path::to_path_buf)
            }
        })
        .collect()
}

fn prepend_runtime_paths(
    environment: &mut HashMap<String, String>,
    runtime_executable_paths: &HashMap<String, String>,
    resolved_executable: &str,
) -> Result<(), String> {
    let mut directories = selected_runtime_directories(runtime_executable_paths);
    if let Some(parent) = Path::new(resolved_executable).parent() {
        directories.push(parent.to_path_buf());
    }
    if directories.is_empty() {
        return Ok(());
    }
    if let Some(existing) = environment
        .iter()
        .find(|(key, _)| key.eq_ignore_ascii_case("PATH"))
        .map(|(_, value)| value.clone())
    {
        directories.extend(std::env::split_paths(&existing));
    }
    let mut seen = std::collections::HashSet::new();
    directories.retain(|path| seen.insert(path.to_string_lossy().to_ascii_lowercase()));
    let joined = std::env::join_paths(directories).map_err(|error| error.to_string())?;
    environment.retain(|key, _| !key.eq_ignore_ascii_case("PATH"));
    environment.insert("PATH".to_string(), joined.to_string_lossy().into_owned());
    Ok(())
}

fn resolve_maven_executable(
    root: &Path,
    working_directory: &Path,
    override_path: &str,
) -> Result<String, String> {
    let configured = override_path.trim();
    if !configured.is_empty() {
        let path = if Path::new(configured).is_absolute() {
            PathBuf::from(configured)
        } else {
            root.join(configured)
        };
        let candidates = [
            path.clone(),
            path.join("bin").join("mvn.cmd"),
            path.join("bin").join("mvn.bat"),
            path.join("bin").join("mvn.exe"),
            path.join("bin").join("mvn"),
        ];
        if let Some(found) = candidates.into_iter().find(|candidate| candidate.is_file()) {
            return Ok(normalize_path(&found).to_string_lossy().into_owned());
        }
        return Err("Maven executable path does not exist.".into());
    }
    let mut saw_incomplete_wrapper = false;
    for directory in [working_directory, root] {
        for name in ["mvnw.cmd", "mvnw.bat", "mvnw"] {
            let wrapper = directory.join(name);
            if !wrapper.is_file() {
                continue;
            }
            if maven_wrapper_is_usable(&wrapper) {
                return Ok(normalize_path(&wrapper).to_string_lossy().into_owned());
            }
            saw_incomplete_wrapper = true;
        }
    }
    discover_toolchains(Some(root))
        .maven
        .into_iter()
        .find(|runtime| {
            !runtime.executable_path.ends_with("mvnw.cmd")
                && !runtime.executable_path.ends_with("mvnw.bat")
                && !runtime.executable_path.ends_with("mvnw")
        })
        .map(|runtime| runtime.executable_path)
        .ok_or_else(|| {
            if saw_incomplete_wrapper {
                "Maven wrapper is incomplete (.mvn/wrapper/maven-wrapper.properties is missing) and no system Maven was found. Install Maven or restore the wrapper files.".into()
            } else {
                "No Maven executable was found. Edit this service configuration.".into()
            }
        })
}

fn maven_wrapper_is_usable(wrapper: &Path) -> bool {
    wrapper.parent().is_some_and(|directory| {
        directory
            .join(".mvn")
            .join("wrapper")
            .join("maven-wrapper.properties")
            .is_file()
    })
}

fn resolve_working_directory(root: &Path, relative: &str) -> Result<PathBuf, String> {
    let relative = relative.trim();
    if relative.is_empty() || relative == "." {
        return Ok(root.to_path_buf());
    }
    if relative.contains("..") || Path::new(relative).is_absolute() {
        return Err("Working directory must stay inside the project.".into());
    }
    let path = join_relative(root, relative);
    if !path.is_dir() {
        return Err(format!("Working directory does not exist: {relative}"));
    }
    Ok(normalize_path(&path))
}

fn resolve_environment_value(
    value: &Value,
    java_home: Option<&str>,
    maven_java_home: Option<&str>,
) -> Option<String> {
    if let Some(text) = value.as_str() {
        return Some(text.to_string());
    }
    let object = value.as_object()?;
    let toolchain = object.get("toolchain")?.as_str()?;
    let property = object
        .get("property")
        .and_then(Value::as_str)
        .unwrap_or("home");
    if property != "home" {
        return None;
    }
    match toolchain {
        "project-jdk" => java_home.map(str::to_string),
        "project-maven" => maven_java_home.map(str::to_string),
        _ => java_home.map(str::to_string),
    }
}

fn lookup_on_path(name: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    for directory in std::env::split_paths(&path) {
        let candidate = directory.join(name);
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

fn command_output(executable: &Path, arguments: &[&str]) -> String {
    let arguments = arguments
        .iter()
        .map(|argument| (*argument).to_string())
        .collect::<Vec<_>>();
    let mut command = command_for_executable(&executable.to_string_lossy(), &arguments);
    command
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    apply_creation_flags(&mut command);
    command
        .output()
        .map(|output| {
            let mut text = decode_process_bytes(&output.stdout);
            text.push_str(&decode_process_bytes(&output.stderr));
            text
        })
        .unwrap_or_default()
}

fn is_batch_file(executable: &str) -> bool {
    Path::new(executable)
        .extension()
        .and_then(|value| value.to_str())
        .is_some_and(|extension| {
            extension.eq_ignore_ascii_case("cmd") || extension.eq_ignore_ascii_case("bat")
        })
}

fn command_for_executable(executable: &str, arguments: &[String]) -> Command {
    if is_batch_file(executable) {
        return batch_command(executable, arguments);
    }
    let mut command = Command::new(executable);
    command.args(arguments);
    command
}

fn batch_command(executable: &str, arguments: &[String]) -> Command {
    let mut command = Command::new("cmd.exe");
    // cmd.exe /C only treats the next token as the command. Extra argv after a
    // quoted .cmd path are dropped, so Maven wrappers start with no goals and
    // exit immediately. /D /S /C plus one verbatim command string is the
    // Windows host convention used by Node and the Maven wrapper itself.
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.raw_arg("/D");
        command.raw_arg("/S");
        command.raw_arg("/C");
        command.raw_arg(batch_command_line(executable, arguments));
    }
    #[cfg(not(windows))]
    {
        command.arg("/C").arg(executable).args(arguments);
    }
    command
}

fn batch_command_line(executable: &str, arguments: &[String]) -> String {
    let mut inner = String::from("call ");
    inner.push_str(&quote_windows_arg(executable));
    for argument in arguments {
        inner.push(' ');
        inner.push_str(&quote_windows_arg(argument));
    }
    format!("\"{inner}\"")
}

fn quote_windows_arg(argument: &str) -> String {
    if argument.is_empty() {
        return "\"\"".into();
    }
    let needs_quotes = argument
        .bytes()
        .any(|byte| matches!(byte, b' ' | b'\t' | b'\n' | b'\r' | b'"'));
    if !needs_quotes {
        return argument.to_string();
    }
    let mut quoted = String::from("\"");
    let mut backslashes = 0;
    for character in argument.chars() {
        match character {
            '\\' => backslashes += 1,
            '"' => {
                quoted.push_str(&"\\".repeat(backslashes * 2 + 1));
                quoted.push('"');
                backslashes = 0;
            }
            _ => {
                quoted.push_str(&"\\".repeat(backslashes));
                quoted.push(character);
                backslashes = 0;
            }
        }
    }
    quoted.push_str(&"\\".repeat(backslashes * 2));
    quoted.push('"');
    quoted
}

fn apply_creation_flags(command: &mut Command) {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(CREATE_NO_WINDOW);
    }
    let _ = command;
}

fn decode_process_bytes(bytes: &[u8]) -> String {
    if bytes.is_empty() {
        return String::new();
    }
    if looks_like_real_utf8(bytes) {
        return String::from_utf8_lossy(bytes).into_owned();
    }
    #[cfg(windows)]
    {
        if let Some(text) = decode_windows_code_page(bytes, windows_ansi_code_page()) {
            return text;
        }
    }
    String::from_utf8_lossy(bytes).into_owned()
}

fn looks_like_real_utf8(bytes: &[u8]) -> bool {
    let Ok(text) = std::str::from_utf8(bytes) else {
        return false;
    };
    text.is_ascii()
        || text.chars().any(|character| {
            ('\u{4E00}'..='\u{9FFF}').contains(&character)
                || ('\u{3400}'..='\u{4DBF}').contains(&character)
        })
}

fn incomplete_suffix_len(bytes: &[u8]) -> usize {
    match bytes.last() {
        Some(&byte) if byte >= 0x81 => 1,
        _ => 0,
    }
}

#[cfg(windows)]
mod winapi {
    #[link(name = "kernel32")]
    extern "system" {
        pub fn GetACP() -> u32;
        pub fn MultiByteToWideChar(
            code_page: u32,
            flags: u32,
            src: *const u8,
            src_len: i32,
            dst: *mut u16,
            dst_len: i32,
        ) -> i32;
    }
}

#[cfg(windows)]
fn windows_ansi_code_page() -> u32 {
    unsafe { winapi::GetACP() }
}

#[cfg(windows)]
fn decode_windows_code_page(bytes: &[u8], code_page: u32) -> Option<String> {
    if bytes.is_empty() {
        return Some(String::new());
    }
    unsafe {
        let needed = winapi::MultiByteToWideChar(
            code_page,
            0,
            bytes.as_ptr(),
            bytes.len() as i32,
            std::ptr::null_mut(),
            0,
        );
        if needed <= 0 {
            return None;
        }
        let mut wide = vec![0_u16; needed as usize];
        let written = winapi::MultiByteToWideChar(
            code_page,
            0,
            bytes.as_ptr(),
            bytes.len() as i32,
            wide.as_mut_ptr(),
            needed,
        );
        if written <= 0 {
            return None;
        }
        Some(String::from_utf16_lossy(&wide[..written as usize]))
    }
}

fn java_version(output: &str) -> Option<String> {
    for line in output.lines() {
        let Some(index) = line.find("version") else {
            continue;
        };
        let rest = line[index + "version".len()..].trim();
        if let Some(quoted) = rest.strip_prefix('"') {
            return quoted.split('"').next().map(str::to_string);
        }
        return rest.split_whitespace().next().map(str::to_string);
    }
    None
}

fn maven_version(output: &str) -> Option<String> {
    output.lines().find_map(|line| {
        let rest = line.trim().strip_prefix("Apache Maven")?;
        rest.split_whitespace().next().map(str::to_string)
    })
}

fn node_version(output: &str) -> Option<String> {
    output
        .lines()
        .map(str::trim)
        .find_map(|line| line.strip_prefix('v'))
        .filter(|version| {
            !version.is_empty()
                && version
                    .chars()
                    .all(|character| character.is_ascii_digit() || character == '.')
        })
        .map(str::to_string)
}

fn runtime_version_parts(version: &str) -> Vec<u32> {
    version
        .split('.')
        .filter_map(|part| part.parse::<u32>().ok())
        .collect()
}

fn spawn_output_reader<T: Read + Send + 'static>(
    app: AppHandle,
    session_id: String,
    stream: Option<T>,
) -> thread::JoinHandle<()> {
    thread::spawn(move || {
        let Some(mut stream) = stream else { return };
        let mut buffer = [0_u8; 4096];
        let mut pending = Vec::new();
        loop {
            match stream.read(&mut buffer) {
                Ok(0) => {
                    if !pending.is_empty() {
                        let chunk = decode_process_bytes(&pending);
                        if !chunk.is_empty() {
                            let _ = app.emit(
                                "run-output",
                                json!({ "sessionId": session_id, "chunk": chunk }),
                            );
                        }
                    }
                    break;
                }
                Ok(count) => {
                    pending.extend_from_slice(&buffer[..count]);
                    let keep = incomplete_suffix_len(&pending);
                    let ready = pending.len().saturating_sub(keep);
                    if ready == 0 {
                        continue;
                    }
                    let chunk = decode_process_bytes(&pending[..ready]);
                    pending.drain(..ready);
                    if chunk.is_empty() {
                        continue;
                    }
                    let _ = app.emit(
                        "run-output",
                        json!({ "sessionId": session_id, "chunk": chunk }),
                    );
                }
                Err(_) => break,
            }
        }
    })
}

fn spawn_exit_waiter(
    app: AppHandle,
    session_id: String,
    mut child: Child,
    pid: u32,
    stdout_reader: thread::JoinHandle<()>,
    stderr_reader: thread::JoinHandle<()>,
) {
    thread::spawn(move || {
        let exit_code = child
            .wait()
            .ok()
            .and_then(|status| status.code())
            .unwrap_or(-1);
        let _ = stdout_reader.join();
        let _ = stderr_reader.join();
        let stale = match sessions().lock() {
            Ok(mut current) => match current.get(&session_id) {
                Some(session) if session.pid == pid => {
                    current.remove(&session_id);
                    false
                }
                _ => true,
            },
            Err(_) => true,
        };
        if stale {
            return;
        }
        let _ = app.emit(
            "run-exit",
            json!({ "sessionId": session_id, "exitCode": exit_code }),
        );
    });
}

fn stop_session(session_id: &str) {
    let pid = sessions()
        .lock()
        .ok()
        .and_then(|mut current| current.remove(session_id).map(|session| session.pid));
    if let Some(pid) = pid {
        let mut command = Command::new("taskkill");
        command.args(["/F", "/T", "/PID", &pid.to_string()]);
        apply_creation_flags(&mut command);
        let _ = command.output();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::{SystemTime, UNIX_EPOCH};

    fn temp_project() -> PathBuf {
        let stamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .expect("clock")
            .as_nanos();
        let path = std::env::temp_dir().join(format!("lithe-run-{stamp}"));
        fs::create_dir_all(&path).expect("temp project");
        path
    }

    #[test]
    fn skipped_directories_include_build_outputs() {
        assert!(is_skipped_directory("target"));
        assert!(is_skipped_directory(".git"));
        assert!(is_skipped_directory("node_modules"));
        assert!(!is_skipped_directory("src"));
    }

    #[test]
    fn workspace_relative_paths_use_forward_slashes() {
        let root = PathBuf::from(r"C:\project");
        let file = PathBuf::from(r"C:\project\src\main\java\App.java");
        assert_eq!(
            workspace_relative(&root, &file).as_deref(),
            Some("src/main/java/App.java")
        );
    }

    #[test]
    fn write_generated_creates_lithe_documents() {
        let root = temp_project();
        let generated = json!({
            "version": 2,
            "configurations": [{ "id": "spring-boot.maven:demo", "provider": "spring-boot.maven" }]
        });
        let requirements = json!({ "version": 1, "toolchains": {} });
        write_generated_documents(
            &root,
            &generated,
            &requirements,
            Some("spring-boot.maven:demo"),
        )
        .expect("write");
        assert!(root
            .join(".lithe")
            .join("run")
            .join("generated.json")
            .is_file());
        assert!(root
            .join(".lithe")
            .join("toolchains")
            .join("requirements.json")
            .is_file());
        assert_eq!(
            fs::read_to_string(root.join(".lithe").join(".gitignore")).expect("gitignore"),
            LITHE_GITIGNORE_ENTRIES.join("\n") + "\n"
        );
        let manifest: Value = serde_json::from_str(
            &fs::read_to_string(root.join(".lithe").join("project.json")).expect("manifest"),
        )
        .expect("json");
        assert_eq!(
            manifest["defaultRunConfiguration"],
            "spring-boot.maven:demo"
        );
        fs::remove_dir_all(root).ok();
    }

    #[test]
    fn write_generated_refuses_paths_outside_the_project() {
        let root = temp_project();
        let outside = std::env::temp_dir().join("lithe-run-outside.json");
        let result = validate_write_target(&root, &outside);
        assert!(result.is_err());
        fs::remove_dir_all(root).ok();
    }

    #[test]
    fn document_transaction_restores_the_first_file_when_the_second_write_fails() {
        let root = temp_project();
        let run = root.join(".lithe/run");
        fs::create_dir_all(&run).unwrap();
        let local = run.join("local.json");
        let project = run.join("configurations.json");
        fs::write(&local, b"old-local").unwrap();
        fs::write(&project, b"old-project").unwrap();
        let documents = vec![
            (local.clone(), b"new-local".to_vec()),
            (project.clone(), b"new-project".to_vec()),
        ];
        let mut writes = 0;
        let result = write_document_transaction(&documents, |path, contents| {
            writes += 1;
            if writes == 2 {
                return Err("injected second write failure".into());
            }
            atomic_write(path, contents)
        });

        assert_eq!(result.unwrap_err(), "injected second write failure");
        assert_eq!(fs::read(&local).unwrap(), b"old-local");
        assert_eq!(fs::read(&project).unwrap(), b"old-project");
        fs::remove_dir_all(root).ok();
    }

    #[test]
    fn three_document_transaction_restores_run_and_toolchain_documents() {
        let root = temp_project();
        let run = root.join(".lithe/run");
        let toolchains = root.join(".lithe/toolchains");
        fs::create_dir_all(&run).unwrap();
        fs::create_dir_all(&toolchains).unwrap();
        let local = run.join("local.json");
        let project = run.join("configurations.json");
        let runtime = toolchains.join("local.json");
        fs::write(&local, b"old-local").unwrap();
        fs::write(&project, b"old-project").unwrap();
        fs::write(&runtime, b"old-runtime").unwrap();
        let documents = vec![
            (local.clone(), b"new-local".to_vec()),
            (project.clone(), b"new-project".to_vec()),
            (runtime.clone(), b"new-runtime".to_vec()),
        ];
        let mut writes = 0;
        let result = write_document_transaction(&documents, |path, contents| {
            writes += 1;
            if writes == 3 {
                return Err("injected third write failure".into());
            }
            atomic_write(path, contents)
        });

        assert_eq!(result.unwrap_err(), "injected third write failure");
        assert_eq!(fs::read(&local).unwrap(), b"old-local");
        assert_eq!(fs::read(&project).unwrap(), b"old-project");
        assert_eq!(fs::read(&runtime).unwrap(), b"old-runtime");
        fs::remove_dir_all(root).ok();
    }

    #[test]
    fn gitignore_update_preserves_existing_entries_and_adds_local_toolchains() {
        let root = temp_project();
        let lithe = root.join(".lithe");
        fs::create_dir_all(&lithe).unwrap();
        let path = lithe.join(".gitignore");
        fs::write(&path, "custom-cache/\nrun/local.json\n").unwrap();

        ensure_lithe_gitignore(&path).unwrap();

        let contents = fs::read_to_string(path).unwrap();
        assert!(contents.starts_with("custom-cache/\nrun/local.json\n"));
        assert_eq!(contents.matches("run/local.json").count(), 1);
        assert!(contents.contains("toolchains/local.json\n"));
        assert!(contents.contains("**/*.tmp\n"));
        fs::remove_dir_all(root).ok();
    }

    #[test]
    fn custom_maven_home_discovers_its_bin_executable() {
        let root = temp_project();
        let home = root.join("apache-maven");
        let executable = home.join("bin/mvn.cmd");
        fs::create_dir_all(executable.parent().unwrap()).unwrap();
        fs::write(&executable, "@echo off\n").unwrap();

        let discovered = discover_toolchains_with_overrides(
            Some(&root),
            None,
            Some(home.to_string_lossy().as_ref()),
            None,
        );
        assert!(discovered
            .maven
            .iter()
            .any(|runtime| { Path::new(&runtime.executable_path) == normalize_path(&executable) }));
        fs::remove_dir_all(root).ok();
    }

    #[test]
    fn java_listing_skips_maven_target() {
        let root = temp_project();
        fs::create_dir_all(root.join("src/main/java")).unwrap();
        fs::create_dir_all(root.join("target/classes")).unwrap();
        fs::write(root.join("src/main/java/App.java"), "class App {}").unwrap();
        fs::write(root.join("target/classes/Skip.java"), "class Skip {}").unwrap();
        let paths = run_list_java_sources(root.clone()).expect("list");
        assert_eq!(paths, vec!["src/main/java/App.java"]);
        fs::remove_dir_all(root).ok();
    }

    #[test]
    fn java_version_reads_quoted_runtime_banner() {
        assert_eq!(
            java_version(r#"openjdk version "17.0.18" 2026-01-20"#).as_deref(),
            Some("17.0.18")
        );
    }

    #[test]
    fn node_version_reads_standard_banner() {
        assert_eq!(node_version("v22.14.0\r\n").as_deref(), Some("22.14.0"));
        assert_eq!(node_version("node 22.14.0"), None);
    }

    #[test]
    fn custom_node_path_accepts_an_executable_or_install_directory() {
        let root = temp_project();
        let executable = root.join("node.exe");
        fs::write(&executable, b"node").unwrap();
        assert_eq!(
            custom_node_executable_candidates(&executable),
            vec![executable]
        );
        assert_eq!(
            custom_node_executable_candidates(&root),
            vec![root.join("node.exe"), root.join("node")]
        );
        fs::remove_dir_all(root).ok();
    }

    #[test]
    fn selected_node_directory_resolves_package_manager_before_path() {
        let root = temp_project();
        let node = root.join("node.exe");
        let shell_script = root.join("npm");
        let npm = root.join("npm.cmd");
        fs::write(&node, b"node").unwrap();
        fs::write(&shell_script, b"#!/bin/sh\n").unwrap();
        fs::write(&npm, b"npm").unwrap();
        let paths = HashMap::from([(
            "project-node".to_string(),
            node.to_string_lossy().into_owned(),
        )]);
        assert_eq!(
            resolve_command_executable("npm", &paths).as_deref(),
            Some(npm.as_path())
        );
        fs::remove_dir_all(root).ok();
    }

    #[test]
    fn selected_node_does_not_fall_back_to_another_installations_npm() {
        let root = temp_project();
        let selected_node = root.join("selected/node.exe");
        let path_npm = root.join("path/npm.cmd");
        fs::create_dir_all(selected_node.parent().unwrap()).unwrap();
        fs::create_dir_all(path_npm.parent().unwrap()).unwrap();
        fs::write(&selected_node, b"node").unwrap();
        fs::write(&path_npm, b"npm").unwrap();
        let paths = HashMap::from([(
            "project-node".to_string(),
            selected_node.to_string_lossy().into_owned(),
        )]);

        assert_eq!(
            resolve_command_executable_with("npm", &paths, |_| Some(path_npm.clone())),
            None
        );
        fs::remove_dir_all(root).ok();
    }

    #[test]
    fn selected_runtime_directories_are_prepended_to_launch_path() {
        let root = temp_project();
        let node = root.join("node/node.exe");
        let package_manager = root.join("tools/npm.cmd");
        let original = root.join("existing");
        let mut environment = HashMap::from([(
            "PATH".to_string(),
            std::env::join_paths([&original])
                .unwrap()
                .to_string_lossy()
                .into_owned(),
        )]);
        let paths = HashMap::from([(
            "project-node".to_string(),
            node.to_string_lossy().into_owned(),
        )]);

        prepend_runtime_paths(
            &mut environment,
            &paths,
            package_manager.to_string_lossy().as_ref(),
        )
        .unwrap();
        let launch_path = environment.get("PATH").unwrap();
        let directories = std::env::split_paths(launch_path).collect::<Vec<_>>();
        assert_eq!(
            directories,
            vec![root.join("node"), root.join("tools"), original]
        );
        fs::remove_dir_all(root).ok();
    }

    #[test]
    fn launch_environment_resolves_java_home_from_toolchain_reference() {
        let home = resolve_environment_value(
            &json!({ "toolchain": "project-jdk", "property": "home" }),
            Some(r"C:\jdk"),
            Some(r"C:\maven-jdk"),
        );
        assert_eq!(home.as_deref(), Some(r"C:\jdk"));
        assert_eq!(
            resolve_environment_value(&json!("debug"), Some(r"C:\jdk"), None).as_deref(),
            Some("debug")
        );
    }

    #[test]
    fn batch_command_line_keeps_maven_goals_inside_one_cmd_string() {
        let line = batch_command_line(
            r"D:\work\demo\mvnw.cmd",
            &[
                "-B".into(),
                "-ntp".into(),
                "-Dspring-boot.run.main-class=com.example.App".into(),
                "spring-boot:run".into(),
            ],
        );
        assert_eq!(
            line,
            r#""call D:\work\demo\mvnw.cmd -B -ntp -Dspring-boot.run.main-class=com.example.App spring-boot:run""#
        );
        assert!(is_batch_file(r"D:\work\demo\mvnw.cmd"));
        assert!(!is_batch_file(r"D:\jdk\bin\java.exe"));
    }

    #[test]
    fn quote_windows_arg_wraps_paths_with_spaces() {
        assert_eq!(
            quote_windows_arg(r"D:\my project\mvnw.cmd"),
            r#""D:\my project\mvnw.cmd""#
        );
    }

    #[test]
    fn maven_wrapper_requires_properties_file() {
        let root = temp_project();
        let wrapper = root.join("mvnw.cmd");
        fs::write(&wrapper, "@echo off\n").unwrap();
        assert!(!maven_wrapper_is_usable(&wrapper));
        fs::create_dir_all(root.join(".mvn/wrapper")).unwrap();
        fs::write(
            root.join(".mvn/wrapper/maven-wrapper.properties"),
            "distributionUrl=https://repo.maven.apache.org/maven2/org/apache/maven/apache-maven/3.9.9/apache-maven-3.9.9-bin.zip\n",
        )
        .unwrap();
        assert!(maven_wrapper_is_usable(&wrapper));
        fs::remove_dir_all(root).ok();
    }

    #[test]
    fn gbk_console_bytes_are_not_treated_as_utf8() {
        let gbk_xi_tong = [0xCF, 0xB5, 0xCD, 0xB3];
        assert!(!looks_like_real_utf8(&gbk_xi_tong));
        assert!(looks_like_real_utf8("系统".as_bytes()));
        assert!(looks_like_real_utf8(b"[INFO] BUILD SUCCESS"));
    }

    #[test]
    fn stdin_write_rejects_an_inactive_session() {
        let session_id = format!("missing-{}", std::process::id());
        let error = run_write_stdin(session_id, "input\n".to_string()).unwrap_err();
        assert_eq!(error, "The run process is no longer active.");
    }

    #[cfg(windows)]
    #[test]
    fn windows_gbk_bytes_decode_to_chinese() {
        let text = decode_windows_code_page(&[0xCF, 0xB5, 0xCD, 0xB3], 936).expect("GBK decode");
        assert_eq!(text, "系统");
    }
}
