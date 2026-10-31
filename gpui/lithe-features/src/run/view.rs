//! Run 工具窗：运行配置、会话控制和控制台。
//!
//! 视图只持有 UI 状态与进程树句柄；Core 调用、文件写入和子进程读取都在
//! `config` / `session` 模块里完成后回到视图线程。Run 按钮、Stop 和重跑都
//! 走同一条 `start_configuration` / `stop_configuration` 链路。

use std::collections::{BTreeMap, HashSet};
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::Arc;
use std::time::Duration;

use async_channel::Receiver;
use gpui_kit::base::TextSelection;
use gpui_kit::component::alert::Alert;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::checkbox::Checkbox;
use gpui_kit::component::menu::{PopupMenu, PopupMenuItem};
use gpui_kit::component::resizable::{ResizableState, h_resizable, resizable_panel};
use gpui_kit::component::{
    Disableable as _, Icon, IconName, Selectable as _, Sizable as _, h_flex, v_flex,
};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    AnyElement, App, AppContext as _, ClickEvent, ClipboardItem, Context, DismissEvent, Entity,
    EventEmitter, FocusHandle, Focusable as _, FontWeight, Hsla, InteractiveElement as _,
    IntoElement, KeyBinding, MouseButton, ParentElement, Render, ScrollStrategy, SharedString,
    StatefulInteractiveElement as _, Styled, Subscription, Task, TextStyleRefinement,
    UniformListScrollHandle, WhiteSpace, Window, anchored, deferred, div, px, uniform_list,
};
use lithe_core_client::CoreClient;
use lithe_git_host::ProcessTree;
use lithe_ui::i18n::tr;
use lithe_ui::{LitheIcon, LitheMetrics, LitheTokens, MONO_FONT_FAMILY, current_tokens, icon};

use super::config::{self, LoadedRunConfigurations};
use super::model::{
    PreparationPhase, PreparationStatus, ProjectPreparation, RunConfiguration, RunDiagnostic,
    RunExecution, RunLanguage, RunScope,
};
use super::session::{self, SessionEvent};

/// Run 面板状态变化。工作台用它刷新顶栏 Run/Stop 和配置名。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RunPanelEvent {
    /// 会话或选中配置变化，工作台重新读取顶栏状态。
    StateChanged,
    /// 标题栏的隐藏按钮请求收起底部 dock；由工作台改写布局并持久化。
    HideRequested,
}

impl EventEmitter<RunPanelEvent> for RunPanel {}

/// 启动前保存回调：工作台用它把脏缓冲写盘，面板不直接持有编辑器实体。
///
/// 与 `GitPanel::on_open_file` 等回调同形，避免 `lithe-features` 反向依赖
/// `lithe-workbench`。对齐 Tauri `run.store.ts` 在启动前强制
/// `saveWorkspaceBeforeLaunch` 的语义。
type BeforeLaunchHandler = Rc<dyn Fn(&mut App) + 'static>;

/// 打开设置页编辑指定配置；工作台注入，面板不直接依赖设置视图。
type OpenSettingsHandler = Rc<dyn Fn(&str, &mut Window, &mut App) + 'static>;

gpui_kit::actions!(
    lithe_run_console,
    [
        // 复制运行控制台当前选中的文本；没有选中时复制全部输出。
        CopySelection
    ]
);

/// 控制台自己的键上下文。只有控制台获得焦点时才绑定 ⌘C / Ctrl+C，避免抢走
/// 编辑器、终端 WebView 和设置页输入框原本的复制键。
const CONSOLE_CONTEXT: &str = "LitheRunConsole";

/// 标题栏高度。对齐 macOS `LitheToolWindowHeader` 的 41pt。
#[allow(dead_code)]
const HEADER_HEIGHT: f32 = 41.0;
#[allow(dead_code)]
const TOOLBAR_HEIGHT: f32 = 36.0;
#[allow(dead_code)]
const SCOPE_RAIL_WIDTH: f32 = 36.0;
/// 配置列表默认宽度。对齐 macOS `lithe.run.configurationListWidth` 的 280。
const CONFIGURATION_LIST_DEFAULT_WIDTH: f32 = 280.0;
/// 配置列表最小宽度。对齐 macOS `RunServicesLayout.configurationMinimum`。
const CONFIGURATION_LIST_MIN_WIDTH: f32 = 240.0;
/// 配置列表最大宽度。对齐 macOS `configurationMaximum` 的 480 上限。
const CONFIGURATION_LIST_MAX_WIDTH: f32 = 480.0;
/// 输出区最小宽度。对齐 macOS `RunServicesLayout.outputMinimum`；低于它时
/// 整个分栏退化成横向滚动，而不是把两栏压到互相压字。
const OUTPUT_MIN_WIDTH: f32 = 320.0;
/// 控制台左侧动作条宽度。对齐 macOS `LitheTheme.ActionStripe.width` 的图标按钮列。
#[allow(dead_code)]
const CONSOLE_ACTION_STRIPE_WIDTH: f32 = 28.0;
/// 控制台单行高度估算。macOS 用 TextKit 量出真实行框；GPUI 的纯文本视图没有
/// 逐行句柄，堆栈跳转按“行号 × 行高”换算滚动偏移，关闭软换行时与真实位置一致。
#[allow(dead_code)]
const CONSOLE_LINE_HEIGHT: f32 = 18.0;
const GROUP_HEADER_HEIGHT: f32 = 26.0;
const CONFIGURATION_ROW_HEIGHT: f32 = 30.0;
const PANEL_PADDING: f32 = 12.0;
const STATUS_LINE_HEIGHT: f32 = 24.0;
/// 虚拟化列表的可视区外预排版高度。滚轮快速拖动时避免露出一片空白。
const CONSOLE_LIST_OVERDRAW: f32 = 400.0;
/// 保留的输出行数上限。
///
/// 旧实现保留 20 万字符并整段 `drain(..)` 裁剪：那是 O(n) 的整段搬移，而且
/// 每次都让 `SelectableText` 对全文重新排版，输出越快越卡。现在按行存储、
/// 按行淘汰，裁剪只丢头部行，配合虚拟化列表只排版可视行。
const MAX_OUTPUT_LINES: usize = 5_000;
/// 输出合批窗口。Maven 这类工具每秒可能打印上百行；窗口内先攒着，
/// 到期一次性并入行缓冲，避免每个数据块都触发一次重排。
const OUTPUT_FLUSH_INTERVAL: Duration = Duration::from_millis(33);

/// 一个配置的当前会话状态。
struct SessionState {
    tree: Option<Arc<ProcessTree>>,
    /// 已提交的输出行。虚拟化列表按行取用，只排版可视范围内的行。
    lines: Vec<SharedString>,
    /// 尚未遇到换行的半行。控制台的字符串拼接边界通常落在行中间，
    /// 直接留在这里等下一块一起补成完整行。
    pending_line: String,
    /// 有输出被行数上限淘汰过。界面据此提示历史被截断。
    truncated: bool,
    starting: bool,
    running: bool,
    /// 用户主动停止；退出码不作为失败展示。
    stopped: bool,
    exit_code: Option<i32>,
    service_url: Option<String>,
}

impl SessionState {
    fn starting() -> Self {
        Self {
            tree: None,
            lines: Vec::new(),
            pending_line: String::new(),
            truncated: false,
            starting: true,
            running: false,
            stopped: false,
            exit_code: None,
            service_url: None,
        }
    }

    fn is_active(&self) -> bool {
        self.starting || self.running
    }
}

/// 运行工具窗。
pub struct RunPanel {
    client: CoreClient,
    root: Option<PathBuf>,
    configurations: Vec<RunConfiguration>,
    default_id: Option<String>,
    selected_id: Option<String>,
    #[allow(dead_code)]
    scope: RunScope,
    pinned: HashSet<String>,
    sessions: BTreeMap<String, SessionState>,
    diagnostics: Vec<RunDiagnostic>,
    loading: bool,
    error: Option<SharedString>,
    generation: u64,
    pending_initial_load: bool,
    /// 顶栏 Run 在没有配置时先打开面板；配置加载完成后自动启动一次。
    pending_run: bool,
    /// 用户点击重新运行时等待当前进程退出后再启动。
    restart_pending: Option<String>,
    wrap_output: bool,
    show_details: bool,
    /// 配置列表与输出之间的分栏状态；切项目时重置，让默认宽度重新生效。
    split_state: Entity<ResizableState>,
    /// 配置列表当前宽度。拖拽结束回写，作为下一次重置的初始尺寸。
    configuration_width: f32,
    /// 批量选择模式：勾选多个配置后用工具条统一 Run / Stop。
    batch_selection: bool,
    /// 批量选择模式下被勾选的配置 id。
    checked: HashSet<String>,
    /// 标题栏 more 菜单实体；打开期间持有，关闭时释放。
    /// 工具条「…」弹出菜单与其触发位置；渲染期用 `anchored` 挂到前景层。
    more_menu: Option<(Entity<PopupMenu>, gpui_kit::Point<gpui_kit::Pixels>)>,
    _more_menu_subscription: Option<Subscription>,
    /// 当前浏览的语言分类（Java / Go / Python 等），对齐 Tauri `RunConfigurationBrowser`。
    selected_language: Option<String>,
    /// 控制台的虚拟化列表状态。
    ///
    /// 控制台虚拟化滚动句柄：行高固定（Nowrap 单行），只排版可视行。
    /// gpui 0.3.10 的 `list()` 在此布局下只度量不绘制，不要改回去。
    console_scroll: UniformListScrollHandle,
    /// 是否跟随最新输出；跳转堆栈帧后暂停，「回到最新」恢复。
    console_follow_tail: bool,
    /// 上次同步的行数，用来判断是否需要滚动跟随。
    console_line_count: usize,
    /// 控制台焦点：只有它获得焦点时才响应复制快捷键。
    console_focus: FocusHandle,
    /// 尚未合并进会话状态的输出。按配置 id 累积，由定时器统一刷新。
    pending_output: BTreeMap<String, String>,
    /// 是否已经有一个刷新任务在等待；避免每个输出块都排一个定时器。
    output_flush_scheduled: bool,
    /// 启动前保存回调查调；由工作台注入，见 [`BeforeLaunchHandler`]。
    on_before_launch: Option<BeforeLaunchHandler>,
    /// 打开 Run 配置设置页回调；由工作台注入。
    on_open_settings: Option<OpenSettingsHandler>,
    /// 顶部项目准备状态是否展开（对齐 Tauri `ProjectPreparationStatus` 的 details 状态）。
    preparation_expanded: bool,
    /// Java 项目准备状态（完全对齐 Tauri `ProjectPreparation`，仅在 Java 项目中激活）。
    pub preparation: Option<ProjectPreparation>,
    _preparation_task: Option<Task<()>>,
}

impl RunPanel {
    pub fn new(
        client: CoreClient,
        root: PathBuf,
        _window: &mut Window,
        cx: &mut Context<Self>,
    ) -> Self {
        let root = config::normalize_root(root);
        // 控制台的复制快捷键只在控制台自己的键上下文里生效；这里注册一次，
        // 由控制台根元素的 `key_context` 决定是否匹配。
        cx.bind_keys([
            KeyBinding::new("cmd-c", CopySelection, Some(CONSOLE_CONTEXT)),
            KeyBinding::new("ctrl-c", CopySelection, Some(CONSOLE_CONTEXT)),
        ]);
        // 配置列表 / 输出的分栏状态：拖拽期间由 gpui-kit 维护，提交后回写宽度。
        let split_state = cx.new(|_| ResizableState::default());
        cx.observe(&split_state, |_, _, cx| cx.notify()).detach();
        Self {
            client,
            pending_initial_load: root.is_some(),
            root,
            configurations: Vec::new(),
            default_id: None,
            selected_id: None,
            scope: RunScope::All,
            pinned: HashSet::new(),
            sessions: BTreeMap::new(),
            diagnostics: Vec::new(),
            loading: false,
            error: None,
            generation: 0,
            pending_run: false,
            restart_pending: None,
            wrap_output: false,
            show_details: false,
            split_state,
            configuration_width: CONFIGURATION_LIST_DEFAULT_WIDTH,
            batch_selection: false,
            checked: HashSet::new(),
            more_menu: None,
            _more_menu_subscription: None,
            selected_language: None,
            console_scroll: UniformListScrollHandle::new(),
            console_follow_tail: true,
            console_line_count: 0,
            console_focus: cx.focus_handle(),
            pending_output: BTreeMap::new(),
            output_flush_scheduled: false,
            on_before_launch: None,
            on_open_settings: None,
            preparation_expanded: false,
            preparation: None,
            _preparation_task: None,
        }
    }

    /// 注入启动前保存回调。工作台在构造期注册一次，面板每次启动前调用。
    pub fn on_before_launch(&mut self, handler: impl Fn(&mut App) + 'static) {
        self.on_before_launch = Some(Rc::new(handler));
    }

    /// 注入「编辑当前配置」回调：打开设置页的 Run Configurations 页。
    pub fn on_open_settings(
        &mut self,
        handler: impl Fn(&str, &mut Window, &mut App) + 'static,
    ) {
        self.on_open_settings = Some(Rc::new(handler));
    }

    /// 外部保存或重新识别配置后刷新列表。
    pub fn refresh(&mut self, cx: &mut Context<Self>) {
        if self.root.is_some() {
            self.reload(cx);
        }
    }

    /// 切换项目根目录；旧会话先停止，旧配置和诊断全部清空。
    pub fn set_root(&mut self, root: PathBuf, _window: &mut Window, cx: &mut Context<Self>) {
        self.stop_all(cx);
        self.root = config::normalize_root(root);
        self.generation = self.generation.wrapping_add(1);
        self.configurations.clear();
        self.default_id = None;
        self.selected_id = None;
        self.diagnostics.clear();
        self.sessions.clear();
        self.pending_output.clear();
        self.error = None;
        self.loading = false;
        self.pending_run = false;
        self.restart_pending = None;
        self.pending_initial_load = self.root.is_some();
        self.preparation = None;
        self._preparation_task = None;
        self.emit(cx);
        cx.notify();
    }

    /// 查找某个 Maven 模块可明确选择的运行配置。
    ///
    /// 对齐 Tauri `findMavenModuleRunConfiguration`：配置必须带 Maven 扩展、
    /// 反应堆根与模块路径都匹配，且是可执行的应用 / 服务配置；优先返回
    /// 固定默认配置，候选多于一个且无默认时返回 `None`（不猜测）。
    pub fn maven_module_run_configuration(
        &self,
        reactor_path: &str,
        module_path: &str,
    ) -> Option<String> {
        let candidates: Vec<&RunConfiguration> = self
            .configurations
            .iter()
            .filter(|configuration| {
                matches!(
                    configuration.execution,
                    RunExecution::Application | RunExecution::Service
                )
            })
            .filter(|configuration| {
                let reactor = normalize_relative(configuration.maven_reactor_path());
                let module = normalize_relative(configuration.module());
                reactor == normalize_relative(Some(reactor_path))
                    && module == normalize_relative(Some(module_path))
            })
            .collect();
        let configured_default = candidates
            .iter()
            .find(|configuration| Some(configuration.id.as_str()) == self.default_id.as_deref());
        if let Some(configuration) = configured_default {
            return Some(configuration.id.clone());
        }
        if candidates.len() == 1 {
            return Some(candidates[0].id.clone());
        }
        None
    }

    /// 选择并启动指定 id 的配置。Maven 工具窗的模块 Run 动作使用。
    pub fn run_configuration(&mut self, id: &str, cx: &mut Context<Self>) {
        self.selected_id = Some(id.to_string());
        self.start_configuration(id.to_string(), cx);
    }

    /// 当前选中配置名，供顶栏配置 pill 显示。
    pub fn selected_label(&self) -> SharedString {
        self.selected_configuration()
            .map(|configuration| configuration.name.clone())
            .unwrap_or_else(|| tr("Run configuration").to_string())
            .into()
    }

    /// 是否有任一配置正在启动或运行。
    pub fn is_running(&self) -> bool {
        self.sessions.values().any(SessionState::is_active)
    }

    /// 当前选中配置是否正在运行。
    pub fn selected_is_running(&self) -> bool {
        self.selected_id
            .as_ref()
            .and_then(|id| self.sessions.get(id))
            .is_some_and(|session| session.running)
    }

    fn invoke_open_settings(&self, id: &str, window: &mut Window, cx: &mut Context<Self>) {
        if let Some(handler) = self.on_open_settings.as_ref() {
            handler(id, window, cx);
        }
    }

    /// 顶栏 Run / F5：执行当前配置；没有配置时先加载再执行。
    pub fn run_selected(&mut self, cx: &mut Context<Self>) {
        if self.configurations.is_empty() {
            self.pending_run = true;
            if !self.loading {
                self.reload(cx);
            }
            return;
        }
        let candidate = self
            .selected_id
            .clone()
            .or_else(|| self.default_id.clone())
            .and_then(|id| {
                self.configurations
                    .iter()
                    .find(|configuration| configuration.id == id)
                    .filter(|configuration| configuration.execution != RunExecution::Group)
                    .map(|configuration| configuration.id.clone())
            })
            .or_else(|| {
                self.configurations
                    .iter()
                    .find(|configuration| configuration.execution != RunExecution::Group)
                    .map(|configuration| configuration.id.clone())
            });
        if let Some(id) = candidate {
            if self.sessions.get(&id).is_some_and(SessionState::is_active) {
                self.restart_configuration(id, cx);
            } else {
                self.start_configuration(id, cx);
            }
        }
    }

    /// 顶栏 Stop：停止当前选中配置。
    pub fn stop_selected(&mut self, cx: &mut Context<Self>) {
        if let Some(id) = self.selected_id.clone() {
            self.stop_configuration(&id, cx);
        }
    }

    fn selected_configuration(&self) -> Option<&RunConfiguration> {
        let id = self.selected_id.as_ref()?;
        self.configurations
            .iter()
            .find(|configuration| &configuration.id == id)
    }

    /// 当前选中会话的输出文本。
    ///
    /// 只用于复制、打印、诊断这类需要全文的一次性动作；渲染走虚拟化列表，
    /// 不再每帧拼接整段输出。
    fn selected_output(&self) -> String {
        self.selected_id
            .as_ref()
            .and_then(|id| self.sessions.get(id))
            .map(SessionState::full_text)
            .unwrap_or_default()
    }

    /// 当前选中会话展示的行数与行文本访问器。
    fn selected_line_count(&self) -> usize {
        self.selected_id
            .as_ref()
            .and_then(|id| self.sessions.get(id))
            .map(SessionState::display_line_count)
            .unwrap_or(0)
    }

    /// 是否有任一控制台输出了内容。
    fn selected_has_output(&self) -> bool {
        self.selected_line_count() > 0
    }

    /// 把行数变化同步给虚拟化列表。
    ///
    /// 行数变化时跟随最新输出。uniform_list 的行数在渲染时传入，
    /// 这里只负责把贴底跟随落成滚动指令。
    fn sync_console_lines(&mut self) {
        let count = self.selected_line_count();
        if count == self.console_line_count {
            return;
        }
        self.console_line_count = count;
        let running = self
            .selected_id
            .as_ref()
            .and_then(|id| self.sessions.get(id))
            .is_some_and(SessionState::is_active);
        if self.console_follow_tail && running && count > 0 {
            self.console_scroll
                .scroll_to_item(count - 1, ScrollStrategy::Bottom);
        }
    }

    /// 回到最新输出（macOS 的 “Jump to latest”）。
    fn scroll_to_latest(&mut self, cx: &mut Context<Self>) {
        self.console_follow_tail = true;
        let count = self.selected_line_count();
        if count > 0 {
            self.console_scroll
                .scroll_to_item(count - 1, ScrollStrategy::Bottom);
        }
        cx.notify();
    }

    /// ⌘C / Ctrl+C：优先复制选择范围，没有选择时复制整段输出。
    fn on_copy_selection(
        &mut self,
        _: &CopySelection,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let selected = TextSelection::selected_text(window, cx);
        let text = if selected.trim().is_empty() {
            self.selected_output()
        } else {
            selected
        };
        if !text.is_empty() {
            cx.write_to_clipboard(ClipboardItem::new_string(text));
        }
    }

    /// 复制按钮与控制台快捷键共用同一份文本。
    fn copy_output(&mut self, cx: &mut Context<Self>) {
        let text = self.selected_output();
        if !text.is_empty() {
            cx.write_to_clipboard(ClipboardItem::new_string(text));
        }
    }

    /// 首次显示时加载配置。构造期不能 spawn。
    fn ensure_loaded(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        if !self.pending_initial_load {
            return;
        }
        self.pending_initial_load = false;
        cx.defer_in(window, |this, _window, cx| {
            if this.root.is_some() {
                this.reload(cx);
            }
        });
    }

    /// 后台读取/生成/解析运行配置。
    fn reload(&mut self, cx: &mut Context<Self>) {
        let Some(root) = self.root.clone() else {
            self.configurations.clear();
            self.loading = false;
            self.error = Some(tr("Open a project to discover run configurations").into());
            self.emit(cx);
            cx.notify();
            return;
        };

        self.pending_initial_load = false;
        self.generation = self.generation.wrapping_add(1);
        let generation = self.generation;
        self.loading = true;
        self.error = None;
        self.emit(cx);
        cx.notify();

        let client = self.client;
        cx.spawn(async move |this, cx| {
            let result = cx
                .background_spawn(async move { config::load_configurations(&client, &root) })
                .await;
            let _ = this.update(cx, |this, cx| {
                if this.generation != generation {
                    return;
                }
                this.loading = false;
                match result {
                    Ok(loaded) => this.apply_loaded(loaded, cx),
                    Err(error) => {
                        this.error = Some(SharedString::from(error));
                        this.emit(cx);
                        cx.notify();
                    }
                }
            });
        })
        .detach();
    }

    /// 检查当前工作区是否是包含 Java 的项目（完全对齐 Tauri 规则）。
    fn has_java_project(&self) -> bool {
        if self
            .configurations
            .iter()
            .any(|c| c.language() == RunLanguage::Java)
        {
            return true;
        }
        if let Some(root) = self.root.as_ref() {
            return root.join("pom.xml").exists()
                || root.join("build.gradle").exists()
                || root.join("build.gradle.kts").exists()
                || root.join("src").join("main").join("java").exists();
        }
        false
    }

    /// 启动 Java 项目准备流程（对齐 Tauri `ProjectPreparation` 状态机）。
    pub fn start_project_preparation(&mut self, cx: &mut Context<Self>) {
        if !self.has_java_project() {
            self.preparation = None;
            self._preparation_task = None;
            return;
        }

        self.preparation = Some(ProjectPreparation::starting());
        cx.notify();

        let task = cx.spawn(async move |this, cx| {
            // 阶段 1: Starting -> 150ms
            cx.background_executor().timer(Duration::from_millis(150)).await;
            let _ = this.update(cx, |this, cx| {
                if let Some(prep) = this.preparation.as_mut() {
                    prep.phase = PreparationPhase::Importing;
                    prep.import_percent = Some(35);
                    cx.notify();
                }
            });

            // 阶段 2: Importing -> 300ms
            cx.background_executor().timer(Duration::from_millis(300)).await;
            let _ = this.update(cx, |this, cx| {
                if let Some(prep) = this.preparation.as_mut() {
                    prep.phase = PreparationPhase::Configuring;
                    prep.import_percent = None;
                    cx.notify();
                }
            });

            // 阶段 3: Configuring -> 250ms
            cx.background_executor().timer(Duration::from_millis(250)).await;
            let _ = this.update(cx, |this, cx| {
                if let Some(prep) = this.preparation.as_mut() {
                    prep.phase = PreparationPhase::Building;
                    cx.notify();
                }
            });

            // 阶段 4: Building -> 200ms -> Ready!
            cx.background_executor().timer(Duration::from_millis(200)).await;
            let _ = this.update(cx, |this, cx| {
                this.preparation = Some(ProjectPreparation::ready());
                cx.notify();
            });
        });

        self._preparation_task = Some(task);
    }

    fn apply_loaded(&mut self, loaded: LoadedRunConfigurations, cx: &mut Context<Self>) {
        self.configurations = loaded.configurations;
        self.default_id = loaded.default_id;
        self.diagnostics = loaded.diagnostics;
        if self
            .selected_id
            .as_ref()
            .is_none_or(|id| !self.configurations.iter().any(|item| &item.id == id))
        {
            self.selected_id = self
                .default_id
                .clone()
                .or_else(|| self.configurations.first().map(|item| item.id.clone()));
        }
        self.pending_initial_load = false;
        if self.has_java_project() {
            if self.preparation.is_none() {
                self.start_project_preparation(cx);
            }
        } else {
            self.preparation = None;
            self._preparation_task = None;
        }
        self.emit(cx);
        cx.notify();

        if self.pending_run {
            self.pending_run = false;
            if !self.configurations.is_empty() {
                self.run_selected(cx);
            }
        }
    }

    /// 重新运行：先停止当前会话，等 Exited 事件到达后再启动。
    fn restart_configuration(&mut self, id: String, cx: &mut Context<Self>) {
        if self.sessions.get(&id).is_some_and(SessionState::is_active) {
            self.restart_pending = Some(id.clone());
            self.stop_configuration(&id, cx);
        } else {
            self.start_configuration(id, cx);
        }
    }

    fn start_configuration(&mut self, id: String, cx: &mut Context<Self>) {
        let Some(configuration) = self
            .configurations
            .iter()
            .find(|configuration| configuration.id == id)
            .filter(|configuration| configuration.execution != RunExecution::Group)
            .cloned()
        else {
            return;
        };
        let Some(root) = self.root.clone() else {
            return;
        };
        if self.sessions.get(&id).is_some_and(SessionState::is_active) {
            self.selected_id = Some(id);
            self.show_details = false;
            self.emit(cx);
            cx.notify();
            return;
        }

        self.selected_id = Some(id.clone());
        self.show_details = false;
        self.sessions.insert(id.clone(), SessionState::starting());
        self.pending_output.remove(&id);
        // 新会话从第 0 行开始：重置跟随，不继承上一次的滚动位置。
        self.console_line_count = 0;
        self.console_follow_tail = true;
        self.emit(cx);
        cx.notify();

        // 先把脏缓冲写盘再启动：改完源码直接点 Run 时，编译/运行必须看到新内容。
        // 保存是异步的（Monaco 逐个提交 save 请求），这里只发出请求，不阻塞启动。
        if let Some(save) = self.on_before_launch.clone() {
            save(cx);
        }

        let client = self.client;
        let session_id = id.clone();
        cx.spawn(async move |this, cx| {
            let receiver = cx
                .background_spawn(async move { session::start(client, root, configuration) })
                .await;
            let _ = this.update(cx, |this, cx| {
                this.watch_session(session_id, receiver, cx);
            });
        })
        .detach();
    }

    fn watch_session(
        &mut self,
        id: String,
        receiver: Receiver<SessionEvent>,
        cx: &mut Context<Self>,
    ) {
        let task: Task<()> = cx.spawn(async move |this, cx| {
            while let Ok(event) = receiver.recv().await {
                let keep = this
                    .update(cx, |this, cx| this.handle_session_event(&id, event, cx))
                    .unwrap_or(false);
                if !keep {
                    break;
                }
            }
        });
        task.detach();
    }

    fn handle_session_event(
        &mut self,
        id: &str,
        event: SessionEvent,
        cx: &mut Context<Self>,
    ) -> bool {
        let is_output = matches!(&event, SessionEvent::Output(_));
        let mut output_chunk: Option<String> = None;
        let mut failed_output: Option<String> = None;
        if let Some(session) = self.sessions.get_mut(id) {
            match event {
                // 输出不在这里直接入账：高频日志先合批，避免每个数据块都触发
                // 一次整段控制台重排。
                SessionEvent::Output(text) => output_chunk = Some(text),
                SessionEvent::Started(tree) => {
                    session.tree = Some(tree);
                    session.starting = false;
                    session.running = true;
                }
                SessionEvent::Exited(code) => {
                    session.starting = false;
                    session.running = false;
                    session.exit_code = code;
                    session.tree = None;
                    // 进程最后一行通常没有换行；不补进列表就会丢最后一条输出。
                    session.flush_pending_line();
                }
                SessionEvent::Failed(message) => {
                    session.starting = false;
                    session.running = false;
                    session.exit_code = Some(1);
                    session.tree = None;
                    session.flush_pending_line();
                    failed_output = Some(format!("{message}\n"));
                }
            }
        }
        if let Some(text) = output_chunk {
            self.queue_output(id, &text, cx);
        }
        if let Some(text) = failed_output {
            // 启动失败要立刻可见，不受合批窗口影响。
            self.pending_output
                .entry(id.to_string())
                .or_default()
                .push_str(&text);
            self.flush_output(cx);
        }

        if self.restart_pending.as_deref() == Some(id)
            && !self.sessions.get(id).is_some_and(SessionState::is_active)
        {
            self.restart_pending = None;
            self.start_configuration(id.to_string(), cx);
        }

        if !is_output {
            self.emit(cx);
            cx.notify();
        }
        true
    }

    /// 把输出块放进合批缓冲；窗口到期后一次性追加。
    fn queue_output(&mut self, id: &str, text: &str, cx: &mut Context<Self>) {
        self.pending_output
            .entry(id.to_string())
            .or_default()
            .push_str(text);
        if self.output_flush_scheduled {
            return;
        }
        self.output_flush_scheduled = true;
        cx.spawn(async move |this, cx| {
            // 计时器在后台执行器上，不占用 UI 线程。
            cx.background_executor().timer(OUTPUT_FLUSH_INTERVAL).await;
            let _ = this.update(cx, |this, cx| {
                this.output_flush_scheduled = false;
                this.flush_output(cx);
            });
        })
        .detach();
    }

    /// 合并缓冲里所有配置的输出，只刷新一次视图。
    fn flush_output(&mut self, cx: &mut Context<Self>) {
        if self.pending_output.is_empty() {
            return;
        }
        let pending = std::mem::take(&mut self.pending_output);
        let mut appended = false;
        let mut service_url_changed = false;
        for (id, text) in pending {
            let Some(session) = self.sessions.get_mut(&id) else {
                continue;
            };
            let url_before = session.service_url.clone();
            session.append_output(&text);
            appended = true;
            if url_before != session.service_url {
                service_url_changed = true;
            }
        }
        if !appended {
            return;
        }
        // 行数变化交给虚拟化列表；是否跟随末尾由 `FollowMode::Tail` 自己决定，
        // 用户上翻后框架会暂停跟随，回到底部时自动恢复，不需要再比对偏移量。
        self.sync_console_lines();
        // 顶栏只关心服务地址这类结构性变化，普通日志不惊动工作台。
        if service_url_changed {
            self.emit(cx);
        }
        cx.notify();
    }

    fn stop_configuration(&mut self, id: &str, cx: &mut Context<Self>) {
        let Some(tree) = self
            .sessions
            .get(id)
            .and_then(|session| session.tree.clone())
        else {
            return;
        };
        if let Some(session) = self.sessions.get_mut(id) {
            session.stopped = true;
        }
        cx.background_spawn(async move {
            let _ = session::stop(tree);
        })
        .detach();
        self.emit(cx);
        cx.notify();
    }

    fn stop_all(&mut self, cx: &mut Context<Self>) {
        let trees: Vec<Arc<ProcessTree>> = self
            .sessions
            .values()
            .filter_map(|session| session.tree.clone())
            .collect();
        if trees.is_empty() {
            return;
        }
        cx.background_spawn(async move {
            for tree in trees {
                let _ = session::stop(tree);
            }
        })
        .detach();
    }

    fn clear_output(&mut self, cx: &mut Context<Self>) {
        if let Some(id) = self.selected_id.clone() {
            if let Some(session) = self.sessions.get_mut(&id) {
                session.clear();
            }
            self.pending_output.remove(&id);
        }
        self.console_line_count = 0;
        self.console_follow_tail = true;
        self.emit(cx);
        cx.notify();
    }

    fn emit(&self, cx: &mut Context<Self>) {
        cx.emit(RunPanelEvent::StateChanged);
    }

    // -----------------------------------------------------------------------
    // 标题栏、批量选择与控制台动作
    // -----------------------------------------------------------------------

    /// 隐藏按钮：面板不改工作台布局，只发出请求，由工作台收起底部 dock 并持久化。
    fn hide_panel(&mut self, cx: &mut Context<Self>) {
        self.close_more_menu();
        cx.emit(RunPanelEvent::HideRequested);
        cx.notify();
    }

    /// 勾选状态取反。批量模式下点行内复选框只改勾选，不切换当前选中配置。
    fn toggle_checked(&mut self, id: &str, cx: &mut Context<Self>) {
        if !self.checked.remove(id) {
            self.checked.insert(id.to_string());
        }
        cx.notify();
    }

    /// 退出批量模式并清空勾选，对齐 macOS “Clear selection”。
    fn clear_checked(&mut self, cx: &mut Context<Self>) {
        self.checked.clear();
        self.batch_selection = false;
        cx.notify();
    }

    /// 批量运行：只启动勾选里尚未运行的配置，已在运行的服务不被重启。
    fn run_checked(&mut self, cx: &mut Context<Self>) {
        let ids: Vec<String> = self.checked.iter().cloned().collect();
        for id in ids {
            if self.sessions.get(&id).is_some_and(SessionState::is_active) {
                continue;
            }
            self.start_configuration(id, cx);
        }
    }

    /// 批量停止：只停勾选里正在运行的配置。
    fn stop_checked(&mut self, cx: &mut Context<Self>) {
        let ids: Vec<String> = self
            .checked
            .iter()
            .filter(|id| self.sessions.get(*id).is_some_and(SessionState::is_active))
            .cloned()
            .collect();
        for id in ids {
            self.stop_configuration(&id, cx);
        }
    }

    /// 勾选里是否有正在运行的配置，决定批量 Stop 是否可用。
    fn checked_has_running(&self) -> bool {
        self.checked
            .iter()
            .any(|id| self.sessions.get(id).is_some_and(SessionState::is_active))
    }

    /// 控制台里的堆栈帧 / 错误行行号（0 基）。macOS 的 Previous/Next Stack Trace
    /// 在这些位置之间跳转。
    fn stack_trace_lines(&self) -> Vec<usize> {
        let Some(session) = self
            .selected_id
            .as_ref()
            .and_then(|id| self.sessions.get(id))
        else {
            return Vec::new();
        };
        (0..session.display_line_count())
            .filter(|index| is_stack_trace_line(session.line_at(*index)))
            .collect()
    }

    /// 跳到上一条 / 下一条堆栈帧。
    ///
    /// 虚拟化列表支持按行定位，不再需要旧实现的“行号 × 行高”像素换算——
    /// 那种换算在开启软换行后只是近似位置，跳转会偏。
    fn jump_stack_trace(&mut self, forward: bool, cx: &mut Context<Self>) {
        let lines = self.stack_trace_lines();
        if lines.is_empty() {
            return;
        }
        // uniform_list 句柄没有公开的“当前顶行”查询（test-support 才有），
        // 用像素偏移除以固定行高换算；行高固定（Nowrap 单行），换算是精确的。
        let current = {
            let state = self.console_scroll.0.borrow();
            let item_height = state
                .last_item_size
                .map(|size| size.item.height)
                .unwrap_or(px(CONSOLE_LINE_HEIGHT))
                .max(px(1.0));
            (state.base_handle.offset().y / item_height).round() as usize
        };
        let target = if forward {
            lines.iter().copied().filter(|line| *line > current).min()
        } else {
            lines.iter().copied().filter(|line| *line < current).max()
        };
        let Some(target) = target else {
            return;
        };
        // 跳转后暂停跟随，否则下一块输出会立刻把视图拉回末尾。
        self.console_follow_tail = false;
        self.console_scroll
            .scroll_to_item(target, ScrollStrategy::Top);
        cx.notify();
    }

    /// 打印控制台输出。GPUI 没有系统打印对话框，这里把输出写到临时文件再用
    /// 系统默认程序打开，由该程序负责打印；写盘失败时保持界面不变。
    fn print_output(&mut self, cx: &mut Context<Self>) {
        let text = self.selected_output();
        if text.is_empty() {
            return;
        }
        let path = std::env::temp_dir().join("lithe-run-output.txt");
        if std::fs::write(&path, text).is_err() {
            return;
        }
        let url = format!("file:///{}", path.to_string_lossy().replace('\\', "/"));
        let _ = lithe_platform::current().open_url(&url);
        cx.notify();
    }

    /// 关闭 more 菜单并释放订阅。
    fn close_more_menu(&mut self) {
        self.more_menu = None;
        self._more_menu_subscription = None;
    }

    /// 打开 / 关闭标题栏 more 菜单。条目与 macOS `RunView.runOptionsMenu` 一致。
    fn toggle_more_menu(
        &mut self,
        position: gpui_kit::Point<gpui_kit::Pixels>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if self.more_menu.is_some() {
            self.close_more_menu();
            cx.notify();
            return;
        }

        let owner = cx.weak_entity();
        let rescan = owner.clone();
        let wraps = owner.clone();
        let batch = owner.clone();
        let clear = owner.clone();
        // 勾选状态先取值再进闭包：闭包是 `move` 的，直接读 `self` 会把面板整体移走。
        let wraps_currently_on = self.wrap_output;
        let batch_currently_on = self.batch_selection;

        let popup = PopupMenu::build(window, cx, move |menu, _window, _cx| {
            menu.min_w(px(220.0))
                .item(
                    PopupMenuItem::new(tr("Rescan services")).on_click(move |_, _window, cx| {
                        let _ = rescan.update(cx, |this, cx| this.reload(cx));
                    }),
                )
                .item(
                    PopupMenuItem::new(tr("Use soft wraps"))
                        .checked(wraps_currently_on)
                        .on_click(move |_, _window, cx| {
                            let _ = wraps.update(cx, |this, cx| {
                                this.wrap_output = !this.wrap_output;
                                cx.notify();
                            });
                        }),
                )
                .item(
                    PopupMenuItem::new(tr("Select configurations for batch actions"))
                        .checked(batch_currently_on)
                        .on_click(move |_, _window, cx| {
                            let _ = batch.update(cx, |this, cx| {
                                this.batch_selection = !this.batch_selection;
                                if !this.batch_selection {
                                    this.checked.clear();
                                }
                                cx.notify();
                            });
                        }),
                )
                .separator()
                .item(
                    PopupMenuItem::new(tr("Clear run output")).on_click(move |_, _window, cx| {
                        let _ = clear.update(cx, |this, cx| this.clear_output(cx));
                    }),
                )
        });

        let subscription =
            cx.subscribe_in(&popup, window, |this, _, _: &DismissEvent, _window, cx| {
                this.close_more_menu();
                cx.notify();
            });

        // 菜单自己接管键盘：上下选择、回车执行、Esc 关闭。
        let focus_handle = popup.read(cx).focus_handle(cx);
        if !focus_handle.contains_focused(window, cx) {
            focus_handle.focus(window, cx);
        }

        self.more_menu = Some((popup, position));
        self._more_menu_subscription = Some(subscription);
        cx.notify();
    }

    // -----------------------------------------------------------------------
    // 渲染
    // -----------------------------------------------------------------------

    /// 36pt 动作工具条。按钮顺序对齐 macOS `RunView.runToolbar`：
    /// 批量勾选组 → Run/Restart → Stop → Rescan → 软换行 → 分隔线 →
    /// Console / 详情（图标 tab）→ 服务地址外链。
    fn render_toolbar(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let selected_running = self.selected_is_running();
        let selected_starting = self
            .selected_id
            .as_ref()
            .and_then(|id| self.sessions.get(id))
            .is_some_and(|session| session.starting);
        let has_configurations = !self.configurations.is_empty();
        let checked_count = self.checked.len();
        let service_url = self
            .selected_id
            .as_ref()
            .and_then(|id| self.sessions.get(id))
            .and_then(|session| session.service_url.clone());

        let mut toolbar = h_flex()
            .id("lithe-run-toolbar")
            .w_full()
            .flex_shrink_0()
            .items_center()
            .gap(px(2.0))
            .px(px(8.0))
            .h(px(TOOLBAR_HEIGHT))
            .bg(tokens.tool_header)
            .border_b_1()
            .border_color(tokens.divider);

        // 批量组：勾选非空时出现，其余时候完全不占位，与 macOS 一致。
        if checked_count > 0 {
            toolbar = toolbar
                .child(
                    div()
                        .px(px(4.0))
                        .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                        .text_color(tokens.secondary_text)
                        .child(format!("{checked_count} {}", tr("selected"))),
                )
                .child(
                    Button::new("lithe-run:run-checked")
                        .ghost()
                        .small()
                        .icon(icon(LitheIcon::Run))
                        .tooltip(tr(
                            "Run checked configurations without restarting running services",
                        ))
                        .disabled(!has_configurations || self.loading)
                        .on_click(cx.listener(move |this, _, _window, cx| this.run_checked(cx))),
                )
                .child(
                    Button::new("lithe-run:stop-checked")
                        .ghost()
                        .small()
                        .child(Icon::new(IconName::Square).with_size(px(14.0)))
                        .tooltip(tr("Stop selected"))
                        .disabled(!self.checked_has_running())
                        .on_click(cx.listener(move |this, _, _window, cx| this.stop_checked(cx))),
                )
                .child(
                    Button::new("lithe-run:clear-checked")
                        .ghost()
                        .small()
                        .icon(icon(LitheIcon::Close))
                        .tooltip(tr("Clear selection"))
                        .on_click(cx.listener(move |this, _, _window, cx| this.clear_checked(cx))),
                );
        }

        toolbar = toolbar
            .child(
                Button::new("lithe-run:run")
                    .ghost()
                    .small()
                    .icon(icon(if selected_running {
                        LitheIcon::Refresh
                    } else {
                        LitheIcon::Run
                    }))
                    .tooltip(tr(if selected_running { "Restart" } else { "Run" }))
                    .disabled(
                        !has_configurations || !self.can_start_selected() || selected_starting,
                    )
                    .on_click(cx.listener(move |this, _, _window, cx| {
                        let id = this
                            .selected_id
                            .clone()
                            .or_else(|| this.default_id.clone())
                            .or_else(|| this.configurations.first().map(|item| item.id.clone()));
                        if let Some(id) = id {
                            if this.sessions.get(&id).is_some_and(SessionState::is_active) {
                                this.restart_configuration(id, cx);
                            } else {
                                this.start_configuration(id, cx);
                            }
                        } else {
                            this.run_selected(cx);
                        }
                    })),
            )
            .child(
                Button::new("lithe-run:stop")
                    .ghost()
                    .small()
                    .child(Icon::new(IconName::Square).with_size(px(14.0)))
                    .tooltip(tr("Stop run"))
                    .disabled(!selected_running)
                    .on_click(cx.listener(move |this, _, _window, cx| {
                        this.stop_selected(cx);
                    })),
            )
            .child(
                Button::new("lithe-run:rescan")
                    .ghost()
                    .small()
                    .icon(icon(LitheIcon::Refresh))
                    .tooltip(tr("Rescan services"))
                    .disabled(self.loading)
                    .on_click(cx.listener(move |this, _, _window, cx| this.reload(cx))),
            )
            .child(
                Button::new("lithe-run:wrap")
                    .ghost()
                    .small()
                    .child(Icon::new(IconName::Menu).with_size(px(16.0)))
                    .tooltip(tr("Use soft wraps"))
                    .selected(self.wrap_output)
                    .on_click(cx.listener(move |this, _, _window, cx| {
                        this.wrap_output = !this.wrap_output;
                        this.emit(cx);
                        cx.notify();
                    })),
            )
            .child(div().flex_1());

        // 选中配置后出现 Console / 详情两个图标 tab；分隔线与 macOS 的
        // `ActionToolbar.separator` 对齐。
        if self.selected_configuration().is_some() {
            toolbar = toolbar
                .child(div().w(px(1.0)).h(px(20.0)).mx(px(6.0)).bg(tokens.divider))
                .child(
                    Button::new("lithe-run:console")
                        .ghost()
                        .small()
                        .icon(icon(LitheIcon::Terminal))
                        .tooltip(tr("Console"))
                        .selected(!self.show_details)
                        .on_click(cx.listener(move |this, _, _window, cx| {
                            this.show_details = false;
                            cx.notify();
                        })),
                )
                .child(
                    Button::new("lithe-run:details")
                        .ghost()
                        .small()
                        .icon(icon(LitheIcon::Settings))
                        .tooltip(tr("Configuration details"))
                        .selected(self.show_details)
                        .on_click(cx.listener(move |this, _, _window, cx| {
                            this.show_details = true;
                            cx.notify();
                        })),
                );
        }

        if let Some(url) = service_url {
            let label = SharedString::from(url.clone());
            toolbar = toolbar.child(
                Button::new("lithe-run:service-url")
                    .ghost()
                    .small()
                    .icon(icon(LitheIcon::References))
                    .max_w(px(260.0))
                    .label(label)
                    .tooltip(tr("Open service in browser"))
                    .on_click(cx.listener(move |_, _, _window, _cx| {
                        let _ = lithe_platform::current().open_url(&url);
                    })),
            );
        }

        toolbar.into_any_element()
    }

    fn can_start_selected(&self) -> bool {
        self.selected_configuration()
            .is_some_and(|configuration| configuration.execution != RunExecution::Group)
            || self
                .configurations
                .iter()
                .any(|configuration| configuration.execution != RunExecution::Group)
    }

    /// 当前可见的配置：先按语言分类过滤，再排除 group 类型。
    ///
    /// 对齐 Tauri `runConfigurationLanguageGroups`：`runnableConfigurations` 去掉
    /// 内置的 “Current File” 后，再把 `execution === "group"` 排除掉——分组不是
    /// 可启动目标，只用于组织。
    fn configurations_for_language(&self, language: RunLanguage) -> Vec<&RunConfiguration> {
        self.configurations
            .iter()
            .filter(|configuration| configuration.execution != RunExecution::Group)
            .filter(|configuration| configuration.language() == language)
            .collect()
    }

    /// 侧栏里实际有配置的语言分类，按 [`RunLanguage::ORDER`] 固定排序。
    fn visible_languages(&self) -> Vec<RunLanguage> {
        RunLanguage::ORDER
            .into_iter()
            .filter(|language| {
                self.configurations
                    .iter()
                    .any(|configuration| configuration.language() == *language)
            })
            .collect()
    }

    /// 语言分类侧栏。对齐 Tauri `RunConfigurationBrowser` 的 `languages` 面板：
    /// 只列出有配置的分类，顺序固定，选中项切换列表内容并选中该分类第一条配置。
    fn render_language_rail(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let languages = self.visible_languages();
        // 当前选中配置所属分类优先；用户手动切换过就用那个分类。都没有时
        // 退回第一个有配置的分类，不伪造一个空列表。
        let current = self
            .selected_configuration()
            .map(RunConfiguration::language)
            .filter(|language| languages.contains(language))
            .or_else(|| {
                self.selected_language
                    .as_deref()
                    .and_then(RunLanguage::from_key)
                    .filter(|language| languages.contains(language))
            })
            .or_else(|| languages.first().copied());

        let mut rail = v_flex()
            .id("lithe-run-languages")
            .w(px(100.0))
            .flex_shrink_0()
            .h_full()
            .gap(px(2.0))
            .p(px(4.0))
            .overflow_y_scroll()
            .bg(tokens.sidebar)
            .border_r_1()
            .border_color(tokens.divider);

        for language in languages {
            let is_selected = current == Some(language);
            let title = language.title();
            rail = rail.child(
                Button::new(format!("lithe-run:lang:{}", language.key()))
                    .ghost()
                    .w_full()
                    .h(px(26.0))
                    .px(px(8.0))
                    .rounded(px(4.0))
                    .when(is_selected, |this| this.bg(tokens.selection))
                    .child(
                        h_flex()
                            .w_full()
                            .items_center()
                            .gap(px(6.0))
                            .child(icon(language.icon()).with_size(px(14.0)).text_color(
                                if is_selected {
                                    tokens.tool_window_selected_text
                                } else {
                                    tokens.primary_text
                                },
                            ))
                            .child(
                                div()
                                    .min_w(px(0.0))
                                    .flex_1()
                                    .truncate()
                                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                                    .font_weight(if is_selected {
                                        FontWeight::SEMIBOLD
                                    } else {
                                        FontWeight::NORMAL
                                    })
                                    .text_color(if is_selected {
                                        tokens.tool_window_selected_text
                                    } else {
                                        tokens.primary_text
                                    })
                                    .child(title),
                            ),
                    )
                    .on_click(cx.listener(move |this, _, _window, cx| {
                        // 切成该分类的第一条配置，和 Tauri `props.onSelect(group.configurations[0].id)`
                        // 一致：只切分类而不选中任何配置，会让右边的输出区读不到会话。
                        if let Some(first) = this.configurations_for_language(language).first() {
                            this.selected_id = Some(first.id.clone());
                        }
                        this.selected_language = Some(language.key().to_string());
                        this.show_details = false;
                        this.emit(cx);
                        cx.notify();
                    })),
            );
        }

        rail.into_any_element()
    }

    fn render_configuration_list(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        // 与侧栏共用同一判据：当前分类 = 选中配置所属分类，否则用用户上次切换
        // 的分类，再否则第一个有配置的分类。之前这里默认写死 "Java"，导致非 Java
        // 项目的列表在没切换侧栏时永远为空。
        let languages = self.visible_languages();
        let current_language = self
            .selected_configuration()
            .map(RunConfiguration::language)
            .filter(|language| languages.contains(language))
            .or_else(|| {
                self.selected_language
                    .as_deref()
                    .and_then(RunLanguage::from_key)
                    .filter(|language| languages.contains(language))
            })
            .or_else(|| languages.first().copied());

        let configurations = current_language
            .map(|language| self.configurations_for_language(language))
            .unwrap_or_default();

        let mut list = v_flex()
            .id("lithe-run-configurations")
            .w_full()
            .flex_shrink_0()
            .h_full()
            .min_h(px(0.0))
            .overflow_y_scroll()
            .bg(tokens.sidebar)
            .border_r_1()
            .border_color(tokens.divider);

        if configurations.is_empty() {
            list = list.child(
                div()
                    .w_full()
                    .p(px(12.0))
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(tr("No configurations in this scope")),
            );
            return list.into_any_element();
        }

        for (group_title, group) in self.group_configurations(&configurations) {
            let representative = group.first().copied();
            let group_icon = representative.map(|c| c.icon());
            list = list.child(
                h_flex()
                    .w_full()
                    .flex_shrink_0()
                    .h(px(GROUP_HEADER_HEIGHT))
                    .items_center()
                    .gap(px(6.0))
                    .px(px(8.0))
                    .child(
                        Icon::new(IconName::ChevronDown)
                            .with_size(px(12.0))
                            .text_color(tokens.secondary_text),
                    )
                    .when_some(group_icon, |this, icon_kind| {
                        let color = if icon_kind == LitheIcon::Spring {
                            tokens.success
                        } else {
                            tokens.secondary_text
                        };
                        this.child(
                            icon(icon_kind)
                                .with_size(px(14.0))
                                .text_color(color),
                        )
                    })
                    .child(
                        div()
                            .min_w(px(0.0))
                            .flex_1()
                            .truncate()
                            .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(tokens.secondary_text)
                            .child(group_title),
                    )
                    .child(
                        div()
                            .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                            .text_color(tokens.tertiary_text)
                            .child(group.len().to_string()),
                    ),
            );
            for configuration in group {
                list = list.child(self.render_configuration_row(&configuration, tokens, cx));
            }
        }

        list.into_any_element()
    }

    fn render_configuration_row(
        &self,
        configuration: &RunConfiguration,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let id = configuration.id.clone();
        let selected = self.selected_id.as_deref() == Some(id.as_str());
        let _pinned = self.pinned.contains(&id);
        let session = self.sessions.get(&id);
        let starting = session.is_some_and(|session| session.starting);
        let stopped = session.is_some_and(|session| session.stopped);
        let running = session.is_some_and(SessionState::is_active);
        let exit_code = session.and_then(|session| session.exit_code);
        let foreground = if selected {
            tokens.tool_window_selected_text
        } else {
            tokens.primary_text
        };
        let status_color = if starting {
            tokens.warning
        } else if running {
            tokens.success
        } else if stopped {
            tokens.tertiary_text
        } else if exit_code == Some(0) {
            tokens.success
        } else if exit_code.is_some() {
            tokens.error
        } else {
            tokens.tertiary_text
        };
        let configuration_for_click = configuration.clone();
        let id_for_toggle = id.clone();
        let id_for_settings = id.clone();
        let id_for_check = id.clone();
        let is_checked = self.checked.contains(&id);

        h_flex()
            .id(format!("lithe-run:configuration:{id}"))
            .w_full()
            .flex_shrink_0()
            .h(px(CONFIGURATION_ROW_HEIGHT))
            .items_center()
            .gap(px(6.0))
            .px(px(8.0))
            .when(selected, |this| this.bg(tokens.selection))
            .when(!selected, |this| this.hover(|style| style.bg(tokens.hover)))
            .on_click(cx.listener(move |this, _, _window, cx| {
                this.selected_id = Some(configuration_for_click.id.clone());
                this.show_details = false;
                // 切换会话：重置跟随，不继承上一个会话的滚动位置。
                this.console_line_count = 0;
                this.console_follow_tail = true;
                this.emit(cx);
                cx.notify();
            }))
            // 批量模式才出现勾选框：平时行内只保留图标、名称、状态点和动作按钮。
            .when(self.batch_selection, |this| {
                this.child(
                    Checkbox::new(SharedString::from(format!("lithe-run:checked:{id}")))
                        .checked(is_checked)
                        .on_click(cx.listener(move |this, _, _window, cx| {
                            this.toggle_checked(&id_for_check, cx);
                        })),
                )
            })
            .child(
                icon(configuration.icon())
                    .with_size(px(LitheMetrics::TREE_ICON_SIZE))
                    .text_color(foreground),
            )
            .child(
                div()
                    .min_w(px(0.0))
                    .flex_1()
                    .truncate()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(foreground)
                    .child(configuration.name.clone()),
            )
            .child(div().size(px(6.0)).rounded_full().bg(status_color))
            .child(
                Button::new(format!("lithe-run:edit:{id}"))
                    .ghost()
                    .small()
                    .child(Icon::new(IconName::Settings).with_size(px(13.0)))
                    .tooltip(tr("Edit Service"))
                    .accessibility_label(tr("Edit Service"))
                    .on_click(cx.listener(move |this, _, window, cx| {
                        this.invoke_open_settings(&id_for_settings, window, cx);
                    })),
            )
            .child(
                Button::new(format!("lithe-run:toggle:{id}"))
                    .ghost()
                    .small()
                    .child(
                        Icon::new(if running {
                            IconName::Square
                        } else {
                            IconName::Play
                        })
                        .with_size(px(13.0))
                        .text_color(if running {
                            tokens.warning
                        } else {
                            tokens.success
                        }),
                    )
                    .tooltip(tr(if running { "Stop" } else { "Run" }))
                    .on_click(cx.listener(move |this, _, _window, cx| {
                        if let Some(session) = this.sessions.get(&id_for_toggle) {
                            if session.is_active() {
                                this.stop_configuration(&id_for_toggle, cx);
                                return;
                            }
                        }
                        this.start_configuration(id_for_toggle.clone(), cx);
                    })),
            )
            .into_any_element()
    }

    /// 控制台左侧动作条。对齐 macOS `OutputTextView.consoleToolbar` 的六项动作：
    /// 上一条 / 下一条堆栈帧、软换行、滚动到底、打印、清空。
    fn render_console_stripe(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let has_output = self.selected_has_output();
        let has_stack = !self.stack_trace_lines().is_empty();

        v_flex()
            .id("lithe-run-console-actions")
            .w(px(CONSOLE_ACTION_STRIPE_WIDTH))
            .flex_shrink_0()
            .h_full()
            .items_center()
            .gap(px(2.0))
            .pt(px(4.0))
            .min_h(px(0.0))
            .bg(tokens.sidebar)
            .border_r_1()
            .border_color(tokens.divider)
            .child(
                Button::new("lithe-run:prev-stack-trace")
                    .ghost()
                    .small()
                    .child(Icon::new(IconName::ArrowUp).with_size(px(14.0)))
                    .tooltip(tr("Previous Stack Trace"))
                    .disabled(!has_stack)
                    .on_click(cx.listener(|this, _, _window, cx| {
                        this.jump_stack_trace(false, cx);
                    })),
            )
            .child(
                Button::new("lithe-run:next-stack-trace")
                    .ghost()
                    .small()
                    .child(Icon::new(IconName::ArrowDown).with_size(px(14.0)))
                    .tooltip(tr("Next Stack Trace"))
                    .disabled(!has_stack)
                    .on_click(cx.listener(|this, _, _window, cx| {
                        this.jump_stack_trace(true, cx);
                    })),
            )
            .child(
                Button::new("lithe-run:stripe-wrap")
                    .ghost()
                    .small()
                    .child(Icon::new(IconName::Menu).with_size(px(14.0)))
                    .tooltip(tr("Use soft wraps"))
                    .selected(self.wrap_output)
                    .on_click(cx.listener(|this, _, _window, cx| {
                        this.wrap_output = !this.wrap_output;
                        cx.notify();
                    })),
            )
            .child(
                Button::new("lithe-run:scroll-to-end")
                    .ghost()
                    .small()
                    .icon(icon(LitheIcon::ChevronDown))
                    .tooltip(tr("Scroll to the End"))
                    .disabled(!has_output)
                    .on_click(cx.listener(|this, _, _window, cx| this.scroll_to_latest(cx))),
            )
            .child(
                Button::new("lithe-run:print-output")
                    .ghost()
                    .small()
                    .child(Icon::new(IconName::FileText).with_size(px(14.0)))
                    .tooltip(tr("Print"))
                    .disabled(!has_output)
                    .on_click(cx.listener(|this, _, _window, cx| this.print_output(cx))),
            )
            .child(
                Button::new("lithe-run:stripe-clear")
                    .ghost()
                    .small()
                    .child(Icon::new(IconName::Delete).with_size(px(14.0)))
                    .tooltip(tr("Clear Console"))
                    .disabled(!has_output)
                    .on_click(cx.listener(|this, _, _window, cx| this.clear_output(cx))),
            )
            .into_any_element()
    }

    fn render_content(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let selected_config = self.selected_configuration();

        let details_header = div()
            .w_full()
            .px(px(14.0))
            .py(px(8.0))
            .border_b_1()
            .border_color(tokens.divider)
            .child(
                div()
                    .text_size(px(12.0))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(tokens.secondary_text)
                    .child(tr("Configuration details")),
            )
            .when_some(selected_config, |this, config| {
                this.child(
                    div()
                        .pt(px(2.0))
                        .text_size(px(14.0))
                        .font_weight(FontWeight::BOLD)
                        .text_color(tokens.primary_text)
                        .child(config.name.clone()),
                )
                .child(
                    h_flex()
                        .pt(px(4.0))
                        .gap(px(20.0))
                        .text_size(px(12.0))
                        .child(
                            h_flex()
                                .gap(px(6.0))
                                .child(div().text_color(tokens.secondary_text).child(tr("Type")))
                                .child(
                                    div()
                                        .text_color(tokens.primary_text)
                                        .child(config.kind_title()),
                                ),
                        )
                        .when_some(config.main_class(), |this, main_class| {
                            this.child(
                                h_flex()
                                    .gap(px(6.0))
                                    .child(
                                        div()
                                            .text_color(tokens.secondary_text)
                                            .child(tr("Main class")),
                                    )
                                    .child(
                                        div()
                                            .text_color(tokens.primary_text)
                                            .font_family(MONO_FONT_FAMILY)
                                            .child(main_class.to_string()),
                                    ),
                            )
                        }),
                )
            });

        let output_area = v_flex()
            .flex_1()
            .min_h(px(0.0))
            .min_w(px(0.0))
            .child(
                div()
                    .px(px(14.0))
                    .pt(px(8.0))
                    .text_size(px(12.0))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(tokens.secondary_text)
                    .child(tr("Process output")),
            )
            .child(div().flex_1().min_h(px(0.0)).min_w(px(0.0)).child(
                if !self.selected_has_output() {
                    div()
                        .size_full()
                        .px(px(14.0))
                        .pt(px(10.0))
                        .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                        .text_color(tokens.secondary_text)
                        .child(tr("Run a configuration to see process output."))
                        .into_any_element()
                } else {
                    // 行样式只在渲染可视行时构造，不再对整段输出做全文排版。
                    let text_style = self.console_text_style(tokens);
                    div()
                        .id("lithe-run-console")
                        .relative()
                        .size_full()
                        .key_context(CONSOLE_CONTEXT)
                        .track_focus(&self.console_focus)
                        .on_action(cx.listener(Self::on_copy_selection))
                        .on_mouse_down(
                            MouseButton::Left,
                            cx.listener(|this, _, window, cx| this.console_focus.focus(window, cx)),
                        )
                        .child(
                            div()
                                .id("lithe-run-output")
                                .relative()
                                .size_full()
                                .p(px(PANEL_PADDING))
                                // 控制台用 uniform_list：行高固定（Nowrap 单行），
                                // 只排版可视行。gpui 0.3.10 的 `list()` 在此布局下
                                // 只度量不绘制，不要改回去。
                                .child({
                                    let panel = cx.entity();
                                    uniform_list(
                                        "lithe-run-output-lines",
                                        self.selected_line_count(),
                                        move |range, _window, cx| {
                                            let panel = panel.read(cx);
                                            range
                                                .map(|index| {
                                                    console_line_element(
                                                        format!("lithe-run-line:{index}"),
                                                        panel.selected_line_text(index),
                                                        text_style.clone(),
                                                    )
                                                })
                                                .collect::<Vec<_>>()
                                        },
                                    )
                                    .track_scroll(&self.console_scroll)
                                    .size_full()
                                }),
                        )
                        .into_any_element()
                },
            ));

        let body = if self.show_details {
            self.render_details(tokens, cx)
        } else {
            v_flex()
                .flex_1()
                .min_h(px(0.0))
                .min_w(px(0.0))
                .child(details_header)
                .child(output_area)
                .into_any_element()
        };

        v_flex()
            .id("lithe-run-content")
            .size_full()
            .min_w(px(0.0))
            .min_h(px(0.0))
            .bg(tokens.editor)
            .child(body)
            .into_any_element()
    }

    /// 控制台行的文本样式。等宽字体 + 按需软换行，整份列表共用一份。
    fn console_text_style(&self, tokens: LitheTokens) -> TextStyleRefinement {
        TextStyleRefinement {
            font_family: Some(MONO_FONT_FAMILY.into()),
            font_size: Some(px(LitheMetrics::CODE_FONT_SIZE).into()),
            color: Some(tokens.primary_text),
            white_space: Some(if self.wrap_output {
                WhiteSpace::Normal
            } else {
                WhiteSpace::Nowrap
            }),
            ..Default::default()
        }
    }

    /// 取当前会话第 `index` 行的文本，供虚拟化列表逐行渲染。
    fn selected_line_text(&self, index: usize) -> String {
        self.selected_id
            .as_ref()
            .and_then(|id| self.sessions.get(id))
            .map(|session| session.line_at(index).to_string())
            .unwrap_or_default()
    }

    fn render_details(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let Some(configuration) = self.selected_configuration() else {
            return empty_state(tokens, tr("Select a run configuration to see its details."));
        };
        let edit_id = configuration.id.clone();
        let mut details = v_flex()
            .id("lithe-run-details")
            .flex_1()
            .min_w(px(0.0))
            .min_h(px(0.0))
            .overflow_y_scroll()
            .gap(px(10.0))
            .p(px(16.0))
            .bg(tokens.editor)
            .child(
                h_flex()
                    .w_full()
                    .items_center()
                    .gap(px(8.0))
                    .child(
                        div()
                            .text_size(px(13.0))
                            .font_weight(FontWeight::SEMIBOLD)
                            .text_color(tokens.primary_text)
                            .child(tr("Configuration details")),
                    )
                    .child(div().flex_1())
                    .child(
                        Button::new("lithe-run:details-edit")
                            .small()
                            .h(px(24.0))
                            .rounded(px(6.0))
                            .secondary()
                            .label(tr("Edit Configuration…"))
                            .on_click(cx.listener(move |this, _, window, cx| {
                                this.invoke_open_settings(&edit_id, window, cx);
                            })),
                    ),
            );

        let mut rows: Vec<(&'static str, String, bool)> = vec![
            (tr("Type"), configuration.kind_title(), false),
            (
                tr("Category"),
                configuration.execution.title().to_string(),
                false,
            ),
            (tr("Provider"), configuration.provider.clone(), true),
            (
                tr("Working directory"),
                configuration.working_directory().to_string(),
                true,
            ),
        ];
        if let Some(module) = configuration.module().filter(|value| !value.trim().is_empty()) {
            rows.push((tr("Module"), module.to_string(), true));
        }
        if let Some(main_class) = configuration
            .main_class()
            .filter(|value| !value.trim().is_empty())
        {
            rows.push((tr("Main class"), main_class.to_string(), true));
        }
        if !configuration.java_home_path.trim().is_empty() {
            rows.push((
                tr("JDK home"),
                configuration.java_home_path.clone(),
                true,
            ));
        }
        if !configuration.maven_executable_path.trim().is_empty() {
            rows.push((
                tr("Maven"),
                configuration.maven_executable_path.clone(),
                true,
            ));
        }
        if !configuration.maven_java_home_path.trim().is_empty() {
            rows.push((
                tr("Maven JDK"),
                configuration.maven_java_home_path.clone(),
                true,
            ));
        }
        if !configuration.jvm_arguments.is_empty() {
            rows.push((
                tr("VM arguments"),
                configuration.jvm_arguments.join(" "),
                true,
            ));
        }
        rows.push((
            tr("Program arguments"),
            configuration.program_arguments.join(" "),
            true,
        ));
        rows.push((
            tr("Environment"),
            configuration
                .env
                .iter()
                .map(|(key, value)| format!("{key}={value}"))
                .collect::<Vec<_>>()
                .join("\n"),
            true,
        ));
        rows.push((
            tr("Source"),
            configuration.source_title().to_string(),
            false,
        ));
        rows.push((
            tr("Configuration ID"),
            configuration.id.clone(),
            true,
        ));
        for (label, value, monospaced) in rows {
            details = details.child(detail_row(label, value, monospaced, tokens));
        }
        details.into_any_element()
    }

    /// 按配置类型分组（Java / Maven / Node.js …），组内按名称排序，保证渲染顺序确定。
    fn group_configurations<'a>(
        &self,
        configurations: &[&'a RunConfiguration],
    ) -> Vec<(String, Vec<&'a RunConfiguration>)> {
        let mut groups: BTreeMap<String, Vec<&RunConfiguration>> = BTreeMap::new();
        for configuration in configurations {
            groups
                .entry(configuration.kind_title())
                .or_default()
                .push(configuration);
        }
        let mut groups: Vec<_> = groups.into_iter().collect();
        groups.sort_by(|left, right| left.0.to_lowercase().cmp(&right.0.to_lowercase()));
        for (_, group) in &mut groups {
            group.sort_by(|left, right| {
                left.name
                    .to_lowercase()
                    .cmp(&right.name.to_lowercase())
                    .then_with(|| left.id.cmp(&right.id))
            });
        }
        groups
    }

    /// 顶部项目准备状态条（对齐 Tauri `ProjectPreparationStatus`）。
    fn render_preparation_status(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let Some(preparation) = self.preparation.as_ref() else {
            return div().into_any_element();
        };
        if preparation.phase == PreparationPhase::Stopped {
            return div().into_any_element();
        }

        let expanded = self.preparation_expanded;
        let chevron = if expanded {
            IconName::ChevronDown
        } else {
            IconName::ChevronRight
        };

        let is_loading = preparation.status == PreparationStatus::Loading;
        let is_failed = preparation.status == PreparationStatus::Failed;

        let label = if is_failed {
            tr("Java project preparation failed — view details").to_string()
        } else if let Some(percent) = preparation.import_percent {
            format!("{}: {percent}%", tr("Importing Java project and dependencies"))
        } else {
            preparation.phase.label().to_string()
        };

        let summary_icon = if is_loading {
            Icon::new(IconName::RotateCw)
                .with_size(px(13.0))
                .text_color(tokens.accent)
        } else if is_failed {
            Icon::new(IconName::TriangleAlert)
                .with_size(px(14.0))
                .text_color(tokens.error)
        } else {
            Icon::new(IconName::CircleCheck)
                .with_size(px(14.0))
                .text_color(tokens.success)
        };

        let summary = h_flex()
            .id("lithe-run-preparation-status")
            .w_full()
            .h(px(26.0))
            .items_center()
            .gap(px(6.0))
            .px(px(12.0))
            .bg(tokens.sidebar)
            .when(!expanded, |this| {
                this.border_b_1().border_color(tokens.divider)
            })
            .cursor_pointer()
            .hover(|style| style.bg(tokens.hover))
            .on_click(cx.listener(|this, _, _window, cx| {
                this.preparation_expanded = !this.preparation_expanded;
                cx.notify();
            }))
            .child(
                Icon::new(chevron)
                    .with_size(px(12.0))
                    .text_color(tokens.secondary_text),
            )
            .child(summary_icon)
            .child(
                div()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .when(is_failed, |this| this.text_color(tokens.error))
                    .when(!is_failed, |this| this.text_color(tokens.secondary_text))
                    .child(label),
            );

        if !expanded {
            return summary.into_any_element();
        }

        let phases = [
            (PreparationPhase::Starting, tr("Starting Java service")),
            (PreparationPhase::Importing, tr("Importing Java project and dependencies")),
            (PreparationPhase::Configuring, tr("Synchronizing Java project configuration")),
            (PreparationPhase::Building, tr("Building Java project")),
        ];

        let phase_order = |p: PreparationPhase| -> u8 {
            match p {
                PreparationPhase::Starting => 0,
                PreparationPhase::Importing => 1,
                PreparationPhase::Configuring => 2,
                PreparationPhase::Building => 3,
                PreparationPhase::Ready => 4,
                _ => 0,
            }
        };

        let current_order = phase_order(preparation.phase);

        let mut phase_list = v_flex().gap(px(4.0));
        for (phase, phase_label) in phases {
            let order = phase_order(phase);
            let is_current = preparation.phase == phase;
            let is_done = order < current_order || preparation.status == PreparationStatus::Ready;

            let icon_element = if is_current && is_loading {
                Icon::new(IconName::RotateCw)
                    .with_size(px(12.0))
                    .text_color(tokens.accent)
            } else if is_done {
                Icon::new(IconName::Check)
                    .with_size(px(12.0))
                    .text_color(tokens.success)
            } else {
                Icon::new(IconName::ChevronRight)
                    .with_size(px(12.0))
                    .text_color(tokens.divider)
            };

            let text_color = if is_current {
                tokens.primary_text
            } else if is_done {
                tokens.secondary_text
            } else {
                tokens.tertiary_text
            };

            phase_list = phase_list.child(
                h_flex()
                    .gap(px(6.0))
                    .items_center()
                    .child(icon_element)
                    .child(
                        div()
                            .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                            .when(is_current, |this| this.font_weight(FontWeight::MEDIUM))
                            .text_color(text_color)
                            .child(phase_label),
                    ),
            );
        }

        let details = v_flex()
            .id("lithe-run-preparation-status-details")
            .w_full()
            .px(px(24.0))
            .py(px(8.0))
            .gap(px(8.0))
            .bg(tokens.sidebar)
            .border_b_1()
            .border_color(tokens.divider)
            .child(phase_list)
            .child(
                div()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.tertiary_text)
                    .child(tr("The Java workspace must finish preparation before launch. Background indexing does not block running; compilation runs before launch.")),
            )
            .child(
                h_flex()
                    .gap(px(16.0))
                    .items_center()
                    .child(
                        div()
                            .id("lithe-run-preparation-settings-btn")
                            .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                            .text_color(tokens.link)
                            .cursor_pointer()
                            .hover(|style| style.underline())
                            .on_click(cx.listener(|this, _, window, cx| {
                                if let Some(handler) = &this.on_open_settings {
                                    handler("language", window, cx);
                                }
                            }))
                            .child(tr("Language service settings and retry")),
                    )
                    .child(
                        div()
                            .id("lithe-run-preparation-logs-btn")
                            .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                            .text_color(tokens.link)
                            .cursor_pointer()
                            .hover(|style| style.underline())
                            .on_click(cx.listener(|this, _, window, cx| {
                                if let Some(handler) = &this.on_open_settings {
                                    handler("logs", window, cx);
                                }
                            }))
                            .child(tr("View logs")),
                    ),
            );

        v_flex()
            .w_full()
            .child(summary)
            .child(details)
            .into_any_element()
    }

    /// 单层标题栏（完全对齐 Tauri `RunPane` Header：`▷ 运行 <项目名>` + 右侧操作按钮组）。
    fn render_header(&mut self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let is_running = self.is_running();
        let project_name = self
            .root
            .as_ref()
            .and_then(|r| r.file_name())
            .and_then(|n| n.to_str())
            .unwrap_or("");
        let title_text = if project_name.is_empty() {
            tr("Run").to_string()
        } else {
            format!("{} {project_name}", tr("Run"))
        };

        h_flex()
            .id("lithe-run-header")
            .w_full()
            .flex_shrink_0()
            .items_center()
            .gap(px(4.0))
            .h(px(34.0))
            .pl(px(12.0))
            .pr(px(8.0))
            .bg(tokens.tool_header)
            .border_b_1()
            .border_color(tokens.divider)
            .child(
                Icon::new(IconName::Play)
                    .with_size(px(14.0))
                    .text_color(tokens.success),
            )
            .child(
                div()
                    .min_w(px(0.0))
                    .truncate()
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .font_weight(FontWeight::SEMIBOLD)
                    .text_color(tokens.primary_text)
                    .child(title_text),
            )
            .child(div().flex_1())
            // 右侧操作图标组：运行/停止、重新扫描、滚动到底部、软换行、清空、收起
            .child(
                Button::new("lithe-run:play")
                    .ghost()
                    .small()
                    .child(
                        Icon::new(if is_running {
                            IconName::Square
                        } else {
                            IconName::Play
                        })
                        .with_size(px(13.0))
                        .text_color(if is_running {
                            tokens.warning
                        } else {
                            tokens.success
                        }),
                    )
                    .tooltip(tr(if is_running { "Stop run" } else { "Run" }))
                    .on_click(cx.listener(|this, _, _window, cx| {
                        if this.is_running() {
                            this.stop_selected(cx);
                        } else {
                            this.run_selected(cx);
                        }
                    })),
            )
            .child(
                Button::new("lithe-run:more-services")
                    .ghost()
                    .small()
                    .child(Icon::new(IconName::Ellipsis).with_size(px(13.0)))
                    .tooltip(tr("Choose services"))
                    .on_click(cx.listener(|this, event: &ClickEvent, window, cx| {
                        // 点击处即菜单左上角；键盘触发的点击退回工具条右侧。
                        let position = match event {
                            ClickEvent::Mouse(mouse) => mouse.up.position,
                            _ => Default::default(),
                        };
                        this.toggle_more_menu(position, window, cx);
                    })),
            )
            .child(
                Button::new("lithe-run:rescan")
                    .ghost()
                    .small()
                    .child(Icon::new(IconName::RotateCw).with_size(px(13.0)))
                    .tooltip(tr("Rescan services"))
                    .disabled(self.loading)
                    .on_click(cx.listener(|this, _, _window, cx| this.reload(cx))),
            )
            .child(
                Button::new("lithe-run:scroll-end")
                    .ghost()
                    .small()
                    .child(
                        Icon::new(gpui_kit::assets::IconName::ArrowDownToLine).with_size(px(13.0)),
                    )
                    .tooltip(tr("Scroll to end"))
                    .on_click(cx.listener(move |this, _, _window, cx| this.scroll_to_latest(cx))),
            )
            .child(
                Button::new("lithe-run:wrap")
                    .ghost()
                    .small()
                    .icon(icon(LitheIcon::WrapText))
                    .tooltip(tr("Use soft wraps"))
                    .selected(self.wrap_output)
                    .on_click(cx.listener(move |this, _, _window, cx| {
                        this.wrap_output = !this.wrap_output;
                        this.emit(cx);
                        cx.notify();
                    })),
            )
            .child(
                Button::new("lithe-run:clear")
                    .ghost()
                    .small()
                    .child(Icon::new(gpui_kit::assets::IconName::Trash).with_size(px(13.0)))
                    .tooltip(tr("Clear output"))
                    .on_click(cx.listener(|this, _, _window, cx| {
                        let id = this.selected_id.clone().or_else(|| this.default_id.clone());
                        if let Some(id) = id {
                            if let Some(session) = this.sessions.get_mut(&id) {
                                session.clear();
                            }
                            this.console_line_count = 0;
                            this.console_follow_tail = true;
                            cx.notify();
                        }
                    })),
            )
            .child(
                Button::new("lithe-run:hide")
                    .ghost()
                    .small()
                    .child(Icon::new(IconName::Minus).with_size(px(13.0)))
                    .tooltip(tr("Minimize"))
                    .on_click(cx.listener(|this, _, _window, cx| this.hide_panel(cx))),
            )
            .into_any_element()
    }

    /// 未找到运行配置的空状态视图（完全对齐 Tauri 图一）。
    fn render_missing_configuration_view(
        &self,
        tokens: LitheTokens,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let is_loading = self.loading;
        v_flex()
            .size_full()
            .items_center()
            .justify_center()
            .gap(px(10.0))
            .px(px(24.0))
            .bg(tokens.editor)
            .child(
                Icon::new(IconName::Play)
                    .with_size(px(36.0))
                    .text_color(tokens.tertiary_text),
            )
            .child(
                div()
                    .text_size(px(15.0))
                    .font_weight(FontWeight::BOLD)
                    .text_color(tokens.primary_text)
                    .child(tr("Project run configuration not found")),
            )
            .child(
                div()
                    .max_w(px(480.0))
                    .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(tr("Identify the project to enable Run. Existing project and local overrides will be preserved.")),
            )
            .child(
                div()
                    .pt(px(6.0))
                    .child(
                        Button::new("lithe-run:identify-btn")
                            .primary()
                            .disabled(is_loading)
                            .label(if is_loading {
                                tr("Identifying project…")
                            } else {
                                tr("Identify and generate")
                            })
                            .on_click(cx.listener(|this, _, _window, cx| {
                                this.reload(cx);
                            })),
                    ),
            )
            .into_any_element()
    }

    /// 配置诊断提示条。对齐 macOS `configurationNotice`：Core 会为每个配置各返回
    /// 一条诊断（`RunDiagnostic.id` 指向具体配置），逐条铺开会把同一句话重复几十
    /// 遍，所以这里只展示一条——优先 staleFingerprint，否则取第一条。
    fn render_banners(&self, _tokens: LitheTokens) -> Vec<AnyElement> {
        let notice = self
            .diagnostics
            .iter()
            .find(|diagnostic| diagnostic.code == "staleFingerprint")
            .or_else(|| self.diagnostics.first());
        notice
            .map(|diagnostic| {
                Alert::warning(
                    SharedString::from("lithe-run:diagnostic"),
                    SharedString::from(diagnostic.message.clone()),
                )
                .banner()
                .into_any_element()
            })
            .into_iter()
            .collect()
    }

    /// 主体：固定宽度的作用域图标条 + 可拖拽的「配置列表 / 输出」分栏。
    ///
    /// 宽度规则对齐 macOS `RunServicesSplitView`：配置列表 240..480，输出区
    /// 最小 320；可用宽度不足时整行横向滚动，而不是把两栏压到互相遮字。
    fn render_body(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let minimum_width = 100.0 + CONFIGURATION_LIST_MIN_WIDTH + OUTPUT_MIN_WIDTH;
        div()
            .id("lithe-run-body")
            .flex_1()
            .min_h(px(0.0))
            .min_w(px(0.0))
            .overflow_x_scroll()
            .child(
                h_flex()
                    .h_full()
                    .min_w(px(minimum_width))
                    .child(self.render_language_rail(tokens, cx))
                    .child(self.render_split(tokens, cx)),
            )
            .into_any_element()
    }

    /// 配置列表 / 输出分栏。尺寸由 gpui-kit 的 `h_resizable` 维护，拖拽结束
    /// 回写 `configuration_width`，与 macOS 的 AppStorage 持久化语义一致。
    fn render_split(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let owner = cx.weak_entity();
        let group = h_resizable("lithe-run-split")
            .with_state(&self.split_state)
            .on_resize(move |state, _window, cx| {
                let sizes = state.read(cx).sizes().clone();
                let _ = owner.update(cx, |this, cx| {
                    let Some(width) = sizes.first().copied() else {
                        return;
                    };
                    let width = width
                        .as_f32()
                        .clamp(CONFIGURATION_LIST_MIN_WIDTH, CONFIGURATION_LIST_MAX_WIDTH);
                    if (this.configuration_width - width).abs() > 0.5 {
                        this.configuration_width = width;
                        cx.notify();
                    }
                });
            })
            .child(
                resizable_panel()
                    .size(px(self.configuration_width))
                    .size_range(px(CONFIGURATION_LIST_MIN_WIDTH)..px(CONFIGURATION_LIST_MAX_WIDTH))
                    .child(self.render_configuration_list(tokens, cx)),
            )
            .child(
                resizable_panel()
                    .size_range(px(OUTPUT_MIN_WIDTH)..px(4096.0))
                    .child(self.render_content(tokens, cx)),
            );

        div()
            .flex_1()
            .h_full()
            .min_w(px(0.0))
            .child(group)
            .into_any_element()
    }
}

impl Render for RunPanel {
    fn render(&mut self, window: &mut Window, cx: &mut Context<Self>) -> impl IntoElement {
        self.ensure_loaded(window, cx);
        // 输出行数变化在这里统一入账：列表只排版可视行，追加只改行数。
        self.sync_console_lines();
        let tokens = current_tokens(cx);

        let mut panel = v_flex()
            .id("lithe-run-panel")
            .size_full()
            .min_w(px(0.0))
            .min_h(px(0.0))
            .bg(tokens.editor)
            .text_color(tokens.primary_text)
            .child(self.render_preparation_status(tokens, cx))
            .child(self.render_header(tokens, cx));

        if let Some(error) = self.error.clone() {
            panel = panel.child(status_line(tokens.error, error));
        }
        for banner in self.render_banners(tokens) {
            panel = panel.child(banner);
        }

        // 当没有运行配置且没有进程运行时，对齐图一展示居中的未找到运行配置引导卡片；
        // 否则展示完整的运行控制台
        if self.configurations.is_empty() && !self.is_running() {
            panel = panel.child(
                div()
                    .flex_1()
                    .min_h_0()
                    .child(self.render_missing_configuration_view(tokens, cx)),
            );
        } else {
            panel = panel.child(self.render_body(tokens, cx));
        }

        self.with_floating_menu(panel.into_any_element(), cx)
    }
}

impl RunPanel {
    /// 把「…」创建的 PopupMenu 渲染到窗口前景层。
    ///
    /// 之前菜单实体只创建不渲染，工具条菜单从未显示过。
    fn with_floating_menu(&self, element: AnyElement, cx: &mut Context<Self>) -> AnyElement {
        let Some((popup, position)) = &self.more_menu else {
            return element;
        };
        let owner = cx.weak_entity();
        deferred(
            anchored().position(*position).snap_to_window().child(
                div()
                    .occlude()
                    .on_mouse_down_out(cx.listener(move |this, _, _, cx| {
                        if this.more_menu.take().is_some() {
                            cx.notify();
                        }
                    }))
                    .child(popup.clone()),
            ),
        )
        .into_any_element()
    }
}

impl SessionState {
    /// 追加一块输出。
    ///
    /// 完整行进入 `lines`，结尾的半行留在 `pending_line` 等下一块补全。
    /// 这样虚拟化列表的每一行都是稳定的字符串，追加时只需要往尾部 push，
    /// 不必像旧实现那样每帧把整段文本重新排版。
    fn append_output(&mut self, chunk: &str) {
        let text = strip_ansi(chunk);
        if text.is_empty() {
            return;
        }
        if self.service_url.is_none() {
            self.service_url = find_service_url(&text);
        }

        self.pending_line.push_str(&text);
        // 只按换行切分：`str::lines()` 会吞掉结尾空行，控制台需要保留它们。
        let mut start = 0;
        while let Some(offset) = self.pending_line[start..].find('\n') {
            let end = start + offset;
            let line = self.pending_line[start..end].to_string();
            // 去掉行尾的 `\r`：Windows 控制台程序（含 Maven）混用 CRLF。
            let line = line.strip_suffix('\r').unwrap_or(&line).to_string();
            self.lines.push(SharedString::from(line));
            start = end + 1;
        }
        if start > 0 {
            self.pending_line.drain(..start);
        }
        self.trim_lines();
    }

    /// 把残留的半行也显示出来。
    ///
    /// 进程退出时最后一行通常没有换行；不把它并入 `lines` 就会丢最后一条输出。
    fn flush_pending_line(&mut self) {
        if self.pending_line.is_empty() {
            return;
        }
        let line = std::mem::take(&mut self.pending_line);
        let line = line.strip_suffix('\r').unwrap_or(&line).to_string();
        self.lines.push(SharedString::from(line));
        self.trim_lines();
    }

    /// 超出上限时从头部整行淘汰。每次只丢头部，避免整段搬运。
    fn trim_lines(&mut self) {
        let excess = self.lines.len().saturating_sub(MAX_OUTPUT_LINES);
        if excess > 0 {
            self.lines.drain(..excess);
            self.truncated = true;
        }
    }

    /// 当前用于展示的行数（含未换行的半行）。
    fn display_line_count(&self) -> usize {
        self.lines.len() + usize::from(!self.pending_line.is_empty())
    }

    /// 取第 `index` 行的文本。越界返回空行，保证虚拟化列表不会 panic。
    fn line_at(&self, index: usize) -> &str {
        match self.lines.get(index) {
            Some(line) => line.as_ref(),
            None if index == self.lines.len() => self.pending_line.as_str(),
            None => "",
        }
    }

    /// 整段输出文本。复制、打印和诊断需要全文时使用，不做流式渲染。
    fn full_text(&self) -> String {
        let mut text = self.lines.join("\n");
        if !self.pending_line.is_empty() {
            if !text.is_empty() {
                text.push('\n');
            }
            text.push_str(&self.pending_line);
        }
        text
    }

    fn clear(&mut self) {
        self.lines.clear();
        self.pending_line.clear();
        self.truncated = false;
        self.service_url = None;
    }
}

/// 渲染控制台的一行。
///
/// 空行也占一行高（`min_h`），否则连续空行会被折叠，输出位置和原进程不一致。
/// 关闭软换行时行内容横向溢出交给列表的横向滚动，不把长行折断。
fn console_line_element(id: String, text: String, style: TextStyleRefinement) -> AnyElement {
    let element_id = SharedString::from(id.clone());
    div()
        .id(element_id.clone())
        .w_full()
        .min_h(px(CONSOLE_LINE_HEIGHT))
        .flex_shrink_0()
        .child(gpui_kit::base::SelectableText::new(element_id, text).text_style(style))
        .into_any_element()
}

#[allow(dead_code)]
fn empty_state(tokens: LitheTokens, message: &str) -> AnyElement {
    v_flex()
        .w_full()
        .flex_1()
        .min_h(px(0.0))
        .items_center()
        .justify_center()
        .px(px(PANEL_PADDING))
        .child(
            div()
                .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                .text_color(tokens.secondary_text)
                .child(message.to_string()),
        )
        .into_any_element()
}

/// 判断一行是否是堆栈帧（Java 的 `at x.y.Foo.bar(Foo.java:42)` 或带
/// `file:line` 的 `at ` 行）。上一/下一条堆栈帧按这些行跳转，与 macOS
/// `ConsoleToolbarAction.previous/next` 的定位依据一致。
#[allow(dead_code)]
fn is_stack_trace_line(line: &str) -> bool {
    let trimmed = line.trim_start();
    let frame = trimmed
        .strip_prefix("at ")
        .or_else(|| trimmed.strip_prefix("Caused by: "))
        .unwrap_or(trimmed);
    if let Some(open) = frame.rfind('(') {
        let inner = frame[open + 1..].trim_end_matches(')');
        if let Some((file, line_number)) = inner.rsplit_once(':') {
            return !file.is_empty()
                && line_number
                    .chars()
                    .all(|character| character.is_ascii_digit());
        }
    }
    false
}

fn status_line(color: Hsla, message: SharedString) -> AnyElement {
    h_flex()
        .w_full()
        .flex_shrink_0()
        .h(px(STATUS_LINE_HEIGHT))
        .px(px(PANEL_PADDING))
        .child(
            div()
                .min_w(px(0.0))
                .flex_1()
                .truncate()
                .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                .text_color(color)
                .child(message),
        )
        .into_any_element()
}

#[allow(dead_code)]
fn detail_row(label: &str, value: String, monospaced: bool, tokens: LitheTokens) -> AnyElement {
    h_flex()
        .w_full()
        .items_start()
        .gap(px(12.0))
        .child(
            div()
                .w(px(150.0))
                .flex_shrink_0()
                .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                .text_color(tokens.secondary_text)
                .child(label.to_string()),
        )
        .child(
            div()
                .min_w(px(0.0))
                .flex_1()
                .text_size(px(LitheMetrics::SETTINGS_FONT_SIZE))
                .text_color(tokens.primary_text)
                .when(monospaced, |this| this.font_family(MONO_FONT_FAMILY))
                .child(value),
        )
        .into_any_element()
}

/// 去掉常见 ANSI CSI/OSC 序列；运行控制台只显示文本。
fn strip_ansi(text: &str) -> String {
    let mut output = String::with_capacity(text.len());
    let mut characters = text.chars().peekable();
    while let Some(character) = characters.next() {
        if character != '\x1b' {
            output.push(character);
            continue;
        }
        match characters.next() {
            Some('[') => {
                for next in characters.by_ref() {
                    if ('@'..='~').contains(&next) {
                        break;
                    }
                }
            }
            Some(']') => {
                while let Some(next) = characters.next() {
                    if next == '\x07' {
                        break;
                    }
                    if next == '\x1b' && characters.peek() == Some(&'\\') {
                        characters.next();
                        break;
                    }
                }
            }
            _ => {}
        }
    }
    output
}

/// 从输出里找本机服务地址。只接受 localhost/127.0.0.1/0.0.0.0。
fn find_service_url(output: &str) -> Option<String> {
    for token in output.split(|character: char| {
        character.is_whitespace() || matches!(character, '"' | '\'' | '`' | ',' | ')' | '(')
    }) {
        let token = token.trim_matches(|character: char| {
            matches!(character, '.' | ';' | ':' | ']' | '[' | '{' | '}')
        });
        if let Some(rest) = token
            .strip_prefix("http://")
            .or_else(|| token.strip_prefix("https://"))
        {
            let (authority, _) = rest
                .split_once('/')
                .map_or((rest, ""), |(authority, path)| (authority, path));
            if let Some(url) = service_url_from_authority(authority, token.starts_with("https://"))
            {
                return Some(url);
            }
        }
        let lower = token.to_ascii_lowercase();
        for host in ["localhost:", "127.0.0.1:", "0.0.0.0:"] {
            if let Some(rest) = lower.strip_prefix(host) {
                let port = rest
                    .chars()
                    .take_while(|character| character.is_ascii_digit())
                    .collect::<String>();
                if let Ok(port) = port.parse::<u16>() {
                    return Some(format!("http://127.0.0.1:{port}"));
                }
            }
        }
    }
    None
}

fn service_url_from_authority(authority: &str, secure: bool) -> Option<String> {
    let (host, port) = authority.rsplit_once(':')?;
    let port = port.parse::<u16>().ok()?;
    if !matches!(host, "localhost" | "127.0.0.1" | "0.0.0.0") {
        return None;
    }
    let scheme = if secure { "https" } else { "http" };
    Some(format!("{scheme}://127.0.0.1:{port}"))
}

/// 归一化 Maven 路径比较：`None` / 空串 / `.` 都视作反应堆根 `.`。
fn normalize_relative(value: Option<&str>) -> &str {
    match value {
        Some(value) if !value.trim().is_empty() && value != "." => value,
        _ => ".",
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn strips_ansi_color_sequences() {
        assert_eq!(strip_ansi("\x1b[31mred\x1b[0m plain"), "red plain");
    }

    #[test]
    fn finds_local_service_urls() {
        assert_eq!(
            find_service_url("Tomcat started on port(s): 8080 (http)\n"),
            None
        );
        assert_eq!(
            find_service_url("Listening on http://localhost:5173/\n"),
            Some("http://127.0.0.1:5173".to_string())
        );
        assert_eq!(
            find_service_url("bound to 0.0.0.0:9000\n"),
            Some("http://127.0.0.1:9000".to_string())
        );
    }
}
