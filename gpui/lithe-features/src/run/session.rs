//! 运行会话：Core 启动计划、本机可执行文件解析和子进程生命周期。
//!
//! Core 只返回平台中立的启动计划；本模块负责把它变成真实进程：
//! `lithe-git-host::ProcessTree` 保证停止时整棵进程树一起结束，stdout/stderr
//! 通过独立线程回传，视图线程只合并文本和状态。

use std::collections::BTreeMap;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::Arc;
use std::thread;
use std::time::Duration;

use async_channel::{Receiver, Sender, unbounded};
use lithe_core_client::CoreClient;
use lithe_git_host::ProcessTree;
use serde_json::{Value, json};

use super::model::RunConfiguration;

/// 运行会话向视图发送的事件。
pub enum SessionEvent {
    /// 子进程已经创建；视图保留进程树用于 Stop。
    Started(Arc<ProcessTree>),
    Output(String),
    Exited(Option<i32>),
    Failed(String),
}

/// 启动一个配置，立即返回事件通道。
///
/// 这是阻塞函数：Core 调用、可执行文件探测和 pre-launch 步骤都在当前线程
/// 执行，调用方必须放到 `cx.background_spawn`。主进程的输出由独立线程读取。
pub fn start(
    client: CoreClient,
    root: PathBuf,
    configuration: RunConfiguration,
) -> Receiver<SessionEvent> {
    let (sender, receiver) = unbounded();
    thread::spawn(move || {
        if let Err(message) = launch(client, root, configuration, sender.clone()) {
            let _ = sender.send_blocking(SessionEvent::Failed(message));
        }
    });
    receiver
}

fn launch(
    client: CoreClient,
    root: PathBuf,
    configuration: RunConfiguration,
    sender: Sender<SessionEvent>,
) -> Result<(), String> {
    let root_text = root.to_string_lossy().to_string();
    let mut request = json!({
        "root": root_text,
        "configurationId": configuration.id,
    });
    // Maven-backed configurations carry Core's reactor ownership. Passing it
    // back keeps `-pl`/`-f` relative to the reactor root instead of the module
    // directory, which matters for multi-module Spring Boot projects.
    if configuration.toolchains.contains_key("maven") {
        if let Some(maven) = configuration.extensions.get("maven") {
            let reactor_path = maven
                .get("reactorPath")
                .and_then(Value::as_str)
                .unwrap_or(".");
            let profiles = maven
                .get("profiles")
                .and_then(Value::as_array)
                .map(|items| {
                    items
                        .iter()
                        .filter_map(Value::as_str)
                        .map(str::to_string)
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default();
            request["mavenContext"] = json!({
                "version": 1,
                "reactorPath": reactor_path,
                "profiles": profiles,
                "settingsPath": null,
                "localRepositoryPath": null,
                "skipTests": maven
                    .get("skipTests")
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
                "mavenExecutablePath": null,
                "javaHomePath": null
            });
        }
    }
    let plan = client
        .execute_raw("runConfig.createLaunchPlan", request)
        .map_err(|error| {
            format!(
                "{}: {error}",
                lithe_ui::i18n::tr("Could not start configuration")
            )
        })?;

    let launch = LaunchPlan::from_json(&plan)?;
    let working_directory = resolve_working_directory(&root, &launch.working_directory);
    let executable = resolve_executable(&root, &working_directory, &launch.executable)?;
    let mut environment = launch.env.clone();
    for (key, reference) in &launch.environment {
        if let Some(value) = resolve_environment_reference(&root, &working_directory, reference) {
            environment.insert(key.clone(), value);
        }
    }

    // pre-launch 步骤是 Java 独立源文件的编译等准备工作；它们必须按顺序
    // 完成，失败时主进程不能启动。
    for step in &launch.pre_launch_steps {
        let step_executable = resolve_executable(&root, &working_directory, &step.executable)?;
        let step_directory = step
            .working_directory
            .as_deref()
            .map(|directory| resolve_working_directory(&root, directory))
            .unwrap_or_else(|| working_directory.clone());
        let step_arguments = merge_path_arguments(
            &step.arguments,
            &resolve_plan_paths(&root, &step.classpath),
            &[],
        );
        let mut command = command_for(&step_executable, &step_arguments);
        command
            .current_dir(&step_directory)
            .envs(&environment)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        let output = command.output().map_err(|error| {
            format!(
                "{}: {}: {error}",
                lithe_ui::i18n::tr("Could not start configuration"),
                step_executable.display()
            )
        })?;
        let text = format!(
            "{}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        if !text.is_empty() {
            let _ = sender.send_blocking(SessionEvent::Output(text));
        }
        if !output.status.success() {
            return Err(format!(
                "{} ({})",
                lithe_ui::i18n::tr("Could not start configuration"),
                output.status
            ));
        }
    }

    let arguments = merge_path_arguments(
        &launch.arguments,
        &resolve_plan_paths(&root, &launch.classpath),
        &resolve_plan_paths(&root, &launch.modulepath),
    );
    let mut command = command_for(&executable, &arguments);
    command
        .current_dir(&working_directory)
        .envs(&environment)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    ProcessTree::prepare(&mut command);
    let mut child = command.spawn().map_err(|error| {
        format!(
            "{}: {}: {error}",
            lithe_ui::i18n::tr("Could not start configuration"),
            executable.display()
        )
    })?;
    let tree = ProcessTree::adopt(&mut child).map_err(|error| {
        let _ = child.kill();
        format!(
            "{}: {}: {error}",
            lithe_ui::i18n::tr("Could not start configuration"),
            executable.display()
        )
    })?;
    let _ = sender.send_blocking(SessionEvent::Started(Arc::new(tree)));

    if let Some(stdout) = child.stdout.take() {
        spawn_reader(stdout, sender.clone());
    }
    if let Some(stderr) = child.stderr.take() {
        spawn_reader(stderr, sender.clone());
    }
    spawn_exit_waiter(child, sender);
    Ok(())
}

fn spawn_reader<R: Read + Send + 'static>(mut reader: R, sender: Sender<SessionEvent>) {
    thread::spawn(move || {
        let mut buffer = [0u8; 8192];
        loop {
            match reader.read(&mut buffer) {
                Ok(0) => break,
                Ok(count) => {
                    let text = String::from_utf8_lossy(&buffer[..count]).into_owned();
                    if sender.send_blocking(SessionEvent::Output(text)).is_err() {
                        break;
                    }
                }
                Err(error) if error.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(_) => break,
            }
        }
    });
}

fn spawn_exit_waiter(mut child: Child, sender: Sender<SessionEvent>) {
    thread::spawn(move || {
        let code = child.wait().ok().and_then(|status| status.code());
        let _ = sender.send_blocking(SessionEvent::Exited(code));
    });
}

/// 停止整棵进程树。调用方应放到后台线程，避免等待内核回收时卡住界面。
pub fn stop(tree: Arc<ProcessTree>) -> Result<(), String> {
    tree.terminate(Duration::from_secs(10))
        .map_err(|error| format!("{}: {error}", lithe_ui::i18n::tr("Could not stop run")))
}

// ---------------------------------------------------------------------------
// 启动计划
// ---------------------------------------------------------------------------

#[derive(Clone, Debug)]
enum ExecutableRef {
    Command(String),
    Toolchain {
        name: String,
        /// `project-jdk` may name a sibling tool such as `javac`.
        tool: Option<String>,
    },
}

#[derive(Clone, Debug)]
enum EnvironmentRef {
    Literal(String),
    ToolchainHome(String),
}

struct LaunchPlan {
    executable: ExecutableRef,
    arguments: Vec<String>,
    working_directory: String,
    environment: BTreeMap<String, EnvironmentRef>,
    env: BTreeMap<String, String>,
    classpath: Vec<String>,
    modulepath: Vec<String>,
    pre_launch_steps: Vec<LaunchStep>,
}

struct LaunchStep {
    executable: ExecutableRef,
    arguments: Vec<String>,
    working_directory: Option<String>,
    classpath: Vec<String>,
}

impl LaunchPlan {
    fn from_json(value: &Value) -> Result<Self, String> {
        let executable =
            parse_executable(value.get("executable").ok_or_else(|| {
                lithe_ui::i18n::tr("Could not read run configuration").to_string()
            })?)?;
        let arguments = string_array(value.get("arguments"));
        let working_directory = value
            .get("workingDirectory")
            .and_then(Value::as_str)
            .unwrap_or(".")
            .to_string();
        let env = string_map(value.get("env"));
        let mut environment = BTreeMap::new();
        if let Some(object) = value.get("environment").and_then(Value::as_object) {
            for (key, reference) in object {
                if let Some(toolchain) = reference.get("toolchain").and_then(Value::as_str) {
                    environment.insert(
                        key.clone(),
                        EnvironmentRef::ToolchainHome(toolchain.to_string()),
                    );
                } else if let Some(literal) = reference.as_str() {
                    environment.insert(key.clone(), EnvironmentRef::Literal(literal.to_string()));
                }
            }
        }
        let classpath = string_array(value.get("classpath"));
        let modulepath = string_array(value.get("modulepath"));
        let pre_launch_steps = value
            .get("preLaunchSteps")
            .and_then(Value::as_array)
            .map(|items| {
                items
                    .iter()
                    .filter_map(|step| {
                        let executable = parse_executable(step.get("executable")?).ok()?;
                        Some(LaunchStep {
                            executable,
                            arguments: string_array(step.get("arguments")),
                            working_directory: step
                                .get("workingDirectory")
                                .and_then(Value::as_str)
                                .map(str::to_string),
                            classpath: string_array(step.get("classpath")),
                        })
                    })
                    .collect()
            })
            .unwrap_or_default();

        Ok(Self {
            executable,
            arguments,
            working_directory,
            environment,
            env,
            classpath,
            modulepath,
            pre_launch_steps,
        })
    }
}

fn parse_executable(value: &Value) -> Result<ExecutableRef, String> {
    if let Some(command) = value.get("command").and_then(Value::as_str) {
        return Ok(ExecutableRef::Command(command.to_string()));
    }
    if let Some(toolchain) = value.get("toolchain").and_then(Value::as_str) {
        return Ok(ExecutableRef::Toolchain {
            name: toolchain.to_string(),
            tool: value
                .get("tool")
                .and_then(Value::as_str)
                .map(str::to_string),
        });
    }
    Err(lithe_ui::i18n::tr("Could not read run configuration").to_string())
}

fn string_array(value: Option<&Value>) -> Vec<String> {
    value
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default()
}

fn string_map(value: Option<&Value>) -> BTreeMap<String, String> {
    value
        .and_then(Value::as_object)
        .map(|object| {
            object
                .iter()
                .filter_map(|(key, value)| {
                    value.as_str().map(|value| (key.clone(), value.to_string()))
                })
                .collect()
        })
        .unwrap_or_default()
}

/// Core 的 classpath/modulepath 是项目相对路径；JVM 需要宿主绝对路径。
fn resolve_plan_paths(root: &Path, paths: &[String]) -> Vec<String> {
    paths
        .iter()
        .map(|value| {
            let path = Path::new(value);
            if path.is_absolute() {
                value.clone()
            } else {
                root.join(path).to_string_lossy().into_owned()
            }
        })
        .collect()
}

fn resolve_working_directory(root: &Path, value: &str) -> PathBuf {
    let path = Path::new(value);
    let path = if path.is_absolute() {
        path.to_path_buf()
    } else {
        root.join(path)
    };
    if path.is_dir() {
        path
    } else {
        root.to_path_buf()
    }
}

fn resolve_environment_reference(
    root: &Path,
    working_directory: &Path,
    reference: &EnvironmentRef,
) -> Option<String> {
    match reference {
        EnvironmentRef::Literal(value) => Some(value.clone()),
        EnvironmentRef::ToolchainHome(toolchain) => {
            if toolchain == "project-jdk" {
                // Only publish a verified JDK home. A `java.exe` shim on PATH
                // (for example Oracle's javapath) is not a JDK root; setting
                // JAVA_HOME to its guessed parent makes Maven fail later.
                if let Some(home) = std::env::var_os("JAVA_HOME") {
                    let home = PathBuf::from(home);
                    if home.join("bin").join(jdk_tool_name("javac")).is_file() {
                        return Some(home.to_string_lossy().into_owned());
                    }
                }
                let executable =
                    resolve_toolchain(root, working_directory, "project-jdk", None).ok()?;
                let home = executable.parent().and_then(Path::parent)?;
                if home.join("bin").join(jdk_tool_name("javac")).is_file() {
                    return Some(home.to_string_lossy().into_owned());
                }
                return None;
            }
            let executable = resolve_toolchain(root, working_directory, toolchain, None).ok()?;
            executable
                .parent()
                .and_then(Path::parent)
                .map(|home| home.to_string_lossy().into_owned())
        }
    }
}

fn jdk_tool_name(tool: &str) -> String {
    if cfg!(windows) {
        format!("{tool}.exe")
    } else {
        tool.to_string()
    }
}

fn resolve_executable(
    root: &Path,
    working_directory: &Path,
    executable: &ExecutableRef,
) -> Result<PathBuf, String> {
    match executable {
        ExecutableRef::Command(command) => resolve_command(root, command),
        ExecutableRef::Toolchain { name, tool } => {
            resolve_toolchain(root, working_directory, name, tool.as_deref())
        }
    }
}

fn resolve_toolchain(
    root: &Path,
    working_directory: &Path,
    toolchain: &str,
    tool: Option<&str>,
) -> Result<PathBuf, String> {
    match toolchain {
        "project-jdk" => {
            let tool = tool.unwrap_or("java");
            let executable_name = jdk_tool_name(if tool.is_empty() { "java" } else { tool });
            if let Some(home) = std::env::var_os("JAVA_HOME") {
                let candidate = PathBuf::from(home).join("bin").join(&executable_name);
                if candidate.is_file() {
                    return Ok(candidate);
                }
            }
            find_on_path(executable_name.trim_end_matches(".exe")).ok_or_else(|| {
                lithe_ui::i18n::tr("No Java runtime was found. Set JAVA_HOME or install a JDK.")
                    .to_string()
            })
        }
        "project-maven" => {
            for directory in [working_directory, root] {
                for name in maven_wrapper_names() {
                    let candidate = directory.join(name);
                    if candidate.is_file() {
                        return Ok(candidate);
                    }
                }
            }
            find_on_path("mvn")
                .ok_or_else(|| format!("{}: mvn", lithe_ui::i18n::tr("Could not find executable")))
        }
        "project-gradle" => find_on_path("gradle").ok_or_else(|| {
            format!(
                "{}: gradle",
                lithe_ui::i18n::tr("Could not find executable")
            )
        }),
        "project-node" => find_on_path("node")
            .ok_or_else(|| format!("{}: node", lithe_ui::i18n::tr("Could not find executable"))),
        other => {
            let name = other.strip_prefix("project-").unwrap_or(other);
            find_on_path(name).ok_or_else(|| {
                format!(
                    "{}: {name}",
                    lithe_ui::i18n::tr("Could not find executable")
                )
            })
        }
    }
}

/// 一种工具链的探测方式。
///
/// `id` 必须和 Core `.lithe/toolchains/requirements.json` 里的 id 完全一致：Core 只在
/// 候选里找到「同 id + 同 type」的条目时才认为该工具链已选择，否则对每条
/// requirement 都报 `missingToolchain`。`type` 始终取 requirement 声明的值。
struct ToolchainProbe {
    id: &'static str,
    command: &'static str,
    version_arguments: &'static [&'static str],
}

/// 宿主能上报的工具链候选，覆盖 Core 生成 requirement 时会用到的 id。
const TOOLCHAIN_PROBES: &[ToolchainProbe] = &[
    ToolchainProbe {
        id: "project-jdk",
        command: "java",
        version_arguments: &["-version"],
    },
    ToolchainProbe {
        id: "project-maven",
        command: "mvn",
        version_arguments: &["-v"],
    },
    ToolchainProbe {
        id: "project-gradle",
        command: "gradle",
        version_arguments: &["--version"],
    },
    ToolchainProbe {
        id: "project-node",
        command: "node",
        version_arguments: &["--version"],
    },
    ToolchainProbe {
        id: "project-python",
        command: "python",
        version_arguments: &["--version"],
    },
    ToolchainProbe {
        id: "project-rust",
        command: "cargo",
        version_arguments: &["--version"],
    },
    ToolchainProbe {
        id: "project-go",
        command: "go",
        version_arguments: &["version"],
    },
];

/// 本机工具链候选，随 `runConfig.resolve` 一起上报。
///
/// Core 只把「候选里存在同 id + 同 type」的 requirement 视为已选择；宿主不报候选
/// 时，即使机器上装了 JDK，每个 Java 配置都会报 “No local java toolchain is
/// selected”。这里读取 `.lithe/toolchains/requirements.json`，只为声明过的工具链
/// 探测，避免每次刷新都为全部工具拉起子进程；requirements 不存在时 Core 本来也
/// 不会产出工具链诊断。
pub(crate) fn toolchain_candidates(root: &Path) -> Vec<Value> {
    let Some(requirements) = read_toolchain_requirements(root) else {
        return Vec::new();
    };

    let mut candidates = Vec::new();
    for (id, kind, needs_version) in requirements {
        let Some((command, version_arguments)) = probe_for(&id) else {
            continue;
        };
        let Ok(executable) = resolve_toolchain(root, root, &id, Some(command.as_str())) else {
            continue;
        };
        // 版本只在 requirement 声明了版本约束时探测：没有约束时 Core 不比较版本。
        let version = if needs_version {
            toolchain_version(&executable, &kind, version_arguments)
        } else {
            String::new()
        };
        candidates.push(json!({
            "id": id,
            "type": kind,
            "version": version,
            "vendor": "",
        }));
    }
    candidates
}

/// 读取 requirements 里的 `(id, type, 是否声明版本约束)`。
fn read_toolchain_requirements(root: &Path) -> Option<Vec<(String, String, bool)>> {
    let path = root
        .join(".lithe")
        .join("toolchains")
        .join("requirements.json");
    let text = std::fs::read_to_string(path).ok()?;
    let document: Value = serde_json::from_str(&text).ok()?;
    let toolchains = document.get("toolchains")?.as_object()?;

    let mut entries = Vec::new();
    for (id, requirement) in toolchains {
        let Some(kind) = requirement.get("type").and_then(Value::as_str) else {
            continue;
        };
        let has_version_constraint = ["minimumVersion", "version"].iter().any(|field| {
            requirement
                .get(*field)
                .and_then(Value::as_str)
                .is_some_and(|value| !value.trim().is_empty())
        });
        entries.push((id.clone(), kind.to_string(), has_version_constraint));
    }
    Some(entries)
}

/// 按 requirement id 找探测方式；未知 id 退化成 `project-<tool>` + `--version`。
fn probe_for(id: &str) -> Option<(String, &'static [&'static str])> {
    if let Some(probe) = TOOLCHAIN_PROBES.iter().find(|probe| probe.id == id) {
        return Some((probe.command.to_string(), probe.version_arguments));
    }
    let tool = id.strip_prefix("project-")?;
    if tool.is_empty() {
        return None;
    }
    Some((tool.to_string(), &["--version"]))
}

/// 探测工具链版本；探测不出来时返回空串，让 Core 自己决定如何诊断。
fn toolchain_version(executable: &Path, kind: &str, arguments: &[&str]) -> String {
    // JDK 的 `bin/java` 上一级总有 `release`，读它比拉起 `java -version` 便宜。
    if kind == "java" {
        if let Some(version) = java_release_version(executable) {
            return version;
        }
    }
    let Ok(output) = Command::new(executable)
        .args(arguments)
        .stdin(Stdio::null())
        .output()
    else {
        return String::new();
    };
    let text = format!(
        "{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    first_version_token(&text).unwrap_or_default()
}

/// 读 `<jdk>/release` 里的 `JAVA_VERSION`。
fn java_release_version(executable: &Path) -> Option<String> {
    let release = executable.parent()?.parent()?.join("release");
    let text = std::fs::read_to_string(release).ok()?;
    text.lines().find_map(|line| {
        let value = line.strip_prefix("JAVA_VERSION=")?.trim().trim_matches('"');
        (!value.is_empty()).then(|| value.to_string())
    })
}

/// 取输出里第一个形如 `21.0.1` / `3.9.9` / `1.22` 的版本号。
fn first_version_token(text: &str) -> Option<String> {
    for raw in text.split_whitespace() {
        let token = raw.trim_matches(|character: char| !character.is_ascii_digit());
        if token.contains('.')
            && token
                .chars()
                .all(|character| character.is_ascii_digit() || character == '.')
        {
            return Some(token.to_string());
        }
    }
    None
}

/// Maven wrapper entry that this platform can actually execute. A Windows
/// host must not fall back to the extensionless POSIX `mvnw`.
#[cfg(windows)]
fn maven_wrapper_names() -> &'static [&'static str] {
    &["mvnw.cmd"]
}

#[cfg(not(windows))]
fn maven_wrapper_names() -> &'static [&'static str] {
    &["mvnw"]
}

fn resolve_command(root: &Path, command: &str) -> Result<PathBuf, String> {
    let path = Path::new(command);
    if path.is_absolute() {
        return Ok(prefer_executable_image(path.to_path_buf()));
    }
    if command.contains('/') || command.contains('\\') {
        let candidate = root.join(path);
        if candidate.is_file() {
            return Ok(prefer_executable_image(candidate));
        }
    }
    find_on_path(command).ok_or_else(|| {
        format!(
            "{}: {command}",
            lithe_ui::i18n::tr("Could not find executable")
        )
    })
}

fn find_on_path(name: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    for directory in std::env::split_paths(&path) {
        for file_name in command_file_names(name) {
            let candidate = directory.join(file_name);
            if candidate.is_file() {
                return Some(candidate);
            }
        }
    }
    None
}

/// Executable file names to probe for one command, in resolution order.
///
/// Windows distributions ship both `mvn.cmd`/`gradle.bat` and an extensionless
/// POSIX script of the same name; `CreateProcess` rejects the script with
/// "not a valid Win32 application", so the runnable image wins over the bare
/// file even when the bare file exists.
#[cfg(windows)]
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

#[cfg(not(windows))]
fn command_file_names(command: &str) -> Vec<String> {
    vec![command.to_string()]
}

#[cfg(windows)]
fn prefer_executable_image(path: PathBuf) -> PathBuf {
    if path.extension().is_some() {
        return path;
    }
    let names = path
        .file_name()
        .and_then(|name| name.to_str())
        .map(command_file_names)
        .unwrap_or_default();
    let Some(parent) = path.parent() else {
        return path;
    };
    let resolved = names
        .into_iter()
        .map(|name| parent.join(name))
        .find(|candidate| candidate.is_file());
    resolved.unwrap_or(path)
}

#[cfg(not(windows))]
fn prefer_executable_image(path: PathBuf) -> PathBuf {
    path
}

fn command_for(executable: &Path, arguments: &[String]) -> Command {
    #[cfg(windows)]
    {
        let extension = executable
            .extension()
            .and_then(|extension| extension.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();
        if extension == "cmd" || extension == "bat" {
            let mut command = Command::new("cmd");
            command.arg("/c").arg(executable);
            command.args(arguments);
            return command;
        }
    }
    let mut command = Command::new(executable);
    command.args(arguments);
    command
}

fn merge_path_arguments(
    arguments: &[String],
    classpath: &[String],
    modulepath: &[String],
) -> Vec<String> {
    let mut merged = merge_one_path(
        arguments.to_vec(),
        classpath,
        &["-cp", "-classpath", "--class-path"],
        "-cp",
    );
    merged = merge_one_path(merged, modulepath, &["-p", "--module-path"], "-p");
    merged
}

fn merge_one_path(
    mut arguments: Vec<String>,
    paths: &[String],
    flags: &[&str],
    default_flag: &str,
) -> Vec<String> {
    if paths.is_empty() {
        return arguments;
    }
    let joined = paths.join(path_list_separator());
    for index in (0..arguments.len().saturating_sub(1)).rev() {
        if flags.contains(&arguments[index].as_str()) {
            arguments[index + 1] = format!(
                "{}{}{}",
                joined,
                path_list_separator(),
                arguments[index + 1]
            );
            return arguments;
        }
    }
    let mut result = vec![default_flag.to_string(), joined];
    result.extend(arguments);
    result
}

fn path_list_separator() -> &'static str {
    #[cfg(windows)]
    {
        ";"
    }
    #[cfg(not(windows))]
    {
        ":"
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;

    #[test]
    fn merges_classpath_into_existing_flag() {
        let arguments = vec!["-cp".to_string(), "old.jar".to_string()];
        let merged = merge_path_arguments(&arguments, &["a.jar".to_string()], &[]);
        assert_eq!(merged[1], format!("a.jar{}old.jar", path_list_separator()));
    }

    #[test]
    fn prepends_classpath_when_missing() {
        let arguments = vec!["Main".to_string()];
        let merged = merge_path_arguments(&arguments, &["a.jar".to_string()], &[]);
        assert_eq!(merged[0], "-cp");
        assert_eq!(merged[1], "a.jar");
        assert_eq!(merged[2], "Main");
    }

    #[test]
    fn runs_a_procfile_process_and_reports_its_output_and_exit() {
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("clock should be after epoch")
            .as_nanos();
        let root =
            std::env::temp_dir().join(format!("lithe-run-session-{}-{unique}", std::process::id()));
        std::fs::create_dir_all(&root).expect("temp project should be created");
        #[cfg(windows)]
        let procfile = "web: cmd /c echo lithe-run-ok\n";
        #[cfg(not(windows))]
        let procfile = "web: echo lithe-run-ok\n";
        std::fs::write(root.join("Procfile"), procfile).expect("Procfile should be written");

        let client = CoreClient::new();
        let loaded =
            super::super::config::load_configurations(&client, &root).expect("config should load");
        let configuration = loaded
            .configurations
            .into_iter()
            .find(|configuration| configuration.provider == "procfile.process")
            .expect("Procfile configuration should exist");
        let receiver = start(client, root.clone(), configuration);

        let watchdog = receiver.clone();
        let started = Instant::now();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_secs(10));
            watchdog.close();
        });

        let mut output = String::new();
        let mut exit_code = None;
        // 必须在测试期间保留进程树；Job Object 在最后一个 Arc 释放时会杀死
        // 子进程，与真实视图的 SessionState 生命周期一致。
        let mut _tree = None;
        while started.elapsed() < Duration::from_secs(10) {
            match receiver.recv_blocking() {
                Ok(SessionEvent::Output(text)) => output.push_str(&text),
                Ok(SessionEvent::Started(tree)) => _tree = Some(tree),
                Ok(SessionEvent::Exited(code)) => {
                    // 读取线程可能比退出等待线程晚一个调度片；继续把通道
                    // 里剩余的 stdout/stderr 排空，直到所有 sender 释放。
                    exit_code = code;
                }
                Ok(SessionEvent::Failed(message)) => panic!("run failed: {message}"),
                Err(_) => break,
            }
        }
        let _ = std::fs::remove_dir_all(&root);
        assert!(output.contains("lithe-run-ok"), "output was: {output}");
        assert_eq!(exit_code, Some(0));
        assert!(started.elapsed() < Duration::from_secs(10));
    }
}
