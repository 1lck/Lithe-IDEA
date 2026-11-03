//! 运行会话：Core 启动计划、本机可执行文件解析和子进程生命周期。
//!
//! Core 只返回平台中立的启动计划；本模块负责把它变成真实进程：
//! `lithe-git-host::ProcessTree` 保证停止时整棵进程树一起结束，stdout/stderr
//! 通过独立线程回传，视图线程只合并文本和状态。

use std::collections::{BTreeMap, HashMap};
use std::io::Read;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, LazyLock, Mutex};
use std::thread;
use std::time::Duration;

use async_channel::{Receiver, Sender, unbounded};
use lithe_core_client::CoreClient;
use lithe_git_host::ProcessTree;
use serde_json::{Value, json};

use super::direct;
use super::model::{PreparationPhase, RunConfiguration};
use super::toolchain;

/// 运行会话向视图发送的事件。
pub enum SessionEvent {
    /// 本次会话实际采用的启动方式；在打印命令行之前发送。
    LaunchMode(RunMode),
    /// 子进程已经创建；视图保留进程树用于 Stop。
    Started(Arc<ProcessTree>),
    Output(String),
    /// 准备状态条的真实进度；视图转交 `apply_preparation_event`。
    Preparation(PreparationEvent),
    Exited(Option<i32>),
    Failed(String),
}

/// 准备状态条的真实进度事件，字段语义与视图侧消费契约一致。
///
/// GPUI 侧没有 Java 语言服务导入，`import_percent` 与 `current_project`
/// 始终为 `None`，不伪造导入进度。
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum PreparationEvent {
    /// 准备阶段推进。
    Phase {
        phase: PreparationPhase,
        import_percent: Option<u8>,
        current_project: Option<String>,
        download_artifact: Option<String>,
    },
    /// 准备完成，主进程已经拉起。
    Ready,
    /// 准备失败。
    Failed,
}

/// 一次会话真正用上的启动方式。
///
/// 视图把它显示在「进程输出」后面：JVM 直启带走 classpath 直接启动主类，
/// 构建工具目标则交给 Maven / Gradle 拉起进程，两者不能只看配置类型猜出来。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RunMode {
    /// `java -cp <classpath> <MainClass>`：直接启动 JVM。
    JvmDirect,
    /// `mvn spring-boot:run` 一类 Maven 目标。
    MavenGoal,
    /// Gradle 等其它构建工具目标。
    BuildToolGoal,
    /// 普通命令进程。
    Process,
}

/// 启动一个配置，立即返回事件通道。
///
/// 这是阻塞函数：Core 调用、可执行文件探测和 pre-launch 步骤都在当前线程
/// 执行，调用方必须放到 `cx.background_spawn`。主进程的输出由独立线程读取。
pub fn start(
    client: CoreClient,
    root: PathBuf,
    configuration: RunConfiguration,
    skip_build: bool,
) -> Receiver<SessionEvent> {
    let (sender, receiver) = unbounded();
    thread::spawn(move || {
        if let Err(message) = launch(client, root, configuration, skip_build, sender.clone()) {
            // 整条启动链失败是唯一的准备失败节点；直启回退路径不会走到这里。
            let _ = sender.send_blocking(SessionEvent::Preparation(PreparationEvent::Failed));
            let _ = sender.send_blocking(SessionEvent::Failed(message));
        }
    });
    receiver
}

/// 构造 `runConfig.createLaunchPlan` 请求；启动和构建预检共用。
fn launch_request(root: &Path, configuration: &RunConfiguration) -> Value {
    let root_text = root.to_string_lossy().to_string();
    let mut request = json!({
        "root": root_text,
        "configurationId": configuration.id,
    });
    // Maven-backed configurations carry Core's reactor ownership. Passing it
    // back keeps `-pl`/`-f` relative to the reactor root instead of the module
    // directory, which matters for multi-module Spring Boot projects.
    if configuration.toolchains.contains_key("maven") {
        let maven = configuration.extensions.get("maven");
        let reactor_path = maven
            .and_then(|maven| maven.get("reactorPath"))
            .and_then(Value::as_str)
            .unwrap_or(".");
        let profiles = maven
            .and_then(|maven| maven.get("profiles"))
            .and_then(Value::as_array)
            .map(|items| {
                items
                    .iter()
                    .filter_map(Value::as_str)
                    .map(str::to_string)
                    .collect::<Vec<_>>()
            })
            .unwrap_or_default();
        // 与 Tauri 一样带上 Maven 工具窗保存的 settings / 本地仓库 / 可执行文件，
        // 否则多模块项目或自定义 Maven 在启动时会退回默认查找。
        let maven_settings = crate::maven::configuration::load_local(root, reactor_path);
        request["mavenContext"] = json!({
            "version": 1,
            "reactorPath": reactor_path,
            "profiles": profiles,
            "settingsPath": maven_settings.settings_path,
            "localRepositoryPath": maven_settings.local_repository_path,
            "skipTests": maven
                .and_then(|maven| maven.get("skipTests"))
                .and_then(Value::as_bool)
                .unwrap_or(false),
            "mavenExecutablePath": maven_settings.maven_executable_path,
            "javaHomePath": maven_settings.java_home_path
        });
    }
    request
}

/// 是否需要在启动前做一次 Java 项目构建检查。
pub fn needs_build_check(configuration: &RunConfiguration) -> bool {
    let provider = configuration.provider.as_str();
    provider.starts_with("spring-boot")
        || provider.starts_with("java")
        || provider.starts_with("maven")
        || configuration.toolchains.contains_key("maven")
        || configuration.toolchains.contains_key("java")
        || configuration.extensions.get("maven").is_some()
        || configuration.extensions.get("java").is_some()
        || configuration.language() == super::model::RunLanguage::Java
}

fn is_maven_launcher(executable: &Path) -> bool {
    let name = executable
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    name.starts_with("mvn") || name.starts_with("mvnw")
}

/// 从已解析的可执行文件和启动计划判定本次会话的启动方式。
///
/// 只看解析后的可执行文件名和计划里的路径参数：`java` 带着 classpath 才是
/// 直启 JVM，否则只是普通命令；Maven 与 Gradle 启动器属于构建工具目标。
fn launch_mode(executable: &Path, plan: &LaunchPlan) -> RunMode {
    let name = executable
        .file_name()
        .and_then(|name| name.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    let stem = ["exe", "cmd", "bat"]
        .iter()
        .find_map(|suffix| name.strip_suffix(&format!(".{suffix}")))
        .unwrap_or(name.as_str());
    match stem {
        "java" | "javaw" => {
            if plan.classpath.is_empty()
                && plan.modulepath.is_empty()
                && !has_java_path_argument(&plan.arguments)
            {
                RunMode::Process
            } else {
                RunMode::JvmDirect
            }
        }
        "mvn" | "mvnw" | "mvnd" => RunMode::MavenGoal,
        "gradle" | "gradlew" => RunMode::BuildToolGoal,
        _ => RunMode::Process,
    }
}

/// 计划参数里是否已经带了 JVM 的路径选项。
fn has_java_path_argument(arguments: &[String]) -> bool {
    arguments.iter().any(|argument| {
        matches!(
            argument.as_str(),
            "-cp" | "-classpath" | "--class-path" | "-p" | "--module-path"
        )
    })
}

/// 把 Maven 简写目标（如 `spring-boot:run`）规约成完整插件坐标，
/// 避免多模块父工程没有配置对应 pluginGroup 时导致 NoPluginFoundForPrefixException。
fn canonicalize_maven_arguments(arguments: &mut [String]) {
    for arg in arguments.iter_mut() {
        if arg == "spring-boot:run" {
            *arg = "org.springframework.boot:spring-boot-maven-plugin:run".to_string();
        } else if arg == "quarkus:dev" {
            *arg = "io.quarkus:quarkus-maven-plugin:dev".to_string();
        } else if arg == "mn:run" {
            *arg = "io.micronaut.maven:micronaut-maven-plugin:run".to_string();
        }
    }
}

fn launch(
    client: CoreClient,
    root: PathBuf,
    configuration: RunConfiguration,
    skip_build: bool,
    sender: Sender<SessionEvent>,
) -> Result<(), String> {
    // Java / Spring Boot 配置先走 `java -cp <classpath> <MainClass>` 直启；
    // 任何一步不成立都打印原因并退回下面的构建工具目标。
    if direct::applies(&configuration) {
        match direct::start(client, &root, &configuration, skip_build, &sender) {
            Ok(()) => return Ok(()),
            Err(error) => {
                let _ = sender.send_blocking(SessionEvent::Output(format!(
                    "{}: {error}\n",
                    lithe_ui::i18n::tr("Direct JVM")
                )));
            }
        }
    }

    let request = launch_request(&root, &configuration);
    let plan = client
        .execute_raw("runConfig.createLaunchPlan", request)
        .map_err(|error| {
            format!(
                "{}: {error}",
                lithe_ui::i18n::tr("Could not start configuration")
            )
        })?;

    let launch = LaunchPlan::from_json(&plan)?;
    // 启动计划解析完成，进入配置同步（pre-launch 编译等）；失败仍由
    // SessionEvent::Failed 承载，直启回退路径不会误报准备失败。
    send_preparation_phase(&sender, PreparationPhase::Configuring);
    let module = configuration
        .extensions
        .get("maven")
        .and_then(|m| m.get("module"))
        .and_then(Value::as_str)
        .filter(|module| *module != "." && !module.is_empty());
    // 模块目录启动看不到 sibling 源码，Maven 只从本地仓库解析依赖；源码改动
    // 后不重新安装依赖模块，编译会停在“找不到符号”。先构建依赖链再启动。
    if !skip_build && needs_maven_install(&configuration.provider, module) {
        if let Some(module) = module {
            send_preparation_phase(&sender, PreparationPhase::Building);
            run_maven_install(client, &root, &configuration, module, &sender)?;
        }
    }
    let working_directory = launch_working_directory(&root, &launch.working_directory, module);
    let toolchains = ProjectToolchains::resolve(
        &root,
        &working_directory,
        &configuration.java_home_path,
        &configuration.maven_executable_path,
    );
    let executable =
        resolve_executable(&root, &working_directory, &launch.executable, &toolchains)?;
    let mut environment = launch.env.clone();
    for (key, reference) in &launch.environment {
        if let Some(value) =
            resolve_environment_reference(&root, &working_directory, reference, &toolchains)
        {
            environment.insert(key.clone(), value);
        }
    }

    // pre-launch 步骤是 Java 独立源文件的编译等准备工作；它们必须按顺序
    // 完成，失败时主进程不能启动。
    for step in &launch.pre_launch_steps {
        let step_executable =
            resolve_executable(&root, &working_directory, &step.executable, &toolchains)?;
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

    let mut arguments = merge_path_arguments(
        &launch.arguments,
        &resolve_plan_paths(&root, &launch.classpath),
        &resolve_plan_paths(&root, &launch.modulepath),
    );
    if let Some(module) = module {
        strip_reactor_selection(&mut arguments, module);
    }

    // 运行方式先于输出到达，界面在第一条日志之前就能标出这次走的是哪条路径。
    let _ = sender.send_blocking(SessionEvent::LaunchMode(launch_mode(&executable, &launch)));

    let command_line = format!(
        "$ {} {}\n\n",
        executable
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("java"),
        arguments.join(" ")
    );
    let _ = sender.send_blocking(SessionEvent::Output(command_line));

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
    let tree = Arc::new(ProcessTree::adopt(&mut child).map_err(|error| {
        let _ = child.kill();
        format!(
            "{}: {}: {error}",
            lithe_ui::i18n::tr("Could not start configuration"),
            executable.display()
        )
    })?);
    let stop_flag = register_stop_flag(&tree, &sender);
    let _ = sender.send_blocking(SessionEvent::Started(Arc::clone(&tree)));

    if let Some(stdout) = child.stdout.take() {
        spawn_reader(stdout, sender.clone());
    }
    if let Some(stderr) = child.stderr.take() {
        spawn_reader(stderr, sender.clone());
    }
    send_preparation_ready(&sender);
    spawn_exit_waiter(child, sender, stop_flag, None);
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

/// 已经登记的会话停止状态；键是视图持有的 `Arc<ProcessTree>` 地址。
///
/// `stopped` 把「用户主动停止」传给退出等待线程，退出 System 行据此与
/// 自然退出区分措辞；`sender` 让强杀发生后能向输出流追加强制停止系统行。
struct StopRegistration {
    stopped: Arc<AtomicBool>,
    sender: Sender<SessionEvent>,
}

static STOP_REGISTRATIONS: LazyLock<Mutex<HashMap<usize, StopRegistration>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

/// 会话启动后登记停止状态，并返回交给退出等待线程的停止标记。
fn register_stop_flag(tree: &Arc<ProcessTree>, sender: &Sender<SessionEvent>) -> Arc<AtomicBool> {
    let stopped = Arc::new(AtomicBool::new(false));
    STOP_REGISTRATIONS
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .insert(
            Arc::as_ptr(tree) as usize,
            StopRegistration {
                stopped: Arc::clone(&stopped),
                sender: sender.clone(),
            },
        );
    stopped
}

/// 标记一次用户主动停止，并返回会话输出发送端供强杀提示使用。
fn mark_user_stop(tree: &Arc<ProcessTree>) -> Option<Sender<SessionEvent>> {
    let registrations = STOP_REGISTRATIONS
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let registration = registrations.get(&(Arc::as_ptr(tree) as usize))?;
    registration.stopped.store(true, Ordering::SeqCst);
    Some(registration.sender.clone())
}

/// 会话退出后注销停止状态，避免进程树地址被复用后误判新会话。
fn forget_stop_flag(stop_flag: &Arc<AtomicBool>) {
    STOP_REGISTRATIONS
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner())
        .retain(|_, registration| !Arc::ptr_eq(&registration.stopped, stop_flag));
}

fn spawn_exit_waiter(
    mut child: Child,
    sender: Sender<SessionEvent>,
    stop_flag: Arc<AtomicBool>,
    temporary: Option<LaunchArgumentFile>,
) {
    thread::spawn(move || {
        let code = child.wait().ok().and_then(|status| status.code());
        // 缩短参数文件在进程结束后才清理；启动失败时它随调用栈就地删除。
        drop(temporary);
        let stopped = stop_flag.load(Ordering::SeqCst);
        forget_stop_flag(&stop_flag);
        // 退出行先于 Exited 事件进入输出流；渲染层把它作为 System 行显示。
        let _ = sender.send_blocking(SessionEvent::Output(exit_system_line(code, stopped)));
        let _ = sender.send_blocking(SessionEvent::Exited(code));
    });
}

/// 进程退出后的 System 行文本。
///
/// 措辞对齐 IDEA：自然退出是 `Process finished with exit code N`；用户主动
/// 停止时附加 stopped 标记，退出码拿不到时如实说明。
pub fn exit_system_line(code: Option<i32>, stopped: bool) -> String {
    let description = match (code, stopped) {
        (Some(code), false) => format!("Process finished with exit code {code}"),
        (Some(code), true) => format!("Process finished with exit code {code} (stopped)"),
        (None, false) => "Process finished with an unknown exit code".to_string(),
        (None, true) => "Process stopped before it reported an exit code".to_string(),
    };
    format!("{description}\n")
}

/// 一次启动自有的缩短参数文件（argfile 或 pathing JAR）。
///
/// Drop 时删除文件：宿主把它移交退出等待线程，进程结束后才清理；
/// 写入失败或启动失败时在当次调用栈里就地删除。
pub(super) struct LaunchArgumentFile(pub(crate) PathBuf);

impl LaunchArgumentFile {
    /// 缩短参数文件的路径，供诊断与测试使用。
    pub(crate) fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for LaunchArgumentFile {
    fn drop(&mut self) {
        if let Err(error) = std::fs::remove_file(&self.0) {
            if error.kind() != std::io::ErrorKind::NotFound {
                eprintln!("Could not remove Java launch argument file: {error}");
            }
        }
    }
}

/// 拉起主进程并把 stdout / stderr 转发到事件通道。
///
/// JVM 直启和 Core 给出的启动计划共用这段生命周期：`ProcessTree` 负责整棵树
/// 的回收，读取线程只往通道里送文本，视图线程不碰 IO。
pub(super) fn spawn_session(
    executable: &Path,
    arguments: &[String],
    working_directory: &Path,
    environment: &BTreeMap<String, String>,
    sender: &Sender<SessionEvent>,
    temporary: Option<LaunchArgumentFile>,
) -> Result<(), String> {
    let mut command = command_for(executable, arguments);
    command
        .current_dir(working_directory)
        .envs(environment)
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
    let tree = Arc::new(ProcessTree::adopt(&mut child).map_err(|error| {
        let _ = child.kill();
        format!(
            "{}: {}: {error}",
            lithe_ui::i18n::tr("Could not start configuration"),
            executable.display()
        )
    })?);
    let stop_flag = register_stop_flag(&tree, sender);
    let _ = sender.send_blocking(SessionEvent::Started(Arc::clone(&tree)));

    if let Some(stdout) = child.stdout.take() {
        spawn_reader(stdout, sender.clone());
    }
    if let Some(stderr) = child.stderr.take() {
        spawn_reader(stderr, sender.clone());
    }
    spawn_exit_waiter(child, sender.clone(), stop_flag, temporary);
    Ok(())
}

/// 停止整棵进程树。调用方应放到后台线程，避免等待内核回收时卡住界面。
///
/// 第一次停止先等宽限期让进程自行退出（Unix 先发 SIGINT），超时才强杀；
/// 对同一棵进程树再次调用跳过宽限期立即强杀，对应界面的连续停止。
/// 强杀发生后向输出流追加一条强制停止系统行，视图无需改动即可呈现。
pub fn stop(tree: Arc<ProcessTree>) -> Result<(), String> {
    let sender = mark_user_stop(&tree);
    let forced = tree
        .terminate_gracefully(Duration::from_secs(10))
        .map_err(|error| format!("{}: {error}", lithe_ui::i18n::tr("Could not stop run")))?;
    if forced {
        if let Some(sender) = sender {
            let _ = sender.send_blocking(SessionEvent::Output(force_stop_system_line()));
        }
    }
    Ok(())
}

/// 强制停止后的系统行文本；与退出 System 行同一机制进入输出流。
fn force_stop_system_line() -> String {
    "Process was force-stopped after the grace period\n".to_string()
}

// ---------------------------------------------------------------------------
// 准备进度事件
// ---------------------------------------------------------------------------

/// 推进准备状态条的阶段；导入相关字段在 GPUI 侧没有数据来源，保持 None。
pub(super) fn send_preparation_phase(sender: &Sender<SessionEvent>, phase: PreparationPhase) {
    let _ = sender.send_blocking(SessionEvent::Preparation(PreparationEvent::Phase {
        phase,
        import_percent: None,
        current_project: None,
        download_artifact: None,
    }));
}

/// 主进程已经拉起，准备阶段完成。
pub(super) fn send_preparation_ready(sender: &Sender<SessionEvent>) {
    let _ = sender.send_blocking(SessionEvent::Preparation(PreparationEvent::Ready));
}

/// 从 Maven 批处理输出里识别正在下载的构件并推进准备状态条。
///
/// `-B` 模式下每条 `Downloading from <仓库>: <URL>`（旧版为 `Downloading: <URL>`）
/// 对应一个构件；连续重复的构件只发一次事件。
pub(super) fn emit_downloads(text: &str, sender: &Sender<SessionEvent>) {
    let mut last = String::new();
    for line in text.lines() {
        let Some(artifact) = maven_download_artifact(line) else {
            continue;
        };
        if artifact == last {
            continue;
        }
        last = artifact.clone();
        let _ = sender.send_blocking(SessionEvent::Preparation(PreparationEvent::Phase {
            phase: PreparationPhase::Building,
            import_percent: None,
            current_project: None,
            download_artifact: Some(artifact),
        }));
    }
}

/// 从一行 Maven 下载日志提取构件名；非下载行返回 None。
fn maven_download_artifact(line: &str) -> Option<String> {
    let url = line
        .strip_prefix("Downloading from ")
        .and_then(|rest| rest.split_once(": "))
        .map(|(_, url)| url)
        .or_else(|| line.strip_prefix("Downloading: "))?;
    let artifact = url.rsplit('/').next()?;
    (!artifact.is_empty()).then(|| artifact.to_string())
}

// ---------------------------------------------------------------------------
// 启动计划
// ---------------------------------------------------------------------------

mod launch_plan;
mod toolchain_probe;

use launch_plan::{EnvironmentRef, ExecutableRef, LaunchPlan, LaunchStep, resolve_plan_paths};
pub(crate) use toolchain_probe::toolchain_candidates;

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

/// 是否需要在模块目录启动前安装 Maven 依赖链。
///
/// 只有 Maven 框架服务和 Maven 模块任务在子模块目录运行时才需要：其他配置
/// 要么没有模块选择，要么由 Java 语言服务直接给出运行路径。
fn needs_maven_install(provider: &str, module: Option<&str>) -> bool {
    module.is_some() && (provider.ends_with(".maven") || provider == "maven.module")
}

/// 在 reactor 根安装当前模块及其依赖链。
///
/// 参数由 Core 的 `maven.launchPlan` 生成，因此 profiles、settings、本地仓库
/// 与 `-pl`/`-am` 的选择规则和 Maven 工具窗一致，宿主不自行拼装。
fn run_maven_install(
    client: CoreClient,
    root: &Path,
    configuration: &RunConfiguration,
    module: &str,
    sender: &Sender<SessionEvent>,
) -> Result<(), String> {
    let context = maven_install_context(root, configuration);
    let launch = crate::maven::plan_goal(
        client,
        root,
        &context,
        Some(module),
        &["install".to_string()],
    )?;
    let command_line = format!(
        "$ {} {}\n\n",
        launch
            .executable
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("mvn"),
        launch.display_arguments()
    );
    let _ = sender.send_blocking(SessionEvent::Output(command_line));

    let mut command = command_for(&launch.executable, &launch.arguments);
    command
        .current_dir(&launch.working_directory)
        .envs(&launch.environment)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let output = command.output().map_err(|error| {
        format!(
            "{}: {}: {error}",
            lithe_ui::i18n::tr("Could not start configuration"),
            launch.executable.display()
        )
    })?;
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    if !text.is_empty() {
        let _ = sender.send_blocking(SessionEvent::Output(text.clone()));
    }
    emit_downloads(&text, sender);
    if !output.status.success() {
        return Err(format!(
            "{} ({})",
            lithe_ui::i18n::tr("Could not start configuration"),
            output.status
        ));
    }
    Ok(())
}

/// 构造依赖构建的 Maven 上下文；安装依赖时跳过测试阶段。
pub(super) fn maven_install_context(
    root: &Path,
    configuration: &RunConfiguration,
) -> crate::maven::LaunchContext {
    let maven = configuration.extensions.get("maven");
    let reactor_path = maven
        .and_then(|maven| maven.get("reactorPath"))
        .and_then(Value::as_str)
        .unwrap_or(".");
    let profiles = maven
        .and_then(|maven| maven.get("profiles"))
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_str)
                .map(str::to_string)
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    let settings = crate::maven::configuration::load_local(root, reactor_path);
    crate::maven::LaunchContext {
        reactor_path: reactor_path.to_string(),
        profiles,
        settings_path: settings.settings_path,
        local_repository_path: settings.local_repository_path,
        skip_tests: true,
        maven_executable_path: settings.maven_executable_path,
        java_home_path: settings.java_home_path,
    }
}

/// 启动进程的工作目录。
///
/// Maven 的插件前缀和插件版本由当前项目的 effective POM 解析。多模块项目里
/// 聚合父 POM 往往只声明 `<pluginManagement>`，模块自己才在 `<build><plugins>`
/// 声明 `spring-boot-maven-plugin` 等框架插件；只有在模块目录启动，Maven 才能
/// 解析出正确的插件，并从模块 POM 取到版本。`-pl`/`-am` 只相对于 reactor 根，
/// 模块目录启动时由 [`strip_reactor_selection`] 移除。
fn launch_working_directory(
    root: &Path,
    plan_working_directory: &str,
    module: Option<&str>,
) -> PathBuf {
    match module {
        Some(module) => root.join(module),
        None => resolve_working_directory(root, plan_working_directory),
    }
}

/// 移除只在 reactor 根有效的模块选择参数。
///
/// 工作目录已经切到 `<module>` 后，Maven 的 reactor 只包含该模块本身（相对路径
/// 为 `.`）；再传 `-pl <module>` 会让 Maven 在 reactor 中查找一个不存在的路径并
/// 以 `Could not find the selected project in the reactor` 失败，`-am` 也随之失去
/// 意义。其他参数（profiles、settings、目标）原样保留。
fn strip_reactor_selection(arguments: &mut Vec<String>, module: &str) {
    let Some(index) = arguments
        .windows(2)
        .position(|pair| pair[0] == "-pl" && pair[1] == module)
    else {
        return;
    };
    arguments.drain(index..index + 2);
    if arguments.get(index).is_some_and(|value| value == "-am") {
        arguments.remove(index);
    }
}

/// 一次启动实际使用的项目工具链。
///
/// 这里必须和设置页一样走项目 requirements 的自动选择，而不是直接读
/// `JAVA_HOME`：用户的 `JAVA_HOME` 可能仍是 JDK 8，而 Spring Boot 3 等项目
/// 需要 17+；Tauri 也是先解析再启动。
pub(super) struct ProjectToolchains {
    java_home: Option<PathBuf>,
    maven_executable: Option<PathBuf>,
}

impl ProjectToolchains {
    pub(super) fn resolve(
        root: &Path,
        working_directory: &Path,
        java_home_path: &str,
        maven_executable_path: &str,
    ) -> Self {
        Self {
            java_home: toolchain::resolve_launch_java_home(root, java_home_path),
            maven_executable: toolchain::resolve_launch_maven_executable(
                root,
                working_directory,
                maven_executable_path,
            ),
        }
    }
}

fn resolve_environment_reference(
    root: &Path,
    working_directory: &Path,
    reference: &EnvironmentRef,
    toolchains: &ProjectToolchains,
) -> Option<String> {
    match reference {
        EnvironmentRef::Literal(value) => Some(value.clone()),
        EnvironmentRef::ToolchainHome(toolchain_name) => {
            if toolchain_name == "project-jdk" {
                // Tauri 发布的是 `resolve_java_home` 选出的 JDK home；这里同样
                // 不再回退到原始 JAVA_HOME，否则旧 JDK 会覆盖刚选出的新版本。
                if let Some(home) = &toolchains.java_home {
                    return Some(home.to_string_lossy().into_owned());
                }
                let executable = resolve_toolchain_with(
                    root,
                    working_directory,
                    "project-jdk",
                    None,
                    toolchains,
                )
                .ok()?;
                let home = executable.parent().and_then(Path::parent)?;
                if home.join("bin").join(jdk_tool_name("javac")).is_file() {
                    return Some(home.to_string_lossy().into_owned());
                }
                return None;
            }
            let executable =
                resolve_toolchain_with(root, working_directory, toolchain_name, None, toolchains)
                    .ok()?;
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
    toolchains: &ProjectToolchains,
) -> Result<PathBuf, String> {
    match executable {
        ExecutableRef::Command(command) => resolve_command(root, command),
        ExecutableRef::Toolchain { name, tool } => {
            resolve_toolchain_with(root, working_directory, name, tool.as_deref(), toolchains)
        }
    }
}

/// 解析一个工具链的可执行文件路径。
///
/// `project-maven` 的解析顺序（反应堆目录 / 工作区根的 wrapper 优先，再退回
/// `PATH` 上的 `mvn`）同时被 Run 面板和 Maven 工具窗使用，因此放在这里共用，
/// 避免两个入口解析出不同的 Maven。
pub(crate) fn resolve_toolchain(
    root: &Path,
    working_directory: &Path,
    toolchain: &str,
    tool: Option<&str>,
) -> Result<PathBuf, String> {
    let resolved = match toolchain {
        "project-jdk" => ProjectToolchains {
            java_home: toolchain::resolve_launch_java_home(root, ""),
            maven_executable: None,
        },
        "project-maven" => ProjectToolchains {
            java_home: None,
            maven_executable: toolchain::resolve_launch_maven_executable(
                root,
                working_directory,
                "",
            ),
        },
        _ => return resolve_toolchain_fallback(root, working_directory, toolchain, tool),
    };
    resolve_toolchain_with(root, working_directory, toolchain, tool, &resolved)
}

/// 先使用已经解析好的项目 JDK / Maven，再退回环境变量和 PATH。
pub(super) fn resolve_toolchain_with(
    root: &Path,
    working_directory: &Path,
    toolchain: &str,
    tool: Option<&str>,
    resolved: &ProjectToolchains,
) -> Result<PathBuf, String> {
    match toolchain {
        "project-jdk" => {
            let tool = tool.unwrap_or("java");
            let executable_name = jdk_tool_name(if tool.is_empty() { "java" } else { tool });
            if let Some(home) = &resolved.java_home {
                let candidate = home.join("bin").join(&executable_name);
                if candidate.is_file() {
                    return Ok(candidate);
                }
            }
            resolve_toolchain_fallback(root, working_directory, toolchain, Some(tool))
        }
        "project-maven" => {
            if let Some(executable) = &resolved.maven_executable {
                if executable.is_file() {
                    return Ok(executable.clone());
                }
            }
            resolve_toolchain_fallback(root, working_directory, toolchain, tool)
        }
        _ => resolve_toolchain_fallback(root, working_directory, toolchain, tool),
    }
}

fn resolve_toolchain_fallback(
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

/// 构造子进程命令。
///
/// Windows 上 `mvnw.cmd` / `mvn.cmd` 必须经 `cmd /c` 启动，`CreateProcess`
/// 会拒绝批处理文件。
pub(crate) fn command_for(executable: &Path, arguments: &[String]) -> Command {
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
    fn installs_maven_dependencies_only_for_module_services() {
        assert!(needs_maven_install(
            "spring-boot.maven",
            Some("services/api")
        ));
        assert!(needs_maven_install("quarkus.maven", Some("services/api")));
        assert!(needs_maven_install("maven.module", Some("services/api")));
        assert!(!needs_maven_install("spring-boot.maven", None));
        assert!(!needs_maven_install(
            "java.current-file",
            Some("services/api")
        ));
    }

    #[test]
    fn maven_module_launches_from_the_module_directory() {
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("clock should be after epoch")
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "lithe-maven-module-{}-{unique}",
            std::process::id()
        ));
        let module = root.join("services").join("api");
        std::fs::create_dir_all(&module).expect("module directory should be created");

        // 有模块时必须在模块目录启动：框架插件由模块 POM 声明并提供版本。
        assert_eq!(
            launch_working_directory(&root, ".", Some("services/api")),
            module
        );
        // 没有模块时沿用 Core 计划的 reactor 目录。
        assert_eq!(launch_working_directory(&root, ".", None), root);
        assert_eq!(
            launch_working_directory(&root, "services", None),
            root.join("services")
        );

        let _ = std::fs::remove_dir_all(&root);
    }

    #[test]
    fn strips_reactor_selection_when_running_from_a_module_directory() {
        let mut arguments = vec![
            "-B".to_string(),
            "-ntp".to_string(),
            "-pl".to_string(),
            "services/api".to_string(),
            "-am".to_string(),
            "-DskipTests".to_string(),
            "spring-boot:run".to_string(),
        ];

        strip_reactor_selection(&mut arguments, "services/api");

        assert_eq!(arguments, ["-B", "-ntp", "-DskipTests", "spring-boot:run"]);
    }

    #[test]
    fn keeps_reactor_selection_for_a_different_module() {
        let mut arguments = vec![
            "-pl".to_string(),
            "services/web".to_string(),
            "-am".to_string(),
            "spring-boot:run".to_string(),
        ];
        let original = arguments.clone();

        strip_reactor_selection(&mut arguments, "services/api");

        assert_eq!(arguments, original);
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
        let receiver = start(client, root.clone(), configuration, false);

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
                Ok(SessionEvent::LaunchMode(_)) | Ok(SessionEvent::Preparation(_)) => {}
                Err(_) => break,
            }
        }
        let _ = std::fs::remove_dir_all(&root);
        assert!(output.contains("lithe-run-ok"), "output was: {output}");
        assert!(output.contains("Process finished with exit code 0"));
        assert_eq!(exit_code, Some(0));
        assert!(started.elapsed() < Duration::from_secs(10));
    }

    #[test]
    fn exit_system_line_distinguishes_user_stops_from_natural_exits() {
        assert_eq!(
            exit_system_line(Some(0), false),
            "Process finished with exit code 0\n"
        );
        assert_eq!(
            exit_system_line(Some(1), false),
            "Process finished with exit code 1\n"
        );
        assert_eq!(
            exit_system_line(Some(143), true),
            "Process finished with exit code 143 (stopped)\n"
        );
        assert_eq!(
            exit_system_line(None, false),
            "Process finished with an unknown exit code\n"
        );
        assert_eq!(
            exit_system_line(None, true),
            "Process stopped before it reported an exit code\n"
        );
        assert_eq!(
            force_stop_system_line(),
            "Process was force-stopped after the grace period\n"
        );
    }

    #[test]
    fn maven_download_lines_reveal_the_artifact() {
        assert_eq!(
            maven_download_artifact(
                "Downloading from central: https://repo.maven.apache.org/maven2/org/springframework/spring-core/6.1.1/spring-core-6.1.1.jar"
            ),
            Some("spring-core-6.1.1.jar".to_string())
        );
        assert_eq!(
            maven_download_artifact("Downloading: https://repo.example.org/a/b/c-lib-1.0.jar"),
            Some("c-lib-1.0.jar".to_string())
        );
        assert_eq!(
            maven_download_artifact(
                "Downloaded from central: https://repo.maven.apache.org/maven2/x.jar"
            ),
            None
        );
        assert_eq!(
            maven_download_artifact("[INFO] Building tiku-backend 1.0.0"),
            None
        );
        assert_eq!(
            maven_download_artifact(
                "Downloading from central: https://repo.maven.apache.org/maven2/"
            ),
            None
        );
    }

    #[test]
    fn download_events_cover_each_artifact_once() {
        let (sender, receiver) = unbounded();
        let text = "\
[INFO] Scanning for projects...\n\
Downloading from central: https://repo.maven.apache.org/maven2/org/a/a-1.0.jar\n\
Progress (1): 4.1/5.6 kB\n\
Downloaded from central: https://repo.maven.apache.org/maven2/org/a/a-1.0.jar\n\
Downloading from central: https://repo.maven.apache.org/maven2/org/a/a-1.0.jar\n\
Downloading from central: https://repo.maven.apache.org/maven2/org/b/b-2.0.pom\n";
        emit_downloads(text, &sender);
        let mut artifacts = Vec::new();
        while let Ok(SessionEvent::Preparation(PreparationEvent::Phase {
            phase,
            download_artifact,
            ..
        })) = receiver.try_recv()
        {
            assert_eq!(phase, PreparationPhase::Building);
            artifacts.push(download_artifact);
        }
        assert_eq!(
            artifacts,
            [Some("a-1.0.jar".to_string()), Some("b-2.0.pom".to_string())]
        );
    }

    /// 用户点停止后，退出 System 行必须带 stopped 措辞，与自然退出区分。
    #[test]
    fn a_user_stop_reports_a_stopped_exit_line() {
        let unique = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .expect("clock should be after epoch")
            .as_nanos();
        let root =
            std::env::temp_dir().join(format!("lithe-run-stop-{}-{unique}", std::process::id()));
        std::fs::create_dir_all(&root).expect("temp project should be created");
        #[cfg(windows)]
        let procfile = "web: cmd /c ping -n 15 127.0.0.1\n";
        #[cfg(not(windows))]
        let procfile = "web: sleep 15\n";
        std::fs::write(root.join("Procfile"), procfile).expect("Procfile should be written");

        let client = CoreClient::new();
        let loaded =
            super::super::config::load_configurations(&client, &root).expect("config should load");
        let configuration = loaded
            .configurations
            .into_iter()
            .find(|configuration| configuration.provider == "procfile.process")
            .expect("Procfile configuration should exist");
        let receiver = start(client, root.clone(), configuration, false);

        let watchdog = receiver.clone();
        let started = Instant::now();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_secs(15));
            watchdog.close();
        });

        let mut output = String::new();
        let mut exit_code = None;
        let mut stopped_tree = None;
        // 必须在测试期间保留进程树；Job Object 在最后一个 Arc 释放时会杀死
        // 子进程，与真实视图的 SessionState 生命周期一致。
        while started.elapsed() < Duration::from_secs(15) {
            match receiver.recv_blocking() {
                Ok(SessionEvent::Output(text)) => output.push_str(&text),
                Ok(SessionEvent::Started(tree)) => {
                    // 连续两次停止覆盖「第一次等待、第二次强杀」的语义。
                    let _ = stop(Arc::clone(&tree));
                    let _ = stop(Arc::clone(&tree));
                    stopped_tree = Some(tree);
                }
                Ok(SessionEvent::Exited(code)) => {
                    exit_code = Some(code);
                    break;
                }
                Ok(SessionEvent::Failed(message)) => panic!("run failed: {message}"),
                Ok(SessionEvent::LaunchMode(_)) | Ok(SessionEvent::Preparation(_)) => {}
                Err(_) => break,
            }
        }
        let _ = std::fs::remove_dir_all(&root);
        assert!(stopped_tree.is_some(), "the session should have started");
        assert!(exit_code.is_some(), "the session should have exited");
        assert!(
            output.contains("stopped"),
            "the exit line must mark a user stop, output was: {output}"
        );
        // 停止必须早于 15 秒的自然结束，证明是停止动作终结了进程。
        assert!(started.elapsed() < Duration::from_secs(15));
    }
}
