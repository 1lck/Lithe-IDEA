//! Maven 任务会话：Core 启动计划、本机可执行文件解析和子进程生命周期。
//!
//! Core 只返回平台中立的启动计划（`maven.launchPlan` / `maven.dependencyPlan`），
//! 不负责拉起 Maven；`executable.toolchain` 恒为 `project-maven`，真实可执行
//! 文件由宿主解析。这与 Tauri 的分工一致：`maven.launchPlan` 给参数，本机
//! 适配器给 `mvnw` / `mvn`。
//!
//! 停止时必须结束整棵进程树：`mvn` 会再拉起 `java`，只杀父进程会留下孤儿。
//! 这里复用 `lithe-git-host` 的 `ProcessTree`，与 Run 面板的停止语义相同。

use std::collections::BTreeMap;
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::sync::Arc;
use std::thread;

use async_channel::{Receiver, Sender, unbounded};
use lithe_core_client::CoreClient;
use lithe_git_host::ProcessTree;
use serde_json::{Value, json};

use super::model::{Dependency, LaunchContext};

/// 会话向视图发送的事件。
pub enum SessionEvent {
    /// 子进程已创建；视图保留进程树用于 Stop。
    Started(Arc<ProcessTree>),
    Output(String),
    Exited(Option<i32>),
    Failed(String),
}

/// 一次已经解析到本机可执行文件的 Maven 启动。
pub struct MavenLaunch {
    pub executable: PathBuf,
    pub arguments: Vec<String>,
    pub working_directory: PathBuf,
    pub environment: BTreeMap<String, String>,
}

impl MavenLaunch {
    /// 展示用的命令行。`settings.xml` 与本地仓库路径要脱敏，避免把用户目录
    /// 写进构建输出。
    pub fn display_arguments(&self) -> String {
        let mut parts: Vec<String> = Vec::with_capacity(self.arguments.len());
        let mut previous = "";
        for argument in &self.arguments {
            if previous == "-s" {
                parts.push("<settings.xml>".to_string());
            } else if let Some(rest) = argument.strip_prefix("-Dmaven.repo.local=") {
                let _ = rest;
                parts.push("-Dmaven.repo.local=<localRepository>".to_string());
            } else {
                parts.push(argument.clone());
            }
            previous = argument.as_str();
        }
        parts.join(" ")
    }

    /// 可执行文件名（不含目录）。
    pub fn executable_name(&self) -> String {
        self.executable
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("mvn")
            .to_string()
    }
}

/// 为一次生命周期目标生成启动计划。
///
/// # Blocking
///
/// 会调用 Core；调用方必须放在后台线程或 `cx.background_spawn` 中。
pub fn plan_goal(
    client: CoreClient,
    root: &Path,
    context: &LaunchContext,
    module: Option<&str>,
    goals: &[String],
) -> Result<MavenLaunch, String> {
    let request = json!({
        "root": root_text(root)?,
        "context": context.to_json(),
        "module": module,
        "goals": goals,
    });
    let plan = client
        .execute_raw("maven.launchPlan", request)
        .map_err(|error| {
            format!(
                "{}: {error}",
                lithe_ui::i18n::tr("Could not start Maven task")
            )
        })?;
    resolve_launch(client, root, context, &plan)
}

/// 为一次依赖树解析生成启动计划。
///
/// `output_file` 是 Maven 写依赖树的绝对路径；Core 会把它写进
/// `-DoutputFile=`，因此必须先由宿主准备好这个文件的位置。
///
/// # Blocking
///
/// 会调用 Core；调用方必须放在后台线程或 `cx.background_spawn` 中。
pub fn plan_dependency_tree(
    client: CoreClient,
    root: &Path,
    context: &LaunchContext,
    module: Option<&str>,
    output_file: &Path,
) -> Result<MavenLaunch, String> {
    let request = json!({
        "root": root_text(root)?,
        "context": context.to_json(),
        "module": module,
        "outputFile": output_file.to_string_lossy(),
    });
    let plan = client
        .execute_raw("maven.dependencyPlan", request)
        .map_err(|error| {
            format!(
                "{}: {error}",
                lithe_ui::i18n::tr("Could not resolve Maven dependencies")
            )
        })?;
    resolve_launch(client, root, context, &plan)
}

/// 读取 Core 写出的依赖树。
///
/// # Blocking
///
/// 会调用 Core 并读文件；调用方必须放在后台线程或 `cx.background_spawn` 中。
pub fn read_dependencies(
    client: CoreClient,
    module_path: &str,
    output_file: &Path,
) -> Result<Vec<Dependency>, String> {
    let request = json!({
        "modulePath": module_path,
        "outputFile": output_file.to_string_lossy(),
    });
    let response = client
        .execute_raw("maven.dependencies", request)
        .map_err(|error| {
            format!(
                "{}: {error}",
                lithe_ui::i18n::tr("Could not resolve Maven dependencies")
            )
        })?;
    let dependencies = response
        .get("dependencies")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(|item| Dependency::from_json(item))
                .collect()
        })
        .unwrap_or_default();
    Ok(dependencies)
}

/// 从 Maven 控制台输出里解析诊断。
///
/// # Blocking
///
/// 会调用 Core；调用方必须放在后台线程或 `cx.background_spawn` 中。
pub fn parse_diagnostics(
    client: CoreClient,
    root: &Path,
    output: &str,
) -> Result<Vec<Diagnostic>, String> {
    let request = json!({
        "root": root_text(root)?,
        "output": output,
    });
    let response = client
        .execute_raw("maven.diagnostics", request)
        .map_err(|error| {
            format!(
                "{}: {error}",
                lithe_ui::i18n::tr("Could not read Maven diagnostics")
            )
        })?;
    Ok(response
        .get("issues")
        .and_then(Value::as_array)
        .map(|items| items.iter().filter_map(Diagnostic::from_json).collect())
        .unwrap_or_default())
}

/// 从 Maven 控制台输出里解析测试结果。
///
/// # Blocking
///
/// 会调用 Core；调用方必须放在后台线程或 `cx.background_spawn` 中。
pub fn parse_test_results(
    client: CoreClient,
    root: &Path,
    output: &str,
) -> Result<Option<TestResults>, String> {
    let request = json!({
        "root": root_text(root)?,
        "output": output,
    });
    let response = client
        .execute_raw("maven.testResults", request)
        .map_err(|error| {
            format!(
                "{}: {error}",
                lithe_ui::i18n::tr("Could not read Maven test results")
            )
        })?;
    Ok(TestResults::from_json(&response))
}

/// 一条 Maven 诊断。
#[derive(Clone, Debug)]
pub struct Diagnostic {
    pub path: String,
    /// 1 起始的行号。
    pub line: u32,
    pub column: Option<u32>,
    pub severity: DiagnosticSeverity,
    pub message: String,
}

impl Diagnostic {
    fn from_json(value: &Value) -> Option<Self> {
        Some(Self {
            path: value.get("path")?.as_str()?.to_string(),
            line: value.get("line").and_then(Value::as_u64).unwrap_or(1) as u32,
            column: value
                .get("column")
                .and_then(Value::as_u64)
                .map(|column| column as u32),
            severity: DiagnosticSeverity::from_wire(
                value
                    .get("severity")
                    .and_then(Value::as_str)
                    .unwrap_or("error"),
            ),
            message: value
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or_default()
                .to_string(),
        })
    }

    /// 诊断位置，`path:line[:column]`。
    pub fn location(&self) -> String {
        let mut text = format!("{}:{}", self.path, self.line);
        if let Some(column) = self.column {
            text.push(':');
            text.push_str(&column.to_string());
        }
        text
    }
}

/// 诊断的严重级别。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum DiagnosticSeverity {
    Error,
    Warning,
}

impl DiagnosticSeverity {
    fn from_wire(value: &str) -> Self {
        match value {
            "warning" => Self::Warning,
            _ => Self::Error,
        }
    }
}

/// Maven 测试结果汇总。
#[derive(Clone, Debug, Default)]
pub struct TestResults {
    pub tests_run: u32,
    pub failures: u32,
    pub errors: u32,
    pub skipped: u32,
    pub passed: u32,
    pub success: bool,
    pub failure_details: Vec<TestFailure>,
}

impl TestResults {
    fn from_json(value: &Value) -> Option<Self> {
        let object = value.as_object()?;
        Some(Self {
            tests_run: object.get("testsRun").and_then(Value::as_u64).unwrap_or(0) as u32,
            failures: object.get("failures").and_then(Value::as_u64).unwrap_or(0) as u32,
            errors: object.get("errors").and_then(Value::as_u64).unwrap_or(0) as u32,
            skipped: object.get("skipped").and_then(Value::as_u64).unwrap_or(0) as u32,
            passed: object.get("passed").and_then(Value::as_u64).unwrap_or(0) as u32,
            success: object
                .get("success")
                .and_then(Value::as_bool)
                .unwrap_or(false),
            failure_details: object
                .get("failureDetails")
                .and_then(Value::as_array)
                .map(|items| items.iter().filter_map(TestFailure::from_json).collect())
                .unwrap_or_default(),
        })
    }

    /// 失败与错误之和，作为失败计数展示。
    pub fn failed_count(&self) -> u32 {
        self.failures + self.errors
    }
}

/// 一条测试失败详情。
#[derive(Clone, Debug)]
pub struct TestFailure {
    pub name: String,
    pub message: Option<String>,
    pub path: Option<String>,
    pub line: Option<u32>,
    pub column: Option<u32>,
}

impl TestFailure {
    fn from_json(value: &Value) -> Option<Self> {
        Some(Self {
            name: value.get("name")?.as_str()?.to_string(),
            message: value
                .get("message")
                .and_then(Value::as_str)
                .map(|value| value.to_string()),
            path: value
                .get("path")
                .and_then(Value::as_str)
                .map(|value| value.to_string()),
            line: value
                .get("line")
                .and_then(Value::as_u64)
                .map(|line| line as u32),
            column: value
                .get("column")
                .and_then(Value::as_u64)
                .map(|column| column as u32),
        })
    }

    /// 源码位置描述；没有位置时返回空串。
    pub fn location(&self) -> String {
        let Some(path) = self.path.as_ref() else {
            return String::new();
        };
        let mut text = path.clone();
        if let Some(line) = self.line {
            text.push(':');
            text.push_str(&line.to_string());
            if let Some(column) = self.column {
                text.push(':');
                text.push_str(&column.to_string());
            }
        }
        text
    }
}

/// 启动 Maven 子进程，立即返回事件通道。
///
/// # Blocking
///
/// 会创建进程并起线程；调用方必须放在后台线程或 `cx.background_spawn` 中。
pub fn spawn(launch: MavenLaunch) -> Receiver<SessionEvent> {
    let (sender, receiver) = unbounded();
    thread::spawn(move || {
        if let Err(message) = run(launch, sender.clone()) {
            let _ = sender.send_blocking(SessionEvent::Failed(message));
        }
    });
    receiver
}

/// 停止整棵进程树。调用方应放到后台线程。
pub fn stop(tree: Arc<ProcessTree>) -> Result<(), String> {
    tree.terminate(std::time::Duration::from_secs(10))
        .map_err(|error| {
            format!(
                "{}: {error}",
                lithe_ui::i18n::tr("Could not stop Maven task")
            )
        })
}

/// 把 Core 的启动计划翻译成本机可执行文件与工作目录。
fn resolve_launch(
    client: CoreClient,
    root: &Path,
    context: &LaunchContext,
    plan: &Value,
) -> Result<MavenLaunch, String> {
    let arguments: Vec<String> = plan
        .get("arguments")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default();
    let working_directory_text = plan
        .get("workingDirectory")
        .and_then(Value::as_str)
        .unwrap_or(".");
    let working_directory = resolve_working_directory(root, working_directory_text);
    let executable =
        crate::run::session::resolve_toolchain(root, &working_directory, "project-maven", None)?;
    let environment = resolve_environment(client, context);
    Ok(MavenLaunch {
        executable,
        arguments,
        working_directory,
        environment,
    })
}

/// 解析 Maven 进程的 `JAVA_HOME`。
///
/// Core 的 `execution.resolveEnvironment` 拥有「继承 < 工具链 < 显式覆盖」的
/// 优先级，宿主只把结果交给子进程，不自己拼 `JAVA_HOME`。
fn resolve_environment(client: CoreClient, context: &LaunchContext) -> BTreeMap<String, String> {
    let java_home = context.java_home_path.clone();
    let request = json!({
        "toolchain": "project-maven",
        "javaHome": java_home,
        "mavenJavaHome": java_home,
        "inherited": inherited_environment(),
        "overrides": {},
        "caseInsensitive": cfg!(windows),
    });
    let Ok(response) = client.execute_raw("execution.resolveEnvironment", request) else {
        return BTreeMap::new();
    };
    response
        .get("environment")
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

/// 宿主进程的环境变量，作为 Core 环境解析的继承层。
fn inherited_environment() -> BTreeMap<String, String> {
    std::env::vars().collect()
}

/// 把 Core 的工作目录（工作区相对）解析成绝对路径。
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

/// 拉起进程并把 stdout / stderr 转发到事件通道。
fn run(launch: MavenLaunch, sender: Sender<SessionEvent>) -> Result<(), String> {
    let mut command = crate::run::session::command_for(&launch.executable, &launch.arguments);
    command
        .current_dir(&launch.working_directory)
        .envs(&launch.environment)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    ProcessTree::prepare(&mut command);
    let mut child = command.spawn().map_err(|error| {
        format!(
            "{}: {}: {error}",
            lithe_ui::i18n::tr("Could not start Maven task"),
            launch.executable.display()
        )
    })?;
    let tree = ProcessTree::adopt(&mut child).map_err(|error| {
        let _ = child.kill();
        format!(
            "{}: {}: {error}",
            lithe_ui::i18n::tr("Could not start Maven task"),
            launch.executable.display()
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

/// 工作区根转成 Core 需要的 UTF-8 字符串。
fn root_text(root: &Path) -> Result<String, String> {
    root.to_str()
        .map(|value| value.to_string())
        .ok_or_else(|| lithe_ui::i18n::tr("Project path is not valid UTF-8").to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;
    use std::time::Instant;

    #[test]
    fn masks_the_settings_and_repository_paths_in_the_displayed_command() {
        let launch = MavenLaunch {
            executable: PathBuf::from("/usr/bin/mvn"),
            arguments: vec![
                "-B".to_string(),
                "-s".to_string(),
                "/home/user/.m2/settings.xml".to_string(),
                "-Dmaven.repo.local=/home/user/.m2/repository".to_string(),
                "verify".to_string(),
            ],
            working_directory: PathBuf::from("/tmp"),
            environment: BTreeMap::new(),
        };
        let displayed = launch.display_arguments();
        assert!(displayed.contains("<settings.xml>"));
        assert!(!displayed.contains("/home/user/.m2/settings.xml"));
        assert!(displayed.contains("-Dmaven.repo.local=<localRepository>"));
        assert!(displayed.ends_with("verify"));
    }

    #[test]
    fn reads_a_diagnostic_location() {
        let value = json!({
            "path": "/tmp/Foo.java",
            "line": 12,
            "column": 5,
            "severity": "error",
            "message": "cannot find symbol"
        });
        let diagnostic = Diagnostic::from_json(&value).expect("diagnostic should parse");
        assert_eq!(diagnostic.location(), "/tmp/Foo.java:12:5");
        assert_eq!(diagnostic.severity, DiagnosticSeverity::Error);
    }

    /// 会话层必须把子进程 stdout 逐块转发成 `SessionEvent::Output`，退出码
    /// 原样上报；这是 Maven 输出面板能实时滚动的前提。
    #[test]
    fn streams_process_output_and_exit_code() {
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("clock should be after epoch")
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "lithe-maven-session-{}-{unique}",
            std::process::id()
        ));
        std::fs::create_dir_all(&root).expect("temp dir should be created");

        // 用批处理文件模拟 Maven：先打一行、隔一拍再打一行、以退出码 1 结束。
        // timeout 需要交互输入，这里用 ping 延时，保证两行输出分属不同读取块。
        #[cfg(windows)]
        let script_path = root.join("lithe-maven-probe.cmd");
        #[cfg(windows)]
        let script = "@echo off\r\necho lithe-maven-line-one\r\nping -n 2 127.0.0.1 >nul\r\necho lithe-maven-line-two\r\nexit /b 1\r\n";
        #[cfg(windows)]
        std::fs::write(&script_path, script).expect("probe script should be written");
        #[cfg(windows)]
        let (executable, arguments) = (
            script_path.clone(),
            vec!["-B".to_string(), "-ntp".to_string(), "compile".to_string()],
        );
        #[cfg(not(windows))]
        let (executable, arguments) = (
            PathBuf::from("sh"),
            vec![
                "-c".to_string(),
                "echo lithe-maven-line-one; sleep 1; echo lithe-maven-line-two; exit 1".to_string(),
            ],
        );

        let launch = MavenLaunch {
            executable,
            arguments,
            working_directory: root.clone(),
            environment: BTreeMap::new(),
        };
        let receiver = spawn(launch);

        // 看门狗：万一子进程挂住，10 秒后关闭通道让 recv_blocking 返回，测试
        // 以失败收场而不是卡死 CI。
        let watchdog = receiver.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_secs(10));
            watchdog.close();
        });

        let started = Instant::now();
        let mut output = String::new();
        let mut exit_code = None;
        let mut _tree = None;
        while started.elapsed() < Duration::from_secs(10) {
            match receiver.recv_blocking() {
                Ok(SessionEvent::Output(text)) => output.push_str(&text),
                Ok(SessionEvent::Started(tree)) => _tree = Some(tree),
                Ok(SessionEvent::Exited(code)) => exit_code = code,
                Ok(SessionEvent::Failed(message)) => panic!("session failed: {message}"),
                Err(_) => break,
            }
        }
        let _ = std::fs::remove_dir_all(&root);
        assert!(
            output.contains("lithe-maven-line-one") && output.contains("lithe-maven-line-two"),
            "output was: {output}"
        );
        assert_eq!(exit_code, Some(1));
        assert!(started.elapsed() < Duration::from_secs(10));
    }
}
