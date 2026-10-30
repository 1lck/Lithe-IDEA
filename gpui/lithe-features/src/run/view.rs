//! Run 工具窗：运行配置、会话控制和控制台。
//!
//! 视图只持有 UI 状态与进程树句柄；Core 调用、文件写入和子进程读取都在
//! `config` / `session` 模块里完成后回到视图线程。Run 按钮、Stop 和重跑都
//! 走同一条 `start_configuration` / `stop_configuration` 链路。

use std::collections::{BTreeMap, HashSet};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use async_channel::Receiver;
use gpui_kit::base::{SelectableText, TextSelection};
use gpui_kit::component::alert::Alert;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::checkbox::Checkbox;
use gpui_kit::component::menu::{PopupMenu, PopupMenuItem};
use gpui_kit::component::resizable::{ResizableState, h_resizable, resizable_panel};
use gpui_kit::component::scroll::{ScrollableElement as _, ScrollbarAxis};
use gpui_kit::component::{
    Disableable as _, Icon, IconName, Selectable as _, Sizable as _, h_flex, v_flex,
};
use gpui_kit::prelude::FluentBuilder as _;
use gpui_kit::{
    Anchor, AnyElement, AppContext as _, ClipboardItem, Context, DismissEvent, Entity, EventEmitter,
    FocusHandle, FontWeight, Focusable as _, Hsla, InteractiveElement as _, IntoElement, KeyBinding,
    MouseButton,
    ParentElement, Render, ScrollEvent, ScrollHandle, SharedString, StatefulInteractiveElement as _,
    Styled, Subscription, Task, TextStyleRefinement, WhiteSpace, Window, anchored, deferred, div,
    point, px,
};
use lithe_core_client::CoreClient;
use lithe_git_host::ProcessTree;
use lithe_ui::i18n::tr;
use lithe_ui::{LitheIcon, LitheMetrics, LitheTokens, MONO_FONT_FAMILY, current_tokens, icon};

use super::config::{self, LoadedRunConfigurations};
use super::model::{RunConfiguration, RunDiagnostic, RunExecution, RunScope};
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
/// 距底部多远仍然算“贴底”。对齐 macOS `OutputTextView.bottomThreshold`。
const FOLLOW_BOTTOM_THRESHOLD: f32 = 80.0;

/// 标题栏高度。对齐 macOS `LitheToolWindowHeader` 的 41pt。
const HEADER_HEIGHT: f32 = 41.0;
const TOOLBAR_HEIGHT: f32 = 36.0;
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
const CONSOLE_ACTION_STRIPE_WIDTH: f32 = 28.0;
/// 控制台单行高度估算。macOS 用 TextKit 量出真实行框；GPUI 的纯文本视图没有
/// 逐行句柄，堆栈跳转按“行号 × 行高”换算滚动偏移，关闭软换行时与真实位置一致。
const CONSOLE_LINE_HEIGHT: f32 = 18.0;
const GROUP_HEADER_HEIGHT: f32 = 26.0;
const CONFIGURATION_ROW_HEIGHT: f32 = 30.0;
const PANEL_PADDING: f32 = 12.0;
const STATUS_LINE_HEIGHT: f32 = 24.0;
/// 保留的输出上限。GPUI 的文本视图每帧都要排版整段内容，
/// 保留太多字符会把滚动和刷新都拖慢；macOS 靠 TextKit 的惰性排版不需要这个上限。
const MAX_OUTPUT_CHARACTERS: usize = 200_000;
/// 输出合批窗口：Maven 这类工具每秒可能打印上百行，逐块刷新会让整段
/// 控制台反复重排。先攒在这个窗口内，再一次性追加并只重绘一次。
const OUTPUT_FLUSH_INTERVAL: Duration = Duration::from_millis(40);

/// 一个配置的当前会话状态。
struct SessionState {
    tree: Option<Arc<ProcessTree>>,
    output: String,
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
            output: String::new(),
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
    more_menu: Option<Entity<PopupMenu>>,
    _more_menu_subscription: Option<Subscription>,
    output_scroll: ScrollHandle,
    /// 输出是否仍跟随末尾。用户上翻后不再跟随新输出，直到回到底部或点击
    /// “跳转到最新位置”。
    follow_output: bool,
    /// 控制台焦点：只有它获得焦点时才响应复制快捷键。
    console_focus: FocusHandle,
    /// 尚未合并进会话状态的输出。按配置 id 累积，由定时器统一刷新。
    pending_output: BTreeMap<String, String>,
    /// 是否已经有一个刷新任务在等待；避免每个输出块都排一个定时器。
    output_flush_scheduled: bool,
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
            output_scroll: ScrollHandle::new(),
            follow_output: true,
            console_focus: cx.focus_handle(),
            pending_output: BTreeMap::new(),
            output_flush_scheduled: false,
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
        self.emit(cx);
        cx.notify();
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
    fn selected_output(&self) -> &str {
        self.selected_id
            .as_ref()
            .and_then(|id| self.sessions.get(id))
            .map(|session| session.output.as_str())
            .unwrap_or("")
    }

    /// 控制台是否贴着末尾。向下滚动时 `offset` 和 `max_offset` 都是负值，
    /// 两者之差就是离底部的像素距离。
    fn output_at_bottom(&self) -> bool {
        let distance = self.output_scroll.offset().y - self.output_scroll.max_offset().y;
        distance <= px(FOLLOW_BOTTOM_THRESHOLD)
    }

    /// 用户滚动控制台：只同步“是否仍然跟随末尾”，内容的滚动与重绘交给 GPUI。
    fn on_console_scroll(&mut self, _: &ScrollEvent, window: &mut Window, cx: &mut Context<Self>) {
        // 滚动偏移在同一轮事件派发里才落盘；延后一帧读取到的才是最终位置，
        // 否则一次滚轮会被旧偏移判成“仍在底部”。
        cx.defer_in(window, |this, _window, cx| {
            let at_bottom = this.output_at_bottom();
            if this.follow_output != at_bottom {
                this.follow_output = at_bottom;
                cx.notify();
            }
        });
    }

    /// 回到最新输出（macOS 的 “Jump to latest”）。
    fn scroll_to_latest(&mut self, cx: &mut Context<Self>) {
        self.follow_output = true;
        self.output_scroll.scroll_to_bottom();
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
            self.selected_output().to_string()
        } else {
            selected
        };
        if !text.is_empty() {
            cx.write_to_clipboard(ClipboardItem::new_string(text));
        }
    }

    /// 复制按钮与控制台快捷键共用同一份文本。
    fn copy_output(&mut self, cx: &mut Context<Self>) {
        let text = self.selected_output().to_string();
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
        self.follow_output = true;
        self.output_scroll.scroll_to_bottom();
        self.emit(cx);
        cx.notify();

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
                }
                SessionEvent::Failed(message) => {
                    session.starting = false;
                    session.running = false;
                    session.exit_code = Some(1);
                    session.tree = None;
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
        // 贴底才跟随末尾：用户上翻查看日志时不为新输出抢走滚动位置，
        // 与 macOS 控制台一致。是否贴底由滚动事件维护，输出本身不改状态。
        if self.follow_output {
            self.output_scroll.scroll_to_bottom();
        }
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
                session.output.clear();
                session.service_url = None;
            }
            self.pending_output.remove(&id);
        }
        self.follow_output = true;
        self.output_scroll.scroll_to_bottom();
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
        self.selected_output()
            .lines()
            .enumerate()
            .filter(|(_, line)| is_stack_trace_line(line))
            .map(|(index, _)| index)
            .collect()
    }

    /// 跳到上一条 / 下一条堆栈帧。GPUI 的纯文本视图没有逐行句柄，关闭软换行时
    /// 按“行号 × 行高”换算的偏移与真实位置一致；开启软换行后是近似位置。
    fn jump_stack_trace(&mut self, forward: bool, cx: &mut Context<Self>) {
        let lines = self.stack_trace_lines();
        if lines.is_empty() {
            return;
        }
        let current =
            (-self.output_scroll.offset().y / px(CONSOLE_LINE_HEIGHT)).round().max(0.0) as usize;
        let target = if forward {
            lines.iter().copied().filter(|line| *line > current).min()
        } else {
            lines.iter().copied().filter(|line| *line < current).max()
        };
        let Some(target) = target else {
            return;
        };
        let bottom = self.output_scroll.max_offset().y;
        self.follow_output = false;
        self.output_scroll
            .set_offset(point(px(0.0), (-px(target as f32 * CONSOLE_LINE_HEIGHT)).max(bottom)));
        cx.notify();
    }

    /// 打印控制台输出。GPUI 没有系统打印对话框，这里把输出写到临时文件再用
    /// 系统默认程序打开，由该程序负责打印；写盘失败时保持界面不变。
    fn print_output(&mut self, cx: &mut Context<Self>) {
        let text = self.selected_output().to_string();
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
    fn toggle_more_menu(&mut self, window: &mut Window, cx: &mut Context<Self>) {
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

        self.more_menu = Some(popup);
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

    fn render_scope_rail(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let mut rail = v_flex()
            .id("lithe-run-scopes")
            .w(px(SCOPE_RAIL_WIDTH))
            .flex_shrink_0()
            .h_full()
            .items_center()
            .gap(px(4.0))
            .pt(px(6.0))
            .min_h(px(0.0))
            .overflow_y_scroll()
            .bg(tokens.sidebar)
            .border_r_1()
            .border_color(tokens.divider);

        for (scope, icon) in [
            (RunScope::All, IconName::Inbox),
            (RunScope::Pinned, IconName::Star),
            (RunScope::Execution(RunExecution::Service), IconName::Play),
            (
                RunScope::Execution(RunExecution::Application),
                IconName::Play,
            ),
            (
                RunScope::Execution(RunExecution::Task),
                IconName::CircleCheck,
            ),
            (RunScope::Execution(RunExecution::Group), IconName::Folder),
        ] {
            let count = self.configurations_in_scope(scope).len();
            rail = rail.child(
                Button::new(format!("lithe-run:scope:{scope:?}"))
                    .ghost()
                    .small()
                    .child(Icon::new(icon).with_size(px(16.0)))
                    .tooltip(format!("{} ({count})", scope.title()))
                    .selected(self.scope == scope)
                    .on_click(cx.listener(move |this, _, _window, cx| {
                        this.scope = scope;
                        cx.notify();
                    })),
            );
        }

        rail.into_any_element()
    }

    fn render_configuration_list(&self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let configurations = self
            .configurations_in_scope(self.scope)
            .into_iter()
            .cloned()
            .collect::<Vec<_>>();
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
            list = list.child(
                h_flex()
                    .w_full()
                    .flex_shrink_0()
                    .h(px(GROUP_HEADER_HEIGHT))
                    .items_center()
                    .gap(px(6.0))
                    .px(px(10.0))
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
        let pinned = self.pinned.contains(&id);
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
        let id_for_pin = id.clone();
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
                this.follow_output = true;
                this.output_scroll.scroll_to_bottom();
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
                Button::new(format!("lithe-run:pin:{id}"))
                    .ghost()
                    .small()
                    .child(
                        Icon::new(if pinned {
                            IconName::StarFill
                        } else {
                            IconName::Star
                        })
                        .with_size(px(14.0)),
                    )
                    .tooltip(if pinned {
                        tr("Unpin configuration")
                    } else {
                        tr("Pin configuration")
                    })
                    .on_click(cx.listener(move |this, _, _window, cx| {
                        if this.pinned.contains(&id_for_pin) {
                            this.pinned.remove(&id_for_pin);
                        } else {
                            this.pinned.insert(id_for_pin.clone());
                        }
                        this.emit(cx);
                        cx.notify();
                    })),
            )
            .child(
                Button::new(format!("lithe-run:toggle:{id}"))
                    .ghost()
                    .small()
                    .icon(icon(if running {
                        LitheIcon::Close
                    } else {
                        LitheIcon::Run
                    }))
                    .tooltip(if running { tr("Stop") } else { tr("Run") })
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
        let has_output = !self.selected_output().is_empty();
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
        if self.show_details {
            return self.render_details(tokens);
        }
        let output = self.selected_output();
        let empty_message = if self.root.is_none() {
            Some(tr("Open a project to discover run configurations"))
        } else if self.configurations.is_empty() && !self.loading {
            Some(tr("No run configuration found"))
        } else {
            None
        };

        h_flex()
            .id("lithe-run-content")
            .flex_1()
            .min_w(px(0.0))
            .min_h(px(0.0))
            .bg(tokens.editor)
            // 动作条只在控制台视图出现；详情视图是纯文本表格，不需要控制台动作。
            .child(self.render_console_stripe(tokens, cx))
            .child(if let Some(message) = empty_message {
                empty_state(tokens, message)
            } else if output.is_empty() {
                empty_state(tokens, tr("Run a configuration to see process output."))
            } else {
                let text = output.to_string();
                // 控制台正文是可选中的纯文本：换行与缩进按原样排版，
                // 关掉自动换行时用横向滚动查看长行（对齐 macOS 行为）。
                let text_style = TextStyleRefinement {
                    font_family: Some(MONO_FONT_FAMILY.into()),
                    font_size: Some(px(LitheMetrics::CODE_FONT_SIZE).into()),
                    color: Some(tokens.primary_text),
                    white_space: Some(if self.wrap_output {
                        WhiteSpace::Normal
                    } else {
                        WhiteSpace::Nowrap
                    }),
                    ..Default::default()
                };
                div()
                    .id("lithe-run-console")
                    .relative()
                    .flex_1()
                    .min_h(px(0.0))
                    .min_w(px(0.0))
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
                            .overflow_scroll()
                            .track_scroll(&self.output_scroll)
                            .on_scroll(cx.listener(Self::on_console_scroll))
                            .p(px(PANEL_PADDING))
                            .child(
                                SelectableText::new("lithe-run-output-text", text)
                                    .selection_color(tokens.selection)
                                    .text_style(text_style),
                            )
                            // gpui-kit 的滚动条层：纵向 + 横向都跟随同一个句柄，
                            // 放在正文之后，保证滚动条画在文本上面。
                            .scrollbar(&self.output_scroll, ScrollbarAxis::Both),
                    )
                    // 右下角浮层：上翻后用 “Jump to latest” 回到底部，复制按钮常驻。
                    .child(
                        div()
                            .absolute()
                            .bottom(px(12.0))
                            .right(px(16.0))
                            .flex()
                            .items_center()
                            .gap(px(4.0))
                            .when(!self.follow_output, |this| {
                                this.child(
                                    Button::new("lithe-run:jump-to-latest")
                                        .ghost()
                                        .small()
                                        .icon(icon(LitheIcon::ChevronDown))
                                        .tooltip(tr("Jump to latest"))
                                        .on_click(cx.listener(|this, _, _window, cx| {
                                            this.scroll_to_latest(cx);
                                        })),
                                )
                            })
                            .child(
                                Button::new("lithe-run:copy-output")
                                    .ghost()
                                    .small()
                                    .child(Icon::new(IconName::Copy).with_size(px(14.0)))
                                    .tooltip(tr("Copy output"))
                                    .on_click(
                                        cx.listener(|this, _, _window, cx| this.copy_output(cx)),
                                    ),
                            ),
                    )
                    .into_any_element()
            })
            .into_any_element()
    }

    fn render_details(&self, tokens: LitheTokens) -> AnyElement {
        let Some(configuration) = self.selected_configuration() else {
            return empty_state(tokens, tr("Select a run configuration to see its details."));
        };
        let mut details = v_flex()
            .id("lithe-run-details")
            .flex_1()
            .min_w(px(0.0))
            .min_h(px(0.0))
            .overflow_y_scroll()
            .gap(px(10.0))
            .p(px(16.0))
            .bg(tokens.editor);

        let rows = [
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
            (
                tr("Module"),
                configuration.module().unwrap_or("—").to_string(),
                true,
            ),
            (
                tr("Main class"),
                configuration.main_class().unwrap_or("—").to_string(),
                true,
            ),
            (
                tr("Program arguments"),
                configuration
                    .maven_program_arguments()
                    .unwrap_or_else(|| configuration.args.join(" ")),
                true,
            ),
            (
                tr("Environment"),
                configuration
                    .env
                    .iter()
                    .map(|(key, value)| format!("{key}={value}"))
                    .collect::<Vec<_>>()
                    .join("\n"),
                true,
            ),
            (
                tr("Source"),
                configuration
                    .source
                    .clone()
                    .unwrap_or_else(|| "—".to_string()),
                true,
            ),
            (tr("Configuration ID"), configuration.id.clone(), true),
        ];
        for (label, value, monospaced) in rows {
            details = details.child(detail_row(label, value, monospaced, tokens));
        }
        details.into_any_element()
    }

    fn configurations_in_scope(&self, scope: RunScope) -> Vec<&RunConfiguration> {
        self.configurations
            .iter()
            .filter(|configuration| match scope {
                RunScope::All => true,
                RunScope::Pinned => self.pinned.contains(&configuration.id),
                RunScope::Execution(execution) => configuration.execution == execution,
            })
            .collect()
    }

    fn group_configurations<'a>(
        &self,
        configurations: &'a [RunConfiguration],
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

    /// 41pt 标题栏：标题 + more 菜单 + 隐藏按钮。对齐 macOS `toolWindowHeader`。
    fn render_header(&mut self, tokens: LitheTokens, cx: &mut Context<Self>) -> AnyElement {
        let menu = self.more_menu.clone();
        h_flex()
            .id("lithe-run-header")
            .w_full()
            .flex_shrink_0()
            .items_center()
            .gap(px(2.0))
            .h(px(HEADER_HEIGHT))
            .pl(px(12.0))
            .pr(px(8.0))
            .bg(tokens.tool_header)
            .border_b_1()
            .border_color(tokens.divider)
            .child(
                div()
                    .text_size(px(13.0))
                    .font_weight(FontWeight::BOLD)
                    .text_color(tokens.primary_text)
                    .child(tr("Run")),
            )
            .child(div().flex_1())
            .child(
                div()
                    .id("lithe-run-more-anchor")
                    .relative()
                    .child(
                        Button::new("lithe-run:more")
                            .ghost()
                            .small()
                            .icon(icon(LitheIcon::More))
                            .tooltip(tr("More Run actions"))
                            .on_click(cx.listener(move |this, _, window, cx| {
                                this.toggle_more_menu(window, cx)
                            })),
                    )
                    .when_some(menu, |this, popup| {
                        this.child(deferred(
                            anchored()
                                .anchor(Anchor::TopRight)
                                .snap_to_window_with_margin(px(8.0))
                                .child(div().mt(px(2.0)).child(popup)),
                        ))
                    }),
            )
            .child(
                Button::new("lithe-run:hide")
                    .ghost()
                    .small()
                    .child(Icon::new(IconName::PanelBottom).with_size(px(16.0)))
                    .tooltip(tr("Hide Run window"))
                    .on_click(cx.listener(|this, _, _window, cx| this.hide_panel(cx))),
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
        let minimum_width =
            SCOPE_RAIL_WIDTH + CONFIGURATION_LIST_MIN_WIDTH + OUTPUT_MIN_WIDTH;
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
                    .child(self.render_scope_rail(tokens, cx))
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
                    let width = width.as_f32().clamp(
                        CONFIGURATION_LIST_MIN_WIDTH,
                        CONFIGURATION_LIST_MAX_WIDTH,
                    );
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
        let tokens = current_tokens(cx);

        let mut panel = v_flex()
            .id("lithe-run-panel")
            .size_full()
            .min_w(px(0.0))
            .min_h(px(0.0))
            .bg(tokens.editor)
            .text_color(tokens.primary_text)
            .child(self.render_header(tokens, cx));

        // 工具条只在有配置或已经跑起来时出现。对齐 macOS `RunView` 的显示条件：
        // 空项目只留标题栏和空状态，不出现一排全禁用的按钮。
        if !self.configurations.is_empty() || self.is_running() {
            panel = panel.child(self.render_toolbar(tokens, cx));
        }

        if let Some(error) = self.error.clone() {
            panel = panel.child(status_line(tokens.error, error));
        }
        for banner in self.render_banners(tokens) {
            panel = panel.child(banner);
        }

        if self.loading {
            panel = panel.child(status_line(tokens.secondary_text, tr("Loading…").into()));
        }

        panel.child(self.render_body(tokens, cx))
    }
}

impl SessionState {
    fn append_output(&mut self, chunk: &str) {
        let text = strip_ansi(chunk);
        self.output.push_str(&text);
        if self.output.len() > MAX_OUTPUT_CHARACTERS {
            let cut = self.output.len().saturating_sub(MAX_OUTPUT_CHARACTERS);
            let cut = next_char_boundary(&self.output, cut);
            self.output.drain(..cut);
        }
        if self.service_url.is_none() {
            self.service_url = find_service_url(&text);
        }
    }
}

fn next_char_boundary(text: &str, mut index: usize) -> usize {
    while index < text.len() && !text.is_char_boundary(index) {
        index += 1;
    }
    index
}

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
fn is_stack_trace_line(line: &str) -> bool {
    let trimmed = line.trim_start();
    let frame = trimmed
        .strip_prefix("at ")
        .or_else(|| trimmed.strip_prefix("Caused by: "))
        .unwrap_or(trimmed);
    if let Some(open) = frame.rfind('(') {
        let inner = frame[open + 1..].trim_end_matches(')');
        if let Some((file, line_number)) = inner.rsplit_once(':') {
            return !file.is_empty() && line_number.chars().all(|character| character.is_ascii_digit());
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
