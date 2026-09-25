use std::sync::mpsc;
use std::time::{Duration, Instant};

use gpui_kit::assets::IconName;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{h_flex, v_flex, Disableable as _, Icon, Sizable as _};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::EventEmitter;
use gpui_kit::{
    div, px, AnyElement, AppContext as _, Context, Entity, FontWeight, InteractiveElement as _,
    IntoElement, ParentElement as _, Render, ScrollHandle, StatefulInteractiveElement as _,
    Styled as _, WeakEntity, Window,
};

use crate::core::CoreClient;
use crate::lsp;
use crate::theme::ThemeColors;
use crate::workbench::editor::EditorView;
use crate::workbench::run::{
    create_launch_plan_request, default_generated_configuration_id, list_java_sources,
    maven_context_for_configuration, parse_resolved_configurations, read_toolchain_paths,
    sequence_is_current, toolchain_candidates, write_generated_documents, LaunchPlan, OutputStream,
    ProcessEvent, ProcessManager, RunConfigItem,
};
use crate::workbench::terminal::TerminalView;
use crate::workbench::view::WorkbenchView;

/// 运行历史上限。
const MAX_RUN_HISTORY: usize = 50;

/// Run 输出保留上限（行），超出丢弃最旧。
const MAX_RUN_OUTPUT: usize = 2000;

/// Run 面板工程状态，对齐 Tauri RunPane 的 missing/ready/invalid 三态
/// （Linux 可用子集：invalid 统一为 `Failed` 并携带 core 错误文案）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RunProjectState {
    /// 无可运行配置（非 Java/Maven/npm 工程或配置为空）。
    Missing,
    /// 正在经 core 探测工程与配置。
    Loading,
    /// 配置列表可用。
    Ready,
    /// 探测失败，内附展示文案。
    Failed(String),
}

/// 上次 Maven 目标参数（头部重跑按钮回放，对齐 Tauri `rerunLastTest` 语义的子集）。
#[derive(Debug, Clone)]
struct MavenGoalParams {
    pom_path: String,
    goal: String,
    target: String,
    profiles: Vec<String>,
    skip_tests: bool,
}

/// Git 提交记录行数上限。
const MAX_GIT_LOG_ENTRIES: usize = 50;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BottomTab {
    Terminal,
    Run,
    Maven,
    Diagnostics,
    GitLog,
}

/// 诊断面板中的一条问题，字段与 Tauri DiagnosticsBuffer 的展示模型对齐。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DiagnosticEntry {
    pub severity: String,
    pub file_path: String,
    pub line: u32,
    pub column: u32,
    pub message: String,
    pub source: Option<String>,
    pub code: Option<String>,
}

/// 诊断面板向外发出的定位事件。
#[derive(Debug, Clone)]
pub enum BottomPanelEvent {
    OpenFile {
        path: String,
        line: u32,
    },
    /// 面板清空按钮：请求宿主同步丢弃缓存的 LSP 诊断。
    ClearDiagnostics,
}

/// Git 提交记录的一行：短 hash + 首行 message，只读展示不跳转。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct GitLogEntry {
    pub hash: String,
    pub message: String,
}

pub struct BottomPanelView {
    pub active_tab: BottomTab,
    pub is_collapsed: bool,
    pub height: f32,
    pub terminal: Entity<TerminalView>,
    pub diagnostics: Vec<DiagnosticEntry>,
    /// 终端工作目录；GitLog 面板取数时作为 `git -C` 目标。
    pub working_dir: String,
    /// 运行历史（`TerminalView::send_command` 被调用时由宿主经
    /// [`BottomPanelView::record_run`] 落入），上限 [`MAX_RUN_HISTORY`]。
    pub run_history: Vec<String>,
    /// Run 面板状态机（Tauri RunPane 的 Linux 可用子集）。
    pub(crate) run_state: RunProjectState,
    /// Run 面板工程展示名（工作区目录名）。
    pub(crate) run_project_name: String,
    /// Run 配置列表（Core resolve 的有效配置）。
    pub(crate) run_configs: Vec<RunConfigItem>,
    /// Core resolve 给出的默认配置 id。
    pub(crate) default_run_config: Option<String>,
    /// 选中的 Run 配置 id。
    pub(crate) selected_run_config: Option<String>,
    /// reload 尚未完成时，行内 Run 要在 ready 后启动的指定 id。
    pending_run_id: Option<String>,
    /// reload 完成后自动启动 Core 选出的配置。
    run_on_ready: bool,
    /// Run/配置加载诊断，按 Core 返回顺序展示。
    pub(crate) run_diagnostics: Vec<String>,
    /// 运行输出行（后台线程经 channel 推送，`cx.spawn` 泵入）。
    pub(crate) run_output: Vec<String>,
    /// 是否有 Run execution 在准备或运行。
    pub(crate) run_running: bool,
    /// 最近一次 Run 主进程退出码。
    pub(crate) run_exit_code: Option<i32>,
    /// 输出跟随末尾（对齐 Tauri `scrollOutputToEnd`，默认开，落盘持久化）。
    pub(crate) run_follow_end: bool,
    /// 运行输出滚动句柄（跟随末尾用）。
    run_scroll: ScrollHandle,
    /// 上次跟随到的输出行数（只在新增时滚动，避免无关重绘抢夺滚动条）。
    run_followed_len: usize,
    /// Maven 任务标题（对齐 Tauri `taskTitle`，如 `compile · pom.xml`）。
    pub(crate) maven_title: Option<String>,
    /// Maven 任务输出行（`$ mvn …` 开头，对齐 Tauri Maven 页）。
    pub(crate) maven_output: Vec<String>,
    /// Maven 任务是否在跑。
    pub(crate) maven_running: bool,
    /// core 客户端（`reload_run_project` / `createLaunchPlan` 经它走 core JSON 命令）。
    client: CoreClient,
    /// 工作台持有的 Java LSP owner；使用弱引用避免父子 Entity 循环。
    workbench: Option<WeakEntity<WorkbenchView>>,
    /// 所有 Run/Maven 子进程的 session/execution 所有者。
    processes: ProcessManager,
    /// Maven 启动序号，丢弃过期 `launchPlan` 结果。
    maven_seq: u64,
    /// 上次 Maven 目标参数（头部重跑按钮回放）。
    last_maven_goal: Option<MavenGoalParams>,
    /// reload 序号，丢弃过期探测结果。
    run_seq: u64,
    /// Run execution 序号，阻止被替换的 session 继续写输出。
    run_execution_seq: u64,
    /// 当前编辑器，Run 前用于保存脏文件。
    run_editor: Option<Entity<EditorView>>,
    /// 最近一次加载的 Git 提交记录。
    pub git_log: Vec<GitLogEntry>,
    /// Git 记录加载失败时的展示文案；成功后清空。
    pub git_log_error: Option<String>,
}

impl EventEmitter<BottomPanelEvent> for BottomPanelView {}

/// 等待 Workbench 轮询到指定 Core LSP 操作结果，并拒绝 workspace/session 替换。
async fn wait_for_lsp_operation(
    workbench: &Entity<WorkbenchView>,
    session_id: &str,
    operation_id: &str,
    timeout: Duration,
    run_guard: Option<(&Entity<BottomPanelView>, u64, u64)>,
    cx: &mut gpui_kit::AsyncApp,
) -> Result<serde_json::Value, String> {
    let deadline = Instant::now() + timeout;
    loop {
        if let Some((owner, reload_seq, execution_seq)) = run_guard {
            if !owner.read_with(cx, |view, _app| {
                view.is_current_run_execution(reload_seq, execution_seq)
            }) {
                return Err(
                    "Run was replaced or cancelled before Java preparation completed.".to_string(),
                );
            }
        }
        let status = workbench.read_with(cx, |workbench, _app| workbench.java_lsp_status());
        if status.session_id.as_deref() != Some(session_id) {
            return Err(
                "Java language-server session was replaced before the request completed."
                    .to_string(),
            );
        }
        if status.state == "failed" || status.state == "stopped" {
            return Err(status.error.unwrap_or_else(|| {
                "Java language-server session stopped before the request completed.".to_string()
            }));
        }
        if let Some(result) = workbench.update(cx, |workbench, _cx| {
            workbench.take_lsp_operation_result(session_id, operation_id)
        }) {
            return result;
        }
        if Instant::now() >= deadline {
            return Err(format!(
                "Java language-server request {operation_id} timed out after {} seconds.",
                timeout.as_secs()
            ));
        }
        cx.background_executor()
            .timer(Duration::from_millis(100))
            .await;
    }
}

async fn wait_for_java_entrypoints(
    workbench: &Entity<WorkbenchView>,
    client: &CoreClient,
    timeout: Duration,
    cx: &mut gpui_kit::AsyncApp,
) -> Result<Option<serde_json::Value>, String> {
    workbench.update(cx, |workbench, cx| workbench.ensure_java_lsp(cx));
    let deadline = Instant::now() + timeout;
    loop {
        let status = workbench.read_with(cx, |workbench, _app| workbench.java_lsp_status());
        if status.state == "failed" || status.state == "stopped" {
            return Ok(None);
        }
        if lsp::java_lsp_allows_run(&status) {
            let Some(session_id) = status.session_id else {
                return Err("Java language service became ready without a session id.".to_string());
            };
            let operation = client
                .execute::<serde_json::Value, serde_json::Value>(
                    cx,
                    "lsp.request",
                    lsp::java_entrypoints_request(&session_id),
                )
                .await?;
            let operation_id = operation
                .get("operationId")
                .and_then(serde_json::Value::as_str)
                .ok_or_else(|| {
                    "Java entrypoint request did not return an operationId.".to_string()
                })?;
            let result = wait_for_lsp_operation(
                workbench,
                &session_id,
                operation_id,
                Duration::from_secs(35),
                None,
                cx,
            )
            .await?;
            return lsp::parse_java_entrypoints(&result).map(Some);
        }
        if Instant::now() >= deadline {
            return Err(
                "Java language service did not reach a runnable project state before the configuration deadline."
                    .to_string(),
            );
        }
        cx.background_executor()
            .timer(Duration::from_millis(200))
            .await;
    }
}

async fn prepare_java_run_launch(
    workbench: &Entity<WorkbenchView>,
    client: &CoreClient,
    item: &RunConfigItem,
    root: &str,
    run_guard: (&Entity<BottomPanelView>, u64, u64),
    cx: &mut gpui_kit::AsyncApp,
) -> Result<(serde_json::Value, String), String> {
    let source_path = item
        .source
        .as_deref()
        .filter(|value| !value.trim().is_empty())
        .ok_or_else(|| "Java run configuration is missing its source path.".to_string())?;
    let configured_main = item.main_class.as_deref();
    let source_key = std::path::Path::new(source_path)
        .strip_prefix(root)
        .map(|path| path.to_string_lossy().replace('\\', "/"))
        .unwrap_or_else(|_| source_path.to_string());
    let source_for_build = lsp::absolute_path(root, source_path);
    workbench.update(cx, |workbench, cx| workbench.ensure_java_lsp(cx));
    let ready_deadline = Instant::now() + Duration::from_secs(10 * 60);
    let session_id = loop {
        if !run_guard.0.read_with(cx, |view, _app| {
            view.is_current_run_execution(run_guard.1, run_guard.2)
        }) {
            return Err(
                "Run was replaced or cancelled before Java preparation completed.".to_string(),
            );
        }
        let status = workbench.read_with(cx, |workbench, _app| workbench.java_lsp_status());
        if status.state == "failed" || status.state == "stopped" {
            return Err(status
                .error
                .unwrap_or_else(|| "Java language service is not ready.".to_string()));
        }
        if lsp::java_lsp_allows_run(&status) {
            if let Some(session_id) = status.session_id {
                break session_id;
            }
        }
        if Instant::now() >= ready_deadline {
            return Err(
                "Java language service did not reach ServiceReady before the run deadline."
                    .to_string(),
            );
        }
        cx.background_executor()
            .timer(Duration::from_millis(200))
            .await;
    };

    let entrypoints_operation = client
        .execute::<serde_json::Value, serde_json::Value>(
            cx,
            "lsp.request",
            lsp::java_entrypoints_request(&session_id),
        )
        .await?;
    let entrypoints_operation_id = entrypoints_operation
        .get("operationId")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| "Java entrypoint request did not return an operationId.".to_string())?;
    let entrypoints = lsp::parse_java_entrypoints(
        &wait_for_lsp_operation(
            workbench,
            &session_id,
            entrypoints_operation_id,
            Duration::from_secs(35),
            Some(run_guard),
            cx,
        )
        .await?,
    )?;
    let entrypoint = lsp::select_java_entrypoint(&entrypoints, &source_key, configured_main)?;
    let main_class = entrypoint
        .get("mainClass")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| "Java entrypoint result is missing mainClass.".to_string())?;
    let project_name = entrypoint
        .get("projectName")
        .and_then(serde_json::Value::as_str)
        .map(str::to_string);

    let build_operation = client
        .execute::<serde_json::Value, serde_json::Value>(
            cx,
            "lsp.request",
            lsp::java_build_request(
                &session_id,
                &source_for_build,
                main_class,
                project_name.as_deref(),
            ),
        )
        .await?;
    let build_operation_id = build_operation
        .get("operationId")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| "Java build request did not return an operationId.".to_string())?;
    let build_result = wait_for_lsp_operation(
        workbench,
        &session_id,
        build_operation_id,
        Duration::from_secs(10 * 60),
        Some(run_guard),
        cx,
    )
    .await;
    let build_error = match &build_result {
        Ok(value) => lsp::parse_java_build_result(value).err(),
        Err(error) => Some(error.clone()),
    };

    let classpath_operation = client
        .execute::<serde_json::Value, serde_json::Value>(
            cx,
            "lsp.request",
            lsp::java_classpath_request(&session_id, main_class, project_name.as_deref()),
        )
        .await?;
    let classpath_operation_id = classpath_operation
        .get("operationId")
        .and_then(serde_json::Value::as_str)
        .ok_or_else(|| "Java classpath request did not return an operationId.".to_string())?;
    let classpath = match wait_for_lsp_operation(
        workbench,
        &session_id,
        classpath_operation_id,
        Duration::from_secs(35),
        Some(run_guard),
        cx,
    )
    .await
    {
        Ok(value) => value,
        Err(error) => {
            if let Some(build_error) = &build_error {
                return Err(format!(
                    "Java project build failed: {build_error}; runtime classpath resolution failed: {error}"
                ));
            }
            return Err(error);
        }
    };
    let launch = match lsp::java_launch_payload(&entrypoint, &classpath) {
        Ok(launch) => launch,
        Err(error) => {
            if let Some(build_error) = &build_error {
                return Err(format!(
                    "Java project build failed: {build_error}; runtime classpath result was invalid: {error}"
                ));
            }
            return Err(error);
        }
    };
    if let Some(error) = build_error {
        return Err(format!("Java project build failed: {error}"));
    }
    Ok((launch, session_id))
}

impl BottomPanelView {
    pub fn new(working_dir: String, cx: &mut Context<Self>) -> Self {
        let terminal = cx.new(|cx| TerminalView::new(working_dir.clone(), cx));

        Self {
            active_tab: BottomTab::Terminal,
            is_collapsed: true,
            height: 240.0,
            terminal,
            diagnostics: Vec::new(),
            working_dir: working_dir.clone(),
            run_history: Vec::new(),
            run_state: RunProjectState::Missing,
            run_project_name: crate::settings::project_dir_name(&working_dir).to_string(),
            run_configs: Vec::new(),
            default_run_config: None,
            selected_run_config: None,
            pending_run_id: None,
            run_on_ready: false,
            run_diagnostics: Vec::new(),
            run_output: Vec::new(),
            run_running: false,
            run_exit_code: None,
            run_follow_end: crate::settings::get(cx).run_scroll_to_end,
            run_scroll: ScrollHandle::new(),
            run_followed_len: 0,
            maven_title: None,
            maven_output: Vec::new(),
            maven_running: false,
            client: CoreClient::new(),
            workbench: None,
            processes: ProcessManager::new(),
            maven_seq: 0,
            last_maven_goal: None,
            run_seq: 0,
            run_execution_seq: 0,
            run_editor: None,
            git_log: Vec::new(),
            git_log_error: None,
        }
    }

    pub fn is_visible(&self) -> bool {
        !self.is_collapsed
    }

    fn render_diagnostics_panel(&self, cx: &mut Context<Self>) -> AnyElement {
        if self.diagnostics.is_empty() {
            return div()
                .size_full()
                .flex()
                .items_center()
                .justify_center()
                .text_xs()
                .text_color(ThemeColors::text_muted())
                .child(crate::i18n::menu_text(cx, "diagnostics.empty").to_string())
                .into_any_element();
        }

        let rows: Vec<AnyElement> = self
            .diagnostics
            .iter()
            .enumerate()
            .map(|(index, diagnostic)| {
                let location = format!(
                    "{}:{}:{}",
                    diagnostic.file_path,
                    diagnostic.line + 1,
                    diagnostic.column + 1
                );
                let source = diagnostic
                    .source
                    .as_deref()
                    .unwrap_or("diagnostic")
                    .to_string();
                let path = diagnostic.file_path.clone();
                let line = diagnostic.line + 1;
                let severity_color = match diagnostic.severity.as_str() {
                    "error" => ThemeColors::destructive(),
                    "warning" => ThemeColors::warning(),
                    _ => ThemeColors::accent_blue(),
                };
                h_flex()
                    .id(format!("diagnostic-{index}"))
                    .w_full()
                    .items_start()
                    .gap_2()
                    .px_3()
                    .py_2()
                    .cursor_pointer()
                    .hover(|row| row.bg(ThemeColors::accent()))
                    .child(
                        div()
                            .text_xs()
                            .font_weight(FontWeight::BOLD)
                            .text_color(severity_color)
                            .child(diagnostic.severity.clone()),
                    )
                    .child(
                        v_flex()
                            .flex_1()
                            .min_w_0()
                            .gap_1()
                            .child(
                                div()
                                    .text_xs()
                                    .text_color(ThemeColors::text_primary())
                                    .child(diagnostic.message.clone()),
                            )
                            .child(
                                div()
                                    .text_xs()
                                    .text_color(ThemeColors::text_muted())
                                    .child(format!("{location} · {source}")),
                            ),
                    )
                    .on_click(cx.listener(move |_this, _event, _window, cx| {
                        cx.emit(BottomPanelEvent::OpenFile {
                            path: path.clone(),
                            line,
                        });
                    }))
                    .into_any_element()
            })
            .collect();

        div()
            .size_full()
            .overflow_y_scrollbar()
            .children(rows)
            .into_any_element()
    }

    pub fn set_height(&mut self, height: f32, cx: &mut Context<Self>) {
        self.height = height;
        cx.notify();
    }

    pub fn set_tab(&mut self, tab: BottomTab, cx: &mut Context<Self>) {
        self.active_tab = tab;
        self.is_collapsed = false;
        if tab == BottomTab::GitLog {
            // 打开即刷新提交记录；refresh_git_log 内已 notify。
            self.refresh_git_log(cx);
            return;
        }
        if tab == BottomTab::Run {
            // 打开即重探 Run 工程；reload_run_project 内已 notify。
            self.reload_run_project(cx);
            return;
        }
        cx.notify();
    }

    /// 用最新一轮 LSP 诊断替换面板内容；顺序与 [`crate::lsp`] 投影一致。
    pub fn set_diagnostics(&mut self, diagnostics: Vec<DiagnosticEntry>, cx: &mut Context<Self>) {
        self.diagnostics = diagnostics;
        cx.notify();
    }

    pub fn toggle_collapsed(&mut self, cx: &mut Context<Self>) {
        self.is_collapsed = !self.is_collapsed;
        cx.notify();
    }

    /// 记录一次运行命令；空命令忽略，超出上限丢弃最旧记录。
    /// 宿主在转调 `TerminalView::send_command` 时调用。
    pub fn record_run(&mut self, cmd: &str, cx: &mut Context<Self>) {
        let cmd = cmd.trim();
        if cmd.is_empty() {
            return;
        }
        self.run_history.push(cmd.to_string());
        if self.run_history.len() > MAX_RUN_HISTORY {
            let overflow = self.run_history.len() - MAX_RUN_HISTORY;
            self.run_history.drain(..overflow);
        }
        cx.notify();
    }

    /// 更新工作目录并重探 Run 工程（替代直接写 `working_dir` 字段）。
    pub fn set_working_dir(&mut self, dir: String, cx: &mut Context<Self>) {
        let _ = self.processes.request_stop("run", None);
        self.maven_seq += 1;
        let _ = self.processes.request_stop("maven", None);
        self.maven_running = false;
        self.pending_run_id = None;
        self.run_on_ready = false;
        self.working_dir = dir;
        self.reload_run_project(cx);
    }

    /// 设置 Run 前需要保存的编辑器实体。
    pub fn set_run_editor(&mut self, editor: Option<Entity<EditorView>>, cx: &mut Context<Self>) {
        self.run_editor = editor;
        cx.notify();
    }

    /// 设置工作台 Java LSP owner。Run 不直接创建第二个 JDT session。
    pub fn set_workbench(&mut self, workbench: Entity<WorkbenchView>, cx: &mut Context<Self>) {
        self.workbench = Some(workbench.downgrade());
        cx.notify();
    }

    /// 重探 Run 工程：先 inspect，再按需 generate，随后持久化并 resolve。
    pub fn reload_run_project(&mut self, cx: &mut Context<Self>) {
        self.run_seq += 1;
        self.run_execution_seq += 1;
        let seq = self.run_seq;
        if self.run_running {
            let _ = self.processes.request_stop("run", None);
            self.run_running = false;
        }
        self.run_project_name = crate::settings::project_dir_name(&self.working_dir).to_string();
        self.run_configs.clear();
        self.default_run_config = None;
        self.selected_run_config = None;
        self.run_diagnostics.clear();
        self.run_state = RunProjectState::Loading;
        cx.notify();

        let client = self.client.clone();
        let root = self.working_dir.clone();
        let workbench = self.workbench.as_ref().and_then(WeakEntity::upgrade);
        cx.spawn(async move |this, cx| {
            let inspection = client
                .execute::<serde_json::Value, serde_json::Value>(
                    &cx,
                    "runConfig.inspect",
                    serde_json::json!({ "root": root, "checkFingerprint": true }),
                )
                .await;
            let inspection = match inspection {
                Ok(value) => value,
                Err(error) => {
                    let _ = this.update(cx, |view, cx| {
                        if view.run_seq == seq {
                            view.run_state = RunProjectState::Failed(error);
                            cx.notify();
                        }
                    });
                    return;
                }
            };
            let status = inspection
                .get("status")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("missing");
            let inspection_diagnostics = inspection
                .get("diagnostics")
                .and_then(serde_json::Value::as_array)
                .map(|items| {
                    items
                        .iter()
                        .filter_map(|item| {
                            item.get("message")
                                .and_then(serde_json::Value::as_str)
                                .map(str::to_string)
                        })
                        .collect::<Vec<_>>()
                })
                .unwrap_or_default();
            let inspection_diagnostics = if status == "ready" {
                inspection_diagnostics
            } else {
                Vec::new()
            };
            if status != "ready" {
                let paths = list_java_sources(&root);
                let java_entrypoints = if paths.is_empty() {
                    None
                } else if let Some(workbench) = workbench.as_ref() {
                    match wait_for_java_entrypoints(
                        workbench,
                        &client,
                        Duration::from_secs(10 * 60),
                        cx,
                    )
                    .await
                    {
                        Ok(value) => value,
                        Err(error) => {
                            let _ = this.update(cx, |view, cx| {
                                if view.run_seq == seq {
                                    view.run_state = RunProjectState::Failed(error);
                                    cx.notify();
                                }
                            });
                            return;
                        }
                    }
                } else {
                    None
                };
                let mut generate_payload = serde_json::json!({
                    "root": root,
                    "paths": paths,
                    "modulePaths": []
                });
                if let Some(entrypoints) = java_entrypoints {
                    generate_payload["javaEntrypoints"] = entrypoints;
                }
                let generated = client
                    .execute::<serde_json::Value, serde_json::Value>(
                        &cx,
                        "runConfig.generate",
                        generate_payload,
                    )
                    .await;
                let generated = match generated {
                    Ok(value) => value,
                    Err(error) => {
                        let _ = this.update(cx, |view, cx| {
                            if view.run_seq == seq {
                                view.run_state = RunProjectState::Failed(error);
                                cx.notify();
                            }
                        });
                        return;
                    }
                };
                if !this
                    .update(cx, |view, _cx| view.run_seq == seq)
                    .unwrap_or(false)
                {
                    return;
                }
                let generated_document = generated.get("generated").cloned().unwrap_or_default();
                let requirements = generated
                    .get("toolchainRequirements")
                    .cloned()
                    .unwrap_or_else(|| serde_json::json!({"version": 1, "toolchains": {}}));
                let default_id = default_generated_configuration_id(&generated_document);
                if let Err(error) = write_generated_documents(
                    &root,
                    &generated_document,
                    &requirements,
                    default_id.as_deref(),
                ) {
                    let _ = this.update(cx, |view, cx| {
                        if view.run_seq == seq {
                            view.run_state = RunProjectState::Failed(error);
                            cx.notify();
                        }
                    });
                    return;
                }
                if !this
                    .update(cx, |view, _cx| view.run_seq == seq)
                    .unwrap_or(false)
                {
                    return;
                }
            }

            let toolchains = read_toolchain_paths(&root);
            let candidates = toolchain_candidates(&root, &toolchains);
            let resolved = client
                .execute::<serde_json::Value, serde_json::Value>(
                    &cx,
                    "runConfig.resolve",
                    serde_json::json!({
                        "root": root,
                        "toolchainCandidates": candidates
                    }),
                )
                .await;
            let resolved = match resolved {
                Ok(value) => value,
                Err(error) => {
                    let _ = this.update(cx, |view, cx| {
                        if view.run_seq == seq {
                            view.run_state = RunProjectState::Failed(error);
                            cx.notify();
                        }
                    });
                    return;
                }
            };
            let parsed = match parse_resolved_configurations(&resolved) {
                Ok(value) => value,
                Err(error) => {
                    let _ = this.update(cx, |view, cx| {
                        if view.run_seq == seq {
                            view.run_state = RunProjectState::Failed(error);
                            cx.notify();
                        }
                    });
                    return;
                }
            };
            let launch = this.update(cx, |view, cx| {
                if view.run_seq != seq {
                    return None;
                }
                view.run_configs = parsed.configurations;
                view.default_run_config = parsed.default_configuration_id.clone();
                view.run_diagnostics = inspection_diagnostics.clone();
                view.run_diagnostics.extend(parsed.diagnostics.clone());
                view.run_diagnostics.dedup();
                let selected = view
                    .pending_run_id
                    .clone()
                    .filter(|id| view.run_configs.iter().any(|item| &item.id == id))
                    .or_else(|| parsed.default_configuration_id.clone())
                    .or_else(|| view.run_configs.first().map(|item| item.id.clone()));
                view.selected_run_config = selected.clone();
                view.run_state = if view.run_configs.is_empty() {
                    RunProjectState::Missing
                } else {
                    RunProjectState::Ready
                };
                let should_launch = view.run_on_ready || view.pending_run_id.is_some();
                view.run_on_ready = false;
                cx.notify();
                let launch_id = view
                    .pending_run_id
                    .take()
                    .or_else(|| should_launch.then(|| selected.clone()).flatten());
                launch_id.and_then(|id| view.run_configs.iter().find(|item| item.id == id).cloned())
            });
            if let Ok(Some(item)) = launch {
                let _ = this.update(cx, |view, cx| view.start_run(item, cx));
            }
        })
        .detach();
    }

    /// 顶部 Run 只在当前 reload 结果 ready 后使用默认/当前选择。
    pub fn run_selected_config(&mut self, cx: &mut Context<Self>) {
        if self.run_running {
            self.stop_running(cx);
            return;
        }
        if !matches!(self.run_state, RunProjectState::Ready) {
            self.run_on_ready = true;
            if !matches!(self.run_state, RunProjectState::Loading) {
                self.reload_run_project(cx);
            } else {
                cx.notify();
            }
            return;
        }
        if let Some(item) = self.selected_run_item() {
            self.start_run(item, cx);
        } else {
            self.run_on_ready = true;
            self.reload_run_project(cx);
        }
    }

    /// 行内 Run 永远携带用户指定的配置 id；配置尚未 ready 时等待 reload。
    pub fn run_configuration_id(&mut self, id: String, cx: &mut Context<Self>) {
        if self.run_running {
            return;
        }
        self.pending_run_id = Some(id.clone());
        self.selected_run_config = Some(id.clone());
        self.run_on_ready = true;
        if matches!(self.run_state, RunProjectState::Ready)
            && self.run_configs.iter().any(|item| item.id == id)
        {
            self.pending_run_id = None;
            self.run_on_ready = false;
            if let Some(item) = self.run_configs.iter().find(|item| item.id == id).cloned() {
                self.start_run(item, cx);
            }
        } else if !matches!(self.run_state, RunProjectState::Loading) {
            self.reload_run_project(cx);
        } else {
            cx.notify();
        }
    }

    fn start_run(&mut self, item: RunConfigItem, cx: &mut Context<Self>) {
        if self.run_running {
            return;
        }
        self.run_execution_seq += 1;
        let execution_seq = self.run_execution_seq;
        self.run_running = true;
        self.run_exit_code = None;
        push_run_line(
            &mut self.run_output,
            format!(
                "{}：{}",
                crate::i18n::menu_text(cx, "run.starting"),
                item.name
            ),
        );
        if Self::needs_java_project_preparation(&item) {
            push_run_line(
                &mut self.run_output,
                run_ui_text(
                    cx,
                    "等待 Java 语言服务完成项目准备…",
                    "Waiting for Java language service preparation…",
                ),
            );
        }
        cx.notify();
        let launch_seq = self.run_seq;
        let launch_execution_seq = execution_seq;
        let client = self.client.clone();
        let root = self.working_dir.clone();
        let editor = self.run_editor.clone();
        let workbench = self.workbench.as_ref().and_then(WeakEntity::upgrade);
        let processes = self.processes.clone();
        cx.spawn(async move |this, cx| {
            let run_owner = this.upgrade().expect("Run owner must remain alive while preparing");
            if let Some(editor) = editor.as_ref() {
                let save = editor.update(cx, |editor, cx| editor.save_active_task(cx));
                if let Err(error) = save.await {
                    let _ = this.update(cx, |view, cx| {
                        if view.is_current_run_execution(launch_seq, launch_execution_seq) {
                            view.run_running = false;
                            push_run_line(&mut view.run_output, error);
                            cx.notify();
                        }
                    });
                    return;
                }
            }
            if this
                .update(cx, |view, _cx| {
                    !view.is_current_run_execution(launch_seq, launch_execution_seq)
                })
                .unwrap_or(true)
            {
                return;
            }
            let current_file = editor
                .as_ref()
                .and_then(|editor| editor.update(cx, |editor, _cx| editor.active_file_path()));
            let current_file = current_file.and_then(|path| workspace_relative_path(&root, &path));
            let mut toolchains = read_toolchain_paths(&root);
            if let Some(path) = item.java_home_path() {
                toolchains.java_home_path = path.to_string();
            }
            if let Some(path) = item.maven_executable_path() {
                toolchains.maven_executable_path = path.to_string();
            }
            if let Some(path) = item.maven_java_home_path() {
                toolchains.maven_java_home_path = path.to_string();
            }
            let maven_context = item
                .uses_maven()
                .then(|| maven_context_for_configuration(&item, &toolchains));
            let java_launch = if Self::needs_java_project_preparation(&item) {
                match workbench.as_ref() {
                    Some(workbench) => {
                        prepare_java_run_launch(
                            workbench,
                            &client,
                            &item,
                            &root,
                            (&run_owner, launch_seq, launch_execution_seq),
                            cx,
                        )
                        .await
                        .map(Some)
                    }
                    None => Err(
                        "Java language service is unavailable because the workbench owner is missing."
                            .to_string(),
                    ),
                }
            } else {
                Ok(None)
            };
            let java_launch = match java_launch {
                Ok(value) => value,
                Err(error) => {
                    let _ = this.update(cx, |view, cx| {
                        if view.is_current_run_execution(launch_seq, launch_execution_seq) {
                            view.run_running = false;
                            view.run_exit_code = Some(1);
                            view.run_diagnostics.push(error.clone());
                            view.run_diagnostics.dedup();
                            push_run_line(&mut view.run_output, error);
                            cx.notify();
                        }
                    });
                    return;
                }
            };
            if let (Some((_, session_id)), Some(workbench)) =
                (java_launch.as_ref(), workbench.as_ref())
            {
                let current_session = workbench
                    .read_with(cx, |workbench, _app| workbench.java_lsp_status())
                    .session_id;
                if current_session.as_deref() != Some(session_id.as_str()) {
                    let error = "Java language-server session changed before launch planning.";
                    let _ = this.update(cx, |view, cx| {
                        if view.is_current_run_execution(launch_seq, launch_execution_seq) {
                            view.run_running = false;
                            view.run_exit_code = Some(1);
                            view.run_diagnostics.push(error.to_string());
                            push_run_line(&mut view.run_output, error.to_string());
                            cx.notify();
                        }
                    });
                    return;
                }
            }
            let payload = create_launch_plan_request(
                &root,
                &item,
                current_file.as_deref(),
                maven_context.as_ref(),
                java_launch.as_ref().map(|(value, _)| value),
            );
            let plan = client
                .execute::<serde_json::Value, serde_json::Value>(
                    &cx,
                    "runConfig.createLaunchPlan",
                    payload,
                )
                .await;
            if this
                .update(cx, |view, _cx| {
                    !view.is_current_run_execution(launch_seq, launch_execution_seq)
                })
                .unwrap_or(true)
            {
                return;
            }
            let plan = match plan {
                Ok(value) => value,
                Err(error) => {
                    let _ = this.update(cx, |view, cx| {
                        if view.is_current_run_execution(launch_seq, launch_execution_seq) {
                            view.run_running = false;
                            push_run_line(&mut view.run_output, error);
                            cx.notify();
                        }
                    });
                    return;
                }
            };
            let plan = match LaunchPlan::from_value(&plan) {
                Ok(plan) => plan,
                Err(error) => {
                    let _ = this.update(cx, |view, cx| {
                        if view.is_current_run_execution(launch_seq, launch_execution_seq) {
                            view.run_running = false;
                            push_run_line(&mut view.run_output, error);
                            cx.notify();
                        }
                    });
                    return;
                }
            };
            let (steps, _main) =
                match crate::workbench::run::process::resolve_launch(&plan, &root, &toolchains) {
                    Ok(value) => value,
                    Err(error) => {
                        let _ = this.update(cx, |view, cx| {
                            if view.is_current_run_execution(launch_seq, launch_execution_seq) {
                                view.run_running = false;
                                push_run_line(&mut view.run_output, error);
                                cx.notify();
                            }
                        });
                        return;
                    }
                };
            if this
                .update(cx, |view, _cx| {
                    !view.is_current_run_execution(launch_seq, launch_execution_seq)
                })
                .unwrap_or(true)
            {
                return;
            }
            let execution_id = uuid::Uuid::new_v4().to_string();
            let (sender, receiver) = mpsc::channel::<ProcessEvent>();
            let handle = match processes.start("run", &execution_id, steps, sender) {
                Ok(handle) => handle,
                Err(error) => {
                    let _ = this.update(cx, |view, cx| {
                        if view.is_current_run_execution(launch_seq, launch_execution_seq) {
                            view.run_running = false;
                            push_run_line(&mut view.run_output, error);
                            cx.notify();
                        }
                    });
                    return;
                }
            };
            let receiver = std::sync::Arc::new(std::sync::Mutex::new(receiver));
            loop {
                let slot = receiver.clone();
                let event = cx
                    .background_executor()
                    .spawn(async move {
                        let guard = slot.lock().ok()?;
                        Some(
                            match guard.recv_timeout(std::time::Duration::from_secs(1)) {
                                Ok(event) => Ok(event),
                                Err(error) => Err(error),
                            },
                        )
                    })
                    .await;
                let event = match event {
                    Some(Ok(event)) => event,
                    Some(Err(mpsc::RecvTimeoutError::Timeout)) => continue,
                    Some(Err(mpsc::RecvTimeoutError::Disconnected)) | None => break,
                };
                let finished = matches!(&event, ProcessEvent::Finished { .. });
                let stale = this
                    .update(cx, |view, _cx| {
                        !view.is_current_run_execution(launch_seq, launch_execution_seq)
                    })
                    .unwrap_or(true);
                if stale {
                    let _ = processes.stop("run", Some(&execution_id));
                    break;
                }
                let _ = this.update(cx, |view, cx| match event {
                    ProcessEvent::Started {
                        index: _index,
                        label,
                    } => {
                        push_run_line(&mut view.run_output, label.clone());
                        view.record_run(&label, cx);
                        cx.notify();
                    }
                    ProcessEvent::Output { stream, text } => {
                        let text = if stream == OutputStream::Stderr {
                            format!("[stderr] {text}")
                        } else {
                            text
                        };
                        push_run_line(&mut view.run_output, text);
                        cx.notify();
                    }
                    ProcessEvent::Finished {
                        exit_code,
                        cancelled,
                        error,
                    } => {
                        if let Some(error) = error {
                            push_run_line(&mut view.run_output, error);
                        }
                        let exit_code = exit_code.or_else(|| Some(1));
                        if cancelled {
                            push_run_line(
                                &mut view.run_output,
                                crate::i18n::menu_text(cx, "run.finished").to_string(),
                            );
                        } else {
                            push_run_line(
                                &mut view.run_output,
                                format!(
                                    "{}：{}",
                                    crate::i18n::menu_text(cx, "run.exited"),
                                    exit_code.unwrap_or(1)
                                ),
                            );
                        }
                        view.run_exit_code = exit_code;
                        view.run_running = false;
                        cx.notify();
                    }
                });
                if finished {
                    break;
                }
            }
            let _ = handle.join();
        })
        .detach();
    }

    /// 停止在跑进程；ProcessManager 异步终止完整进程树并在输出泵中回收。
    pub fn stop_running(&mut self, cx: &mut Context<Self>) {
        let mut stopped = false;
        if self.run_running {
            self.run_execution_seq += 1;
            let _ = self.processes.request_stop("run", None);
            push_run_line(
                &mut self.run_output,
                crate::i18n::menu_text(cx, "run.stopping").to_string(),
            );
            self.run_running = false;
            stopped = true;
        }
        if self.maven_running {
            self.maven_seq += 1;
            let _ = self.processes.request_stop("maven", None);
            push_run_line(
                &mut self.maven_output,
                crate::i18n::menu_text(cx, "run.stopping").to_string(),
            );
            self.maven_running = false;
            stopped = true;
        }
        if stopped {
            cx.notify();
        }
    }
    /// 是否发生过 Maven 运行；宿主据此决定左侧栏是否展示 maven 项
    ///（对齐 Tauri `hasMavenRun`：任务跑过即真，与终端历史无关）。
    pub fn has_maven_run(&self) -> bool {
        self.maven_running || !self.maven_output.is_empty()
    }

    /// 运行 Maven 目标：Core 生成计划，Linux 只解析工具链并托管进程。
    pub fn run_maven_goal(
        &mut self,
        pom_path: &str,
        goal: &str,
        target: &str,
        profiles: &[String],
        skip_tests: bool,
        cx: &mut Context<Self>,
    ) {
        let goal = goal.trim().to_string();
        if goal.is_empty() {
            return;
        }
        if self.maven_running {
            let _ = self.processes.request_stop("maven", None);
        }
        self.maven_seq += 1;
        let seq = self.maven_seq;
        let title = format!("{goal} · {target}");
        self.last_maven_goal = Some(MavenGoalParams {
            pom_path: pom_path.to_string(),
            goal: goal.clone(),
            target: target.to_string(),
            profiles: profiles.to_vec(),
            skip_tests,
        });
        self.active_tab = BottomTab::Maven;
        self.is_collapsed = false;
        self.maven_title = Some(title);
        self.maven_output.clear();
        self.maven_running = true;
        cx.notify();

        let client = self.client.clone();
        let root = self.working_dir.clone();
        let module = maven_module_for_pom(&self.working_dir, pom_path);
        let profiles = profiles.to_vec();
        let processes = self.processes.clone();
        cx.spawn(async move |this, cx| {
            let plan = client
                .execute::<serde_json::Value, serde_json::Value>(
                    &cx,
                    "maven.launchPlan",
                    serde_json::json!({
                        "root": root,
                        "context": {
                            "version": 1,
                            "reactorPath": ".",
                            "profiles": profiles,
                            "skipTests": skip_tests,
                        },
                        "module": module,
                        "goals": [goal],
                    }),
                )
                .await;
            if this
                .update(cx, |view, _cx| view.maven_seq != seq)
                .unwrap_or(true)
            {
                return;
            }
            let plan = match plan {
                Ok(value) => value,
                Err(error) => {
                    let _ = this.update(cx, |view, cx| {
                        if view.maven_seq == seq {
                            view.maven_running = false;
                            push_run_line(&mut view.maven_output, error);
                            cx.notify();
                        }
                    });
                    return;
                }
            };
            let plan = match LaunchPlan::from_value(&plan) {
                Ok(plan) => plan,
                Err(error) => {
                    let _ = this.update(cx, |view, cx| {
                        if view.maven_seq == seq {
                            view.maven_running = false;
                            push_run_line(&mut view.maven_output, error);
                            cx.notify();
                        }
                    });
                    return;
                }
            };
            let toolchains = read_toolchain_paths(&root);
            let (steps, _main) =
                match crate::workbench::run::process::resolve_launch(&plan, &root, &toolchains) {
                    Ok(value) => value,
                    Err(error) => {
                        let _ = this.update(cx, |view, cx| {
                            if view.maven_seq == seq {
                                view.maven_running = false;
                                push_run_line(&mut view.maven_output, error);
                                cx.notify();
                            }
                        });
                        return;
                    }
                };
            if this
                .update(cx, |view, _cx| view.maven_seq != seq)
                .unwrap_or(true)
            {
                return;
            }
            let execution_id = uuid::Uuid::new_v4().to_string();
            let (sender, receiver) = mpsc::channel::<ProcessEvent>();
            let handle = match processes.start("maven", &execution_id, steps, sender) {
                Ok(handle) => handle,
                Err(error) => {
                    let _ = this.update(cx, |view, cx| {
                        if view.maven_seq == seq {
                            view.maven_running = false;
                            push_run_line(&mut view.maven_output, error);
                            cx.notify();
                        }
                    });
                    return;
                }
            };
            let receiver = std::sync::Arc::new(std::sync::Mutex::new(receiver));
            loop {
                let slot = receiver.clone();
                let event = cx
                    .background_executor()
                    .spawn(async move {
                        let guard = slot.lock().ok()?;
                        Some(
                            match guard.recv_timeout(std::time::Duration::from_secs(1)) {
                                Ok(event) => Ok(event),
                                Err(error) => Err(error),
                            },
                        )
                    })
                    .await;
                let event = match event {
                    Some(Ok(event)) => event,
                    Some(Err(mpsc::RecvTimeoutError::Timeout)) => continue,
                    Some(Err(mpsc::RecvTimeoutError::Disconnected)) | None => break,
                };
                let finished = matches!(&event, ProcessEvent::Finished { .. });
                let _ = this.update(cx, |view, cx| {
                    if view.maven_seq != seq {
                        return;
                    }
                    match event {
                        ProcessEvent::Started { label, .. } => {
                            push_run_line(&mut view.maven_output, label.clone());
                            view.record_run(&label, cx);
                        }
                        ProcessEvent::Output { text, .. } => {
                            push_run_line(&mut view.maven_output, text);
                        }
                        ProcessEvent::Finished {
                            exit_code,
                            cancelled,
                            error,
                        } => {
                            if let Some(error) = error {
                                push_run_line(&mut view.maven_output, error);
                            }
                            if let Some(code) = exit_code {
                                push_run_line(
                                    &mut view.maven_output,
                                    format!(
                                        "{}：{}",
                                        crate::i18n::menu_text(cx, "run.exited"),
                                        code
                                    ),
                                );
                            } else if cancelled {
                                push_run_line(
                                    &mut view.maven_output,
                                    crate::i18n::menu_text(cx, "run.finished").to_string(),
                                );
                            }
                            view.maven_running = false;
                        }
                    }
                    cx.notify();
                });
                if finished {
                    break;
                }
            }
            let _ = handle.join();
        })
        .detach();
    }

    /// 重跑上次 Maven 目标（头部重跑按钮，对齐 Tauri `rerunLastTest` 语义的子集：
    /// Linux 无测试会话跟踪，重跑即以上次参数再跑一次）。
    pub fn rerun_maven(&mut self, cx: &mut Context<Self>) {
        if self.maven_running {
            return;
        }
        if let Some(last) = self.last_maven_goal.clone() {
            self.run_maven_goal(
                &last.pom_path,
                &last.goal,
                &last.target,
                &last.profiles,
                last.skip_tests,
                cx,
            );
        }
    }

    /// 判断配置是否必须由 JDT/Core 准备项目运行时路径。
    pub fn needs_java_project_preparation(item: &RunConfigItem) -> bool {
        let has_target = item
            .source
            .as_deref()
            .is_some_and(|source| !source.trim().is_empty())
            && item
                .main_class
                .as_deref()
                .is_some_and(|main| !main.trim().is_empty());
        has_target
            && (item.toolchains.contains_key("maven")
                || item.provider == "spring-boot.maven"
                || item.provider == "maven.module")
            && (item.provider == "java.main" || item.provider == "spring-boot.maven")
    }

    fn is_current_run_execution(&self, reload_seq: u64, execution_seq: u64) -> bool {
        sequence_is_current(self.run_seq, reload_seq)
            && sequence_is_current(self.run_execution_seq, execution_seq)
    }

    /// 当前选中项只按稳定 id 查找，不在 reload 后回退到旧列表。
    fn selected_run_item(&self) -> Option<RunConfigItem> {
        self.selected_run_config
            .as_deref()
            .and_then(|id| self.run_configs.iter().find(|item| item.id == id).cloned())
    }

    /// 重新加载 Git 提交记录。core 的 `git.historyPage` 需经宿主异步接线，
    /// 这里用 `git -C <working_dir> log --oneline -50` 同步退化实现，
    /// 解析 hash + 首行 message 只读展示。
    pub fn refresh_git_log(&mut self, cx: &mut Context<Self>) {
        match load_git_log(&self.working_dir) {
            Ok(entries) => {
                self.git_log = entries;
                self.git_log_error = None;
            }
            Err(err) => {
                self.git_log.clear();
                self.git_log_error = Some(err);
            }
        }
        cx.notify();
    }

    /// 占位日志入口：Tauri 没有通用 Output 面板，各业务接线后改走各自面板，
    /// 当前仅保留调用点可编译，不存储不展示。
    pub fn append_log(&mut self, _log: String, _cx: &mut Context<Self>) {}

    /// 窗格通用头部：图标 + 标题 + 状态区 + 操作按钮 + 最小化，
    /// 对齐 Tauri 各窗格自带按钮头（底部无标签切换条，切换只走左侧活动栏）。
    fn render_pane_header(
        &self,
        icon: IconName,
        title: String,
        status: Option<AnyElement>,
        buttons: Vec<AnyElement>,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        h_flex()
            .h(px(30.0))
            .w_full()
            .flex_shrink_0()
            .bg(ThemeColors::bg_tab_bar())
            .border_b_1()
            .border_color(ThemeColors::border())
            .items_center()
            .gap_1()
            .px_2()
            .child(
                Icon::new(icon)
                    .size(px(14.0))
                    .text_color(ThemeColors::text_muted()),
            )
            .child(
                div()
                    .flex_1()
                    .truncate()
                    .text_xs()
                    .font_weight(FontWeight::BOLD)
                    .text_color(ThemeColors::text_primary())
                    .child(title),
            )
            .when_some(status, |el, status| el.child(status))
            .children(buttons)
            .child(
                Button::new("pane-minimize")
                    .small()
                    .ghost()
                    .icon(IconName::Minus)
                    .tooltip(crate::i18n::menu_text(cx, "run.minimize"))
                    .on_click(cx.listener(|this, _event, _window, cx| {
                        this.toggle_collapsed(cx);
                    })),
            )
            .into_any_element()
    }

    /// 最小化之外的头部操作按钮（小幽灵图标按钮 + tooltip）。
    fn header_button(
        id: String,
        icon: IconName,
        tooltip: String,
        disabled: bool,
        cx: &mut Context<Self>,
        on_click: impl Fn(&mut Self, &mut Window, &mut Context<Self>) + 'static,
    ) -> AnyElement {
        Button::new(id)
            .small()
            .ghost()
            .icon(icon)
            .tooltip(tooltip)
            .disabled(disabled)
            .on_click(cx.listener(move |this, _event, window, cx| {
                on_click(this, window, cx);
            }))
            .into_any_element()
    }

    /// Run 窗格头部：运行/停止 + 重扫 + 跟随末尾 + 清空 + 最小化
    ///（对齐 Tauri RunPane 头）。
    fn render_run_header(&self, cx: &mut Context<Self>) -> AnyElement {
        let running = self.run_running;
        let status = running.then(|| {
            div()
                .text_xs()
                .text_color(ThemeColors::accent_green())
                .child(crate::i18n::menu_text(cx, "run.running"))
                .into_any_element()
        });
        let title = format!(
            "{} {}",
            crate::i18n::menu_text(cx, "run.title"),
            self.run_project_name
        );
        let can_run = !matches!(self.run_state, RunProjectState::Loading);
        let follow_end = self.run_follow_end;
        let mut buttons = vec![
            Self::header_button(
                "run-toggle".to_string(),
                if running {
                    IconName::Square
                } else {
                    IconName::Play
                },
                crate::i18n::menu_text(cx, if running { "run.stop" } else { "run.run" })
                    .to_string(),
                !can_run,
                cx,
                |this, _window, cx| this.run_selected_config(cx),
            ),
            Self::header_button(
                "run-rescan".to_string(),
                IconName::RotateCw,
                crate::i18n::menu_text(cx, "run.rescan").to_string(),
                running,
                cx,
                |this, _window, cx| this.reload_run_project(cx),
            ),
        ];
        buttons.push(
            Button::new("run-follow-end")
                .small()
                .when(follow_end, |b| b.primary())
                .when(!follow_end, |b| b.ghost())
                .icon(IconName::ArrowDownToLine)
                .tooltip(crate::i18n::menu_text(cx, "run.scrollToEnd"))
                .on_click(cx.listener(|this, _event, _window, cx| {
                    this.run_follow_end = !this.run_follow_end;
                    crate::settings::update(cx, |s| {
                        s.run_scroll_to_end = this.run_follow_end;
                    });
                    // 打开跟随即滚到底（长度归零触发下次 render 滚动）。
                    this.run_followed_len = 0;
                    cx.notify();
                }))
                .into_any_element(),
        );
        buttons.push(Self::header_button(
            "run-clear-output".to_string(),
            IconName::Trash,
            crate::i18n::menu_text(cx, "run.clearOutput").to_string(),
            self.run_output.is_empty(),
            cx,
            |this, _window, cx| {
                this.run_output.clear();
                cx.notify();
            },
        ));
        self.render_pane_header(IconName::Play, title, status, buttons, cx)
    }

    /// Maven 窗格头部：停止 + 重跑 + 清空 + 最小化（对齐 Tauri MavenRunPane 头）。
    fn render_maven_header(&self, cx: &mut Context<Self>) -> AnyElement {
        let title = match self.maven_title.clone() {
            Some(task) => format!(
                "{} - {} - {task}",
                crate::i18n::menu_text(cx, "run.title"),
                crate::i18n::menu_text(cx, "maven.title")
            ),
            None => format!(
                "{} - {}",
                crate::i18n::menu_text(cx, "run.title"),
                crate::i18n::menu_text(cx, "maven.title")
            ),
        };
        let status = self.maven_running.then(|| {
            div()
                .text_xs()
                .text_color(ThemeColors::accent_green())
                .child(crate::i18n::menu_text(cx, "run.running"))
                .into_any_element()
        });
        let can_rerun = self.last_maven_goal.is_some() && !self.maven_running;
        let can_clear = !self.maven_output.is_empty() || self.maven_title.is_some();
        self.render_pane_header(
            IconName::Box,
            title,
            status,
            vec![
                Self::header_button(
                    "maven-stop".to_string(),
                    IconName::Square,
                    crate::i18n::menu_text(cx, "maven.stop").to_string(),
                    !self.maven_running,
                    cx,
                    |this, _window, cx| this.stop_running(cx),
                ),
                Self::header_button(
                    "maven-rerun".to_string(),
                    IconName::RefreshCw,
                    crate::i18n::menu_text(cx, "maven.rerunTest").to_string(),
                    !can_rerun,
                    cx,
                    |this, _window, cx| this.rerun_maven(cx),
                ),
                Self::header_button(
                    "maven-clear-output".to_string(),
                    IconName::Trash,
                    crate::i18n::menu_text(cx, "maven.clearOutput").to_string(),
                    !can_clear,
                    cx,
                    |this, _window, cx| {
                        this.maven_output.clear();
                        cx.notify();
                    },
                ),
            ],
            cx,
        )
    }

    /// Run 面板体：配置列表 + 输出区；头部由 `render_run_header` 负责。
    fn render_run_panel(&mut self, cx: &mut Context<Self>) -> AnyElement {
        if self.run_configs.is_empty() {
            match &self.run_state {
                RunProjectState::Loading => {
                    return run_center_text(run_ui_text(cx, "加载中…", "Loading…"));
                }
                RunProjectState::Failed(err) => {
                    let msg = if err.is_empty() {
                        run_ui_text(cx, "加载失败", "Failed to load")
                    } else {
                        err.clone()
                    };
                    return v_flex()
                        .size_full()
                        .items_center()
                        .justify_center()
                        .gap_2()
                        .text_xs()
                        .text_color(ThemeColors::text_muted())
                        .child(div().child(msg))
                        .child(
                            Button::new("run-retry")
                                .small()
                                .ghost()
                                .label(run_ui_text(cx, "重试", "Retry"))
                                .on_click(cx.listener(|this, _event, _window, cx| {
                                    this.reload_run_project(cx);
                                })),
                        )
                        .into_any_element();
                }
                _ => {
                    // Missing 空态 + 生成配置按钮。
                    return v_flex()
                        .size_full()
                        .items_center()
                        .justify_center()
                        .gap_2()
                        .text_xs()
                        .text_color(ThemeColors::text_muted())
                        .child(div().child(run_ui_text(
                            cx,
                            "暂无可运行配置",
                            "No runnable configurations",
                        )))
                        .child(
                            Button::new("run-generate")
                                .small()
                                .primary()
                                .label(run_ui_text(cx, "生成配置", "Generate"))
                                .on_click(cx.listener(|this, _event, _window, cx| {
                                    this.reload_run_project(cx);
                                })),
                        )
                        .into_any_element();
                }
            }
        }

        let diagnostic_rows: Vec<AnyElement> = self
            .run_diagnostics
            .iter()
            .map(|message| {
                div()
                    .px_2()
                    .py_1()
                    .text_xs()
                    .text_color(ThemeColors::text_muted())
                    .child(message.clone())
                    .into_any_element()
            })
            .collect();
        let rows: Vec<AnyElement> = self
            .run_configs
            .iter()
            .map(|item| {
                let id = item.id.clone();
                let run_id = item.id.clone();
                let selected = self.selected_run_config.as_deref() == Some(item.id.as_str());
                h_flex()
                    .id(format!("run-config-{}", item.id))
                    .w_full()
                    .items_center()
                    .gap_1p5()
                    .px_2()
                    .py_1()
                    .rounded_sm()
                    .cursor_pointer()
                    .text_xs()
                    .when(selected, |row| {
                        row.bg(ThemeColors::bg_tab_hover())
                            .text_color(ThemeColors::text_primary())
                    })
                    .when(!selected, |row| {
                        row.text_color(ThemeColors::text_muted()).hover(|h| {
                            h.bg(ThemeColors::bg_tab_hover())
                                .text_color(ThemeColors::text_primary())
                        })
                    })
                    .child(
                        v_flex()
                            .flex_1()
                            .min_w_0()
                            .child(div().truncate().child(item.name.clone()))
                            .child(
                                div()
                                    .truncate()
                                    .font_family("monospace")
                                    .child(format!("{} {}", item.kind, item.detail)),
                            ),
                    )
                    .child(
                        Button::new(format!("run-start-{}", item.id))
                            .small()
                            .ghost()
                            .icon(IconName::Play)
                            .tooltip(run_ui_text(cx, "运行", "Run"))
                            .on_click(cx.listener(move |this, _event, _window, cx| {
                                this.run_configuration_id(run_id.clone(), cx);
                            })),
                    )
                    .on_click(cx.listener(move |this, _event, _window, cx| {
                        this.selected_run_config = Some(id.clone());
                        cx.notify();
                    }))
                    .into_any_element()
            })
            .collect();

        let total = self.run_output.len();
        let start = total.saturating_sub(800);
        let output: Vec<AnyElement> = if self.run_output.is_empty() {
            vec![div()
                .text_color(ThemeColors::text_muted())
                .child(crate::i18n::menu_text(cx, "run.emptyOutput"))
                .into_any_element()]
        } else {
            self.run_output[start..]
                .iter()
                .map(|line| render_output_line(line))
                .collect()
        };
        // 跟随末尾：只在新增输出时滚到最后一行（对齐 Tauri `useFollowOutputEnd`）。
        if self.run_follow_end && output.len() != self.run_followed_len {
            self.run_followed_len = output.len();
            if output.len() > 1 {
                self.run_scroll.scroll_to_item(output.len() - 1);
            }
        }

        v_flex()
            .size_full()
            .child(
                h_flex()
                    .flex_1()
                    .w_full()
                    .min_h_0()
                    .child(
                        div()
                            .flex_shrink_0()
                            .w(px(220.0))
                            .h_full()
                            .overflow_y_scrollbar()
                            .border_r_1()
                            .border_color(ThemeColors::border())
                            .py_1()
                            .children(rows)
                            .children(diagnostic_rows),
                    )
                    .child(
                        div()
                            .flex_1()
                            .h_full()
                            .vertical_scrollbar(&self.run_scroll)
                            .p_2()
                            .font_family("monospace")
                            .text_xs()
                            .text_color(ThemeColors::text_primary())
                            .children(output),
                    ),
            )
            .into_any_element()
    }

    /// Maven 面板体：输出区（首行 `$ mvn …`，流式追加）；头部由 `render_maven_header` 负责。
    fn render_maven_panel(&self, cx: &mut Context<Self>) -> AnyElement {
        let total = self.maven_output.len();
        let start = total.saturating_sub(800);
        let output: Vec<AnyElement> = if self.maven_output.is_empty() {
            vec![div()
                .text_color(ThemeColors::text_muted())
                .child(crate::i18n::menu_text(cx, "run.emptyOutput"))
                .into_any_element()]
        } else {
            self.maven_output[start..]
                .iter()
                .map(|line| render_output_line(line))
                .collect()
        };
        div()
            .flex_1()
            .w_full()
            .min_h_0()
            .overflow_y_scrollbar()
            .p_2()
            .font_family("monospace")
            .text_xs()
            .text_color(ThemeColors::text_primary())
            .children(output)
            .into_any_element()
    }

    /// GitLog 面板：只读提交列表，行点击不跳转；空态与失败文案兜底。
    fn render_git_log_panel(&self, cx: &mut Context<Self>) -> AnyElement {
        if let Some(err) = self.git_log_error.clone() {
            return div()
                .size_full()
                .flex()
                .items_center()
                .justify_center()
                .text_xs()
                .text_color(ThemeColors::text_muted())
                .child(if err.is_empty() {
                    git_log_failed_text(cx).to_string()
                } else {
                    err
                })
                .into_any_element();
        }
        if self.git_log.is_empty() {
            return div()
                .size_full()
                .flex()
                .items_center()
                .justify_center()
                .text_xs()
                .text_color(ThemeColors::text_muted())
                .child(git_log_empty_text(cx))
                .into_any_element();
        }

        let rows: Vec<AnyElement> = self
            .git_log
            .iter()
            .enumerate()
            .map(|(idx, entry)| {
                h_flex()
                    .id(format!("git-log-{idx}"))
                    .w_full()
                    .items_center()
                    .gap_2()
                    .px_3()
                    .py_1()
                    .text_xs()
                    .child(
                        div()
                            .flex_shrink_0()
                            .font_family("monospace")
                            .text_color(ThemeColors::accent_blue())
                            .child(entry.hash.clone()),
                    )
                    .child(
                        div()
                            .flex_1()
                            .truncate()
                            .text_color(ThemeColors::text_primary())
                            .child(entry.message.clone()),
                    )
                    .into_any_element()
            })
            .collect();

        div()
            .flex_1()
            .w_full()
            .overflow_y_scrollbar()
            .py_1()
            .children(rows)
            .into_any_element()
    }
}

impl Render for BottomPanelView {
    fn render(&mut self, _window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        if self.is_collapsed {
            return div().h(px(0.0));
        }

        // 各窗格自带按钮头（对齐 Tauri：底部无标签切换条，切换只走左侧活动栏）。
        let (header, body) = match self.active_tab {
            BottomTab::Terminal => (
                self.render_pane_header(
                    IconName::Terminal,
                    crate::i18n::menu_text(cx, "workbench.terminal").to_string(),
                    None,
                    vec![Self::header_button(
                        "terminal-clear".to_string(),
                        IconName::Trash,
                        crate::i18n::menu_text(cx, "ui.clear").to_string(),
                        false,
                        cx,
                        |this, _window, cx| {
                            let _ = this.terminal.update(cx, |t, cx| t.clear(cx));
                        },
                    )],
                    cx,
                ),
                div()
                    .size_full()
                    .child(self.terminal.clone())
                    .into_any_element(),
            ),
            BottomTab::Run => (self.render_run_header(cx), self.render_run_panel(cx)),
            BottomTab::Maven => (self.render_maven_header(cx), self.render_maven_panel(cx)),
            BottomTab::Diagnostics => (
                self.render_pane_header(
                    IconName::TriangleAlert,
                    format!(
                        "{} ({})",
                        crate::i18n::menu_text(cx, "workbench.diagnostics"),
                        self.diagnostics.len()
                    ),
                    None,
                    vec![Self::header_button(
                        "diagnostics-clear".to_string(),
                        IconName::Trash,
                        crate::i18n::menu_text(cx, "ui.clear").to_string(),
                        self.diagnostics.is_empty(),
                        cx,
                        |this, _window, cx| {
                            this.diagnostics.clear();
                            cx.emit(BottomPanelEvent::ClearDiagnostics);
                            cx.notify();
                        },
                    )],
                    cx,
                ),
                self.render_diagnostics_panel(cx),
            ),
            BottomTab::GitLog => (
                self.render_pane_header(
                    IconName::GitGraph,
                    crate::i18n::menu_text(cx, "workbench.gitLog").to_string(),
                    None,
                    vec![Self::header_button(
                        "gitlog-refresh".to_string(),
                        IconName::RotateCw,
                        crate::i18n::menu_text(cx, "ui.refresh").to_string(),
                        false,
                        cx,
                        |this, _window, cx| this.refresh_git_log(cx),
                    )],
                    cx,
                ),
                self.render_git_log_panel(cx),
            ),
        };

        v_flex()
            .h(px(self.height))
            .w_full()
            .bg(ThemeColors::bg_bottom_panel())
            .border_t_1()
            .border_color(ThemeColors::border())
            .child(header)
            .child(div().flex_1().w_full().min_h_0().child(body))
    }
}

/// 同步取 Git 提交记录：`git -C <workdir> log --oneline -N`，解析 hash + 首行
/// message。core 侧 `git.historyPage` 存在但 linux `CoreClient` 尚未暴露对应
/// 方法，且本次只允许改动底部面板/活动栏两文件，故先用子进程退化实现；
/// 宿主后续可把 [`BottomPanelView::refresh_git_log`] 切到 core 异步接线。
fn load_git_log(workdir: &str) -> Result<Vec<GitLogEntry>, String> {
    let output = std::process::Command::new("git")
        .arg("-C")
        .arg(workdir)
        .arg("log")
        .arg("--oneline")
        .arg(format!("-{MAX_GIT_LOG_ENTRIES}"))
        .output()
        .map_err(|e| e.to_string())?;
    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).trim().to_string();
        return Err(stderr);
    }
    let stdout = String::from_utf8_lossy(&output.stdout);
    let entries = stdout
        .lines()
        .filter_map(|line| {
            let line = line.trim();
            if line.is_empty() {
                return None;
            }
            let (hash, message) = match line.split_once(char::is_whitespace) {
                Some((hash, message)) => (hash.trim(), message.trim()),
                None => (line, ""),
            };
            if hash.is_empty() {
                return None;
            }
            Some(GitLogEntry {
                hash: hash.to_string(),
                message: message.to_string(),
            })
        })
        .collect();
    Ok(entries)
}

fn workspace_relative_path(root: &str, path: &str) -> Option<String> {
    let root = std::path::Path::new(root);
    let path = std::path::Path::new(path);
    let relative = if path.is_absolute() {
        path.strip_prefix(root).ok()?
    } else {
        path
    };
    Some(relative.to_string_lossy().replace('\\', "/"))
}

/// pom 所在目录相对 root 的模块路径：根 pom 为 `.`。
fn maven_module_for_pom(root: &str, pom: &str) -> String {
    let relative = std::path::Path::new(pom)
        .parent()
        .and_then(|directory| directory.strip_prefix(root).ok())
        .map(|relative| relative.to_string_lossy().replace('\\', "/"))
        .unwrap_or_default();
    let trimmed = relative.trim_matches('/').to_string();
    if trimmed.is_empty() {
        ".".to_string()
    } else {
        trimmed
    }
}

/// 行首空白转不换行空格：GPUI `Normal` 会塌缩连续空白（Tauri `pre-wrap`
/// 保留），只转行首以兼顾缩进保留与行内换行。
fn preserve_leading_whitespace(line: &str) -> String {
    let indent_len = line.len() - line.trim_start_matches([' ', '\t']).len();
    let (indent, rest) = line.split_at(indent_len);
    let mut out = String::with_capacity(line.len() + indent.len() * 2);
    for c in indent.chars() {
        if c == '\t' {
            out.push_str("\u{a0}\u{a0}\u{a0}\u{a0}");
        } else {
            out.push('\u{a0}');
        }
    }
    out.push_str(rest);
    out
}

/// 输出行渲染：显式换行模式（对齐 Tauri `pre-wrap`）+ 行首缩进保留。
fn render_output_line(line: &str) -> AnyElement {
    div()
        .whitespace_normal()
        .child(preserve_leading_whitespace(line))
        .into_any_element()
}
fn push_run_line(output: &mut Vec<String>, line: String) {
    output.push(line);
    if output.len() > MAX_RUN_OUTPUT {
        let overflow = output.len() - MAX_RUN_OUTPUT;
        output.drain(..overflow);
    }
}

fn run_center_text(text: String) -> AnyElement {
    div()
        .size_full()
        .flex()
        .items_center()
        .justify_center()
        .text_xs()
        .text_color(ThemeColors::text_muted())
        .child(text)
        .into_any_element()
}

fn run_ui_text(cx: &gpui_kit::App, zh: &str, en: &str) -> String {
    if crate::i18n::is_zh(cx) {
        zh.to_string()
    } else {
        en.to_string()
    }
}

fn git_log_empty_text(cx: &gpui_kit::App) -> &'static str {
    if crate::i18n::is_zh(cx) {
        "暂无提交记录"
    } else {
        "No commits"
    }
}

fn git_log_failed_text(cx: &gpui_kit::App) -> &'static str {
    if crate::i18n::is_zh(cx) {
        "加载提交记录失败"
    } else {
        "Failed to load git log"
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn item(
        provider: &str,
        source: Option<&str>,
        main_class: Option<&str>,
        module: Option<&str>,
    ) -> RunConfigItem {
        let mut extensions = serde_json::Map::new();
        if let Some(source) = source {
            extensions.insert("java".to_string(), serde_json::json!({ "source": source }));
        }
        let mut maven = serde_json::Map::new();
        if let Some(module) = module {
            maven.insert("module".to_string(), serde_json::json!(module));
        }
        if let Some(main_class) = main_class {
            maven.insert("mainClass".to_string(), serde_json::json!(main_class));
        }
        extensions.insert("maven".to_string(), serde_json::Value::Object(maven));
        let mut toolchains = serde_json::Map::new();
        toolchains.insert("java".to_string(), serde_json::json!("project-jdk"));
        if module.is_some() || provider.contains("maven") {
            toolchains.insert("maven".to_string(), serde_json::json!("project-maven"));
        }
        let value = serde_json::json!({
            "id": "test",
            "name": "Test",
            "provider": provider,
            "toolchains": toolchains,
            "extensions": extensions,
        });
        RunConfigItem::from_value(&value).expect("run config")
    }

    #[test]
    fn only_maven_backed_java_and_spring_targets_require_jdt() {
        assert!(BottomPanelView::needs_java_project_preparation(&item(
            "java.main",
            Some("src/App.java"),
            Some("demo.App"),
            Some(".")
        )));
        assert!(BottomPanelView::needs_java_project_preparation(&item(
            "spring-boot.maven",
            Some("src/App.java"),
            Some("demo.App"),
            Some(".")
        )));
        assert!(!BottomPanelView::needs_java_project_preparation(&item(
            "quarkus.maven",
            Some("src/App.java"),
            Some("demo.App"),
            Some(".")
        )));
        assert!(!BottomPanelView::needs_java_project_preparation(&item(
            "java.main",
            Some("src/App.java"),
            Some("demo.App"),
            None
        )));
        assert!(!BottomPanelView::needs_java_project_preparation(&item(
            "java.main",
            None,
            Some("demo.App"),
            Some(".")
        )));

        let standalone = RunConfigItem::from_value(&serde_json::json!({
            "id": "standalone",
            "name": "Standalone",
            "provider": "java.main",
            "toolchains": {"java": "project-jdk"},
            "extensions": {
                "java": {"source": "src/App.java"},
                "maven": {"module": ".", "mainClass": "demo.App"}
            }
        }))
        .expect("standalone config");
        assert!(!BottomPanelView::needs_java_project_preparation(
            &standalone
        ));
    }
}
