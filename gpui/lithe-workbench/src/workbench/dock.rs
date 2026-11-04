use super::notifications::NotificationKind;
use gpui_kit::component::button::{Button, ButtonVariants as _};
use gpui_kit::component::resizable::{ResizableState, h_resizable, resizable_panel};
use gpui_kit::component::{Sizable as _, v_flex};
use gpui_kit::{
    AnyElement, App, AppContext as _, Bounds, Context, DragMoveEvent, Element, ElementId, Empty,
    FontWeight, GlobalElementId, InspectorElementId, InteractiveElement as _, IntoElement,
    LayoutId, MouseButton, MouseDownEvent, MouseUpEvent, ParentElement as _, Pixels, Render,
    RenderOnce as _, SharedString, StatefulInteractiveElement as _, Style, Styled as _,
    WeakEntity, Window, div, px,
};
use lithe_ui::components::tool_window_header::ToolWindowHeader;
use lithe_ui::i18n::tr;
use lithe_ui::icons::{LitheIcon, icon};
use lithe_ui::{LitheMetrics, current_tokens};

use super::Workbench;
use crate::layout;
use crate::top_bar::{TOOL_WINDOW_HEADER_BUTTON_RADIUS, TOOL_WINDOW_HEADER_BUTTON_SIZE};
use crate::workspace_layout;

/// 底部工具窗高度拖动的载荷。
///
/// GPUI 只在存在活动拖动时派发 `on_drag_move`。载荷不绘制拖动预览，实际高度
/// 由 `Workbench` 记录的开始位置计算。
struct BottomResizeDrag;

impl Render for BottomResizeDrag {
    fn render(&mut self, _window: &mut Window, _cx: &mut Context<Self>) -> impl IntoElement {
        Empty
    }
}

/// 底部工具窗拖动的窗口级结束探测器。
///
/// 拖动会越过编辑区，而 Monaco 是覆盖在 GPUI 之上的原生 WebView，它的
/// `BlockMouse` hitbox 会让祖先元素的 `on_mouse_up` 判定为未悬停。这里与
/// `gpui-base` 的分栏组一样注册窗口级监听，保证在 WebView 上松开也能提交尺寸。
struct BottomResizeCommit {
    owner: WeakEntity<Workbench>,
}

impl IntoElement for BottomResizeCommit {
    type Element = Self;

    fn into_element(self) -> Self::Element {
        self
    }
}

impl Element for BottomResizeCommit {
    type RequestLayoutState = ();
    type PrepaintState = ();

    fn id(&self) -> Option<ElementId> {
        None
    }

    fn source_location(&self) -> Option<&'static std::panic::Location<'static>> {
        None
    }

    fn request_layout(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        window: &mut Window,
        cx: &mut App,
    ) -> (LayoutId, Self::RequestLayoutState) {
        (window.request_layout(Style::default(), None, cx), ())
    }

    fn prepaint(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        _: Bounds<Pixels>,
        _: &mut Self::RequestLayoutState,
        _: &mut Window,
        _: &mut App,
    ) -> Self::PrepaintState {
    }

    fn paint(
        &mut self,
        _: Option<&GlobalElementId>,
        _: Option<&InspectorElementId>,
        _: Bounds<Pixels>,
        _: &mut Self::RequestLayoutState,
        _: &mut Self::PrepaintState,
        window: &mut Window,
        _: &mut App,
    ) {
        let owner = self.owner.clone();
        window.on_mouse_event(move |_: &MouseUpEvent, phase, _window, cx| {
            if !phase.bubble() {
                return;
            }
            let _ = owner.update(cx, |this, cx| this.finish_bottom_resize(cx));
        });
    }
}

/// 工具窗停靠的锚点。每个锚点同一时间只显示一个工具窗。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum DockAnchor {
    Left,
    Bottom,
    Right,
}

/// 提交工具窗标题栏操作菜单里的动作。
///
/// 标题栏在 `commit_header` 里渲染，真正的 Git 写操作由 `GitPanel` 执行，
/// 两者通过这个枚举传递意图，避免布局层直接拼命令。管理器对话框只传意图
/// （`Dialog`），职开 gpui-kit 对话框由工作台覆盖层完成。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[allow(dead_code)]
pub(crate) enum CommitHeaderAction {
    StageAll,
    UnstageAll,
    DiscardSelected,
    /// 丢弃全部（Core `git.write discardAll`，确认受 confirmBeforeDiscard）。
    DiscardAll,
    /// Fetch 直执行（对齐 Tauri handleFetch，无对话框）。
    Fetch,
    /// 无仓库态的初始化（Core `git.initialize`）。
    Initialize,
    /// 打开 Git 管理器对话框（Push / Pull / Branch / …）。
    Dialog(lithe_features::git::GitDialogKind),
}

/// 工作台支持的工具窗。
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum ToolWindow {
    Project,
    Changes,
    Search,
    PullRequests,
    GitLog,
    Terminal,
    Agent,
    References,
    Problems,
    Spring,
    Run,
    Tests,
    Debug,
    BuildOutput,
    Database,
    Services,
    Extensions,
    Maven,
    /// 底部停靠的 Maven 构建输出（Tauri 底部面板的 `maven` tab）。
    MavenOutput,
}

impl ToolWindow {
    /// 持久化和活动栏共用的稳定 id。
    pub(crate) fn id(self) -> &'static str {
        match self {
            Self::Project => "project",
            Self::Changes => "changes",
            Self::Search => "search",
            Self::PullRequests => "pull-requests",
            Self::GitLog => "git-log",
            Self::Terminal => "terminal",
            Self::Agent => "agent",
            Self::References => "references",
            Self::Problems => "problems",
            Self::Spring => "spring",
            Self::Run => "run",
            Self::Tests => "tests",
            Self::Debug => "debug",
            Self::BuildOutput => "build-output",
            Self::Database => "database",
            Self::Services => "services",
            Self::Extensions => "extensions",
            Self::Maven => "maven",
            Self::MavenOutput => "maven-output",
        }
    }

    /// 从持久化 id 恢复；未知 id 返回 `None`，由调用方退回默认布局。
    pub(crate) fn from_id(id: &str) -> Option<Self> {
        match id {
            "project" | "files" => Some(Self::Project),
            "changes" | "git" => Some(Self::Changes),
            "search" => Some(Self::Search),
            "pull-requests" => Some(Self::PullRequests),
            "git-log" | "gitLog" => Some(Self::GitLog),
            "terminal" => Some(Self::Terminal),
            "agent" => Some(Self::Agent),
            "references" => Some(Self::References),
            "problems" | "diagnostics" => Some(Self::Problems),
            "spring" => Some(Self::Spring),
            "run" => Some(Self::Run),
            "tests" => Some(Self::Tests),
            "debug" => Some(Self::Debug),
            "build-output" => Some(Self::BuildOutput),
            "database" => Some(Self::Database),
            "services" => Some(Self::Services),
            "extensions" => Some(Self::Extensions),
            "maven" => Some(Self::Maven),
            "maven-output" => Some(Self::MavenOutput),
            _ => None,
        }
    }

    pub(crate) fn anchor(self) -> DockAnchor {
        match self {
            Self::Project | Self::Changes | Self::Search | Self::PullRequests => DockAnchor::Left,
            Self::GitLog
            | Self::Terminal
            | Self::References
            | Self::Problems
            | Self::Spring
            | Self::Run
            | Self::Tests
            | Self::Debug
            | Self::BuildOutput => DockAnchor::Bottom,
            Self::Database | Self::Services | Self::Extensions | Self::Agent | Self::Maven => {
                DockAnchor::Right
            }
            Self::MavenOutput => DockAnchor::Bottom,
        }
    }

    pub(crate) fn title(self) -> &'static str {
        match self {
            Self::Project => tr("Project"),
            Self::Changes => tr("Commit"),
            Self::Search => tr("Search"),
            Self::PullRequests => tr("Pull Requests"),
            Self::GitLog => tr("Git Log"),
            Self::Terminal => tr("Terminal"),
            Self::Agent => tr("Agent"),
            Self::References => tr("Usages"),
            Self::Problems => tr("Problems"),
            Self::Spring => tr("Spring Endpoints"),
            Self::Run => tr("Run"),
            Self::Tests => tr("Tests"),
            Self::Debug => tr("Debug"),
            Self::BuildOutput => tr("Build Output"),
            Self::Database => tr("Database"),
            Self::Services => tr("Services"),
            Self::Extensions => tr("Extensions"),
            Self::Maven => tr("Maven"),
            Self::MavenOutput => tr("Maven"),
        }
    }

    pub(crate) fn icon(self) -> LitheIcon {
        match self {
            Self::Project => LitheIcon::Project,
            Self::Changes => LitheIcon::Changes,
            Self::Search => LitheIcon::Search,
            Self::PullRequests => LitheIcon::PullRequests,
            Self::GitLog => LitheIcon::GitLog,
            Self::Terminal => LitheIcon::Terminal,
            Self::Agent => LitheIcon::Agent,
            Self::References => LitheIcon::References,
            Self::Problems => LitheIcon::Problems,
            Self::Spring => LitheIcon::Spring,
            Self::Run => LitheIcon::Run,
            Self::Tests => LitheIcon::Tests,
            Self::Debug => LitheIcon::Debug,
            Self::BuildOutput => LitheIcon::BuildOutput,
            Self::Database | Self::Services => LitheIcon::Project,
            Self::Extensions => LitheIcon::Extensions,
            Self::Maven | Self::MavenOutput => LitheIcon::Maven,
        }
    }

    fn unavailable_reason(self) -> &'static str {
        match self {
            Self::References => tr("References are not available in this GPUI build."),
            Self::Problems => tr("Problems are not available in this GPUI build."),
            Self::Spring => tr("Spring support is not available in this GPUI build."),
            Self::Tests => tr("Tests are not available in this GPUI build."),
            Self::Debug => tr("The debugger is not available in this GPUI build."),
            Self::BuildOutput => tr("Build output is not available in this GPUI build."),
            Self::Extensions => tr("Extensions are not available in this GPUI build."),
            _ => tr("This tool window is not available in this GPUI build."),
        }
    }

    /// 工具窗是否在标题栏显示刷新按钮。
    ///
    /// Search 不在此列：搜索面板自己按查询重新搜索，标题栏刷新既不对齐 Tauri
    /// 的搜索工具窗（它没有刷新/折叠按钮），也会和面板内的搜索按钮重复。
    /// Problems 不在此列：macOS `ProblemsView.header`（`JavaProblemsView.swift:162`）
    /// 只放 scope 切换、计数和隐藏按钮，没有刷新；JDT 按文件增量推送诊断，
    /// 多一个刷新按钮既不对齐也会让用户以为诊断需要手动拉取。GitLog 的刷新
    /// 在面板自己的工具条里（`GitLogView.swift:1140`），不走通用标题栏。
    fn supports_refresh(self) -> bool {
        matches!(self, Self::Project | Self::Changes)
    }
}

/// 一个工具窗在它所在锚点里的状态。
#[derive(Clone, Copy, Debug, Default)]
pub(super) struct ToolState {
    pub(super) visible: bool,
    pub(super) active: bool,
}

impl Workbench {
    pub(crate) fn set_project_view_dependencies(
        &mut self,
        dependencies: bool,
        cx: &mut Context<Self>,
    ) {
        self.project_view_dependencies = dependencies;
        cx.notify();
    }

    pub(crate) fn reveal_active_file_in_tree(
        &mut self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        if let Some(tab_path) = self.active_tab_path() {
            let tree = self.project_tree.clone();
            tree.update(cx, |t, cx| {
                t.reveal_path(&tab_path, window, cx);
            });
        }
    }

    pub(crate) fn toggle_project_tree_search(&mut self, cx: &mut Context<Self>) {
        self.project_search_open = !self.project_search_open;
        if !self.project_search_open {
            self.project_search_query.clear();
        }
        cx.notify();
    }

    pub(crate) fn clear_project_tree_search(&mut self, cx: &mut Context<Self>) {
        self.project_search_query.clear();
        cx.notify();
    }

    /// 头栏「隐藏文件」开关。对齐 Tauri `showHiddenFilesInFileTree`：真实
    /// 落点是项目树的点前缀行投影过滤；勾选状态只本会话记忆。
    pub(crate) fn toggle_show_hidden_files(&mut self, cx: &mut Context<Self>) {
        self.project_show_hidden = !self.project_show_hidden;
        let visible = self.project_show_hidden;
        self.project_tree
            .update(cx, |tree, tree_cx| tree.set_show_dotfiles(visible, tree_cx));
        cx.notify();
    }

    pub(super) fn toggle_tool(
        &mut self,
        tool: ToolWindow,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let anchor = tool.anchor();
        let was_active = self.tool_state(tool).active;
        let was_visible = self.tool_state(tool).visible;

        if was_visible && was_active {
            self.set_dock_visible(anchor, false, cx);
        } else {
            self.show_tool(tool, window, cx);
        }
    }

    pub(crate) fn show_tool(
        &mut self,
        tool: ToolWindow,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let anchor = tool.anchor();
        match anchor {
            DockAnchor::Left => self.active_left = tool,
            DockAnchor::Bottom => self.active_bottom = Some(tool),
            DockAnchor::Right => self.active_right = Some(tool),
        }
        self.set_dock_visible(anchor, true, cx);

        if tool == ToolWindow::Terminal {
            // Terminal 工具窗打开时保证至少有一个会话，再把焦点交给主 pane。
            // 对齐 macOS `toolContent` 的 `onActivate: { model.activeToolTerminalSession?.focus() }`
            //（WorkbenchView.swift:1525）。
            self.ensure_terminal_session(window, cx);
            self.terminal_focus_secondary = false;
            if let Some(panel) = self.active_terminal_panel() {
                panel.update(cx, |panel, panel_cx| panel.focus(window, panel_cx));
            }
        } else if tool == ToolWindow::Problems {
            // macOS `ProblemsView` 每次渲染都直接读 `EditorDiagnosticsStore`
            // 的最新快照；GPUI 的问题列表是工作台持有的事件快照，打开面板时
            // 补一次语言服务的权威结果，去掉标题栏刷新按钮后也不会看到旧诊断。
            self.refresh_problems(cx);
        } else if tool == ToolWindow::Agent {
            let agent = self.agent.clone();
            agent.update(cx, |panel, panel_cx| panel.focus(window, panel_cx));
        }
    }

    pub(crate) fn set_dock_visible(
        &mut self,
        anchor: DockAnchor,
        visible: bool,
        cx: &mut Context<Self>,
    ) {
        let was_visible = match anchor {
            DockAnchor::Left => self.left_visible,
            DockAnchor::Bottom => self.bottom_visible,
            DockAnchor::Right => self.right_visible,
        };
        match anchor {
            DockAnchor::Left => self.left_visible = visible,
            DockAnchor::Bottom => self.bottom_visible = visible,
            DockAnchor::Right => self.right_visible = visible,
        }
        if was_visible != visible {
            self.reset_dock_state(anchor, cx);
        }
        self.persist_layout();
        cx.notify();
    }

    pub(super) fn tool_state(&self, tool: ToolWindow) -> ToolState {
        let anchor = tool.anchor();
        let active = match anchor {
            DockAnchor::Left => self.active_left == tool,
            DockAnchor::Bottom => self.active_bottom == Some(tool),
            DockAnchor::Right => self.active_right == Some(tool),
        };
        let visible = active
            && match anchor {
                DockAnchor::Left => self.left_visible,
                DockAnchor::Bottom => self.bottom_visible,
                DockAnchor::Right => self.right_visible,
            };
        ToolState { visible, active }
    }

    pub(super) fn reset_dock_state(&mut self, anchor: DockAnchor, cx: &mut Context<Self>) {
        match anchor {
            DockAnchor::Left | DockAnchor::Right => {
                self.horizontal_state = cx.new(|_| ResizableState::default());
            }
            // 底部高度直接由 `bottom_height` 驱动，没有需要清空的分栏缓存。
            DockAnchor::Bottom => {}
        }
    }

    /// 提交分栏组的最新宽度。
    ///
    /// 两侧工具窗都是 `fixed` panel（见 `render_top_row`），拖动某个 handle
    /// 时 gpui-kit 只会改动紧邻它的 panel，未拖动的一侧保持原值，因此
    /// 这里按索引读回的宽度不会把另一侧带偏。写入前仍按各自区间夹紧：右侧
    /// panel 被向左拖过编辑区最小宽度时，gpui-kit 会把它撑到 `size_range`
    /// 之外，夹紧后持久化下来的仍是合法宽度。
    pub(super) fn commit_horizontal_sizes(&mut self, sizes: &[Pixels], cx: &mut Context<Self>) {
        let mut index = 0;
        if self.left_visible {
            if let Some(width) = sizes.get(index) {
                self.left_width = width.as_f32().clamp(
                    layout::LEFT_PANEL_MIN_WIDTH.as_f32(),
                    layout::LEFT_PANEL_MAX_WIDTH.as_f32(),
                );
            }
            index += 1;
        }
        index += 1; // editor
        if self.notifications_visible || self.right_visible {
            if let Some(width) = sizes.get(index) {
                self.right_width = width.as_f32().clamp(
                    layout::RIGHT_PANEL_MIN_WIDTH.as_f32(),
                    layout::RIGHT_PANEL_MAX_WIDTH.as_f32(),
                );
            }
        }
        self.persist_layout();
        cx.notify();
    }

    /// 开始拖动底部工具窗高度。
    fn begin_bottom_resize(&mut self, pointer_y: Pixels) {
        self.bottom_resize_origin = Some((pointer_y, self.bottom_height));
    }

    /// 当前窗口允许的底部工具窗最大高度：给编辑区保留最小高度。
    fn bottom_panel_max_height(window: &Window) -> Pixels {
        (window.viewport_size().height - layout::BOTTOM_PANEL_MIN_EDITOR_HEIGHT).clamp(
            layout::BOTTOM_PANEL_MIN_HEIGHT,
            layout::BOTTOM_PANEL_MAX_HEIGHT,
        )
    }

    /// 跟随指针更新底部工具窗高度，并夹在最小尺寸与窗口可容纳的上限之间。
    fn update_bottom_resize(&mut self, pointer_y: Pixels, window: &Window, cx: &mut Context<Self>) {
        let Some((origin_y, origin_height)) = self.bottom_resize_origin else {
            return;
        };
        let max_height = Self::bottom_panel_max_height(window);
        let height = (origin_height + (origin_y - pointer_y).as_f32()).clamp(
            layout::BOTTOM_PANEL_MIN_HEIGHT.as_f32(),
            max_height.as_f32(),
        );
        if (self.bottom_height - height).abs() < 0.5 {
            return;
        }
        self.bottom_height = height;
        cx.notify();
    }

    /// 结束拖动；只在高度真的变化时持久化，和分栏组的提交时机保持一致。
    fn finish_bottom_resize(&mut self, cx: &mut Context<Self>) {
        let Some((_, origin_height)) = self.bottom_resize_origin.take() else {
            return;
        };
        if (self.bottom_height - origin_height).abs() < 0.5 {
            return;
        }
        self.persist_layout();
        cx.notify();
    }

    fn on_bottom_resize_drag(
        &mut self,
        event: &DragMoveEvent<BottomResizeDrag>,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        self.update_bottom_resize(event.event.position.y, window, cx);
    }

    /// 底部工具窗上沿的 6px 拖动间隙。
    ///
    /// 对齐 Tauri `bottom-pane.tsx` 的 `resizeGutter`：全宽命中、`ns-resize`
    /// 光标，悬停和拖动都不高亮。
    fn render_bottom_resize_gutter(&self, cx: &mut Context<Self>) -> AnyElement {
        div()
            .id("lithe-bottom-pane-gutter")
            .flex_shrink_0()
            .w_full()
            .h(layout::BOTTOM_PANE_GAP)
            .cursor_row_resize()
            .on_mouse_down(
                MouseButton::Left,
                cx.listener(|this, event: &MouseDownEvent, _window, _cx| {
                    this.begin_bottom_resize(event.position.y);
                }),
            )
            .on_drag(BottomResizeDrag, |_, _, _, cx| {
                cx.stop_propagation();
                cx.new(|_| BottomResizeDrag)
            })
            .into_any_element()
    }

    pub(super) fn persist_layout(&mut self) {
        // 锚点变化同样要带上当前标签会话，否则一次拖动就会把上次的会话
        // 写成空表。走统一入口顺带取消还在排队的节流任务。
        let Some(root) = self.layout_root.clone() else {
            return;
        };
        self.persist_layout_now(&root);
    }

    pub(super) fn restore_layout(&mut self, window: &mut Window, cx: &mut Context<Self>) {
        // Render 的 defer 与 `open_project` 都可能触发恢复：二次执行会覆盖
        // 用户手选的标签，还会重复启动 watcher 与恢复会话。
        if self.layout_restored {
            return;
        }
        // 启动时自动打开的最近项目只填了 `project_root`，没有经过
        // `open_project`：这里补上工作区根，锚点布局和标签会话才会被恢复，
        // 之后的标签变化也才能继续写盘。
        if self.layout_root.is_none() {
            self.layout_root = self.project_root.clone();
        }
        let Some(root) = self.layout_root.clone() else {
            self.layout_restored = true;
            return;
        };
        let layout = workspace_layout::load(&root);
        // 与 `apply_layout`（workspace.rs）同一套容错：持久化文件可能被手工
        // 编辑，旧版本也可能把工具窗 id 写在另一个锚点。id 只在锚点匹配时
        // 生效，尺寸统一 clamp 到当前区间，避免非法值把分栏拖出屏幕。
        self.active_left = ToolWindow::from_id(&layout.active_left)
            .filter(|tool| tool.anchor() == DockAnchor::Left)
            .unwrap_or(ToolWindow::Project);
        self.active_bottom = layout
            .active_bottom
            .as_deref()
            .and_then(ToolWindow::from_id)
            .filter(|tool| tool.anchor() == DockAnchor::Bottom);
        self.active_right = layout
            .active_right
            .as_deref()
            .and_then(ToolWindow::from_id)
            .filter(|tool| tool.anchor() == DockAnchor::Right);
        self.left_visible = layout.left_visible;
        // 没有活动工具窗时不能保持“可见”：否则活动栏高亮空项、底部留出
        // 一条没有内容的空白。判定与 `apply_layout` 保持一致。
        self.bottom_visible = layout.bottom_visible && self.active_bottom.is_some();
        self.right_visible = layout.right_visible && self.active_right.is_some();
        self.left_width = layout.left_width.clamp(
            layout::LEFT_PANEL_MIN_WIDTH.as_f32(),
            layout::LEFT_PANEL_MAX_WIDTH.as_f32(),
        );
        self.right_width = layout.right_width.clamp(
            layout::RIGHT_PANEL_MIN_WIDTH.as_f32(),
            layout::RIGHT_PANEL_MAX_WIDTH.as_f32(),
        );
        self.bottom_height = layout.bottom_height.clamp(
            layout::BOTTOM_PANEL_MIN_HEIGHT.as_f32(),
            layout::BOTTOM_PANEL_MAX_HEIGHT.as_f32(),
        );
        self.horizontal_state = cx.new(|_| ResizableState::default());
        self.layout_restored = true;
        // 会话和锚点布局来自同一份读取结果，恢复顺序统一交给工作台。
        self.restore_session_tabs(layout.open_paths, layout.active_path, window, cx);
        cx.notify();
    }

    pub(crate) fn refresh_tool(
        &mut self,
        tool: ToolWindow,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match tool {
            ToolWindow::Project => self.refresh_project_tree(window, cx),
            ToolWindow::Changes => {
                self.git.update(cx, |panel, panel_cx| {
                    panel.refresh(window, panel_cx);
                });
            }
            ToolWindow::GitLog => {
                self.git_log.update(cx, |panel, panel_cx| {
                    panel.refresh(window, panel_cx);
                });
            }
            // Problems 没有独立实体，刷新就是把语言服务当前的诊断快照重新读回。
            ToolWindow::Problems => self.refresh_problems(cx),
            ToolWindow::Search => {
                let root = self.project_root.clone().unwrap_or_default();
                self.search.update(cx, |panel, panel_cx| {
                    panel.set_root(root, window, panel_cx);
                });
            }
            ToolWindow::Maven => {
                self.maven.update(cx, |panel, panel_cx| {
                    panel.refresh(window, panel_cx);
                });
            }
            _ => {}
        }
    }

    /// Maven 节点菜单的 Run：找到该模块可明确选择的运行配置并启动。
    ///
    /// 匹配规则在 `RunPanel` 里；找不到时给出明确提示，不静默失败。
    pub(crate) fn run_maven_module(
        &mut self,
        reactor_path: &str,
        module_path: &str,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        let configuration = self
            .run_panel
            .read(cx)
            .maven_module_run_configuration(reactor_path, module_path);
        match configuration {
            Some(id) => {
                self.show_tool(ToolWindow::Run, window, cx);
                self.run_panel
                    .update(cx, |panel, panel_cx| panel.run_configuration(&id, panel_cx));
            }
            None => {
                self.push_notification(
                    "Maven",
                    Some(SharedString::from(tr(
                        "No unambiguous Run configuration is available for this module.",
                    ))),
                    NotificationKind::Error,
                );
            }
        }
    }

    /// 提交工具窗标题栏操作菜单的转发入口。
    ///
    /// 标题栏只负责呈现，真正的 Git 写操作仍由 `GitPanel` 拥有；这里把菜单
    /// 请求转给同一个实体，避免在布局层复制业务规则。管理器对话框在这里
    /// 创建（`Window` 可用的唯一路径）并交给 gpui-kit 的对话框层。
    pub(crate) fn commit_header_action(
        &mut self,
        action: CommitHeaderAction,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) {
        match action {
            CommitHeaderAction::StageAll => {
                self.git
                    .update(cx, |panel, panel_cx| panel.stage_all_changes(panel_cx));
            }
            CommitHeaderAction::UnstageAll => {
                self.git
                    .update(cx, |panel, panel_cx| panel.unstage_all_changes(panel_cx));
            }
            CommitHeaderAction::DiscardSelected => {
                self.git
                    .update(cx, |panel, panel_cx| panel.discard_selected_change(panel_cx));
            }
            CommitHeaderAction::DiscardAll => {
                self.git
                    .update(cx, |panel, panel_cx| panel.discard_all_changes(panel_cx));
            }
            CommitHeaderAction::Fetch => {
                self.git
                    .update(cx, |panel, panel_cx| panel.fetch_changes(panel_cx));
            }
            CommitHeaderAction::Initialize => {
                self.git
                    .update(cx, |panel, panel_cx| panel.initialize_repository(panel_cx));
            }
            CommitHeaderAction::Dialog(kind) => {
                let panel = self.git.clone();
                let root = self.git.read(cx).repository_root().clone();
                let patch_paths: Vec<String> = match kind {
                    lithe_features::git::GitDialogKind::CreatePatch => {
                        self.git.read(cx).patch_selection().to_vec()
                    }
                    _ => Vec::new(),
                };
                let client = self.client;
                let workbench_owner = cx.weak_entity();
                crate::workbench::overlays::git_dialogs::GitDialogView::open(
                    kind,
                    client,
                    root,
                    patch_paths,
                    panel.downgrade(),
                    workbench_owner,
                    window,
                    cx,
                );
            }
        }
    }

    pub(super) fn render_dock_panel(
        &self,
        tool: ToolWindow,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let tokens = current_tokens(cx);
        // Search 没有工具窗标题栏：对齐 Tauri 侧栏搜索，它直接渲染
        // `GlobalSearchBuffer compact`，没有标题、刷新和折叠按钮。面板自己有
        // 搜索框与选项，再加一层标题栏只会浪费高度并重复控件。
        let header = if tool == ToolWindow::Search {
            None
        } else if tool == ToolWindow::Terminal {
            Some(self.render_terminal_tab_bar(window, cx))
        } else if tool == ToolWindow::Project {
            Some(crate::project_header::render_project_tool_header(
                tool,
                self.project_search_open,
                &self.project_search_query,
                self.project_options_open,
                self.project_show_hidden,
                self.project_view_dependencies,
                window,
                cx,
            ))
        } else if tool == ToolWindow::Changes {
            Some(crate::commit_header::render_commit_tool_header(
                self.commit_tab,
                self.git.read(cx).has_repository(),
                tokens,
                cx.weak_entity(),
                cx,
            ))
        } else if tool == ToolWindow::Run
            || tool == ToolWindow::GitLog
            || tool == ToolWindow::Maven
            || tool == ToolWindow::MavenOutput
        {
            // 这些面板自带标题行（对齐 Tauri 的面板内标题 + 工具条），
            // 再叠一层通用标题栏只会重复占高。
            None
        } else {
            Some(self.render_tool_header(tool, window, cx))
        };
        let content = self.render_tool_content(tool, cx);

        v_flex()
            .size_full()
            .min_h(px(0.))
            .min_w(px(0.))
            .rounded(px(LitheMetrics::PANE_RADIUS))
            .overflow_hidden()
            .border_1()
            .border_color(tokens.panel_border)
            .bg(tokens.editor)
            .children(header)
            .child(
                div()
                    .flex_1()
                    .min_h(px(0.))
                    .min_w(px(0.))
                    .overflow_hidden()
                    .child(content),
            )
            .into_any_element()
    }

    pub(super) fn render_tool_header(
        &self,
        tool: ToolWindow,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let anchor = tool.anchor();
        let refresh_owner = cx.weak_entity();
        let collapse_owner = cx.weak_entity();

        let mut header = ToolWindowHeader::new(tool.title());
        if tool.supports_refresh() {
            header = header.actions([Button::new(format!("lithe-dock-refresh:{}", tool.id()))
                .ghost()
                .with_size(px(TOOL_WINDOW_HEADER_BUTTON_SIZE))
                .rounded(px(TOOL_WINDOW_HEADER_BUTTON_RADIUS))
                .icon(icon(LitheIcon::Refresh))
                .tooltip(tr("Refresh"))
                .accessibility_label(tr("Refresh"))
                .on_click(move |_, window, cx| {
                    let _ =
                        refresh_owner.update(cx, |this, cx| this.refresh_tool(tool, window, cx));
                })
                .into_any_element()]);
        }

        header
            .on_collapse(move |_window, cx| {
                let _ =
                    collapse_owner.update(cx, |this, cx| this.set_dock_visible(anchor, false, cx));
            })
            .render(window, cx)
            .into_any_element()
    }

    pub(super) fn render_tool_content(
        &self,
        tool: ToolWindow,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        match tool {
            ToolWindow::Project => self.project_tree.clone().into_any_element(),
            // 提交 / Stash 两个分段都由同一个 `GitPanel` 渲染：分段切换经
            // `set_commit_tab` 同步到面板的 `stash_visible`，面板自己决定渲染
            // 变更树还是 stash 列表（不再需要工作台侧的占位页）。
            ToolWindow::Changes => self.git.clone().into_any_element(),
            ToolWindow::GitLog => self.git_log.clone().into_any_element(),
            ToolWindow::Search => self.search.clone().into_any_element(),
            ToolWindow::Problems => self.render_problems(cx),
            ToolWindow::Terminal => self.render_terminal_content(cx),
            ToolWindow::Agent => self.agent.clone().into_any_element(),
            ToolWindow::Run => self.run_panel.clone().into_any_element(),
            ToolWindow::Maven => self.maven.clone().into_any_element(),
            ToolWindow::MavenOutput => self.maven_output.clone().into_any_element(),
            ToolWindow::PullRequests
            | ToolWindow::References
            | ToolWindow::Spring
            | ToolWindow::Tests
            | ToolWindow::Debug
            | ToolWindow::BuildOutput
            | ToolWindow::Database
            | ToolWindow::Services
            | ToolWindow::Extensions => self.render_unavailable_tool(tool, cx),
        }
    }

    pub(super) fn render_unavailable_tool(
        &self,
        tool: ToolWindow,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let tokens = current_tokens(cx);
        v_flex()
            .size_full()
            .min_h(px(0.))
            .min_w(px(0.))
            .items_center()
            .justify_center()
            .gap(px(8.))
            .child(
                icon(tool.icon())
                    .with_size(px(28.))
                    .text_color(tokens.tertiary_text),
            )
            .child(
                div()
                    .text_size(px(LitheMetrics::UI_FONT_SIZE))
                    .font_weight(FontWeight::MEDIUM)
                    .text_color(tokens.primary_text)
                    .child(tool.title()),
            )
            .child(
                div()
                    .text_size(px(LitheMetrics::SMALL_FONT_SIZE))
                    .text_color(tokens.secondary_text)
                    .child(tool.unavailable_reason()),
            )
            .into_any_element()
    }

    pub(super) fn render_top_row(&self, window: &mut Window, cx: &mut Context<Self>) -> AnyElement {
        let owner = cx.weak_entity();
        let mut horizontal = h_resizable(layout::HORIZONTAL_GROUP_ID)
            .with_state(&self.horizontal_state)
            .on_resize(move |state, _window, cx| {
                let sizes = state.read(cx).sizes().clone();
                let _ = owner.update(cx, |this, cx| {
                    this.commit_horizontal_sizes(&sizes, cx);
                });
            });

        if self.left_visible {
            // fixed：左侧工具窗只由它自己的分隔线改宽度。gpui-kit 拖动某个
            // handle 时会把被拖动 panel 之外的余量分给同组其它 panel；不标记
            // fixed 的话，拖动右侧（Maven 等）分隔线把编辑区压到最小宽度后，
            // 多出来的位移会落到左侧 panel 上，看起来就是项目树跟着一起缩。
            horizontal = horizontal.child(
                resizable_panel()
                    .size(px(self.left_width))
                    .size_range(layout::LEFT_PANEL_MIN_WIDTH..layout::LEFT_PANEL_MAX_WIDTH)
                    .fixed()
                    .child(div().size_full().pr(px(6.)).child(self.render_dock_panel(
                        self.active_left,
                        window,
                        cx,
                    ))),
            );
        }

        horizontal = horizontal.child(
            resizable_panel()
                .size_range(layout::EDITOR_MIN_WIDTH..layout::EDITOR_MAX_WIDTH)
                .child(self.render_editor_area(window, cx)),
        );

        if self.notifications_visible {
            // 通知中心占用右栏的位置，和 Maven 等右侧工具窗同样只由自己的
            // 分隔线改宽度，不从左侧工具窗借空间。
            horizontal = horizontal.child(
                resizable_panel()
                    .size(px(self.right_width))
                    .size_range(layout::RIGHT_PANEL_MIN_WIDTH..layout::RIGHT_PANEL_MAX_WIDTH)
                    .fixed()
                    .child(
                        div()
                            .size_full()
                            .pl(px(6.))
                            .child(self.render_notifications_panel(window, cx)),
                    ),
            );
        } else if self.right_visible {
            if let Some(tool) = self.active_right {
                // 同上：右栏固定宽度，拖动它时只让编辑区让出/收回空间，
                // 反过来也不允许左侧分隔线把右栏挤窄。
                horizontal = horizontal.child(
                    resizable_panel()
                        .size(px(self.right_width))
                        .size_range(layout::RIGHT_PANEL_MIN_WIDTH..layout::RIGHT_PANEL_MAX_WIDTH)
                        .fixed()
                        .child(
                            div()
                                .size_full()
                                .pl(px(6.))
                                .child(self.render_dock_panel(tool, window, cx)),
                        ),
                );
            }
        }

        div()
            .size_full()
            .min_h(px(0.))
            .min_w(px(0.))
            .child(horizontal)
            .into_any_element()
    }

    pub(super) fn render_dock_area(
        &self,
        window: &mut Window,
        cx: &mut Context<Self>,
    ) -> AnyElement {
        let tokens = current_tokens(cx);
        let mut column = v_flex().size_full().min_h(px(0.)).min_w(px(0.)).child(
            div()
                .flex_1()
                .min_h(px(0.))
                .child(self.render_top_row(window, cx)),
        );

        if self.bottom_visible {
            if let Some(tool) = self.active_bottom {
                let max_height = Self::bottom_panel_max_height(window);
                column = column.child(self.render_bottom_resize_gutter(cx)).child(
                    div()
                        .h(px(self.bottom_height.min(max_height.as_f32())))
                        .min_h(layout::BOTTOM_PANEL_MIN_HEIGHT)
                        .max_h(max_height)
                        .child(self.render_dock_panel(tool, window, cx)),
                );
            }
        }

        div()
            .size_full()
            .min_h(px(0.))
            .min_w(px(0.))
            .p(px(4.))
            // 编辑器四周（左右留白、状态栏上方、工具窗之间的缝隙）与编辑器内容
            // 同底色：这些留白由本容器的 padding 与面板间的 gap 组成，露出的是
            // 本容器的背景，不能用窗口底色，否则编辑区会被一圈异色边框包住。
            .bg(tokens.editor)
            .on_drag_move(cx.listener(Self::on_bottom_resize_drag))
            .child(column)
            .child(BottomResizeCommit {
                owner: cx.weak_entity(),
            })
            .into_any_element()
    }
}
