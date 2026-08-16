//! Windows adapters for run-configuration persistence, toolchain discovery, and process launch.
//!
//! Shared detection, merge, and launch-plan assembly stay in `lithe-core`. This
//! module only writes `.lithe` documents, finds local JDK/Maven installations,
//! and streams child-process output to the workbench.

use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::fs;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::{Mutex, OnceLock};
use std::thread;
use tauri::{AppHandle, Emitter};

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
const LITHE_GITIGNORE: &str = "run/local.json\n**/*.tmp\n";

pub struct RunProcessManager;

struct RunningSession {
    pid: u32,
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
pub struct WriteDocumentArgs {
    pub root: PathBuf,
    pub relative_path: String,
    pub contents: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DiscoveredToolchains {
    pub java: Vec<JavaRuntime>,
    pub maven: Vec<MavenRuntime>,
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
pub fn run_write_document(args: WriteDocumentArgs) -> Result<(), String> {
    let root = existing_directory(&args.root)?;
    let relative = args.relative_path.replace('\\', "/");
    if !matches!(
        relative.as_str(),
        "run/local.json" | "run/configurations.json" | "project.json"
    ) {
        return Err("Run documents can only be written under .lithe/run or .lithe/project.json".into());
    }
    let target = join_relative(&root.join(".lithe"), &relative);
    validate_write_target(&root, &target)?;
    if let Some(parent) = target.parent() {
        fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    atomic_write(&target, args.contents.as_bytes())
}

#[tauri::command]
pub fn run_discover_toolchains(root: PathBuf) -> Result<DiscoveredToolchains, String> {
    let project_root = existing_directory(&root).ok();
    Ok(discover_toolchains(project_root.as_deref()))
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
    )?;
    let mut environment = std::env::vars().collect::<HashMap<_, _>>();
    if let Some(home) = &java_home {
        environment.insert("JAVA_HOME".into(), home.clone());
    }
    for (key, value) in args.environment {
        if let Some(text) = resolve_environment_value(
            &value,
            java_home.as_deref(),
            maven_java_home.as_deref(),
        ) {
            environment.insert(key, text);
        }
    }
    if let Some(home) = maven_java_home.or(java_home) {
        environment.entry("JAVA_HOME".into()).or_insert(home);
    }
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
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    apply_creation_flags(&mut command);
    let mut child = command
        .spawn()
        .map_err(|error| format!("Unable to start process: {error}"))?;
    let pid = child.id();
    let stdout = child.stdout.take();
    let stderr = child.stderr.take();
    sessions()
        .lock()
        .map_err(|_| "Run process state is unavailable".to_string())?
        .insert(args.session_id.clone(), RunningSession { pid });

    let stdout_reader = spawn_output_reader(app.clone(), args.session_id.clone(), stdout);
    let stderr_reader = spawn_output_reader(app.clone(), args.session_id.clone(), stderr);
    spawn_exit_waiter(app, args.session_id, child, pid, stdout_reader, stderr_reader);
    Ok(())
}

#[tauri::command]
pub fn run_stop_process(session_id: String) -> Result<(), String> {
    stop_session(&session_id);
    Ok(())
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
    for path in [&generated_path, &requirements_path, &ignore_path, &manifest_path] {
        validate_write_target(&root, path)?;
    }
    fs::create_dir_all(&run_directory).map_err(|error| error.to_string())?;
    fs::create_dir_all(&toolchain_directory).map_err(|error| error.to_string())?;
    atomic_write(&requirements_path, pretty_json(requirements)?.as_bytes())?;
    if !ignore_path.exists() {
        atomic_write(&ignore_path, LITHE_GITIGNORE.as_bytes())?;
    }
    if !manifest_path.exists() {
        let mut manifest = json!({ "version": 1 });
        if let Some(default_id) = default_run_configuration.filter(|value| !value.is_empty()) {
            manifest["defaultRunConfiguration"] = json!(default_id);
        }
        atomic_write(&manifest_path, pretty_json(&manifest)?.as_bytes())?;
    }
    atomic_write(&generated_path, pretty_json(generated)?.as_bytes())
}

fn collect_java_sources(root: &Path, directory: &Path, paths: &mut Vec<String>) -> Result<(), String> {
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
    name.starts_with('.') || SKIPPED_DIRECTORIES.iter().any(|value| value.eq_ignore_ascii_case(name))
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

fn atomic_write(path: &Path, contents: &[u8]) -> Result<(), String> {
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
    fs::rename(&temporary, path).map_err(|error| error.to_string())
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

fn discover_toolchains(project_root: Option<&Path>) -> DiscoveredToolchains {
    let mut java = Vec::new();
    let mut seen_homes = std::collections::HashSet::new();
    for home in java_home_candidates(project_root) {
        if !seen_homes.insert(home.clone()) {
            continue;
        }
        if let Some(runtime) = probe_java_home(&home) {
            java.push(runtime);
        }
    }
    java.sort_by(|left, right| right.version.cmp(&left.version).then(left.home_path.cmp(&right.home_path)));

    let mut maven = Vec::new();
    let mut seen_executables = std::collections::HashSet::new();
    for executable in maven_executable_candidates(project_root) {
        if !seen_executables.insert(executable.clone()) {
            continue;
        }
        if let Some(runtime) = probe_maven(&executable) {
            maven.push(runtime);
        }
    }
    DiscoveredToolchains { java, maven }
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

fn probe_java_home(home: &Path) -> Option<JavaRuntime> {
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

fn java_executable(home: &Path) -> Option<PathBuf> {
    for name in ["java.exe", "java"] {
        let candidate = home.join("bin").join(name);
        if candidate.is_file() {
            return Some(candidate);
        }
    }
    None
}

fn java_home_from_executable(executable: &Path) -> Option<PathBuf> {
    executable.parent().and_then(Path::parent).map(Path::to_path_buf)
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
        return Err(format!("JDK Home does not point to a directory: {configured}"));
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
) -> Result<String, String> {
    if let Some(toolchain) = executable.toolchain.as_deref() {
        return match toolchain {
            "project-jdk" => {
                let home = java_home.ok_or_else(|| {
                    "No Java runtime was found. Set JAVA_HOME or install a JDK.".to_string()
                })?;
                java_executable(Path::new(home))
                    .map(|path| path.to_string_lossy().into_owned())
                    .ok_or_else(|| "No Java runtime was found. Set JAVA_HOME or install a JDK.".into())
            }
            "project-maven" => resolve_maven_executable(root, working_directory, maven_override),
            other => Err(format!("No resolver is registered for toolchain {other}.")),
        };
    }
    if let Some(command) = executable.command.as_deref().filter(|value| !value.is_empty()) {
        return lookup_on_path(command)
            .or_else(|| lookup_on_path(&format!("{command}.cmd")))
            .or_else(|| lookup_on_path(&format!("{command}.exe")))
            .map(|path| path.to_string_lossy().into_owned())
            .ok_or_else(|| format!("Could not find executable: {command}"));
    }
    Err("The launch plan names neither a toolchain nor a command.".into())
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
    let property = object.get("property").and_then(Value::as_str).unwrap_or("home");
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
    command.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped());
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
        let Some(index) = line.find("version") else { continue };
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
        let exit_code = child.wait().ok().and_then(|status| status.code()).unwrap_or(-1);
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
        assert!(root.join(".lithe").join("run").join("generated.json").is_file());
        assert!(root
            .join(".lithe")
            .join("toolchains")
            .join("requirements.json")
            .is_file());
        assert_eq!(
            fs::read_to_string(root.join(".lithe").join(".gitignore")).expect("gitignore"),
            LITHE_GITIGNORE
        );
        let manifest: Value = serde_json::from_str(
            &fs::read_to_string(root.join(".lithe").join("project.json")).expect("manifest"),
        )
        .expect("json");
        assert_eq!(manifest["defaultRunConfiguration"], "spring-boot.maven:demo");
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

    #[cfg(windows)]
    #[test]
    fn windows_gbk_bytes_decode_to_chinese() {
        let text = decode_windows_code_page(&[0xCF, 0xB5, 0xCD, 0xB3], 936)
            .expect("GBK decode");
        assert_eq!(text, "系统");
    }
}
