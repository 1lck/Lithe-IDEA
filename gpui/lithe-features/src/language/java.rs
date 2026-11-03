//! Java 语言服务（JDT LS）：与 macOS 相同的资源布局、启动方式和准备状态。
//!
//! 资源只来自产品自己的 Java Support bundle（JDT LS + 它自己的 JDK），
//! 不读取 `PATH`、`JAVA_HOME` 或其它机器级安装。准备阶段来自 Core 的
//! `projectPreparation` 投影，宿主不自行猜测。
//!
//! 与 macOS 的分层对应关系：
//! - [`JavaLanguageService`]：会话与事件轮询，对应 `LanguageServerSession`；
//! - [`JavaLanguageServiceModel`]：应用级状态，对应 `LanguageToolingSessionManager`；
//! - 视图在 `language::status` 与 Run 面板中消费同一份快照。

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

use async_channel::{Receiver, Sender, unbounded};
use gpui_kit::{AppContext as _, Context, EventEmitter, Task};
use lithe_core_client::CoreClient;
use serde_json::{Value, json};

use crate::run::model::{PreparationPhase, PreparationStatus, ProjectPreparation};

/// Core 的轮询接口没有阻塞等待，空轮询也要有界，避免空转占满一个核心。
const POLL_INTERVAL: Duration = Duration::from_millis(120);
/// 停止后等待 Core 结束会话的上限；超时直接销毁，避免退出被卡住。
const STOP_BUDGET: Duration = Duration::from_secs(3);

/// Core 的 `java.prepareLaunch` 返回的启动目标（由 JDT 决定）。
#[derive(Clone, Debug)]
pub struct JavaLaunchTarget {
    pub main_class: String,
    pub project_name: Option<String>,
    pub class_paths: Vec<String>,
    pub module_paths: Vec<String>,
    /// JDT 报告了编译错误，但 classpath 已解析；Run 面板据此弹出决策横幅。
    pub build_failure: Option<JavaBuildFailure>,
}

/// JDT 构建失败的证据，对齐 macOS `JavaLaunchBuildFailure` 与
/// `JavaBuildReport`：宿主只负责展示，不据此单独阻止启动。
#[derive(Clone, Debug)]
pub struct JavaBuildFailure {
    pub code: String,
    pub message: String,
    pub report: Option<JavaBuildReport>,
}

/// JDT 构建报告；字段与 Core `JavaBuildReport` 一一对应。
#[derive(Clone, Debug, Default)]
pub struct JavaBuildReport {
    pub marker_scope: Option<String>,
    pub elapsed_milliseconds: Option<u64>,
    /// `rebuildJavaIndex` 表示构建器本身失效，重建索引才可能恢复。
    pub recovery: Option<String>,
    /// 本次失败之前构建器已经失效过，解释文案据此区分。
    pub builder_failed_earlier: bool,
}

/// 语言服务线程收到的命令。所有 Core 轮询都由该线程独占，
/// 因此准备请求与状态事件不会互相抢事件队列。
enum JavaCommand {
    PrepareLaunch {
        source_path: String,
        main_class: Option<String>,
        reply: Sender<Result<JavaLaunchTarget, String>>,
    },
    /// 保存后把最新文本同步给 JDT 并回报 didSave；macOS 在启动前对每个
    /// 打开文档都做这一步，只有写盘成功并不足以让 JDT 的 working copy 更新。
    NotifySaved {
        path: PathBuf,
        text: String,
    },
}

/// 语言服务线程发给模型的事件。
#[derive(Clone, Debug)]
enum JavaServiceEvent {
    /// Core 推送的真实准备快照。
    Preparation(ProjectPreparation),
    /// 会话启动或轮询失败；附带的原因只用于日志，不直接展示。
    Failed(String),
    /// 会话已经终止；界面据此区分“准备停止”和“准备完成”。
    Stopped,
}

/// 一个工作区的 Java 语言服务会话。
struct JavaLanguageService {
    stop: Arc<AtomicBool>,
    receiver: Receiver<JavaServiceEvent>,
    commands: Sender<JavaCommand>,
    thread: Option<JoinHandle<()>>,
}

impl JavaLanguageService {
    fn start(client: CoreClient, root: PathBuf) -> Self {
        let (sender, receiver) = unbounded();
        let (commands, command_receiver) = unbounded();
        let stop = Arc::new(AtomicBool::new(false));
        let thread_stop = Arc::clone(&stop);
        let thread = thread::spawn(move || run(client, root, thread_stop, sender, command_receiver));
        Self {
            stop,
            receiver,
            commands,
            thread: Some(thread),
        }
    }

    fn receiver(&self) -> Receiver<JavaServiceEvent> {
        self.receiver.clone()
    }

    /// 请求 JDT 为一次运行准备主类、构建与运行时 classpath。
    fn prepare_launch(
        &self,
        source_path: String,
        main_class: Option<String>,
    ) -> Receiver<Result<JavaLaunchTarget, String>> {
        let (reply, receiver) = unbounded();
        let _ = self.commands.send_blocking(JavaCommand::PrepareLaunch {
            source_path,
            main_class,
            reply,
        });
        receiver
    }

    /// 把保存后的文档同步给 JDT 并回报 didSave。
    fn notify_saved(&self, path: PathBuf, text: String) {
        let _ = self.commands.send_blocking(JavaCommand::NotifySaved { path, text });
    }

    /// 通知会话退出，并交出线程句柄供调用方等待清理完成。
    fn stop(&mut self) -> Option<JoinHandle<()>> {
        self.stop.store(true, Ordering::SeqCst);
        self.thread.take()
    }
}

/// 应用级 Java 语言服务状态。
///
/// 工作台在打开/关闭项目时更新 root；Run 面板和状态栏读取同一份快照，
/// 与 macOS 的 session-owned snapshot 一致。
pub struct JavaLanguageServiceModel {
    client: CoreClient,
    root: Option<PathBuf>,
    generation: u64,
    service: Option<JavaLanguageService>,
    preparation: Option<ProjectPreparation>,
    seen: Vec<PreparationPhase>,
    expanded: bool,
    failure: Option<String>,
}

/// 语言服务状态变化；工作台与 Run 面板据此刷新。
#[derive(Clone, Copy, Debug)]
pub enum JavaLanguageServiceEvent {
    Changed,
}

impl EventEmitter<JavaLanguageServiceEvent> for JavaLanguageServiceModel {}

impl JavaLanguageServiceModel {
    pub fn new(client: CoreClient) -> Self {
        Self {
            client,
            root: None,
            generation: 0,
            service: None,
            preparation: None,
            seen: Vec::new(),
            expanded: false,
            failure: None,
        }
    }

    /// 切换工作区；相同 root 重复调用不会重启会话。
    pub fn set_root(&mut self, root: Option<PathBuf>, cx: &mut Context<Self>) {
        let normalized = root.filter(|path| !path.as_os_str().is_empty());
        if normalized == self.root {
            return;
        }
        let _ = self.stop_service();
        self.generation = self.generation.wrapping_add(1);
        self.root = normalized;
        self.preparation = None;
        self.seen.clear();
        self.failure = None;
        cx.notify();
        self.emit(cx);

        let Some(root) = self.root.clone() else {
            return;
        };
        let generation = self.generation;
        let client = self.client;
        cx.spawn(async move |this, cx| {
            let decision = cx
                .background_spawn(async move { java_workspace_should_start(client, &root) })
                .await;
            match decision {
                Ok(true) => {
                    let _ = this.update(cx, |this, cx| {
                        if this.generation != generation {
                            return;
                        }
                        this.start_service(cx);
                    });
                }
                Ok(false) => {}
                Err(message) => {
                    let _ = this.update(cx, |this, _cx| {
                        if this.generation != generation {
                            return;
                        }
                        crate::logging::log_info(
                            "language",
                            format!("Java workspace policy failed: {message}"),
                        );
                    });
                }
            }
        })
        .detach();
    }

    /// 关闭项目时停止会话并清空状态。
    pub fn stop(&mut self, cx: &mut Context<Self>) {
        self.set_root(None, cx);
    }

    pub fn preparation(&self) -> Option<&ProjectPreparation> {
        self.preparation.as_ref()
    }

    pub fn seen(&self) -> &[PreparationPhase] {
        &self.seen
    }

    /// 运行闸门：Java 项目准备完成或失败前，Run 先排队。
    pub fn blocks_run(&self) -> bool {
        self.preparation
            .as_ref()
            .is_some_and(|preparation| preparation.blocks_run)
    }

    pub fn is_expanded(&self) -> bool {
        self.expanded
    }

    pub fn toggle_expanded(&mut self, cx: &mut Context<Self>) {
        self.expanded = !self.expanded;
        cx.notify();
    }

    pub fn failure(&self) -> Option<&str> {
        self.failure.as_deref()
    }

    /// 让 JDT 为一次运行准备主类、构建与运行时 classpath。
    ///
    /// 与 macOS 一致：宿主只等待 Core 的操作结果，不自己跑 Maven。
    pub fn prepare_launch(
        &mut self,
        source_path: PathBuf,
        main_class: Option<String>,
        cx: &mut Context<Self>,
    ) -> Task<Result<JavaLaunchTarget, String>> {
        let Some(service) = self.service.as_ref() else {
            return Task::ready(Err(
                "The Java language service is not running.".to_string()
            ));
        };
        let receiver = service.prepare_launch(path_text(&source_path), main_class);
        cx.spawn(async move |_this, _cx| match receiver.recv().await {
            Ok(result) => result,
            Err(_) => Err("The Java language service stopped.".to_string()),
        })
    }

    /// 保存后把文档同步给 JDT 并回报 didSave。
    ///
    /// 对齐 macOS `saveJavaWorkspaceForLaunch`：磁盘持久化不等于语言服务就绪，
    /// 构建前必须让 JDT 的 working copy 看到同一份文本。
    pub fn notify_document_saved(&mut self, path: PathBuf, text: String) {
        if path.extension().and_then(|extension| extension.to_str()) != Some("java") {
            return;
        }
        if let Some(service) = self.service.as_ref() {
            service.notify_saved(path, text);
        }
    }

    /// 清空并重建当前工作区的 Java 索引。
    ///
    /// 与 macOS `rebuildJavaIndex` 一致：停止会话、删除该工作区对应的 JDT
    /// 状态目录，再重新启动服务；旧索引不会被增量构建继续沿用。
    pub fn rebuild_index(&mut self, cx: &mut Context<Self>) {
        let Some(root) = self.root.clone() else {
            return;
        };
        let handle = self.stop_service();
        self.generation = self.generation.wrapping_add(1);
        self.preparation = Some(ProjectPreparation::starting());
        self.seen.clear();
        self.failure = None;
        cx.notify();
        self.emit(cx);

        let client = self.client;
        let root_text = path_text(&root);
        cx.spawn(async move |this, cx| {
            let directory = cx
                .background_spawn(async move {
                    // 等语言服务线程完成 shutdown，再删除状态目录；否则 JDT
                    // 退出时还可能在写同一批文件。
                    if let Some(handle) = handle {
                        let _ = handle.join();
                    }
                    let cache = cache_directory()?;
                    let key = client
                        .execute_raw(
                            "lsp.jdtWorkspaceKey",
                            json!({ "workspaceRoot": root_text }),
                        )
                        .ok()?
                        .get("workspaceKey")
                        .and_then(Value::as_str)
                        .map(str::to_string)?;
                    Some(cache.join(key))
                })
                .await;
            if let Some(directory) = directory {
                crate::logging::log_info(
                    "language",
                    format!("Rebuilding Java index: {}", directory.display()),
                );
                let _ = std::fs::remove_dir_all(directory);
            }
            let _ = this.update(cx, |this, cx| this.start_service(cx));
        })
        .detach();
    }

    fn start_service(&mut self, cx: &mut Context<Self>) {
        let Some(root) = self.root.clone() else {
            return;
        };
        if self.service.is_some() {
            return;
        }
        let service = JavaLanguageService::start(self.client, root);
        let receiver = service.receiver();
        self.service = Some(service);
        self.preparation = Some(ProjectPreparation::starting());
        self.seen.clear();
        self.failure = None;
        cx.notify();
        self.emit(cx);

        let generation = self.generation;
        cx.spawn(async move |this, cx| {
            while let Ok(event) = receiver.recv().await {
                let alive = this
                    .update(cx, |this, cx| {
                        if this.generation != generation {
                            return;
                        }
                        this.apply_event(event, cx);
                    })
                    .is_ok();
                if !alive {
                    break;
                }
            }
        })
        .detach();
    }

    fn apply_event(&mut self, event: JavaServiceEvent, cx: &mut Context<Self>) {
        match event {
            JavaServiceEvent::Preparation(preparation) => {
                let changed = self.preparation.as_ref() != Some(&preparation);
                if !self.seen.contains(&preparation.phase) {
                    self.seen.push(preparation.phase);
                }
                if changed {
                    crate::logging::log_info(
                        "language",
                        format!(
                            "Java preparation: {} ({:?}, blocks_run={})",
                            preparation.phase.label(),
                            preparation.status,
                            preparation.blocks_run
                        ),
                    );
                }
                self.preparation = Some(preparation);
                if changed {
                    cx.notify();
                    self.emit(cx);
                }
            }
            JavaServiceEvent::Failed(message) => {
                crate::logging::log_info(
                    "language",
                    format!("Java language service failed: {message}"),
                );
                self.failure = Some(message);
                self.preparation = Some(ProjectPreparation {
                    phase: PreparationPhase::Failed,
                    status: PreparationStatus::Failed,
                    blocks_run: false,
                    import_percent: None,
                    current_project: None,
                    download_artifact: None,
                });
                cx.notify();
                self.emit(cx);
            }
            JavaServiceEvent::Stopped => {
                self.service = None;
                if let Some(preparation) = self.preparation.as_mut() {
                    if preparation.status != PreparationStatus::Failed
                        && preparation.status != PreparationStatus::Ready
                    {
                        preparation.phase = PreparationPhase::Stopped;
                        preparation.status = PreparationStatus::Idle;
                        preparation.blocks_run = true;
                    }
                }
                cx.notify();
                self.emit(cx);
            }
        }
    }

    fn stop_service(&mut self) -> Option<JoinHandle<()>> {
        self.service.take().and_then(|mut service| service.stop())
    }

    fn emit(&self, cx: &mut Context<Self>) {
        cx.emit(JavaLanguageServiceEvent::Changed);
    }
}

/// 后台线程主体：发现 Java Support、启动会话、轮询事件与准备请求。
fn run(
    client: CoreClient,
    root: PathBuf,
    stop: Arc<AtomicBool>,
    sender: Sender<JavaServiceEvent>,
    commands: Receiver<JavaCommand>,
) {
    let installation = match JdtlsInstallation::discover(&root) {
        Ok(installation) => installation,
        Err(message) => {
            fail_pending_launches(&mut BTreeMap::new(), &message);
            let _ = sender.send_blocking(JavaServiceEvent::Failed(message));
            let _ = sender.send_blocking(JavaServiceEvent::Stopped);
            return;
        }
    };
    let payload = match installation.start_request(&root) {
        Ok(payload) => payload,
        Err(message) => {
            let _ = sender.send_blocking(JavaServiceEvent::Failed(message));
            let _ = sender.send_blocking(JavaServiceEvent::Stopped);
            return;
        }
    };
    if stop.load(Ordering::SeqCst) {
        return;
    }

    let session_id = match client.execute_raw("lsp.startServer", payload) {
        Ok(value) => match value.get("sessionId").and_then(Value::as_str) {
            Some(session_id) => session_id.to_string(),
            None => {
                let _ = sender.send_blocking(JavaServiceEvent::Failed(
                    "Core did not return a language-server session".to_string(),
                ));
                let _ = sender.send_blocking(JavaServiceEvent::Stopped);
                return;
            }
        },
        Err(error) => {
            let _ = sender.send_blocking(JavaServiceEvent::Failed(format!(
                "{} ({})",
                error.message, error.code
            )));
            let _ = sender.send_blocking(JavaServiceEvent::Stopped);
            return;
        }
    };

    let mut terminal = false;
    let mut last_preparation: Option<ProjectPreparation> = None;
    let mut pending_launches: BTreeMap<String, Sender<Result<JavaLaunchTarget, String>>> =
        BTreeMap::new();
    while !stop.load(Ordering::SeqCst) && !terminal {
        // 准备请求与事件轮询由同一线程独占，避免两个消费者抢 Core 的事件队列。
        while let Ok(command) = commands.try_recv() {
            match command {
                JavaCommand::PrepareLaunch {
                    source_path,
                    main_class,
                    reply,
                } => {
                    let request = json!({
                        "sessionId": session_id,
                        "sourcePath": source_path,
                        "mainClass": main_class,
                    });
                    match client.execute_raw("java.prepareLaunch", request) {
                        Ok(value) => match value
                            .get("operationId")
                            .and_then(Value::as_str)
                            .filter(|id| !id.is_empty())
                        {
                            Some(operation_id) => {
                                pending_launches.insert(operation_id.to_string(), reply);
                            }
                            None => {
                                let _ = reply.send_blocking(Err(
                                    "Core did not return a Java launch operation".to_string(),
                                ));
                            }
                        },
                        Err(error) => {
                            let _ = reply.send_blocking(Err(format!(
                                "{} ({})",
                                error.message, error.code
                            )));
                        }
                    }
                }
                JavaCommand::NotifySaved { path, text } => {
                    // JDT 的 didSave 会丢弃并重新加载 working copy；先同步完整
                    // 文本，再回报保存，顺序与 macOS `notifyDocumentSaved` 一致。
                    let uri = file_uri(&path);
                    let sync = json!({
                        "sessionId": session_id,
                        "uri": uri.clone(),
                        "languageId": "java",
                        "text": text.clone(),
                    });
                    if let Err(error) = client.execute_raw("lsp.syncDocument", sync) {
                        crate::logging::log_info(
                            "language",
                            format!(
                                "Java document sync failed for {}: {} ({})",
                                path.display(),
                                error.message,
                                error.code
                            ),
                        );
                        continue;
                    }
                    let save = json!({
                        "sessionId": session_id,
                        "uri": uri,
                        "text": text,
                    });
                    if let Err(error) = client.execute_raw("lsp.saveDocument", save) {
                        crate::logging::log_info(
                            "language",
                            format!(
                                "Java document didSave failed for {}: {} ({})",
                                path.display(),
                                error.message,
                                error.code
                            ),
                        );
                    }
                }
            }
        }

        match client.execute_raw("lsp.pollEvents", json!({ "sessionId": session_id })) {
            Ok(value) => {
                // Core 同时返回当前投影；即使启动期间的事件已经被清空，
                // 也能据此恢复真实阶段，避免界面停在一个过期状态。
                if let Some(snapshot) =
                    value.get("projectPreparation").and_then(preparation_snapshot)
                {
                    if last_preparation.as_ref() != Some(&snapshot) {
                        last_preparation = Some(snapshot.clone());
                        let _ = sender.send_blocking(JavaServiceEvent::Preparation(snapshot));
                    }
                }
                if let Some(events) = value.get("events").and_then(Value::as_array) {
                    for event in events {
                        if event.get("type").and_then(Value::as_str) == Some("requestCompleted") {
                            complete_launch(event, &mut pending_launches);
                        }
                        terminal |= handle_event(event, &sender);
                    }
                }
            }
            Err(error) => {
                let _ = sender.send_blocking(JavaServiceEvent::Failed(format!(
                    "{} ({})",
                    error.message, error.code
                )));
                terminal = true;
            }
        }
        if !terminal {
            // 有在途准备时缩短轮询间隔，让构建完成事件尽快回到 Run 面板。
            let interval = if pending_launches.is_empty() {
                POLL_INTERVAL
            } else {
                Duration::from_millis(60)
            };
            thread::sleep(interval);
        }
    }

    fail_pending_launches(
        &mut pending_launches,
        "The Java language service stopped before launch preparation finished.",
    );
    shutdown(&client, &session_id);
}

/// 完成一次 `java.prepareLaunch` 操作并回复等待方。
fn complete_launch(
    event: &Value,
    pending: &mut BTreeMap<String, Sender<Result<JavaLaunchTarget, String>>>,
) {
    let Some(operation_id) = event.get("operationId").and_then(Value::as_str) else {
        return;
    };
    let Some(reply) = pending.remove(operation_id) else {
        return;
    };
    let result = if let Some(error) = event.get("error") {
        Err(error
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("Java launch preparation failed")
            .to_string())
    } else {
        event
            .get("result")
            .ok_or_else(|| "The Java language service returned no launch result".to_string())
            .and_then(launch_target)
    };
    let _ = reply.send_blocking(result);
}

/// 把 Core 的 `java.prepareLaunch` 结果转成启动目标。
///
/// 编译错误仍然带回已解析的 target 和完整构建报告：Run 面板据此让用户决定
/// 是否仍然运行，并展示与 macOS `JavaLaunchDecisionDialog` 相同的证据。
fn launch_target(value: &Value) -> Result<JavaLaunchTarget, String> {
    let build_failure = match value.get("kind").and_then(Value::as_str) {
        Some("ready") => None,
        Some("buildFailed") => {
            let failure = value.get("failure");
            let code = failure
                .and_then(|failure| failure.get("code"))
                .and_then(Value::as_str)
                .unwrap_or("javaBuildCompilationErrors")
                .to_string();
            let message = failure
                .and_then(|failure| failure.get("message"))
                .and_then(Value::as_str)
                .unwrap_or("The Java project build reported compilation errors.")
                .to_string();
            let report = failure
                .and_then(|failure| failure.get("report"))
                .map(|report| JavaBuildReport {
                    marker_scope: report
                        .get("markerScope")
                        .and_then(Value::as_str)
                        .map(str::to_string),
                    elapsed_milliseconds: report
                        .get("elapsedMilliseconds")
                        .and_then(Value::as_u64),
                    recovery: report
                        .get("recovery")
                        .and_then(Value::as_str)
                        .map(str::to_string),
                    builder_failed_earlier: report
                        .get("builderFailedEarlier")
                        .and_then(Value::as_bool)
                        .unwrap_or(false),
                });
            Some(JavaBuildFailure {
                code,
                message,
                report,
            })
        }
        other => {
            return Err(format!(
                "The Java language service returned an unexpected launch kind: {}",
                other.unwrap_or("missing")
            ));
        }
    };
    let target = value
        .get("target")
        .ok_or_else(|| "The Java language service returned no launch target".to_string())?;
    let main_class = target
        .get("mainClass")
        .and_then(Value::as_str)
        .filter(|main| !main.trim().is_empty())
        .ok_or_else(|| "The Java language service returned no main class".to_string())?
        .to_string();
    let project_name = target
        .get("projectName")
        .and_then(Value::as_str)
        .filter(|project| !project.is_empty())
        .map(str::to_string);
    Ok(JavaLaunchTarget {
        main_class,
        project_name,
        class_paths: string_array(target.get("classPaths")),
        module_paths: string_array(target.get("modulePaths")),
        build_failure,
    })
}

fn string_array(value: Option<&Value>) -> Vec<String> {
    value
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(Value::as_str)
                .filter(|item| !item.trim().is_empty())
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default()
}

fn fail_pending_launches(
    pending: &mut BTreeMap<String, Sender<Result<JavaLaunchTarget, String>>>,
    message: &str,
) {
    for (_, reply) in std::mem::take(pending) {
        let _ = reply.send_blocking(Err(message.to_string()));
    }
}

/// 消费一条 Core 运行时事件；返回是否会话已终止。
fn handle_event(event: &Value, sender: &Sender<JavaServiceEvent>) -> bool {
    match event.get("type").and_then(Value::as_str) {
        Some("stateChanged") => match event.get("state").and_then(Value::as_str) {
            Some("failed") => {
                let message = event
                    .get("error")
                    .and_then(|error| error.get("message"))
                    .and_then(Value::as_str)
                    .or_else(|| event.get("message").and_then(Value::as_str))
                    .unwrap_or("Java language service failed")
                    .to_string();
                let _ = sender.send_blocking(JavaServiceEvent::Failed(message));
                true
            }
            Some("stopped") => {
                let _ = sender.send_blocking(JavaServiceEvent::Stopped);
                true
            }
            _ => false,
        },
        _ => false,
    }
}

/// 把 Core 的 `projectPreparation` 结果转成界面状态。
fn preparation_snapshot(value: &Value) -> Option<ProjectPreparation> {
    Some(ProjectPreparation {
        phase: PreparationPhase::from_core(value.get("phase")?.as_str()?)?,
        status: PreparationStatus::from_core(value.get("status")?.as_str()?)?,
        blocks_run: value.get("blocksRun")?.as_bool()?,
        import_percent: None,
        current_project: None,
        download_artifact: None,
    })
}

/// 请求 Core 停止会话，等终态事件或预算耗尽后释放会话。
fn shutdown(client: &CoreClient, session_id: &str) {
    let _ = client.execute_raw("lsp.stopServer", json!({ "sessionId": session_id }));
    let deadline = Instant::now() + STOP_BUDGET;
    while Instant::now() < deadline {
        let terminal = match client.execute_raw("lsp.pollEvents", json!({ "sessionId": session_id })) {
            Ok(value) => value
                .get("events")
                .and_then(Value::as_array)
                .map(|events| {
                    events.iter().any(|event| {
                        event.get("type").and_then(Value::as_str) == Some("stateChanged")
                            && matches!(
                                event.get("state").and_then(Value::as_str),
                                Some("stopped" | "failed")
                            )
                    })
                })
                .unwrap_or(false),
            // 会话已经不存在时也没有可等的事件。
            Err(_) => true,
        };
        if terminal {
            break;
        }
        thread::sleep(Duration::from_millis(60));
    }
    let _ = client.execute_raw("lsp.destroyServer", json!({ "sessionId": session_id }));
}

/// 用 Core 的 `java.workspacePolicy` 判断工作区是否应该启动 Java 语言服务。
///
/// 与 macOS 一致：由 Core 决定 Java 项目，而不是宿主检查 `pom.xml` 或源码目录。
fn java_workspace_should_start(client: CoreClient, root: &Path) -> Result<bool, String> {
    let snapshot = client
        .workspace_snapshot(root)
        .map_err(|error| format!("{} ({})", error.message, error.code))?;
    let response = client
        .execute_raw(
            "java.workspacePolicy",
            json!({
                "workspacePaths": snapshot.files,
                "changedPaths": [],
            }),
        )
        .map_err(|error| format!("{} ({})", error.message, error.code))?;
    Ok(response
        .get("shouldStart")
        .and_then(Value::as_bool)
        .unwrap_or(false))
}

// ---------------------------------------------------------------------------
// Java Support 资源（与 macOS 插件包语义一致）
// ---------------------------------------------------------------------------
//
// 语言服务器资源是产品的一部分，不搜索用户环境：一个只读 bundle 同时包含
// JDT LS 与它自己的 JDK。`LanguageServers/jdtls` + `LanguageServers/jdk` 对应
// Windows 安装布局，`language-server` + `runtime/<arch>` 对应 macOS 插件布局。

/// 已解析的 Java Support bundle：安装根与其中的 JDT LS 目录。
struct LanguageServerBundle {
    root: PathBuf,
    server: PathBuf,
}

impl LanguageServerBundle {
    fn discover(project_root: &Path) -> Option<Self> {
        for root in bundle_candidates(project_root) {
            if let Some(server) = server_root(&root) {
                return Some(Self { root, server });
            }
        }
        None
    }
}

/// bundle 候选目录；不包含 PATH、JAVA_HOME 或其它机器级安装。
fn bundle_candidates(project_root: &Path) -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    if let Some(root) = std::env::var_os("LITHE_LANGUAGE_SERVER_ROOT") {
        candidates.push(PathBuf::from(root));
    }
    if let Ok(executable) = std::env::current_exe() {
        if let Some(directory) = executable.parent() {
            candidates.push(directory.join("LanguageServers"));
            let mut cursor = Some(directory);
            for _ in 0..6 {
                let Some(current) = cursor else { break };
                candidates.push(current.join(".artifacts"));
                cursor = current.parent();
            }
        }
    }
    candidates.push(project_root.join(".lithe").join("toolchains"));
    candidates
}

/// bundle 内的 JDT LS 根：Windows 安装布局或 macOS 插件布局。
fn server_root(bundle: &Path) -> Option<PathBuf> {
    [
        bundle.join("jdtls"),
        bundle.join("language-server"),
        bundle
            .join("dev.lithe.plugin.java-support")
            .join("language-server"),
        bundle.to_path_buf(),
    ]
    .into_iter()
    .find(|root| is_jdtls_root(root))
}

fn is_jdtls_root(root: &Path) -> bool {
    first_matching(&root.join("plugins"), "org.eclipse.equinox.launcher_", ".jar").is_some()
        && configuration_directory(root).is_some()
}

/// Eclipse 的配置目录：Windows 安装布局的 `config_*`，或插件布局的
/// `configuration/<arch>/config.ini`。
fn configuration_directory(server: &Path) -> Option<PathBuf> {
    for name in ["config_win", "config_mac", "config_linux"] {
        let candidate = server.join(name);
        if candidate.is_dir() {
            return Some(candidate);
        }
    }
    let base = server.join("configuration");
    let preferred = base.join(host_arch_name());
    if preferred.join("config.ini").is_file() {
        return Some(preferred);
    }
    let mut directories = std::fs::read_dir(&base)
        .ok()?
        .filter_map(|entry| entry.ok())
        .map(|entry| entry.path())
        .filter(|path| path.join("config.ini").is_file())
        .collect::<Vec<_>>();
    directories.sort();
    directories.into_iter().next()
}

fn host_arch_name() -> &'static str {
    match std::env::consts::ARCH {
        "aarch64" => "arm64",
        "x86_64" => "x86_64",
        other => other,
    }
}

/// 已解析的 JDT LS 及其直接启动资源。
struct JdtlsInstallation {
    launcher_jar: PathBuf,
    configuration_directory: PathBuf,
    lombok_agent: PathBuf,
    java_debug_bundle: Option<PathBuf>,
    extension_bundles: Vec<PathBuf>,
    java: PathBuf,
    java_home: PathBuf,
}

impl JdtlsInstallation {
    fn discover(project_root: &Path) -> Result<Self, String> {
        let bundle = LanguageServerBundle::discover(project_root).ok_or_else(|| {
            format!(
                "The Java Support bundle was not found. Put JDT LS and its JDK in {} \
                 (jdtls/ + jdk/, or the Java Support plugin layout language-server/ + runtime/).",
                default_bundle_hint()
            )
        })?;
        let server = &bundle.server;
        let launcher_jar =
            first_matching(&server.join("plugins"), "org.eclipse.equinox.launcher_", ".jar")
                .ok_or_else(|| incomplete(&bundle, "plugins/org.eclipse.equinox.launcher_*.jar"))?;
        let configuration_directory = configuration_directory(server)
            .ok_or_else(|| incomplete(&bundle, "configuration"))?;
        let lombok_agent = server.join("lombok").join("lombok.jar");
        if !lombok_agent.is_file() {
            return Err(incomplete(&bundle, "lombok/lombok.jar"));
        }
        let minimum = minimum_java_version(server);
        let (java, java_home) = bundled_java(&bundle.root, server, minimum)?;
        let java_debug_bundle =
            first_matching(&server.join("java-debug"), "com.microsoft.java.debug.plugin-", ".jar");
        let extension_bundles = jar_files(&server.join("java-test").join("extensions"));
        Ok(Self {
            launcher_jar,
            configuration_directory,
            lombok_agent,
            java_debug_bundle,
            extension_bundles,
            java,
            java_home,
        })
    }

    /// 构造 Core 的 `lsp.startServer` 请求。
    ///
    /// 与 macOS 一致：语言服务器只用自己的运行时直接启动，Core 负责复制
    /// 只读配置目录、创建 data 目录并拼出 JDT 参数。
    fn start_request(&self, root: &Path) -> Result<Value, String> {
        let cache_directory = cache_directory().ok_or_else(|| {
            "No writable application data directory for the Java language server".to_string()
        })?;
        let mut launch_resources = json!({
            "launcherJarPath": path_text(&self.launcher_jar),
            "configurationDirectory": path_text(&self.configuration_directory),
            "lombokAgentPath": path_text(&self.lombok_agent),
        });
        if let Some(bundle) = &self.java_debug_bundle {
            launch_resources["javaDebugBundlePath"] = json!(path_text(bundle));
        }
        if !self.extension_bundles.is_empty() {
            launch_resources["javaExtensionBundlePaths"] = json!(
                self.extension_bundles
                    .iter()
                    .map(|path| path_text(path))
                    .collect::<Vec<_>>()
            );
        }
        Ok(json!({
            "providerId": "java",
            "arguments": [],
            "rootUri": file_uri(root),
            "workingDirectory": path_text(root),
            "executablePath": path_text(&self.java),
            "runtimeExecutablePath": path_text(&self.java),
            "environment": { "JAVA_HOME": path_text(&self.java_home) },
            "cacheDirectory": path_text(&cache_directory),
            "jdtlsLaunchResources": launch_resources,
            "javaRuntimes": [],
            // 与 macOS 的 `startLanguageServer` 默认值一致。
            "initializeTimeoutMilliseconds": 30_000,
            "requestTimeoutMilliseconds": 30_000,
            "shutdownTimeoutMilliseconds": 2_000,
        }))
    }
}

fn incomplete(bundle: &LanguageServerBundle, resource: &str) -> String {
    format!(
        "The Java Support bundle at {} is incomplete: {resource} is missing. Reinstall or reprepare it.",
        bundle.server.display()
    )
}

/// 语言服务器运行时的默认安装位置，只用于错误提示。
fn default_bundle_hint() -> String {
    std::env::current_exe()
        .ok()
        .and_then(|executable| executable.parent().map(Path::to_path_buf))
        .map(|directory| directory.join("LanguageServers").display().to_string())
        .unwrap_or_else(|| "the application LanguageServers directory".to_string())
}

/// 只在 bundle 内寻找 JDT LS 自己的 JDK：`jdk/` 或 `runtime/<arch>/`。
fn bundled_java(
    bundle_root: &Path,
    server: &Path,
    minimum: u32,
) -> Result<(PathBuf, PathBuf), String> {
    let name = if cfg!(windows) { "java.exe" } else { "java" };
    let mut homes = vec![bundle_root.join("jdk")];
    if let Some(parent) = server.parent() {
        homes.push(parent.join("jdk"));
        homes.extend(runtime_homes(&parent.join("runtime")));
    }
    homes.extend(runtime_homes(&bundle_root.join("runtime")));

    let mut candidates: Vec<(PathBuf, PathBuf, Option<u32>)> = Vec::new();
    for home in homes {
        let java = home.join("bin").join(name);
        if java.is_file() {
            let major = java_major_version(&home);
            candidates.push((java, home, major));
        }
    }
    let selected = candidates
        .iter()
        .filter(|(_, _, major)| major.is_some_and(|major| major >= minimum))
        .max_by_key(|(_, _, major)| *major);
    match selected {
        Some((java, home, _)) => Ok((java.clone(), home.clone())),
        None if candidates.is_empty() => Err(format!(
            "The Java Support bundle at {} does not ship a Java runtime.",
            bundle_root.display()
        )),
        None => Err(format!(
            "The Java Support bundle must ship Java {minimum} or newer; found {}.",
            candidates
                .iter()
                .map(|(_, _, major)| major.map_or("unknown".to_string(), |major| major.to_string()))
                .collect::<Vec<_>>()
                .join(", ")
        )),
    }
}

/// `runtime/<arch>` 下带 `bin/java` 的 JDK 目录。
fn runtime_homes(runtime: &Path) -> Vec<PathBuf> {
    let mut homes = std::fs::read_dir(runtime)
        .map(|entries| {
            entries
                .filter_map(|entry| entry.ok())
                .map(|entry| entry.path())
                .filter(|path| path.is_dir())
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    homes.sort();
    homes
}

/// JDT LS 要求的最低 Java 主版本；安装清单优先，缺失时按 JDT LS 当前要求。
fn minimum_java_version(root: &Path) -> u32 {
    std::fs::read_to_string(root.join("manifest.json"))
        .ok()
        .and_then(|text| serde_json::from_str::<Value>(&text).ok())
        .and_then(|value| value.get("minimumJavaVersion").and_then(Value::as_u64))
        .map(|version| version as u32)
        .unwrap_or(21)
}

/// 从 JDK 的 `release` 文件读取主版本；读不到时返回 `None`。
fn java_major_version(home: &Path) -> Option<u32> {
    let release = std::fs::read_to_string(home.join("release")).ok()?;
    let line = release
        .lines()
        .find(|line| line.starts_with("JAVA_VERSION="))?;
    let version = line
        .trim_start_matches("JAVA_VERSION=")
        .trim_matches('"');
    let mut parts = version.split('.');
    let first = parts.next()?.parse::<u32>().ok()?;
    if first == 1 {
        parts.next()?.parse().ok()
    } else {
        Some(first)
    }
}

fn cache_directory() -> Option<PathBuf> {
    crate::settings::app_data_dir().map(|directory| directory.join("lsp"))
}

fn first_matching(directory: &Path, prefix: &str, suffix: &str) -> Option<PathBuf> {
    let mut matches = jar_files(directory)
        .into_iter()
        .filter(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .map(|name| name.starts_with(prefix) && name.ends_with(suffix))
                .unwrap_or(false)
        })
        .collect::<Vec<_>>();
    matches.sort();
    matches.into_iter().next()
}

fn jar_files(directory: &Path) -> Vec<PathBuf> {
    let mut files = std::fs::read_dir(directory)
        .map(|entries| {
            entries
                .filter_map(|entry| entry.ok())
                .map(|entry| entry.path())
                .filter(|path| path.is_file())
                .filter(|path| {
                    path.extension()
                        .and_then(|extension| extension.to_str())
                        .is_some_and(|extension| extension.eq_ignore_ascii_case("jar"))
                })
                .collect::<Vec<_>>()
        })
        .unwrap_or_default();
    files.sort();
    files
}

fn path_text(path: &Path) -> String {
    path.to_string_lossy().into_owned()
}

/// LSP 的 `rootUri` 必须是 URI；Windows 盘符需要第三条斜杠。
fn file_uri(path: &Path) -> String {
    let text = path.to_string_lossy().replace('\\', "/");
    if text.starts_with('/') {
        format!("file://{text}")
    } else {
        format!("file:///{text}")
    }
}
