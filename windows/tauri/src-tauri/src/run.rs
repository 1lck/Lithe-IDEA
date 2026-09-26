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
use std::sync::{
    mpsc::{self, Receiver, RecvTimeoutError, SyncSender},
    Mutex, OnceLock,
};
use std::thread;
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Manager};

mod launch_arguments;

const MAVEN_LAUNCHERS: &[&str] = &["mvn.cmd", "mvn.bat", "mvn.exe", "mvn"];
const MVND_LAUNCHERS: &[&str] = &["mvnd.exe", "mvnd.cmd", "mvnd.bat", "mvnd"];

const CREATE_NO_WINDOW: u32 = 0x0800_0000;
const RUN_OUTPUT_FLUSH_INTERVAL: Duration = Duration::from_millis(100);
const RUN_OUTPUT_HIGH_WATER_BYTES: usize = 1_048_576;
const RUN_OUTPUT_QUEUE_CAPACITY_CHUNKS: usize = 64;
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
const LITHE_GITIGNORE_ENTRIES: &[&str] = &[
    "run/local.json",
    "toolchains/local.json",
    // Pre-launch compile products for standalone Java (javac -d output); a
    // build artifact, never source, so it stays out of version control.
    "run/classes/",
    "**/*.tmp",
];

pub struct RunProcessManager;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
struct RunSessionKey {
    window_label: String,
    session_id: String,
}

struct RunningSession {
    pid: u32,
    execution_id: Option<String>,
    stdin: Option<ChildStdin>,
}

impl Default for RunProcessManager {
    fn default() -> Self {
        Self
    }
}

fn sessions() -> &'static Mutex<HashMap<RunSessionKey, RunningSession>> {
    static SESSIONS: OnceLock<Mutex<HashMap<RunSessionKey, RunningSession>>> = OnceLock::new();
    SESSIONS.get_or_init(|| Mutex::new(HashMap::new()))
}

fn run_session_key(window_label: &str, session_id: &str) -> RunSessionKey {
    RunSessionKey {
        window_label: window_label.to_string(),
        session_id: session_id.to_string(),
    }
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
    /// Sibling tool to run from the toolchain's `bin` directory, e.g. `"javac"`.
    /// Empty or absent means the toolchain's default launcher (`java`).
    #[serde(default)]
    pub tool: Option<String>,
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
    pub window_label: String,
    pub session_id: String,
    #[serde(default)]
    pub execution_id: Option<String>,
    pub executable: String,
    pub arguments: Vec<String>,
    pub working_directory: String,
    #[serde(default)]
    pub environment: HashMap<String, String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ExecutePreLaunchArgs {
    pub executable: String,
    pub arguments: Vec<String>,
    pub working_directory: String,
    #[serde(default)]
    pub environment: HashMap<String, String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PreLaunchOutcome {
    pub exit_code: i32,
    pub output: String,
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

/// Resolves the Maven this workspace would run without launching any process.
///
/// `run_discover_toolchains` runs `mvn -version` and `java -version` on every
/// candidate, and a project wrapper may download a Maven distribution on its
/// first run. That cost is acceptable while resolving run configurations, but
/// not on the editor path that blocks Java language-server startup.
///
/// Candidate order matches `resolve_maven_executable`, so project import and
/// builds agree on one Maven.
#[tauri::command]
pub fn maven_resolve_installation(root: PathBuf, override_path: Option<String>) -> Option<String> {
    let root = existing_directory(&root).ok()?;
    maven_executable_without_probing(&root, override_path.as_deref())
}

fn maven_executable_without_probing(root: &Path, override_path: Option<&str>) -> Option<String> {
    if let Some(configured) = override_path
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        let path = if Path::new(configured).is_absolute() {
            PathBuf::from(configured)
        } else {
            root.join(configured)
        };
        return custom_maven_executable_candidates(&path)
            .into_iter()
            .find(|candidate| candidate.is_file())
            .map(|candidate| normalize_path(&candidate).to_string_lossy().into_owned());
    }
    for name in ["mvnw.cmd", "mvnw.bat", "mvnw"] {
        let wrapper = root.join(name);
        if wrapper.is_file() && maven_wrapper_is_usable(&wrapper) {
            return Some(normalize_path(&wrapper).to_string_lossy().into_owned());
        }
    }
    // Wrappers were already considered above, and an unusable one must not
    // shadow a machine installation here.
    maven_executable_candidates(Some(root))
        .into_iter()
        .filter(|candidate| !is_maven_wrapper(candidate))
        .find(|candidate| candidate.is_file())
        .map(|candidate| normalize_path(&candidate).to_string_lossy().into_owned())
}

fn is_maven_wrapper(path: &Path) -> bool {
    path.file_name()
        .and_then(|name| name.to_str())
        .is_some_and(|name| {
            matches!(
                name.to_ascii_lowercase().as_str(),
                "mvnw" | "mvnw.cmd" | "mvnw.bat"
            )
        })
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

/// Project toolchain selections to resolve for display, exactly as a launch would.
#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ResolveToolchainsArgs {
    pub root: PathBuf,
    /// Empty selects the automatic JDK.
    #[serde(default)]
    pub java_home_path: String,
    /// Empty selects the project wrapper, then a detected Maven.
    #[serde(default)]
    pub maven_executable_path: String,
    /// Empty inherits the resolved project JDK.
    #[serde(default)]
    pub maven_java_home_path: String,
}

/// Outcome of resolving one toolchain for Settings.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "status", rename_all = "camelCase")]
pub enum ToolchainResolution {
    /// `source` names where the value came from: `configured`, `javaHome`,
    /// `path`, `project`, `detected`, `mavenWrapper`, or `projectJdk`.
    /// `version` and `vendor` are empty when the tool was not probed.
    Resolved {
        path: String,
        version: String,
        vendor: String,
        source: &'static str,
    },
    /// Nothing was configured and nothing usable was detected.
    NotFound { message: Option<String> },
    /// The configured path cannot be used; a launch fails with `message`.
    Invalid { message: String },
}

/// Resolved project JDK, Maven, and Maven JDK.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ResolvedToolchains {
    pub java: ToolchainResolution,
    pub maven: ToolchainResolution,
    pub maven_java: ToolchainResolution,
}

/// Resolves the project toolchains without launching the project.
///
/// Settings shows these values in place of "automatic" or "inherited", so the
/// command reuses the resolvers `run_resolve_launch` uses: the displayed JDK
/// and Maven are the ones a launch starts. Probing runs `java -version`, so the
/// work stays off the main thread.
#[tauri::command]
pub async fn run_resolve_toolchains(
    args: ResolveToolchainsArgs,
) -> Result<ResolvedToolchains, String> {
    tauri::async_runtime::spawn_blocking(move || {
        let root = existing_directory(&args.root)?;
        Ok(resolve_toolchains_for_display(
            &root,
            &args.java_home_path,
            &args.maven_executable_path,
            &args.maven_java_home_path,
        ))
    })
    .await
    .map_err(|error| format!("Toolchain resolution failed: {error}"))?
}

fn resolve_toolchains_for_display(
    root: &Path,
    java_home_path: &str,
    maven_executable_path: &str,
    maven_java_home_path: &str,
) -> ResolvedToolchains {
    let java = java_resolution(root, java_home_path);
    // Mirrors `run_resolve_launch`: an empty Maven JDK inherits the project JDK.
    let maven_java = if maven_java_home_path.trim().is_empty() {
        match &java {
            ToolchainResolution::Resolved {
                path,
                version,
                vendor,
                ..
            } => ToolchainResolution::Resolved {
                path: path.clone(),
                version: version.clone(),
                vendor: vendor.clone(),
                source: "projectJdk",
            },
            other => other.clone(),
        }
    } else {
        java_resolution(root, maven_java_home_path)
    };
    ResolvedToolchains {
        java,
        maven: maven_resolution(root, maven_executable_path),
        maven_java,
    }
}

fn java_resolution(root: &Path, override_path: &str) -> ToolchainResolution {
    match resolve_java_home(root, override_path) {
        Ok(Some(home)) => {
            let home_path = Path::new(&home);
            let source = if override_path.trim().is_empty() {
                automatic_java_source(root, home_path)
            } else {
                "configured"
            };
            let runtime = probe_java_home(home_path);
            ToolchainResolution::Resolved {
                version: runtime
                    .as_ref()
                    .map(|runtime| runtime.version.clone())
                    .unwrap_or_default(),
                vendor: runtime.map(|runtime| runtime.vendor).unwrap_or_default(),
                path: home,
                source,
            }
        }
        Ok(None) => ToolchainResolution::NotFound { message: None },
        Err(message) => ToolchainResolution::Invalid { message },
    }
}

/// Names the candidate list entry an automatic JDK came from. Display only:
/// the choice itself is `resolve_java_home`'s.
fn automatic_java_source(root: &Path, home: &Path) -> &'static str {
    let key = |path: &Path| normalize_path(path).to_string_lossy().to_lowercase();
    let selected = key(home);
    if std::env::var_os("JAVA_HOME").is_some_and(|value| key(Path::new(&value)) == selected) {
        return "javaHome";
    }
    let on_path = lookup_on_path("java.exe")
        .or_else(|| lookup_on_path("java"))
        .and_then(|executable| java_home_from_executable(&executable));
    if on_path.is_some_and(|path| key(&path) == selected) {
        return "path";
    }
    if key(&root.join(".lithe").join("toolchains").join("jdk")) == selected {
        return "project";
    }
    "detected"
}

fn maven_resolution(root: &Path, override_path: &str) -> ToolchainResolution {
    match resolve_maven_executable(root, root, override_path) {
        Ok(executable) => {
            let path = Path::new(&executable);
            let is_wrapper = path
                .file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.to_ascii_lowercase().starts_with("mvnw"));
            let source = if !override_path.trim().is_empty() {
                "configured"
            } else if is_wrapper {
                "mavenWrapper"
            } else {
                "detected"
            };
            // Running a wrapper may download a Maven distribution, so only a
            // plain Maven installation is probed for its version.
            let version = if is_wrapper {
                String::new()
            } else {
                probe_maven(path)
                    .map(|runtime| runtime.version)
                    .unwrap_or_default()
            };
            ToolchainResolution::Resolved {
                path: executable,
                version,
                vendor: String::new(),
                source,
            }
        }
        Err(message) if override_path.trim().is_empty() => ToolchainResolution::NotFound {
            message: Some(message),
        },
        Err(message) => ToolchainResolution::Invalid { message },
    }
}

/// Runs one pre-launch step (e.g. `javac`) to completion and reports its exit
/// code plus combined stdout/stderr. Standalone Java compiles here before the
/// main `java` process starts; the store aborts the run when `exit_code != 0`
/// and surfaces `output` as the compiler's real diagnostic.
#[tauri::command]
pub async fn run_execute_prelaunch(args: ExecutePreLaunchArgs) -> Result<PreLaunchOutcome, String> {
    // `.output()` blocks until the compiler exits. Sync Tauri commands run on the
    // main thread, so a long `javac` compile would freeze the workbench; run the
    // blocking wait on a worker thread instead.
    tauri::async_runtime::spawn_blocking(move || {
        let mut command = command_for_executable(&args.executable, &args.arguments);
        command
            .current_dir(&args.working_directory)
            .envs(&args.environment)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        apply_creation_flags(&mut command);
        let output = command
            .output()
            .map_err(|error| format!("Unable to start process: {error}"))?;
        let mut text = decode_process_bytes(&output.stdout);
        text.push_str(&decode_process_bytes(&output.stderr));
        Ok(PreLaunchOutcome {
            exit_code: output.status.code().unwrap_or(-1),
            output: text,
        })
    })
    .await
    .map_err(|error| format!("Pre-launch task failed: {error}"))?
}

#[tauri::command]
pub fn run_start_process(app: AppHandle, args: StartProcessArgs) -> Result<(), String> {
    if args.window_label.trim().is_empty() {
        return Err("A run process must be started from an active window.".into());
    }
    stop_session(&args.window_label, &args.session_id, None);
    let (arguments, argfile) = prepare_launch_arguments(&args)?;
    let mut command = command_for_executable(&args.executable, &arguments);
    command
        .current_dir(&args.working_directory)
        .envs(&args.environment)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    apply_creation_flags(&mut command);
    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(error) => {
            drop(argfile);
            return Err(spawn_failure_message(&args.executable, &arguments, &error));
        }
    };
    let pid = child.id();
    let stdin = child.stdin.take();
    let stdout = child.stdout.take();
    let stderr = child.stderr.take();
    let execution_id = args.execution_id.clone();
    let session_key = run_session_key(&args.window_label, &args.session_id);
    sessions()
        .lock()
        .map_err(|_| "Run process state is unavailable".to_string())?
        .insert(
            session_key,
            RunningSession {
                pid,
                execution_id: args.execution_id,
                stdin,
            },
        );

    // Run and Maven panels rebuild highlighted output when this event crosses
    // into the webview. Coalesce native pipe reads before that expensive
    // boundary instead of asking React to render every 4 KiB read separately.
    // A bounded queue preserves pipe backpressure when the webview cannot keep
    // up. Each reader sends at most one decoded 4 KiB read per slot.
    let (output_sender, output_receiver) = mpsc::sync_channel(RUN_OUTPUT_QUEUE_CAPACITY_CHUNKS);
    let output_dispatcher = spawn_output_dispatcher(
        app.clone(),
        args.window_label.clone(),
        args.session_id.clone(),
        pid,
        execution_id,
        output_receiver,
    );
    let stdout_reader = spawn_output_reader(stdout, output_sender.clone());
    let stderr_reader = spawn_output_reader(stderr, output_sender);
    spawn_exit_waiter(
        app,
        args.window_label,
        args.session_id,
        child,
        pid,
        stdout_reader,
        stderr_reader,
        output_dispatcher,
        argfile,
    );
    Ok(())
}

fn prepare_launch_arguments(
    args: &StartProcessArgs,
) -> Result<(Vec<String>, Option<launch_arguments::LaunchArgumentFile>), String> {
    launch_arguments::prepare(&args.executable, &args.arguments)
}

/// Explains a refused spawn with the detail the operating system reported.
///
/// The generic host message used to replace the real cause, so a command line
/// rejected for its length looked identical to a missing executable.
fn spawn_failure_message(executable: &str, arguments: &[String], error: &std::io::Error) -> String {
    let length: usize = executable.chars().count()
        + arguments
            .iter()
            .map(|argument| argument.chars().count() + 1)
            .sum::<usize>();
    let hint = if error.raw_os_error() == Some(206) {
        " The command line is too long for Windows even after moving the Java class path into an argument file."
    } else {
        ""
    };
    format!(
        "Unable to start process: {error} (executable={executable}, arguments={}, commandLength={length}).{hint}",
        arguments.len()
    )
}

#[tauri::command]
pub fn run_stop_process(
    window_label: String,
    session_id: String,
    execution_id: Option<String>,
) -> Result<(), String> {
    stop_session(&window_label, &session_id, execution_id.as_deref());
    Ok(())
}

#[tauri::command]
pub fn run_write_stdin(
    window_label: String,
    session_id: String,
    input: String,
) -> Result<(), String> {
    let mut current = sessions()
        .lock()
        .map_err(|_| "Run process state is unavailable".to_string())?;
    let session = current
        .get_mut(&run_session_key(&window_label, &session_id))
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
pub(crate) fn replace_run_document(source: &Path, destination: &Path) -> Result<(), String> {
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
pub(crate) fn replace_run_document(source: &Path, destination: &Path) -> Result<(), String> {
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

/// Installed JDKs for the Java language service, which binds each project to
/// the JDK matching the release it compiles for.
pub(crate) fn discover_java_runtimes(project_root: Option<&Path>) -> Vec<JavaRuntime> {
    probe_java_homes(java_home_candidates(project_root))
}

fn probe_java_homes(homes: Vec<PathBuf>) -> Vec<JavaRuntime> {
    let mut java = Vec::new();
    let mut seen_homes = std::collections::HashSet::new();
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
    java
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
    let mut homes = java_home_candidates(project_root);
    if let Some(path) = java_home_path.filter(|value| !value.trim().is_empty()) {
        homes.insert(0, PathBuf::from(path));
    }
    let java = probe_java_homes(homes);

    let maven = discover_maven_candidates(
        maven_executable_candidates(project_root),
        maven_executable_path,
        probe_maven,
    );

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

// Keep candidate selection separate from machine discovery and process probes,
// so custom-path tests do not launch every installed JDK, Maven and Node runtime.
fn discover_maven_candidates(
    mut executables: Vec<PathBuf>,
    override_path: Option<&str>,
    mut probe: impl FnMut(&Path) -> Option<MavenRuntime>,
) -> Vec<MavenRuntime> {
    if let Some(path) = override_path.filter(|value| !value.trim().is_empty()) {
        executables.splice(0..0, custom_maven_executable_candidates(Path::new(path)));
    }
    let mut maven = Vec::new();
    let mut seen_executables = std::collections::HashSet::new();
    for executable in executables {
        if seen_executables.insert(executable.clone()) {
            if let Some(runtime) = probe(&executable) {
                maven.push(runtime);
            }
        }
    }
    maven
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
    // Preserve ordinary Maven discovery precedence; mvnd is an additional
    // installation, not a reason to replace an existing project wrapper.
    for name in MAVEN_LAUNCHERS {
        if let Some(path) = lookup_on_path(name) {
            executables.push(path);
        }
    }
    if let Some(home) = std::env::var_os("MVND_HOME") {
        executables.extend(custom_maven_executable_candidates(Path::new(&home)));
    }
    for name in MVND_LAUNCHERS {
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
    // Settings accept an installation root, its bin directory, or a launcher.
    // Never substitute mvnd's embedded mvn: that silently disables the daemon.
    [path.join("bin"), path.to_path_buf()]
        .into_iter()
        .flat_map(|bin| {
            MVND_LAUNCHERS
                .iter()
                .chain(MAVEN_LAUNCHERS)
                .map(move |name| bin.join(name))
        })
        .collect()
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
    jdk_tool_executable(home, "java")
}

/// Resolves a JDK `bin` tool (`java`, `javac`, …) by name, preferring the
/// `.exe` on Windows and falling back to the extensionless launcher.
pub(crate) fn jdk_tool_executable(home: &Path, tool: &str) -> Option<PathBuf> {
    for name in [format!("{tool}.exe"), tool.to_string()] {
        let candidate = home.join("bin").join(&name);
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
                // A pre-launch step names a sibling JDK tool (javac); the main
                // process leaves `tool` empty and resolves the default launcher.
                let tool = executable
                    .tool
                    .as_deref()
                    .map(str::trim)
                    .filter(|value| !value.is_empty())
                    .unwrap_or("java");
                jdk_tool_executable(Path::new(home), tool)
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
        if let Some(found) = custom_maven_executable_candidates(&path)
            .into_iter()
            .find(|candidate| candidate.is_file())
        {
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

pub(crate) fn apply_creation_flags(command: &mut Command) {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        command.creation_flags(CREATE_NO_WINDOW);
    }
    let _ = command;
}

pub(crate) fn decode_process_bytes(bytes: &[u8]) -> String {
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
    text.is_ascii() || text.chars().any(|character| character.len_utf8() >= 3)
}

pub(crate) fn incomplete_suffix_len(bytes: &[u8]) -> usize {
    match std::str::from_utf8(bytes) {
        Ok(_) => 0,
        Err(error) if error.error_len().is_none() => bytes.len() - error.valid_up_to(),
        Err(_) => incomplete_windows_code_page_suffix_len(bytes),
    }
}

#[cfg(windows)]
fn incomplete_windows_code_page_suffix_len(bytes: &[u8]) -> usize {
    bytes.last().is_some_and(|byte| unsafe {
        winapi::IsDBCSLeadByteEx(windows_ansi_code_page(), *byte) != 0
    }) as usize
}

#[cfg(not(windows))]
fn incomplete_windows_code_page_suffix_len(_bytes: &[u8]) -> usize {
    0
}

#[cfg(windows)]
mod winapi {
    #[link(name = "kernel32")]
    extern "system" {
        pub fn GetACP() -> u32;
        pub fn IsDBCSLeadByteEx(code_page: u32, test_char: u8) -> i32;
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
        // mvnd prints "Apache Maven Daemon ..." before the embedded Maven
        // version. Do not report "Daemon" as the Maven version.
        let rest = line.trim().strip_prefix("Apache Maven ")?;
        let version = rest.split_whitespace().next()?;
        version
            .starts_with(|c: char| c.is_ascii_digit())
            .then(|| version.to_string())
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
    stream: Option<T>,
    output_sender: SyncSender<String>,
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
                            let _ = output_sender.send(chunk);
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
                    if output_sender.send(chunk).is_err() {
                        break;
                    }
                }
                Err(_) => break,
            }
        }
    })
}

fn receive_output_batch(
    receiver: &Receiver<String>,
    flush_interval: Duration,
    high_water_bytes: usize,
) -> Option<String> {
    let first = receiver.recv().ok()?;
    let mut chunks = vec![first];
    let mut byte_count = chunks[0].len();
    let deadline = Instant::now() + flush_interval;

    while byte_count < high_water_bytes {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() {
            break;
        }
        match receiver.recv_timeout(remaining) {
            Ok(chunk) => {
                byte_count += chunk.len();
                chunks.push(chunk);
            }
            Err(RecvTimeoutError::Timeout | RecvTimeoutError::Disconnected) => break,
        }
    }

    Some(chunks.concat())
}

fn spawn_output_dispatcher(
    app: AppHandle,
    window_label: String,
    session_id: String,
    pid: u32,
    execution_id: Option<String>,
    receiver: Receiver<String>,
) -> thread::JoinHandle<()> {
    thread::spawn(move || {
        while let Some(chunk) = receive_output_batch(
            &receiver,
            RUN_OUTPUT_FLUSH_INTERVAL,
            RUN_OUTPUT_HIGH_WATER_BYTES,
        ) {
            let session_key = run_session_key(&window_label, &session_id);
            let is_current = sessions().lock().is_ok_and(|current| {
                current.get(&session_key).is_some_and(|session| {
                    session.pid == pid && session.execution_id.as_deref() == execution_id.as_deref()
                })
            });
            if !is_current {
                // A stopped or replaced process no longer owns the panel, but
                // its pipe must still be drained until the reader threads
                // finish. Dropping the receiver could leave the child blocked
                // on a full stdout pipe while taskkill is still completing.
                continue;
            }
            let _ = app.emit_to(
                &window_label,
                "run-output",
                json!({ "sessionId": session_id, "chunk": chunk }),
            );
        }
    })
}

#[allow(clippy::too_many_arguments)]
fn spawn_exit_waiter(
    app: AppHandle,
    window_label: String,
    session_id: String,
    mut child: Child,
    pid: u32,
    stdout_reader: thread::JoinHandle<()>,
    stderr_reader: thread::JoinHandle<()>,
    output_dispatcher: thread::JoinHandle<()>,
    argfile: Option<launch_arguments::LaunchArgumentFile>,
) {
    thread::spawn(move || {
        let exit_code = child
            .wait()
            .ok()
            .and_then(|status| status.code())
            .unwrap_or(-1);
        // The JVM reads the argument file while starting, so it is removed only
        // after the process it configured has ended.
        drop(argfile);
        let _ = stdout_reader.join();
        let _ = stderr_reader.join();
        // Preserve the console contract: the final output batch is observable
        // before the matching exit event marks the session as complete.
        let _ = output_dispatcher.join();
        let session_key = run_session_key(&window_label, &session_id);
        let stale = match sessions().lock() {
            Ok(mut current) => match current.get(&session_key) {
                Some(session) if session.pid == pid => {
                    current.remove(&session_key);
                    false
                }
                _ => true,
            },
            Err(_) => true,
        };
        if stale {
            return;
        }
        let _ = app.emit_to(
            &window_label,
            "run-exit",
            json!({ "sessionId": session_id, "exitCode": exit_code }),
        );
    });
}

fn take_owned_session(
    current: &mut HashMap<RunSessionKey, RunningSession>,
    key: &RunSessionKey,
    execution_id: Option<&str>,
) -> Option<RunningSession> {
    // Check and remove under the same lock; an old adapter must not reap a new Run.
    if let Some(expected) = execution_id {
        if current.get(key)?.execution_id.as_deref() != Some(expected) {
            return None;
        }
    }
    current.remove(key)
}

fn stop_session(window_label: &str, session_id: &str, execution_id: Option<&str>) {
    let pid = sessions().lock().ok().and_then(|mut current| {
        take_owned_session(
            &mut current,
            &run_session_key(window_label, session_id),
            execution_id,
        )
        .map(|session| session.pid)
    });
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

    #[test]
    fn output_batch_coalesces_queued_chunks_in_order() {
        let (sender, receiver) = mpsc::sync_channel(2);
        sender.send("first".to_string()).unwrap();
        sender.send(" second".to_string()).unwrap();
        drop(sender);

        assert_eq!(
            receive_output_batch(&receiver, Duration::from_secs(1), 1024).as_deref(),
            Some("first second")
        );
        assert!(receive_output_batch(&receiver, Duration::from_secs(1), 1024).is_none());
    }

    #[test]
    fn output_batch_flushes_at_the_high_water_mark() {
        let (sender, receiver) = mpsc::sync_channel(3);
        sender.send("abc".to_string()).unwrap();
        sender.send("def".to_string()).unwrap();
        sender.send("ghi".to_string()).unwrap();

        assert_eq!(
            receive_output_batch(&receiver, Duration::from_secs(1), 6).as_deref(),
            Some("abcdef")
        );
        drop(sender);
        assert_eq!(
            receive_output_batch(&receiver, Duration::from_secs(1), 6).as_deref(),
            Some("ghi")
        );
    }

    #[test]
    fn output_queue_applies_backpressure_at_capacity() {
        let (output_sender, output_receiver) = mpsc::sync_channel(1);
        output_sender.send("first".to_string()).unwrap();
        let (started_sender, started_receiver) = mpsc::channel();
        let (finished_sender, finished_receiver) = mpsc::channel();
        let sender_thread = thread::spawn(move || {
            let _ = started_sender.send(());
            let result = output_sender.send("second".to_string());
            let _ = finished_sender.send(result.is_ok());
        });

        let did_start = started_receiver
            .recv_timeout(Duration::from_secs(1))
            .is_ok();
        let was_blocked = finished_receiver.try_recv().is_err();
        let first = output_receiver.recv_timeout(Duration::from_secs(1)).ok();
        let did_finish = finished_receiver
            .recv_timeout(Duration::from_secs(1))
            .unwrap_or(false);
        let second = output_receiver.recv_timeout(Duration::from_secs(1)).ok();
        drop(output_receiver);
        let joined = if did_finish {
            sender_thread.join().is_ok()
        } else {
            false
        };

        assert!(did_start);
        assert!(was_blocked);
        assert_eq!(first.as_deref(), Some("first"));
        assert!(did_finish);
        assert_eq!(second.as_deref(), Some("second"));
        assert!(joined);
    }

    #[test]
    fn stale_execution_cleanup_preserves_replacement_process() {
        let key = run_session_key("window", "primary");
        let mut current = HashMap::new();
        current.insert(
            key.clone(),
            RunningSession {
                pid: 42,
                execution_id: Some("replacement".into()),
                stdin: None,
            },
        );
        assert!(take_owned_session(&mut current, &key, Some("old-debug")).is_none());
        assert_eq!(current.get(&key).unwrap().pid, 42);
        assert_eq!(
            take_owned_session(&mut current, &key, Some("replacement"))
                .unwrap()
                .pid,
            42
        );
        assert!(current.is_empty());
    }

    #[test]
    fn unqualified_stop_keeps_manual_stop_compatible() {
        let key = run_session_key("window", "primary");
        let mut current = HashMap::new();
        current.insert(
            key.clone(),
            RunningSession {
                pid: 42,
                execution_id: None,
                stdin: None,
            },
        );
        assert!(take_owned_session(&mut current, &key, Some("old-debug")).is_none());
        assert!(take_owned_session(&mut current, &key, None).is_some());
        assert!(current.is_empty());
    }

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
    fn mvnd_paths_resolve_consistently_for_import_discovery_and_execution() {
        struct Fixture(PathBuf);
        impl Drop for Fixture {
            fn drop(&mut self) {
                if let Err(error) = fs::remove_dir_all(&self.0) {
                    eprintln!("Could not clean mvnd fixture: {error}");
                }
            }
        }
        let fixture = Fixture(temp_project());
        for name in ["mvnd.exe", "mvnd.cmd", "mvnd.bat", "mvnd"] {
            let home = fixture.0.join(format!("maven daemon {name}"));
            let launcher = home.join("bin").join(name);
            fs::create_dir_all(launcher.parent().unwrap()).unwrap();
            fs::write(&launcher, "fixture; never executed").unwrap();
            // A distribution also contains ordinary Maven. Selecting mvnd must
            // retain its daemon client, rather than silently selecting mvn.
            fs::create_dir_all(home.join("mvn/bin")).unwrap();
            fs::write(home.join("mvn/bin/mvn.cmd"), "embedded Maven").unwrap();
            fs::write(fixture.0.join("mvnw.cmd"), "wrapper").unwrap();
            let expected = normalize_path(&launcher).to_string_lossy().into_owned();
            for configured in [home.clone(), home.join("bin"), launcher.clone()] {
                let configured = configured.to_string_lossy();
                assert_eq!(
                    maven_executable_without_probing(&fixture.0, Some(&configured)),
                    Some(expected.clone())
                );
                assert_eq!(
                    resolve_maven_executable(&fixture.0, &fixture.0, &configured).unwrap(),
                    expected
                );
                let discovered =
                    discover_maven_candidates(vec![launcher.clone()], Some(&configured), |path| {
                        path.is_file().then(|| MavenRuntime {
                            executable_path: normalize_path(path).to_string_lossy().into_owned(),
                            version: "3.9.16".into(),
                        })
                    });
                assert_eq!(discovered.len(), 1);
                assert_eq!(discovered[0].executable_path, expected);
            }
        }
        let invalid = fixture
            .0
            .join("missing-mvnd")
            .to_string_lossy()
            .into_owned();
        assert!(maven_executable_without_probing(&fixture.0, Some(&invalid)).is_none());
        assert!(resolve_maven_executable(&fixture.0, &fixture.0, &invalid).is_err());
    }

    #[test]
    fn mvnd_version_uses_embedded_maven_instead_of_daemon_banner() {
        let output = "Apache Maven Daemon (mvnd) 1.0.6 windows-amd64 native client\nTerminal: DumbTerminal\nApache Maven 3.9.16 (revision)\nMaven home: example/mvnd/mvn";
        assert_eq!(maven_version(output).as_deref(), Some("3.9.16"));
        assert_eq!(
            maven_version("Apache Maven 3.9.9 (revision)").as_deref(),
            Some("3.9.9")
        );
        assert_eq!(maven_version("Apache Maven Daemon (mvnd) 1.0.6"), None);
    }

    #[test]
    #[ignore = "integration: requires LITHE_TEST_MVND_HOME pointing to a real distribution"]
    fn mvnd_installed_distribution_resolves_without_spawning_a_daemon() {
        let home = PathBuf::from(
            std::env::var_os("LITHE_TEST_MVND_HOME").expect("set LITHE_TEST_MVND_HOME"),
        );
        let expected = normalize_path(&home.join("bin/mvnd.exe"))
            .to_string_lossy()
            .into_owned();
        assert!(Path::new(&expected).is_file());
        for configured in [home.clone(), home.join("bin"), home.join("bin/mvnd.exe")] {
            let configured = configured.to_string_lossy();
            assert_eq!(
                maven_executable_without_probing(&home, Some(&configured)),
                Some(expected.clone())
            );
            assert_eq!(
                resolve_maven_executable(&home, &home, &configured).unwrap(),
                expected
            );
        }
    }

    #[test]
    fn custom_maven_home_discovers_its_bin_executable() {
        struct Fixture(PathBuf);
        impl Drop for Fixture {
            fn drop(&mut self) {
                if let Err(error) = fs::remove_dir_all(&self.0) {
                    eprintln!("Could not clean Maven discovery fixture: {error}");
                }
            }
        }
        let fixture = Fixture(temp_project());
        let home = fixture.0.join("apache-maven");
        let executable = home.join("bin/mvn.cmd");
        fs::create_dir_all(executable.parent().unwrap()).unwrap();
        fs::write(&executable, "Maven fixture").unwrap();

        // The same executable can be found in the environment and the custom
        // home. Probe fixture files only, preserving discovery and deduplication
        // coverage without depending on the CI machine's installed toolchains.
        for existing in [vec![], vec![executable.clone()]] {
            let mut successful_probes = 0;
            let discovered = discover_maven_candidates(
                existing,
                Some(home.to_string_lossy().as_ref()),
                |candidate| {
                    candidate.is_file().then(|| {
                        successful_probes += 1;
                        MavenRuntime {
                            executable_path: normalize_path(candidate)
                                .to_string_lossy()
                                .into_owned(),
                            version: "3.9.9".into(),
                        }
                    })
                },
            );
            assert_eq!(successful_probes, 1);
            assert_eq!(discovered.len(), 1);
            assert_eq!(
                Path::new(&discovered[0].executable_path),
                normalize_path(&executable)
            );
            assert_eq!(discovered[0].version, "3.9.9");
        }
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
    fn displayed_maven_is_the_wrapper_a_launch_would_run() {
        // Settings shows the resolved Maven in place of "automatic"; it must be
        // the one `run_resolve_launch` picks, and a wrapper is never executed.
        let root = temp_project();
        fs::write(root.join("mvnw.cmd"), "@echo off\n").unwrap();
        fs::create_dir_all(root.join(".mvn/wrapper")).unwrap();
        fs::write(
            root.join(".mvn/wrapper/maven-wrapper.properties"),
            "distributionUrl=https://example.invalid/apache-maven-3.9.9-bin.zip\n",
        )
        .unwrap();

        match maven_resolution(&root, "") {
            ToolchainResolution::Resolved {
                path,
                version,
                source,
                ..
            } => {
                assert!(path.ends_with("mvnw.cmd"), "resolved {path}");
                assert_eq!(source, "mavenWrapper");
                assert!(version.is_empty());
            }
            other => panic!("expected the wrapper, got {other:?}"),
        }
        fs::remove_dir_all(root).ok();
    }

    #[test]
    fn displayed_toolchains_report_invalid_selections_as_a_launch_would() {
        let root = temp_project();
        let missing = root.join("missing").to_string_lossy().into_owned();

        let resolved = resolve_toolchains_for_display(&root, &missing, &missing, "");

        assert!(matches!(resolved.java, ToolchainResolution::Invalid { .. }));
        assert!(matches!(
            resolved.maven,
            ToolchainResolution::Invalid { .. }
        ));
        // An empty Maven JDK inherits the project JDK, including its failure.
        assert_eq!(resolved.maven_java, resolved.java);
        fs::remove_dir_all(root).ok();
    }

    #[test]
    fn maven_resolution_without_probing_prefers_a_usable_wrapper() {
        // The editor path awaits this resolution before starting JDT LS, so it
        // must reach the same Maven a build would run without launching one.
        let root = temp_project();
        let wrapper = root.join("mvnw.cmd");
        fs::write(&wrapper, "@echo off\n").unwrap();
        fs::create_dir_all(root.join(".mvn/wrapper")).unwrap();
        fs::write(
            root.join(".mvn/wrapper/maven-wrapper.properties"),
            "distributionUrl=https://example.invalid/apache-maven-3.9.9-bin.zip\n",
        )
        .unwrap();

        let resolved =
            maven_executable_without_probing(&root, None).expect("a usable wrapper should resolve");

        assert!(resolved.ends_with("mvnw.cmd"), "resolved {resolved}");
        fs::remove_dir_all(root).ok();
    }

    #[test]
    fn maven_resolution_without_probing_accepts_a_home_or_a_launcher_override() {
        let root = temp_project();
        let home = root.join("apache-maven");
        fs::create_dir_all(home.join("bin")).unwrap();
        let launcher = home.join("bin").join("mvn.cmd");
        fs::write(&launcher, "@echo off\n").unwrap();
        // A wrapper must not shadow an explicit selection.
        fs::write(root.join("mvnw.cmd"), "@echo off\n").unwrap();

        for override_path in [
            home.to_string_lossy().into_owned(),
            launcher.to_string_lossy().into_owned(),
        ] {
            let resolved = maven_executable_without_probing(&root, Some(&override_path))
                .expect("an existing override should resolve");
            assert!(
                resolved.ends_with("mvn.cmd"),
                "override {override_path} resolved to {resolved}"
            );
        }
        fs::remove_dir_all(root).ok();
    }

    #[test]
    fn maven_resolution_without_probing_ignores_an_incomplete_wrapper() {
        // Without maven-wrapper.properties the wrapper cannot run, so it must
        // not be reported as the installation project import should follow.
        let root = temp_project();
        fs::write(root.join("mvnw.cmd"), "@echo off\n").unwrap();

        let resolved = maven_executable_without_probing(&root, None);

        assert!(
            !resolved
                .as_deref()
                .is_some_and(|value| value.ends_with("mvnw.cmd")),
            "resolved {resolved:?}"
        );
        fs::remove_dir_all(root).ok();
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
        assert!(looks_like_real_utf8("🙂".as_bytes()));
        assert!(looks_like_real_utf8(b"[INFO] BUILD SUCCESS"));
    }

    #[test]
    fn utf8_suffix_detection_only_keeps_an_incomplete_scalar() {
        assert_eq!(incomplete_suffix_len("日志🙂".as_bytes()), 0);
        assert_eq!(incomplete_suffix_len(&[0xE6]), 1);
        assert_eq!(incomplete_suffix_len(&[0xE6, 0x97]), 2);
        assert_eq!(incomplete_suffix_len(&[0xF0]), 1);
        assert_eq!(incomplete_suffix_len(&[0xF0, 0x9F]), 2);
        assert_eq!(incomplete_suffix_len(&[0xF0, 0x9F, 0x99]), 3);
        #[cfg(not(windows))]
        assert_eq!(incomplete_suffix_len(&[0x82]), 0);
    }

    #[test]
    fn run_session_keys_are_scoped_by_window_label() {
        let left = run_session_key("project-a", "primary");
        let right = run_session_key("project-b", "primary");
        assert_ne!(left, right);
        assert_eq!(left, run_session_key("project-a", "primary"));
    }

    #[test]
    fn stdin_write_rejects_an_inactive_session() {
        let session_id = format!("missing-{}", std::process::id());
        let error = run_write_stdin("main".into(), session_id, "input\n".to_string()).unwrap_err();
        assert_eq!(error, "The run process is no longer active.");
    }

    #[cfg(windows)]
    #[test]
    fn windows_gbk_bytes_decode_to_chinese() {
        let text = decode_windows_code_page(&[0xCF, 0xB5, 0xCD, 0xB3], 936).expect("GBK decode");
        assert_eq!(text, "系统");
    }

    #[test]
    fn gitignore_entries_cover_prelaunch_compile_output() {
        // Standalone Java compiles into .lithe/run/classes/<configId>; the
        // build artifact must stay untracked like the other run scratch files.
        assert!(LITHE_GITIGNORE_ENTRIES.contains(&"run/classes/"));
    }

    #[test]
    fn jdk_tool_executable_resolves_javac_sibling() {
        let home = temp_project();
        let bin = home.join("bin");
        fs::create_dir_all(&bin).expect("bin");
        for tool in ["java", "javac"] {
            fs::write(bin.join(format!("{tool}.exe")), b"").expect("tool");
        }
        let javac = jdk_tool_executable(&home, "javac").expect("javac");
        assert_eq!(javac.file_name().unwrap().to_string_lossy(), "javac.exe");
        // The default launcher still resolves through the same helper.
        let java = java_executable(&home).expect("java");
        assert_eq!(java.file_name().unwrap().to_string_lossy(), "java.exe");
        fs::remove_dir_all(home).ok();
    }

    #[test]
    fn resolve_executable_selects_javac_for_prelaunch_tool() {
        let home = temp_project();
        let bin = home.join("bin");
        fs::create_dir_all(&bin).expect("bin");
        for tool in ["java", "javac"] {
            fs::write(bin.join(format!("{tool}.exe")), b"").expect("tool");
        }
        let home_string = home.to_string_lossy().into_owned();
        let step_executable = LaunchExecutable {
            toolchain: Some("project-jdk".into()),
            command: None,
            tool: Some("javac".into()),
        };
        let resolved = resolve_executable(
            &home,
            &home,
            &step_executable,
            "",
            Some(&home_string),
            &HashMap::new(),
        )
        .expect("resolve javac");
        assert!(resolved.ends_with("javac.exe"), "resolved = {resolved}");

        let main_executable = LaunchExecutable {
            toolchain: Some("project-jdk".into()),
            command: None,
            tool: None,
        };
        let resolved_main = resolve_executable(
            &home,
            &home,
            &main_executable,
            "",
            Some(&home_string),
            &HashMap::new(),
        )
        .expect("resolve java");
        assert!(
            resolved_main.ends_with("java.exe"),
            "resolved_main = {resolved_main}"
        );
        fs::remove_dir_all(home).ok();
    }

    /// The host used to return a message that hid the operating system's
    /// reason, so every failure read "Unable to start the run configuration."
    #[test]
    fn a_refused_spawn_reports_the_operating_system_reason() {
        let error = std::io::Error::from_raw_os_error(2);
        let message = spawn_failure_message("C:\\missing\\java.exe", &["Main".to_string()], &error);
        assert!(message.contains("C:\\missing\\java.exe"), "{message}");
        assert!(message.contains("arguments=1"), "{message}");
        assert!(message.contains("commandLength="), "{message}");
    }
}
