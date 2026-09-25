//! Run/Maven 进程解析与受管会话（跨平台）。
//!
//! 每个执行由一个 session/execution 身份拥有。一个后台线程顺序执行所有步骤，
//! stdout/stderr 各自有明确归属并在进程结束后 join；停止操作向独立进程组
//! 发送 TERM，超时后再 KILL，调用方通过 `ProcessHandle::join` 完成回收。
//!
//! 进程组信号是平台能力：Unix 用 `setpgid` + `kill(-pgid)` 覆盖整棵进程树，
//! Windows 没有等价的原生进程组信号，改用 `taskkill /T` 终止同一 pid 的
//! 子树。两条路径都保持“先温和、后强制、有界等待”的同一语义契约。

use std::collections::{BTreeMap, HashMap};
use std::fs;
use std::io::{BufRead, BufReader};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{mpsc, Arc, Condvar, Mutex};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use serde_json::Value;

use super::config::{
    merge_java_paths, LaunchExecutable, LaunchPlan, PreLaunchStep, ToolchainPaths,
};

const PROCESS_STOP_TIMEOUT: Duration = Duration::from_secs(2);
const PROCESS_POLL_INTERVAL: Duration = Duration::from_millis(20);

/// 平台无关的终止信号强度，替代裸 `SIGTERM`/`SIGKILL` 常量。
///
/// Unix 映射到对应信号；Windows 没有 SIGTERM/SIGKILL 区分，`Terminate`
/// 与 `Kill` 都落到进程树强制终止（Windows 无法只靠软件手段做到“可捕获的
/// 温和退出”，因此 `Terminate` 仅用于先给目标一次自行退出的机会）。
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ProcessSignal {
    /// 请求目标自行退出（Unix `SIGTERM`）。
    Terminate,
    /// 强制终止目标（Unix `SIGKILL`）。
    Kill,
}

/// 一个已经解析到当前平台路径和环境的命令。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProcessCommand {
    pub program: String,
    pub arguments: Vec<String>,
    pub working_directory: String,
    pub environment: BTreeMap<String, String>,
}

impl ProcessCommand {
    fn label(&self) -> String {
        format!("{} {}", self.program, self.arguments.join(" "))
    }
}

/// 一个由同一 session 顺序执行的步骤。
#[derive(Debug, Clone)]
pub struct ProcessStep {
    pub label: String,
    pub command: ProcessCommand,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OutputStream {
    Stdout,
    Stderr,
}

#[derive(Debug)]
pub enum ProcessEvent {
    Started {
        index: usize,
        label: String,
    },
    Output {
        stream: OutputStream,
        text: String,
    },
    Finished {
        exit_code: Option<i32>,
        cancelled: bool,
        error: Option<String>,
    },
}

#[derive(Debug)]
struct Control {
    stop_requested: AtomicBool,
    pgid: Mutex<Option<i32>>,
    finished: Mutex<bool>,
    finished_signal: Condvar,
}

impl Control {
    fn new() -> Self {
        Self {
            stop_requested: AtomicBool::new(false),
            pgid: Mutex::new(None),
            finished: Mutex::new(false),
            finished_signal: Condvar::new(),
        }
    }

    fn request_stop(&self) {
        self.stop_requested.store(true, Ordering::Release);
    }

    fn is_stop_requested(&self) -> bool {
        self.stop_requested.load(Ordering::Acquire)
    }

    fn set_pgid(&self, pgid: i32) {
        if let Ok(mut slot) = self.pgid.lock() {
            *slot = Some(pgid);
        }
    }

    fn pgid(&self) -> Option<i32> {
        self.pgid.lock().ok().and_then(|value| *value)
    }

    fn mark_finished(&self) {
        if let Ok(mut pgid) = self.pgid.lock() {
            *pgid = None;
        }
        if let Ok(mut finished) = self.finished.lock() {
            *finished = true;
        }
        self.finished_signal.notify_all();
    }

    fn wait_finished(&self, timeout: Duration) -> bool {
        let Ok(finished) = self.finished.lock() else {
            return true;
        };
        let (finished, timeout_result) = self
            .finished_signal
            .wait_timeout_while(finished, timeout, |finished| !*finished)
            .unwrap();
        *finished || timeout_result.timed_out()
    }
}

struct SessionEntry {
    execution_id: String,
    control: Arc<Control>,
    join: Arc<Mutex<Option<JoinHandle<()>>>>,
}

#[derive(Clone)]
struct ProcessManagerInner {
    sessions: Arc<Mutex<HashMap<String, SessionEntry>>>,
}

/// 管理所有 Linux Run/Maven session；同一个 session 启动新执行前先停止旧执行。
#[derive(Clone)]
pub struct ProcessManager {
    inner: ProcessManagerInner,
}

/// 一个可停止、可等待回收的执行句柄。
pub struct ProcessHandle {
    manager: ProcessManager,
    session_id: String,
    execution_id: String,
    control: Arc<Control>,
    join: Arc<Mutex<Option<JoinHandle<()>>>>,
}

impl ProcessManager {
    pub fn new() -> Self {
        Self {
            inner: ProcessManagerInner {
                sessions: Arc::new(Mutex::new(HashMap::new())),
            },
        }
    }

    /// 启动一个 session；步骤失败会由同一个 worker 停止后续步骤。
    pub fn start(
        &self,
        session_id: &str,
        execution_id: &str,
        steps: Vec<ProcessStep>,
        sender: mpsc::Sender<ProcessEvent>,
    ) -> Result<ProcessHandle, String> {
        if session_id.trim().is_empty() || execution_id.trim().is_empty() {
            return Err("A process session and execution id are required".to_string());
        }
        self.stop(session_id, None).ok();

        let control = Arc::new(Control::new());
        let join = Arc::new(Mutex::new(None));
        {
            let mut sessions = self
                .inner
                .sessions
                .lock()
                .map_err(|_| "Process session state is unavailable".to_string())?;
            sessions.insert(
                session_id.to_string(),
                SessionEntry {
                    execution_id: execution_id.to_string(),
                    control: control.clone(),
                    join: join.clone(),
                },
            );
        }

        let worker_control = control.clone();
        let worker = thread::Builder::new()
            .name("lithe-run-process".to_string())
            .spawn(move || {
                let outcome = execute_steps(&steps, &sender, &worker_control);
                if let Err(error) = outcome {
                    let _ = sender.send(ProcessEvent::Finished {
                        exit_code: Some(1),
                        cancelled: false,
                        error: Some(error),
                    });
                }
                worker_control.mark_finished();
                // The entry remains until the owner calls join/reap, so stop can
                // still observe the exact execution while its final event drains.
            })
            .map_err(|error| {
                let mut sessions = self.inner.sessions.lock().ok();
                if let Some(sessions) = sessions.as_mut() {
                    sessions.remove(session_id);
                }
                format!("Could not start process worker: {error}")
            })?;
        if let Ok(mut slot) = join.lock() {
            *slot = Some(worker);
        }
        Ok(ProcessHandle {
            manager: self.clone(),
            session_id: session_id.to_string(),
            execution_id: execution_id.to_string(),
            control,
            join,
        })
    }

    /// 发出停止信号后立即返回；worker 负责有界等待和 join。
    pub fn request_stop(&self, session_id: &str, execution_id: Option<&str>) -> Result<(), String> {
        let control = {
            let sessions = self
                .inner
                .sessions
                .lock()
                .map_err(|_| "Process session state is unavailable".to_string())?;
            sessions
                .get(session_id)
                .filter(|entry| execution_id.is_none_or(|id| entry.execution_id == id))
                .map(|entry| entry.control.clone())
        };
        if let Some(control) = control {
            control.request_stop();
            send_signal(control.pgid(), ProcessSignal::Terminate);
        }
        Ok(())
    }

    /// 停止当前 session；传入 execution id 时只停止匹配的执行。
    pub fn stop(&self, session_id: &str, execution_id: Option<&str>) -> Result<(), String> {
        let entry = {
            let sessions = self
                .inner
                .sessions
                .lock()
                .map_err(|_| "Process session state is unavailable".to_string())?;
            sessions
                .get(session_id)
                .filter(|entry| execution_id.is_none_or(|id| entry.execution_id == id))
                .map(|entry| {
                    (
                        entry.execution_id.clone(),
                        entry.control.clone(),
                        entry.join.clone(),
                    )
                })
        };
        let Some((owned_execution, control, join)) = entry else {
            return Ok(());
        };
        stop_control(&control)?;
        if let Ok(mut slot) = join.lock() {
            if let Some(worker) = slot.take() {
                let _ = worker.join();
            }
        }
        if let Ok(mut sessions) = self.inner.sessions.lock() {
            if sessions
                .get(session_id)
                .is_some_and(|entry| entry.execution_id == owned_execution)
            {
                sessions.remove(session_id);
            }
        }
        Ok(())
    }

    fn reap(&self, session_id: &str, execution_id: &str) {
        let should_remove = {
            let Ok(sessions) = self.inner.sessions.lock() else {
                return;
            };
            sessions
                .get(session_id)
                .is_some_and(|entry| entry.execution_id == execution_id)
        };
        if should_remove {
            if let Ok(mut sessions) = self.inner.sessions.lock() {
                sessions.remove(session_id);
            }
        }
    }
}

impl Default for ProcessManager {
    fn default() -> Self {
        Self::new()
    }
}

impl ProcessHandle {
    pub fn stop(&self) -> Result<(), String> {
        self.control.request_stop();
        send_signal(self.control.pgid(), ProcessSignal::Terminate);
        if !self.control.wait_finished(PROCESS_STOP_TIMEOUT) {
            send_signal(self.control.pgid(), ProcessSignal::Kill);
            if !self.control.wait_finished(PROCESS_STOP_TIMEOUT) {
                return Err("Process did not exit within the stop deadline".to_string());
            }
        }
        self.join()
    }

    /// 等待 worker 完成并移除 session 条目；必须在消费 Finished 事件后调用。
    pub fn join(&self) -> Result<(), String> {
        if !self.control.wait_finished(PROCESS_STOP_TIMEOUT) {
            return Err("Process worker did not finish within the join deadline".to_string());
        }
        if let Ok(mut slot) = self.join.lock() {
            if let Some(worker) = slot.take() {
                worker
                    .join()
                    .map_err(|_| "Process worker panicked".to_string())?;
            }
        }
        self.manager.reap(&self.session_id, &self.execution_id);
        Ok(())
    }
}

impl Drop for ProcessHandle {
    fn drop(&mut self) {
        let _ = self.stop();
    }
}

impl Drop for ProcessManagerInner {
    fn drop(&mut self) {
        let sessions = self
            .sessions
            .lock()
            .map(|mut sessions| sessions.drain().map(|(_, entry)| entry).collect::<Vec<_>>())
            .unwrap_or_default();
        for entry in sessions {
            entry.control.request_stop();
            send_signal(entry.control.pgid(), ProcessSignal::Terminate);
            let _ = entry.control.wait_finished(PROCESS_STOP_TIMEOUT);
            send_signal(entry.control.pgid(), ProcessSignal::Kill);
            if let Ok(mut slot) = entry.join.lock() {
                if let Some(worker) = slot.take() {
                    let _ = worker.join();
                }
            }
        }
    }
}

fn execute_steps(
    steps: &[ProcessStep],
    sender: &mpsc::Sender<ProcessEvent>,
    control: &Control,
) -> Result<(), String> {
    for (index, step) in steps.iter().enumerate() {
        if control.is_stop_requested() {
            let _ = sender.send(ProcessEvent::Finished {
                exit_code: None,
                cancelled: true,
                error: None,
            });
            return Ok(());
        }
        if sender
            .send(ProcessEvent::Started {
                index,
                label: step.label.clone(),
            })
            .is_err()
        {
            return Ok(());
        }
        let outcome = execute_step(&step.command, sender, control)?;
        let Some(code) = outcome else {
            let _ = sender.send(ProcessEvent::Finished {
                exit_code: None,
                cancelled: true,
                error: None,
            });
            return Ok(());
        };
        if code != 0 {
            let _ = sender.send(ProcessEvent::Finished {
                exit_code: Some(code),
                cancelled: false,
                error: None,
            });
            return Ok(());
        }
    }
    let _ = sender.send(ProcessEvent::Finished {
        exit_code: Some(0),
        cancelled: false,
        error: None,
    });
    Ok(())
}

/// Returns `Some(exit_code)` for a completed child, or `None` when stopped.
fn execute_step(
    spec: &ProcessCommand,
    sender: &mpsc::Sender<ProcessEvent>,
    control: &Control,
) -> Result<Option<i32>, String> {
    let mut command = Command::new(&spec.program);
    command
        .args(&spec.arguments)
        .current_dir(&spec.working_directory)
        .envs(&spec.environment)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    configure_process_group(&mut command);
    let mut child = command
        .spawn()
        .map_err(|error| format!("Unable to start process {}: {error}", spec.program))?;
    let pgid = child.id() as i32;
    control.set_pgid(pgid);
    let stdout = child.stdout.take();
    let stderr = child.stderr.take();
    let stdout_thread = spawn_reader(stdout, OutputStream::Stdout, sender.clone());
    let stderr_thread = spawn_reader(stderr, OutputStream::Stderr, sender.clone());

    let status = wait_for_child(&mut child, control);
    // A child can exit while a forked descendant still owns the pipe. Kill the
    // whole process group before joining readers so the reader threads cannot
    // remain blocked on inherited descriptors.
    send_signal(Some(pgid), ProcessSignal::Kill);
    if let Some(thread) = stdout_thread {
        let _ = thread.join();
    }
    if let Some(thread) = stderr_thread {
        let _ = thread.join();
    }
    if control.is_stop_requested() {
        return Ok(None);
    }
    let status = status?;
    status.code().map(Some).ok_or_else(|| {
        format!(
            "Process {} was terminated without an exit code",
            spec.program
        )
    })
}

fn spawn_reader<R>(
    reader: Option<R>,
    stream: OutputStream,
    sender: mpsc::Sender<ProcessEvent>,
) -> Option<JoinHandle<()>>
where
    R: std::io::Read + Send + 'static,
{
    let reader = reader?;
    Some(thread::spawn(move || {
        for line in BufReader::new(reader).lines() {
            let Ok(line) = line else { break };
            if sender
                .send(ProcessEvent::Output { stream, text: line })
                .is_err()
            {
                break;
            }
        }
    }))
}

fn wait_for_child(
    child: &mut Child,
    control: &Control,
) -> Result<std::process::ExitStatus, String> {
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return Ok(status),
            Ok(None) if control.is_stop_requested() => {
                send_signal(control.pgid(), ProcessSignal::Terminate);
                thread::park_timeout(PROCESS_STOP_TIMEOUT.min(Duration::from_millis(200)));
                send_signal(control.pgid(), ProcessSignal::Kill);
                return child
                    .wait()
                    .map_err(|error| format!("Waiting for process failed: {error}"));
            }
            Ok(None) => thread::park_timeout(PROCESS_POLL_INTERVAL),
            Err(error) => return Err(format!("Waiting for process failed: {error}")),
        }
    }
}

fn stop_control(control: &Control) -> Result<(), String> {
    control.request_stop();
    send_signal(control.pgid(), ProcessSignal::Terminate);
    if !control.wait_finished(PROCESS_STOP_TIMEOUT) {
        send_signal(control.pgid(), ProcessSignal::Kill);
        if !control.wait_finished(PROCESS_STOP_TIMEOUT) {
            return Err("Process did not exit within the stop deadline".to_string());
        }
    }
    Ok(())
}

/// 把子进程放进独立进程组，使停止操作能覆盖子进程派生的整棵进程树。
///
/// Unix 用 `setpgid(0, 0)`；Windows 用 `CREATE_NEW_PROCESS_GROUP`，二者都让
/// 后续终止按组/树进行，而不是只杀掉直接子进程。
fn configure_process_group(command: &mut Command) {
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt as _;
        // CREATE_NEW_PROCESS_GROUP (0x0000_0200)：让子进程成为新进程组
        // 组长，配合 `taskkill /T` 能一并清理其派生进程。
        const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
        command.creation_flags(CREATE_NEW_PROCESS_GROUP);
    }
}

/// 终止一个外部拥有的进程组并有界等待它消失，语义与 [`ProcessHandle::stop`]
/// 完全一致：先 `Terminate`，超过 `grace` 仍未退出再 `Kill`。
///
/// 集成终端的 PTY 子进程由 `portable-pty` 拥有，其 reader 线程负责最终
/// `wait()` 回收，因此这里只负责“信号 + 有界等待”，不负责 join。返回
/// `true` 表示进程组已在期限内消失（`pgid` 不可用时视为已完成）。
pub fn terminate_process_group(pgid: Option<i32>, grace: Duration) -> bool {
    let Some(pgid) = pgid.filter(|value| *value > 1) else {
        return true;
    };
    send_signal(Some(pgid), ProcessSignal::Terminate);
    if wait_for_process_group_exit(pgid, grace) {
        return true;
    }
    send_signal(Some(pgid), ProcessSignal::Kill);
    wait_for_process_group_exit(pgid, grace)
}

/// 轮询进程组是否仍存在；Unix 用 `kill(-pgid, 0)` 探测，Windows 的
/// `taskkill` 调用本身同步等待完成，直接视为已退出。
fn wait_for_process_group_exit(pgid: i32, timeout: Duration) -> bool {
    #[cfg(unix)]
    {
        let deadline = Instant::now() + timeout;
        loop {
            // 0 号信号只做存在性探测：整组都退出后返回 ESRCH。
            if unsafe { libc::kill(-pgid, 0) } != 0 {
                return true;
            }
            if Instant::now() >= deadline {
                return false;
            }
            thread::park_timeout(PROCESS_POLL_INTERVAL);
        }
    }
    #[cfg(windows)]
    {
        let _ = (pgid, timeout);
        true
    }
}

/// 向由 `pgid` 标识的进程组（Unix）或进程树（Windows）发送终止信号。
///
/// `pgid` 只在子进程存活期间有效；None 或 <= 1（pid 0/1 属于内核或 launchd/
/// init）时不做任何事，避免误伤会话或系统进程。
fn send_signal(pgid: Option<i32>, signal: ProcessSignal) {
    let Some(pgid) = pgid.filter(|value| *value > 1) else {
        return;
    };
    #[cfg(unix)]
    {
        // 负 pid 表示对整进程组发信号；这里信号值只在 Unix 意义上有区别。
        let signal_number = match signal {
            ProcessSignal::Terminate => libc::SIGTERM,
            ProcessSignal::Kill => libc::SIGKILL,
        };
        unsafe {
            libc::kill(-pgid, signal_number);
        }
    }
    #[cfg(windows)]
    {
        // Windows 无 POSIX 进程组信号，统一用 `taskkill /T` 终止该 pid 及其
        // 派生进程；“先温和后强制”的语义由调用方的有界等待轮次体现。
        // 为了避免弹出控制台窗口，隐藏子窗口并以静默方式调用。
        let _ = signal;
        use std::os::windows::process::CommandExt as _;
        use std::process::{Command as WindowsCommand, Stdio};
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        let mut killer = WindowsCommand::new("taskkill");
        killer
            .args(["/PID", &pgid.to_string(), "/T", "/F"])
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .creation_flags(CREATE_NO_WINDOW);
        let _ = killer.status();
    }
}

/// 解析 Core 计划中的主进程和每个 pre-launch 步骤。
pub fn resolve_launch(
    plan: &LaunchPlan,
    root: &str,
    toolchains: &ToolchainPaths,
) -> Result<(Vec<ProcessStep>, ProcessCommand), String> {
    let working_directory = resolve_working_directory(root, &plan.working_directory)?;
    let mut environment = base_environment();
    let java_home = configured_java_home(root, toolchains)?;
    let maven_java_home = configured_maven_java_home(root, toolchains, java_home.as_deref())?;
    apply_plan_environment(
        &mut environment,
        &plan.environment,
        java_home.as_deref(),
        maven_java_home.as_deref(),
    );
    environment.extend(plan.env.clone());
    if plan.executable.toolchain.as_deref() == Some("project-maven")
        && !plan.env.contains_key("JAVA_HOME")
    {
        if let Some(home) = maven_java_home.as_deref() {
            environment.insert("JAVA_HOME".to_string(), home.to_string());
        }
    }
    let main_executable = resolve_executable(
        root,
        &working_directory,
        &plan.executable,
        toolchains,
        java_home.as_deref(),
    )?;
    let mut main_arguments = merge_java_paths(
        &plan.arguments,
        &resolve_paths(root, &plan.classpath)?,
        "-cp",
        &["-cp", "-classpath", "--class-path"],
    );
    main_arguments = merge_java_paths(
        &main_arguments,
        &resolve_paths(root, &plan.modulepath)?,
        "--module-path",
        &["-p", "--module-path"],
    );
    prepend_executable_path(&mut environment, &main_executable);
    let main = ProcessCommand {
        program: main_executable,
        arguments: main_arguments,
        working_directory: working_directory.clone(),
        environment: environment.clone(),
    };

    let mut steps = Vec::with_capacity(plan.pre_launch_steps.len() + 1);
    for step in &plan.pre_launch_steps {
        steps.push(resolve_prelaunch_step(
            root,
            &working_directory,
            step,
            toolchains,
            java_home.as_deref(),
            &environment,
        )?);
    }
    steps.push(ProcessStep {
        label: format!("$ {}", main.label()),
        command: main.clone(),
    });
    Ok((steps, main))
}

fn resolve_prelaunch_step(
    root: &str,
    working_directory: &str,
    step: &PreLaunchStep,
    toolchains: &ToolchainPaths,
    java_home: Option<&str>,
    base_environment: &BTreeMap<String, String>,
) -> Result<ProcessStep, String> {
    let executable = resolve_executable(
        root,
        working_directory,
        &step.executable,
        toolchains,
        java_home,
    )?;
    prepare_prelaunch_output_directory(root, &step.executable, &step.arguments)?;
    let mut arguments = merge_java_paths(
        &step.arguments,
        &resolve_paths(root, &step.classpath)?,
        "-cp",
        &["-cp", "-classpath", "--class-path"],
    );
    arguments = merge_java_paths(
        &arguments,
        &resolve_paths(root, &step.modulepath)?,
        "--module-path",
        &["-p", "--module-path"],
    );
    let mut environment = base_environment.clone();
    prepend_executable_path(&mut environment, &executable);
    let command = ProcessCommand {
        program: executable.clone(),
        arguments,
        working_directory: working_directory.to_string(),
        environment,
    };
    Ok(ProcessStep {
        label: format!("$ {} {}", executable, command.arguments.join(" ")),
        command,
    })
}

fn prepare_prelaunch_output_directory(
    root: &str,
    executable: &LaunchExecutable,
    arguments: &[String],
) -> Result<(), String> {
    let is_javac = executable.tool.as_deref() == Some("javac")
        || executable.command.as_deref().is_some_and(|command| {
            Path::new(command)
                .file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name == "javac")
        });
    if !is_javac {
        return Ok(());
    }
    for (index, argument) in arguments.iter().enumerate() {
        let output = if argument == "-d" || argument == "--output-dir" {
            arguments.get(index + 1).ok_or_else(|| {
                format!("Compiler output option {argument} is missing its directory")
            })?
        } else if let Some(value) = argument.strip_prefix("--output-dir=") {
            value
        } else {
            continue;
        };
        let path = Path::new(output);
        if !path.is_absolute()
            && path
                .components()
                .any(|component| matches!(component, std::path::Component::ParentDir))
        {
            return Err("Compiler output directory must stay inside the project.".to_string());
        }
        let output_path = if path.is_absolute() {
            path.to_path_buf()
        } else {
            Path::new(root).join(path)
        };
        fs::create_dir_all(&output_path)
            .map_err(|error| format!("Unable to create compiler output directory: {error}"))?;
    }
    Ok(())
}

fn configured_java_home(root: &str, toolchains: &ToolchainPaths) -> Result<Option<String>, String> {
    if let Some(path) = non_empty(&toolchains.java_home_path) {
        let selected = absolute_path(root, &path);
        return selected_java_home(&selected)
            .map(|home| Some(home.to_string_lossy().into_owned()))
            .ok_or_else(|| {
                format!(
                    "The selected JDK does not contain bin/java: {}",
                    selected.to_string_lossy()
                )
            });
    }
    Ok(std::env::var_os("JAVA_HOME")
        .map(PathBuf::from)
        .map(|path| path.to_string_lossy().into_owned())
        .filter(|path| jdk_tool(path, "java").is_some())
        .or_else(|| {
            lookup_on_path("java")
                .and_then(|path| path.parent().and_then(Path::parent).map(Path::to_path_buf))
                .map(|path| path.to_string_lossy().into_owned())
                .filter(|path| jdk_tool(path, "java").is_some())
        }))
}

fn configured_maven_java_home(
    root: &str,
    toolchains: &ToolchainPaths,
    java_home: Option<&str>,
) -> Result<Option<String>, String> {
    if let Some(path) = non_empty(&toolchains.maven_java_home_path) {
        let selected = absolute_path(root, &path);
        return selected_java_home(&selected)
            .map(|home| Some(home.to_string_lossy().into_owned()))
            .ok_or_else(|| {
                format!(
                    "The selected Maven JDK does not contain bin/java: {}",
                    selected.to_string_lossy()
                )
            });
    }
    Ok(java_home.map(str::to_string))
}

fn selected_java_home(path: &Path) -> Option<PathBuf> {
    if jdk_tool(&path.to_string_lossy(), "java").is_some() {
        return Some(path.to_path_buf());
    }
    if path.is_file()
        && path
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name == "java")
    {
        let home = path.parent().and_then(Path::parent)?;
        if jdk_tool(&home.to_string_lossy(), "java").is_some() {
            return Some(home.to_path_buf());
        }
    }
    None
}

fn non_empty(value: &str) -> Option<String> {
    let value = value.trim();
    (!value.is_empty()).then(|| value.to_string())
}

fn resolve_executable(
    root: &str,
    working_directory: &str,
    executable: &LaunchExecutable,
    toolchains: &ToolchainPaths,
    java_home: Option<&str>,
) -> Result<String, String> {
    if let Some(toolchain) = executable.toolchain.as_deref() {
        return match toolchain {
            "project-jdk" => {
                let home = java_home.ok_or_else(|| {
                    "No Java runtime was found. Set javaHomePath or install a JDK.".to_string()
                })?;
                let tool = executable.tool.as_deref().unwrap_or("java");
                jdk_tool(&home, tool)
                    .ok_or_else(|| format!("The selected JDK does not contain bin/{tool}."))
            }
            "project-maven" => {
                resolve_maven(root, working_directory, &toolchains.maven_executable_path)
            }
            "project-node" => {
                resolve_runtime(root, "project-node", &toolchains.runtime_executable_paths)
            }
            other => resolve_runtime(root, other, &toolchains.runtime_executable_paths),
        };
    }
    let command = executable
        .command
        .as_deref()
        .ok_or_else(|| "Launch plan names neither a toolchain nor a command".to_string())?;
    resolve_command(
        root,
        working_directory,
        command,
        &toolchains.runtime_executable_paths,
    )
}

fn resolve_runtime(
    root: &str,
    id: &str,
    paths: &BTreeMap<String, String>,
) -> Result<String, String> {
    if let Some(configured) = paths.get(id).and_then(|value| non_empty(value)) {
        let path = absolute_path(root, &configured);
        if path.is_file() {
            return Ok(path.to_string_lossy().into_owned());
        }
        if id == "project-node" {
            // Node 安装目录可能是 `bin/`（Unix）或直接为根（Windows）。
            for tool in ["node", "npm"] {
                for name in binary_file_names(tool) {
                    let direct = path.join(&name);
                    if direct.is_file() {
                        return Ok(direct.to_string_lossy().into_owned());
                    }
                    let nested = path.join("bin").join(&name);
                    if nested.is_file() {
                        return Ok(nested.to_string_lossy().into_owned());
                    }
                }
            }
        }
        return Err(format!("Configured executable for {id} does not exist."));
    }
    let names = if id == "project-node" {
        binary_file_names("node")
    } else {
        vec![id.to_string()]
    };
    names
        .iter()
        .find_map(|name| lookup_on_path(name))
        .map(|path| path.to_string_lossy().into_owned())
        .ok_or_else(|| format!("No executable was found for toolchain {id}."))
}

fn resolve_command(
    root: &str,
    working_directory: &str,
    command: &str,
    runtime_paths: &BTreeMap<String, String>,
) -> Result<String, String> {
    let command_path = Path::new(command);
    if command_path.is_absolute() {
        if command_path.is_file() {
            return Ok(command_path.to_string_lossy().into_owned());
        }
        return Err(format!("Could not find executable: {command}"));
    }
    if command_path.components().count() > 1 {
        for base in [working_directory, root] {
            let candidate = Path::new(base).join(command_path);
            if candidate.is_file() {
                return Ok(candidate.to_string_lossy().into_owned());
            }
        }
    }
    let lower = command.to_ascii_lowercase();
    if matches!(
        lower.as_str(),
        "node" | "node.exe" | "npm" | "npm.cmd" | "pnpm" | "pnpm.cmd" | "yarn" | "yarn.cmd"
    ) {
        if let Some(selected) = runtime_paths
            .get("project-node")
            .and_then(|value| non_empty(value))
        {
            let directory = absolute_path(root, &selected);
            let directory = if directory.is_dir() {
                directory
            } else {
                directory
                    .parent()
                    .unwrap_or_else(|| Path::new(root))
                    .to_path_buf()
            };
            for name in binary_file_names(command) {
                let direct = directory.join(&name);
                if direct.is_file() {
                    return Ok(direct.to_string_lossy().into_owned());
                }
                let nested = directory.join("bin").join(name);
                if nested.is_file() {
                    return Ok(nested.to_string_lossy().into_owned());
                }
            }
            return Err(format!("Selected Node runtime does not contain {command}."));
        }
    }
    binary_file_names(command)
        .iter()
        .find_map(|name| lookup_on_path(name))
        .map(|path| path.to_string_lossy().into_owned())
        .ok_or_else(|| format!("Could not find executable: {command}"))
}

fn resolve_maven(root: &str, working_directory: &str, configured: &str) -> Result<String, String> {
    if let Some(configured) = non_empty(configured) {
        if !configured.contains('/') && !configured.contains('\\') {
            if let Some(path) = lookup_on_path(&configured) {
                return Ok(path.to_string_lossy().into_owned());
            }
        }
        let path = absolute_path(root, &configured);
        let mut candidates = vec![path.clone()];
        // Maven 可能是目录（`bin/mvn[.cmd]`）或直接指向可执行文件。
        for name in binary_file_names("mvn") {
            candidates.push(path.join("bin").join(&name));
            candidates.push(path.join(&name));
        }
        for candidate in candidates {
            if candidate.is_file() {
                return Ok(candidate.to_string_lossy().into_owned());
            }
        }
        return Err("Maven executable path does not exist.".to_string());
    }
    for directory in [working_directory, root] {
        // Maven Wrapper 在 Unix 是 `mvnw`，Windows 是 `mvnw.cmd`。
        let wrapper = binary_file_names("mvnw")
            .into_iter()
            .map(|name| Path::new(directory).join(name))
            .find(|candidate| candidate.is_file());
        if let Some(wrapper) = wrapper {
            if Path::new(directory)
                .join(".mvn/wrapper/maven-wrapper.properties")
                .is_file()
            {
                return Ok(wrapper.to_string_lossy().into_owned());
            }
        }
    }
    lookup_on_path("mvn")
        .map(|path| path.to_string_lossy().into_owned())
        .ok_or_else(|| {
            "No Maven executable was found. Edit this service configuration.".to_string()
        })
}

fn lookup_on_path(name: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    let candidates = binary_file_names(name);
    std::env::split_paths(&path).find_map(|directory| {
        candidates
            .iter()
            .map(|name| directory.join(name))
            .find(|candidate| candidate.is_file())
    })
}

fn jdk_tool(home: &str, tool: &str) -> Option<String> {
    let bin = Path::new(home).join("bin");
    // Windows 的 JDK 工具带 `.exe`（`bin/java.exe`），Unix 无扩展名。
    for name in binary_file_names(tool) {
        let candidate = bin.join(&name);
        if candidate.is_file() {
            return Some(candidate.to_string_lossy().into_owned());
        }
    }
    None
}

/// 在无扩展名工具名的基础上补全当前平台的可执行后缀。
///
/// Windows 上 `java`/`mvn` 实际是 `java.exe`/`mvn.cmd` 等；名字已带
/// 扩展名或非 Windows 平台时只返回原名。
fn binary_file_names(tool: &str) -> Vec<String> {
    #[cfg(windows)]
    {
        if Path::new(tool).extension().is_some() {
            return vec![tool.to_string()];
        }
        vec![
            format!("{tool}.exe"),
            format!("{tool}.cmd"),
            format!("{tool}.bat"),
            tool.to_string(),
        ]
    }
    #[cfg(not(windows))]
    {
        vec![tool.to_string()]
    }
}

fn resolve_working_directory(root: &str, relative: &str) -> Result<String, String> {
    let relative = relative.trim();
    if relative.is_empty() || relative == "." {
        return Ok(root.to_string());
    }
    let candidate = Path::new(relative);
    if candidate.is_absolute()
        || candidate
            .components()
            .any(|component| matches!(component, std::path::Component::ParentDir))
    {
        return Err("Working directory must stay inside the project.".to_string());
    }
    let path = Path::new(root).join(candidate);
    if !path.is_dir() {
        return Err(format!("Working directory does not exist: {relative}"));
    }
    Ok(path.to_string_lossy().into_owned())
}

fn resolve_paths(root: &str, values: &[String]) -> Result<Vec<String>, String> {
    values
        .iter()
        .map(|value| {
            let path = Path::new(value);
            if path.is_absolute() {
                Ok(value.clone())
            } else {
                if path
                    .components()
                    .any(|component| matches!(component, std::path::Component::ParentDir))
                {
                    return Err("Java path entries must stay inside the project.".to_string());
                }
                Ok(Path::new(root).join(path).to_string_lossy().into_owned())
            }
        })
        .collect()
}

fn apply_plan_environment(
    environment: &mut BTreeMap<String, String>,
    values: &BTreeMap<String, Value>,
    java_home: Option<&str>,
    maven_java_home: Option<&str>,
) {
    for (key, value) in values {
        let resolved = match value {
            Value::String(value) => Some(value.clone()),
            Value::Object(object) => {
                let toolchain = object.get("toolchain").and_then(Value::as_str);
                let property = object
                    .get("property")
                    .and_then(Value::as_str)
                    .unwrap_or("home");
                if property != "home" {
                    None
                } else {
                    match toolchain {
                        Some("project-maven") => maven_java_home.map(str::to_string),
                        _ => java_home.map(str::to_string),
                    }
                }
            }
            _ => None,
        };
        if let Some(value) = resolved {
            environment.insert(key.clone(), value);
        }
    }
    if let Some(home) = java_home {
        environment.insert("JAVA_HOME".to_string(), home.to_string());
    }
}

fn base_environment() -> BTreeMap<String, String> {
    std::env::vars().collect()
}

fn prepend_executable_path(environment: &mut BTreeMap<String, String>, executable: &str) {
    let Some(parent) = Path::new(executable).parent() else {
        return;
    };
    let mut directories = vec![parent.to_path_buf()];
    if let Some(path) = environment
        .get("PATH")
        .map(String::as_str)
        .or_else(|| environment.get("Path").map(String::as_str))
    {
        directories.extend(std::env::split_paths(path));
    }
    directories.dedup();
    if let Ok(path) = std::env::join_paths(directories) {
        environment.insert("PATH".to_string(), path.to_string_lossy().into_owned());
    }
}

fn absolute_path(root: &str, value: &str) -> PathBuf {
    let path = Path::new(value);
    if path.is_absolute() {
        path.to_path_buf()
    } else {
        Path::new(root).join(path)
    }
}

// 这些测试用 `/bin/sh` 驱动真实子进程并校验 Unix 进程组信号与 `bin/` 路径
// 语义；Windows 的进程树终止与可执行文件命名不同，因此仅在 Unix 上运行。
#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::fs;
    use std::sync::atomic::{AtomicU64, Ordering};
    use std::time::Instant;

    static TEST_SEQUENCE: AtomicU64 = AtomicU64::new(0);

    struct Fixture {
        root: PathBuf,
        manager: ProcessManager,
    }

    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = self.manager.stop("test", None);
            let _ = fs::remove_dir_all(&self.root);
        }
    }

    fn fixture(name: &str) -> Fixture {
        let root = std::env::temp_dir().join(format!(
            "lithe-linux-process-{name}-{}-{}",
            std::process::id(),
            TEST_SEQUENCE.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&root).expect("fixture");
        Fixture {
            root,
            manager: ProcessManager::new(),
        }
    }

    fn shell_step(root: &Path, script: &str, label: &str) -> ProcessStep {
        ProcessStep {
            label: label.to_string(),
            command: ProcessCommand {
                program: "/bin/sh".to_string(),
                arguments: vec!["-c".to_string(), script.to_string()],
                working_directory: root.to_string_lossy().into_owned(),
                environment: std::env::vars().collect(),
            },
        }
    }

    fn wait_for_finished(
        receiver: &mpsc::Receiver<ProcessEvent>,
        deadline: Duration,
    ) -> Vec<ProcessEvent> {
        let start = Instant::now();
        let mut events = Vec::new();
        while start.elapsed() < deadline {
            let remaining = deadline.saturating_sub(start.elapsed());
            match receiver.recv_timeout(remaining) {
                Ok(event) => {
                    let finished = matches!(&event, ProcessEvent::Finished { .. });
                    events.push(event);
                    if finished {
                        return events;
                    }
                }
                Err(mpsc::RecvTimeoutError::Timeout) => break,
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            }
        }
        events
    }

    #[test]
    fn prelaunch_failure_stops_before_main_step() {
        let fixture = fixture("prelaunch-failure");
        let marker = fixture.root.join("main-ran");
        let marker_text = marker.to_string_lossy().into_owned();
        let steps = vec![
            shell_step(&fixture.root, "exit 7", "compiler"),
            shell_step(
                &fixture.root,
                &format!("printf done > '{marker_text}'"),
                "main",
            ),
        ];
        let (sender, receiver) = mpsc::channel();
        let handle = fixture
            .manager
            .start("test", "execution-1", steps, sender)
            .expect("start");
        let events = wait_for_finished(&receiver, Duration::from_secs(2));
        handle.join().expect("join");
        assert!(events.iter().any(|event| matches!(
            event,
            ProcessEvent::Finished {
                exit_code: Some(7),
                ..
            }
        )));
        assert!(
            !marker.exists(),
            "main step must not run after prelaunch failure"
        );
    }

    #[test]
    fn stop_terminates_the_complete_process_group() {
        let fixture = fixture("process-group");
        let script = "sleep 30 & child=$!; printf '%s\\n' \"$child\"; wait";
        let steps = vec![shell_step(&fixture.root, script, "tree")];
        let (sender, receiver) = mpsc::channel();
        let handle = fixture
            .manager
            .start("test", "execution-2", steps, sender)
            .expect("start");
        let mut child_pid = None;
        let deadline = Instant::now() + Duration::from_secs(2);
        while Instant::now() < deadline && child_pid.is_none() {
            let remaining = deadline.saturating_duration_since(Instant::now());
            match receiver.recv_timeout(remaining) {
                Ok(ProcessEvent::Output { text, .. }) => {
                    if let Ok(pid) = text.trim().parse::<i32>() {
                        child_pid = Some(pid);
                    }
                }
                Ok(ProcessEvent::Finished { .. }) => break,
                Ok(_) => {}
                Err(mpsc::RecvTimeoutError::Timeout)
                | Err(mpsc::RecvTimeoutError::Disconnected) => break,
            }
        }
        let child_pid = child_pid.expect("fake process must report its child pid");
        fixture
            .manager
            .request_stop("test", Some("execution-2"))
            .unwrap();
        let events = wait_for_finished(&receiver, Duration::from_secs(2));
        handle.join().expect("join");
        assert!(events.iter().any(|event| matches!(
            event,
            ProcessEvent::Finished {
                cancelled: true,
                ..
            }
        )));
        let gone_deadline = Instant::now() + Duration::from_secs(2);
        while Instant::now() < gone_deadline {
            let result = unsafe { libc::kill(child_pid, 0) };
            if result == -1 {
                break;
            }
            thread::park_timeout(Duration::from_millis(10));
        }
        assert_eq!(
            unsafe { libc::kill(child_pid, 0) },
            -1,
            "child process survived group stop"
        );
    }

    #[test]
    fn executable_toolchain_and_tool_map_to_linux_paths() {
        let fixture = fixture("toolchain-map");
        let jdk = fixture.root.join("jdk");
        fs::create_dir_all(jdk.join("bin")).unwrap();
        fs::write(jdk.join("bin/java"), "java fixture").unwrap();
        fs::write(jdk.join("bin/javac"), "javac fixture").unwrap();
        let maven = fixture.root.join("maven/bin");
        fs::create_dir_all(&maven).unwrap();
        fs::write(maven.join("mvn"), "maven fixture").unwrap();
        let node = fixture.root.join("node/bin");
        fs::create_dir_all(&node).unwrap();
        fs::write(node.join("node"), "node fixture").unwrap();
        fs::write(node.join("npm"), "npm fixture").unwrap();
        let paths = ToolchainPaths {
            java_home_path: jdk.to_string_lossy().into_owned(),
            maven_executable_path: fixture.root.join("maven").to_string_lossy().into_owned(),
            runtime_executable_paths: BTreeMap::from([(
                "project-node".to_string(),
                fixture.root.join("node/bin").to_string_lossy().into_owned(),
            )]),
            ..ToolchainPaths::default()
        };
        let plan = LaunchPlan {
            executable: LaunchExecutable {
                toolchain: Some("project-jdk".to_string()),
                command: None,
                tool: Some("javac".to_string()),
            },
            arguments: vec!["-version".to_string()],
            working_directory: ".".to_string(),
            environment: BTreeMap::new(),
            env: BTreeMap::new(),
            pre_launch_steps: vec![PreLaunchStep {
                executable: LaunchExecutable {
                    toolchain: Some("project-jdk".to_string()),
                    command: None,
                    tool: Some("javac".to_string()),
                },
                arguments: vec!["-version".to_string()],
                classpath: Vec::new(),
                modulepath: Vec::new(),
            }],
            classpath: Vec::new(),
            modulepath: Vec::new(),
        };
        let (steps, main) = resolve_launch(&plan, &fixture.root.to_string_lossy(), &paths).unwrap();
        assert!(main.program.ends_with("jdk/bin/javac"));
        assert_eq!(steps.len(), 2);
        assert!(steps[0].command.program.ends_with("jdk/bin/javac"));

        let mut maven_plan = plan.clone();
        maven_plan.executable = LaunchExecutable {
            toolchain: Some("project-maven".to_string()),
            command: None,
            tool: None,
        };
        maven_plan.pre_launch_steps.clear();
        let (_, maven) =
            resolve_launch(&maven_plan, &fixture.root.to_string_lossy(), &paths).unwrap();
        assert!(maven.program.ends_with("maven/bin/mvn"));

        let mut node_plan = plan.clone();
        node_plan.executable = LaunchExecutable {
            toolchain: None,
            command: Some("npm".to_string()),
            tool: None,
        };
        node_plan.pre_launch_steps.clear();
        let (_, npm) = resolve_launch(&node_plan, &fixture.root.to_string_lossy(), &paths).unwrap();
        assert!(npm.program.ends_with("node/bin/npm"));
    }

    #[test]
    fn javac_prelaunch_creates_its_output_directory() {
        let fixture = fixture("javac-output");
        let jdk = fixture.root.join("jdk");
        fs::create_dir_all(jdk.join("bin")).unwrap();
        fs::write(jdk.join("bin/java"), "java fixture").unwrap();
        fs::write(jdk.join("bin/javac"), "javac fixture").unwrap();
        let paths = ToolchainPaths {
            java_home_path: jdk.to_string_lossy().into_owned(),
            ..ToolchainPaths::default()
        };
        let plan = LaunchPlan {
            executable: LaunchExecutable {
                toolchain: Some("project-jdk".to_string()),
                command: None,
                tool: None,
            },
            arguments: vec!["demo.App".to_string()],
            working_directory: ".".to_string(),
            environment: BTreeMap::new(),
            env: BTreeMap::new(),
            pre_launch_steps: vec![PreLaunchStep {
                executable: LaunchExecutable {
                    toolchain: Some("project-jdk".to_string()),
                    command: None,
                    tool: Some("javac".to_string()),
                },
                arguments: vec![
                    "-d".to_string(),
                    ".lithe/run/classes/current-file".to_string(),
                    "src/App.java".to_string(),
                ],
                classpath: Vec::new(),
                modulepath: Vec::new(),
            }],
            classpath: vec![".lithe/run/classes/current-file".to_string()],
            modulepath: Vec::new(),
        };
        resolve_launch(&plan, &fixture.root.to_string_lossy(), &paths).unwrap();
        assert!(fixture
            .root
            .join(".lithe/run/classes/current-file")
            .is_dir());
    }
}
