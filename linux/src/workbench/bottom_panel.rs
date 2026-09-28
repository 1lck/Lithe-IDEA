use std::sync::mpsc;
use std::time::{Duration, Instant};

use gpui_kit::assets::IconName;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::scroll::ScrollableElement as _;
use gpui_kit::component::{h_flex, v_flex, Disableable as _, Icon, Sizable as _};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::EventEmitter;
use gpui_kit::Subscription;
use gpui_kit::{
    div, px, AnyElement, App, AppContext as _, Context, Entity, FontWeight,
    InteractiveElement as _, IntoElement, MouseButton, ParentElement as _, Render, Rgba,
    StatefulInteractiveElement as _, Styled as _, WeakEntity, Window,
};

use crate::core::CoreClient;
use crate::lsp;
use crate::theme::ThemeColors;
use crate::workbench::activity_rail::IDEA_ICON_DEBUGGER;
use crate::workbench::console::OutputConsole;
use crate::workbench::editor::EditorView;
use crate::workbench::run::{
    create_launch_plan_request, default_generated_configuration_id, list_java_sources,
    maven_context_for_configuration, parse_resolved_configurations, read_toolchain_paths,
    sequence_is_current, toolchain_candidates, write_generated_documents, LaunchPlan, ProcessEvent,
    ProcessManager, RunConfigGroup, RunConfigItem,
};
use crate::workbench::terminal::TerminalView;
use crate::workbench::view::WorkbenchView;

/// 运行历史上限。
const MAX_RUN_HISTORY: usize = 50;

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

/// Maven 输出文本缓冲上限（字节）；超过后丢弃较早的一半，保住近期输出。
const MAX_MAVERN_OUTPUT_TEXT: usize = 1_000_000;

/// 一条 Maven 构建诊断（对齐 mac `MavenBuildIssue`）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MavenBuildIssue {
    pub path: String,
    pub line: usize,
    pub column: Option<usize>,
    pub severity: String,
    pub message: String,
}

/// 剥离 ANSI 转义序列并丢弃 `\r`（对齐 mac `ANSIOutputRenderer.parse`：
/// 进度条回车行不单独成行），得到可正则解析的纯文本。
fn strip_ansi_bytes(bytes: &[u8]) -> String {
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;
    while index < bytes.len() {
        match bytes[index] {
            0x1b => {
                index += 1;
                if index < bytes.len() && bytes[index] == b']' {
                    // OSC 序列：吞到 BEL。
                    while index < bytes.len() && bytes[index] != 0x07 {
                        index += 1;
                    }
                    index += 1;
                } else if index < bytes.len() && bytes[index] == b'[' {
                    index += 1;
                    // CSI 序列：吞到终止字节（@ 到 ~）。
                    while index < bytes.len() && !(0x40..=0x7e).contains(&bytes[index]) {
                        index += 1;
                    }
                    index += 1;
                }
            }
            0x0d => index += 1,
            byte => {
                out.push(byte);
                index += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// 把控制台输出追加进诊断文本缓冲（超限时丢弃较早的一半）。
fn append_maven_output_text(buffer: &mut String, bytes: &[u8]) {
    buffer.push_str(&strip_ansi_bytes(bytes));
    if buffer.len() > MAX_MAVERN_OUTPUT_TEXT {
        let cut = buffer
            // 在上限之后找最近的换行，避免截断出半行。
            .char_indices()
            .map(|(index, _)| index)
            .find(|&index| index >= MAX_MAVERN_OUTPUT_TEXT / 2 && buffer.is_char_boundary(index))
            .unwrap_or(MAX_MAVERN_OUTPUT_TEXT / 2);
        buffer.drain(..cut);
    }
}

/// 解析 core `maven.diagnostics` 响应。
fn parse_maven_issues(value: &serde_json::Value) -> Vec<MavenBuildIssue> {
    value
        .get("issues")
        .and_then(serde_json::Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(|item| {
                    Some(MavenBuildIssue {
                        path: item.get("path")?.as_str()?.to_string(),
                        line: item.get("line")?.as_u64()? as usize,
                        column: item
                            .get("column")
                            .and_then(serde_json::Value::as_u64)
                            .map(|v| v as usize),
                        severity: item
                            .get("severity")
                            .and_then(serde_json::Value::as_str)
                            .unwrap_or("error")
                            .to_string(),
                        message: item
                            .get("message")
                            .and_then(serde_json::Value::as_str)
                            .unwrap_or_default()
                            .to_string(),
                    })
                })
                .collect()
        })
        .unwrap_or_default()
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum BottomTab {
    Terminal,
    Run,
    Maven,
    Diagnostics,
    GitLog,
    /// 测试工具窗（对齐 macOS `execution.tests`，UI 占位，功能待接入）。
    Tests,
    /// 调试工具窗（对齐 macOS `debug.session`，UI 占位，功能待接入）。
    Debug,
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
    /// Maven 运行态变化（宿主同步右侧 Maven 面板的 run/stop 按钮切换）。
    MavenRunningChanged(bool),
    /// Run 运行态/选中配置变化（宿主同步顶部工具栏的 Run/Stop 与配置胶囊）。
    RunStateChanged,
    /// 选中配置缺 Java 启动元数据，需要用户确认后重新生成（对齐 mac
    /// 的 setup 确认对话框 → generateFromJavaEntrypoints → 续跑）。
    RunSetupRequired,
    /// Run 面板请求打开设置对话框并定位分类（对齐 Tauri
    /// `openSettingsDialog(category)`；`category` 为 `SettingsCategory::id`）。
    OpenSettings {
        category: &'static str,
    },
    /// Java 构建失败且策略为 `ask`：宿主展示构建失败决策对话框
    /// （对齐 Tauri `JavaLaunchDecisionBanner`）。
    RunBuildFailedDecision,
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
    /// 运行输出控制台（PTY 原始字节经 channel 泵入，终端组件渲染）。
    pub(crate) run_console: OutputConsole,
    /// 是否有 Run execution 在准备或运行。
    pub(crate) run_running: bool,
    /// 最近一次 Run 主进程退出码。
    pub(crate) run_exit_code: Option<i32>,
    /// 输出跟随末尾（对齐 Tauri `scrollOutputToEnd`，默认开，落盘持久化）。
    pub(crate) run_follow_end: bool,
    /// 基础设施区块是否折叠（对齐 Tauri `infrastructureCollapsed`，默认折叠）。
    run_infrastructure_collapsed: bool,
    /// 其他运行配置区块是否折叠（对齐 Tauri `otherConfigurationsCollapsed`）。
    run_other_collapsed: bool,
    /// Run 控制台视口是否停在底部（观察者镜像，变化才 notify）。
    /// 跟随末尾开启时也只在底部才拉底（对齐 macOS 智能滚动：上翻查阅
    /// 历史时不被新输出拉走），离开底部时显示"跳到最新"浮层按钮。
    run_at_bottom: bool,
    /// Maven 控制台视口是否停在底部（同 [`Self::run_at_bottom`]）。
    maven_at_bottom: bool,
    /// Java 准备状态区块是否展开（对齐 Tauri `<details>` 默认收起）。
    java_prep_expanded: bool,
    /// 等待用户决策的 Java 构建失败信息；`None` 表示无待决策项。
    pub(crate) pending_build_error: Option<String>,
    /// 用户对 [`Self::pending_build_error`] 的决策：`true` 仍然启动，
    /// `false` 放弃本次运行；由 [`Self::resolve_build_failure_decision`] 写入。
    build_failure_decision: Option<bool>,
    /// Maven 任务标题（对齐 Tauri `taskTitle`，如 `compile · pom.xml`）。
    pub(crate) maven_title: Option<String>,
    /// Maven 任务输出控制台（同 [`Self::run_console`]）。
    pub(crate) maven_console: OutputConsole,
    /// Maven 输出文本缓冲（剥离 ANSI 后累积，供诊断解析；超限截断头部）。
    maven_output_text: String,
    /// 最近一次 Maven 任务的编译诊断（对齐 mac `MavenBuildIssue` 列表，
    /// 来自 core `maven.diagnostics`）。
    pub maven_issues: Vec<MavenBuildIssue>,
    /// 最近一次应用到输出控制台的主题背景色；主题切换时用于同步配色。
    console_background: Rgba,
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
    /// 控制台滚动观察者订阅，保持到视图销毁。
    _subscriptions: Vec<Subscription>,
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
        // 对齐 Tauri：构建失败按工作区策略决策——`alwaysProceed` 直接继续，
        // `ask` 弹出决策对话框等待用户选择。
        let proceed = wait_for_java_build_decision(run_guard, &error, cx).await;
        if !proceed {
            return Err(format!("Java project build failed: {error}"));
        }
    }
    Ok((launch, session_id))
}

/// Java 构建失败后的启动决策等待：先请求面板弹出决策对话框，随后轮询
/// 用户决策与工作区策略。运行被替换/取消或超时均视为放弃启动。
async fn wait_for_java_build_decision(
    run_guard: (&Entity<BottomPanelView>, u64, u64),
    build_error: &str,
    cx: &mut gpui_kit::AsyncApp,
) -> bool {
    let requested = run_guard.0.update(cx, |panel, cx| {
        panel.request_build_failure_decision(build_error.to_string(), cx);
    });
    let _ = requested;
    let deadline = Instant::now() + Duration::from_secs(10 * 60);
    loop {
        let current = run_guard.0.read_with(cx, |view, _app| {
            view.is_current_run_execution(run_guard.1, run_guard.2)
        });
        if !current {
            return false;
        }
        let (decision, policy) = run_guard.0.read_with(cx, |view, app| {
            (
                view.build_failure_decision,
                crate::settings::java_build_failure_policy(
                    crate::settings::get(app),
                    &view.working_dir,
                )
                .to_string(),
            )
        });
        // 用户可能在等待期间于设置里改为始终继续；决策以最新策略优先。
        if policy == "alwaysProceed" {
            return true;
        }
        if let Some(proceed) = decision {
            return proceed;
        }
        if Instant::now() >= deadline {
            return false;
        }
        cx.background_executor()
            .timer(Duration::from_millis(200))
            .await;
    }
}

impl BottomPanelView {
    pub fn new(working_dir: String, cx: &mut Context<Self>) -> Self {
        let terminal = cx.new(|cx| TerminalView::new(working_dir.clone(), cx));
        let run_console = OutputConsole::new(cx);
        let maven_console = OutputConsole::new(cx);
        let obs_run_console = run_console.view.clone();
        let obs_maven_console = maven_console.view.clone();

        let mut view = Self {
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
            run_console,
            run_running: false,
            run_exit_code: None,
            run_follow_end: crate::settings::get(cx).run_scroll_to_end,
            run_infrastructure_collapsed: true,
            run_other_collapsed: true,
            run_at_bottom: true,
            maven_at_bottom: true,
            java_prep_expanded: false,
            pending_build_error: None,
            build_failure_decision: None,
            maven_title: None,
            maven_console,
            maven_output_text: String::new(),
            maven_issues: Vec::new(),
            console_background: crate::theme::palette().background,
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
            _subscriptions: Vec::new(),
        };
        // 控制台滚动镜像：用户滚动终端（组件 notify 自身）时更新"是否在
        // 底部"，驱动跟随语义与"跳到最新"按钮显隐。
        view._subscriptions
            .push(cx.observe(&obs_run_console, |this, view, cx| {
                let at_bottom = view.read(cx).state().display_offset() == 0;
                if this.run_at_bottom != at_bottom {
                    this.run_at_bottom = at_bottom;
                    cx.notify();
                }
            }));
        view._subscriptions
            .push(cx.observe(&obs_maven_console, |this, view, cx| {
                let at_bottom = view.read(cx).state().display_offset() == 0;
                if this.maven_at_bottom != at_bottom {
                    this.maven_at_bottom = at_bottom;
                    cx.notify();
                }
            }));
        view
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
    /// 内容不变时短路（LSP 抖动期每批都全量推送，避免无谓重渲染）。
    pub fn set_diagnostics(&mut self, diagnostics: Vec<DiagnosticEntry>, cx: &mut Context<Self>) {
        if self.diagnostics == diagnostics {
            return;
        }
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
    ///
    /// 终端会话同步跟随：项目切换后旧 shell 的 cwd 与环境已过期，由
    /// `TerminalView::set_working_dir` 安全重启会话。
    pub fn set_working_dir(&mut self, dir: String, cx: &mut Context<Self>) {
        let _ = self.processes.request_stop("run", None);
        self.maven_seq += 1;
        let _ = self.processes.request_stop("maven", None);
        self.set_maven_running(false, cx);
        self.pending_run_id = None;
        self.run_on_ready = false;
        self.working_dir = dir.clone();
        let _ = self.terminal.update(cx, |term, cx| {
            term.set_working_dir(dir, cx);
        });
        self.reload_run_project(cx);
    }

    /// 新建终端会话：切到终端页并按当前工作目录重启会话。
    pub fn restart_terminal(&mut self, cx: &mut Context<Self>) {
        self.active_tab = BottomTab::Terminal;
        self.is_collapsed = false;
        let _ = self.terminal.update(cx, |term, cx| term.restart(cx));
        cx.notify();
    }

    /// 关闭终端会话：真正终止 PTY 子进程并回到空态，再折叠面板。
    /// 只折叠面板会让 shell 继续在后台跑，属于资源泄漏。
    pub fn close_terminal_session(&mut self, cx: &mut Context<Self>) {
        let _ = self.terminal.update(cx, |term, cx| term.close_session(cx));
        self.active_tab = BottomTab::Terminal;
        self.is_collapsed = true;
        cx.notify();
    }

    /// 终端窗格状态区：会话在跑时点亮状态与 shell 名，已退出时展示退出码/信号。
    fn terminal_status(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let (has_session, running, shell, exit) = {
            let terminal = self.terminal.read(cx);
            (
                terminal.has_session(),
                terminal.is_running(),
                terminal.shell().to_string(),
                terminal
                    .session_exit()
                    .map(|exit| exit.detail())
                    .filter(|detail| !detail.is_empty()),
            )
        };
        if !has_session {
            return None;
        }
        let text = if running {
            let label = crate::i18n::menu_text(cx, "run.running");
            if shell.is_empty() {
                label.to_string()
            } else {
                format!("{label} · {shell}")
            }
        } else {
            let label = crate::i18n::menu_text(cx, "terminal.sessionExited");
            match exit {
                Some(detail) => format!("{label} · {detail}"),
                None => label.to_string(),
            }
        };
        Some(
            div()
                .text_xs()
                .text_color(if running {
                    ThemeColors::accent_green()
                } else {
                    ThemeColors::text_muted()
                })
                .child(text)
                .into_any_element(),
        )
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
            self.set_run_running(false, cx);
        }
        self.run_project_name = crate::settings::project_dir_name(&self.working_dir).to_string();
        self.run_configs.clear();
        self.default_run_config = None;
        if self.selected_run_config.take().is_some() {
            // 选中项被 reload 重置，顶部胶囊名称需要同步。
            cx.emit(BottomPanelEvent::RunStateChanged);
        }
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
        // 对齐 mac：框架服务配置缺 Java 启动元数据时不回退 mvn goal
        //（会因插件前缀解析失败），先走 setup 确认重新生成。
        if self.needs_run_setup() {
            cx.emit(BottomPanelEvent::RunSetupRequired);
            cx.notify();
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
        self.select_run_config(id.clone(), cx);
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

    /// 对齐 mac `generateFromJavaEntrypoints`：等待 Java 语言服务就绪、
    /// 取 JDT entrypoints 重新生成配置文档，再 reload 并按 `run_on_ready`
    /// 续跑。供 setup 确认对话框的确认动作调用。
    pub fn regenerate_run_project(&mut self, cx: &mut Context<Self>) {
        self.run_seq += 1;
        self.run_execution_seq += 1;
        let seq = self.run_seq;
        self.run_state = RunProjectState::Loading;
        cx.notify();
        let Some(workbench) = self.workbench.as_ref().and_then(WeakEntity::upgrade) else {
            // 无宿主可等 JDT：退化为普通 reload（行为与旧行为一致）。
            self.reload_run_project(cx);
            return;
        };
        let client = self.client.clone();
        let root = self.working_dir.clone();
        cx.spawn(async move |this, cx| {
            let java_entrypoints = match wait_for_java_entrypoints(
                &workbench,
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
            };
            let paths = list_java_sources(&root);
            let mut payload = serde_json::json!({
                "root": root,
                "paths": paths,
                "modulePaths": []
            });
            if let Some(entrypoints) = java_entrypoints {
                payload["javaEntrypoints"] = entrypoints;
            }
            let generated = client
                .execute::<serde_json::Value, serde_json::Value>(&cx, "runConfig.generate", payload)
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
            let _ = this.update(cx, |view, cx| {
                if view.run_seq != seq {
                    return;
                }
                // 生成完成后续跑选中的配置（对齐 mac 的 intent 续跑）。
                view.run_on_ready = true;
                view.reload_run_project(cx);
            });
        })
        .detach();
    }

    fn start_run(&mut self, item: RunConfigItem, cx: &mut Context<Self>) {
        if self.run_running {
            return;
        }
        self.run_execution_seq += 1;
        let execution_seq = self.run_execution_seq;
        self.set_run_running(true, cx);
        self.run_exit_code = None;
        // 新执行开始：丢弃上一次的构建失败决策状态。
        self.pending_build_error = None;
        self.build_failure_decision = None;
        // 子进程 PTY 的初始尺寸取输出控制台当前实测行列数。
        let terminal_size = self.run_console.size();
        self.run_console.write_heading(&format!(
            "{}：{}",
            crate::i18n::menu_text(cx, "run.starting"),
            item.name
        ));
        if Self::needs_java_project_preparation(&item) {
            self.run_console.write_muted(&run_ui_text(
                cx,
                "等待 Java 语言服务完成项目准备…",
                "Waiting for Java language service preparation…",
            ));
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
                            view.set_run_running(false, cx);
                            view.run_console.write_error(&error);
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
                            view.set_run_running(false, cx);
                            view.run_exit_code = Some(1);
                            view.run_diagnostics.push(error.clone());
                            view.run_diagnostics.dedup();
                            view.run_console.write_error(&error);
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
                            view.set_run_running(false, cx);
                            view.run_exit_code = Some(1);
                            view.run_diagnostics.push(error.to_string());
                            view.run_console.write_error(&error.to_string());
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
                            view.set_run_running(false, cx);
                            view.run_console.write_error(&error);
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
                            view.set_run_running(false, cx);
                            view.run_console.write_error(&error);
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
                                view.set_run_running(false, cx);
                                view.run_console.write_error(&error);
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
            let handle = match processes.start("run", &execution_id, steps, sender, terminal_size) {
                Ok(handle) => handle,
                Err(error) => {
                    let _ = this.update(cx, |view, cx| {
                        if view.is_current_run_execution(launch_seq, launch_execution_seq) {
                            view.set_run_running(false, cx);
                            view.run_console.write_error(&error);
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
                        view.run_console.write_heading(&label);
                        view.record_run(&label, cx);
                        cx.notify();
                    }
                    ProcessEvent::Output { bytes } => {
                        view.run_console.write_bytes(&bytes);
                        // 对齐 macOS 智能滚动：仅当用户仍停在底部才拉底，
                        // 上翻查阅历史时不被新输出拉走。
                        if view.run_follow_end && view.run_console.is_at_bottom(cx) {
                            view.run_console.scroll_to_bottom(cx);
                        }
                        cx.notify();
                    }
                    ProcessEvent::Finished {
                        exit_code,
                        cancelled,
                        error,
                    } => {
                        if let Some(error) = error {
                            view.run_console.write_error(&error);
                        }
                        let exit_code = exit_code.or_else(|| Some(1));
                        if cancelled {
                            view.run_console
                                .write_muted(crate::i18n::menu_text(cx, "run.finished"));
                        } else {
                            view.run_console.write_muted(&format!(
                                "{}：{}",
                                crate::i18n::menu_text(cx, "run.exited"),
                                exit_code.unwrap_or(1)
                            ));
                        }
                        view.run_exit_code = exit_code;
                        view.set_run_running(false, cx);
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

    /// 统一翻转 Maven 运行态：写标志、通知宿主（右侧 Maven 面板按钮联动）并刷新。
    fn set_maven_running(&mut self, running: bool, cx: &mut Context<Self>) {
        if self.maven_running != running {
            self.maven_running = running;
            cx.emit(BottomPanelEvent::MavenRunningChanged(running));
            cx.notify();
        }
    }

    /// 请求用户决策 Java 构建失败（幂等；对齐 Tauri `openRunDecisionPane`）。
    fn request_build_failure_decision(&mut self, error: String, cx: &mut Context<Self>) {
        if self.pending_build_error.is_some() {
            return;
        }
        self.build_failure_decision = None;
        self.pending_build_error = Some(error);
        cx.emit(BottomPanelEvent::RunBuildFailedDecision);
        cx.notify();
    }

    /// 决策对话框回调：`proceed=false` 放弃本次运行；`always=true` 同时把
    /// 该工作区策略写为 `alwaysProceed`（对齐 Tauri run-preferences）。
    pub fn resolve_build_failure_decision(
        &mut self,
        proceed: bool,
        always: bool,
        cx: &mut Context<Self>,
    ) {
        if always && proceed {
            let root = self.working_dir.clone();
            crate::settings::update(cx, |settings| {
                settings.java_build_failure_policy_by_workspace.insert(
                    crate::settings::workspace_preference_key(&root),
                    "alwaysProceed".to_string(),
                );
            });
        }
        self.pending_build_error = None;
        self.build_failure_decision = Some(proceed);
        cx.notify();
    }

    /// 统一翻转 Run 运行态：写标志并通知宿主（顶部工具栏按钮联动）。
    fn set_run_running(&mut self, running: bool, cx: &mut Context<Self>) {
        if self.run_running != running {
            self.run_running = running;
            cx.emit(BottomPanelEvent::RunStateChanged);
            cx.notify();
        }
    }

    /// 选中运行配置（顶部工具栏胶囊点击；变化才通知宿主）。
    pub fn select_run_config(&mut self, id: String, cx: &mut Context<Self>) {
        if self.selected_run_config.as_deref() != Some(id.as_str()) {
            self.select_run_config(id, cx);
            cx.emit(BottomPanelEvent::RunStateChanged);
            cx.notify();
        }
    }

    /// 顶部工具栏所需运行态快照：(在跑, 选中配置名, 配置列表)。
    pub fn run_toolbar_state(&self) -> (bool, Option<String>, Vec<(String, String)>) {
        let selected = self
            .selected_run_item()
            .map(|item| item.name)
            .or_else(|| self.run_configs.first().map(|item| item.name.clone()));
        let configs = self
            .run_configs
            .iter()
            .map(|item| (item.id.clone(), item.name.clone()))
            .collect();
        (self.run_running, selected, configs)
    }

    /// 顶部工具栏 Run：在跑时对齐 mac `restartSelectedRun` 直接重跑
    ///（ProcessManager.start 会先停同 id 旧会话），未在跑走常规启动。
    pub fn restart_selected_run(&mut self, cx: &mut Context<Self>) {
        if self.needs_run_setup() {
            cx.emit(BottomPanelEvent::RunSetupRequired);
            cx.notify();
            return;
        }
        if let Some(item) = self.selected_run_item() {
            self.run_execution_seq += 1;
            let _ = self.processes.request_stop("run", None);
            self.set_run_running(false, cx);
            self.start_run(item, cx);
        } else {
            self.run_selected_config(cx);
        }
    }

    /// 选中配置是否需要先重新生成才能启动（对齐 mac `configurationReadiness`
    /// 的 needsGeneration 语义）：Spring Boot 等框架服务配置缺 Java 启动元数据
    /// （source/main_class）时，直接发 mvn goal 会因插件前缀解析失败
    /// （如 `No plugin found for prefix 'spring-boot'`），必须等 JDT
    /// entrypoints 就绪后重新生成配置再直启。
    pub fn needs_run_setup(&self) -> bool {
        self.selected_run_item().is_some_and(|item| {
            let has_source = item
                .source
                .as_deref()
                .is_some_and(|value| !value.trim().is_empty());
            let has_main = item
                .main_class
                .as_deref()
                .is_some_and(|value| !value.trim().is_empty());
            item.provider == "spring-boot.maven" && (!has_source || !has_main)
        })
    }

    /// 停止在跑进程；ProcessManager 异步终止完整进程树并在输出泵中回收。
    pub fn stop_running(&mut self, cx: &mut Context<Self>) {
        let mut stopped = false;
        if self.run_running {
            self.run_execution_seq += 1;
            let _ = self.processes.request_stop("run", None);
            self.run_console
                .write_muted(crate::i18n::menu_text(cx, "run.stopping"));
            self.set_run_running(false, cx);
            stopped = true;
        }
        if self.maven_running {
            self.maven_seq += 1;
            let _ = self.processes.request_stop("maven", None);
            self.maven_console
                .write_muted(crate::i18n::menu_text(cx, "run.stopping"));
            self.set_maven_running(false, cx);
            stopped = true;
        }
        if stopped {
            cx.notify();
        }
    }
    /// 是否发生过 Maven 运行；宿主据此决定左侧栏是否展示 maven 项
    ///（对齐 Tauri `hasMavenRun`：任务跑过即真，与终端历史无关）。
    pub fn has_maven_run(&self) -> bool {
        self.maven_running || !self.maven_console.is_empty()
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
        self.maven_console.clear();
        self.maven_output_text.clear();
        self.maven_issues.clear();
        self.set_maven_running(true, cx);

        let client = self.client.clone();
        let root = self.working_dir.clone();
        let module = maven_module_for_pom(&self.working_dir, pom_path);
        let profiles = profiles.to_vec();
        let processes = self.processes.clone();
        let terminal_size = self.maven_console.size();
        // TEMP_DIAG: 定位“输出只剩一行”问题——确认 spawn 时的 PTY 行列。
        tracing::debug!(
            target: "maven_pump",
            pty_cols = terminal_size.cols,
            pty_rows = terminal_size.rows,
            "maven process spawning"
        );
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
                            view.set_maven_running(false, cx);
                            view.maven_console.write_error(&error);
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
                            view.set_maven_running(false, cx);
                            view.maven_console.write_error(&error);
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
                                view.set_maven_running(false, cx);
                                view.maven_console.write_error(&error);
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
            let handle = match processes.start("maven", &execution_id, steps, sender, terminal_size)
            {
                Ok(handle) => handle,
                Err(error) => {
                    let _ = this.update(cx, |view, cx| {
                        if view.maven_seq == seq {
                            view.set_maven_running(false, cx);
                            view.maven_console.write_error(&error);
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
                let failed = matches!(
                    &event,
                    ProcessEvent::Finished {
                        exit_code: Some(code),
                        ..
                    } if *code != 0
                );
                let _ = this.update(cx, |view, cx| {
                    if view.maven_seq != seq {
                        return;
                    }
                    match event {
                        ProcessEvent::Started { label, .. } => {
                            view.maven_console.write_heading(&label);
                            view.record_run(&label, cx);
                        }
                        ProcessEvent::Output { bytes } => {
                            view.maven_console.write_bytes(&bytes);
                            append_maven_output_text(&mut view.maven_output_text, &bytes);
                            // 对齐 macOS 智能滚动：仅当用户仍停在底部才拉底。
                            if view.run_follow_end && view.maven_console.is_at_bottom(cx) {
                                view.maven_console.scroll_to_bottom(cx);
                            }
                            // TEMP_DIAG: 定位“输出只剩一行”问题。
                            let (cols, rows) = view.maven_console.size_cells();
                            let offset = view.maven_console.display_offset(cx);
                            tracing::debug!(
                                target: "maven_pump",
                                bytes = bytes.len(),
                                terminal_cols = cols,
                                terminal_rows = rows,
                                display_offset = offset,
                                "maven output chunk"
                            );
                        }
                        ProcessEvent::Finished {
                            exit_code,
                            cancelled,
                            error,
                        } => {
                            if let Some(error) = error {
                                view.maven_console.write_error(&error);
                            }
                            if let Some(code) = exit_code {
                                view.maven_console.write_muted(&format!(
                                    "{}：{}",
                                    crate::i18n::menu_text(cx, "run.exited"),
                                    code
                                ));
                            } else if cancelled {
                                view.maven_console
                                    .write_muted(crate::i18n::menu_text(cx, "run.finished"));
                            }
                            view.set_maven_running(false, cx);
                        }
                    }
                    cx.notify();
                });
                if finished {
                    // 对齐 mac：构建失败时把输出交给 core `maven.diagnostics`
                    // 解析为可点击的 issue 列表。
                    if failed {
                        let output = this
                            .update(cx, |view, _cx| {
                                (view.maven_seq == seq).then(|| view.maven_output_text.clone())
                            })
                            .unwrap_or(None);
                        if let Some(output) = output {
                            let parsed = client
                                .execute::<serde_json::Value, serde_json::Value>(
                                    &cx,
                                    "maven.diagnostics",
                                    serde_json::json!({ "root": root, "output": output }),
                                )
                                .await;
                            let _ = this.update(cx, |view, cx| {
                                if view.maven_seq != seq {
                                    return;
                                }
                                view.maven_issues = parsed
                                    .ok()
                                    .map(|value| parse_maven_issues(&value))
                                    .unwrap_or_default();
                                cx.notify();
                            });
                        }
                    }
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
        icon: Icon,
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
            .child(icon.size(px(14.0)).text_color(ThemeColors::text_muted()))
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
                "run-restart".to_string(),
                IconName::RotateCw,
                crate::i18n::menu_text(cx, "run.restart").to_string(),
                !running,
                cx,
                |this, _window, cx| this.restart_selected_run(cx),
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
                    // 打开跟随时立即滚到底；之后的输出跟随由事件泵负责。
                    if this.run_follow_end {
                        this.run_console.scroll_to_bottom(cx);
                    }
                    cx.notify();
                }))
                .into_any_element(),
        );
        buttons.push(Self::header_button(
            "run-clear-output".to_string(),
            IconName::Trash,
            crate::i18n::menu_text(cx, "run.clearOutput").to_string(),
            self.run_console.is_empty(),
            cx,
            |this, _window, cx| {
                this.run_console.clear();
                cx.notify();
            },
        ));
        self.render_pane_header(Icon::new(IconName::Play), title, status, buttons, cx)
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
        // 状态区：运行中标记 + issue 计数徽标（对齐 mac 头部徽标）。
        let has_status = self.maven_running || !self.maven_issues.is_empty();
        let status = has_status.then(|| {
            h_flex()
                .gap_2()
                .items_center()
                .when(self.maven_running, |status| {
                    status.child(
                        div()
                            .text_xs()
                            .text_color(ThemeColors::accent_green())
                            .child(crate::i18n::menu_text(cx, "run.running")),
                    )
                })
                .when(!self.maven_issues.is_empty(), |status| {
                    status.child(
                        h_flex()
                            .gap_1()
                            .items_center()
                            .child(
                                Icon::new(IconName::TriangleAlert)
                                    .size(px(12.0))
                                    .text_color(ThemeColors::warning()),
                            )
                            .child(
                                div()
                                    .text_xs()
                                    .text_color(ThemeColors::warning())
                                    .child(self.maven_issues.len().to_string()),
                            ),
                    )
                })
                .into_any_element()
        });
        let can_rerun = self.last_maven_goal.is_some() && !self.maven_running;
        let can_clear = !self.maven_console.is_empty() || self.maven_title.is_some();
        self.render_pane_header(
            Icon::new(IconName::Box),
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
                        this.maven_console.clear();
                        cx.notify();
                    },
                ),
            ],
            cx,
        )
    }

    /// Run 面板体：Java 准备状态区块 + 配置列表/详情/输出区；头部由
    /// `render_run_header` 负责。
    fn render_run_panel(&mut self, cx: &mut Context<Self>) -> AnyElement {
        let preparation = self.render_java_preparation(cx);
        v_flex()
            .size_full()
            .children(preparation)
            .child(self.render_run_body(cx))
            .into_any_element()
    }

    /// 宿主 Java LSP 状态快照（工作台实体被释放时返回 `None`）。
    fn java_preparation_snapshot(&self, cx: &App) -> Option<lsp::JavaLspStatus> {
        Some(
            self.workbench
                .as_ref()?
                .upgrade()?
                .read(cx)
                .java_lsp_status(),
        )
    }

    /// Java 语言服务准备状态区块（对齐 Tauri `ProjectPreparationStatus`）：
    /// 摘要行 + 可展开的四阶段列表、说明、设置/日志入口和构建失败策略重置。
    fn render_java_preparation(&self, cx: &mut Context<Self>) -> Option<AnyElement> {
        let status = self.java_preparation_snapshot(cx)?;
        let preparation = status.project_preparation.as_ref();
        let phase = preparation
            .and_then(|value| value.get("phase"))
            .and_then(serde_json::Value::as_str)
            .unwrap_or("");
        let preparation_status = preparation
            .and_then(|value| value.get("status"))
            .and_then(serde_json::Value::as_str)
            .unwrap_or("");
        // 无会话且无准备快照（或准备已停止）时不占位，对齐 Tauri 的
        // `preparation.phase === "stopped"` 隐藏语义。
        if preparation.is_none() && (status.state == "idle" || status.state == "stopped") {
            return None;
        }
        if phase == "stopped" {
            return None;
        }
        let failed = status.state == "failed" || preparation_status == "failed";
        let ready = !failed && (preparation_status == "ready" || status.state == "ready");
        let loading = !failed && !ready;
        let label_key = if failed {
            "preparation.failed"
        } else {
            match phase {
                "importing" | "configuring" | "building" | "ready" => {
                    // `ready` 阶段固定用就绪文案，进行中阶段显示对应动作。
                    if phase == "ready" {
                        "preparation.ready"
                    } else {
                        // 动态键来自 Core 稳定枚举，上面已穷举。
                        match phase {
                            "importing" => "preparation.importing",
                            "configuring" => "preparation.configuring",
                            _ => "preparation.building",
                        }
                    }
                }
                _ => "preparation.starting",
            }
        };
        let expanded = self.java_prep_expanded;
        let policy =
            crate::settings::java_build_failure_policy(crate::settings::get(cx), &self.working_dir);
        let show_policy_reset = policy == "alwaysProceed";

        let summary = h_flex()
            .id("java-prep-summary")
            .w_full()
            .items_center()
            .gap_1p5()
            .px_2()
            .py_1()
            .rounded_sm()
            .cursor_pointer()
            .text_xs()
            .hover(|h| h.bg(ThemeColors::bg_tab_hover()))
            .on_click(cx.listener(|this, _event, _window, cx| {
                this.java_prep_expanded = !this.java_prep_expanded;
                cx.notify();
            }))
            .child(
                Icon::new(if expanded {
                    IconName::ChevronDown
                } else {
                    IconName::ChevronRight
                })
                .size(px(12.0))
                .text_color(ThemeColors::text_muted()),
            )
            .child(if loading {
                Icon::new(IconName::LoaderCircle)
                    .size(px(12.0))
                    .text_color(ThemeColors::text_muted())
                    .into_any_element()
            } else if failed {
                div()
                    .text_color(ThemeColors::destructive())
                    .child("!".to_string())
                    .into_any_element()
            } else {
                Icon::new(IconName::Check)
                    .size(px(12.0))
                    .text_color(ThemeColors::accent_green())
                    .into_any_element()
            })
            .child(
                div()
                    .truncate()
                    .text_color(if failed {
                        ThemeColors::destructive()
                    } else {
                        ThemeColors::text_muted()
                    })
                    .child(crate::i18n::menu_text(cx, label_key).to_string()),
            );

        // 展开内容：四阶段进度、说明、设置/日志入口、构建失败策略。
        let phase_rows: Vec<AnyElement> = ["starting", "importing", "configuring", "building"]
            .iter()
            .map(|step| {
                let key = format!("preparation.{step}");
                let current = !failed && !ready && phase == *step;
                h_flex()
                    .items_center()
                    .gap_1()
                    .text_color(if current {
                        ThemeColors::text_primary()
                    } else {
                        ThemeColors::text_muted()
                    })
                    .when(current, |row| row.font_weight(FontWeight::MEDIUM))
                    .child(div().child(if current { "› " } else { "· " }))
                    .child(div().child(crate::i18n::menu_text(cx, &key).to_string()))
                    .into_any_element()
            })
            .collect();
        let mut details = v_flex()
            .w_full()
            .px_2()
            .pb_2()
            .gap_1()
            .text_xs()
            .children(phase_rows)
            .child(
                div()
                    .text_color(ThemeColors::text_muted())
                    .child(crate::i18n::menu_text(cx, "preparation.explanation").to_string()),
            )
            .child(
                h_flex()
                    .items_center()
                    .gap_3()
                    .pt_1()
                    .child(
                        Button::new("java-prep-settings")
                            .small()
                            .ghost()
                            .label(crate::i18n::menu_text(cx, "preparation.settings"))
                            .on_click(cx.listener(|this, _event, _window, cx| {
                                cx.emit(BottomPanelEvent::OpenSettings { category: "lsp" });
                                this.java_prep_expanded = false;
                                cx.notify();
                            })),
                    )
                    .child(
                        Button::new("java-prep-logs")
                            .small()
                            .ghost()
                            .label(crate::i18n::menu_text(cx, "preparation.logs"))
                            .on_click(cx.listener(|this, _event, _window, cx| {
                                cx.emit(BottomPanelEvent::OpenSettings { category: "logs" });
                                this.java_prep_expanded = false;
                                cx.notify();
                            })),
                    ),
            );
        if show_policy_reset {
            details = details.child(
                v_flex()
                    .w_full()
                    .gap_1()
                    .border_t_1()
                    .border_color(ThemeColors::border())
                    .pt_2()
                    .mt_1()
                    .text_color(ThemeColors::text_muted())
                    .child(
                        div().child(
                            crate::i18n::menu_text(cx, "run.javaBuildAlwaysContinueEnabled")
                                .to_string(),
                        ),
                    )
                    .child(
                        Button::new("java-prep-policy-reset")
                            .small()
                            .ghost()
                            .label(crate::i18n::menu_text(cx, "run.javaBuildAskAgain"))
                            .on_click(cx.listener(|this, _event, _window, cx| {
                                let root = this.working_dir.clone();
                                crate::settings::update(cx, |settings| {
                                    settings
                                        .java_build_failure_policy_by_workspace
                                        .remove(&crate::settings::workspace_preference_key(&root));
                                });
                                cx.notify();
                            })),
                    ),
            );
        }

        Some(
            v_flex()
                .flex_shrink_0()
                .w_full()
                .border_b_1()
                .border_color(ThemeColors::border())
                .px_1()
                .py_1()
                .child(summary)
                .when(expanded, |block| block.child(details))
                .into_any_element(),
        )
    }

    /// 配置详情区块（对齐 Tauri 配置详情）：类型与主类，随选中配置变化；
    /// 未选中时显示占位文案（Tauri `run.selectConfiguration`）。
    fn render_run_config_details(&self, cx: &Context<Self>) -> AnyElement {
        let Some(item) = self.selected_run_item() else {
            return v_flex()
                .flex_shrink_0()
                .w_full()
                .border_b_1()
                .border_color(ThemeColors::border())
                .px_2()
                .py_1p5()
                .gap_1()
                .child(
                    div()
                        .text_xs()
                        .font_weight(FontWeight::MEDIUM)
                        .text_color(ThemeColors::text_primary())
                        .child(crate::i18n::menu_text(cx, "run.details").to_string()),
                )
                .child(
                    div()
                        .text_xs()
                        .text_color(ThemeColors::text_muted())
                        .child(crate::i18n::menu_text(cx, "run.selectConfiguration").to_string()),
                )
                .into_any_element();
        };
        // 类型展示与 Tauri 配置详情一致：优先 provider 语义，退回 kind。
        let type_label = if item.provider.contains("spring-boot") {
            "Spring Boot".to_string()
        } else if item.provider.starts_with("java.") {
            "Java".to_string()
        } else if item.provider.contains("maven") {
            "Maven".to_string()
        } else {
            item.kind.clone()
        };
        let mut rows = v_flex().gap_1();
        rows = rows.child(
            h_flex()
                .items_start()
                .gap_2()
                .text_xs()
                .child(
                    div()
                        .flex_shrink_0()
                        .text_color(ThemeColors::text_muted())
                        .child(crate::i18n::menu_text(cx, "run.detailType").to_string()),
                )
                .child(
                    div()
                        .min_w_0()
                        .truncate()
                        .text_color(ThemeColors::text_primary())
                        .child(type_label),
                ),
        );
        if let Some(main_class) = item.main_class.as_deref().filter(|v| !v.is_empty()) {
            rows = rows.child(
                h_flex()
                    .items_start()
                    .gap_2()
                    .text_xs()
                    .child(
                        div()
                            .flex_shrink_0()
                            .text_color(ThemeColors::text_muted())
                            .child(crate::i18n::menu_text(cx, "run.detailMainClass").to_string()),
                    )
                    .child(
                        div()
                            .min_w_0()
                            .truncate()
                            .font_family(crate::fonts::mono_family(cx))
                            .text_color(ThemeColors::text_primary())
                            .child(main_class.to_string()),
                    ),
            );
        }
        v_flex()
            .flex_shrink_0()
            .w_full()
            .border_b_1()
            .border_color(ThemeColors::border())
            .px_2()
            .py_1p5()
            .gap_1()
            .child(
                div()
                    .text_xs()
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(ThemeColors::text_primary())
                    .child(crate::i18n::menu_text(cx, "run.details").to_string()),
            )
            .child(rows)
            .into_any_element()
    }

    /// Run 面板主体：配置列表 + 详情/输出区；头部由 `render_run_header` 负责。
    fn render_run_body(&mut self, cx: &mut Context<Self>) -> AnyElement {
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

        // 列表分组（对齐 Tauri RunPane：服务 / 基础设施 / 其他运行配置→应用+任务）。
        let mut services: Vec<RunConfigItem> = Vec::new();
        let mut infrastructure: Vec<RunConfigItem> = Vec::new();
        let mut applications: Vec<RunConfigItem> = Vec::new();
        let mut tasks: Vec<RunConfigItem> = Vec::new();
        for item in &self.run_configs {
            match item.normalized_group() {
                Some(RunConfigGroup::Service) => services.push(item.clone()),
                Some(RunConfigGroup::Infrastructure) => infrastructure.push(item.clone()),
                Some(RunConfigGroup::Application) => applications.push(item.clone()),
                Some(RunConfigGroup::Task) => tasks.push(item.clone()),
                None => {}
            }
        }
        for group in [
            &mut services,
            &mut infrastructure,
            &mut applications,
            &mut tasks,
        ] {
            RunConfigItem::sort_by_name(group);
        }

        let mut sidebar = v_flex().py_1().gap_0p5().child(
            div()
                .px_2()
                .py_1()
                .text_xs()
                .font_weight(FontWeight::MEDIUM)
                .text_color(ThemeColors::text_muted())
                .child(crate::i18n::menu_text(cx, "run.configurations").to_string()),
        );
        sidebar = sidebar.children(self.render_run_config_rows(&services, "services", cx));
        if !infrastructure.is_empty() {
            sidebar = sidebar.child(self.render_run_group_toggle(
                "run.infrastructure",
                "infrastructure-toggle",
                self.run_infrastructure_collapsed,
                cx,
            ));
            if !self.run_infrastructure_collapsed {
                sidebar =
                    sidebar.children(self.render_run_config_rows(&infrastructure, "infra", cx));
            }
        }
        let other: Vec<&RunConfigItem> = applications.iter().chain(tasks.iter()).collect();
        if !other.is_empty() {
            sidebar = sidebar.child(self.render_run_group_toggle(
                "run.otherConfigurations",
                "other-toggle",
                self.run_other_collapsed,
                cx,
            ));
            if !self.run_other_collapsed {
                sidebar = sidebar
                    .child(
                        div()
                            .px_2()
                            .py_1()
                            .text_xs()
                            .text_color(ThemeColors::text_muted())
                            .child(crate::i18n::menu_text(cx, "run.applications").to_string()),
                    )
                    .children(self.render_run_config_rows(&applications, "apps", cx))
                    .child(
                        div()
                            .px_2()
                            .py_1()
                            .text_xs()
                            .text_color(ThemeColors::text_muted())
                            .child(crate::i18n::menu_text(cx, "run.tasks").to_string()),
                    )
                    .children(self.render_run_config_rows(&tasks, "tasks", cx));
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
                            .child(sidebar)
                            .children(diagnostic_rows),
                    )
                    .child(
                        v_flex()
                            .flex_1()
                            .h_full()
                            .min_h_0()
                            .child(self.render_run_config_details(cx))
                            .child(self.render_run_output(cx)),
                    ),
            )
            .into_any_element()
    }

    /// 左侧列表的配置行（对齐 Tauri `ConfigurationSection`）：单行名称 +
    /// 悬停显示的编辑入口 + 常驻运行按钮；无分组的配置不渲染。
    fn render_run_config_rows(
        &self,
        items: &[RunConfigItem],
        section_id: &str,
        cx: &mut Context<Self>,
    ) -> Vec<AnyElement> {
        items
            .iter()
            .enumerate()
            .map(|(index, item)| {
                let id = item.id.clone();
                let run_id = item.id.clone();
                let selected = self.selected_run_config.as_deref() == Some(item.id.as_str());
                // 每行独立 hover group，避免兄弟行共享 group 名互相影响。
                let group_name = format!("run-row-{section_id}-{index}");
                h_flex()
                    .id(format!("run-config-{section_id}-{index}-{}", item.id))
                    .group(group_name.clone())
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
                        Icon::new(IconName::Code)
                            .size(px(12.0))
                            .flex_shrink_0()
                            .text_color(ThemeColors::text_muted()),
                    )
                    .child(div().flex_1().min_w_0().truncate().child(item.name.clone()))
                    .child(
                        div()
                            .opacity(0.0)
                            .group_hover(group_name, |style| style.opacity(1.0))
                            .child(
                                Button::new(format!("run-edit-{section_id}-{index}"))
                                    .small()
                                    .ghost()
                                    .icon(IconName::Cog)
                                    .tooltip(crate::i18n::menu_text(cx, "run.editService"))
                                    .on_click(cx.listener(move |this, _event, _window, cx| {
                                        cx.emit(BottomPanelEvent::OpenSettings { category: "run" });
                                        this.java_prep_expanded = false;
                                        cx.notify();
                                    })),
                            ),
                    )
                    .child(
                        Button::new(format!("run-start-{section_id}-{index}"))
                            .small()
                            .ghost()
                            .icon(IconName::Play)
                            .tooltip(run_ui_text(cx, "运行", "Run"))
                            .on_click(cx.listener(move |this, _event, _window, cx| {
                                this.run_configuration_id(run_id.clone(), cx);
                            })),
                    )
                    .on_click(cx.listener(move |this, _event, _window, cx| {
                        this.select_run_config(id.clone(), cx);
                        cx.notify();
                    }))
                    .into_any_element()
            })
            .collect()
    }

    /// 折叠分组标题行（对齐 Tauri 基础设施/其他运行配置的 ▸/▾ 按钮）。
    fn render_run_group_toggle(
        &self,
        title_key: &'static str,
        toggle_id: &'static str,
        collapsed: bool,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        h_flex()
            .id(toggle_id)
            .mt_1()
            .w_full()
            .items_center()
            .justify_between()
            .px_2()
            .py_1()
            .rounded_sm()
            .cursor_pointer()
            .text_xs()
            .font_weight(FontWeight::MEDIUM)
            .text_color(ThemeColors::text_muted())
            .hover(|h| h.text_color(ThemeColors::text_primary()))
            .on_click(cx.listener(move |this, _event, _window, cx| {
                if toggle_id == "infrastructure-toggle" {
                    this.run_infrastructure_collapsed = !this.run_infrastructure_collapsed;
                } else {
                    this.run_other_collapsed = !this.run_other_collapsed;
                }
                cx.notify();
            }))
            .child(crate::i18n::menu_text(cx, title_key).to_string())
            .child(
                Icon::new(if collapsed {
                    IconName::ChevronRight
                } else {
                    IconName::ChevronDown
                })
                .size(px(12.0))
                .text_color(ThemeColors::text_muted()),
            )
            .into_any_element()
    }

    /// 右侧进程输出区：空态显示占位文案，有输出时渲染控制台
    /// （对齐 Tauri `RunOutputText` 的 emptyLabel 语义）。
    fn render_run_output(&self, cx: &mut Context<Self>) -> AnyElement {
        if self.run_console.is_empty() {
            return v_flex()
                .flex_1()
                .min_h_0()
                .items_center()
                .justify_center()
                .px_2()
                .text_xs()
                .text_color(ThemeColors::text_muted())
                .child(div().child(crate::i18n::menu_text(cx, "run.processOutput").to_string()))
                .child(
                    div()
                        .mt_1()
                        .child(crate::i18n::menu_text(cx, "run.emptyOutput").to_string()),
                )
                .into_any_element();
        }
        h_flex()
            .flex_1()
            .min_h_0()
            .relative()
            .flex()
            .flex_col()
            .on_mouse_up(
                MouseButton::Left,
                cx.listener(|this, _event, _window, cx| {
                    this.run_console.copy_selection(cx);
                }),
            )
            .child(
                div()
                    .flex_1()
                    .min_h_0()
                    .child(self.run_console.view.clone()),
            )
            .when(!self.run_at_bottom, |panel| {
                panel.child(Self::jump_to_latest_button("run-jump-latest", false, cx))
            })
            .into_any_element()
    }

    /// Maven 面板体：issue 列表（失败诊断，可点击跳转）+ 输出区；头部由
    /// `render_maven_header` 负责。
    fn render_maven_panel(&self, cx: &mut Context<Self>) -> AnyElement {
        let issues = self.maven_issues.clone();
        div()
            .flex_1()
            .w_full()
            .min_h_0()
            .flex()
            .flex_col()
            .when(!issues.is_empty(), |panel| {
                // 对齐 mac `MavenBuildOutputView.issueList`：错误/警告可点击
                // 跳源码，限高避免挤掉输出区。
                panel.child({
                    let rows: Vec<AnyElement> = issues
                        .iter()
                        .map(|issue| {
                            let location = match issue.column {
                                Some(column) => format!("{}:{}:{}", issue.path, issue.line, column),
                                None => format!("{}:{}", issue.path, issue.line),
                            };
                            let path = issue.path.clone();
                            let line = issue.line;
                            div()
                                .id(format!(
                                    "maven-issue-{}-{line}-{}",
                                    path,
                                    issue.column.is_some()
                                ))
                                .w_full()
                                .flex_shrink_0()
                                .px_2p5()
                                .py_1()
                                .rounded(px(4.0))
                                .hover(|row| row.bg(ThemeColors::bg_tab_hover()))
                                .on_mouse_down(
                                    MouseButton::Left,
                                    cx.listener(move |_this, _event, _window, cx| {
                                        // maven 行号 1 起，跳转语义一致。
                                        cx.emit(BottomPanelEvent::OpenFile {
                                            path: path.clone(),
                                            line: line as u32,
                                        });
                                    }),
                                )
                                .child(
                                    h_flex()
                                        .items_start()
                                        .gap_1p5()
                                        .child(
                                            Icon::new(if issue.severity == "warning" {
                                                IconName::TriangleAlert
                                            } else {
                                                IconName::OctagonX
                                            })
                                            .size(px(13.0))
                                            .text_color(if issue.severity == "warning" {
                                                ThemeColors::warning()
                                            } else {
                                                ThemeColors::destructive()
                                            }),
                                        )
                                        .child(
                                            v_flex()
                                                .min_w_0()
                                                .child(
                                                    div()
                                                        .text_xs()
                                                        .font_weight(FontWeight::MEDIUM)
                                                        .text_color(ThemeColors::text_primary())
                                                        .truncate()
                                                        .child(issue.message.clone()),
                                                )
                                                .child(
                                                    div()
                                                        .text_xs()
                                                        .text_color(ThemeColors::text_muted())
                                                        .truncate()
                                                        .child(location),
                                                ),
                                        ),
                                )
                                .into_any_element()
                        })
                        .collect();
                    div()
                        .max_h(px(132.0))
                        .w_full()
                        .flex_shrink_0()
                        .overflow_y_scrollbar()
                        .border_b_1()
                        .border_color(ThemeColors::border())
                        .bg(ThemeColors::surface())
                        .py_1()
                        .children(rows)
                })
            })
            .child(
                div()
                    .flex_1()
                    .min_h_0()
                    .relative()
                    .on_mouse_up(
                        MouseButton::Left,
                        cx.listener(|this, _event, _window, cx| {
                            this.maven_console.copy_selection(cx);
                        }),
                    )
                    .child(self.maven_console.view.clone())
                    .when(!self.maven_at_bottom, |panel| {
                        panel.child(Self::jump_to_latest_button("maven-jump-latest", true, cx))
                    }),
            )
            .into_any_element()
    }

    /// “跳到最新”浮层按钮（对齐 macOS `Jump to latest`）：用户上翻后出现在
    /// 控制台右下角，点击回到底部并恢复跟随。
    fn jump_to_latest_button(id: &'static str, maven: bool, cx: &mut Context<Self>) -> AnyElement {
        div()
            .absolute()
            .bottom_2()
            .right_3()
            .child(
                Button::new(id)
                    .small()
                    .icon(IconName::ArrowDownToLine)
                    .label(crate::i18n::menu_text(cx, "ui.jumpToLatest").to_string())
                    .on_click(cx.listener(move |this, _event, _window, cx| {
                        if maven {
                            this.maven_console.scroll_to_bottom(cx);
                        } else {
                            this.run_console.scroll_to_bottom(cx);
                        }
                        cx.notify();
                    })),
            )
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
                            .font_family(crate::fonts::mono_family(cx))
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

        // 主题切换时把新调色板同步给 Run/Maven 输出控制台（与集成终端一致）；
        // 否则切到深色后控制台仍保持创建时的浅色配色。
        let background = crate::theme::palette().background;
        if background != self.console_background {
            self.run_console.apply_config(cx);
            self.maven_console.apply_config(cx);
            self.console_background = background;
        }

        // 各窗格自带按钮头（对齐 Tauri：底部无标签切换条，切换只走左侧活动栏）。
        let (header, body) = match self.active_tab {
            BottomTab::Terminal => {
                let status = self.terminal_status(cx);
                let (at_bottom, has_session) = {
                    let terminal = self.terminal.read(cx);
                    (terminal.is_at_bottom(cx), terminal.has_session())
                };
                (
                    self.render_pane_header(
                        Icon::new(IconName::Terminal),
                        crate::i18n::menu_text(cx, "workbench.terminal").to_string(),
                        status,
                        vec![
                            Self::header_button(
                                "terminal-restart".to_string(),
                                IconName::RefreshCw,
                                crate::i18n::menu_text(cx, "terminal.restartSession").to_string(),
                                false,
                                cx,
                                |this, _window, cx| {
                                    let _ = this.terminal.update(cx, |term, cx| term.restart(cx));
                                },
                            ),
                            Self::header_button(
                                "terminal-search".to_string(),
                                IconName::Search,
                                crate::i18n::menu_text(cx, "terminal.find").to_string(),
                                // 搜索栏是会话网格上的浮层，没有会话时无处可显示。
                                !has_session,
                                cx,
                                |this, window, cx| {
                                    let _ = this
                                        .terminal
                                        .update(cx, |term, cx| term.open_search(window, cx));
                                },
                            ),
                            Self::header_button(
                                "terminal-scroll-bottom".to_string(),
                                IconName::ArrowDownToLine,
                                crate::i18n::menu_text(cx, "terminal.scrollToBottom").to_string(),
                                at_bottom,
                                cx,
                                |this, _window, cx| {
                                    let _ = this
                                        .terminal
                                        .update(cx, |term, cx| term.scroll_to_bottom(cx));
                                },
                            ),
                            Self::header_button(
                                "terminal-clear".to_string(),
                                IconName::Trash,
                                crate::i18n::menu_text(cx, "ui.clear").to_string(),
                                false,
                                cx,
                                |this, _window, cx| {
                                    let _ = this.terminal.update(cx, |term, cx| term.clear(cx));
                                },
                            ),
                            Self::header_button(
                                "terminal-close".to_string(),
                                IconName::X,
                                crate::i18n::menu_text(cx, "menu.closeTerminal").to_string(),
                                false,
                                cx,
                                |this, _window, cx| this.close_terminal_session(cx),
                            ),
                        ],
                        cx,
                    ),
                    div()
                        .size_full()
                        .child(self.terminal.clone())
                        .into_any_element(),
                )
            }
            BottomTab::Run => (self.render_run_header(cx), self.render_run_panel(cx)),
            BottomTab::Maven => (self.render_maven_header(cx), self.render_maven_panel(cx)),
            BottomTab::Diagnostics => {
                // 严重级统计：总数摘要按最高严重级着色（对齐 Tauri
                // DiagnosticsPane 的 problemSummary/problemSummaryTone），
                // 非零 error/warning 用图标计数（对齐 macOS Problems 头部徽标）。
                let error_count = self
                    .diagnostics
                    .iter()
                    .filter(|diagnostic| diagnostic.severity == "error")
                    .count();
                let warning_count = self
                    .diagnostics
                    .iter()
                    .filter(|diagnostic| diagnostic.severity == "warning")
                    .count();
                let info_count = self.diagnostics.len() - error_count - warning_count;
                let total = self.diagnostics.len();
                let summary_color = if error_count > 0 {
                    ThemeColors::destructive()
                } else if warning_count > 0 {
                    ThemeColors::warning()
                } else if info_count > 0 {
                    ThemeColors::accent_blue()
                } else {
                    ThemeColors::text_muted()
                };
                let count_key = if total == 1 {
                    "diagnostics.problemCountOne"
                } else {
                    "diagnostics.problemCount"
                };
                let summary =
                    crate::i18n::menu_text(cx, count_key).replace("{count}", &total.to_string());
                let mut status = h_flex()
                    .gap_2()
                    .items_center()
                    .child(div().text_xs().text_color(summary_color).child(summary));
                if error_count > 0 {
                    status = status.child(
                        h_flex()
                            .gap_1()
                            .items_center()
                            .child(
                                Icon::new(IconName::OctagonX)
                                    .size(px(12.0))
                                    .text_color(ThemeColors::destructive()),
                            )
                            .child(
                                div()
                                    .text_xs()
                                    .text_color(ThemeColors::destructive())
                                    .child(error_count.to_string()),
                            ),
                    );
                }
                if warning_count > 0 {
                    status = status.child(
                        h_flex()
                            .gap_1()
                            .items_center()
                            .child(
                                Icon::new(IconName::TriangleAlert)
                                    .size(px(12.0))
                                    .text_color(ThemeColors::warning()),
                            )
                            .child(
                                div()
                                    .text_xs()
                                    .text_color(ThemeColors::warning())
                                    .child(warning_count.to_string()),
                            ),
                    );
                }
                (
                    self.render_pane_header(
                        Icon::new(IconName::TriangleAlert),
                        crate::i18n::menu_text(cx, "workbench.diagnostics").to_string(),
                        Some(status.into_any_element()),
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
                )
            }
            BottomTab::GitLog => (
                self.render_pane_header(
                    Icon::new(IconName::GitGraph),
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
            BottomTab::Tests => (
                self.render_pane_header(
                    Icon::new(IconName::BadgeCheck),
                    crate::i18n::menu_text(cx, "workbench.tests").to_string(),
                    None,
                    vec![],
                    cx,
                ),
                run_center_text(placeholder_text(cx, "tests")),
            ),
            BottomTab::Debug => (
                self.render_pane_header(
                    Icon::default().data(IDEA_ICON_DEBUGGER),
                    crate::i18n::menu_text(cx, "workbench.debug").to_string(),
                    None,
                    vec![],
                    cx,
                ),
                run_center_text(placeholder_text(cx, "debug")),
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

/// Tests/Debug 占位面板空态文案（UI 已就位，功能待接入）。
fn placeholder_text(cx: &gpui_kit::App, tab: &str) -> String {
    let (zh, en) = match tab {
        "tests" => (
            "测试面板 UI 占位，功能接入中。",
            "Tests panel placeholder; functionality coming soon.",
        ),
        _ => (
            "调试面板 UI 占位，功能接入中。",
            "Debug panel placeholder; functionality coming soon.",
        ),
    };
    run_ui_text(cx, zh, en)
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

    /// 复现“Maven 输出只剩一行”的终端层验证：与 run_maven_goal 相同的字节
    /// 序列（清屏 → 命令回显 → 30 行流式输出）逐块喂入终端状态后，光标应
    /// 深入网格、视口跟随底部。若此测试通过而线上仍只显示一行，问题在
    /// 布局/PTY 链路而非终端语义。
    #[test]
    fn maven_stream_clears_screen_and_keeps_lines() {
        let (tx, _rx) = std::sync::mpsc::channel();
        let proxy = gpui_xterm::GpuiEventProxy::new(tx);
        let mut state = gpui_xterm::TerminalState::new(120, 30, proxy);

        state.process_bytes(b"\x1b[2J\x1b[H");
        state.process_bytes(b"\x1b[1m$ mvn clean\x1b[0m\r\n");
        for i in 0..30 {
            state.process_bytes(format!("[INFO] Building module-{i}\r\n").as_bytes());
        }

        assert_eq!(state.display_offset(), 0, "viewport should follow the tail");
        state.with_term(|term| {
            use alacritty_terminal::grid::Dimensions as _;
            let grid = term.grid();
            assert_eq!(grid.screen_lines(), 30);
            let cursor_row = grid.cursor.point.line.0;
            // 31 行写入 30 行网格：第一行（回显）滚入回滚区，光标在末行。
            assert_eq!(
                cursor_row, 29,
                "cursor should sit on the last grid row after scrolling once, got {cursor_row}"
            );
        });
    }

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
